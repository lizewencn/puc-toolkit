Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-PucSensitiveResultName([string]$Name) {
    -not [string]::IsNullOrWhiteSpace($Name) -and
        $Name -match '(?i)(password|passwd|token|cookie|authorization|secret|captcha|cipher)'
}

function ConvertTo-PucSafeResultValue($Value, [string]$Name = '') {
    if (Test-PucSensitiveResultName $Name) { return '[已隐藏]' }
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }

    if ($Value -is [Collections.IDictionary]) {
        $safe = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $safe[[string]$key] = ConvertTo-PucSafeResultValue $Value[$key] ([string]$key)
        }
        return $safe
    }

    if ($Value -is [Collections.IEnumerable]) {
        return @($Value | ForEach-Object { ConvertTo-PucSafeResultValue $_ '' })
    }

    $properties = @($Value.PSObject.Properties | Where-Object MemberType -in @('NoteProperty','Property'))
    if ($properties.Count -gt 0) {
        $safe = [ordered]@{}
        foreach ($property in $properties) {
            $safe[$property.Name] = ConvertTo-PucSafeResultValue $property.Value $property.Name
        }
        return [pscustomobject]$safe
    }

    return [string]$Value
}

function Protect-PucResultText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $protected = [regex]::Replace(
        $Text,
        '(?im)(?<key>"?(?:password|passwd|token|cookie|authorization|secret|captcha(?:Id|Value)?|cipher)"?)(?<separator>\s*[:=]\s*)(?<value>"[^"]*"|''[^'']*''|[^\s,;\}\]]+)',
        '${key}${separator}[已隐藏]'
    )
    return $protected
}

function Get-PucResultRecords([string[]]$Outputs) {
    $records = [Collections.Generic.List[object]]::new()
    foreach ($output in @($Outputs)) {
        $outputText = ([string]$output).Trim()
        $parsedOutput = $false
        if ($outputText.StartsWith('{') -or $outputText.StartsWith('[')) {
            try {
                $parsed = $outputText | ConvertFrom-Json
                if ($null -ne $parsed) {
                    $records.Add($parsed)
                    $parsedOutput = $true
                }
            } catch {}
        }
        if ($parsedOutput) { continue }
        foreach ($line in @($outputText -split "`r?`n")) {
            $candidate = $line.Trim()
            if (-not ($candidate.StartsWith('{') -or $candidate.StartsWith('['))) { continue }
            try {
                $parsed = $candidate | ConvertFrom-Json
                if ($null -ne $parsed) { $records.Add($parsed) }
            } catch {}
        }
    }
    return @($records)
}

function Format-PucResultRawText([string[]]$Outputs, [string]$ExtraText = '') {
    $blocks = [Collections.Generic.List[string]]::new()
    foreach ($output in @($Outputs) + @($ExtraText)) {
        if ([string]::IsNullOrWhiteSpace([string]$output)) { continue }
        $lines = [Collections.Generic.List[string]]::new()
        foreach ($line in @(([string]$output) -split "`r?`n")) {
            $candidate = $line.Trim()
            $formatted = $null
            if ($candidate.StartsWith('{') -or $candidate.StartsWith('[')) {
                try {
                    $safe = ConvertTo-PucSafeResultValue ($candidate | ConvertFrom-Json)
                    $formatted = $safe | ConvertTo-Json -Depth 60
                } catch {}
            }
            if ($null -ne $formatted) { $lines.Add($formatted) }
            else { $lines.Add((Protect-PucResultText $line)) }
        }
        $blocks.Add(($lines -join "`r`n").Trim())
    }
    return ($blocks -join "`r`n`r`n").Trim()
}

function Get-PucResultLabel([string]$Name) {
    $labels = @{
        account='账号'; accounts='账号'; action='动作'; alias='别名'; alreadyComplete='已完整'; assetDirectory='资源目录'
        bytes='文件大小'; changedFields='变更字段'; changes='变更'; code='编码'; command='命令'
        configBytes='配置大小'; configFilePath='配置文件'; configSha256='配置 SHA-256'; dispatchNumber='调度号码'; dispatcherAccount='调度账号'
        count='数量'; currentEnabled='当前启用'; currentFlag='当前值'; currentLicenseType='当前 License 类型'
        currentValue='当前值'; desiredFlag='目标值'; desiredValue='目标值'; environment='环境'; error='错误'; configRoot='最新路径'
        failed='失败数'; failedAccount='失败账号'; filePath='文件路径'; group='分类'; incomingLicenseType='待导入 License 类型'
        idNumber='证件号码'; importedLicenseType='已导入 License 类型'; itemCount='项目数'; licenseBytes='License 大小'
        licenseFilePath='License 文件'; licenseSha256='License SHA-256'; manifestPath='执行清单'
        mobile='手机号码'; name='名称'; nodeCount='节点数'; officerId='警员编号'; percentage='进度'; previousLicenseType='原 License 类型'
        message='提示'; operationResult='操作结果'; previewHash='预览哈希'; query='查询条件'; reason='说明'; replacement='已替换'
        replacementRequired='需要替换'; result='结果码'; results='结果'; sha256='SHA-256'
        role='角色'; roleGuid='角色 GUID'; roleSelection='角色选择'; sequence='序号'; snapshotHash='快照哈希'; stage1Result='阶段 1 结果'; stage2Result='阶段 2 结果'; status='状态'
        succeeded='成功数'; target='目标'; targetSource='目标来源'; taskId='任务 ID'; updateCount='待更新'
        value='值'; verified='已验证'; writeRequired='需要写入'; writesUsed='写入次数'; plannedWrites='计划写入'
        finalPasswordStatus='最终密码'; oldValue='原值'; newValue='新值'; field='字段'; ok='成功'
        finalPath='升级包路径'; finalName='升级包文件名'; package='版本包'; packageName='应用包名'; packageCount='版本包数量'; packageNames='版本包'; updatedCount='更新数量'; installedCount='新增安装数量'; versionName='版本名称'; versionCode='版本号'
        apkMd5='APK MD5'; apkSize='APK 大小'; upgradeZipMd5='upgrade.zip MD5'; outputSize='升级包大小'; outputDirectory='输出目录'; description='升级说明'; force='强制升级'
    }
    if ($labels.ContainsKey($Name)) { return $labels[$Name] }
    return $Name
}

function Get-PucStatusText([string]$Value) {
    $statuses = @{
        'already-complete'='无需修改'; 'completed'='已完成'; 'configured'='配置完成'; 'created'='已创建'
        'current'='当前状态'; 'exported'='已导出'; 'failed'='失败'; 'imported'='已导入'; 'partial-failure'='部分失败'
        'planned'='已检查'; 'planned-offline'='本地检查完成'; 'previewed'='预检完成'; 'ready'='待执行'
        'skipped'='已跳过'; 'unchanged'='无需变更'; 'updated'='已更新'; 'installed'='已安装'; 'no-change'='无需变更'; 'no-match'='查询结果为空'
        'password-reset'='密码已重置'; 'preview-failed'='预检失败'; 'conflict-skipped'='冲突已跳过'
        'build-complete'='已制作完成'; 'latest'='已是最新版本'; 'staged'='已下载待安装'; 'update-failed'='更新失败'
        'true'='是'; 'false'='否'
    }
    if ($statuses.ContainsKey($Value)) { return $statuses[$Value] }
    return $Value
}

function Format-PucResultValue($Value, [string]$Name = '') {
    if ($null -eq $Value) { return '无' }
    if (Test-PucSensitiveResultName $Name) { return '[已隐藏]' }
    if ($Value -is [bool]) { return $(if ($Value) { '是' } else { '否' }) }
    if ($Name -match '(?i)(^bytes$|Bytes$)' -and $null -ne ($Value -as [long])) {
        $bytes = [long]$Value
        if ($bytes -ge 1GB) { return ('{0:N2} GB ({1:N0} 字节)' -f ($bytes / 1GB),$bytes) }
        if ($bytes -ge 1MB) { return ('{0:N2} MB ({1:N0} 字节)' -f ($bytes / 1MB),$bytes) }
        if ($bytes -ge 1KB) { return ('{0:N2} KB ({1:N0} 字节)' -f ($bytes / 1KB),$bytes) }
        return "$bytes 字节"
    }
    if ($Name -eq 'percentage') { return "$Value%" }
    if ($Name -eq 'status') { return Get-PucStatusText ([string]$Value) }
    if ($Value -is [string] -or $Value -is [ValueType]) { return [string]$Value }
    if ($Value -is [Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '0 项' }
        if (@($items | Where-Object { $_ -isnot [string] -and $_ -isnot [ValueType] }).Count -eq 0) {
            $displayItems = @($items | ForEach-Object { Get-PucStatusText ([string]$_) })
            return ($displayItems -join ', ')
        }
        return "$($items.Count) 项"
    }
    return ((ConvertTo-PucSafeResultValue $Value $Name) | ConvertTo-Json -Depth 8 -Compress)
}

function Add-PucResultField($Fields, $Seen, [string]$Name, $Value) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $null -eq $Value -or (Test-PucSensitiveResultName $Name)) { return }
    $formatted = Format-PucResultValue $Value $Name
    if ([string]::IsNullOrWhiteSpace($formatted)) { return }
    $entry = [pscustomobject]@{Name=$Name;Label=(Get-PucResultLabel $Name);Value=$formatted}
    if ($Seen.ContainsKey($Name)) { $Fields[$Seen[$Name]] = $entry }
    else { $Seen[$Name] = $Fields.Count; $Fields.Add($entry) }
}

function ConvertTo-PucResultRow([string]$Group, $Item) {
    $row = [ordered]@{group=(Get-PucResultLabel $Group)}
    if ($null -eq $Item) { $row.value='无'; return $row }
    if ($Item -is [string] -or $Item -is [ValueType]) { $row.value=(Format-PucResultValue $Item); return $row }

    $properties = @($Item.PSObject.Properties | Where-Object MemberType -in @('NoteProperty','Property'))
    foreach ($property in $properties) {
        if (Test-PucSensitiveResultName $property.Name) { $row[$property.Name]='[已隐藏]'; continue }
        if ($null -eq $property.Value) { continue }
        $row[$property.Name] = Format-PucResultValue $property.Value $property.Name
    }
    return $row
}

function Get-PucResultErrorSummary([string]$RawText, $LatestRecord) {
    if ($null -ne $LatestRecord) {
        foreach ($name in @('error','msg','message','reason','detail')) {
            $property = $LatestRecord.PSObject.Properties[$name]
            if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                return (Protect-PucResultText ([string]$property.Value))
            }
        }
    }
    foreach ($line in @($RawText -split "`r?`n")) {
        $candidate = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate.StartsWith('{') -or $candidate.StartsWith('[')) { continue }
        if ($candidate -match '^(At |\+ |CategoryInfo|FullyQualifiedErrorId|=== )') { continue }
        if ($candidate.Length -gt 500) { return $candidate.Substring(0,497) + '...' }
        return $candidate
    }
    return '执行未成功，详细信息见“详细输出”。'
}

function New-PucResultModel {
    [CmdletBinding()]
    param(
        [string[]]$Outputs = @(),
        [string]$ExtraText = '',
        [string]$OperationLabel = '',
        [string]$Environment = '',
        [string]$Stage = '',
        [object[]]$ExecutionNodes = @(),
        [datetime]$StartedAt = [datetime]::Now,
        [ValidateSet('Idle','Progress','Confirmation','Finished')][string]$ViewState = 'Idle',
        [int]$ExitCode = 0
    )

    $rawText = Format-PucResultRawText -Outputs $Outputs -ExtraText $ExtraText
    $records = @(Get-PucResultRecords $Outputs)
    $latest = if ($records.Count -gt 0) { $records[-1] } else { $null }
    $combinedText = (($Outputs -join "`n") + "`n" + $ExtraText)
    $latestStatus = if ($null -ne $latest -and $null -ne $latest.PSObject.Properties['status']) { [string]$latest.status } else { '' }

    $kind = 'Neutral'
    $statusText = '就绪'
    if ($ViewState -eq 'Progress') { $kind='Progress';$statusText='正在执行' }
    elseif ($ViewState -eq 'Confirmation') { $kind='Warning';$statusText='等待确认' }
    elseif ($ViewState -eq 'Finished') {
        if ($combinedText -match '(?i)(用户已取消|cancelled|canceled)') { $kind='Neutral';$statusText='已取消' }
        elseif ($latestStatus -eq 'no-match') { $kind='Neutral';$statusText='查询结果为空' }
        elseif ($latestStatus -eq 'latest' -and $ExitCode -eq 0) { $kind='Success';$statusText='已是最新版本' }
        elseif ($combinedText -match '(?i)(uncertain|不确定|may require manual reconciliation|No retry was attempted)' -and $ExitCode -ne 0) { $kind='Warning';$statusText='结果不确定' }
        elseif ($latestStatus -match 'partial-failure' -or ($ExitCode -ne 0 -and $combinedText -match '(?i)(after the configuration file was saved|部分成功|已成功)')) { $kind='Warning';$statusText='部分成功' }
        elseif ($ExitCode -eq 0) { $kind='Success';$statusText='执行成功' }
        else { $kind='Error';$statusText='执行失败' }
    }

    $fields = [Collections.Generic.List[object]]::new()
    $seen = @{}
    Add-PucResultField $fields $seen 'environment' $Environment
    $elapsed = [Math]::Max(0,([datetime]::Now - $StartedAt).TotalSeconds)
    $fields.Add([pscustomobject]@{Name='duration';Label='耗时';Value=('{0:N1} 秒' -f $elapsed)})
    if (@($ExecutionNodes).Count -gt 0) {
        $nodeNumber = 0
        foreach ($node in @($ExecutionNodes)) {
            $nodeNumber++
            $nodeStatus = switch ([string]$node.Status) {
                'running' {'执行中'}
                'completed' {'已完成'}
                'failed' {'失败'}
                'skipped' {'已跳过'}
                default {'待执行'}
            }
            $fields.Add([pscustomobject]@{
                Name="executionNode$nodeNumber"
                Label="$nodeNumber."
                Value="$([string]$node.Label)（$nodeStatus）"
                Status=[string]$node.Status
            })
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($Stage)) {
        $fields.Add([pscustomobject]@{Name='stage';Label='执行阶段';Value=$Stage})
    }
    if ($latestStatus -eq 'latest' -and $ExitCode -eq 0) {
        Add-PucResultField $fields $seen 'message' '仓库下全部版本包已是最新版本，无需更新。'
    }

    $displayFields = @(
        'account','query','message','operationResult','configRoot','targetSource','accountCount','count','itemCount','nodeCount','updateCount','packageCount','packageNames','updatedCount','installedCount','alreadyComplete',
        'succeeded','failed','failedAccount','currentEnabled','currentFlag','currentValue','desiredFlag','desiredValue',
        'writeRequired','verified','taskId','percentage','filePath','bytes','sha256','configFilePath','configBytes',
        'configSha256','licenseFilePath','licenseBytes','licenseSha256','manifestPath','replacementRequired',
        'currentLicenseType','incomingLicenseType','previousLicenseType','importedLicenseType','replacement','previewHash','snapshotHash'
    )
    foreach ($record in $records) {
        foreach ($name in $displayFields) {
            $property = $record.PSObject.Properties[$name]
            if ($null -ne $property) { Add-PucResultField $fields $seen $name $property.Value }
        }
    }
    if ($seen.ContainsKey('configFilePath')) {
        foreach ($duplicate in @('filePath','bytes','sha256')) {
            if ($seen.ContainsKey($duplicate)) { $fields.RemoveAt($seen[$duplicate]); $seen.Clear(); for($i=0;$i -lt $fields.Count;$i++){$seen[$fields[$i].Name]=$i} }
        }
    }

    if ($ViewState -eq 'Finished' -and $ExitCode -ne 0) {
        Add-PucResultField $fields $seen 'error' (Get-PucResultErrorSummary $rawText $latest)
    }

    $rows = [Collections.Generic.List[object]]::new()
    $rowRecord = $null
    for ($recordIndex = $records.Count - 1; $recordIndex -ge 0; $recordIndex--) {
        $candidateCollections = @($records[$recordIndex].PSObject.Properties | Where-Object {
            $_.Value -isnot [string] -and $_.Value -is [Collections.IEnumerable] -and @($_.Value).Count -gt 0
        })
        if ($candidateCollections.Count -gt 0) { $rowRecord = $records[$recordIndex]; break }
    }
    if ($null -ne $rowRecord) {
        foreach ($property in @($rowRecord.PSObject.Properties)) {
            if ($property.Value -is [string] -or $property.Value -isnot [Collections.IEnumerable]) { continue }
            $items = @($property.Value)
            if ($items.Count -eq 0) { continue }
            foreach ($item in $items) { $rows.Add((ConvertTo-PucResultRow $property.Name $item)) }
        }
    }

    [pscustomobject]@{
        Kind=$kind
        StatusText=$statusText
        Heading=if ([string]::IsNullOrWhiteSpace($OperationLabel)) { $statusText } else { "$statusText · $OperationLabel" }
        Fields=@($fields)
        Rows=@($rows)
        RawText=$rawText
    }
}

Export-ModuleMember -Function New-PucResultModel,Format-PucResultRawText,Get-PucResultLabel
