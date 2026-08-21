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
$forceUpgradeOptions = @(
    [pscustomobject]@{Label='否';Value=$false},
    [pscustomobject]@{Label='是';Value=$true}
)
$personnelTypeOptions = @(
    [pscustomobject]@{Label='人员';Value='102'},
    [pscustomobject]@{Label='车';Value='103'},
    [pscustomobject]@{Label='应急车';Value='104'}
)

function New-PucExecutionNode([string]$Label, [string[]]$Stages) {
    [pscustomobject]@{Label=$Label;Stages=@($Stages);Status='pending'}
}

function Get-PucExecutionNodeDefinitions([string]$Operation, [string]$Action = '') {
    switch ($Operation) {
        'android-upgrade' {
            return @(
                (New-PucExecutionNode '解析 APK' @('android-upgrade-inspect')),
                (New-PucExecutionNode '检查升级包' @('android-upgrade-preview')),
                (New-PucExecutionNode '制作升级包' @('android-upgrade-build'))
            )
        }
        'create' { return @((New-PucExecutionNode '新增调度账号' @('create-live','create-large-live'))) }
        'reset' { return @((New-PucExecutionNode '密码重置预检' @('reset-preview')),(New-PucExecutionNode '重置密码' @('reset-live'))) }
        {$_ -in @('reset-query','reset-file')} { return @((New-PucExecutionNode '批量重置预检' @('batch-reset-preview')),(New-PucExecutionNode '批量重置密码' @('batch-reset-live'))) }
        'complete' { return @((New-PucExecutionNode '账号补全预检' @('completion-preview')),(New-PucExecutionNode '补全账号信息' @('completion-live'))) }
        'update' { return @((New-PucExecutionNode '检查变更文件' @('update-plan')),(New-PucExecutionNode '账号更新预检' @('update-preview')),(New-PucExecutionNode '更新账号' @('update-live'))) }
        {$_ -in @('personnel-prefix','personnel-exact')} { return @((New-PucExecutionNode '人员新增预检' @('personnel-preview')),(New-PucExecutionNode '新增人员' @('personnel-live'))) }
        'role' { return @((New-PucExecutionNode '角色新增预检' @('role-preview')),(New-PucExecutionNode '新增角色' @('role-live'))) }
        'policy' {
            if ($Action -eq 'Status') { return @((New-PucExecutionNode '查询首次登录策略' @('policy-status'))) }
            return @((New-PucExecutionNode '首次登录策略预检' @('policy-preview')),(New-PucExecutionNode '更新首次登录策略' @('policy-live')))
        }
        'force-login' {
            if ($Action -eq 'Status') { return @((New-PucExecutionNode '查询重复登录策略' @('force-status'))) }
            return @((New-PucExecutionNode '重复登录策略预检' @('force-preview')),(New-PucExecutionNode '更新重复登录策略' @('force-live')))
        }
        'config-export' { return @((New-PucExecutionNode '导出配置和 License' @('config-export'))) }
        'config-import' { return @((New-PucExecutionNode '检查配置文件' @('config-import-plan')),(New-PucExecutionNode '导入配置' @('config-import-live'))) }
        'license-export' { return @((New-PucExecutionNode '导出 License' @('license-export'))) }
        'license-import' { return @((New-PucExecutionNode '检查 License 文件' @('license-import-plan')),(New-PucExecutionNode 'License 导入预检' @('license-import-preview')),(New-PucExecutionNode '导入 License' @('license-import-live'))) }
        'permission-import' { return @((New-PucExecutionNode '检查权限菜单' @('permission-import-plan')),(New-PucExecutionNode '导入权限菜单' @('permission-import-live'))) }
        'incident-levels' { return @((New-PucExecutionNode '警情等级预检' @('incident-preview')),(New-PucExecutionNode '配置警情等级' @('incident-live'))) }
        default { return @() }
    }
}

function Get-PucExecutionNodeForStage($Nodes, [string]$Stage) {
    return @($Nodes | Where-Object { $Stage -in @($_.Stages) } | Select-Object -First 1)
}

function Set-PucPendingExecutionNodesSkipped($State) {
    if ($null -eq $State) { return }
    foreach ($node in @($State.ExecutionNodes)) {
        if ([string]$node.Status -eq 'pending') { $node.Status = 'skipped' }
    }
}

$script:Operations = @(
    [pscustomobject]@{Key='create';Label='新增调度账号';Fields=@(
        (New-Field 'prefix' '账号前缀' 'Text' ''),
        (New-Field 'count' '创建数量' 'Number' 1)
    )},
    [pscustomobject]@{Key='reset';Label='重置单个账号密码';Fields=@(
        (New-Field 'account' '调度账号（输入关键字搜索）' 'SearchCombo')
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
        (New-Field 'account' '调度账号（输入关键字搜索）' 'SearchCombo'),
        (New-Field 'changesPath' '变更 JSON' 'File' '' @() 'JSON 文件 (*.json)|*.json')
    )},
    [pscustomobject]@{Key='personnel-prefix';Label='批量新增通讯录人员';Fields=@(
        (New-Field 'aliasValue' '人员别名前缀' 'Text'),
        (New-Field 'startSequence' '起始序号' 'Number' 0),
        (New-Field 'count' '创建数量' 'Number' 1),
        (New-Field 'numberType' '类型' 'Combo' '102' $personnelTypeOptions),
        (New-Field 'dispatcherAccount' '关联调度账号（输入关键字搜索，可选）' 'SearchCombo'),
        (New-Field 'rootOrganizationName' '根组织名称（可选）' 'Text')
    )},
    [pscustomobject]@{Key='personnel-exact';Label='新增指定通讯录人员';Fields=@(
        (New-Field 'aliasValue' '人员别名' 'Text'),
        (New-Field 'numberType' '类型' 'Combo' '102' $personnelTypeOptions),
        (New-Field 'dispatcherAccount' '关联调度账号（输入关键字搜索，可选）' 'SearchCombo'),
        (New-Field 'rootOrganizationName' '根组织名称（可选）' 'Text')
    )},
    [pscustomobject]@{Key='role';Label='新增角色';Fields=@(
        (New-Field 'roleAlias' '角色名称' 'Text')
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
    [pscustomobject]@{Key='incident-levels';Label='配置警情等级';Fields=@()},
    [pscustomobject]@{Key='android-upgrade';Label='制作 Android 升级包';Fields=@(
        (New-Field 'apkPath' 'APK 文件' 'File' '' @() 'APK 文件 (*.apk)|*.apk'),
        (New-Field 'description' '升级说明' 'Multiline'),
        (New-Field 'force' '强制升级' 'Radio' $false $forceUpgradeOptions)
    )}
)
$script:ShowEnvironmentPasswordsByDefault = $true
$script:DefaultNewAccountPassword = '888'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'PucTaskbarIdentity.cs')
$script:PucAppUserModelId = 'lizewencn.PucToolkit'
[PucTaskbarIdentity]::SetProcessIdentity($script:PucAppUserModelId)
[Windows.Forms.Application]::EnableVisualStyles()
Import-Module (Join-Path $PSScriptRoot 'PucResultRenderer.psm1') -Force

function Set-PucButtonStyle($Button, [ValidateSet('Primary','Secondary','Info','Upload','Soft','Utility','OutlineInfo','OutlineTheme','OutlineWarning')][string]$Kind = 'Secondary') {
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
    } elseif ($Kind -eq 'Info') {
        $normalBackColor = [Drawing.Color]::FromArgb(37,99,235)
        $normalForeColor = [Drawing.Color]::White
        $Button.FlatAppearance.BorderSize = 0
        $Button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(29,78,216)
        $Button.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(30,64,175)
    } elseif ($Kind -eq 'Upload') {
        $normalBackColor = [Drawing.Color]::FromArgb(79,70,229)
        $normalForeColor = [Drawing.Color]::White
        $Button.FlatAppearance.BorderSize = 0
        $Button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(67,56,202)
        $Button.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(55,48,163)
    } elseif ($Kind -eq 'Utility') {
        $normalBackColor = [Drawing.Color]::FromArgb(241,245,249)
        $normalForeColor = [Drawing.Color]::FromArgb(51,65,85)
        $Button.FlatAppearance.BorderSize = 1
        $Button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(203,213,225)
        $Button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(226,232,240)
        $Button.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(203,213,225)
    } elseif ($Kind -eq 'OutlineInfo') {
        $normalBackColor = [Drawing.Color]::White
        $normalForeColor = [Drawing.Color]::FromArgb(29,78,216)
        $Button.FlatAppearance.BorderSize = 1
        $Button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(147,197,253)
        $Button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(239,246,255)
        $Button.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(219,234,254)
    } elseif ($Kind -eq 'OutlineTheme') {
        $normalBackColor = [Drawing.Color]::White
        $normalForeColor = [Drawing.Color]::FromArgb(0,105,99)
        $Button.FlatAppearance.BorderSize = 1
        $Button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(134,203,196)
        $Button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(240,250,249)
        $Button.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(214,234,232)
    } elseif ($Kind -eq 'OutlineWarning') {
        $normalBackColor = [Drawing.Color]::White
        $normalForeColor = [Drawing.Color]::FromArgb(194,95,20)
        $Button.FlatAppearance.BorderSize = 1
        $Button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(229,161,93)
        $Button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(255,247,237)
        $Button.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(255,237,213)
    } elseif ($Kind -eq 'Soft') {
        $normalBackColor = [Drawing.Color]::FromArgb(224,247,245)
        $normalForeColor = [Drawing.Color]::FromArgb(0,105,99)
        $Button.FlatAppearance.BorderSize = 1
        $Button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(134,203,196)
        $Button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(204,239,235)
        $Button.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(183,228,222)
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

function Set-PucUpdateIconStyle($Button) {
    $Button.AutoSize = $false
    $Button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize = 0
    $Button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(240,250,249)
    $Button.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(214,234,232)
    $Button.UseVisualStyleBackColor = $false
    $Button.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
    $Button.Padding = New-Object Windows.Forms.Padding(0)
    $Button.Font = New-Object Drawing.Font('Segoe MDL2 Assets',14)
    $updateEnabledStyle = {
        $Button.BackColor = [Drawing.Color]::White
        if ($Button.Enabled) {
            $Button.ForeColor = [Drawing.Color]::FromArgb(0,105,99)
            $Button.Cursor = [Windows.Forms.Cursors]::Hand
        } else {
            $Button.ForeColor = [Drawing.Color]::FromArgb(153,162,169)
            $Button.Cursor = [Windows.Forms.Cursors]::Default
        }
    }.GetNewClosure()
    $Button.Add_EnabledChanged($updateEnabledStyle)
    & $updateEnabledStyle
}

function Get-PucSkillUpdateDisplayText {
    $prefix = '上次更新：'
    $statePath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'puc-config\update-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return ($prefix + '暂无记录') }
    try {
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        $entry = $state.repository
        if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.updatedAt)) { $entry = $state.skills.'puc-config' }
        if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.updatedAt)) { return ($prefix + '暂无记录') }
        $updatedAt = [DateTimeOffset]::Parse([string]$entry.updatedAt).ToLocalTime()
        return ($prefix + $updatedAt.ToString('yyyy-MM-dd HH:mm:ss'))
    } catch { return ($prefix + '暂无记录') }
}

if ($SelfTest) {
    if ($script:Operations.Count -ne 18) { throw '操作目录数量不正确。' }
    if (-not $script:ShowEnvironmentPasswordsByDefault) { throw '新增环境的显示密码选项必须默认勾选。' }
    if ($script:DefaultNewAccountPassword -ne '888') { throw '新账号及重置默认密码必须默认为 888。' }
    Assert-NewEnvironmentPasswords -AdminPassword 'admin-test-password' -NewAccountPassword $script:DefaultNewAccountPassword
    $emptyNewAccountPasswordRejected = $false
    try { Assert-NewEnvironmentPasswords -AdminPassword 'admin-test-password' -NewAccountPassword '' } catch { $emptyNewAccountPasswordRejected = $_.Exception.Message -eq '新账号及重置默认密码不能为空。' }
    if (-not $emptyNewAccountPasswordRejected) { throw '新增环境未拒绝空的新账号及重置默认密码。' }
    $keys = @($script:Operations.Key | Sort-Object -Unique)
    if ($keys.Count -ne $script:Operations.Count) { throw '操作目录中存在重复键。' }
    $expectedKeys = @('create','reset','reset-query','reset-file','complete','update','personnel-prefix','personnel-exact','role','policy','force-login','config-export','config-import','license-export','license-import','permission-import','incident-levels','android-upgrade')
    foreach ($key in $expectedKeys) { if ($key -notin $keys) { throw "操作目录缺少 $key。" } }
    foreach ($key in $expectedKeys) {
        $action = if ($key -in @('policy','force-login')) {'Status'} else {''}
        if (@(Get-PucExecutionNodeDefinitions -Operation $key -Action $action).Count -lt 1) { throw "操作 $key 未定义执行节点。" }
    }
    if (@(Get-PucExecutionNodeDefinitions -Operation 'update').Count -ne 3 -or @(Get-PucExecutionNodeDefinitions -Operation 'policy' -Action 'Enable').Count -ne 2) { throw '多阶段操作的执行节点定义不正确。' }
    $upgradeOperation = $script:Operations | Where-Object Key -eq 'android-upgrade'
    $upgradeKinds = @{}
    foreach ($field in @($upgradeOperation.Fields)) { $upgradeKinds[[string]$field.Key] = [string]$field.Kind }
    if ($upgradeKinds.apkPath -ne 'File' -or $upgradeKinds.description -ne 'Multiline' -or $upgradeKinds.force -ne 'Radio' -or $upgradeKinds.ContainsKey('outputDirectory')) { throw 'Android 升级包操作字段定义不正确。' }
    if ([bool](@($upgradeOperation.Fields | Where-Object Key -eq 'force')[0].Default)) { throw '强制升级必须默认选择否。' }
    if (@($script:Operations | Where-Object Key -eq 'create').Fields.Key -contains 'startSequence') {
        throw '调度账号创建不得询问起始序号。'
    }
    $createOperation = @($script:Operations | Where-Object Key -eq 'create')[0]
    $createPrefixField = @($createOperation.Fields | Where-Object Key -eq 'prefix')[0]
    $createCountField = @($createOperation.Fields | Where-Object Key -eq 'count')[0]
    if (-not [string]::IsNullOrEmpty([string]$createPrefixField.Default)) { throw '新增调度账号的账号前缀不得设置默认值。' }
    if ([int]$createCountField.Default -ne 1) { throw '新增调度账号的创建数量必须默认为 1。' }
    foreach ($personnelOperation in @($script:Operations | Where-Object Key -in @('personnel-prefix','personnel-exact'))) {
        $typeField = @($personnelOperation.Fields | Where-Object Key -eq 'numberType')
        $dispatcherField = @($personnelOperation.Fields | Where-Object Key -eq 'dispatcherAccount')
        if ($typeField.Count -ne 1 -or $typeField[0].Kind -ne 'Combo' -or (@($typeField[0].Options.Value) -join ',') -ne '102,103,104') { throw '人员类型下拉字段定义不正确。' }
        if ($dispatcherField.Count -ne 1 -or $dispatcherField[0].Kind -ne 'SearchCombo') { throw '调度员模糊搜索字段定义不正确。' }
    }
    $updateAccountField = @(@($script:Operations | Where-Object Key -eq 'update')[0].Fields | Where-Object Key -eq 'account')
    if ($updateAccountField.Count -ne 1 -or $updateAccountField[0].Kind -ne 'SearchCombo') { throw '更新账号信息的调度账号模糊搜索字段定义不正确。' }
    $resetAccountField = @(@($script:Operations | Where-Object Key -eq 'reset')[0].Fields | Where-Object Key -eq 'account')
    if ($resetAccountField.Count -ne 1 -or $resetAccountField[0].Kind -ne 'SearchCombo') { throw '重置单个账号密码的调度账号模糊搜索字段定义不正确。' }
    $environmentUri = ConvertTo-PucBaseUrlFromIp '10.161.30.163'
    if ($environmentUri.AbsoluteUri -ne 'https://10.161.30.163:16890/') { throw '服务 IP 默认地址拼接失败。' }
    $fullUrlRejected = $false
    try { [void](ConvertTo-PucBaseUrlFromIp 'https://10.161.30.163:16890') } catch { $fullUrlRejected = $true }
    if (-not $fullUrlRejected) { throw '新增环境不得接受包含协议或端口的服务地址。' }
    $workflowScripts = @('Initialize-PucConfig.ps1','Repair-PucEnvironmentNames.ps1','Get-PucEnvironmentVersion.ps1','Invoke-PucAccounts.ps1','Invoke-PucAccountPasswordReset.ps1','Invoke-PucAccountPasswordResetBatch.ps1','Invoke-PucAccountCompletion.ps1','Invoke-PucAccountUpdate.ps1','Invoke-PucPersonnel.ps1','Invoke-PucRole.ps1','Invoke-PucSkillUpdate.ps1','Invoke-PucDispatcherSearch.ps1','Invoke-PucFirstLoginPasswordCheck.ps1','Invoke-PucForceLogin.ps1','Invoke-PucConfigTransfer.ps1','Invoke-PucLicense.ps1','Invoke-PucPermissionMenuImport.ps1','Invoke-PucIncidentAlarmLevels.ps1','Invoke-AndroidUpgradePackage.ps1','PucResultRenderer.psm1')
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
    $latestSkillModel = New-PucResultModel -Outputs @('{"status":"latest","scope":"repository","localCommit":"fc4f71c","remoteCommit":"fc4f71c","packageCount":5,"packageNames":["puc-config","get-business-log"],"updated":false}') -OperationLabel '更新版本包' -Environment '' -Stage '检查版本' -StartedAt $resultStartedAt -ViewState Finished -ExitCode 0
    if ($latestSkillModel.Kind -ne 'Success' -or $latestSkillModel.StatusText -ne '已是最新版本' -or @($latestSkillModel.Fields | Where-Object { $_.Name -eq 'message' -and $_.Value -eq '仓库下全部版本包已是最新版本，无需更新。' }).Count -ne 1) { throw '最新版本友好提示渲染失败。' }
    $partialModel = New-PucResultModel -Outputs @('{"status":"partial-failure","environment":"10.161.30.163","succeeded":1,"failed":1,"results":[{"account":"mhw1","status":"password-reset"},{"account":"mhw2","status":"failed","reason":"request failed"}]}') -OperationLabel '批量重置密码' -Environment '10.161.30.163' -Stage 'batch-reset-live' -StartedAt $resultStartedAt -ViewState Finished -ExitCode 1
    if ($partialModel.Kind -ne 'Warning' -or @($partialModel.Rows).Count -ne 2) { throw '部分失败结果表格验证失败。' }
    $noMatchModel = New-PucResultModel -Outputs @('{"status":"no-match","query":"missing","accountCount":0,"accounts":[],"message":"未查询到匹配的调度账号，请调整查询关键字后重试。"}') -OperationLabel '批量重置密码（按查询）' -Environment '10.161.30.163' -Stage 'batch-reset-preview' -StartedAt $resultStartedAt -ViewState Finished -ExitCode 0
    if ($noMatchModel.Kind -ne 'Neutral' -or $noMatchModel.StatusText -ne '查询结果为空' -or @($noMatchModel.Fields | Where-Object { $_.Name -eq 'message' -and $_.Value -match '未查询到匹配的调度账号' }).Count -ne 1) { throw '空查询结果友好提示渲染失败。' }
    $stageModel = New-PucResultModel -Outputs @('{"status":"previewed","accounts":[{"account":"mhw1"},{"account":"mhw2"}]}','{"status":"password-reset","results":[{"account":"mhw1","status":"password-reset"},{"account":"mhw2","status":"password-reset"}]}') -OperationLabel '批量重置密码' -Environment '10.161.30.163' -Stage 'batch-reset-live' -StartedAt $resultStartedAt -ViewState Finished -ExitCode 0
    if (@($stageModel.Rows).Count -ne 2 -or @($stageModel.Rows | Where-Object group -eq '账号').Count -ne 0) { throw '执行结果不得混合预检与最终阶段数据。' }
    $nodeModel = New-PucResultModel -Outputs @('{"status":"previewed","results":[{"alias":"test","status":"planned"}]}') -OperationLabel '新增人员' -Environment '10.161.30.163' -ExecutionNodes @([pscustomobject]@{Label='人员新增预检';Status='completed'},[pscustomobject]@{Label='新增人员';Status='running'}) -StartedAt $resultStartedAt -ViewState Progress
    if (@($nodeModel.Fields | Where-Object Name -like 'executionNode*').Count -ne 2 -or [string]$nodeModel.Fields[2].Label -ne '1.') { throw '编号执行节点摘要渲染失败。' }
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

function Initialize-PucLauncherConfigRoot {
    param(
        [string]$SettingsPath = (Get-PucSettingsPath),
        [string]$DefaultRoot = (Get-PucDefaultConfigRoot)
    )
    $settingsPath = [IO.Path]::GetFullPath($SettingsPath)
    $defaultRoot = [IO.Path]::GetFullPath($DefaultRoot)
    $configuredRoot = ''
    try {
        $settings = Read-PucJson -Path $settingsPath -Default $null
        if ($null -ne $settings -and -not [string]::IsNullOrWhiteSpace([string]$settings.configRoot)) {
            $candidate = [string]$settings.configRoot
            if ([IO.Path]::IsPathRooted($candidate)) { $configuredRoot = [IO.Path]::GetFullPath($candidate) }
        }
    } catch { $configuredRoot = '' }

    if (-not [string]::IsNullOrWhiteSpace($configuredRoot) -and (Test-Path -LiteralPath $configuredRoot -PathType Container)) {
        return [pscustomobject]@{ConfigRoot=$configuredRoot;Initialized=$false;SettingsPath=$settingsPath}
    }

    New-Item -ItemType Directory -Force -Path $defaultRoot | Out-Null
    Write-PucJson -Path $settingsPath -Value ([ordered]@{configRoot=[IO.Path]::GetFullPath($defaultRoot)})
    return [pscustomobject]@{ConfigRoot=[IO.Path]::GetFullPath($defaultRoot);Initialized=$true;SettingsPath=$settingsPath}
}

function Assert-PucLauncherConfigDocument($Document, [string]$Path) {
    if ($null -eq $Document -or $null -eq $Document.PSObject.Properties['environments']) {
        throw "配置文件缺少 environments 结构：$Path"
    }
}

function Resolve-PucLauncherConfigRootFromSelection([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) { throw '配置存放位置必须是绝对路径。' }
    $selectedPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $selectedLeaf = Split-Path -Leaf $selectedPath
    $selectedParent = Split-Path -Parent $selectedPath
    if ($selectedLeaf -ieq 'puc-config' -and (Split-Path -Leaf $selectedParent) -ieq 'agentSkillLocalConfig') { return $selectedPath }
    if ($selectedLeaf -ieq 'agentSkillLocalConfig') { return Join-Path $selectedPath 'puc-config' }
    return Join-Path (Join-Path $selectedPath 'agentSkillLocalConfig') 'puc-config'
}

function Get-PucLauncherStorageSelectionPath([string]$ConfigRoot) {
    if ([string]::IsNullOrWhiteSpace($ConfigRoot)) { return Get-PucDefaultConfigRoot | Split-Path -Parent | Split-Path -Parent }
    $resolvedRoot = [IO.Path]::GetFullPath($ConfigRoot).TrimEnd('\')
    $parent = Split-Path -Parent $resolvedRoot
    if ((Split-Path -Leaf $resolvedRoot) -ieq 'puc-config' -and (Split-Path -Leaf $parent) -ieq 'agentSkillLocalConfig') {
        return Split-Path -Parent $parent
    }
    return Split-Path -Parent $resolvedRoot
}

function Get-PucLauncherConfigPathActionText([string]$Action) {
    $actionText = switch ($Action) {
        'moved' {'配置目录及全部内容已迁移'}
        'moved-initialized' {'配置目录及全部内容已迁移，并已初始化配置文件'}
        'initialized' {'已在新路径初始化配置文件'}
        'selected-existing' {'已切换到目标路径中的配置文件'}
        default {'配置路径未变化'}
    }
    return [string]$actionText
}

function Get-PucLauncherConfigPathResultJson([string]$Action, [string]$ConfigRoot) {
    $resolvedRoot = [IO.Path]::GetFullPath($ConfigRoot)
    $actionText = Get-PucLauncherConfigPathActionText $Action
    return ([ordered]@{
        status='updated'
        message='配置路径设置成功'
        operationResult=$actionText
        configRoot=$resolvedRoot
    } | ConvertTo-Json -Compress)
}

function Set-PucLauncherConfigRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$CurrentRoot = '',
        [string]$SettingsPath = (Get-PucSettingsPath),
        [string]$TemplatePath = (Join-Path $PSScriptRoot '..\assets\config.template.json')
    )
    $selectedRoot = Resolve-PucLauncherConfigRootFromSelection -Path $Path
    if ([string]::IsNullOrWhiteSpace($CurrentRoot)) {
        try { $CurrentRoot = Get-PucConfigRoot } catch { $CurrentRoot = '' }
    }
    $resolvedCurrentRoot = if ([string]::IsNullOrWhiteSpace($CurrentRoot)) {''} else {[IO.Path]::GetFullPath($CurrentRoot)}
    $resolvedSettingsPath = [IO.Path]::GetFullPath($SettingsPath)
    $resolvedTemplatePath = [IO.Path]::GetFullPath($TemplatePath)
    $sourceConfigPath = if ([string]::IsNullOrWhiteSpace($resolvedCurrentRoot)) {''} else {Join-Path $resolvedCurrentRoot 'config.json'}
    $targetConfigPath = Join-Path $selectedRoot 'config.json'
    $sameRoot = -not [string]::IsNullOrWhiteSpace($resolvedCurrentRoot) -and [string]::Equals($resolvedCurrentRoot.TrimEnd('\'),$selectedRoot.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)
    $sourceRootExists = -not [string]::IsNullOrWhiteSpace($resolvedCurrentRoot) -and (Test-Path -LiteralPath $resolvedCurrentRoot -PathType Container)
    $sourceConfigExists = $sourceRootExists -and (Test-Path -LiteralPath $sourceConfigPath -PathType Leaf)
    $targetRootExists = Test-Path -LiteralPath $selectedRoot -PathType Container
    $targetConfigExists = Test-Path -LiteralPath $targetConfigPath -PathType Leaf
    $movedRoot = $false
    $initializedConfig = $false
    $createdTargetRoot = $false
    $targetWasEmpty = $false
    $action = 'unchanged'
    try {
        if ($sourceConfigExists) {
            $sourceDocument = Read-PucJson -Path $sourceConfigPath -Default $null
            Assert-PucLauncherConfigDocument -Document $sourceDocument -Path $sourceConfigPath
        }

        if ($sourceRootExists -and -not $sameRoot) {
            if ($targetRootExists) {
                $targetWasEmpty = @((Get-ChildItem -LiteralPath $selectedRoot -Force)).Count -eq 0
                if (-not $targetWasEmpty) { throw "目标配置目录已存在内容，未执行合并或覆盖：$selectedRoot" }
                Remove-Item -LiteralPath $selectedRoot -Force
            }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $selectedRoot) | Out-Null
            Move-Item -LiteralPath $resolvedCurrentRoot -Destination $selectedRoot
            $movedRoot = $true
            $targetRootExists = $true
            $targetConfigExists = Test-Path -LiteralPath $targetConfigPath -PathType Leaf
            $action = 'moved'
        } elseif (-not $targetRootExists) {
            New-Item -ItemType Directory -Force -Path $selectedRoot | Out-Null
            $createdTargetRoot = $true
            $targetRootExists = $true
        }

        if ($targetConfigExists) {
            $targetDocument = Read-PucJson -Path $targetConfigPath -Default $null
            Assert-PucLauncherConfigDocument -Document $targetDocument -Path $targetConfigPath
            if (-not $movedRoot -and -not $sameRoot) { $action = 'selected-existing' }
        } else {
            if (-not (Test-Path -LiteralPath $resolvedTemplatePath -PathType Leaf)) { throw "配置模板不存在：$resolvedTemplatePath" }
            $template = Read-PucJson -Path $resolvedTemplatePath -Default $null
            Assert-PucLauncherConfigDocument -Document $template -Path $resolvedTemplatePath
            Write-PucJson -Path $targetConfigPath -Value $template
            $initializedConfig = $true
            $action = if ($movedRoot) {'moved-initialized'} else {'initialized'}
        }
        Write-PucJson -Path $resolvedSettingsPath -Value ([ordered]@{configRoot=$selectedRoot})
        if ($movedRoot) {
            $oldStructureParent = Split-Path -Parent $resolvedCurrentRoot
            if ((Split-Path -Leaf $oldStructureParent) -ieq 'agentSkillLocalConfig' -and (Test-Path -LiteralPath $oldStructureParent -PathType Container) -and @((Get-ChildItem -LiteralPath $oldStructureParent -Force)).Count -eq 0) {
                Remove-Item -LiteralPath $oldStructureParent -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        $migrationError = $_.Exception.Message
        try {
            if ($movedRoot -and (Test-Path -LiteralPath $selectedRoot -PathType Container) -and -not (Test-Path -LiteralPath $resolvedCurrentRoot)) {
                if ($initializedConfig -and (Test-Path -LiteralPath $targetConfigPath -PathType Leaf)) { Remove-Item -LiteralPath $targetConfigPath -Force -ErrorAction Stop }
                Move-Item -LiteralPath $selectedRoot -Destination $resolvedCurrentRoot -ErrorAction Stop
                if ($targetWasEmpty) { New-Item -ItemType Directory -Force -Path $selectedRoot | Out-Null }
            } elseif ($createdTargetRoot -and (Test-Path -LiteralPath $selectedRoot -PathType Container)) {
                Remove-Item -LiteralPath $selectedRoot -Recurse -Force -ErrorAction Stop
            } elseif ($initializedConfig -and (Test-Path -LiteralPath $targetConfigPath -PathType Leaf)) {
                Remove-Item -LiteralPath $targetConfigPath -Force -ErrorAction Stop
            }
        } catch {
            throw "配置路径更新失败，且配置目录回滚失败。原始错误：$migrationError；回滚错误：$($_.Exception.Message)"
        }
        throw $migrationError
    }
    return [pscustomobject]@{ConfigRoot=$selectedRoot;ConfigPath=$targetConfigPath;StoragePath=(Get-PucLauncherStorageSelectionPath $selectedRoot);Action=$action;RestartRequired=$false}
}
$script:LauncherPath = Join-Path $PSScriptRoot 'Invoke-PucScript.cmd'
$script:ExecutionState = $null
$script:FieldControls = @{}
$script:VersionLookup = $null
$script:PendingVersionEnvironment = ''
$script:LastUpgradePackagePath = ''
$script:DispatcherLookup = $null
$script:UploadButtonRequestedVisible = $false

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
        'Multiline' { return $entry.Input.Text.Trim() }
        'File' { return $entry.Input.Text.Trim() }
        'Folder' { return $entry.Input.Text.Trim() }
        'Number' { return [int]$entry.Input.Value }
        'Check' { return [bool]$entry.Input.Checked }
        'Combo' { return [string]$entry.Input.SelectedItem.Value }
        'SearchCombo' {
            $text = $entry.Input.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($text)) { return '' }
            if ($null -eq $entry.Input.SelectedItem -or [string]$entry.Input.SelectedItem.Label -ne $text) {
                throw '请从调度账号搜索下拉列表中选择一个账号。'
            }
            return [string]$entry.Input.SelectedItem.Value
        }
        'Radio' {
            $selected = @($entry.Input.Controls | Where-Object { $_ -is [Windows.Forms.RadioButton] -and $_.Checked } | Select-Object -First 1)
            if ($selected.Count -eq 0) { return $false }
            return [bool]$selected[0].Tag
        }
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
$form.ClientSize = New-Object Drawing.Size(860,520)
$form.MinimumSize = New-Object Drawing.Size(876,600)
$form.BackColor = [Drawing.Color]::FromArgb(246,248,250)
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI',9)
$launcherIcon = $null
$launcherIconPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\assets\puc-config.ico'))
if (Test-Path -LiteralPath $launcherIconPath -PathType Leaf) {
    $sourceIcon = New-Object Drawing.Icon($launcherIconPath)
    try { $launcherIcon = [Drawing.Icon]$sourceIcon.Clone() } finally { $sourceIcon.Dispose() }
    $form.Icon = $launcherIcon
    $form.ShowIcon = $true
}
[void]$form.Handle
$taskbarIconResource = "$launcherIconPath,0"
[PucTaskbarIdentity]::ConfigureWindow($form.Handle,$script:PucAppUserModelId,$taskbarIconResource)

$header = New-Object Windows.Forms.Panel
$header.Location = New-Object Drawing.Point(0,0)
$header.Size = New-Object Drawing.Size(860,58)
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

$lastUpdateLabel = New-Object Windows.Forms.Label
$lastUpdateLabel.Text = Get-PucSkillUpdateDisplayText
$lastUpdateLabel.AutoSize = $false
$lastUpdateLabel.ForeColor = [Drawing.Color]::FromArgb(92,102,110)
$lastUpdateLabel.Location = New-Object Drawing.Point(486,17)
$lastUpdateLabel.Size = New-Object Drawing.Size(310,26)
$lastUpdateLabel.Anchor = 'Top,Right'
$lastUpdateLabel.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$header.Controls.Add($lastUpdateLabel)

$updateButton = New-Object Windows.Forms.Button
$updateButton.Text = [string][char]0xE896
$updateButton.AccessibleName = '更新版本包'
$updateButton.Location = New-Object Drawing.Point(808,11)
$updateButton.Size = New-Object Drawing.Size(38,38)
$updateButton.Anchor = 'Top,Right'
Set-PucUpdateIconStyle $updateButton
$header.Controls.Add($updateButton)

$headerToolTip = New-Object Windows.Forms.ToolTip
$headerToolTip.SetToolTip($updateButton,'更新版本包')

$accent = New-Object Windows.Forms.Panel
$accent.Location = New-Object Drawing.Point(0,55)
$accent.Size = New-Object Drawing.Size(860,3)
$accent.Anchor = 'Left,Right,Bottom'
$accent.BackColor = [Drawing.Color]::FromArgb(0,134,126)
$header.Controls.Add($accent)

$selectionPanel = New-Object Windows.Forms.Panel
$selectionPanel.Location = New-Object Drawing.Point(0,58)
$selectionPanel.Size = New-Object Drawing.Size(860,126)
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
$operationBox.Size = New-Object Drawing.Size(242,28)
$operationBox.DisplayMember = 'Label'
foreach ($operation in $script:Operations) { $operationBox.Items.Add($operation) | Out-Null }
$operationBox.SelectedIndex = 0
$selectionPanel.Controls.Add($operationBox)

$configPathButton = New-Object Windows.Forms.Button
$configPathButton.Text = '设置配置路径'
$configPathButton.AccessibleName = '设置配置文件路径'
$configPathButton.Location = New-Object Drawing.Point(504,35)
$configPathButton.Size = New-Object Drawing.Size(108,34)
Set-PucButtonStyle $configPathButton 'OutlineWarning'
$selectionPanel.Controls.Add($configPathButton)
$headerToolTip.SetToolTip($configPathButton,'设置配置文件路径')

$addEnvironmentButton = New-Object Windows.Forms.Button
$addEnvironmentButton.Text = '新增环境'
$addEnvironmentButton.Location = New-Object Drawing.Point(624,35)
$addEnvironmentButton.Size = New-Object Drawing.Size(96,34)
Set-PucButtonStyle $addEnvironmentButton 'OutlineInfo'
$selectionPanel.Controls.Add($addEnvironmentButton)

$reloadButton = New-Object Windows.Forms.Button
$reloadButton.Text = '刷新'
$reloadButton.Location = New-Object Drawing.Point(732,35)
$reloadButton.Size = New-Object Drawing.Size(100,34)
Set-PucButtonStyle $reloadButton 'OutlineTheme'
$selectionPanel.Controls.Add($reloadButton)

$addressLabel = New-Object Windows.Forms.Label
$addressLabel.AutoSize = $false
$addressLabel.ForeColor = [Drawing.Color]::FromArgb(92,102,110)
$addressLabel.Location = New-Object Drawing.Point(24,76)
$addressLabel.Size = New-Object Drawing.Size(206,22)
$addressLabel.AutoEllipsis = $true
$selectionPanel.Controls.Add($addressLabel)

$versionLabel = New-Object Windows.Forms.Label
$versionLabel.Text = '版本：未获取'
$versionLabel.AutoSize = $false
$versionLabel.ForeColor = [Drawing.Color]::FromArgb(92,102,110)
$versionLabel.Location = New-Object Drawing.Point(24,98)
$versionLabel.Size = New-Object Drawing.Size(184,22)
$versionLabel.AutoEllipsis = $true
$selectionPanel.Controls.Add($versionLabel)

$versionCompatibilityWarningLabel = New-Object Windows.Forms.Label
$versionCompatibilityWarningLabel.Text = '不同版本号上表现可能存在差异'
$versionCompatibilityWarningLabel.AutoSize = $false
$versionCompatibilityWarningLabel.ForeColor = [Drawing.Color]::FromArgb(192,57,43)
$versionCompatibilityWarningLabel.Location = New-Object Drawing.Point(216,98)
$versionCompatibilityWarningLabel.Size = New-Object Drawing.Size(190,22)
$versionCompatibilityWarningLabel.Anchor = 'Top,Left'
$versionCompatibilityWarningLabel.TextAlign = [Drawing.ContentAlignment]::TopLeft
$selectionPanel.Controls.Add($versionCompatibilityWarningLabel)

$versionToolTip = New-Object Windows.Forms.ToolTip

$inputPanel = New-Object Windows.Forms.Panel
$inputPanel.Location = New-Object Drawing.Point(16,184)
$inputPanel.Size = New-Object Drawing.Size(828,0)
$inputPanel.Anchor = 'Top,Left,Right'
$inputPanel.BackColor = [Drawing.Color]::White
$inputPanel.BorderStyle = [Windows.Forms.BorderStyle]::None
$inputPanelDoubleBufferedProperty = [Windows.Forms.Control].GetProperty('DoubleBuffered',[Reflection.BindingFlags]'Instance,NonPublic')
$inputPanelDoubleBufferedProperty.SetValue($inputPanel,$true,$null)
$inputPanel.Add_Paint({
    param($sender,$eventArgs)
    if ($sender.ClientSize.Width -le 1 -or $sender.ClientSize.Height -le 1) { return }
    $borderPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(218,224,228))
    try { $eventArgs.Graphics.DrawRectangle($borderPen,0,0,($sender.ClientSize.Width - 1),($sender.ClientSize.Height - 1)) } finally { $borderPen.Dispose() }
})
$form.Controls.Add($inputPanel)

$inputSectionAccent = New-Object Windows.Forms.Panel
$inputSectionAccent.Location = New-Object Drawing.Point(24,14)
$inputSectionAccent.Size = New-Object Drawing.Size(4,18)
$inputSectionAccent.BackColor = [Drawing.Color]::FromArgb(0,134,126)

$inputSectionLabel = New-Object Windows.Forms.Label
$inputSectionLabel.Text = '操作参数'
$inputSectionLabel.AutoSize = $true
$inputSectionLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI',10,[Drawing.FontStyle]::Bold)
$inputSectionLabel.ForeColor = [Drawing.Color]::FromArgb(28,58,62)
$inputSectionLabel.Location = New-Object Drawing.Point(36,13)

$actionPanel = New-Object Windows.Forms.Panel
$actionPanel.Location = New-Object Drawing.Point(0,184)
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

$uploadButton = New-Object Windows.Forms.Button
$uploadButton.Text = '上传'
$uploadButton.Location = New-Object Drawing.Point(272,14)
$uploadButton.Size = New-Object Drawing.Size(112,34)
$uploadButton.Enabled = $false
$uploadButton.Visible = $false
Set-PucButtonStyle $uploadButton 'Upload'
$actionPanel.Controls.Add($uploadButton)

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
$statusLabel.Anchor = 'Top,Left,Right'
$statusLabel.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
$statusLabel.AutoEllipsis = $true
$actionPanel.Controls.Add($statusLabel)

function Update-ActionPanelLayout {
    $showUpload = $null -ne $operationBox.SelectedItem -and [string]$operationBox.SelectedItem.Key -eq 'android-upgrade'
    $script:UploadButtonRequestedVisible = $showUpload
    $uploadButton.Visible = $showUpload
    $statusLeft = if ($showUpload) {396} else {282}
    $statusLabel.Left = $statusLeft
    $statusLabel.Width = [Math]::Max(120,$actionPanel.ClientSize.Width - $statusLeft - 28)
}

function Set-PucDispatcherSearchStatus([Windows.Forms.ComboBox]$Control, [ValidateSet('Idle','Loading','Found','Empty','Failed','Selected')][string]$State, [int]$Count = 0) {
    if ($null -eq $Control -or $Control.IsDisposed -or $Control.Tag -isnot [Windows.Forms.Label]) { return }
    $searchStatus = [Windows.Forms.Label]$Control.Tag
    switch ($State) {
        'Loading' { $searchStatus.Text = '查询中...'; $searchStatus.ForeColor = [Drawing.Color]::FromArgb(45,112,176) }
        'Found' { $searchStatus.Text = "找到 $Count 个账号"; $searchStatus.ForeColor = [Drawing.Color]::FromArgb(0,128,105) }
        'Empty' { $searchStatus.Text = '未找到匹配账号'; $searchStatus.ForeColor = [Drawing.Color]::FromArgb(92,102,110) }
        'Failed' { $searchStatus.Text = '查询失败'; $searchStatus.ForeColor = [Drawing.Color]::FromArgb(184,70,45) }
        'Selected' { $searchStatus.Text = '已选择'; $searchStatus.ForeColor = [Drawing.Color]::FromArgb(0,128,105) }
        default { $searchStatus.Text = ''; $searchStatus.ForeColor = [Drawing.Color]::FromArgb(92,102,110) }
    }
}

function Request-DispatcherLookup([Windows.Forms.ComboBox]$Control) {
    if ($null -ne $Control.SelectedItem -and [string]$Control.SelectedItem.Label -eq $Control.Text) {
        Set-PucDispatcherSearchStatus -Control $Control -State Selected
        return
    }
    $query = $Control.Text.Trim()
    if ($null -eq $script:DispatcherLookup) {
        $script:DispatcherLookup = [pscustomobject]@{Control=$Control;Query=$query;RequestedQuery='';RequestedEnvironment='';DueAt=[datetime]::Now.AddMilliseconds(400);StartedAt=[datetime]::Now;Handle=$null}
    } else {
        $script:DispatcherLookup.Control = $Control
        $script:DispatcherLookup.Query = $query
        $script:DispatcherLookup.DueAt = [datetime]::Now.AddMilliseconds(400)
    }
    if ([string]::IsNullOrWhiteSpace($query)) {
        $Control.Items.Clear()
        $Control.SelectedIndex = -1
        Set-PucDispatcherSearchStatus -Control $Control -State Idle
    } elseif ($null -ne $script:DispatcherLookup.Handle) {
        Set-PucDispatcherSearchStatus -Control $Control -State Loading
    } else {
        Set-PucDispatcherSearchStatus -Control $Control -State Idle
    }
}

function Update-DispatcherLookup {
    $lookup = $script:DispatcherLookup
    if ($null -eq $lookup) { return }
    if ($null -ne $lookup.Handle) {
        $lookup.Handle.Process.Refresh()
        if (-not $lookup.Handle.Process.HasExited) { return }
        $result = Complete-HiddenProcess $lookup.Handle
        $lookup.Handle = $null
        $control = $lookup.Control
        $currentEnvironment = if ($null -ne $environmentBox.SelectedItem) { [string]$environmentBox.SelectedItem.Name } else { '' }
        if ($null -ne $control -and -not $control.IsDisposed -and $lookup.RequestedQuery -eq $control.Text.Trim() -and $lookup.RequestedEnvironment -eq $currentEnvironment) {
            if ($result.ExitCode -eq 0) {
                $document = Get-LastJsonObject $result.Text
                $typedText = $control.Text
                $control.BeginUpdate()
                try {
                    $control.Items.Clear()
                    $rows = @($document.results)
                    foreach ($row in $rows) {
                        [void]$control.Items.Add([pscustomobject]@{Label=[string]$row.label;Value=[string]$row.account})
                    }
                    $control.SelectedIndex = -1
                    $control.Text = $typedText
                    $control.SelectionStart = $control.Text.Length
                } finally { $control.EndUpdate() }
                Set-PucDispatcherSearchStatus -Control $control -State $(if ($rows.Count -gt 0) {'Found'} else {'Empty'}) -Count $rows.Count
                if ($control.Focused -and $control.Items.Count -gt 0) { $control.DroppedDown = $true }
            } else {
                Set-PucDispatcherSearchStatus -Control $control -State Failed
                Show-PucStandaloneResult -OperationLabel '搜索调度账号' -Environment ([string]$lookup.RequestedEnvironment) -Stage '调度账号模糊搜索' -Outputs @($result.Text) -StartedAt ([datetime]$lookup.StartedAt) -ViewState Finished -ExitCode $result.ExitCode
                $statusLabel.Text = '调度账号搜索失败，请查看服务状态后重试。'
                $statusLabel.ForeColor = [Drawing.Color]::FromArgb(184,70,45)
            }
        }
        if ($lookup.Query -ne $lookup.RequestedQuery) { $lookup.DueAt = [datetime]::Now.AddMilliseconds(200) }
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$lookup.Query) -or [datetime]::Now -lt $lookup.DueAt) { return }
    if ($null -eq $lookup.Control -or $lookup.Control.IsDisposed -or $null -eq $environmentBox.SelectedItem) { return }
    $lookup.RequestedQuery = [string]$lookup.Query
    $lookup.RequestedEnvironment = [string]$environmentBox.SelectedItem.Name
    $lookup.DueAt = [datetime]::MaxValue
    $lookup.StartedAt = [datetime]::Now
    Set-PucDispatcherSearchStatus -Control $lookup.Control -State Loading
    try {
        $lookup.Handle = New-HiddenProcess @('Invoke-PucDispatcherSearch.ps1','-Environment',$lookup.RequestedEnvironment,'-Query',$lookup.RequestedQuery)
    } catch {
        Set-PucDispatcherSearchStatus -Control $lookup.Control -State Failed
        Show-PucStandaloneResult -OperationLabel '搜索调度账号' -Environment ([string]$lookup.RequestedEnvironment) -Stage '调度账号模糊搜索' -Outputs @($_.Exception.Message) -StartedAt ([datetime]$lookup.StartedAt) -ViewState Finished -ExitCode 1
        $statusLabel.Text = '调度账号搜索失败，请查看详细输出。'
        $statusLabel.ForeColor = [Drawing.Color]::FromArgb(184,70,45)
    }
}

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
$resultGrid.MultiSelect = $true
$resultGrid.SelectionMode = [Windows.Forms.DataGridViewSelectionMode]::CellSelect
$resultGrid.ClipboardCopyMode = [Windows.Forms.DataGridViewClipboardCopyMode]::EnableWithoutHeaderText
$resultGrid.RowHeadersVisible = $false
$resultGrid.BackgroundColor = [Drawing.Color]::White
$resultGrid.BorderStyle = [Windows.Forms.BorderStyle]::None
$resultGrid.AutoSizeRowsMode = [Windows.Forms.DataGridViewAutoSizeRowsMode]::AllCells
$resultGrid.ColumnHeadersHeightSizeMode = [Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
$resultGrid.DefaultCellStyle.WrapMode = [Windows.Forms.DataGridViewTriState]::True
$resultGrid.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(214,234,232)
$resultGrid.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::FromArgb(28,37,44)
$resultGrid.Visible = $false

$resultGridMenu = New-Object Windows.Forms.ContextMenuStrip
$copySelectedResultMenuItem = $resultGridMenu.Items.Add('复制所选')
$copySelectedResultMenuItem.ShortcutKeyDisplayString = 'Ctrl+C'
$copyAllResultsMenuItem = $resultGridMenu.Items.Add('复制全部（含表头）')
$resultGrid.ContextMenuStrip = $resultGridMenu
$resultGrid.Add_CellMouseDown({
    param($sender,$eventArgs)
    if ($eventArgs.Button -ne [Windows.Forms.MouseButtons]::Right -or $eventArgs.RowIndex -lt 0 -or $eventArgs.ColumnIndex -lt 0) { return }
    $cell = $sender.Rows[$eventArgs.RowIndex].Cells[$eventArgs.ColumnIndex]
    if (-not $cell.Selected) {
        $sender.ClearSelection()
        $cell.Selected = $true
        $sender.CurrentCell = $cell
    }
})
$resultGridMenu.Add_Opening({
    $copySelectedResultMenuItem.Enabled = $resultGrid.SelectedCells.Count -gt 0
    $copyAllResultsMenuItem.Enabled = $resultGrid.Rows.Count -gt 0 -and $resultGrid.Columns.Count -gt 0
})
$copySelectedResultMenuItem.Add_Click({
    $clipboardData = $resultGrid.GetClipboardContent()
    if ($null -ne $clipboardData) { [Windows.Forms.Clipboard]::SetDataObject($clipboardData,$true) }
})
$copyAllResultsMenuItem.Add_Click({
    $visibleColumns = @($resultGrid.Columns | Where-Object Visible | Sort-Object DisplayIndex)
    if ($visibleColumns.Count -eq 0) { return }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add((@($visibleColumns | ForEach-Object { [string]$_.HeaderText }) -join "`t"))
    foreach ($row in @($resultGrid.Rows | Where-Object { -not $_.IsNewRow })) {
        $values = @($visibleColumns | ForEach-Object {
            ([string]$row.Cells[$_.Index].FormattedValue) -replace "`r?`n",' '
        })
        $lines.Add(($values -join "`t"))
    }
    [Windows.Forms.Clipboard]::SetText(($lines -join [Environment]::NewLine))
})
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
    $actionY = 184 + $InputHeight
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
        'personnel-preview'='人员新增预检';'personnel-live'='新增人员';'role-preview'='角色新增预检';'role-live'='新增角色';'policy-status'='查询首次登录策略'
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
            $statusProperty = $field.PSObject.Properties['Status']
            if ($null -ne $statusProperty) {
                $nodePalette = switch ([string]$statusProperty.Value) {
                    'running' { @{Back=[Drawing.Color]::FromArgb(232,244,252);Fore=[Drawing.Color]::FromArgb(0,92,153)} }
                    'completed' { @{Back=[Drawing.Color]::FromArgb(231,245,239);Fore=[Drawing.Color]::FromArgb(0,115,90)} }
                    'failed' { @{Back=[Drawing.Color]::FromArgb(253,236,234);Fore=[Drawing.Color]::FromArgb(184,70,45)} }
                    default { @{Back=[Drawing.Color]::White;Fore=[Drawing.Color]::FromArgb(92,102,110)} }
                }
                $item.BackColor = $nodePalette.Back
                $item.ForeColor = $nodePalette.Fore
            }
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

function New-InputControl($Field, [int]$Index, [int]$X, [int]$Y, [int]$Width) {
    $label = New-Object Windows.Forms.Label
    $label.Text = [string]$Field.Label
    $label.AutoSize = $true
    $label.Font = New-Object Drawing.Font('Microsoft YaHei UI',9)
    $label.ForeColor = [Drawing.Color]::FromArgb(47,57,63)
    $label.Location = New-Object Drawing.Point($X,$Y)
    $inputPanel.Controls.Add($label)
    $controlY = $Y + 23
    $input = $null
    $additionalControls = @()
    $searchStatus = $null
    $browseButton = $null
    switch ([string]$Field.Kind) {
        'Text' {
            $input = New-Object Windows.Forms.TextBox
            $input.Text = [string]$Field.Default
            $input.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
            $input.BackColor = [Drawing.Color]::White
            $input.Location = New-Object Drawing.Point($X,$controlY)
            $input.Size = New-Object Drawing.Size($Width,27)
        }
        'Multiline' {
            $input = New-Object Windows.Forms.TextBox
            $input.Multiline = $true
            $input.ScrollBars = 'Vertical'
            $input.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
            $input.BackColor = [Drawing.Color]::White
            $input.Location = New-Object Drawing.Point($X,$controlY)
            $input.Size = New-Object Drawing.Size($Width,54)
        }
        'Number' {
            $input = New-Object Windows.Forms.NumericUpDown
            $input.Minimum = 0
            $input.Maximum = 1000
            $input.Value = [decimal]$Field.Default
            $input.BackColor = [Drawing.Color]::White
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
            $input.BackColor = [Drawing.Color]::White
            $input.Location = New-Object Drawing.Point($X,$controlY)
            $input.Size = New-Object Drawing.Size($Width,28)
        }
        'SearchCombo' {
            $searchStatus = New-Object Windows.Forms.Label
            $searchStatus.AutoSize = $false
            $searchStatus.Location = New-Object Drawing.Point(($X + $Width - 116),$Y)
            $searchStatus.Size = New-Object Drawing.Size(116,19)
            $searchStatus.TextAlign = [Drawing.ContentAlignment]::MiddleRight
            $searchStatus.AutoEllipsis = $true
            $searchStatus.ForeColor = [Drawing.Color]::FromArgb(92,102,110)
            $inputPanel.Controls.Add($searchStatus)
            $additionalControls += $searchStatus
            $input = New-Object Windows.Forms.ComboBox
            $input.DropDownStyle = 'DropDown'
            $input.DisplayMember = 'Label'
            $input.ValueMember = 'Value'
            $input.BackColor = [Drawing.Color]::White
            $input.Location = New-Object Drawing.Point($X,$controlY)
            $input.Size = New-Object Drawing.Size($Width,28)
            $input.Tag = $searchStatus
            $input.Add_TextUpdate({
                param($sender,$eventArgs)
                Request-DispatcherLookup -Control ([Windows.Forms.ComboBox]$sender)
            })
            $input.Add_SelectionChangeCommitted({
                param($sender,$eventArgs)
                Set-PucDispatcherSearchStatus -Control ([Windows.Forms.ComboBox]$sender) -State Selected
            })
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
            $browseButton = $browse
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
        'Folder' {
            $input = New-Object Windows.Forms.TextBox
            $input.Location = New-Object Drawing.Point($X,$controlY)
            $input.Size = New-Object Drawing.Size(($Width - 82),27)
            $browse = New-Object Windows.Forms.Button
            $browse.Text = '选择...'
            $browse.Location = New-Object Drawing.Point(($X + $Width - 74),($controlY - 3))
            $browse.Size = New-Object Drawing.Size(74,32)
            $browseButton = $browse
            Set-PucButtonStyle $browse
            $textBox = $input
            $browse.Add_Click({
                $dialog = New-Object Windows.Forms.FolderBrowserDialog
                if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) { $textBox.Text = $dialog.SelectedPath }
                $dialog.Dispose()
            }.GetNewClosure())
            $inputPanel.Controls.Add($browse)
            $additionalControls += $browse
        }
        'Radio' {
            $input = New-Object Windows.Forms.FlowLayoutPanel
            $input.Location = New-Object Drawing.Point($X,$controlY)
            $input.Size = New-Object Drawing.Size($Width,30)
            $input.FlowDirection = 'LeftToRight'
            foreach ($option in $Field.Options) {
                $radio = New-Object Windows.Forms.RadioButton
                $radio.Text = [string]$option.Label
                $radio.Tag = [bool]$option.Value
                $radio.Checked = ([bool]$option.Value -eq [bool]$Field.Default)
                $radio.AutoSize = $true
                $input.Controls.Add($radio)
            }
        }
        default { throw "不支持的字段类型：$($Field.Kind)" }
    }
    $inputPanel.Controls.Add($input)
    $script:FieldControls[$Field.Key] = [pscustomobject]@{Kind=$Field.Kind;LayoutIndex=$Index;Input=$input;Label=$label;SearchStatus=$searchStatus;BrowseButton=$browseButton;AdditionalControls=$additionalControls}
}

function Update-PucInputFieldLayout {
    if ($null -eq $script:FieldControls -or $script:FieldControls.Count -eq 0) { return }
    $horizontalPadding = 24
    $columnGap = 16
    $columnWidth = [Math]::Max(180,[Math]::Floor(($inputPanel.ClientSize.Width - ($horizontalPadding * 2) - $columnGap) / 2))
    foreach ($entry in @($script:FieldControls.Values)) {
        $column = [int]$entry.LayoutIndex % 2
        $x = $horizontalPadding + ($column * ($columnWidth + $columnGap))
        $entry.Label.Left = $x
        $entry.Input.Left = $x
        switch ([string]$entry.Kind) {
            {$_ -in @('Text','Multiline','Number','Combo','SearchCombo','Radio')} {
                $entry.Input.Width = $columnWidth
            }
            {$_ -in @('File','Folder')} {
                $entry.Input.Width = [Math]::Max(96,($columnWidth - 82))
                if ($null -ne $entry.BrowseButton) { $entry.BrowseButton.Left = $x + $columnWidth - 74 }
            }
        }
        if ($null -ne $entry.SearchStatus) { $entry.SearchStatus.Left = $x + $columnWidth - $entry.SearchStatus.Width }
    }
}

$script:InputPanelResizeInvalidationCount = 0
$inputPanel.Add_SizeChanged({
    param($sender,$eventArgs)
    $sender.Invalidate()
    $script:InputPanelResizeInvalidationCount++
    Update-PucInputFieldLayout
})

function Rebuild-Inputs {
$script:LastUpgradePackagePath = ''
$script:SkillUpdateHandle = $null
$script:SkillUpdateStartedAt = $null
    $uploadButton.Enabled = $false
    Update-ActionPanelLayout
    $inputPanel.SuspendLayout()
    $inputPanel.Controls.Clear()
    $script:FieldControls = @{}
    if ($null -ne $script:DispatcherLookup) { $script:DispatcherLookup.Control = $null }
    $fields = @($operationBox.SelectedItem.Fields)
    if ($fields.Count -eq 0) {
        Resize-FormForFields 0
        $inputPanel.ResumeLayout()
        return
    }
    $inputPanel.Controls.Add($inputSectionAccent)
    $inputPanel.Controls.Add($inputSectionLabel)
    $rowHeight = 66
    $columnGap = 16
    $columnWidth = [Math]::Max(180,[Math]::Floor(($inputPanel.ClientSize.Width - 48 - $columnGap) / 2))
    for ($index = 0; $index -lt $fields.Count; $index++) {
        $column = $index % 2
        $row = [Math]::Floor($index / 2)
        $x = 24 + ($column * ($columnWidth + $columnGap))
        New-InputControl -Field $fields[$index] -Index $index -X $x -Y (42 + ($row * $rowHeight)) -Width $columnWidth
    }
    $rows = [Math]::Ceiling($fields.Count / 2)
    Resize-FormForFields (42 + ($rows * $rowHeight))
    Update-PucInputFieldLayout
    $inputPanel.ResumeLayout($true)
}

function Set-ControlsEnabled([bool]$Enabled) {
    $environmentBox.Enabled = $Enabled
    $operationBox.Enabled = $Enabled
    $addEnvironmentButton.Enabled = $Enabled
    $reloadButton.Enabled = $Enabled
    $updateButton.Enabled = $Enabled -and $null -eq $script:SkillUpdateHandle
    $configPathButton.Enabled = $Enabled
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
    foreach ($entry in @($script:FieldControls.Values | Where-Object Kind -eq 'SearchCombo')) {
        $entry.Input.Items.Clear()
        $entry.Input.SelectedIndex = -1
        $entry.Input.Text = ''
        Set-PucDispatcherSearchStatus -Control $entry.Input -State Idle
    }
    if ($null -ne $script:DispatcherLookup) { $script:DispatcherLookup.Control = $null; $script:DispatcherLookup.Query = '' }
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
    $node = @(Get-PucExecutionNodeForStage -Nodes $script:ExecutionState.ExecutionNodes -Stage $Stage)
    if ($node.Count -eq 1) { $node[0].Status = 'running' }
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
        -ExecutionNodes @($script:ExecutionState.ExecutionNodes) `
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
    Set-PucPendingExecutionNodesSkipped $script:ExecutionState
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
        ExecutionNodes=[Collections.Generic.List[object]]::new()
    }
    $executionAction = if ($operation -in @('policy','force-login')) { [string](Get-FieldValue 'action') } else { '' }
    foreach ($node in @(Get-PucExecutionNodeDefinitions -Operation $operation -Action $executionAction)) { $state.ExecutionNodes.Add($node) }
    $script:ExecutionState = $state
    switch ($operation) {
        'android-upgrade' {
            $path = Assert-ExistingFile ([string](Get-FieldValue 'apkPath')) @('.apk') 'APK 文件'
            $description = [string](Get-FieldValue 'description')
            if ([string]::IsNullOrWhiteSpace($description)) { throw '升级说明不能为空。' }
            $state.Data.ApkPath=$path;$state.Data.Description=$description;$state.Data.Force=[bool](Get-FieldValue 'force')
            $script:LastUpgradePackagePath='';$uploadButton.Enabled=$false
            Start-Stage 'android-upgrade-inspect' @('Invoke-AndroidUpgradePackage.ps1','-Action','Inspect','-ApkPath',$path)
        }
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
            $numberType=[string](Get-FieldValue 'numberType')
            if($numberType -notin @('102','103','104')){throw '人员类型不正确。'}
            $arguments=@('Invoke-PucPersonnel.ps1','-Environment',$environment,'-NumberType',$numberType)
            if($operation -eq 'personnel-exact'){$arguments+=@('-ExactAlias',$alias)}else{
                $count=[int](Get-FieldValue 'count');if($count -lt 1){throw '创建数量必须大于 0。'}
                $arguments+=@('-AliasPrefix',$alias,'-StartSequence',[string](Get-FieldValue 'startSequence'),'-Count',[string]$count)
            }
            $dispatcher=[string](Get-FieldValue 'dispatcherAccount');if($dispatcher){Assert-SafeArgument $dispatcher '关联调度账号';$arguments+=@('-DispatcherAccount',$dispatcher)}
            $rootOrg=[string](Get-FieldValue 'rootOrganizationName');if($rootOrg){Assert-SafeArgument $rootOrg '根组织名称';$arguments+=@('-RootOrganizationName',$rootOrg)}
            $state.Data.BaseArguments=@($arguments)
            Start-Stage 'personnel-preview' (@($arguments)+@('-DryRun'))
        }
        'role' {
            $roleAlias=[string](Get-FieldValue 'roleAlias');Assert-SafeArgument $roleAlias '角色名称'
            if([string]::IsNullOrWhiteSpace($roleAlias)){throw '角色名称不能为空。'}
            $arguments=@('Invoke-PucRole.ps1','-Environment',$environment,'-RoleAlias',$roleAlias)
            $state.Data.BaseArguments=@($arguments);$state.Data.RoleAlias=$roleAlias
            Start-Stage 'role-preview' (@($arguments)+@('-DryRun'))
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

function Start-SkillUpdate {
    if ($null -ne $script:SkillUpdateHandle) { return }
    $script:SkillUpdateStartedAt = [datetime]::Now
    try {
        Set-ControlsEnabled $false
        Clear-PucResultView
        $statusLabel.Text = '正在检查远端更新...'
        $statusLabel.ForeColor = [Drawing.Color]::FromArgb(92,102,110)
        $skillPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:SkillUpdateHandle = New-HiddenProcess @('Invoke-PucSkillUpdate.ps1','-SkillPath',$skillPath,'-Mode','Apply')
    } catch {
        $script:SkillUpdateHandle = $null
        Set-ControlsEnabled $true
        Show-PucStandaloneResult -OperationLabel '更新版本包' -Environment '' -Stage '检查并更新版本包' -Outputs @($_.Exception.Message) -StartedAt $script:SkillUpdateStartedAt -ViewState Finished -ExitCode 1
        $statusLabel.Text = '更新失败'
        $statusLabel.ForeColor = [Drawing.Color]::FromArgb(184,70,45)
    }
}

function Complete-SkillUpdate {
    $handle = $script:SkillUpdateHandle
    $result = Complete-HiddenProcess $handle
    $script:SkillUpdateHandle = $null
    $json = Get-LastJsonObject $result.Text
    Show-PucStandaloneResult -OperationLabel '更新版本包' -Environment '' -Stage '检查并更新版本包' -Outputs @($(if ([string]::IsNullOrWhiteSpace($result.Text)) {'（无输出）'} else {$result.Text})) -StartedAt $script:SkillUpdateStartedAt -ViewState Finished -ExitCode $result.ExitCode
    if ($result.ExitCode -ne 0) {
        $statusLabel.Text = '更新失败'
        $statusLabel.ForeColor = [Drawing.Color]::FromArgb(184,70,45)
        Set-ControlsEnabled $true
        return
    }
    if ([string]$json.status -eq 'staged') {
        $workerPath=[IO.Path]::GetFullPath([string]$json.workerPath)
        $manifestPath=[IO.Path]::GetFullPath([string]$json.manifestPath)
        if(-not(Test-Path -LiteralPath $workerPath -PathType Leaf)-or-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){
            $statusLabel.Text='更新暂存结果无效';$statusLabel.ForeColor=[Drawing.Color]::FromArgb(184,70,45);Set-ControlsEnabled $true;return
        }
        $statusLabel.Text = '下载校验完成，正在退出并安装更新'
        $statusLabel.ForeColor = [Drawing.Color]::FromArgb(0,115,90)
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$workerPath+'"'),'-ManifestPath',('"'+$manifestPath+'"'),'-ParentProcessId',[string]$PID) -WindowStyle Hidden | Out-Null
        } catch {
            $statusLabel.Text='无法启动独立更新组件';$statusLabel.ForeColor=[Drawing.Color]::FromArgb(184,70,45);Set-ControlsEnabled $true;return
        }
        $form.Close()
        return
    } else {
        $statusLabel.Text = '全部版本包已是最新版本'
        $statusLabel.ForeColor = [Drawing.Color]::FromArgb(92,102,110)
    }
    Set-ControlsEnabled $true
}

function Show-PendingSkillUpdateResult {
    $resultPath=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'puc-config\update-result.json'
    if(-not(Test-Path -LiteralPath $resultPath -PathType Leaf)){return $false}
    try {
        $text=Get-Content -Raw -LiteralPath $resultPath
        $record=$text|ConvertFrom-Json
        $failed=[string]$record.status -eq 'update-failed'
        Show-PucStandaloneResult -OperationLabel '更新版本包' -Environment '' -Stage '关闭后安装版本包' -Outputs @($text) -StartedAt ([datetime]::Now) -ViewState Finished -ExitCode $(if($failed){1}else{0})
        $statusLabel.Text=$(if($failed){'版本包更新失败，已恢复旧版本'}else{'所有版本包更新完成'})
        $statusLabel.ForeColor=$(if($failed){[Drawing.Color]::FromArgb(184,70,45)}else{[Drawing.Color]::FromArgb(0,115,90)})
        $lastUpdateLabel.Text=Get-PucSkillUpdateDisplayText
        return $true
    } catch { return $false }
    finally { Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue }
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 200
$timer.Add_Tick({
    Update-EnvironmentVersionLookup
    Update-DispatcherLookup
    if ($null -ne $script:SkillUpdateHandle) {
        $script:SkillUpdateHandle.Process.Refresh()
        if (-not $script:SkillUpdateHandle.Process.HasExited) { return }
        Complete-SkillUpdate
        return
    }
    if($null -eq $script:ExecutionState -or $null -eq $script:ExecutionState.Handle){return}
    $process=$script:ExecutionState.Handle.Process;$process.Refresh();if(-not $process.HasExited){return}
    $result=Complete-HiddenProcess $script:ExecutionState.Handle
    $script:ExecutionState.Handle=$null
    $stage=[string]$script:ExecutionState.Stage
    $node = @(Get-PucExecutionNodeForStage -Nodes $script:ExecutionState.ExecutionNodes -Stage $stage)
    if ($node.Count -eq 1) { $node[0].Status = if ($result.ExitCode -eq 0) {'completed'} else {'failed'} }
    $stageHeading = if ($node.Count -eq 1) {
        $nodeIndex = [array]::IndexOf(@($script:ExecutionState.ExecutionNodes),$node[0]) + 1
        "=== $nodeIndex. $([string]$node[0].Label) ==="
    } else { "=== $(Get-PucStageDisplayLabel $stage) ===" }
    $stageOutput = if ([string]::IsNullOrWhiteSpace($result.Text)) {'（无输出）'} else {$result.Text}
    $script:ExecutionState.Outputs.Add("$stageHeading`r`n$stageOutput")

    if($stage -eq 'create-live' -and $result.ExitCode -ne 0 -and $result.Text -match 'ACCOUNT_LOOKUP_DECISION_REQUIRED'){
        if ($node.Count -eq 1) { $node[0].Status = 'pending' }
        Request-PreviewConfirmation -Prompt '请查看完整账号预览，确认是否继续创建。' -NextStage 'create-large-live' -Arguments @('Invoke-PucAccounts.ps1','-Environment',$script:ExecutionState.Environment,'-Prefix',$script:ExecutionState.Data.Prefix,'-Count',[string]$script:ExecutionState.Data.Count,'-Live','-ConfirmLive','-ContinueWhenMoreThan30Accounts') -CancelText '用户已取消继续创建。';return
    }
    if($result.ExitCode -ne 0){Finish-Execution $result.ExitCode;return}

    $json=Get-LastJsonObject $result.Text
    try {
        switch($stage){
            'android-upgrade-inspect' {
                if ([string]$json.status -ne 'inspected' -or [string]::IsNullOrWhiteSpace([string]$json.apkMd5)) { throw 'APK 解析结果无效。' }
                $manifest=New-TempManifest 'android-upgrade';$script:ExecutionState.TempPaths.Add($manifest);$script:ExecutionState.Data.Manifest=$manifest
                $document=[ordered]@{apkPath=[string]$json.apkPath;description=[string]$script:ExecutionState.Data.Description;force=[bool]$script:ExecutionState.Data.Force;versionCode=[long]$json.versionCode;versionName=[string]$json.versionName;apkMd5=[string]$json.apkMd5;apkSize=[long]$json.apkSize}
                [IO.File]::WriteAllText($manifest,($document|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
                Start-Stage 'android-upgrade-preview' @('Invoke-AndroidUpgradePackage.ps1','-Action','Preview','-ManifestPath',$manifest);return
            }
            'android-upgrade-preview' {
                Request-PreviewConfirmation -Prompt '请核对 APK、版本、升级说明、强制升级状态和输出目录。' -NextStage 'android-upgrade-build' -Arguments @('Invoke-AndroidUpgradePackage.ps1','-Action','Build','-ManifestPath',$script:ExecutionState.Data.Manifest) -CancelText '用户已取消制作升级包。';return
            }
            'android-upgrade-build' {
                $path=[string]$json.finalPath
                if ([string]$json.status -ne 'created' -or [string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw '升级包制作结果缺少有效文件。' }
                $script:LastUpgradePackagePath=$path;$uploadButton.Enabled=$true
                Finish-Execution 0;return
            }
            'reset-preview' {
                $hash=[string]$json.snapshotHash;if($hash -notmatch '^[A-Fa-f0-9]{64}$'){throw '预检未返回有效的账号快照哈希。'}
                Start-Stage 'reset-live' @('Invoke-PucAccountPasswordReset.ps1','-Environment',$script:ExecutionState.Environment,'-Account',$script:ExecutionState.Data.Account,'-Live','-ConfirmLive','-ExpectedSnapshotHash',$hash);return
            }
            'batch-reset-preview' {
                if([string]$json.status -eq 'no-match'){
                    Set-PucPendingExecutionNodesSkipped $script:ExecutionState
                    Finish-Execution 0
                    $statusLabel.Text='查询结果为空'
                    $statusLabel.ForeColor=[Drawing.Color]::FromArgb(92,102,110)
                    return
                }
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
            'role-preview' { Start-Stage 'role-live' (@($script:ExecutionState.Data.BaseArguments)+@('-Live','-ConfirmLive'));return }
            'policy-preview' {
                if($json.writeRequired -ne $true){Set-PucPendingExecutionNodesSkipped $script:ExecutionState;Finish-Execution 0;return}
                Start-Stage 'policy-live' @('Invoke-PucFirstLoginPasswordCheck.ps1','-Environment',$script:ExecutionState.Environment,'-Action',$script:ExecutionState.Data.Action,'-Live','-ConfirmLive');return
            }
            'force-preview' {
                if([string]$json.status -eq 'no-change'){Set-PucPendingExecutionNodesSkipped $script:ExecutionState;Finish-Execution 0;return}
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
$actionPanel.Add_SizeChanged({Update-ActionPanelLayout})
function Sync-ContainerWidths {
    $containerWidth = [Math]::Max(760,$form.ClientSize.Width)
    $header.Width = $containerWidth
    $accent.Width = $containerWidth
    $selectionPanel.Width = $containerWidth
    $inputPanel.Width = [Math]::Max(728,($containerWidth - 32))
    $actionPanel.Width = $containerWidth
    $resultLabel.Width = [Math]::Max(200,$containerWidth - 48)
    $resultTabs.Width = [Math]::Max(200,$containerWidth - 48)
}

$form.Add_Resize({
    Sync-ContainerWidths
    if ($resultFields.Columns.Count -ge 2) {
        $resultFields.Columns[1].Width = [Math]::Max(180,$resultFields.ClientSize.Width - $resultFields.Columns[0].Width - 8)
    }
})
Sync-ContainerWidths
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
$configPathButton.Add_Click({
    $startedAt = [datetime]::Now
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = '选择配置存放位置，程序会在其中使用 agentSkillLocalConfig\puc-config 目录'
    $dialog.ShowNewFolderButton = $true
    try {
        try { $currentRoot = Get-PucConfigRoot } catch { $currentRoot = Get-PucDefaultConfigRoot }
        $currentStoragePath = Get-PucLauncherStorageSelectionPath $currentRoot
        if (Test-Path -LiteralPath $currentStoragePath -PathType Container) { $dialog.SelectedPath = $currentStoragePath }
        if ($dialog.ShowDialog($form) -ne [Windows.Forms.DialogResult]::OK) { return }
        $previousRoot = try { Get-PucConfigRoot } catch { '' }
        $pathChange = Set-PucLauncherConfigRoot -Path $dialog.SelectedPath -CurrentRoot $previousRoot
        Load-Environments
        $pathActionText = Get-PucLauncherConfigPathActionText ([string]$pathChange.Action)
        $statusLabel.Text = "$pathActionText；最新路径：$($pathChange.ConfigRoot)"
        $statusLabel.ForeColor = [Drawing.Color]::FromArgb(0,115,90)
        $headerToolTip.SetToolTip($configPathButton,("当前配置路径：$($pathChange.ConfigRoot)"))
        $pathResultJson = Get-PucLauncherConfigPathResultJson -Action ([string]$pathChange.Action) -ConfigRoot ([string]$pathChange.ConfigRoot)
        Show-PucStandaloneResult -OperationLabel '设置配置路径' -Environment '' -Stage '更新配置路径' -Outputs @($pathResultJson) -StartedAt $startedAt -ViewState Finished -ExitCode 0
        if ($pathChange.RestartRequired) {
            $vbs = Join-Path $PSScriptRoot 'Start-PucConfigTool.vbs'
            Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"') -WindowStyle Hidden | Out-Null
            $form.Close()
            return
        }
    } catch {
        $statusLabel.Text = '配置路径更新失败'
        $statusLabel.ForeColor = [Drawing.Color]::FromArgb(184,70,45)
        [Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'设置配置文件路径','OK','Error') | Out-Null
    } finally { $dialog.Dispose() }
})
$updateButton.Add_Click({ Start-SkillUpdate })
$clearButton.Add_Click({$script:LastUpgradePackagePath='';$uploadButton.Enabled=$false;Clear-PucResultView;$statusLabel.Text='就绪';$statusLabel.ForeColor=[Drawing.Color]::FromArgb(92,102,110)})
$confirmButton.Add_Click({Confirm-PendingPreview})
$cancelConfirmationButton.Add_Click({Cancel-PendingPreview})
$uploadButton.Add_Click({
    if ([string]::IsNullOrWhiteSpace($script:LastUpgradePackagePath) -or -not (Test-Path -LiteralPath $script:LastUpgradePackagePath -PathType Leaf)) {
        $uploadButton.Enabled=$false
        [Windows.Forms.MessageBox]::Show($form,'请先成功制作升级包。','上传升级包','OK','Warning')|Out-Null
        return
    }
    if ($null -eq $environmentBox.SelectedItem) {
        [Windows.Forms.MessageBox]::Show($form,'请先新增或选择 PUC 环境后再上传。','上传升级包','OK','Warning')|Out-Null
        return
    }
    [Windows.Forms.MessageBox]::Show($form,'PUC 升级包上传接口尚未配置，未执行上传。','上传升级包','OK','Information')|Out-Null
})
$runButton.Add_Click({
    $startedAt=[datetime]::Now
    try{
        if($null -eq $environmentBox.SelectedItem -and [string]$operationBox.SelectedItem.Key -ne 'android-upgrade'){throw '请选择环境。'}
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
    if($null -ne $script:SkillUpdateHandle){
        $eventArgs.Cancel=$true
        [Windows.Forms.MessageBox]::Show($form,'Skill 更新仍在进行，请等待完成后再关闭。','PUC Toolkit','OK','Information')|Out-Null
        return
    }
    if($null -ne $script:ExecutionState){
        $eventArgs.Cancel=$true
        [Windows.Forms.MessageBox]::Show($form,'PUC 操作仍在运行，请等待完成后再关闭。','PUC Toolkit','OK','Information')|Out-Null
    }
})

if ($UiSelfTest) {
    try {
        $rootSelfTestDirectory = Join-Path ([IO.Path]::GetTempPath()) ('puc-launcher-root-self-test-' + [guid]::NewGuid().ToString('N'))
        try {
            $testSettingsPath = Join-Path $rootSelfTestDirectory 'local\setting.json'
            $testDefaultRoot = Join-Path $rootSelfTestDirectory 'desktop\agentSkillLocalConfig\puc-config'
            $initializedRoot = Initialize-PucLauncherConfigRoot -SettingsPath $testSettingsPath -DefaultRoot $testDefaultRoot
            $savedSettings = Read-PucJson -Path $testSettingsPath -Default $null
            if (-not $initializedRoot.Initialized -or -not (Test-Path -LiteralPath $testDefaultRoot -PathType Container) -or [string]$savedSettings.configRoot -ne [IO.Path]::GetFullPath($testDefaultRoot)) { throw 'GUI 默认配置路径自动初始化失败。' }
            $testCustomRoot = Join-Path $rootSelfTestDirectory 'custom-config'
            New-Item -ItemType Directory -Force -Path $testCustomRoot | Out-Null
            Write-PucJson -Path $testSettingsPath -Value ([ordered]@{configRoot=$testCustomRoot})
            $preservedRoot = Initialize-PucLauncherConfigRoot -SettingsPath $testSettingsPath -DefaultRoot $testDefaultRoot
            if ($preservedRoot.Initialized -or $preservedRoot.ConfigRoot -ne [IO.Path]::GetFullPath($testCustomRoot)) { throw 'GUI 覆盖了有效的自定义配置路径。' }
            $testTemplatePath = Join-Path $rootSelfTestDirectory 'config.template.json'
            Write-PucJson -Path $testTemplatePath -Value ([ordered]@{version=1;environments=@()})
            $sourceDocument = [ordered]@{version=1;environments=@([ordered]@{name='10.1.1.1';baseUrl='https://10.1.1.1:16890'})}
            $migrationSourceParent = Join-Path $rootSelfTestDirectory 'old-storage\agentSkillLocalConfig'
            $migrationSourceRoot = Join-Path $migrationSourceParent 'puc-config'
            Write-PucJson -Path (Join-Path $migrationSourceRoot 'config.json') -Value $sourceDocument
            Write-PucJson -Path (Join-Path $migrationSourceRoot 'runtime.json') -Value ([ordered]@{marker='runtime-preserved'})
            Write-PucJson -Path (Join-Path $migrationSourceRoot 'reports\latest.json') -Value ([ordered]@{marker='report-preserved'})
            Write-PucJson -Path $testSettingsPath -Value ([ordered]@{configRoot=$migrationSourceRoot})
            $moveTargetStorage = Join-Path $rootSelfTestDirectory 'moved-config'
            $moveTargetRoot = Join-Path $moveTargetStorage 'agentSkillLocalConfig\puc-config'
            if ((Resolve-PucLauncherConfigRootFromSelection $moveTargetStorage) -ne $moveTargetRoot -or (Resolve-PucLauncherConfigRootFromSelection (Split-Path -Parent $moveTargetRoot)) -ne $moveTargetRoot -or (Resolve-PucLauncherConfigRootFromSelection $moveTargetRoot) -ne $moveTargetRoot) { throw 'GUI 配置存放位置未正确解析固定目录结构。' }
            $moveResult = Set-PucLauncherConfigRoot -Path $moveTargetStorage -CurrentRoot $migrationSourceRoot -SettingsPath $testSettingsPath -TemplatePath $testTemplatePath
            if ($moveResult.Action -ne 'moved' -or $moveResult.RestartRequired -or (Test-Path -LiteralPath $migrationSourceRoot) -or (Test-Path -LiteralPath $migrationSourceParent) -or -not (Test-Path -LiteralPath (Join-Path $moveTargetRoot 'config.json'))) { throw 'GUI 配置目录整体迁移失败。' }
            $movedDocument = Read-PucJson -Path (Join-Path $moveTargetRoot 'config.json') -Default $null
            $movedRuntime = Read-PucJson -Path (Join-Path $moveTargetRoot 'runtime.json') -Default $null
            $movedReport = Read-PucJson -Path (Join-Path $moveTargetRoot 'reports\latest.json') -Default $null
            $movedSettings = Read-PucJson -Path $testSettingsPath -Default $null
            if (@($movedDocument.environments).Count -ne 1 -or [string]$movedDocument.environments[0].name -ne '10.1.1.1' -or [string]$movedRuntime.marker -ne 'runtime-preserved' -or [string]$movedReport.marker -ne 'report-preserved' -or [string]$movedSettings.configRoot -ne $moveTargetRoot) { throw '迁移后的 GUI 配置目录内容不完整。' }
            $pathResultJson = Get-PucLauncherConfigPathResultJson -Action ([string]$moveResult.Action) -ConfigRoot ([string]$moveResult.ConfigRoot)
            $pathResultModel = New-PucResultModel -Outputs @($pathResultJson) -OperationLabel '设置配置路径' -Stage '更新配置路径' -StartedAt ([datetime]::Now) -ViewState Finished -ExitCode 0
            $pathResultFields = @{}; foreach ($field in @($pathResultModel.Fields)) { $pathResultFields[[string]$field.Name] = [string]$field.Value }
            if ($pathResultModel.Heading -ne '执行成功 · 设置配置路径' -or $pathResultFields['message'] -ne '配置路径设置成功' -or $pathResultFields['operationResult'] -ne '配置目录及全部内容已迁移' -or $pathResultFields['configRoot'] -ne $moveTargetRoot) { throw 'GUI 执行摘要未展示配置路径设置结果和最新路径。' }
            $emptySourceRoot = Join-Path $rootSelfTestDirectory 'empty-source'
            $initializeTargetStorage = Join-Path $rootSelfTestDirectory 'initialized-config'
            $initializeTargetRoot = Join-Path $initializeTargetStorage 'agentSkillLocalConfig\puc-config'
            $initializeResult = Set-PucLauncherConfigRoot -Path $initializeTargetStorage -CurrentRoot $emptySourceRoot -SettingsPath $testSettingsPath -TemplatePath $testTemplatePath
            $initializedDocument = Read-PucJson -Path (Join-Path $initializeTargetRoot 'config.json') -Default $null
            if ($initializeResult.Action -ne 'initialized' -or $initializeResult.RestartRequired -or [int]$initializedDocument.version -ne 1 -or @($initializedDocument.environments).Count -ne 0) { throw 'GUI 新路径配置文件初始化失败。' }
        } finally {
            if (Test-Path -LiteralPath $rootSelfTestDirectory) { Remove-Item -LiteralPath $rootSelfTestDirectory -Recurse -Force -ErrorAction SilentlyContinue }
        }
        if ($updateButton.Parent -ne $header -or $updateButton.Text -ne [string][char]0xE896 -or $updateButton.AccessibleName -ne '更新版本包' -or -not $updateButton.Enabled -or $updateButton.FlatAppearance.BorderSize -ne 0 -or $updateButton.ForeColor -ne [Drawing.Color]::FromArgb(0,105,99) -or $updateButton.FlatAppearance.MouseOverBackColor -ne [Drawing.Color]::FromArgb(240,250,249) -or $updateButton.FlatAppearance.MouseDownBackColor -ne [Drawing.Color]::FromArgb(214,234,232) -or $updateButton.Bounds.IntersectsWith($lastUpdateLabel.Bounds)) { throw '顶部版本更新图标渲染不正确。' }
        if ($lastUpdateLabel.Parent -ne $header -or $lastUpdateLabel.Text -notmatch '^上次更新：(暂无记录|\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})$') { throw '上次更新时间渲染不正确。' }
        if ($addEnvironmentButton.BackColor -ne [Drawing.Color]::White -or $addEnvironmentButton.ForeColor -ne [Drawing.Color]::FromArgb(29,78,216) -or $addEnvironmentButton.FlatAppearance.BorderColor -ne [Drawing.Color]::FromArgb(147,197,253)) { throw '新增环境按钮配色不正确。' }
        if ($configPathButton.Parent -ne $selectionPanel -or $configPathButton.Text -ne '设置配置路径' -or $configPathButton.AccessibleName -ne '设置配置文件路径' -or $configPathButton.BackColor -ne [Drawing.Color]::White -or $configPathButton.ForeColor -ne [Drawing.Color]::FromArgb(194,95,20) -or $configPathButton.FlatAppearance.BorderColor -ne [Drawing.Color]::FromArgb(229,161,93)) { throw '配置路径按钮渲染不正确。' }
        if ($reloadButton.BackColor -ne [Drawing.Color]::White -or $reloadButton.ForeColor -ne [Drawing.Color]::FromArgb(0,105,99) -or $reloadButton.FlatAppearance.BorderColor -ne [Drawing.Color]::FromArgb(134,203,196)) { throw '刷新按钮配色不正确。' }
        foreach ($toolbarButton in @($configPathButton,$addEnvironmentButton,$reloadButton)) {
            if ($toolbarButton.FlatStyle -ne [Windows.Forms.FlatStyle]::Flat -or $toolbarButton.FlatAppearance.BorderSize -ne 1 -or $toolbarButton.Height -ne $reloadButton.Height -or $toolbarButton.Font.Name -ne $reloadButton.Font.Name -or $toolbarButton.Font.Size -ne $reloadButton.Font.Size -or $toolbarButton.Font.Style -ne $reloadButton.Font.Style) { throw '环境工具栏按钮风格不一致。' }
        }
        foreach ($leftControl in @($operationBox,$configPathButton,$addEnvironmentButton)) {
            $rightControl = if ($leftControl -eq $operationBox) {$configPathButton} elseif ($leftControl -eq $configPathButton) {$addEnvironmentButton} else {$reloadButton}
            if ($leftControl.Bounds.IntersectsWith($rightControl.Bounds)) { throw '环境操作行控件发生重叠。' }
        }
        foreach ($operation in $script:Operations) {
            $requiredWidth = [Windows.Forms.TextRenderer]::MeasureText([string]$operation.Label,$operationBox.Font).Width + 28
            if ($requiredWidth -gt $operationBox.ClientSize.Width) { throw "操作名称显示宽度不足：$([string]$operation.Label)" }
        }
        if ($uploadButton.Enabled -or $script:UploadButtonRequestedVisible) { throw '非 Android 升级包操作不得显示或启用上传按钮。' }
        $operationBox.SelectedItem = @($script:Operations | Where-Object Key -eq 'android-upgrade')[0]
        Rebuild-Inputs
        if (-not $script:UploadButtonRequestedVisible -or $uploadButton.Enabled) { throw 'Android 升级包操作必须显示处于禁用状态的上传按钮。' }
        if ($uploadButton.Bounds.IntersectsWith($statusLabel.Bounds)) { throw '上传按钮与状态文本发生重叠。' }
        $operationBox.SelectedItem = @($script:Operations | Where-Object Key -eq 'reset-query')[0]
        Rebuild-Inputs
        if ($script:UploadButtonRequestedVisible) { throw '切换到非 Android 升级包操作后上传按钮仍然可见。' }
        $operationBox.SelectedItem = @($script:Operations | Where-Object Key -eq 'create')[0]
        Rebuild-Inputs
        if (-not [string]::IsNullOrEmpty([string]$script:FieldControls['prefix'].Input.Text)) { throw '新增调度账号 GUI 不得预填账号前缀。' }
        if ([int]$script:FieldControls['count'].Input.Value -ne 1) { throw '新增调度账号 GUI 创建数量必须默认为 1。' }
        if (-not [bool]$inputPanelDoubleBufferedProperty.GetValue($inputPanel,$null)) { throw '操作参数面板未启用双缓冲重绘。' }
        $prefixInput = $script:FieldControls['prefix'].Input
        $countInput = $script:FieldControls['count'].Input
        $initialFieldWidth = $prefixInput.Width
        if ($prefixInput.Left -ne 24 -or $countInput.Left - $prefixInput.Right -ne 16 -or $prefixInput.Width -ne $countInput.Width -or $countInput.Right -ne ($inputPanel.ClientSize.Width - 24)) { throw '操作参数两列未与容器等宽对齐。' }
        $originalClientSize = $form.ClientSize
        $initialResizeInvalidationCount = $script:InputPanelResizeInvalidationCount
        $form.ClientSize = New-Object Drawing.Size(($originalClientSize.Width + 240),$originalClientSize.Height)
        Sync-ContainerWidths
        Update-PucInputFieldLayout
        if ($prefixInput.Width -le $initialFieldWidth -or $countInput.Right -ne ($inputPanel.ClientSize.Width - 24) -or $countInput.Left - $prefixInput.Right -ne 16) { throw '窗口缩放后操作参数两列未随容器伸缩。' }
        if ($script:InputPanelResizeInvalidationCount -le $initialResizeInvalidationCount) { throw '窗口缩放时操作参数面板未执行全区域失效重绘。' }
        $form.ClientSize = $originalClientSize
        Sync-ContainerWidths
        Update-PucInputFieldLayout
        $operationBox.SelectedItem = @($script:Operations | Where-Object Key -eq 'personnel-exact')[0]
        Rebuild-Inputs
        $typeControl = $script:FieldControls['numberType'].Input
        $dispatcherControl = $script:FieldControls['dispatcherAccount'].Input
        $dispatcherStatus = $script:FieldControls['dispatcherAccount'].SearchStatus
        if ($typeControl.Items.Count -ne 3 -or (@($typeControl.Items | ForEach-Object Label) -join ',') -ne '人员,车,应急车') { throw '人员类型下拉选项渲染不正确。' }
        if ($dispatcherControl.DropDownStyle -ne [Windows.Forms.ComboBoxStyle]::DropDown -or $dispatcherControl.DisplayMember -ne 'Label' -or $dispatcherControl.ValueMember -ne 'Value') { throw '调度账号搜索单选下拉渲染不正确。' }
        if ($dispatcherStatus -isnot [Windows.Forms.Label] -or $dispatcherControl.Tag -ne $dispatcherStatus) { throw '调度账号搜索状态标签未正确绑定。' }
        if ($script:FieldControls['dispatcherAccount'].Label.Bounds.IntersectsWith($dispatcherStatus.Bounds)) { throw '调度账号搜索状态与字段标题发生重叠。' }
        Set-PucDispatcherSearchStatus -Control $dispatcherControl -State Loading
        if ($dispatcherStatus.Text -ne '查询中...' -or $dispatcherStatus.ForeColor.B -le $dispatcherStatus.ForeColor.R) { throw '调度账号查询中状态显示不正确。' }
        Set-PucDispatcherSearchStatus -Control $dispatcherControl -State Found -Count 2
        if ($dispatcherStatus.Text -ne '找到 2 个账号') { throw '调度账号查询成功状态显示不正确。' }
        Set-PucDispatcherSearchStatus -Control $dispatcherControl -State Empty
        if ($dispatcherStatus.Text -ne '未找到匹配账号') { throw '调度账号查询空结果状态显示不正确。' }
        Set-PucDispatcherSearchStatus -Control $dispatcherControl -State Failed
        if ($dispatcherStatus.Text -ne '查询失败' -or $dispatcherStatus.ForeColor.R -le $dispatcherStatus.ForeColor.G) { throw '调度账号查询失败状态显示不正确。' }
        Set-PucDispatcherSearchStatus -Control $dispatcherControl -State Selected
        if ($dispatcherStatus.Text -ne '已选择' -or $dispatcherStatus.ForeColor.G -le $dispatcherStatus.ForeColor.R) { throw '调度账号已选择状态显示不正确。' }
        $script:DispatcherLookup = $null
        $dispatcherControl.Text = 'mhw'
        $onTextUpdate = [Windows.Forms.ComboBox].GetMethod('OnTextUpdate',[Reflection.BindingFlags]'Instance,NonPublic')
        [void]$onTextUpdate.Invoke($dispatcherControl,@([EventArgs]::Empty))
        if ($null -eq $script:DispatcherLookup -or $script:DispatcherLookup.Control -ne $dispatcherControl -or $script:DispatcherLookup.Query -ne 'mhw') { throw '调度账号搜索输入事件未正确建立查询状态。' }
        $script:DispatcherLookup = $null
        $operationBox.SelectedItem = @($script:Operations | Where-Object Key -eq 'update')[0]
        Rebuild-Inputs
        $updateAccountControl = $script:FieldControls['account'].Input
        if ($updateAccountControl.DropDownStyle -ne [Windows.Forms.ComboBoxStyle]::DropDown -or $updateAccountControl.DisplayMember -ne 'Label' -or $updateAccountControl.ValueMember -ne 'Value') { throw '更新账号信息的调度账号搜索下拉渲染不正确。' }
        $updateAccountControl.Text = 'mhw19'
        [void]$onTextUpdate.Invoke($updateAccountControl,@([EventArgs]::Empty))
        if ($null -eq $script:DispatcherLookup -or $script:DispatcherLookup.Control -ne $updateAccountControl -or $script:DispatcherLookup.Query -ne 'mhw19') { throw '更新账号信息的调度账号搜索事件未正确建立查询状态。' }
        $freeTextRejected = $false
        try { [void](Get-FieldValue 'account') } catch { $freeTextRejected = $_.Exception.Message -eq '请从调度账号搜索下拉列表中选择一个账号。' }
        if (-not $freeTextRejected) { throw '更新账号信息错误地接受了未选择的自由文本账号。' }
        [void]$updateAccountControl.Items.Add([pscustomobject]@{Label='mhw19001_alias(mhw19001)';Value='mhw19001'})
        $updateAccountControl.SelectedIndex = 0
        if ([string](Get-FieldValue 'account') -ne 'mhw19001') { throw '更新账号信息未读取选中的精确调度账号。' }
        $script:DispatcherLookup = $null
        $operationBox.SelectedItem = @($script:Operations | Where-Object Key -eq 'reset')[0]
        Rebuild-Inputs
        $resetAccountControl = $script:FieldControls['account'].Input
        if ($resetAccountControl.DropDownStyle -ne [Windows.Forms.ComboBoxStyle]::DropDown -or $resetAccountControl.DisplayMember -ne 'Label' -or $resetAccountControl.ValueMember -ne 'Value') { throw '重置单个账号密码的调度账号搜索下拉渲染不正确。' }
        $resetAccountControl.Text = 'mhw20'
        [void]$onTextUpdate.Invoke($resetAccountControl,@([EventArgs]::Empty))
        if ($null -eq $script:DispatcherLookup -or $script:DispatcherLookup.Control -ne $resetAccountControl -or $script:DispatcherLookup.Query -ne 'mhw20') { throw '重置单个账号密码的调度账号搜索事件未正确建立查询状态。' }
        $resetFreeTextRejected = $false
        try { [void](Get-FieldValue 'account') } catch { $resetFreeTextRejected = $_.Exception.Message -eq '请从调度账号搜索下拉列表中选择一个账号。' }
        if (-not $resetFreeTextRejected) { throw '重置单个账号密码错误地接受了未选择的自由文本账号。' }
        [void]$resetAccountControl.Items.Add([pscustomobject]@{Label='mhw20001_alias(mhw20001)';Value='mhw20001'})
        $resetAccountControl.SelectedIndex = 0
        if ([string](Get-FieldValue 'account') -ne 'mhw20001') { throw '重置单个账号密码未读取选中的精确调度账号。' }
        $script:DispatcherLookup = $null
        $nodeColorModel = New-PucResultModel -OperationLabel '新增人员' -Environment '10.161.30.163' -ExecutionNodes @(
            [pscustomobject]@{Label='人员新增预检';Status='running'},
            [pscustomobject]@{Label='新增人员';Status='completed'},
            [pscustomobject]@{Label='结果校验';Status='failed'}
        ) -StartedAt ([datetime]::Now.AddSeconds(-1)) -ViewState Progress
        Show-PucResultModel $nodeColorModel
        $nodeItems = @($resultFields.Items | Where-Object { $_.Text -in @('1.','2.','3.') })
        $nodeColors = @($nodeItems | ForEach-Object { $_.ForeColor.ToArgb() } | Sort-Object -Unique)
        if ($nodeItems.Count -ne 3 -or $nodeColors.Count -ne 3) { throw '执行节点的执行中、已完成和失败状态颜色未正确区分。' }
        $operationBox.SelectedItem = @($script:Operations | Where-Object Key -eq 'reset-query')[0]
        Rebuild-Inputs
        $confirmationOutputs = [Collections.Generic.List[string]]::new()
        $confirmationOutputs.Add('{"status":"preview","accounts":[{"account":"mhw1"},{"account":"mhw2"}]}')
        $script:ExecutionState = [pscustomobject]@{
            Environment='10.161.30.163';Operation='reset-query';Stage='batch-reset-preview';Handle=$null;PendingConfirmation=$null
            StartedAt=[datetime]::Now.AddSeconds(-2);Outputs=$confirmationOutputs;TempPaths=[Collections.Generic.List[string]]::new();Data=@{}
            ExecutionNodes=[Collections.Generic.List[object]]::new()
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
        if ($addressLabel.Bounds.IntersectsWith($versionLabel.Bounds) -or $versionLabel.Left -ne $environmentBox.Left -or $versionLabel.Top -le $addressLabel.Top -or $versionCompatibilityWarningLabel.Anchor -ne 'Top,Left' -or $versionCompatibilityWarningLabel.TextAlign -ne [Drawing.ContentAlignment]::TopLeft) { throw '版本信息行未显示在环境栏下方左侧。' }
        if ($versionLabel.Bounds.IntersectsWith($versionCompatibilityWarningLabel.Bounds)) { throw '版本号与兼容性提示发生重叠。' }
        if ([Windows.Forms.TextRenderer]::MeasureText($versionCompatibilityWarningLabel.Text,$versionCompatibilityWarningLabel.Font).Width -gt $versionCompatibilityWarningLabel.ClientSize.Width) { throw '版本兼容性提示文本显示不完整。' }
        if ($selectionPanel.Bottom -ne $inputPanel.Top) { throw '环境信息区与操作参数区布局不连续。' }
        if ($summaryTab.Text -ne '执行摘要' -or $resultTab.Text -ne '执行结果' -or $detailsTab.Text -ne '详细输出') { throw '结果标签页中文标题不正确。' }
        if ($resultGrid.Parent -ne $resultTab -or $resultLayout.RowCount -ne 2) { throw '摘要和结果未使用独立标签页布局。' }
        if ($resultFields.Items.Count -lt 3) { throw '结果摘要字段未渲染。' }
        if ($resultGrid.Rows.Count -ne 2) { throw '批量结果表格未渲染完整。' }
        if ($resultGrid.SelectionMode -ne [Windows.Forms.DataGridViewSelectionMode]::CellSelect -or -not $resultGrid.MultiSelect) { throw '执行结果表格未启用单元格多选。' }
        if ($resultGrid.ClipboardCopyMode -ne [Windows.Forms.DataGridViewClipboardCopyMode]::EnableWithoutHeaderText) { throw '执行结果表格未启用剪贴板复制。' }
        if ($resultGrid.ContextMenuStrip -ne $resultGridMenu -or $resultGridMenu.Items.Count -ne 2) { throw '执行结果表格复制菜单不完整。' }
        if ($resultGrid.Columns.Contains('group')) { throw '单一来源批量结果不应显示冗余分类列。' }
        if (-not $resultGrid.Columns.Contains('account') -or $resultGrid.Columns['account'].MinimumWidth -lt 140) { throw '账号列宽度不足。' }
        foreach ($compactName in @('stage1Result','stage2Result','writesUsed')) {
            if (-not $resultGrid.Columns.Contains($compactName) -or $resultGrid.Columns[$compactName].Width -gt 60) { throw "紧凑数值列宽度不正确：$compactName" }
        }
        if ($resultGrid.Columns['stage1Result'].HeaderText -ne '阶段 1 结果' -or $resultGrid.Columns['writesUsed'].HeaderText -ne '写入次数') { throw '结果列中文标题不正确。' }
        if ($detailsBox.Text -match 'UI-SECRET') { throw '详细输出包含未脱敏字段。' }
        if ($resultTabs.Height -lt 300 -or $resultLayout.RowStyles[1].SizeType -ne [Windows.Forms.SizeType]::Percent) { throw '执行摘要区域未使用完整可用高度。' }
        if ($resultTabs.Left -ne 24 -or $resultTabs.Right -ne ($form.ClientSize.Width - 24)) { throw '运行信息区域未与容器宽度保持一致。' }
        if ($null -eq $form.Icon -or -not $form.ShowIcon -or -not (Test-Path -LiteralPath $launcherIconPath -PathType Leaf)) { throw '主窗口未加载桌面快捷方式使用的 PUC Toolkit 图标。' }
        if ([PucTaskbarIdentity]::GetProcessIdentity() -ne $script:PucAppUserModelId -or [PucTaskbarIdentity]::GetWindowProperty($form.Handle,5) -ne $script:PucAppUserModelId -or [PucTaskbarIdentity]::GetWindowProperty($form.Handle,3) -ne $taskbarIconResource) { throw '任务栏未绑定 PUC Toolkit 的独立应用标识和图标资源。' }
        [pscustomobject]@{status='ui-self-test-passed';tabs=$resultTabs.TabPages.Count;summaryFields=$resultFields.Items.Count;detailRows=$resultGrid.Rows.Count;resultHeight=$resultTabs.Height;environmentVersionControl='passed';versionCompatibilityWarning='passed';summaryFullHeight='passed';resultContainerWidth='passed';windowIcon='passed';taskbarIdentity='passed';inputPanelRedraw='passed';responsiveInputColumns='passed';latestStageRows='passed';compactNumericColumns='passed';accountColumnWidth='passed';inlineConfirmation='passed';uploadVisibility='passed';actionBarLayout='passed';createPrefixDefault='empty';createCountDefault=1;personnelTypeDropdown='passed';dispatcherSearchDropdown='passed';dispatcherSearchEvent='passed';dispatcherSearchStatus='passed';updateAccountSearchDropdown='passed';updateAccountSearchSelection='passed';resetAccountSearchDropdown='passed';resetAccountSearchSelection='passed';executionNodeColors='passed';redundantGroupColumn='hidden'} | ConvertTo-Json -Compress
    } finally {
        $timer.Stop();$timer.Dispose();$form.Dispose()
        if ($null -ne $launcherIcon) { $launcherIcon.Dispose() }
    }
    return
}

try{
    $startupError = ''
    $rootInitialization = $null
    try {
        $rootInitialization = Initialize-PucLauncherConfigRoot
        Load-Environments
        $headerToolTip.SetToolTip($configPathButton,("当前配置路径：$($rootInitialization.ConfigRoot)"))
    } catch {
        $startupError = $_.Exception.Message
        $environmentBox.Items.Clear()
        $environmentBox.SelectedIndex = -1
        Update-EnvironmentAddress
    }
    Rebuild-Inputs
    Clear-PucResultView
    if (-not [string]::IsNullOrWhiteSpace($startupError)) {
        Show-PucStandaloneResult -OperationLabel '加载配置' -Environment '' -Stage '初始化配置路径' -Outputs @($startupError) -StartedAt ([datetime]::Now) -ViewState Finished -ExitCode 1
        $statusLabel.Text = '配置加载失败，请重新设置配置路径'
        $statusLabel.ForeColor = [Drawing.Color]::FromArgb(184,70,45)
    } elseif (Show-PendingSkillUpdateResult) {
        # The one-time update result already populated the status and summary.
    } elseif ($null -ne $rootInitialization -and $rootInitialization.Initialized) {
        $statusLabel.Text = '已自动初始化默认配置路径'
        $statusLabel.ForeColor = [Drawing.Color]::FromArgb(0,115,90)
    }
    [void]$form.ShowDialog()
}catch{
    [Windows.Forms.MessageBox]::Show($_.Exception.Message,'PUC Toolkit','OK','Error')|Out-Null
}finally{
    $timer.Stop();$timer.Dispose();$form.Dispose()
    if ($null -ne $launcherIcon) { $launcherIcon.Dispose() }
}
