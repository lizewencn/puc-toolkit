[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$UiSelfTest
)

$ErrorActionPreference = 'Stop'

function Assert-SafeIdentifier([string]$Value, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z0-9_.@-]+$') {
        throw "$Name 包含不支持的字符。"
    }
}

function Assert-SafeArgument([string]$Value, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Name 不能为空。" }
    if ($Value.IndexOfAny([char[]]@('"', "`r", "`n", '%')) -ge 0) {
        throw "$Name 包含不支持的命令行字符。"
    }
}

function Assert-NewEnvironmentPasswords([string]$AdminPassword, [string]$NewAccountPassword) {
    if ([string]::IsNullOrWhiteSpace($AdminPassword)) { throw '管理员登录密码不能为空。' }
    if ([string]::IsNullOrWhiteSpace($NewAccountPassword)) { throw '新账号及重置默认密码不能为空。' }
}

function ConvertTo-PucBaseUrlFromIp([string]$Value) {
    $ipText = $Value.Trim()
    if ($ipText -notmatch '^(?:0|[1-9]\d{0,2})(?:\.(?:0|[1-9]\d{0,2})){3}$') {
        throw '服务 IP 必须是完整的 IPv4 地址，例如 10.161.30.163。'
    }

    $address = $null
    if (-not [Net.IPAddress]::TryParse($ipText, [ref]$address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw '服务 IP 不是有效的 IPv4 地址。'
    }

    return [uri]("https://{0}:16890" -f $address.ToString())
}

function New-CommandProcessorArguments([string]$LauncherPath, [string[]]$Arguments) {
    Assert-SafeArgument $LauncherPath '脚本启动器路径'
    foreach ($argument in $Arguments) { Assert-SafeArgument ([string]$argument) '工作流参数' }
    $quotedArguments = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $command = '"' + $LauncherPath + '" ' + $quotedArguments
    return '/d /s /c "' + $command + '"'
}

function Get-LastJsonObject([string]$Text) {
    $lines = @($Text -split "`r?`n")
    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        $candidate = $lines[$index].Trim()
        if (-not $candidate.StartsWith('{')) { continue }
        try { return $candidate | ConvertFrom-Json } catch {}
    }
    return $null
}

function New-Field([string]$Key, [string]$Label, [string]$Kind, $Default = '', $Options = @(), [string]$Filter = '') {
    [pscustomobject]@{ Key=$Key; Label=$Label; Kind=$Kind; Default=$Default; Options=@($Options); Filter=$Filter }
}

$actionOptions = @(
    [pscustomobject]@{Label='查询状态';Value='Status'},
    [pscustomobject]@{Label='启用';Value='Enable'},
    [pscustomobject]@{Label='禁用';Value='Disable'}
)
$completionModeOptions = @(
    [pscustomobject]@{Label='精确账号';Value='Account'},
    [pscustomobject]@{Label='查询前缀';Value='Query'}
)
$permissionTargetOptions = @(
    [pscustomobject]@{Label='WebPUC';Value='WebPUC'},
    [pscustomobject]@{Label='APP';Value='APP'},
    [pscustomobject]@{Label='WebConfs';Value='WebConfs'}
)

$script:Operations = @(
    [pscustomobject]@{Key='create';Label='新增调度账号';Fields=@(
        (New-Field 'prefix' '账号前缀' 'Text' 'mhw'),
        (New-Field 'count' '创建数量' 'Number' 1)
    )},
    [pscustomobject]@{Key='reset';Label='重置单个账号密码';Fields=@(
        (New-Field 'account' '调度账号' 'Text')
    )},
    [pscustomobject]@{Key='reset-query';Label='批量重置密码（按查询）';Fields=@(
        (New-Field 'query' '账号查询关键字' 'Text')
    )},
    [pscustomobject]@{Key='reset-file';Label='批量重置密码（账号清单）';Fields=@(
        (New-Field 'accountsPath' '账号清单 JSON' 'File' '' @() 'JSON 文件 (*.json)|*.json')
    )},
    [pscustomobject]@{Key='complete';Label='补全账号信息';Fields=@(
        (New-Field 'targetMode' '目标方式' 'Combo' 'Account' $completionModeOptions),
        (New-Field 'target' '账号或查询前缀' 'Text'),
        (New-Field 'normalizeAlias' '规范生成账号别名' 'Check' $false)
    )},
    [pscustomobject]@{Key='update';Label='更新账号信息';Fields=@(
        (New-Field 'account' '调度账号' 'Text'),
        (New-Field 'changesPath' '变更 JSON' 'File' '' @() 'JSON 文件 (*.json)|*.json')
    )},
    [pscustomobject]@{Key='personnel-prefix';Label='批量新增通讯录人员';Fields=@(
        (New-Field 'aliasValue' '人员别名前缀' 'Text'),
        (New-Field 'startSequence' '起始序号' 'Number' 0),
        (New-Field 'count' '创建数量' 'Number' 1),
        (New-Field 'personnelTypeGuid' '人员类型 GUID' 'Text'),
        (New-Field 'dispatcherAccount' '关联调度账号（可选）' 'Text'),
        (New-Field 'rootOrganizationName' '根组织名称（可选）' 'Text')
    )},
    [pscustomobject]@{Key='personnel-exact';Label='新增指定通讯录人员';Fields=@(
        (New-Field 'aliasValue' '人员别名' 'Text'),
        (New-Field 'personnelTypeGuid' '人员类型 GUID' 'Text'),
        (New-Field 'dispatcherAccount' '关联调度账号（可选）' 'Text'),
        (New-Field 'rootOrganizationName' '根组织名称（可选）' 'Text')
    )},
    [pscustomobject]@{Key='policy';Label='首次登录密码验证';Fields=@(
        (New-Field 'action' '操作' 'Combo' 'Status' $actionOptions)
    )},
    [pscustomobject]@{Key='force-login';Label='重复登录强制下线';Fields=@(
        (New-Field 'action' '操作' 'Combo' 'Status' $actionOptions)
    )},
    [pscustomobject]@{Key='config-export';Label='导出配置';Fields=@()},
    [pscustomobject]@{Key='config-import';Label='导入配置';Fields=@(
        (New-Field 'filePath' '配置文件' 'File' '' @() '配置文件 (*.json;*.txt)|*.json;*.txt')
    )},
    [pscustomobject]@{Key='license-export';Label='导出 License';Fields=@()},
    [pscustomobject]@{Key='license-import';Label='导入 License';Fields=@(
        (New-Field 'filePath' 'License 文件' 'File' '' @() 'License 文件 (*.enc)|*.enc')
    )},
    [pscustomobject]@{Key='permission-import';Label='导入权限菜单';Fields=@(
        (New-Field 'filePath' '权限菜单 JSON' 'File' '' @() 'JSON 文件 (*.json)|*.json'),
        (New-Field 'target' '导入目标' 'Combo' 'WebPUC' $permissionTargetOptions)
    )},
    [pscustomobject]@{Key='incident-levels';Label='配置警情等级';Fields=@()}
)
$script:ShowEnvironmentPasswordsByDefault = $true
$script:DefaultNewAccountPassword = '888'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
Import-Module (Join-Path $PSScriptRoot 'PucResultRenderer.psm1') -Force

function Set-PucButtonStyle($Button, [ValidateSet('Primary','Secondary')][string]$Kind = 'Secondary') {
    $Button.AutoSize = $false
    $Button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $Button.UseVisualStyleBackColor = $false
    $Button.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
    $Button.Padding = New-Object Windows.Forms.Padding(0)

    if ($Kind -eq 'Primary') {
        $normalBackColor = [Drawing.Color]::FromArgb(0,134,126)
        $normalForeColor = [Drawing.Color]::White
        $Button.FlatAppearance.BorderSize = 0
        $Button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(0,116,109)
        $Button.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(0,96,90)
    } else {
        $normalBackColor = [Drawing.Color]::White
        $normalForeColor = [Drawing.Color]::FromArgb(28,37,44)
        $Button.FlatAppearance.BorderSize = 1
        $Button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(190,197,202)
        $Button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(232,243,242)
        $Button.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(214,234,232)
    }

    $updateEnabledStyle = {
        if ($Button.Enabled) {
            $Button.BackColor = $normalBackColor
            $Button.ForeColor = $normalForeColor
            $Button.Cursor = [Windows.Forms.Cursors]::Hand
        } else {
            $Button.BackColor = [Drawing.Color]::FromArgb(232,235,237)
            $Button.ForeColor = [Drawing.Color]::FromArgb(132,141,148)
            $Button.Cursor = [Windows.Forms.Cursors]::Default
        }
    }.GetNewClosure()
    $Button.Add_EnabledChanged($updateEnabledStyle)
    & $updateEnabledStyle
}

if ($SelfTest) {
    if ($script:Operations.Count -ne 16) { throw '操作目录数量不正确。' }
    if (-not $script:ShowEnvironmentPasswordsByDefault) { throw '新增环境的显示密码选项必须默认勾选。' }
    if ($script:DefaultNewAccountPassword -ne '888') { throw '新账号及重置默认密码必须默认为 888。' }
    Assert-NewEnvironmentPasswords -AdminPassword 'admin-test-password' -NewAccountPassword $script:DefaultNewAccountPassword
    $emptyNewAccountPasswordRejected = $false
    try { Assert-NewEnvironmentPasswords -AdminPassword 'admin-test-password' -NewAccountPassword '' } catch { $emptyNewAccountPasswordRejected = $_.Exception.Message -eq '新账号及重置默认密码不能为空。' }
    if (-not $emptyNewAccountPasswordRejected) { throw '新增环境未拒绝空的新账号及重置默认密码。' }
    $keys = @($script:Operations.Key | Sort-Object -Unique)
    if ($keys.Count -ne $script:Operations.Count) { throw '操作目录中存在重复键。' }
    $expectedKeys = @('create','reset','reset-query','reset-file','complete','update','personnel-prefix','personnel-exact','policy','force-login','config-export','config-import','license-export','license-import','permission-import','incident-levels')
    foreach ($key in $expectedKeys) { if ($key -notin $keys) { throw "操作目录缺少 $key。" } }
    if (@($script:Operations | Where-Object Key -eq 'create').Fields.Key -contains 'startSequence') {
        throw '调度账号创建不得询问起始序号。'
    }
    $environmentUri = ConvertTo-PucBaseUrlFromIp '10.161.30.163'
    if ($environmentUri.AbsoluteUri -ne 'https://10.161.30.163:16890/') { throw '服务 IP 默认地址拼接失败。' }
    $fullUrlRejected = $false
    try { [void](ConvertTo-PucBaseUrlFromIp 'https://10.161.30.163:16890') } catch { $fullUrlRejected = $true }
    if (-not $fullUrlRejected) { throw '新增环境不得接受包含协议或端口的服务地址。' }
    $workflowScripts = @('Initialize-PucConfig.ps1','Repair-PucEnvironmentNames.ps1','Get-PucEnvironmentVersion.ps1','Invoke-PucAccounts.ps1','Invoke-PucAccountPasswordReset.ps1','Invoke-PucAccountPasswordResetBatch.ps1','Invoke-PucAccountCompletion.ps1','Invoke-PucAccountUpdate.ps1','Invoke-PucPersonnel.ps1','Invoke-PucFirstLoginPasswordCheck.ps1','Invoke-PucForceLogin.ps1','Invoke-PucConfigTransfer.ps1','Invoke-PucLicense.ps1','Invoke-PucPermissionMenuImport.ps1','Invoke-PucIncidentAlarmLevels.ps1','PucResultRenderer.psm1')
    foreach ($workflowScript in $workflowScripts) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $workflowScript) -PathType Leaf)) { throw "工作流脚本不存在：$workflowScript" }
    }
    $processorArguments = New-CommandProcessorArguments -LauncherPath 'C:\Program Files\PUC\Invoke-PucScript.cmd' -Arguments @('Set-PucConfigRoot.ps1','-Status')
    if ($processorArguments -notmatch 'Invoke-PucScript\.cmd" "Set-PucConfigRoot\.ps1"') { throw '隐藏命令行构造失败。' }
    $parsed = Get-LastJsonObject "提示`n{`"status`":`"ok`",`"snapshotHash`":`"$('A' * 64)`"}"
    if ($parsed.status -ne 'ok') { throw 'JSON 结果解析失败。' }
    Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
    if ((Get-PucEnvironmentNameFromBaseUrl 'https://10.161.30.163:16890') -ne '10.161.30.163') { throw '完整环境名解析失败。' }
    $resultStartedAt = [datetime]::Now.AddSeconds(-2)
    $successModel = New-PucResultModel -Outputs @('{"status":"exported","environment":"10.161.30.163","configFilePath":"C:\\export\\config.json","configBytes":2048,"licenseFilePath":"C:\\export\\license.enc","licenseBytes":512,"token":"DO-NOT-SHOW"}') -OperationLabel '导出配置' -Environment '10.161.30.163' -Stage 'config-export' -StartedAt $resultStartedAt -ViewState Finished -ExitCode 0
    if ($successModel.Kind -ne 'Success' -or $successModel.RawText -match 'DO-NOT-SHOW') { throw '成功结果渲染或敏感字段脱敏验证失败。' }
    if (@($successModel.Fields | Where-Object Name -eq 'configFilePath').Count -ne 1) { throw '文件结果摘要验证失败。' }
    $partialModel = New-PucResultModel -Outputs @('{"status":"partial-failure","environment":"10.161.30.163","succeeded":1,"failed":1,"results":[{"account":"mhw1","status":"password-reset"},{"account":"mhw2","status":"failed","reason":"request failed"}]}') -OperationLabel '批量重置密码' -Environment '10.161.30.163' -Stage 'batch-reset-live' -StartedAt $resultStartedAt -ViewState Finished -ExitCode 1
    if ($partialModel.Kind -ne 'Warning' -or @($partialModel.Rows).Count -ne 2) { throw '部分失败结果表格验证失败。' }
    $stageModel = New-PucResultModel -Outputs @('{"status":"previewed","accounts":[{"account":"mhw1"},{"account":"mhw2"}]}','{"status":"password-reset","results":[{"account":"mhw1","status":"password-reset"},{"account":"mhw2","status":"password-reset"}]}') -OperationLabel '批量重置密码' -Environment '10.161.30.163' -Stage 'batch-reset-live' -StartedAt $resultStartedAt -ViewState Finished -ExitCode 0
    if (@($stageModel.Rows).Count -ne 2 -or @($stageModel.Rows | Where-Object group -eq '账号').Count -ne 0) { throw '执行结果不得混合预检与最终阶段数据。' }
    $createModel = New-PucResultModel -Outputs @('{"status":"created","count":2,"succeeded":2,"failed":0,"results":[{"sequence":1,"account":"mhw163001","alias":"mhw163001_alias","status":"created"},{"sequence":2,"account":"mhw163002","alias":"mhw163002_alias","status":"created"}]}','{"status":"post-create-login-policy","environment":"10.161.30.163"}') -OperationLabel '新增调度账号' -Environment '10.161.30.163' -Stage 'create-live' -StartedAt $resultStartedAt -ViewState Finished -ExitCode 0
    if (@($createModel.Rows).Count -ne 2 -or [string]$createModel.Rows[0].account -ne 'mhw163001') { throw '新增账号执行结果表格验证失败。' }
    $errorModel = New-PucResultModel -Outputs @('Request failed; authorization=SECRET-VALUE. No retry was attempted.') -OperationLabel '更新账号' -Environment '10.161.30.163' -Stage 'update-live' -StartedAt $resultStartedAt -ViewState Finished -ExitCode 1
    if ($errorModel.Kind -ne 'Warning' -or $errorModel.RawText -match 'SECRET-VALUE') { throw '结果不确定状态或详细输出脱敏验证失败。' }
    $testForm = New-Object Windows.Forms.Form
    $testButton = New-Object Windows.Forms.Button
    try {
        $testButton.Size = New-Object Drawing.Size(112,34)
        Set-PucButtonStyle $testButton 'Primary'
        $testForm.Controls.Add($testButton)
        $script:ButtonSelfTestClicked = $false
        $testButton.Add_Click({ $script:ButtonSelfTestClicked = $true })
        $insideTopLeft = $testButton.ClientRectangle.Contains((New-Object Drawing.Point(1,1)))
        $insideBottomRight = $testButton.ClientRectangle.Contains((New-Object Drawing.Point(($testButton.ClientSize.Width-2),($testButton.ClientSize.Height-2))))
        if (-not $insideTopLeft -or -not $insideBottomRight) { throw '按钮完整矩形点击区域验证失败。' }
        $onClick = [Windows.Forms.Button].GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic')
        [void]$onClick.Invoke($testButton, @([EventArgs]::Empty))
        if (-not $script:ButtonSelfTestClicked) { throw '按钮完整控件点击事件验证失败。' }
        if ($testButton.Cursor -ne [Windows.Forms.Cursors]::Hand) { throw '按钮启用状态的手型指针验证失败。' }
        if ($testButton.FlatAppearance.MouseOverBackColor -eq $testButton.BackColor) { throw '按钮悬停反馈验证失败。' }
        $testButton.Enabled = $false
        if ($testButton.Cursor -ne [Windows.Forms.Cursors]::Default) { throw '按钮禁用状态指针验证失败。' }
    } finally {
        Remove-Variable -Scope Script -Name ButtonSelfTestClicked -ErrorAction SilentlyContinue
        $testButton.Dispose()
        $testForm.Dispose()
    }
    [pscustomobject]@{status='self-test-passed';operationCount=$script:Operations.Count;language='zh-CN';buttonInteraction='passed';resultRendering='passed'} | ConvertTo-Json -Compress
    return
}

Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$script:LauncherPath = Join-Path $PSScriptRoot 'Invoke-PucScript.cmd'
$script:ExecutionState = $null
$script:FieldControls = @{}
$script:VersionLookup = $null
$script:PendingVersionEnvironment = ''

function Get-EnvironmentEntries {
    $root = Get-PucConfigRoot
    $configPath = Join-Path $root 'config.json'
    $document = Read-PucJson -Path $configPath -Default $null
    if ($null -eq $document) { return @() }
    $null = Repair-PucEnvironmentNames -ConfigRoot $root -Apply
    $document = Read-PucJson -Path $configPath -Default $null
    $entries = @($document.environments | ForEach-Object {
        [pscustomobject]@{Name=[string]$_.name;BaseUrl=[string]$_.baseUrl}
    } | Where-Object {-not [string]::IsNullOrWhiteSpace($_.Name)} | Sort-Object Name)
    return $entries
}

function New-HiddenProcess([string[]]$Arguments) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $env:ComSpec
    $startInfo.Arguments = New-CommandProcessorArguments -LauncherPath $script:LauncherPath -Arguments $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw '无法启动 PUC 工作流。' }
    [pscustomobject]@{
        Process=$process
        StandardOutput=$process.StandardOutput.ReadToEndAsync()
        StandardError=$process.StandardError.ReadToEndAsync()
    }
}

function Complete-HiddenProcess($Handle) {
    $Handle.Process.WaitForExit()
    $output = [string]$Handle.StandardOutput.Result
    $errorOutput = [string]$Handle.StandardError.Result
    $exitCode = $Handle.Process.ExitCode
    $Handle.Process.Dispose()
    $combined = @($output.TrimEnd(),$errorOutput.TrimEnd()) | Where-Object {-not [string]::IsNullOrWhiteSpace($_)}
    [pscustomobject]@{ExitCode=$exitCode;Text=($combined -join "`r`n")}
}

function New-TempManifest([string]$Prefix) {
    $directory = Join-Path ([IO.Path]::GetTempPath()) 'puc-config-launcher'
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    Join-Path $directory ($Prefix + '-' + [guid]::NewGuid().ToString('N') + '.json')
}

function Get-FieldValue([string]$Key) {
    if (-not $script:FieldControls.ContainsKey($Key)) { return $null }
    $entry = $script:FieldControls[$Key]
    switch ($entry.Kind) {
        'Text' { return $entry.Input.Text.Trim() }
        'File' { return $entry.Input.Text.Trim() }
        'Number' { return [int]$entry.Input.Value }
        'Check' { return [bool]$entry.Input.Checked }
        'Combo' { return [string]$entry.Input.SelectedItem.Value }
    }
}

function Assert-ExistingFile([string]$Path, [string[]]$Extensions, [string]$Name) {
    Assert-SafeArgument $Path $Name
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "$Name 不存在：$resolved" }
    if ($Extensions.Count -gt 0 -and [IO.Path]::GetExtension($resolved).ToLowerInvariant() -notin $Extensions) {
        throw "$Name 的文件类型不正确。"
    }
    return $resolved
}

$form = New-Object Windows.Forms.Form
$form.Text = 'PUC Toolkit'
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'Sizable'
$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.AutoScaleMode = 'Dpi'
$form.ClientSize = New-Object Drawing.Size(760,520)
$form.MinimumSize = New-Object Drawing.Size(776,600)
$form.BackColor = [Drawing.Color]::FromArgb(246,248,250)
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI',9)

$header = New-Object Windows.Forms.Panel
$header.Location = New-Object Drawing.Point(0,0)
$header.Size = New-Object Drawing.Size(760,58)
$header.Anchor = 'Top,Left,Right'
$header.BackColor = [Drawing.Color]::White
$form.Controls.Add($header)

$title = New-Object Windows.Forms.Label
$title.Text = 'PUC Toolkit'
$title.Font = New-Object Drawing.Font('Microsoft YaHei UI',15,[Drawing.FontStyle]::Bold)
$title.ForeColor = [Drawing.Color]::FromArgb(28,37,44)
$title.AutoSize = $true
$title.Location = New-Object Drawing.Point(24,15)
$header.Controls.Add($title)

$accent = New-Object Windows.Forms.Panel
$accent.Location = New-Object Drawing.Point(0,55)
$accent.Size = New-Object Drawing.Size(760,3)
$accent.Anchor = 'Left,Right,Bottom'
$accent.BackColor = [Drawing.Color]::FromArgb(0,134,126)
$header.Controls.Add($accent)

$selectionPanel = New-Object Windows.Forms.Panel
$selectionPanel.Location = New-Object Drawing.Point(0,58)
$selectionPanel.Size = New-Object Drawing.Size(760,104)
$selectionPanel.Anchor = 'Top,Left,Right'
$selectionPanel.BackColor = [Drawing.Color]::FromArgb(246,248,250)
$form.Controls.Add($selectionPanel)

$environmentLabel = New-Object Windows.Forms.Label
$environmentLabel.Text = '环境'
$environmentLabel.AutoSize = $true
$environmentLabel.Location = New-Object Drawing.Point(24,15)
$selectionPanel.Controls.Add($environmentLabel)

$environmentBox = New-Object Windows.Forms.ComboBox
$environmentBox.DropDownStyle = 'DropDownList'
$environmentBox.Location = New-Object Drawing.Point(24,38)
$environmentBox.Size = New-Object Drawing.Size(206,28)
$environmentBox.DisplayMember = 'Name'
$selectionPanel.Controls.Add($environmentBox)

$operationLabel = New-Object Windows.Forms.Label
$operationLabel.Text = '操作'
$operationLabel.AutoSize = $true
$operationLabel.Location = New-Object Drawing.Point(250,15)
$selectionPanel.Controls.Add($operationLabel)

$operationBox = New-Object Windows.Forms.ComboBox
$operationBox.DropDownStyle = 'DropDownList'
$operationBox.Location = New-Object Drawing.Point(250,38)
$operationBox.Size = New-Object Drawing.Size(278,28)
$operationBox.DisplayMember = 'Label'
foreach ($operation in $script:Operations) { $operationBox.Items.Add($operation) | Out-Null }
$operationBox.SelectedIndex = 0
$selectionPanel.Controls.Add($operationBox)

$addEnvironmentButton = New-Object Windows.Forms.Button
$addEnvironmentButton.Text = '新增环境'
$addEnvironmentButton.Location = New-Object Drawing.Point(544,35)
$addEnvironmentButton.Size = New-Object Drawing.Size(88,34)
Set-PucButtonStyle $addEnvironmentButton
$selectionPanel.Controls.Add($addEnvironmentButton)

$reloadButton = New-Object Windows.Forms.Button
$reloadButton.Text = '刷新'
$reloadButton.Location = New-Object Drawing.Point(644,35)
$reloadButton.Size = New-Object Drawing.Size(88,34)
Set-PucButtonStyle $reloadButton
$selectionPanel.Controls.Add($reloadButton)

$addressLabel = New-Object Windows.Forms.Label
$addressLabel.AutoSize = $false
$addressLabel.ForeColor = [Drawing.Color]::FromArgb(92,102,110)
$addressLabel.Location = New-Object Drawing.Point(24,76)
$addressLabel.Size = New-Object Drawing.Size(310,22)
$addressLabel.AutoEllipsis = $true
$selectionPanel.Controls.Add($addressLabel)

$versionLabel = New-Object Windows.Forms.Label
$versionLabel.Text = '版本：未获取'
$versionLabel.AutoSize = $false
$versionLabel.ForeColor = [Drawing.Color]::FromArgb(92,102,110)
$versionLabel.Location = New-Object Drawing.Point(350,76)
$versionLabel.Size = New-Object Drawing.Size(184,22)
$versionLabel.AutoEllipsis = $true
$selectionPanel.Controls.Add($versionLabel)

$versionCompatibilityWarningLabel = New-Object Windows.Forms.Label
$versionCompatibilityWarningLabel.Text = '不同版本号上表现可能存在差异'
$versionCompatibilityWarningLabel.AutoSize = $false
$versionCompatibilityWarningLabel.ForeColor = [Drawing.Color]::FromArgb(192,57,43)
$versionCompatibilityWarningLabel.Location = New-Object Drawing.Point(542,76)
$versionCompatibilityWarningLabel.Size = New-Object Drawing.Size(190,22)
$versionCompatibilityWarningLabel.Anchor = 'Top,Right'
$versionCompatibilityWarningLabel.TextAlign = [Drawing.ContentAlignment]::TopLeft
$selectionPanel.Controls.Add($versionCompatibilityWarningLabel)

$versionToolTip = New-Object Windows.Forms.ToolTip

$inputPanel = New-Object Windows.Forms.Panel
$inputPanel.Location = New-Object Drawing.Point(0,162)
$inputPanel.Size = New-Object Drawing.Size(760,0)
$inputPanel.Anchor = 'Top,Left,Right'
$inputPanel.BackColor = [Drawing.Color]::White
$form.Controls.Add($inputPanel)

$actionPanel = New-Object Windows.Forms.Panel
$actionPanel.Location = New-Object Drawing.Point(0,162)
$actionPanel.Size = New-Object Drawing.Size(760,62)
$actionPanel.Anchor = 'Top,Left,Right'
$actionPanel.BackColor = [Drawing.Color]::FromArgb(246,248,250)
$form.Controls.Add($actionPanel)

$runButton = New-Object Windows.Forms.Button
$runButton.Text = '执行'
$runButton.Location = New-Object Drawing.Point(24,14)
$runButton.Size = New-Object Drawing.Size(112,34)
Set-PucButtonStyle $runButton 'Primary'
$actionPanel.Controls.Add($runButton)

$clearButton = New-Object Windows.Forms.Button
$clearButton.Text = '清空结果'
$clearButton.Location = New-Object Drawing.Point(148,14)
$clearButton.Size = New-Object Drawing.Size(112,34)
Set-PucButtonStyle $clearButton
$actionPanel.Controls.Add($clearButton)

$confirmButton = New-Object Windows.Forms.Button
$confirmButton.Text = '确认执行'
$confirmButton.Location = New-Object Drawing.Point(24,14)
$confirmButton.Size = New-Object Drawing.Size(112,34)
$confirmButton.Visible = $false
Set-PucButtonStyle $confirmButton 'Primary'
$actionPanel.Controls.Add($confirmButton)

$cancelConfirmationButton = New-Object Windows.Forms.Button
$cancelConfirmationButton.Text = '取消'
$cancelConfirmationButton.Location = New-Object Drawing.Point(148,14)
$cancelConfirmationButton.Size = New-Object Drawing.Size(112,34)
$cancelConfirmationButton.Visible = $false
Set-PucButtonStyle $cancelConfirmationButton
$actionPanel.Controls.Add($cancelConfirmationButton)

$statusLabel = New-Object Windows.Forms.Label
$statusLabel.Text = '就绪'
$statusLabel.AutoSize = $false
$statusLabel.ForeColor = [Drawing.Color]::FromArgb(92,102,110)
$statusLabel.Location = New-Object Drawing.Point(282,12)
$statusLabel.Size = New-Object Drawing.Size(450,38)
$statusLabel.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
$statusLabel.AutoEllipsis = $true
$actionPanel.Controls.Add($statusLabel)

$resultLabel = New-Object Windows.Forms.Label
$resultLabel.Text = '运行信息'
$resultLabel.AutoSize = $true
$resultLabel.Location = New-Object Drawing.Point(24,236)
$form.Controls.Add($resultLabel)

$resultTabs = New-Object Windows.Forms.TabControl
$resultTabs.Location = New-Object Drawing.Point(24,260)
$resultTabs.Size = New-Object Drawing.Size(708,320)
$resultTabs.Padding = New-Object Drawing.Point(14,5)
$resultTabs.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($resultTabs)

$summaryTab = New-Object Windows.Forms.TabPage
$summaryTab.Text = '执行摘要'
$summaryTab.BackColor = [Drawing.Color]::White
$resultTabs.TabPages.Add($summaryTab)

$resultLayout = New-Object Windows.Forms.TableLayoutPanel
$resultLayout.Dock = [Windows.Forms.DockStyle]::Fill
$resultLayout.ColumnCount = 1
$resultLayout.RowCount = 2
$resultLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
$resultLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,42))) | Out-Null
$resultLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
$summaryTab.Controls.Add($resultLayout)

$resultTab = New-Object Windows.Forms.TabPage
$resultTab.Text = '执行结果'
$resultTab.BackColor = [Drawing.Color]::White
$resultTabs.TabPages.Add($resultTab)

$detailsTab = New-Object Windows.Forms.TabPage
$detailsTab.Text = '详细输出'
$detailsTab.BackColor = [Drawing.Color]::White
$resultTabs.TabPages.Add($detailsTab)

$resultStatusPanel = New-Object Windows.Forms.Panel
$resultStatusPanel.Dock = [Windows.Forms.DockStyle]::Fill
$resultLayout.Controls.Add($resultStatusPanel,0,0)

$resultStatusTitle = New-Object Windows.Forms.Label
$resultStatusTitle.Text = '就绪'
$resultStatusTitle.AutoSize = $true
$resultStatusTitle.Font = New-Object Drawing.Font('Microsoft YaHei UI',11,[Drawing.FontStyle]::Bold)
$resultStatusTitle.Location = New-Object Drawing.Point(14,10)
$resultStatusPanel.Controls.Add($resultStatusTitle)

$resultFields = New-Object Windows.Forms.ListView
$resultFields.Dock = [Windows.Forms.DockStyle]::Fill
$resultFields.View = [Windows.Forms.View]::Details
$resultFields.HeaderStyle = [Windows.Forms.ColumnHeaderStyle]::Nonclickable
$resultFields.FullRowSelect = $true
$resultFields.GridLines = $false
$resultFields.HideSelection = $false
$resultFields.MultiSelect = $false
$resultFields.BorderStyle = [Windows.Forms.BorderStyle]::None
$resultFields.BackColor = [Drawing.Color]::White
$resultFields.Columns.Add('项目',145) | Out-Null
$resultFields.Columns.Add('内容',510) | Out-Null
$resultLayout.Controls.Add($resultFields,0,1)

$emptyResultLabel = New-Object Windows.Forms.Label
$emptyResultLabel.Text = '当前阶段暂无明细结果。'
$emptyResultLabel.Dock = [Windows.Forms.DockStyle]::Fill
$emptyResultLabel.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
$emptyResultLabel.ForeColor = [Drawing.Color]::FromArgb(92,102,110)
$resultTab.Controls.Add($emptyResultLabel)

$resultGrid = New-Object Windows.Forms.DataGridView
$resultGrid.Dock = [Windows.Forms.DockStyle]::Fill
$resultGrid.ReadOnly = $true
$resultGrid.AllowUserToAddRows = $false
$resultGrid.AllowUserToDeleteRows = $false
$resultGrid.AllowUserToResizeRows = $false
$resultGrid.MultiSelect = $false
$resultGrid.SelectionMode = [Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$resultGrid.RowHeadersVisible = $false
$resultGrid.BackgroundColor = [Drawing.Color]::White
$resultGrid.BorderStyle = [Windows.Forms.BorderStyle]::None
$resultGrid.AutoSizeRowsMode = [Windows.Forms.DataGridViewAutoSizeRowsMode]::AllCells
$resultGrid.ColumnHeadersHeightSizeMode = [Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
$resultGrid.DefaultCellStyle.WrapMode = [Windows.Forms.DataGridViewTriState]::True
$resultGrid.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(214,234,232)
$resultGrid.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::FromArgb(28,37,44)
$resultGrid.Visible = $false
$resultTab.Controls.Add($resultGrid)

$detailsBox = New-Object Windows.Forms.RichTextBox
$detailsBox.Dock = [Windows.Forms.DockStyle]::Fill
$detailsBox.ReadOnly = $true
$detailsBox.BorderStyle = [Windows.Forms.BorderStyle]::None
$detailsBox.BackColor = [Drawing.Color]::FromArgb(250,251,252)
$detailsBox.ForeColor = [Drawing.Color]::FromArgb(38,45,50)
$detailsBox.Font = New-Object Drawing.Font('Consolas',9)
$detailsBox.WordWrap = $false
$detailsBox.DetectUrls = $false
$detailsTab.Controls.Add($detailsBox)

function Resize-FormForFields([int]$InputHeight) {
    $inputPanel.Height = $InputHeight
    $actionY = 162 + $InputHeight
    $actionPanel.Top = $actionY
    $resultLabel.Top = $actionY + 70
    $resultTop = $actionY + 94
    $workingHeight = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height
    $maxClientHeight = [Math]::Max(520,$workingHeight - 56)
    $availableResultHeight = $maxClientHeight - $resultTop - 20
    $resultHeight = [Math]::Max(244,[Math]::Min(340,$availableResultHeight))
    $targetWidth = [Math]::Max(760,$form.ClientSize.Width)
    $form.ClientSize = New-Object Drawing.Size($targetWidth,($resultTop + $resultHeight + 20))
    $resultTabs.Top = $resultTop
    $resultTabs.Height = $resultHeight
}

function Get-PucOperationDisplayLabel([string]$Key) {
    $operation = @($script:Operations | Where-Object Key -eq $Key | Select-Object -First 1)
    if ($operation.Count -eq 1) { return [string]$operation[0].Label }
    return $Key
}

function Get-PucStageDisplayLabel([string]$Stage) {
    $labels = @{
        'create-live'='新增账号';'create-large-live'='新增账号';'reset-preview'='密码重置预检';'reset-live'='重置密码'
        'batch-reset-preview'='批量重置预检';'batch-reset-live'='批量重置密码';'completion-preview'='账号补全预检'
        'completion-live'='补全账号信息';'update-plan'='检查变更文件';'update-preview'='账号更新预检';'update-live'='更新账号'
        'personnel-preview'='人员新增预检';'personnel-live'='新增人员';'policy-status'='查询首次登录策略'
        'policy-preview'='首次登录策略预检';'policy-live'='更新首次登录策略';'force-status'='查询重复登录策略'
        'force-preview'='重复登录策略预检';'force-live'='更新重复登录策略';'config-export'='导出配置和 License'
        'config-import-plan'='检查配置文件';'config-import-live'='导入配置';'license-export'='导出 License'
        'license-import-plan'='检查 License 文件';'license-import-preview'='License 导入预检';'license-import-live'='导入 License'
        'permission-import-plan'='检查权限菜单';'permission-import-live'='导入权限菜单';'incident-preview'='警情等级预检'
        'incident-live'='配置警情等级'
    }
    if ($labels.ContainsKey($Stage)) { return $labels[$Stage] }
    return $Stage
}

function Get-PucResultRowKeys($Row) {
    if ($Row -is [Collections.IDictionary]) { return @($Row.Keys | ForEach-Object { [string]$_ }) }
    return @($Row.PSObject.Properties.Name)
}

function Get-PucResultRowValue($Row, [string]$Name) {
    if ($Row -is [Collections.IDictionary]) {
        if ($Row.Contains($Name)) { return [string]$Row[$Name] }
        return ''
    }
    $property = $Row.PSObject.Properties[$Name]
    if ($null -eq $property) { return '' }
    return [string]$property.Value
}

function Show-PucResultModel($Model) {
    $palette = switch ([string]$Model.Kind) {
        'Success' { @{Back=[Drawing.Color]::FromArgb(231,245,239);Fore=[Drawing.Color]::FromArgb(0,105,78)} }
        'Warning' { @{Back=[Drawing.Color]::FromArgb(255,245,219);Fore=[Drawing.Color]::FromArgb(154,96,0)} }
        'Error' { @{Back=[Drawing.Color]::FromArgb(253,236,234);Fore=[Drawing.Color]::FromArgb(174,52,45)} }
        'Progress' { @{Back=[Drawing.Color]::FromArgb(232,243,242);Fore=[Drawing.Color]::FromArgb(0,105,99)} }
        default { @{Back=[Drawing.Color]::FromArgb(238,241,243);Fore=[Drawing.Color]::FromArgb(76,86,94)} }
    }
    $resultStatusPanel.BackColor = $palette.Back
    $resultStatusTitle.ForeColor = $palette.Fore
    $resultStatusTitle.Text = [string]$Model.Heading

    $resultFields.BeginUpdate()
    try {
        $resultFields.Items.Clear()
        foreach ($field in @($Model.Fields)) {
            $item = New-Object Windows.Forms.ListViewItem([string]$field.Label)
            [void]$item.SubItems.Add([string]$field.Value)
            $item.ToolTipText = "$([string]$field.Label)：$([string]$field.Value)"
            [void]$resultFields.Items.Add($item)
        }
    } finally { $resultFields.EndUpdate() }

    $rows = @($Model.Rows)
    $resultGrid.SuspendLayout()
    try {
        $resultGrid.Rows.Clear()
        $resultGrid.Columns.Clear()
        if ($rows.Count -gt 0) {
            $allNames = [Collections.Generic.List[string]]::new()
            foreach ($row in $rows) {
                foreach ($name in @(Get-PucResultRowKeys $row)) {
                    if (-not $allNames.Contains($name)) { $allNames.Add($name) }
                }
            }
            if ($allNames.Contains('group')) {
                $groupValues = @($rows | ForEach-Object { Get-PucResultRowValue $_ 'group' } | Sort-Object -Unique)
                if ($groupValues.Count -le 1) { [void]$allNames.Remove('group') }
            }
            $preferred = @('group','account','alias','name','code','field','status','ok','result','oldValue','newValue','reason','error','value','snapshotHash')
            $columns = [Collections.Generic.List[string]]::new()
            foreach ($name in $preferred) { if ($allNames.Contains($name) -and $columns.Count -lt 9) { $columns.Add($name) } }
            foreach ($name in $allNames) { if (-not $columns.Contains($name) -and $columns.Count -lt 9) { $columns.Add($name) } }
            foreach ($name in $columns) {
                $index = $resultGrid.Columns.Add($name,(Get-PucResultLabel $name))
                $resultGrid.Columns[$index].SortMode = [Windows.Forms.DataGridViewColumnSortMode]::Automatic
                $resultGrid.Columns[$index].AutoSizeMode = [Windows.Forms.DataGridViewAutoSizeColumnMode]::DisplayedCells
                $resultGrid.Columns[$index].MinimumWidth = 70
            }
            $compactNames = @('sequence','count','accountCount','itemCount','nodeCount','updateCount','succeeded','failed','writesUsed','plannedWrites','stage1Result','stage2Result','result','percentage')
            foreach ($column in @($resultGrid.Columns)) {
                if ($column.Name -eq 'account') {
                    $column.AutoSizeMode = [Windows.Forms.DataGridViewAutoSizeColumnMode]::None
                    $column.MinimumWidth = 140
                    $column.Width = 150
                } elseif ($column.Name -in $compactNames) {
                    $column.AutoSizeMode = [Windows.Forms.DataGridViewAutoSizeColumnMode]::None
                    $column.MinimumWidth = 48
                    $column.Width = 56
                } elseif ($column.Name -eq 'snapshotHash') {
                    $column.AutoSizeMode = [Windows.Forms.DataGridViewAutoSizeColumnMode]::None
                    $column.MinimumWidth = 130
                    $column.Width = 180
                }
            }
            foreach ($row in $rows) {
                $values = @($columns | ForEach-Object { Get-PucResultRowValue $row $_ })
                [void]$resultGrid.Rows.Add($values)
            }
            if ($resultGrid.Columns.Count -gt 0) {
                $fillColumn = @($resultGrid.Columns | Where-Object Name -in @('reason','error','value','newValue','finalPasswordStatus','alias','name','account') | Select-Object -Last 1)
                if ($fillColumn.Count -eq 0) { $fillColumn = @($resultGrid.Columns | Where-Object Name -notin $compactNames | Select-Object -Last 1) }
                if ($fillColumn.Count -eq 0) { $fillColumn = @($resultGrid.Columns[$resultGrid.Columns.Count-1]) }
                $fillColumn[0].AutoSizeMode = [Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
            }
            $resultGrid.Visible = $true
            $emptyResultLabel.Visible = $false
        } else {
            $resultGrid.Visible = $false
            $emptyResultLabel.Visible = $true
        }
    } finally {
        $resultGrid.ResumeLayout()
        $resultTab.PerformLayout()
    }

    $detailsBox.Text = if ([string]::IsNullOrWhiteSpace([string]$Model.RawText)) { '暂无详细输出。' } else { [string]$Model.RawText }
    $detailsBox.SelectionStart = 0
    $detailsBox.ScrollToCaret()
    $resultTabs.SelectedTab = if ($rows.Count -gt 0 -and [string]$Model.StatusText -eq '等待确认') { $resultTab } else { $summaryTab }
}

function Clear-PucResultView {
    $model = New-PucResultModel -OperationLabel '' -Environment '' -Stage '' -ViewState Idle
    Show-PucResultModel $model
}

function Show-PucStandaloneResult {
    param(
        [string]$OperationLabel,
        [string]$Environment,
        [string]$Stage,
        [string[]]$Outputs = @(),
        [datetime]$StartedAt = [datetime]::Now,
        [ValidateSet('Progress','Finished')][string]$ViewState = 'Finished',
        [int]$ExitCode = 0
    )
    $model = New-PucResultModel -Outputs $Outputs -OperationLabel $OperationLabel -Environment $Environment -Stage $Stage -StartedAt $StartedAt -ViewState $ViewState -ExitCode $ExitCode
    Show-PucResultModel $model
}

function New-InputControl($Field, [int]$X, [int]$Y, [int]$Width) {
    $label = New-Object Windows.Forms.Label
    $label.Text = [string]$Field.Label
    $label.AutoSize = $true
    $label.Location = New-Object Drawing.Point($X,$Y)
    $inputPanel.Controls.Add($label)
    $controlY = $Y + 23
    $input = $null
    $additionalControls = @()
    switch ([string]$Field.Kind) {
        'Text' {
            $input = New-Object Windows.Forms.TextBox
            $input.Text = [string]$Field.Default
            $input.Location = New-Object Drawing.Point($X,$controlY)
            $input.Size = New-Object Drawing.Size($Width,27)
        }
        'Number' {
            $input = New-Object Windows.Forms.NumericUpDown
            $input.Minimum = 0
            $input.Maximum = 1000
            $input.Value = [decimal]$Field.Default
            $input.Location = New-Object Drawing.Point($X,$controlY)
            $input.Size = New-Object Drawing.Size($Width,27)
        }
        'Check' {
            $label.Visible = $false
            $input = New-Object Windows.Forms.CheckBox
            $input.Text = [string]$Field.Label
            $input.Checked = [bool]$Field.Default
            $input.AutoSize = $true
            $input.Location = New-Object Drawing.Point($X,($Y + 22))
        }
        'Combo' {
            $input = New-Object Windows.Forms.ComboBox
            $input.DropDownStyle = 'DropDownList'
            $input.DisplayMember = 'Label'
            foreach ($option in $Field.Options) { $input.Items.Add($option) | Out-Null }
            $selected = 0
            for ($index = 0; $index -lt $input.Items.Count; $index++) {
                if ([string]$input.Items[$index].Value -eq [string]$Field.Default) { $selected = $index; break }
            }
            $input.SelectedIndex = $selected
            $input.Location = New-Object Drawing.Point($X,$controlY)
            $input.Size = New-Object Drawing.Size($Width,28)
        }
        'File' {
            $input = New-Object Windows.Forms.TextBox
            $input.Text = [string]$Field.Default
            $input.Location = New-Object Drawing.Point($X,$controlY)
            $input.Size = New-Object Drawing.Size(($Width - 82),27)
            $browse = New-Object Windows.Forms.Button
            $browse.Text = '选择...'
            $browse.Location = New-Object Drawing.Point(($X + $Width - 74),($controlY - 3))
            $browse.Size = New-Object Drawing.Size(74,32)
            Set-PucButtonStyle $browse
            $textBox = $input
            $filter = [string]$Field.Filter
            $browse.Add_Click({
                $dialog = New-Object Windows.Forms.OpenFileDialog
                $dialog.Filter = $filter
                $dialog.CheckFileExists = $true
                if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) { $textBox.Text = $dialog.FileName }
                $dialog.Dispose()
            }.GetNewClosure())
            $inputPanel.Controls.Add($browse)
            $additionalControls += $browse
        }
        default { throw "不支持的字段类型：$($Field.Kind)" }
    }
    $inputPanel.Controls.Add($input)
    $script:FieldControls[$Field.Key] = [pscustomobject]@{Kind=$Field.Kind;Input=$input;Label=$label;AdditionalControls=$additionalControls}
}

function Rebuild-Inputs {
    $inputPanel.SuspendLayout()
    $inputPanel.Controls.Clear()
    $script:FieldControls = @{}
    $fields = @($operationBox.SelectedItem.Fields)
    if ($fields.Count -eq 0) {
        Resize-FormForFields 0
        $inputPanel.ResumeLayout()
        return
    }
    $rowHeight = 66
    for ($index = 0; $index -lt $fields.Count; $index++) {
        $column = $index % 2
        $row = [Math]::Floor($index / 2)
        $x = if ($column -eq 0) {24} else {386}
        New-InputControl -Field $fields[$index] -X $x -Y (12 + ($row * $rowHeight)) -Width 346
    }
    $rows = [Math]::Ceiling($fields.Count / 2)
    Resize-FormForFields (20 + ($rows * $rowHeight))
    $inputPanel.ResumeLayout()
}

function Set-ControlsEnabled([bool]$Enabled) {
    $environmentBox.Enabled = $Enabled
    $operationBox.Enabled = $Enabled
    $addEnvironmentButton.Enabled = $Enabled
    $reloadButton.Enabled = $Enabled
    $runButton.Enabled = $Enabled
    $clearButton.Enabled = $Enabled
    foreach ($entry in $script:FieldControls.Values) {
        $entry.Input.Enabled = $Enabled
        foreach ($control in $entry.AdditionalControls) { $control.Enabled = $Enabled }
    }
}

function Set-ConfirmationMode([bool]$Enabled) {
    $runButton.Visible = -not $Enabled
    $clearButton.Visible = -not $Enabled
    $confirmButton.Visible = $Enabled
    $cancelConfirmationButton.Visible = $Enabled
    $confirmButton.Enabled = $Enabled
    $cancelConfirmationButton.Enabled = $Enabled
}

function Request-EnvironmentVersion([string]$Environment) {
    $script:PendingVersionEnvironment = $Environment
    if ([string]::IsNullOrWhiteSpace($Environment)) {
        $versionLabel.Text = '版本：未选择环境'
        $versionToolTip.SetToolTip($versionLabel,'')
        return
    }
    $versionLabel.Text = '版本：正在获取...'
    $versionToolTip.SetToolTip($versionLabel,"正在读取 https://$Environment`:16890/env.js")
    if ($null -ne $script:VersionLookup) { return }
    try {
        $script:VersionLookup = [pscustomobject]@{
            Environment=$Environment
            Handle=(New-HiddenProcess @('Get-PucEnvironmentVersion.ps1','-Environment',$Environment))
        }
    } catch {
        $script:VersionLookup = $null
        $versionLabel.Text = '版本：获取失败'
        $versionToolTip.SetToolTip($versionLabel,$_.Exception.Message)
    }
}

function Update-EnvironmentVersionLookup {
    if ($null -eq $script:VersionLookup) { return }
    $process = $script:VersionLookup.Handle.Process
    $process.Refresh()
    if (-not $process.HasExited) { return }
    $completedEnvironment = [string]$script:VersionLookup.Environment
    $result = Complete-HiddenProcess $script:VersionLookup.Handle
    $script:VersionLookup = $null

    if ([string]::Equals($completedEnvironment,$script:PendingVersionEnvironment,[StringComparison]::Ordinal)) {
        if ($result.ExitCode -eq 0) {
            try {
                $json = Get-LastJsonObject $result.Text
                $version = [string]$json.version
                if ([string]::IsNullOrWhiteSpace($version)) { throw '版本响应缺少 version。' }
                $versionLabel.Text = "版本：$version"
                $versionLabel.ForeColor = [Drawing.Color]::FromArgb(38,80,75)
                $versionToolTip.SetToolTip($versionLabel,$versionLabel.Text)
            } catch {
                $versionLabel.Text = '版本：解析失败'
                $versionLabel.ForeColor = [Drawing.Color]::FromArgb(184,70,45)
                $versionToolTip.SetToolTip($versionLabel,$_.Exception.Message)
            }
        } else {
            $versionLabel.Text = '版本：获取失败'
            $versionLabel.ForeColor = [Drawing.Color]::FromArgb(184,70,45)
            $versionToolTip.SetToolTip($versionLabel,$result.Text)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($script:PendingVersionEnvironment) -and
        -not [string]::Equals($completedEnvironment,$script:PendingVersionEnvironment,[StringComparison]::Ordinal)) {
        Request-EnvironmentVersion $script:PendingVersionEnvironment
    }
}

function Update-EnvironmentAddress {
    if ($null -eq $environmentBox.SelectedItem) { $addressLabel.Text = ''; Request-EnvironmentVersion ''; return }
    $addressLabel.Text = [string]$environmentBox.SelectedItem.BaseUrl
    $versionLabel.ForeColor = [Drawing.Color]::FromArgb(92,102,110)
    Request-EnvironmentVersion ([string]$environmentBox.SelectedItem.Name)
}

function Load-Environments([string]$PreferredName = '') {
    $selectedName = if (-not [string]::IsNullOrWhiteSpace($PreferredName)) {$PreferredName} elseif ($null -ne $environmentBox.SelectedItem) {[string]$environmentBox.SelectedItem.Name} else {''}
    $entries = @(Get-EnvironmentEntries)
    $environmentBox.Items.Clear()
    foreach ($entry in $entries) { $environmentBox.Items.Add($entry) | Out-Null }
    $selectedIndex = if($environmentBox.Items.Count -gt 0){0}else{-1}
    for ($index = 0; $index -lt $environmentBox.Items.Count; $index++) {
        if ([string]$environmentBox.Items[$index].Name -eq $selectedName) { $selectedIndex = $index; break }
    }
    $environmentBox.SelectedIndex = $selectedIndex
    Update-EnvironmentAddress
}

function Show-NewEnvironmentDialog {
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = '新增 PUC 环境'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = New-Object Drawing.Size(520,514)
    $dialog.BackColor = [Drawing.Color]::FromArgb(246,248,250)
    $dialog.Font = New-Object Drawing.Font('Microsoft YaHei UI',9)

    $fields = @(
        [pscustomobject]@{Label='服务 IP';Y=24},
        [pscustomobject]@{Label='Realm';Y=88},
        [pscustomobject]@{Label='管理员账号';Y=152},
        [pscustomobject]@{Label='复用本地密码配置';Y=216}
    )
    foreach($field in $fields){
        $label=New-Object Windows.Forms.Label;$label.Text=$field.Label;$label.AutoSize=$true;$label.Location=New-Object Drawing.Point(24,$field.Y);$dialog.Controls.Add($label)
    }
    $protocolLabel=New-Object Windows.Forms.Label;$protocolLabel.Text='https://';$protocolLabel.AutoSize=$true;$protocolLabel.Location=New-Object Drawing.Point(24,53);$dialog.Controls.Add($protocolLabel)
    $ipBox=New-Object Windows.Forms.TextBox;$ipBox.Location=New-Object Drawing.Point(82,48);$ipBox.Size=New-Object Drawing.Size(352,27);$dialog.Controls.Add($ipBox)
    $portLabel=New-Object Windows.Forms.Label;$portLabel.Text=':16890';$portLabel.AutoSize=$true;$portLabel.Location=New-Object Drawing.Point(440,53);$dialog.Controls.Add($portLabel)
    $realmBox=New-Object Windows.Forms.TextBox;$realmBox.Text='puc.com';$realmBox.Location=New-Object Drawing.Point(24,112);$realmBox.Size=New-Object Drawing.Size(472,27);$dialog.Controls.Add($realmBox)
    $adminBox=New-Object Windows.Forms.TextBox;$adminBox.Text='admin';$adminBox.Location=New-Object Drawing.Point(24,176);$adminBox.Size=New-Object Drawing.Size(472,27);$dialog.Controls.Add($adminBox)
    $templateBox=New-Object Windows.Forms.ComboBox;$templateBox.DropDownStyle='DropDownList';$templateBox.DisplayMember='Label';$templateBox.Location=New-Object Drawing.Point(24,240);$templateBox.Size=New-Object Drawing.Size(300,28)
    $templateBox.Items.Add([pscustomobject]@{Label='不复用';Value=''})|Out-Null
    foreach($entry in @(Get-EnvironmentEntries)){$templateBox.Items.Add([pscustomobject]@{Label=$entry.Name;Value=$entry.Name})|Out-Null}
    $templateBox.SelectedIndex=0;$dialog.Controls.Add($templateBox)
    $tlsBox=New-Object Windows.Forms.CheckBox;$tlsBox.Text='允许自签名 TLS 证书';$tlsBox.Checked=$true;$tlsBox.AutoSize=$true;$tlsBox.Location=New-Object Drawing.Point(342,242);$dialog.Controls.Add($tlsBox)

    $passwordPanel=New-Object Windows.Forms.Panel;$passwordPanel.Location=New-Object Drawing.Point(0,280);$passwordPanel.Size=New-Object Drawing.Size(520,166);$passwordPanel.BackColor=$dialog.BackColor;$dialog.Controls.Add($passwordPanel)
    $adminPasswordLabel=New-Object Windows.Forms.Label;$adminPasswordLabel.Text='管理员登录密码';$adminPasswordLabel.AutoSize=$true;$adminPasswordLabel.Location=New-Object Drawing.Point(24,0);$passwordPanel.Controls.Add($adminPasswordLabel)
    $adminPasswordBox=New-Object Windows.Forms.TextBox;$adminPasswordBox.Location=New-Object Drawing.Point(24,24);$adminPasswordBox.Size=New-Object Drawing.Size(472,27);$adminPasswordBox.UseSystemPasswordChar=$true;$passwordPanel.Controls.Add($adminPasswordBox)
    $newAccountPasswordLabel=New-Object Windows.Forms.Label;$newAccountPasswordLabel.Text='新账号及重置默认密码（必填）';$newAccountPasswordLabel.AutoSize=$true;$newAccountPasswordLabel.Location=New-Object Drawing.Point(24,66);$passwordPanel.Controls.Add($newAccountPasswordLabel)
    $newAccountPasswordBox=New-Object Windows.Forms.TextBox;$newAccountPasswordBox.Text=$script:DefaultNewAccountPassword;$newAccountPasswordBox.Location=New-Object Drawing.Point(24,90);$newAccountPasswordBox.Size=New-Object Drawing.Size(472,27);$newAccountPasswordBox.UseSystemPasswordChar=$true;$passwordPanel.Controls.Add($newAccountPasswordBox)
    $showPasswordBox=New-Object Windows.Forms.CheckBox;$showPasswordBox.Text='显示密码';$showPasswordBox.AutoSize=$true;$showPasswordBox.Location=New-Object Drawing.Point(24,130);$passwordPanel.Controls.Add($showPasswordBox)

    $saveButton=New-Object Windows.Forms.Button;$saveButton.Text='新增';$saveButton.Size=New-Object Drawing.Size(96,34);$saveButton.Location=New-Object Drawing.Point(296,458);Set-PucButtonStyle $saveButton 'Primary';$dialog.Controls.Add($saveButton)
    $cancelButton=New-Object Windows.Forms.Button;$cancelButton.Text='取消';$cancelButton.Size=New-Object Drawing.Size(96,34);$cancelButton.Location=New-Object Drawing.Point(400,458);$cancelButton.DialogResult=[Windows.Forms.DialogResult]::Cancel;Set-PucButtonStyle $cancelButton;$dialog.Controls.Add($cancelButton)
    $dialog.AcceptButton=$saveButton;$dialog.CancelButton=$cancelButton
    $showPasswordBox.Add_CheckedChanged({$masked=-not$showPasswordBox.Checked;$adminPasswordBox.UseSystemPasswordChar=$masked;$newAccountPasswordBox.UseSystemPasswordChar=$masked})
    $showPasswordBox.Checked=$script:ShowEnvironmentPasswordsByDefault
    $updatePasswordLayout={
        $usesTemplate=-not[string]::IsNullOrWhiteSpace([string]$templateBox.SelectedItem.Value)
        $passwordPanel.Visible=-not$usesTemplate
        $buttonY=if($usesTemplate){300}else{458}
        $saveButton.Top=$buttonY;$cancelButton.Top=$buttonY
        $dialog.ClientSize=New-Object Drawing.Size(520,($buttonY+56))
    }
    $templateBox.Add_SelectedIndexChanged($updatePasswordLayout)
    & $updatePasswordLayout
    $saveButton.Add_Click({
        try{
            $uri=ConvertTo-PucBaseUrlFromIp $ipBox.Text
            $name=Get-PucEnvironmentNameFromBaseUrl -BaseUrl $uri
            if(@(Get-EnvironmentEntries|Where-Object Name -eq $name).Count -gt 0){throw "环境 $name 已存在。"}
            $realm=$realmBox.Text.Trim();Assert-SafeArgument $realm 'Realm'
            $admin=$adminBox.Text.Trim();Assert-SafeArgument $admin '管理员账号'
            $template=[string]$templateBox.SelectedItem.Value
            $adminPassword=if([string]::IsNullOrWhiteSpace($template)){$adminPasswordBox.Text}else{''}
            $newAccountPassword=if([string]::IsNullOrWhiteSpace($template)){$newAccountPasswordBox.Text}else{''}
            if([string]::IsNullOrWhiteSpace($template)){Assert-NewEnvironmentPasswords -AdminPassword $adminPassword -NewAccountPassword $newAccountPassword}
            $dialog.Tag=[pscustomobject]@{Name=$name;BaseUrl=$uri.AbsoluteUri.TrimEnd('/');Realm=$realm;AdminAccount=$admin;TemplateEnvironment=$template;AllowInsecureTls=[bool]$tlsBox.Checked;AdminPassword=$adminPassword;NewAccountPassword=$newAccountPassword}
            $dialog.DialogResult=[Windows.Forms.DialogResult]::OK;$dialog.Close()
        }catch{[Windows.Forms.MessageBox]::Show($dialog,$_.Exception.Message,'新增环境','OK','Warning')|Out-Null}
    })
    try{if($dialog.ShowDialog($form)-eq[Windows.Forms.DialogResult]::OK){return $dialog.Tag};return $null}finally{$dialog.Dispose()}
}

function Start-Stage([string]$Stage, [string[]]$Arguments) {
    $script:ExecutionState.Stage = $Stage
    $script:ExecutionState.Handle = New-HiddenProcess $Arguments
    $statusLabel.Text = switch -Wildcard ($Stage) {
        '*-plan' {'正在检查文件...'}
        '*-preview' {'正在预检...'}
        default {'正在执行...'}
    }
    Show-CurrentOutputs -ViewState Progress
}

function Show-CurrentOutputs {
    param(
        [ValidateSet('Progress','Confirmation','Finished')][string]$ViewState = 'Progress',
        [int]$ExitCode = 0
    )
    if ($null -eq $script:ExecutionState) { return }
    $model = New-PucResultModel `
        -Outputs @($script:ExecutionState.Outputs) `
        -OperationLabel (Get-PucOperationDisplayLabel ([string]$script:ExecutionState.Operation)) `
        -Environment ([string]$script:ExecutionState.Environment) `
        -Stage (Get-PucStageDisplayLabel ([string]$script:ExecutionState.Stage)) `
        -StartedAt ([datetime]$script:ExecutionState.StartedAt) `
        -ViewState $ViewState `
        -ExitCode $ExitCode
    Show-PucResultModel $model
}

function Remove-ExecutionTempFiles {
    if ($null -eq $script:ExecutionState) { return }
    foreach ($path in $script:ExecutionState.TempPaths) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Finish-Execution([int]$ExitCode, [string]$ExtraText = '') {
    if (-not [string]::IsNullOrWhiteSpace($ExtraText)) { $script:ExecutionState.Outputs.Add($ExtraText) }
    Show-CurrentOutputs -ViewState Finished -ExitCode $ExitCode
    $cancelled = -not [string]::IsNullOrWhiteSpace($ExtraText) -and $ExtraText -match '(?i)(用户已取消|cancelled|canceled)'
    $statusLabel.Text = if ($cancelled) {'已取消'} elseif ($ExitCode -eq 0) {'执行完成'} else {"执行失败（退出码 $ExitCode）"}
    $statusLabel.ForeColor = if ($cancelled) {[Drawing.Color]::FromArgb(92,102,110)} elseif ($ExitCode -eq 0) {[Drawing.Color]::FromArgb(0,115,90)} else {[Drawing.Color]::FromArgb(184,70,45)}
    Remove-ExecutionTempFiles
    $script:ExecutionState = $null
    Set-ConfirmationMode $false
    Set-ControlsEnabled $true
}

function Request-PreviewConfirmation {
    param(
        [string]$Prompt,
        [string]$NextStage,
        [string[]]$Arguments,
        [string]$CancelText = '用户已取消执行。'
    )
    if ($null -eq $script:ExecutionState) { throw '当前没有可确认的执行任务。' }
    $script:ExecutionState.PendingConfirmation = [pscustomobject]@{
        Prompt=$Prompt
        NextStage=$NextStage
        Arguments=@($Arguments)
        CancelText=$CancelText
    }
    Show-CurrentOutputs -ViewState Confirmation
    Set-ConfirmationMode $true
    $statusLabel.Text = $Prompt
    $statusLabel.ForeColor = [Drawing.Color]::FromArgb(154,96,0)
}

function Confirm-PendingPreview {
    if ($null -eq $script:ExecutionState -or $null -eq $script:ExecutionState.PendingConfirmation) { return }
    $pending = $script:ExecutionState.PendingConfirmation
    $script:ExecutionState.PendingConfirmation = $null
    Set-ConfirmationMode $false
    Start-Stage -Stage ([string]$pending.NextStage) -Arguments @($pending.Arguments)
}

function Cancel-PendingPreview {
    if ($null -eq $script:ExecutionState -or $null -eq $script:ExecutionState.PendingConfirmation) { return }
    $cancelText = [string]$script:ExecutionState.PendingConfirmation.CancelText
    $script:ExecutionState.PendingConfirmation = $null
    Set-ConfirmationMode $false
    Finish-Execution 0 $cancelText
}

function Start-RequestedWorkflow {
    $environment = [string]$environmentBox.SelectedItem.Name
    $operation = [string]$operationBox.SelectedItem.Key
    $state = [pscustomobject]@{
        Environment=$environment;Operation=$operation;Stage='';Handle=$null;PendingConfirmation=$null
        StartedAt=[datetime]::Now
        Outputs=[Collections.Generic.List[string]]::new()
        TempPaths=[Collections.Generic.List[string]]::new()
        Data=@{}
    }
    $script:ExecutionState = $state
    switch ($operation) {
        'create' {
            $prefix = [string](Get-FieldValue 'prefix')
            if ($prefix -notmatch '^[A-Za-z0-9_]+$') { throw '账号前缀只能包含字母、数字和下划线。' }
            $count = [int](Get-FieldValue 'count')
            if ($count -lt 1) { throw '创建数量必须大于 0。' }
            $state.Data.Prefix=$prefix;$state.Data.Count=$count
            Start-Stage 'create-live' @('Invoke-PucAccounts.ps1','-Environment',$environment,'-Prefix',$prefix,'-Count',[string]$count,'-Live','-ConfirmLive')
        }
        'reset' {
            $account = [string](Get-FieldValue 'account');Assert-SafeIdentifier $account '调度账号';$state.Data.Account=$account
            Start-Stage 'reset-preview' @('Invoke-PucAccountPasswordReset.ps1','-Environment',$environment,'-Account',$account,'-DryRun')
        }
        'reset-query' {
            $query = [string](Get-FieldValue 'query');Assert-SafeIdentifier $query '账号查询关键字'
            $manifest = New-TempManifest 'password-reset';$state.TempPaths.Add($manifest);$state.Data.Manifest=$manifest;$state.Data.QueryMode=$true
            Start-Stage 'batch-reset-preview' @('Invoke-PucAccountPasswordResetBatch.ps1','-Environment',$environment,'-Query',$query,'-DryRun','-ManifestPath',$manifest)
        }
        'reset-file' {
            $path = Assert-ExistingFile ([string](Get-FieldValue 'accountsPath')) @('.json') '账号清单'
            $manifest = New-TempManifest 'password-reset';$state.TempPaths.Add($manifest);$state.Data.Manifest=$manifest;$state.Data.QueryMode=$false
            Start-Stage 'batch-reset-preview' @('Invoke-PucAccountPasswordResetBatch.ps1','-Environment',$environment,'-AccountsPath',$path,'-DryRun','-ManifestPath',$manifest)
        }
        'complete' {
            $mode=[string](Get-FieldValue 'targetMode');$target=[string](Get-FieldValue 'target');Assert-SafeIdentifier $target '账号或查询前缀'
            $manifest=New-TempManifest 'account-completion';$state.TempPaths.Add($manifest);$state.Data.Manifest=$manifest;$state.Data.QueryMode=($mode -eq 'Query')
            $arguments=@('Invoke-PucAccountCompletion.ps1','-Environment',$environment)
            if($mode -eq 'Query'){$arguments+=@('-Query',$target)}else{$arguments+=@('-Account',$target)}
            if(Get-FieldValue 'normalizeAlias'){$arguments+='-NormalizeGeneratedAlias';$state.Data.NormalizeAlias=$true}
            $arguments+=@('-DryRun','-ManifestPath',$manifest)
            Start-Stage 'completion-preview' $arguments
        }
        'update' {
            $account=[string](Get-FieldValue 'account');Assert-SafeIdentifier $account '调度账号'
            $path=Assert-ExistingFile ([string](Get-FieldValue 'changesPath')) @('.json') '变更 JSON'
            $state.Data.Account=$account;$state.Data.FilePath=$path
            Start-Stage 'update-plan' @('Invoke-PucAccountUpdate.ps1','-Environment',$environment,'-Account',$account,'-ChangesPath',$path,'-PlanOnly')
        }
        {$_ -in @('personnel-prefix','personnel-exact')} {
            $alias=[string](Get-FieldValue 'aliasValue');Assert-SafeArgument $alias '人员别名或前缀'
            $guidText=[string](Get-FieldValue 'personnelTypeGuid');$parsedGuid=[guid]::Empty
            if(-not [guid]::TryParse($guidText,[ref]$parsedGuid)){throw '人员类型 GUID 格式不正确。'}
            $arguments=@('Invoke-PucPersonnel.ps1','-Environment',$environment,'-PersonnelTypeGuid',$guidText)
            if($operation -eq 'personnel-exact'){$arguments+=@('-ExactAlias',$alias)}else{
                $count=[int](Get-FieldValue 'count');if($count -lt 1){throw '创建数量必须大于 0。'}
                $arguments+=@('-AliasPrefix',$alias,'-StartSequence',[string](Get-FieldValue 'startSequence'),'-Count',[string]$count)
            }
            $dispatcher=[string](Get-FieldValue 'dispatcherAccount');if($dispatcher){Assert-SafeArgument $dispatcher '关联调度账号';$arguments+=@('-DispatcherAccount',$dispatcher)}
            $rootOrg=[string](Get-FieldValue 'rootOrganizationName');if($rootOrg){Assert-SafeArgument $rootOrg '根组织名称';$arguments+=@('-RootOrganizationName',$rootOrg)}
            $state.Data.BaseArguments=@($arguments)
            Start-Stage 'personnel-preview' (@($arguments)+@('-DryRun'))
        }
        'policy' {
            $action=[string](Get-FieldValue 'action');$state.Data.Action=$action
            $arguments=@('Invoke-PucFirstLoginPasswordCheck.ps1','-Environment',$environment,'-Action',$action,'-DryRun')
            Start-Stage $(if($action -eq 'Status'){'policy-status'}else{'policy-preview'}) $arguments
        }
        'force-login' {
            $action=[string](Get-FieldValue 'action');$state.Data.Action=$action
            $arguments=@('Invoke-PucForceLogin.ps1','-Environment',$environment,'-Action',$action,'-DryRun')
            Start-Stage $(if($action -eq 'Status'){'force-status'}else{'force-preview'}) $arguments
        }
        'config-export' { Start-Stage 'config-export' @('Invoke-PucConfigTransfer.ps1','-Action','Export','-Environment',$environment) }
        'config-import' {
            $path=Assert-ExistingFile ([string](Get-FieldValue 'filePath')) @('.json','.txt') '配置文件';$state.Data.FilePath=$path
            Start-Stage 'config-import-plan' @('Invoke-PucConfigTransfer.ps1','-Action','Import','-Environment',$environment,'-FilePath',$path,'-PlanOnly')
        }
        'license-export' { Start-Stage 'license-export' @('Invoke-PucLicense.ps1','-Action','Export','-Environment',$environment) }
        'license-import' {
            $path=Assert-ExistingFile ([string](Get-FieldValue 'filePath')) @('.enc') 'License 文件';$state.Data.FilePath=$path
            Start-Stage 'license-import-plan' @('Invoke-PucLicense.ps1','-Action','Import','-Environment',$environment,'-FilePath',$path,'-PlanOnly')
        }
        'permission-import' {
            $path=Assert-ExistingFile ([string](Get-FieldValue 'filePath')) @('.json') '权限菜单文件';$target=[string](Get-FieldValue 'target')
            $state.Data.FilePath=$path;$state.Data.Target=$target
            Start-Stage 'permission-import-plan' @('Invoke-PucPermissionMenuImport.ps1','-Environment',$environment,'-FilePath',$path,'-Target',$target,'-PlanOnly')
        }
        'incident-levels' { Start-Stage 'incident-preview' @('Invoke-PucIncidentAlarmLevels.ps1','-Environment',$environment,'-DryRun') }
        default { throw '不支持的操作。' }
    }
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 200
$timer.Add_Tick({
    Update-EnvironmentVersionLookup
    if($null -eq $script:ExecutionState -or $null -eq $script:ExecutionState.Handle){return}
    $process=$script:ExecutionState.Handle.Process;$process.Refresh();if(-not $process.HasExited){return}
    $result=Complete-HiddenProcess $script:ExecutionState.Handle
    $script:ExecutionState.Handle=$null
    $stage=[string]$script:ExecutionState.Stage
    if(-not [string]::IsNullOrWhiteSpace($result.Text)){$script:ExecutionState.Outputs.Add($result.Text)}

    if($stage -eq 'create-live' -and $result.ExitCode -ne 0 -and $result.Text -match 'ACCOUNT_LOOKUP_DECISION_REQUIRED'){
        Request-PreviewConfirmation -Prompt '请查看完整账号预览，确认是否继续创建。' -NextStage 'create-large-live' -Arguments @('Invoke-PucAccounts.ps1','-Environment',$script:ExecutionState.Environment,'-Prefix',$script:ExecutionState.Data.Prefix,'-Count',[string]$script:ExecutionState.Data.Count,'-Live','-ConfirmLive','-ContinueWhenMoreThan30Accounts') -CancelText '用户已取消继续创建。';return
    }
    if($result.ExitCode -ne 0){Finish-Execution $result.ExitCode;return}

    $json=Get-LastJsonObject $result.Text
    try {
        switch($stage){
            'reset-preview' {
                $hash=[string]$json.snapshotHash;if($hash -notmatch '^[A-Fa-f0-9]{64}$'){throw '预检未返回有效的账号快照哈希。'}
                Start-Stage 'reset-live' @('Invoke-PucAccountPasswordReset.ps1','-Environment',$script:ExecutionState.Environment,'-Account',$script:ExecutionState.Data.Account,'-Live','-ConfirmLive','-ExpectedSnapshotHash',$hash);return
            }
            'batch-reset-preview' {
                $nextArguments=@('Invoke-PucAccountPasswordResetBatch.ps1','-Environment',$script:ExecutionState.Environment,'-Live','-ConfirmLive','-ManifestPath',$script:ExecutionState.Data.Manifest)
                if($script:ExecutionState.Data.QueryMode){Request-PreviewConfirmation -Prompt '请查看完整账号列表，确认是否重置这些账号的密码。' -NextStage 'batch-reset-live' -Arguments $nextArguments -CancelText '用户已取消批量重置。';return}
                Start-Stage 'batch-reset-live' $nextArguments;return
            }
            'completion-preview' {
                $args=@('Invoke-PucAccountCompletion.ps1','-Environment',$script:ExecutionState.Environment,'-Live','-ConfirmLive','-ManifestPath',$script:ExecutionState.Data.Manifest)
                if($script:ExecutionState.Data.NormalizeAlias){$args+='-NormalizeGeneratedAlias'}
                if($script:ExecutionState.Data.QueryMode){Request-PreviewConfirmation -Prompt '请查看完整账号列表，确认是否补全这些账号的信息。' -NextStage 'completion-live' -Arguments $args -CancelText '用户已取消批量补全。';return}
                Start-Stage 'completion-live' $args;return
            }
            'update-plan' {
                Start-Stage 'update-preview' @('Invoke-PucAccountUpdate.ps1','-Environment',$script:ExecutionState.Environment,'-Account',$script:ExecutionState.Data.Account,'-ChangesPath',$script:ExecutionState.Data.FilePath,'-DryRun');return
            }
            'update-preview' {
                $hash=[string]$json.snapshotHash;if($hash -notmatch '^[A-Fa-f0-9]{64}$'){throw '预检未返回有效的账号快照哈希。'}
                Start-Stage 'update-live' @('Invoke-PucAccountUpdate.ps1','-Environment',$script:ExecutionState.Environment,'-Account',$script:ExecutionState.Data.Account,'-ChangesPath',$script:ExecutionState.Data.FilePath,'-Live','-ConfirmLive','-ExpectedSnapshotHash',$hash);return
            }
            'personnel-preview' { Start-Stage 'personnel-live' (@($script:ExecutionState.Data.BaseArguments)+@('-Live','-ConfirmLive'));return }
            'policy-preview' {
                if($json.writeRequired -ne $true){Finish-Execution 0;return}
                Start-Stage 'policy-live' @('Invoke-PucFirstLoginPasswordCheck.ps1','-Environment',$script:ExecutionState.Environment,'-Action',$script:ExecutionState.Data.Action,'-Live','-ConfirmLive');return
            }
            'force-preview' {
                if([string]$json.status -eq 'no-change'){Finish-Execution 0;return}
                Start-Stage 'force-live' @('Invoke-PucForceLogin.ps1','-Environment',$script:ExecutionState.Environment,'-Action',$script:ExecutionState.Data.Action,'-Live','-ConfirmLive');return
            }
            'config-import-plan' {
                Request-PreviewConfirmation -Prompt '请核对环境、文件路径、大小和哈希，确认是否导入配置。' -NextStage 'config-import-live' -Arguments @('Invoke-PucConfigTransfer.ps1','-Action','Import','-Environment',$script:ExecutionState.Environment,'-FilePath',$script:ExecutionState.Data.FilePath,'-ConfirmImport') -CancelText '用户已取消配置导入。';return
            }
            'license-import-plan' {
                Start-Stage 'license-import-preview' @('Invoke-PucLicense.ps1','-Action','Import','-Environment',$script:ExecutionState.Environment,'-FilePath',$script:ExecutionState.Data.FilePath,'-DryRun');return
            }
            'license-import-preview' {
                $hash=[string]$json.previewHash;if($hash -notmatch '^[A-Fa-f0-9]{64}$'){throw '预检未返回有效的 License 预览哈希。'}
                Request-PreviewConfirmation -Prompt '请核对 License 预览结果，确认是否导入并替换当前 License。' -NextStage 'license-import-live' -Arguments @('Invoke-PucLicense.ps1','-Action','Import','-Environment',$script:ExecutionState.Environment,'-FilePath',$script:ExecutionState.Data.FilePath,'-Live','-ConfirmImport','-ExpectedPreviewHash',$hash) -CancelText '用户已取消 License 导入。';return
            }
            'permission-import-plan' {
                Request-PreviewConfirmation -Prompt '请核对环境、文件和导入目标，确认是否替换权限菜单。' -NextStage 'permission-import-live' -Arguments @('Invoke-PucPermissionMenuImport.ps1','-Environment',$script:ExecutionState.Environment,'-FilePath',$script:ExecutionState.Data.FilePath,'-Target',$script:ExecutionState.Data.Target,'-ConfirmImport') -CancelText '用户已取消权限菜单导入。';return
            }
            'incident-preview' {
                $hash=[string]$json.PreviewHash;if($hash -notmatch '^[A-Fa-f0-9]{64}$'){throw '预检未返回有效的警情等级预览哈希。'}
                Start-Stage 'incident-live' @('Invoke-PucIncidentAlarmLevels.ps1','-Environment',$script:ExecutionState.Environment,'-Live','-ConfirmLive','-ExpectedPreviewHash',$hash);return
            }
            default { Finish-Execution 0;return }
        }
    } catch { Finish-Execution 1 $_.Exception.Message }
})
$timer.Start()

$operationBox.Add_SelectedIndexChanged({Rebuild-Inputs})
$environmentBox.Add_SelectedIndexChanged({Update-EnvironmentAddress})
$form.Add_Resize({
    if ($resultFields.Columns.Count -ge 2) {
        $resultFields.Columns[1].Width = [Math]::Max(180,$resultFields.ClientSize.Width - $resultFields.Columns[0].Width - 8)
    }
})
$addEnvironmentButton.Add_Click({
    $startedAt=[datetime]::Now
    $newEnvironment=Show-NewEnvironmentDialog
    if($null -eq $newEnvironment){return}
    try{
        Set-ControlsEnabled $false;Show-PucStandaloneResult -OperationLabel '新增环境' -Environment $newEnvironment.Name -Stage '保存本地环境配置' -StartedAt $startedAt -ViewState Progress;$statusLabel.Text='正在新增环境...';$statusLabel.ForeColor=[Drawing.Color]::FromArgb(92,102,110)
        $root=Get-PucConfigRoot
        $parameters=@{ConfigRoot=$root;BaseUrl=[uri]$newEnvironment.BaseUrl;Realm=$newEnvironment.Realm;AdminAccount=$newEnvironment.AdminAccount;AllowInsecureTls=[bool]$newEnvironment.AllowInsecureTls}
        if([string]::IsNullOrWhiteSpace($newEnvironment.TemplateEnvironment)){
            $parameters.UseProvidedPasswords=$true
            $parameters.AdminPassword=$newEnvironment.AdminPassword
            $parameters.NewAccountPassword=$newEnvironment.NewAccountPassword
        }else{$parameters.TemplateEnvironment=$newEnvironment.TemplateEnvironment}
        $result=Initialize-PucEnvironmentConfig @parameters
        Load-Environments -PreferredName $newEnvironment.Name
        Show-PucStandaloneResult -OperationLabel '新增环境' -Environment $newEnvironment.Name -Stage '保存本地环境配置' -Outputs @(($result|ConvertTo-Json -Depth 10 -Compress)) -StartedAt $startedAt -ViewState Finished -ExitCode 0
        $statusLabel.Text='环境新增完成';$statusLabel.ForeColor=[Drawing.Color]::FromArgb(0,115,90)
    }catch{
        Show-PucStandaloneResult -OperationLabel '新增环境' -Environment $newEnvironment.Name -Stage '保存本地环境配置' -Outputs @($_.Exception.Message) -StartedAt $startedAt -ViewState Finished -ExitCode 1
        $statusLabel.Text='新增环境失败';$statusLabel.ForeColor=[Drawing.Color]::FromArgb(184,70,45)
        [Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'新增环境','OK','Warning')|Out-Null
    }finally{
        $newEnvironment.AdminPassword=$null;$newEnvironment.NewAccountPassword=$null
        Set-ControlsEnabled $true
    }
})
$reloadButton.Add_Click({
    try{Load-Environments;$statusLabel.Text='环境列表已刷新';$statusLabel.ForeColor=[Drawing.Color]::FromArgb(92,102,110)}
    catch{[Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'PUC Toolkit','OK','Error')|Out-Null}
})
$clearButton.Add_Click({Clear-PucResultView;$statusLabel.Text='就绪';$statusLabel.ForeColor=[Drawing.Color]::FromArgb(92,102,110)})
$confirmButton.Add_Click({Confirm-PendingPreview})
$cancelConfirmationButton.Add_Click({Cancel-PendingPreview})
$runButton.Add_Click({
    $startedAt=[datetime]::Now
    try{
        if($null -eq $environmentBox.SelectedItem){throw '请选择环境。'}
        Set-ControlsEnabled $false;Clear-PucResultView;$statusLabel.Text='正在准备...';$statusLabel.ForeColor=[Drawing.Color]::FromArgb(92,102,110)
        Start-RequestedWorkflow
    }catch{
        $failedEnvironment=if($null-ne$environmentBox.SelectedItem){[string]$environmentBox.SelectedItem.Name}else{''}
        $failedOperation=if($null-ne$operationBox.SelectedItem){[string]$operationBox.SelectedItem.Label}else{'执行操作'}
        $failedStage=if($null-ne$script:ExecutionState){Get-PucStageDisplayLabel ([string]$script:ExecutionState.Stage)}else{'参数校验'}
        Remove-ExecutionTempFiles;$script:ExecutionState=$null;Set-ControlsEnabled $true
        Show-PucStandaloneResult -OperationLabel $failedOperation -Environment $failedEnvironment -Stage $failedStage -Outputs @($_.Exception.Message) -StartedAt $startedAt -ViewState Finished -ExitCode 1
        $statusLabel.Text='参数校验失败';$statusLabel.ForeColor=[Drawing.Color]::FromArgb(184,70,45)
        [Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'PUC Toolkit','OK','Warning')|Out-Null
    }
})

$form.Add_FormClosing({
    param($sender,$eventArgs)
    if($null -ne $script:ExecutionState){
        $eventArgs.Cancel=$true
        [Windows.Forms.MessageBox]::Show($form,'PUC 操作仍在运行，请等待完成后再关闭。','PUC Toolkit','OK','Information')|Out-Null
    }
})

if ($UiSelfTest) {
    try {
        $confirmationOutputs = [Collections.Generic.List[string]]::new()
        $confirmationOutputs.Add('{"status":"preview","accounts":[{"account":"mhw1"},{"account":"mhw2"}]}')
        $script:ExecutionState = [pscustomobject]@{
            Environment='10.161.30.163';Operation='reset-query';Stage='batch-reset-preview';Handle=$null;PendingConfirmation=$null
            StartedAt=[datetime]::Now.AddSeconds(-2);Outputs=$confirmationOutputs;TempPaths=[Collections.Generic.List[string]]::new();Data=@{}
        }
        Request-PreviewConfirmation -Prompt '请查看完整账号列表，确认是否执行。' -NextStage 'batch-reset-live' -Arguments @('Test.ps1','-Live') -CancelText '用户已取消测试。'
        if ($null -eq $script:ExecutionState.PendingConfirmation) { throw '内嵌确认状态未建立。' }
        if ($script:ExecutionState.PendingConfirmation.NextStage -ne 'batch-reset-live') { throw '内嵌确认后续阶段不正确。' }
        if ($runButton.Visible -or -not $confirmButton.Enabled -or -not $cancelConfirmationButton.Enabled) { throw '内嵌确认按钮状态不正确。' }
        if ($resultTabs.SelectedTab -ne $resultTab) { throw '等待确认时未自动显示执行结果列表。' }
        Cancel-PendingPreview
        if ($null -ne $script:ExecutionState -or $resultStatusTitle.Text -notmatch '已取消') { throw '内嵌确认取消流程不正确。' }

        $uiModel = New-PucResultModel -Outputs @('{"status":"partial-failure","environment":"10.161.30.163","succeeded":1,"failed":1,"results":[{"account":"mhw19001","status":"password-reset","stage1Result":0,"stage2Result":0,"writesUsed":2,"finalPasswordStatus":"configured"},{"account":"mhw19002","status":"failed","stage1Result":0,"stage2Result":1,"writesUsed":1,"reason":"request failed"}],"token":"UI-SECRET"}') -OperationLabel '批量重置密码' -Environment '10.161.30.163' -Stage '批量重置密码' -StartedAt ([datetime]::Now.AddSeconds(-3)) -ViewState Finished -ExitCode 1
        Show-PucResultModel $uiModel
        if ($resultTabs.TabPages.Count -ne 3) { throw '结果标签页数量不正确。' }
        if ($versionLabel.Parent -ne $selectionPanel -or $versionLabel.Text -notmatch '^版本：') { throw '环境版本显示控件不正确。' }
        if ($versionCompatibilityWarningLabel.Parent -ne $selectionPanel -or $versionCompatibilityWarningLabel.Text -ne '不同版本号上表现可能存在差异' -or $versionCompatibilityWarningLabel.ForeColor.R -lt 150) { throw '版本兼容性提示控件不正确。' }
        if ($versionLabel.Bounds.IntersectsWith($versionCompatibilityWarningLabel.Bounds)) { throw '版本号与兼容性提示发生重叠。' }
        if ([Windows.Forms.TextRenderer]::MeasureText($versionCompatibilityWarningLabel.Text,$versionCompatibilityWarningLabel.Font).Width -gt $versionCompatibilityWarningLabel.ClientSize.Width) { throw '版本兼容性提示文本显示不完整。' }
        if ($summaryTab.Text -ne '执行摘要' -or $resultTab.Text -ne '执行结果' -or $detailsTab.Text -ne '详细输出') { throw '结果标签页中文标题不正确。' }
        if ($resultGrid.Parent -ne $resultTab -or $resultLayout.RowCount -ne 2) { throw '摘要和结果未使用独立标签页布局。' }
        if ($resultFields.Items.Count -lt 3) { throw '结果摘要字段未渲染。' }
        if ($resultGrid.Rows.Count -ne 2) { throw '批量结果表格未渲染完整。' }
        if ($resultGrid.Columns.Contains('group')) { throw '单一来源批量结果不应显示冗余分类列。' }
        if (-not $resultGrid.Columns.Contains('account') -or $resultGrid.Columns['account'].MinimumWidth -lt 140) { throw '账号列宽度不足。' }
        foreach ($compactName in @('stage1Result','stage2Result','writesUsed')) {
            if (-not $resultGrid.Columns.Contains($compactName) -or $resultGrid.Columns[$compactName].Width -gt 60) { throw "紧凑数值列宽度不正确：$compactName" }
        }
        if ($resultGrid.Columns['stage1Result'].HeaderText -ne '阶段 1 结果' -or $resultGrid.Columns['writesUsed'].HeaderText -ne '写入次数') { throw '结果列中文标题不正确。' }
        if ($detailsBox.Text -match 'UI-SECRET') { throw '详细输出包含未脱敏字段。' }
        if ($resultTabs.Height -lt 300 -or $resultLayout.RowStyles[1].SizeType -ne [Windows.Forms.SizeType]::Percent) { throw '执行摘要区域未使用完整可用高度。' }
        [pscustomobject]@{status='ui-self-test-passed';tabs=$resultTabs.TabPages.Count;summaryFields=$resultFields.Items.Count;detailRows=$resultGrid.Rows.Count;resultHeight=$resultTabs.Height;environmentVersionControl='passed';versionCompatibilityWarning='passed';summaryFullHeight='passed';latestStageRows='passed';compactNumericColumns='passed';accountColumnWidth='passed';inlineConfirmation='passed';redundantGroupColumn='hidden'} | ConvertTo-Json -Compress
    } finally {
        $timer.Stop();$timer.Dispose();$form.Dispose()
    }
    return
}

try{
    Load-Environments
    Rebuild-Inputs
    Clear-PucResultView
    [void]$form.ShowDialog()
}catch{
    [Windows.Forms.MessageBox]::Show($_.Exception.Message,'PUC Toolkit','OK','Error')|Out-Null
}finally{
    $timer.Stop();$timer.Dispose();$form.Dispose()
}
