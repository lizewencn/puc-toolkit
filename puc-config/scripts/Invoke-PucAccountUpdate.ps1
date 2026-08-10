[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][string]$Account,
    [string]$ChangesJson,
    [string]$ChangesPath,
    [switch]$PlanOnly,
    [switch]$DryRun,
    [switch]$Live,
    [switch]$ConfirmLive,
    [string]$ExpectedSnapshotHash,
    [string]$ConfigRoot
)

$ErrorActionPreference = 'Stop'
if (@($PlanOnly,$DryRun,$Live | Where-Object { $_ }).Count -ne 1) { throw 'Select exactly one mode: PlanOnly, DryRun, or Live.' }
if ([string]::IsNullOrWhiteSpace($Account)) { throw 'Account must not be empty.' }
if ([string]::IsNullOrWhiteSpace($ChangesJson) -eq [string]::IsNullOrWhiteSpace($ChangesPath)) {
    throw 'Provide exactly one changes source: ChangesJson or ChangesPath.'
}
if ($Live -and -not $ConfirmLive) { throw 'Live account update requires ConfirmLive after explicit confirmation.' }
if ($Live -and [string]::IsNullOrWhiteSpace($ExpectedSnapshotHash)) { throw 'Live account update requires ExpectedSnapshotHash from the authenticated dry run.' }

Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$root = Get-PucConfigRoot $ConfigRoot
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment

if (-not [string]::IsNullOrWhiteSpace($ChangesPath)) {
    $resolvedChangesPath = [IO.Path]::GetFullPath($ChangesPath)
    if (-not (Test-Path -LiteralPath $resolvedChangesPath -PathType Leaf)) { throw "Changes file does not exist: $resolvedChangesPath" }
    if ([IO.Path]::GetExtension($resolvedChangesPath).ToLowerInvariant() -ne '.json') { throw 'Changes file must have a .json extension.' }
    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    try { $changesText = [IO.File]::ReadAllText($resolvedChangesPath, $strictUtf8) }
    catch { throw "Changes file must be valid UTF-8: $($_.Exception.Message)" }
} else {
    $resolvedChangesPath = $null
    $changesText = $ChangesJson
}

try { $changes = $changesText | ConvertFrom-Json }
catch { throw "Changes are not valid JSON: $($_.Exception.Message)" }
if ($changes -isnot [pscustomobject]) { throw 'Changes must be one JSON object.' }
$changeProperties = @($changes.PSObject.Properties)
if ($changeProperties.Count -eq 0) { throw 'Changes JSON object must not be empty.' }

$accountFields = @(
    'dispatcher_no','dispatcher_name','org_identifier','org_alias','system_id','role','role_guid',
    'org_identifier_list','custom_org_identifier_list','custom_org_id','dispatch_sap_list','imei_list',
    'device_sn','device_group_list','system_id_list','sort_id','dispatcher_priority','device_type',
    'dispatcher_type','avatar_url','avatar_md5sum','is_del_avatar'
)
$mfaFields = @('mfa_switch','email')
$allowedFields = @($accountFields + $mfaFields)
foreach ($property in $changeProperties) {
    if ($property.Name -notin $allowedFields) { throw "Field '$($property.Name)' is not editable in the verified account-update workflow." }
}

function Has-Change([string]$Name) {
    return @($changes.PSObject.Properties.Match($Name)).Count -eq 1
}

function Get-PropertyValue($Object, [string]$Name, $Default = $null) {
    $property = @($Object.PSObject.Properties.Match($Name)) | Select-Object -First 1
    if ($null -eq $property) { return $Default }
    return $property.Value
}

if ((Has-Change 'role') -ne (Has-Change 'role_guid')) { throw 'role and role_guid must be changed together.' }
if ((Has-Change 'org_identifier') -ne (Has-Change 'org_alias')) { throw 'org_identifier and org_alias must be changed together.' }

$normalizedChanges = [ordered]@{}
foreach ($property in $changeProperties) {
    $name = $property.Name
    $value = $property.Value
    if ($name -eq 'imei_list') {
        if ($null -eq $value) { $value = @() }
        elseif ($value -is [string]) {
            $trimmed = $value.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) { $value = @() }
            elseif ($trimmed.StartsWith('[')) {
                try { $parsedImei = $trimmed | ConvertFrom-Json } catch { throw 'imei_list string is not valid JSON.' }
                $value = @($parsedImei | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
            } else {
                $value = @($trimmed -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
        } elseif ($value -is [System.Collections.IEnumerable]) {
            $value = @($value | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
        } else { throw 'imei_list must be an array or delimited string.' }
    }
    if ($name -eq 'dispatch_sap_list') {
        if ($null -eq $value) { $value = '' }
        elseif ($value -isnot [string]) { $value = $value | ConvertTo-Json -Depth 30 -Compress }
        elseif (-not [string]::IsNullOrWhiteSpace($value)) {
            try { $null = $value | ConvertFrom-Json } catch { throw 'dispatch_sap_list string must contain valid JSON.' }
        }
    }
    if ($name -in @('dispatcher_priority','device_type','dispatcher_type','is_del_avatar','mfa_switch')) {
        $number = 0
        if (-not [int]::TryParse([string]$value, [ref]$number)) { throw "$name must be an integer." }
        if ($name -in @('is_del_avatar','mfa_switch') -and $number -notin @(0,1)) { throw "$name must be 0 or 1." }
        $value = $number
    }
    if ($name -eq 'sort_id' -and $null -ne $value) {
        $number = 0
        if (-not [int]::TryParse([string]$value, [ref]$number)) { throw 'sort_id must be an integer or null.' }
        $value = $number
    }
    if ($name -in @('dispatcher_no','dispatcher_name','role','role_guid','org_identifier','org_alias') -and [string]::IsNullOrWhiteSpace([string]$value)) {
        throw "$name must not be empty."
    }
    if ($name -eq 'email' -and -not [string]::IsNullOrWhiteSpace([string]$value) -and -not ([string]$value).Contains('@')) {
        throw 'email must be empty or contain @.'
    }
    $normalizedChanges[$name] = $value
}

if ($PlanOnly) {
    [pscustomobject]@{
        status='planned-offline'; action='UpdateAccount'; environment=$Environment; account=$Account
        changesSource=if ($resolvedChangesPath) { $resolvedChangesPath } else { 'inline-json' }
        requestedFields=@($normalizedChanges.Keys); networkUsed=$false
    } | ConvertTo-Json -Depth 10 -Compress
    return
}

$validation = & (Join-Path $PSScriptRoot 'Invoke-PucAuth.ps1') -Action Validate -Environment $Environment -ConfigRoot $root | ConvertFrom-Json
if ($validation.valid -ne $true) { throw "Saved token is not usable ($($validation.reason)). Complete the login workflow first." }
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
$baseUri = [uri]$environmentConfig.baseUrl
$oldCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
$callbackChanged = $false
if ($environmentConfig.allowInsecureTls -eq $true -and -not (Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')) {
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    $callbackChanged = $true
}

function Invoke-PucAccountRequest([hashtable]$Body) {
    [byte[]]$jsonBody = ConvertTo-PucJsonBytes -Value $Body -Depth 40
    $params = @{
        Method='POST'; Uri=$baseUri.AbsoluteUri.TrimEnd('/') + '/confs'; ContentType='application/json; charset=utf-8'
        Headers=@{ Accept='application/json, text/plain, */*'; token=[string]$environmentConfig.token }
        Body=$jsonBody; TimeoutSec=60
    }
    if ($environmentConfig.allowInsecureTls -eq $true -and (Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')) {
        $params.SkipCertificateCheck = $true
    }
    $response = ConvertFrom-PucResponseEncoding -Value (Invoke-RestMethod @params)
    if ($null -eq $response) { throw "$($Body.cmd_name) returned an empty response. No retry was attempted." }
    $resultProperty = @($response.PSObject.Properties.Match('result')) | Select-Object -First 1
    if ($null -ne $resultProperty -and [string]$resultProperty.Value -ne '0') {
        throw "$($Body.cmd_name) failed: result=$([string]$resultProperty.Value); msg=$([string](Get-PropertyValue $response 'msg' '')). No retry was attempted."
    }
    return $response
}

function Get-ExactAccount {
    $pageIndex = 1
    $matches = [Collections.Generic.List[object]]::new()
    while ($true) {
        $response = Invoke-PucAccountRequest ([ordered]@{
            cmd_name='account_list_request'; user_id=[string]$environmentConfig.adminAccount
            realm=[string]$environmentConfig.realm; page_sizes=30; page_index=$pageIndex
            querykey=$Account; lock_query=0; filter=[ordered]@{by_role='';by_state=0}
        })
        foreach ($row in @((Get-PropertyValue $response 'account_list' @()))) {
            if ([string]::Equals([string](Get-PropertyValue $row 'dispatcher_account' ''),$Account,[StringComparison]::OrdinalIgnoreCase)) {
                $matches.Add($row)
            }
        }
        $pageCount = 0
        [void][int]::TryParse([string](Get-PropertyValue $response 'page_count' 0),[ref]$pageCount)
        if ($pageCount -le 0 -or $pageIndex -ge $pageCount) { break }
        if ($pageIndex -ge 1000) { throw 'Account lookup exceeded 1000 pages.' }
        $pageIndex++
    }
    if ($matches.Count -ne 1) { throw "Exact account lookup for '$Account' returned $($matches.Count) matches." }
    return $matches[0]
}

function Normalize-Imei($Value) {
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) {
        $trimmed = $Value.Trim()
        if (-not $trimmed) { return @() }
        if ($trimmed.StartsWith('[')) { try { return @(($trimmed | ConvertFrom-Json) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) } catch {} }
        return @($trimmed -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    return @($Value | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
}

function New-UpdateState($Record) {
    $editable = [string](Get-PropertyValue $Record 'judge_sync_edit' '')
    if ($editable -notin @('1','True','true')) { throw "Account '$Account' is not editable according to judge_sync_edit." }
    if ([string](Get-PropertyValue $Record 'system_type' '') -eq '21') { throw "Account '$Account' is a protected system account and cannot be edited." }
    $cipher = [string](Get-PropertyValue $Record 'dispatcher_pwd' '')
    if ([string]::IsNullOrWhiteSpace($cipher)) { throw "Account '$Account' did not return a password cipher to preserve." }

    $recordPucId = [string](Get-PropertyValue $Record 'puc_id' '')
    if ([string]::IsNullOrWhiteSpace($recordPucId)) { $recordPucId = [string]$environmentConfig.pucId }
    $payload = [ordered]@{
        cmd_name='update_account'; dispatcher_no=[string](Get-PropertyValue $Record 'dispatcher_no' '')
        dispatcher_account=[string](Get-PropertyValue $Record 'dispatcher_account' ''); dispatcher_name=[string](Get-PropertyValue $Record 'dispatcher_name' '')
        dispatcher_pwd=$cipher; is_change_pwd=0; org_identifier=[string](Get-PropertyValue $Record 'org_identifier' '')
        org_alias=[string](Get-PropertyValue $Record 'org_alias' ''); realm=[string]$environmentConfig.realm
        system_id=[string](Get-PropertyValue $Record 'system_id' ''); is_sync=0; role=[string](Get-PropertyValue $Record 'role' '')
        role_guid=[string](Get-PropertyValue $Record 'role_guid' ''); org_identifier_list=[string](Get-PropertyValue $Record 'org_identifier_list' '')
        custom_org_identifier_list=[string](Get-PropertyValue $Record 'custom_org_identifier_list' ''); custom_org_id=[string](Get-PropertyValue $Record 'custom_org_id' '')
        dispatch_sap_list=[string](Get-PropertyValue $Record 'dispatch_sap_list' ''); imei_list=@(Normalize-Imei (Get-PropertyValue $Record 'imei_list' @()))
        device_sn=[string](Get-PropertyValue $Record 'device_sn' ''); device_group_list=[string](Get-PropertyValue $Record 'device_group_list' '')
        system_id_list=[string](Get-PropertyValue $Record 'system_id_list' ''); sort_id=(Get-PropertyValue $Record 'sort_id' $null)
        saprule_type=0; dispatcher_priority=[int](Get-PropertyValue $Record 'dispatcher_priority' 1)
        guid=[string](Get-PropertyValue $Record 'guid' ''); puc_id=$recordPucId
        device_type=[int](Get-PropertyValue $Record 'device_type' 29); dispatcher_type=[int](Get-PropertyValue $Record 'dispatcher_type' 0)
        avatar_url=[string](Get-PropertyValue $Record 'avatar_url' ''); avatar_md5sum=[string](Get-PropertyValue $Record 'avatar_md5sum' '')
    }
    foreach ($field in $accountFields) {
        if ($normalizedChanges.Contains($field)) { $payload[$field] = $normalizedChanges[$field] }
    }
    $identityFields = @('dispatcher_account','guid')
    foreach ($field in $identityFields) {
        if ([string]::IsNullOrWhiteSpace([string]$payload[$field])) { throw "Account record is missing required identity field '$field'." }
    }
    $snapshotJson = $payload | ConvertTo-Json -Depth 40 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $snapshotHash = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($snapshotJson)) | ForEach-Object { $_.ToString('x2') }) -join '').ToUpperInvariant() }
    finally { $sha.Dispose() }
    return [pscustomobject]@{Payload=$payload;SnapshotHash=$snapshotHash}
}

function New-ChangeSummary($Record) {
    $items = foreach ($property in $changeProperties) {
        $oldValue = Get-PropertyValue $Record $property.Name $null
        [pscustomobject]@{field=$property.Name;oldValue=$oldValue;newValue=$normalizedChanges[$property.Name]}
    }
    return @($items)
}

try {
    $record = Get-ExactAccount
    $state = New-UpdateState $record
    $summary = New-ChangeSummary $record
    if ($DryRun) {
        [pscustomobject]@{
            status='previewed'; action='UpdateAccount'; environment=$Environment; account=[string]$record.dispatcher_account
            snapshotHash=$state.SnapshotHash; changes=$summary; networkUsed=$true; writesUsed=0
        } | ConvertTo-Json -Depth 15 -Compress
        return
    }

    if (-not [string]::Equals($state.SnapshotHash,$ExpectedSnapshotHash,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Account snapshot changed or does not match the authenticated dry run. Run DryRun again before updating.'
    }
    $updateResponse = Invoke-PucAccountRequest $state.Payload
    $mfaUpdated = $false
    if ((Has-Change 'mfa_switch') -or (Has-Change 'email')) {
        $mfaBody = [ordered]@{
            cmd_name='mfa_dispatcher_info_config_update'; cmd_guid=[guid]::NewGuid().ToString(); realm=[string]$environmentConfig.realm
            mfa_dispatcher_info_config=[ordered]@{
                puc_id=[string]$environmentConfig.pucId; realm=[string]$environmentConfig.realm
                dispatcher_account=[string]$record.dispatcher_account; system_id=[string]$state.Payload.system_id; guid=[string]$record.guid
                mfa_switch=if (Has-Change 'mfa_switch') { [int]$normalizedChanges.mfa_switch } else { [int](Get-PropertyValue $record 'mfa_switch' 0) }
                email=if (Has-Change 'email') { [string]$normalizedChanges.email } else { [string](Get-PropertyValue $record 'email' '') }
            }
        }
        try { $null = Invoke-PucAccountRequest $mfaBody; $mfaUpdated = $true }
        catch { throw "update_account succeeded, but MFA/email update failed and may require manual reconciliation: $($_.Exception.Message)" }
    }
    $refreshed = Get-ExactAccount
    [pscustomobject]@{
        status='updated'; action='UpdateAccount'; environment=$Environment; account=[string]$refreshed.dispatcher_account
        snapshotHash=$state.SnapshotHash; changedFields=@($normalizedChanges.Keys); accountResult=[string]$updateResponse.result
        mfaUpdated=$mfaUpdated; refreshed=$true
    } | ConvertTo-Json -Depth 10 -Compress
} finally {
    if ($callbackChanged) { [Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCallback }
}
