function New-PucAppBusinessTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    foreach ($requiredKey in @('Form','ScriptRoot','GetConfigRoot','GetEnvironments','AddEnvironment','WriteLog')) {
        if (-not $Context.ContainsKey($requiredKey) -or $null -eq $Context[$requiredKey]) {
            throw "APP 业务页缺少上下文：$requiredKey"
        }
    }

    $styleButton = {
        param($Button, [bool]$Primary = $false)
        $Button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
        $Button.UseVisualStyleBackColor = $false
        $Button.Cursor = [Windows.Forms.Cursors]::Hand
        if ($Primary) {
            $Button.BackColor = [Drawing.Color]::FromArgb(0,134,126)
            $Button.ForeColor = [Drawing.Color]::White
            $Button.FlatAppearance.BorderSize = 0
            $Button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(0,116,109)
            $Button.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(0,96,90)
        } else {
            $Button.BackColor = [Drawing.Color]::White
            $Button.ForeColor = [Drawing.Color]::FromArgb(28,37,44)
            $Button.FlatAppearance.BorderSize = 1
            $Button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(190,197,202)
            $Button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(232,243,242)
            $Button.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(214,234,232)
        }
    }

    $tab = New-Object Windows.Forms.TabPage
    $tab.Text = 'APP 业务'
    $tab.BackColor = [Drawing.Color]::FromArgb(246,248,250)

    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = [Windows.Forms.DockStyle]::Fill
    $layout.Padding = New-Object Windows.Forms.Padding(20,14,20,14)
    $layout.ColumnCount = 2
    $layout.RowCount = 3
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,92)))
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,196)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,42)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
    $tab.Controls.Add($layout)

    $loginGroup = New-Object Windows.Forms.GroupBox
    $loginGroup.Text = 'APP 登录'
    $loginGroup.Dock = [Windows.Forms.DockStyle]::Fill
    $loginGroup.Margin = New-Object Windows.Forms.Padding(0,0,0,8)
    $layout.Controls.Add($loginGroup,0,0)
    $layout.SetColumnSpan($loginGroup,2)

    $loginLayout = New-Object Windows.Forms.TableLayoutPanel
    $loginLayout.Dock = [Windows.Forms.DockStyle]::Fill
    $loginLayout.Padding = New-Object Windows.Forms.Padding(12,8,12,7)
    $loginLayout.ColumnCount = 4
    $loginLayout.RowCount = 5
    [void]$loginLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,82)))
    [void]$loginLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,44)))
    [void]$loginLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,82)))
    [void]$loginLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,56)))
    foreach ($height in @(34,34,34,38,24)) {
        [void]$loginLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,$height)))
    }
    $loginGroup.Controls.Add($loginLayout)

    $environmentLabel = New-Object Windows.Forms.Label
    $environmentLabel.Text = '服务器环境'
    $environmentLabel.AutoSize = $true
    $environmentLabel.Anchor = 'Left'
    $loginLayout.Controls.Add($environmentLabel,0,0)

    $environmentPanel = New-Object Windows.Forms.TableLayoutPanel
    $environmentPanel.Dock = [Windows.Forms.DockStyle]::Fill
    $environmentPanel.Margin = New-Object Windows.Forms.Padding(0)
    $environmentPanel.ColumnCount = 2
    $environmentPanel.RowCount = 1
    [void]$environmentPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
    [void]$environmentPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,96)))

    $environmentBox = New-Object Windows.Forms.ComboBox
    $environmentBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $environmentBox.DisplayMember = 'Name'
    $environmentBox.Dock = [Windows.Forms.DockStyle]::Fill
    $environmentBox.Margin = New-Object Windows.Forms.Padding(3,4,8,4)
    $environmentPanel.Controls.Add($environmentBox,0,0)

    $addEnvironmentButton = New-Object Windows.Forms.Button
    $addEnvironmentButton.Text = '新增环境'
    $addEnvironmentButton.Dock = [Windows.Forms.DockStyle]::Fill
    $addEnvironmentButton.Margin = New-Object Windows.Forms.Padding(0,1,0,1)
    & $styleButton $addEnvironmentButton $false
    $environmentPanel.Controls.Add($addEnvironmentButton,1,0)
    $loginLayout.Controls.Add($environmentPanel,1,0)
    $loginLayout.SetColumnSpan($environmentPanel,3)

    $serverLabel = New-Object Windows.Forms.Label
    $serverLabel.Text = '服务器地址'
    $serverLabel.AutoSize = $true
    $serverLabel.Anchor = 'Left'
    $loginLayout.Controls.Add($serverLabel,0,1)

    $serverBox = New-Object Windows.Forms.TextBox
    $serverBox.Dock = [Windows.Forms.DockStyle]::Fill
    $serverBox.Margin = New-Object Windows.Forms.Padding(3,5,8,5)
    $serverBox.ReadOnly = $true
    $loginLayout.Controls.Add($serverBox,1,1)
    $loginLayout.SetColumnSpan($serverBox,2)

    $followEnvironmentBox = New-Object Windows.Forms.CheckBox
    $followEnvironmentBox.Text = '跟随所选环境'
    $followEnvironmentBox.Checked = $true
    $followEnvironmentBox.AutoSize = $true
    $followEnvironmentBox.Anchor = 'Left'
    $loginLayout.Controls.Add($followEnvironmentBox,3,1)

    $accountLabel = New-Object Windows.Forms.Label
    $accountLabel.Text = 'APP 账号'
    $accountLabel.AutoSize = $true
    $accountLabel.Anchor = 'Left'
    $loginLayout.Controls.Add($accountLabel,0,2)

    $accountBox = New-Object Windows.Forms.TextBox
    $accountBox.Dock = [Windows.Forms.DockStyle]::Fill
    $accountBox.Margin = New-Object Windows.Forms.Padding(3,5,10,5)
    $loginLayout.Controls.Add($accountBox,1,2)

    $passwordLabel = New-Object Windows.Forms.Label
    $passwordLabel.Text = 'APP 密码'
    $passwordLabel.AutoSize = $true
    $passwordLabel.Anchor = 'Left'
    $loginLayout.Controls.Add($passwordLabel,2,2)

    $passwordBox = New-Object Windows.Forms.TextBox
    $passwordBox.Dock = [Windows.Forms.DockStyle]::Fill
    $passwordBox.Margin = New-Object Windows.Forms.Padding(3,5,3,5)
    $passwordBox.UseSystemPasswordChar = $true
    $loginLayout.Controls.Add($passwordBox,3,2)

    $loginActionPanel = New-Object Windows.Forms.TableLayoutPanel
    $loginActionPanel.Dock = [Windows.Forms.DockStyle]::Fill
    $loginActionPanel.Margin = New-Object Windows.Forms.Padding(0)
    $loginActionPanel.ColumnCount = 4
    $loginActionPanel.RowCount = 1
    [void]$loginActionPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,96)))
    [void]$loginActionPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,156)))
    [void]$loginActionPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,190)))
    [void]$loginActionPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
    $loginLayout.Controls.Add($loginActionPanel,0,3)
    $loginLayout.SetColumnSpan($loginActionPanel,4)

    $loginButton = New-Object Windows.Forms.Button
    $loginButton.Text = '登录'
    $loginButton.Dock = [Windows.Forms.DockStyle]::Fill
    $loginButton.Margin = New-Object Windows.Forms.Padding(0,2,8,2)
    & $styleButton $loginButton $true
    $loginActionPanel.Controls.Add($loginButton,0,0)

    $onlineLabel = New-Object Windows.Forms.Label
    $onlineLabel.Text = '在线状态：未登录'
    $onlineLabel.AutoSize = $true
    $onlineLabel.ForeColor = [Drawing.Color]::FromArgb(92,102,110)
    $onlineLabel.Anchor = 'Left'
    $onlineLabel.Margin = New-Object Windows.Forms.Padding(8,0,0,0)
    $loginActionPanel.Controls.Add($onlineLabel,1,0)

    $heartbeatLabel = New-Object Windows.Forms.Label
    $heartbeatLabel.Text = '心跳状态：未收到'
    $heartbeatLabel.AutoSize = $true
    $heartbeatLabel.ForeColor = [Drawing.Color]::FromArgb(92,102,110)
    $heartbeatLabel.Anchor = 'Left'
    $loginActionPanel.Controls.Add($heartbeatLabel,2,0)

    $sessionLabel = New-Object Windows.Forms.Label
    $sessionLabel.Text = '当前账号：-    APP PUC ID：-'
    $sessionLabel.AutoSize = $true
    $sessionLabel.AutoEllipsis = $true
    $sessionLabel.ForeColor = [Drawing.Color]::FromArgb(92,102,110)
    $sessionLabel.Anchor = 'Left'
    $loginActionPanel.Controls.Add($sessionLabel,3,0)

    $hintLabel = New-Object Windows.Forms.Label
    $hintLabel.Text = '请选择环境并登录。'
    $hintLabel.ForeColor = [Drawing.Color]::FromArgb(92,102,110)
    $hintLabel.AutoEllipsis = $true
    $hintLabel.Dock = [Windows.Forms.DockStyle]::Fill
    $hintLabel.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
    $loginLayout.Controls.Add($hintLabel,0,4)
    $loginLayout.SetColumnSpan($hintLabel,4)

    $businessLabel = New-Object Windows.Forms.Label
    $businessLabel.Text = '业务功能'
    $businessLabel.AutoSize = $true
    $businessLabel.Anchor = 'Left'
    $layout.Controls.Add($businessLabel,0,1)

    $businessBox = New-Object Windows.Forms.ComboBox
    $businessBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $businessBox.DisplayMember = 'Label'
    $businessBox.ValueMember = 'Key'
    $businessBox.Dock = [Windows.Forms.DockStyle]::Fill
    $businessBox.Margin = New-Object Windows.Forms.Padding(3,7,3,7)
    [void]$businessBox.Items.Add([pscustomobject]@{Key='group-batch';Label='批量建群'})
    $businessBox.SelectedIndex = 0
    $layout.Controls.Add($businessBox,1,1)

    $batchPanel = New-Object Windows.Forms.TableLayoutPanel
    $batchPanel.Dock = [Windows.Forms.DockStyle]::Fill
    $batchPanel.Margin = New-Object Windows.Forms.Padding(0,4,0,0)
    $batchPanel.ColumnCount = 1
    $batchPanel.RowCount = 3
    [void]$batchPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,38)))
    [void]$batchPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,24)))
    [void]$batchPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
    $layout.Controls.Add($batchPanel,0,2)
    $layout.SetColumnSpan($batchPanel,2)

    $batchToolbar = New-Object Windows.Forms.FlowLayoutPanel
    $batchToolbar.Dock = [Windows.Forms.DockStyle]::Fill
    $batchToolbar.WrapContents = $false
    $batchToolbar.Margin = New-Object Windows.Forms.Padding(0)

    $groupCountLabel = New-Object Windows.Forms.Label
    $groupCountLabel.Text = '群数量'
    $groupCountLabel.AutoSize = $true
    $groupCountLabel.Margin = New-Object Windows.Forms.Padding(0,9,4,0)
    $batchToolbar.Controls.Add($groupCountLabel)

    $groupCountInput = New-Object Windows.Forms.NumericUpDown
    $groupCountInput.Minimum = 1
    $groupCountInput.Maximum = 10000
    $groupCountInput.Value = 1
    $groupCountInput.Width = 72
    $groupCountInput.Margin = New-Object Windows.Forms.Padding(0,5,12,0)
    $batchToolbar.Controls.Add($groupCountInput)

    $addMemberButton = New-Object Windows.Forms.Button
    $addMemberButton.Text = '添加成员'
    $addMemberButton.AccessibleName = 'Select dispatchers'
    $addMemberButton.AutoSize = $true
    $addMemberButton.Margin = New-Object Windows.Forms.Padding(0,2,6,2)
    & $styleButton $addMemberButton $false
    $batchToolbar.Controls.Add($addMemberButton)

    $removeMemberButton = New-Object Windows.Forms.Button
    $removeMemberButton.Text = '删除成员'
    $removeMemberButton.AutoSize = $true
    $removeMemberButton.Margin = New-Object Windows.Forms.Padding(0,2,12,2)
    & $styleButton $removeMemberButton $false
    $batchToolbar.Controls.Add($removeMemberButton)

    $batchButton = New-Object Windows.Forms.Button
    $batchButton.Text = '开始批量建群'
    $batchButton.Enabled = $false
    $batchButton.AutoSize = $true
    $batchButton.Margin = New-Object Windows.Forms.Padding(0,2,0,2)
    & $styleButton $batchButton $true
    $batchToolbar.Controls.Add($batchButton)
    $batchPanel.Controls.Add($batchToolbar,0,0)

    $batchProgressLabel = New-Object Windows.Forms.Label
    $batchProgressLabel.Text = '等待执行'
    $batchProgressLabel.ForeColor = [Drawing.Color]::FromArgb(92,102,110)
    $batchProgressLabel.Dock = [Windows.Forms.DockStyle]::Fill
    $batchProgressLabel.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
    $batchPanel.Controls.Add($batchProgressLabel,0,1)

    $batchSplit = New-Object Windows.Forms.SplitContainer
    $batchSplit.Dock = [Windows.Forms.DockStyle]::Fill
    $batchSplit.Orientation = [Windows.Forms.Orientation]::Vertical
    $batchSplit.SplitterDistance = 260
    $batchSplit.Margin = New-Object Windows.Forms.Padding(0)
    $batchPanel.Controls.Add($batchSplit,0,2)

    $memberGrid = New-Object Windows.Forms.DataGridView
    $memberGrid.Dock = [Windows.Forms.DockStyle]::Fill
    $memberGrid.AllowUserToAddRows = $false
    $memberGrid.AllowUserToDeleteRows = $false
    $memberGrid.AllowUserToResizeRows = $false
    $memberGrid.RowHeadersVisible = $false
    $memberGrid.MultiSelect = $true
    $memberGrid.SelectionMode = [Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $memberGrid.BackgroundColor = [Drawing.Color]::White
    $memberGrid.AutoSizeColumnsMode = [Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    [void]$memberGrid.Columns.Add('account','成员账号')
    [void]$memberGrid.Columns.Add('app_puc_id','APP PUC ID')
    [void]$memberGrid.Rows.Add()
    $batchSplit.Panel1.Controls.Add($memberGrid)

    $resultGrid = New-Object Windows.Forms.DataGridView
    $resultGrid.Dock = [Windows.Forms.DockStyle]::Fill
    $resultGrid.ReadOnly = $true
    $resultGrid.AllowUserToAddRows = $false
    $resultGrid.AllowUserToDeleteRows = $false
    $resultGrid.AllowUserToResizeRows = $false
    $resultGrid.RowHeadersVisible = $false
    $resultGrid.MultiSelect = $false
    $resultGrid.SelectionMode = [Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $resultGrid.BackgroundColor = [Drawing.Color]::White
    foreach ($column in @(
        @('index','序号'),@('group_id','群 ID'),@('final_subject','最终群名'),
        @('create_code','创建码'),@('rename_code','改名码'),@('status','状态')
    )) { [void]$resultGrid.Columns.Add($column[0],$column[1]) }
    $resultGrid.Columns['index'].Width = 48
    $resultGrid.Columns['group_id'].Width = 82
    $resultGrid.Columns['final_subject'].AutoSizeMode = [Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $resultGrid.Columns['create_code'].Width = 62
    $resultGrid.Columns['rename_code'].Width = 62
    $resultGrid.Columns['status'].Width = 100
    $batchSplit.Panel2.Controls.Add($resultGrid)

    $state = [pscustomobject]@{
        Disposed=$false
        UpdatingAddress=$false
        LoadingEnvironments=$false
        BridgeProcess=$null
        BridgeOutputTask=$null
        BridgeErrorTask=$null
        BridgeErrorText=[Text.StringBuilder]::new()
        LoginActive=$false
        LoginOnline=$false
        LastLoginError=''
        LoginGeneration=0
        BatchRunning=$false
        BatchGeneration=0
        PollTimer=$null
        RefreshAction=$null
        PollAction=$null
        DisposeAction=$null
        UpdateAddressAction=$null
        UpdateBatchControlsAction=$null
        SetLoginLifecycleAction=$null
        SendCommandAction=$null
        StartBridgeAction=$null
        StopBridgeAction=$null
        ReceiveMessageAction=$null
        StartBatchAction=$null
        StartLoginAction=$null
        AddMembersAction=$null
        ShowMemberPickerAction=$null
    }

    $getValue = {
        param($Object, [string]$Name)
        if ($null -eq $Object) { return $null }
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        return $property.Value
    }.GetNewClosure()

    $addMembers = {
        param($Members, [Parameter(ValueFromRemainingArguments)]$RemainingMembers)
        $selectedMembers = @($Members) + @($RemainingMembers)
        $existing = @{}
        foreach ($row in @($memberGrid.Rows)) {
            if ($row.IsNewRow) { continue }
            $account = ([string]$row.Cells['account'].Value).Trim()
            if (-not [string]::IsNullOrWhiteSpace($account)) { $existing[$account.ToLowerInvariant()] = $true }
        }
        foreach ($member in $selectedMembers) {
            $account = ([string](& $getValue $member 'account')).Trim()
            $appPucId = ([string](& $getValue $member 'appPucId')).Trim()
            if ([string]::IsNullOrWhiteSpace($account) -or [string]::IsNullOrWhiteSpace($appPucId)) { continue }
            $key = $account.ToLowerInvariant()
            if ($existing.ContainsKey($key)) { continue }
            $emptyRow = @($memberGrid.Rows | Where-Object {
                -not $_.IsNewRow -and [string]::IsNullOrWhiteSpace([string]$_.Cells['account'].Value) -and
                [string]::IsNullOrWhiteSpace([string]$_.Cells['app_puc_id'].Value)
            } | Select-Object -First 1)
            if ($emptyRow.Count -eq 1) {
                $emptyRow[0].Cells['account'].Value = $account
                $emptyRow[0].Cells['app_puc_id'].Value = $appPucId
            } else {
                [void]$memberGrid.Rows.Add($account,$appPucId)
            }
            $existing[$key] = $true
        }
    }.GetNewClosure()
    $state.AddMembersAction = $addMembers

    $resolveConfigRoot = {
        $configRoot = [string](& $Context.GetConfigRoot)
        if ([string]::IsNullOrWhiteSpace($configRoot)) { throw 'PUC 配置路径为空，请先设置配置路径。' }
        return $configRoot
    }.GetNewClosure()

    $reportSearchError = {
        param([string]$Message)
        if ([string]::IsNullOrWhiteSpace($Message)) { $Message = '未知搜索错误' }
        & $Context['WriteLog'] 'APP业务' "[member-search-error] $Message"
    }.GetNewClosure()

    $showMemberPicker = {
        if ($null -eq $environmentBox.SelectedItem) { throw '请先选择服务器环境。' }
        $environmentName = [string]$environmentBox.SelectedItem.Name
        $configRoot = & $resolveConfigRoot
        $dialog = New-Object Windows.Forms.Form
        $dialog.Text = '选择调度员'
        $dialog.StartPosition = [Windows.Forms.FormStartPosition]::CenterParent
        $dialog.Size = New-Object Drawing.Size(720,520)
        $dialog.MinimumSize = New-Object Drawing.Size(620,420)
        $dialog.ShowInTaskbar = $false

        $pickerLayout = New-Object Windows.Forms.TableLayoutPanel
        $pickerLayout.Dock = [Windows.Forms.DockStyle]::Fill
        $pickerLayout.Padding = New-Object Windows.Forms.Padding(12)
        $pickerLayout.ColumnCount = 1
        $pickerLayout.RowCount = 3
        [void]$pickerLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,42)))
        [void]$pickerLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
        [void]$pickerLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,44)))
        $dialog.Controls.Add($pickerLayout)

        $searchPanel = New-Object Windows.Forms.TableLayoutPanel
        $searchPanel.Dock = [Windows.Forms.DockStyle]::Fill
        $searchPanel.ColumnCount = 3
        [void]$searchPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
        [void]$searchPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,88)))
        [void]$searchPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,150)))
        $queryBox = New-Object Windows.Forms.TextBox
        $queryBox.Dock = [Windows.Forms.DockStyle]::Fill
        $queryBox.Margin = New-Object Windows.Forms.Padding(0,5,8,5)
        $searchPanel.Controls.Add($queryBox,0,0)
        $searchButton = New-Object Windows.Forms.Button
        $searchButton.Text = '搜索'
        $searchButton.Dock = [Windows.Forms.DockStyle]::Fill
        $searchButton.Margin = New-Object Windows.Forms.Padding(0,2,8,2)
        & $styleButton $searchButton $false
        $searchPanel.Controls.Add($searchButton,1,0)
        $searchStatus = New-Object Windows.Forms.Label
        $searchStatus.Text = '输入账号或名称搜索'
        $searchStatus.AutoEllipsis = $true
        $searchStatus.Dock = [Windows.Forms.DockStyle]::Fill
        $searchStatus.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
        $searchPanel.Controls.Add($searchStatus,2,0)
        $pickerLayout.Controls.Add($searchPanel,0,0)

        $pickerGrid = New-Object Windows.Forms.DataGridView
        $pickerGrid.Dock = [Windows.Forms.DockStyle]::Fill
        $pickerGrid.AllowUserToAddRows = $false
        $pickerGrid.AllowUserToDeleteRows = $false
        $pickerGrid.RowHeadersVisible = $false
        $pickerGrid.SelectionMode = [Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
        $pickerGrid.MultiSelect = $true
        $pickerGrid.AutoSizeColumnsMode = [Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
        $checkColumn = New-Object Windows.Forms.DataGridViewCheckBoxColumn
        $checkColumn.Name = 'selected'; $checkColumn.HeaderText = '选择'; $checkColumn.Width = 52
        $checkColumn.AutoSizeMode = [Windows.Forms.DataGridViewAutoSizeColumnMode]::None
        [void]$pickerGrid.Columns.Add($checkColumn)
        [void]$pickerGrid.Columns.Add('name','名称')
        [void]$pickerGrid.Columns.Add('account','调度账号')
        [void]$pickerGrid.Columns.Add('app_puc_id','APP PUC ID')
        $pickerGrid.Columns['app_puc_id'].Width = 110
        $pickerLayout.Controls.Add($pickerGrid,0,1)

        $buttonPanel = New-Object Windows.Forms.FlowLayoutPanel
        $buttonPanel.Dock = [Windows.Forms.DockStyle]::Fill
        $buttonPanel.FlowDirection = [Windows.Forms.FlowDirection]::RightToLeft
        $confirmButton = New-Object Windows.Forms.Button
        $confirmButton.Text = '添加所选'; $confirmButton.Width = 96; $confirmButton.Height = 34
        & $styleButton $confirmButton $true
        $cancelButton = New-Object Windows.Forms.Button
        $cancelButton.Text = '取消'; $cancelButton.Width = 88; $cancelButton.Height = 34
        $cancelButton.DialogResult = [Windows.Forms.DialogResult]::Cancel
        & $styleButton $cancelButton $false
        $buttonPanel.Controls.Add($confirmButton); $buttonPanel.Controls.Add($cancelButton)
        $pickerLayout.Controls.Add($buttonPanel,0,2)
        $dialog.CancelButton = $cancelButton

        $runSearch = {
            $query = $queryBox.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($query)) { $searchStatus.Text = '请输入搜索关键字'; return }
            $searchButton.Enabled = $false
            $searchStatus.Text = '查询中...'
            $pickerGrid.Rows.Clear()
            try {
                $searchScript = Join-Path ([string]$Context.ScriptRoot) 'Invoke-PucAppMemberSearch.ps1'
                $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $searchScript -Environment $environmentName -Query $query -ConfigRoot $configRoot 2>&1)
                if ($LASTEXITCODE -ne 0) { throw (($lines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) }
                $result = $null
                for ($index = $lines.Count - 1; $index -ge 0; $index--) {
                    try { $result = ([string]$lines[$index]) | ConvertFrom-Json; break } catch {}
                }
                if ($null -eq $result) { throw '调度员搜索未返回有效结果。' }
                foreach ($item in @($result.results)) {
                    [void]$pickerGrid.Rows.Add($false,[string]$item.name,[string]$item.account,[string]$item.appPucId)
                }
                $searchStatus.Text = if ($pickerGrid.Rows.Count -eq 0) { '未找到匹配调度员' } else { "找到 $($pickerGrid.Rows.Count) 个调度员" }
            } catch {
                $searchStatus.Text = '查询失败'
                $errorMessage = $_.Exception.Message
                & $reportSearchError $errorMessage
                [Windows.Forms.MessageBox]::Show($dialog,$errorMessage,'搜索调度员','OK','Warning') | Out-Null
            } finally { $searchButton.Enabled = $true }
        }.GetNewClosure()
        $searchButton.Add_Click($runSearch)
        $queryBox.Add_KeyDown(({
            param($sender,$eventArgs)
            if ($eventArgs.KeyCode -eq [Windows.Forms.Keys]::Enter) { $eventArgs.SuppressKeyPress = $true; & $runSearch }
        }.GetNewClosure()))
        $pickerGrid.Add_CellDoubleClick(({
            param($sender,$eventArgs)
            if ($eventArgs.RowIndex -ge 0) { $row = $pickerGrid.Rows[$eventArgs.RowIndex]; $row.Cells['selected'].Value = -not [bool]$row.Cells['selected'].Value }
        }.GetNewClosure()))
        $confirmButton.Add_Click(({
            $pickerGrid.EndEdit()
            $selected = @($pickerGrid.Rows | Where-Object { [bool]$_.Cells['selected'].Value } | ForEach-Object {
                [pscustomobject]@{account=[string]$_.Cells['account'].Value;appPucId=[string]$_.Cells['app_puc_id'].Value}
            })
            if ($selected.Count -eq 0) { $searchStatus.Text = '请至少选择一个调度员'; return }
            & $addMembers $selected
            $dialog.DialogResult = [Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }.GetNewClosure()))
        try { [void]$dialog.ShowDialog($Context.Form) } finally { $dialog.Dispose() }
    }.GetNewClosure()
    $state.ShowMemberPickerAction = $showMemberPicker

    $setServerAddress = {
        param([string]$Address)
        $state.UpdatingAddress = $true
        try { $serverBox.Text = $Address } finally { $state.UpdatingAddress = $false }
    }.GetNewClosure()

    $convertServerAddress = {
        param([string]$BaseUrl)
        try { $sourceUri = [uri]$BaseUrl } catch { throw "APP 环境地址无效：$BaseUrl" }
        if (-not $sourceUri.IsAbsoluteUri -or $sourceUri.Scheme -notin @('http','https') -or [string]::IsNullOrWhiteSpace($sourceUri.Host)) {
            throw "APP 环境地址必须是完整的 HTTP 或 HTTPS URL：$BaseUrl"
        }
        $builder = [UriBuilder]::new($sourceUri)
        $builder.Port = 16663
        $builder.UserName = ''
        $builder.Password = ''
        $builder.Query = ''
        $builder.Fragment = ''
        $address = $builder.Uri.GetLeftPart([UriPartial]::Path)
        if ($sourceUri.AbsolutePath -eq '/') { return $address.TrimEnd('/') }
        return $address
    }.GetNewClosure()

    $updateAddress = {
        if ($state.LoadingEnvironments) { return }
        if ($null -eq $environmentBox.SelectedItem) {
            & $setServerAddress ''
            return
        }
        if ($followEnvironmentBox.Checked) {
            & $setServerAddress (& $convertServerAddress ([string]$environmentBox.SelectedItem.BaseUrl))
        }
    }.GetNewClosure()
    $state.UpdateAddressAction = $updateAddress

    $refresh = {
        param([string]$PreferredName = '')
        if ($state.Disposed) { return }
        $selectedName = if (-not [string]::IsNullOrWhiteSpace($PreferredName)) {
            $PreferredName
        } elseif ($null -ne $environmentBox.SelectedItem) {
            [string]$environmentBox.SelectedItem.Name
        } else { '' }
        $manualAddress = $serverBox.Text
        $state.LoadingEnvironments = $true
        try {
            $environmentBox.Items.Clear()
            foreach ($entry in @(& $Context.GetEnvironments)) {
                if ($null -ne $entry) { [void]$environmentBox.Items.Add($entry) }
            }
            $selectedIndex = if ($environmentBox.Items.Count -gt 0) { 0 } else { -1 }
            for ($index = 0; $index -lt $environmentBox.Items.Count; $index++) {
                if ([string]$environmentBox.Items[$index].Name -eq $selectedName) { $selectedIndex = $index; break }
            }
            $environmentBox.SelectedIndex = $selectedIndex
        } finally { $state.LoadingEnvironments = $false }
        if ($followEnvironmentBox.Checked) { & $updateAddress } else { & $setServerAddress $manualAddress }
    }.GetNewClosure()
    $state.RefreshAction = $refresh

    $updateBatchControls = {
        $editable = -not $state.BatchRunning
        $memberGrid.Enabled = $editable
        $groupCountInput.Enabled = $editable
        $addMemberButton.Enabled = $editable
        $removeMemberButton.Enabled = $editable
        $batchButton.Enabled = $state.LoginOnline -and $editable
    }.GetNewClosure()
    $state.UpdateBatchControlsAction = $updateBatchControls

    $setBatchRunning = {
        param([bool]$Running, [string]$Message = '')
        $state.BatchRunning = $Running
        if (-not [string]::IsNullOrWhiteSpace($Message)) { $batchProgressLabel.Text = $Message }
        & $updateBatchControls
    }.GetNewClosure()

    $setResultRow = {
        param($Result)
        if ($null -eq $Result) { return }
        $indexValue = & $getValue $Result 'index'
        if ($null -eq $indexValue) { return }
        $existingRow = @($resultGrid.Rows | Where-Object { [string]$_.Cells['index'].Value -eq [string]$indexValue } | Select-Object -First 1)
        if ($existingRow.Count -eq 0) {
            $rowIndex = $resultGrid.Rows.Add()
            $targetRow = $resultGrid.Rows[$rowIndex]
        } else { $targetRow = $existingRow[0] }
        foreach ($name in @('index','group_id','final_subject','create_code','rename_code','status')) {
            $value = & $getValue $Result $name
            $targetRow.Cells[$name].Value = if ($null -eq $value) { '' } else { [string]$value }
        }
    }.GetNewClosure()

    $showBatchProgress = {
        param($Progress)
        if ($null -eq $Progress) { return }
        $eventName = [string](& $getValue $Progress 'event')
        $indexValue = & $getValue $Progress 'index'
        $displayIndex = if ($null -eq $indexValue) { '' } else { [int]$indexValue + 1 }
        $batchProgressLabel.Text = switch ($eventName) {
            'batch_started' { '批量建群已开始' }
            'group_creating' { "正在创建第 $displayIndex 个群" }
            'group_created' { "第 $displayIndex 个群已创建，准备修改群名" }
            'group_renaming' { "正在修改第 $displayIndex 个群的名称" }
            'group_completed' { "第 $displayIndex 个群处理完成" }
            'group_failed' { "第 $displayIndex 个群处理失败" }
            'session_unavailable' { "第 $displayIndex 个群因会话不可用而跳过" }
            'batch_completed' { '批量建群正在汇总结果' }
            default { '批量建群处理中' }
        }
        & $setResultRow (& $getValue $Progress 'result')
    }.GetNewClosure()

    $showBatchSummary = {
        param($Summary)
        if ($null -eq $Summary) { & $setBatchRunning $false '批量建群已结束，但未返回汇总。'; return }
        $resultGrid.Rows.Clear()
        foreach ($result in @(& $getValue $Summary 'results')) { & $setResultRow $result }
        $renamed = [int](& $getValue $Summary 'renamed_count')
        $renameFailed = [int](& $getValue $Summary 'rename_failed_count')
        $createFailed = [int](& $getValue $Summary 'create_failed_count')
        $unavailable = [int](& $getValue $Summary 'session_unavailable_count')
        & $setBatchRunning $false "完成：成功 $renamed，改名失败 $renameFailed，创建失败 $createFailed，会话不可用 $unavailable"
    }.GetNewClosure()

    $setLoginLifecycle = {
        param([string]$EventName, [string]$Message = '', $Session = $null)
        if ($EventName -eq 'message') {
            if (-not [string]::IsNullOrWhiteSpace($Message)) {
                $hintLabel.Text = $Message
                & $Context['WriteLog'] 'APP业务' "[$EventName] $Message"
            }
            return
        }
        $labels = @{
            connecting='正在连接';token_acquired='已获取令牌';websocket_connected='WebSocket 已连接'
            login_success='在线';reconnecting='正在重连';disconnected='已断开';error='错误';stopped='已停止'
        }
        if (-not $labels.ContainsKey($EventName)) { return }
        if ($EventName -eq 'error' -and -not [string]::IsNullOrWhiteSpace($Message)) {
            $state.LastLoginError = $Message
        } elseif ($EventName -in @('connecting','token_acquired','websocket_connected','login_success')) {
            $state.LastLoginError = ''
        } elseif ($EventName -eq 'stopped') {
            if ($Message -eq 'client stopped' -and -not [string]::IsNullOrWhiteSpace($state.LastLoginError)) {
                $Message = $state.LastLoginError
            } else {
                $state.LastLoginError = ''
            }
        }
        $logMessage = if ([string]::IsNullOrWhiteSpace($Message)) { [string]$labels[$EventName] } else { $Message }
        & $Context['WriteLog'] 'APP业务' "[$EventName] $logMessage"
        $state.LoginOnline = $EventName -eq 'login_success'
        $state.LoginActive = $EventName -in @('connecting','token_acquired','websocket_connected','login_success','reconnecting','disconnected','error')
        $onlineLabel.Text = "在线状态：$($labels[$EventName])"
        $onlineLabel.ForeColor = if ($state.LoginOnline) {
            [Drawing.Color]::FromArgb(0,115,90)
        } elseif ($EventName -eq 'error') {
            [Drawing.Color]::FromArgb(184,70,45)
        } else { [Drawing.Color]::FromArgb(92,102,110) }
        if ($EventName -in @('disconnected','error','stopped')) {
            $heartbeatLabel.Text = '心跳状态：未连接'
            $heartbeatLabel.ForeColor = [Drawing.Color]::FromArgb(92,102,110)
        }
        $loginButton.Text = if ($state.LoginActive) { '停止' } else { '登录' }
        $accountBox.Enabled = -not $state.LoginActive
        $passwordBox.Enabled = -not $state.LoginActive
        $serverBox.Enabled = -not $state.LoginActive
        $serverBox.ReadOnly = $followEnvironmentBox.Checked -or $state.LoginActive
        $environmentBox.Enabled = -not $state.LoginActive
        $followEnvironmentBox.Enabled = -not $state.LoginActive
        $addEnvironmentButton.Enabled = -not $state.LoginActive
        if ($state.LoginOnline -and $null -ne $Session) {
            $sessionAccount = [string](& $getValue $Session 'account')
            $appPucId = [string](& $getValue $Session 'app_puc_id')
            $sessionLabel.Text = "当前账号：$sessionAccount    APP PUC ID：$appPucId"
        } else { $sessionLabel.Text = '当前账号：-    APP PUC ID：-' }
        if (-not [string]::IsNullOrWhiteSpace($Message)) { $hintLabel.Text = $Message }
        & $updateBatchControls
    }.GetNewClosure()
    $state.SetLoginLifecycleAction = $setLoginLifecycle

    $getPythonCommand = {
        if (-not [string]::IsNullOrWhiteSpace($env:PUC_PYTHON_EXE) -and (Test-Path -LiteralPath $env:PUC_PYTHON_EXE -PathType Leaf)) {
            return $env:PUC_PYTHON_EXE
        }
        $command = Get-Command python.exe,python -ErrorAction SilentlyContinue |
            Where-Object { $_.Source -notlike '*\WindowsApps\*' } |
            Select-Object -First 1
        if ($null -eq $command) { throw '未找到可用的 Python。请安装 Python 并确保 python 命令可用。' }
        return $command.Source
    }.GetNewClosure()

    $sendCommand = {
        param($Command)
        $process = $state.BridgeProcess
        if ($null -eq $process -or $process.HasExited) { throw 'APP 登录组件未运行。' }
        $process.StandardInput.WriteLine(($Command | ConvertTo-Json -Compress -Depth 10))
        $process.StandardInput.Flush()
    }.GetNewClosure()
    $state.SendCommandAction = $sendCommand

    $startBridge = {
        if ($null -ne $state.BridgeProcess -and -not $state.BridgeProcess.HasExited) { return }
        $python = & $getPythonCommand
        $bridgePath = Join-Path ([string]$Context.ScriptRoot) 'AppPucBridge.py'
        if (-not (Test-Path -LiteralPath $bridgePath -PathType Leaf)) { throw "APP 登录组件不存在：$bridgePath" }
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $python
        $startInfo.Arguments = '-u "' + $bridgePath + '"'
        $startInfo.WorkingDirectory = Split-Path -Parent (Split-Path -Parent ([string]$Context.ScriptRoot))
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'APP 登录组件启动失败。' }
        $state.BridgeProcess = $process
        $state.BridgeErrorText.Clear() | Out-Null
        $state.BridgeOutputTask = $process.StandardOutput.ReadLineAsync()
        $state.BridgeErrorTask = $process.StandardError.ReadLineAsync()
    }.GetNewClosure()
    $state.StartBridgeAction = $startBridge

    $stopBridge = {
        param([bool]$Close = $false)
        $process = $state.BridgeProcess
        if ($null -eq $process) { return }
        if (-not $process.HasExited) {
            try { & $sendCommand @{command='stop'} } catch {}
            if ($Close) {
                try { $process.StandardInput.Close() } catch {}
                try { if (-not $process.HasExited) { $process.Kill() } } catch {}
            }
        }
        if ($Close) {
            try { $process.Dispose() } catch {}
            $state.BridgeProcess = $null
            $state.BridgeOutputTask = $null
            $state.BridgeErrorTask = $null
            $state.LoginActive = $false
            $state.LoginOnline = $false
            & $setBatchRunning $false '批量建群已停止。'
        }
    }.GetNewClosure()
    $state.StopBridgeAction = $stopBridge

    $closeBridgeAfterError = {
        param([string]$Message)
        $process = $state.BridgeProcess
        if ($null -ne $process) {
            try { $process.StandardInput.Close() } catch {}
            try { if (-not $process.HasExited) { $process.Kill() } } catch {}
            try { $process.Dispose() } catch {}
        }
        $state.BridgeProcess = $null
        $state.BridgeOutputTask = $null
        $state.BridgeErrorTask = $null
        $state.LoginActive = $false
        $state.LoginOnline = $false
        & $setLoginLifecycle 'stopped' $Message
        & $setBatchRunning $false $Message
    }.GetNewClosure()

    $receiveMessage = {
        param([string]$Line)
        if ([string]::IsNullOrWhiteSpace($Line)) { return }
        try { $message = $Line | ConvertFrom-Json } catch {
            & $setLoginLifecycle 'error' 'APP 登录组件返回了无法识别的数据。'
            return
        }
        if ([string](& $getValue $message 'type') -eq 'event') {
            $eventName = [string](& $getValue $message 'event')
            if ($eventName -eq 'batch_progress') {
                $generation = & $getValue $message 'generation'
                if ($null -ne $generation -and [string]$generation -eq [string]$state.BatchGeneration) {
                    & $showBatchProgress (& $getValue $message 'progress')
                }
                return
            }
            $generation = & $getValue $message 'generation'
            if ($null -eq $generation -or [string]$generation -ne [string]$state.LoginGeneration) { return }
            if ($eventName -eq 'heartbeat') {
                $heartbeatTime = [datetime]::Now.ToString('HH:mm:ss')
                $heartbeatLabel.Text = '心跳状态：正常 ' + $heartbeatTime
                $heartbeatLabel.ForeColor = [Drawing.Color]::FromArgb(0,115,90)
                & $Context['WriteLog'] 'APP业务' "[heartbeat] 心跳正常 $heartbeatTime"
                return
            }
            & $setLoginLifecycle $eventName ([string](& $getValue $message 'message')) (& $getValue $message 'session')
            return
        }
        $ok = [bool](& $getValue $message 'ok')
        $commandName = [string](& $getValue $message 'command')
        if ($commandName -eq 'batch_create_groups') {
            $generation = & $getValue $message 'generation'
            if ($null -eq $generation -or [string]$generation -ne [string]$state.BatchGeneration) { return }
            if (-not $ok) {
                $errorObject = & $getValue $message 'error'
                $errorMessage = [string](& $getValue $errorObject 'message')
                & $setBatchRunning $false $(if ([string]::IsNullOrWhiteSpace($errorMessage)) {'批量建群失败。'} else {$errorMessage})
                return
            }
            $data = & $getValue $message 'data'
            if ([string](& $getValue $data 'state') -eq 'completed') {
                & $showBatchSummary (& $getValue $data 'summary')
            }
            return
        }
        if (-not $ok) {
            $errorObject = & $getValue $message 'error'
            $errorMessage = [string](& $getValue $errorObject 'message')
            $state.LoginActive = $false
            & $setLoginLifecycle 'stopped' $(if ([string]::IsNullOrWhiteSpace($errorMessage)) {'APP 登录失败。'} else {$errorMessage})
            return
        }
        if ($commandName -eq 'stop') { & $setLoginLifecycle 'stopped' 'APP 登录已停止。' }
    }.GetNewClosure()
    $state.ReceiveMessageAction = $receiveMessage

    $getTaskResult = {
        param($Task, [string]$StreamName)
        if ($Task.IsCanceled) { throw "APP 登录组件的 $StreamName 读取已取消。" }
        if ($Task.IsFaulted) {
            $detail = if ($null -ne $Task.Exception) { $Task.Exception.GetBaseException().Message } else { '未知读取错误' }
            throw "APP 登录组件的 $StreamName 读取失败：$detail"
        }
        try { return $Task.GetAwaiter().GetResult() } catch { throw "APP 登录组件的 $StreamName 读取失败：$($_.Exception.Message)" }
    }.GetNewClosure()

    $poll = {
        if ($state.Disposed) { return }
        $process = $state.BridgeProcess
        if ($null -eq $process) { return }
        try {
            for ($count = 0; $count -lt 20 -and $null -ne $state.BridgeOutputTask -and $state.BridgeOutputTask.IsCompleted; $count++) {
                $line = & $getTaskResult $state.BridgeOutputTask '标准输出'
                if ($null -eq $line) { $state.BridgeOutputTask = $null; break }
                & $receiveMessage ([string]$line)
                $state.BridgeOutputTask = $process.StandardOutput.ReadLineAsync()
            }
            for ($count = 0; $count -lt 20 -and $null -ne $state.BridgeErrorTask -and $state.BridgeErrorTask.IsCompleted; $count++) {
                $line = & $getTaskResult $state.BridgeErrorTask '错误输出'
                if ($null -eq $line) { $state.BridgeErrorTask = $null; break }
                [void]$state.BridgeErrorText.AppendLine([string]$line)
                $state.BridgeErrorTask = $process.StandardError.ReadLineAsync()
            }
            $process.Refresh()
            if ($process.HasExited -and $null -eq $state.BridgeOutputTask -and $null -eq $state.BridgeErrorTask) {
                $detail = $state.BridgeErrorText.ToString().Trim()
                if ($state.LoginActive -or -not [string]::IsNullOrWhiteSpace($detail)) {
                    & $closeBridgeAfterError $(if ([string]::IsNullOrWhiteSpace($detail)) {'APP 登录组件已退出。'} else {"APP 登录组件启动失败：$detail"})
                } else {
                    try { $process.Dispose() } catch {}
                    $state.BridgeProcess = $null
                }
            }
        } catch { & $closeBridgeAfterError $_.Exception.Message }
    }.GetNewClosure()
    $state.PollAction = $poll

    $startLogin = {
        $account = $accountBox.Text.Trim()
        $password = $passwordBox.Text
        $server = $serverBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($account)) { throw '请输入 APP 账号。' }
        if ([string]::IsNullOrWhiteSpace($password)) { throw '请输入 APP 密码。' }
        if ([string]::IsNullOrWhiteSpace($server)) { throw '请选择或输入服务器地址。' }
        & $startBridge
        $state.LoginGeneration++
        & $sendCommand @{command='login';generation=$state.LoginGeneration;account=$account;password=$password;server=$server;verify_tls=$false}
        $heartbeatLabel.Text = '心跳状态：等待心跳'
        $heartbeatLabel.ForeColor = [Drawing.Color]::FromArgb(92,102,110)
        & $setLoginLifecycle 'connecting' '正在连接 APP PUC 服务。'
    }.GetNewClosure()
    $state.StartLoginAction = $startLogin

    $startBatch = {
        if (-not $state.LoginOnline) { throw 'APP 当前不在线，无法批量建群。' }
        if ($state.BatchRunning) { throw '批量建群正在执行，请等待完成。' }
        $members = @()
        foreach ($row in @($memberGrid.Rows)) {
            if ($row.IsNewRow) { continue }
            $memberAccount = ([string]$row.Cells['account'].Value).Trim()
            $appPucId = ([string]$row.Cells['app_puc_id'].Value).Trim()
            if ([string]::IsNullOrWhiteSpace($memberAccount) -and [string]::IsNullOrWhiteSpace($appPucId)) { continue }
            if ([string]::IsNullOrWhiteSpace($memberAccount) -or [string]::IsNullOrWhiteSpace($appPucId)) {
                throw '每个成员都必须填写账号和 APP PUC ID。'
            }
            $members += [ordered]@{account=$memberAccount;app_puc_id=$appPucId}
        }
        if ($members.Count -eq 0) { throw '请至少添加一个完整的群成员。' }
        $state.BatchGeneration++
        $resultGrid.Rows.Clear()
        & $setBatchRunning $true '正在提交批量建群任务...'
        try {
            & $sendCommand ([ordered]@{
                command='batch_create_groups';generation=$state.BatchGeneration
                members=@($members);group_count=[int]$groupCountInput.Value
            })
        } catch { & $setBatchRunning $false $_.Exception.Message; throw }
    }.GetNewClosure()
    $state.StartBatchAction = $startBatch

    $dispose = {
        if ($state.Disposed) { return }
        $state.Disposed = $true
        if ($null -ne $state.PollTimer) {
            try { $state.PollTimer.Stop() } catch {}
            try { $state.PollTimer.Dispose() } catch {}
            $state.PollTimer = $null
        }
        & $stopBridge $true
        $passwordBox.Clear()
    }.GetNewClosure()
    $state.DisposeAction = $dispose

    $environmentBox.Add_SelectedIndexChanged(({ & $state.UpdateAddressAction }.GetNewClosure()))
    $serverBox.Add_TextChanged(({
        if ($state.UpdatingAddress) { return }
        if ($followEnvironmentBox.Checked) { $followEnvironmentBox.Checked = $false }
    }.GetNewClosure()))
    $followEnvironmentBox.Add_CheckedChanged(({
        $serverBox.ReadOnly = $followEnvironmentBox.Checked -or $state.LoginActive
        if ($followEnvironmentBox.Checked) { & $state.UpdateAddressAction }
    }.GetNewClosure()))
    $addEnvironmentButton.Add_Click(({
        try {
            $preferredName = [string](& $Context.AddEnvironment)
            & $state.RefreshAction $preferredName
        } catch {
            [Windows.Forms.MessageBox]::Show($Context.Form,$_.Exception.Message,'新增环境','OK','Warning') | Out-Null
        }
    }.GetNewClosure()))
    $loginButton.Add_Click(({
        try {
            if ($state.LoginActive) {
                & $state.StopBridgeAction $false
                $hintLabel.Text = '正在停止 APP 登录...'
            } else { & $state.StartLoginAction }
        } catch {
            $hintLabel.Text = $_.Exception.Message
            & $Context['WriteLog'] 'APP业务' "[error] $($_.Exception.Message)"
            [Windows.Forms.MessageBox]::Show($Context.Form,$_.Exception.Message,'APP 登录','OK','Warning') | Out-Null
        }
    }.GetNewClosure()))
    $addMemberButton.Add_Click(({
        try { & $state.ShowMemberPickerAction } catch {
            & $reportSearchError $_.Exception.Message
            [Windows.Forms.MessageBox]::Show($Context.Form,$_.Exception.Message,'添加成员','OK','Warning') | Out-Null
        }
    }.GetNewClosure()))
    $removeMemberButton.Add_Click(({
        foreach ($row in @($memberGrid.SelectedRows)) {
            if (-not $row.IsNewRow) { $memberGrid.Rows.Remove($row) }
        }
        if ($memberGrid.Rows.Count -eq 0) { [void]$memberGrid.Rows.Add() }
    }.GetNewClosure()))
    $batchButton.Add_Click(({
        try { & $state.StartBatchAction } catch {
            $batchProgressLabel.Text = $_.Exception.Message
            [Windows.Forms.MessageBox]::Show($Context.Form,$_.Exception.Message,'批量建群','OK','Warning') | Out-Null
        }
    }.GetNewClosure()))

    $pollTimer = New-Object Windows.Forms.Timer
    $pollTimer.Interval = 100
    $pollTimer.Add_Tick(({ & $state.PollAction }.GetNewClosure()))
    $state.PollTimer = $pollTimer
    $pollTimer.Start()
    & $updateBatchControls

    return [pscustomobject]@{
        TabPage=$tab
        Refresh=$refresh
        Poll=$poll
        Dispose=$dispose
        Controls=[pscustomobject]@{
            Environment=$environmentBox
            Server=$serverBox
            OnlineStatus=$onlineLabel
            HeartbeatStatus=$heartbeatLabel
            Business=$businessBox
            AddMember=$addMemberButton
            MemberGrid=$memberGrid
        }
        AddMembers=$addMembers
        ResolveConfigRoot=$resolveConfigRoot
        ReportSearchError=$reportSearchError
    }
}
