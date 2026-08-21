[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][string]$Account,
    [switch]$PlanOnly,
    [switch]$DryRun,
    [switch]$Live,
    [switch]$ConfirmLive,
    [string]$ExpectedSnapshotHash,
    [string]$ConfigRoot,
    [switch]$SkipPostPolicyStatus
)

$ErrorActionPreference = 'Stop'
if (@($PlanOnly,$DryRun,$Live | Where-Object { $_ }).Count -ne 1) { throw 'Select exactly one mode: PlanOnly, DryRun, or Live.' }
if ([string]::IsNullOrWhiteSpace($Account)) { throw 'Account must not be empty.' }
if ($Live -and -not $ConfirmLive) { throw 'Live password reset requires ConfirmLive after explicit confirmation.' }
if ($Live -and [string]::IsNullOrWhiteSpace($ExpectedSnapshotHash)) { throw 'Live password reset requires ExpectedSnapshotHash from the authenticated dry run.' }

Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$root = Get-PucConfigRoot $ConfigRoot

if ($PlanOnly) {
    [pscustomobject]@{ status='planned-offline'; action='ResetAccountPassword'; environment=$Environment; account=$Account; networkUsed=$false; passwordCollected=$false; plannedWrites=2 } |
        ConvertTo-Json -Compress
    return
}

$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
$validation = & (Join-Path $PSScriptRoot 'Invoke-PucAuth.ps1') -Action Ensure -Environment $Environment -ConfigRoot $root | ConvertFrom-Json
if ($validation.valid -ne $true) { throw "Saved token is not usable ($($validation.reason)). Complete the login workflow first." }
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
$baseUri = [uri]$environmentConfig.baseUrl

function Get-PropertyValue($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = @($Object.PSObject.Properties.Match($Name)) | Select-Object -First 1
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Invoke-PucAccountRequest([hashtable]$Body) {
    $response = Invoke-PucJsonRequest -Uri ([uri]($baseUri.AbsoluteUri.TrimEnd('/') + '/confs')) -Body $Body -Headers @{token=[string]$environmentConfig.token} -AllowInsecureTls ([bool]$environmentConfig.allowInsecureTls) -TimeoutSec 60 -Depth 60
    if ($null -eq $response) { throw "$($Body.cmd_name) returned an empty response. No retry was attempted." }
    if ($null -ne $response.PSObject.Properties['result'] -and [string]$response.result -ne '0') {
        throw (New-PucApiFailureMessage -Operation ([string]$Body.cmd_name) -Response $response)
    }
    return $response
}

function Get-PostOperationPolicyStatus {
    if ($SkipPostPolicyStatus) { return $null }
    try {
        $policy = & (Join-Path $PSScriptRoot 'Invoke-PucFirstLoginPasswordCheck.ps1') -Environment $Environment -Action Status -DryRun -ConfigRoot $root | ConvertFrom-Json
        return [pscustomobject]@{
            known=$true; enabled=([int]$policy.currentFlag -eq 1); firstLoginChangeFlag=[int]$policy.currentFlag
            recommendation=$(if ([int]$policy.currentFlag -eq 1) { 'No policy change is required.' } else { 'Consider enabling first-login password validation.' })
        }
    } catch {
        return [pscustomobject]@{ known=$false; enabled=$null; firstLoginChangeFlag=$null; recommendation='Policy status is unknown; query the login policy before deciding whether to enable it.'; error=$_.Exception.Message }
    }
}

function Get-ExactAccount {
    $pageIndex = 1
    $matches = [Collections.Generic.List[object]]::new()
    while ($true) {
        $response = Invoke-PucAccountRequest ([ordered]@{
            cmd_name='account_list_request'; user_id=[string]$environmentConfig.adminAccount; realm=[string]$environmentConfig.realm
            page_sizes=30; page_index=$pageIndex; querykey=$Account; lock_query=0; filter=[ordered]@{by_role='';by_state=0}
        })
        foreach ($row in @((Get-PropertyValue $response 'account_list' @()))) {
            $rowAccount = [string](Get-PropertyValue $row 'dispatcher_account' '')
            if ([string]::IsNullOrWhiteSpace($rowAccount)) { continue }
            if ([string]::Equals($rowAccount,$Account,[StringComparison]::OrdinalIgnoreCase)) { $matches.Add($row) }
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

function Get-RecordHash($Record) {
    $json = $Record | ConvertTo-Json -Depth 60 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)) | ForEach-Object { $_.ToString('x2') }) -join '').ToUpperInvariant() }
    finally { $sha.Dispose() }
}

try {
    $timestampPassword = $null
    $finalPassword = $null
    $record = Get-ExactAccount
    $snapshotHash = Get-RecordHash $record
    if ($DryRun) {
        [pscustomobject]@{ status='previewed'; action='ResetAccountPassword'; environment=$Environment; account=[string]$record.dispatcher_account; snapshotHash=$snapshotHash; finalPasswordConfigured=(-not [string]::IsNullOrWhiteSpace([string]$environmentConfig.newAccountPassword)); plannedWrites=2; writesUsed=0 } |
            ConvertTo-Json -Compress
        return
    }
    if (-not [string]::Equals($snapshotHash,$ExpectedSnapshotHash,[StringComparison]::OrdinalIgnoreCase)) { throw 'Account snapshot changed or does not match the authenticated dry run. Run DryRun again before resetting the password.' }

    $finalPassword = [string]$environmentConfig.newAccountPassword
    if ([string]::IsNullOrWhiteSpace($finalPassword)) { throw "newAccountPassword is empty for environment '$Environment'. Fill it in config.json locally." }
    $timestampPassword = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString([Globalization.CultureInfo]::InvariantCulture)
    $timestampCipher = ConvertTo-PucDesHex $timestampPassword
    $finalCipher = ConvertTo-PucDesHex $finalPassword
    $payload = [ordered]@{}
    try {
        foreach ($property in $record.PSObject.Properties) { $payload[$property.Name] = $property.Value }
        $payload['cmd_name'] = 'update_account'
        $payload['is_change_pwd'] = 1
        if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $record 'puc_id' ''))) { $payload['puc_id'] = [string]$environmentConfig.pucId }
        $imei = Get-PropertyValue $record 'imei_list' @()
        if ($imei -is [string]) {
            $trimmed = $imei.Trim()
            if (-not $trimmed) { $payload['imei_list'] = @() }
            elseif ($trimmed.StartsWith('[')) { $payload['imei_list'] = @(($trimmed | ConvertFrom-Json)) }
            else { $payload['imei_list'] = @($trimmed -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        } else { $payload['imei_list'] = @($imei) }
        $payload['dispatcher_pwd'] = $timestampCipher
        $stage1Response = Invoke-PucAccountRequest $payload
        $payload['dispatcher_pwd'] = $finalCipher
        try { $stage2Response = Invoke-PucAccountRequest $payload }
        catch { throw "Timestamp password stage succeeded, but restoring newAccountPassword failed or was uncertain: $($_.Exception.Message)" }
    } finally {
        $timestampCipher = $null
        $finalCipher = $null
        if ($payload.Contains('dispatcher_pwd')) { $payload['dispatcher_pwd'] = $null }
    }
    $policyStatus = Get-PostOperationPolicyStatus
    [pscustomobject]@{ status='password-reset'; action='ResetAccountPassword'; environment=$Environment; account=[string]$record.dispatcher_account; snapshotHash=$snapshotHash; stage1Result=[string]$stage1Response.result; stage2Result=[string]$stage2Response.result; writesUsed=2; finalPasswordSource='newAccountPassword'; firstLoginPasswordValidation=$policyStatus } |
        ConvertTo-Json -Compress
} finally {
    $timestampPassword = $null
    $finalPassword = $null
}
