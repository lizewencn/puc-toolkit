[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][ValidateSet('Status','Enable','Disable')][string]$Action,
    [switch]$PlanOnly,
    [switch]$DryRun,
    [switch]$Live,
    [switch]$ConfirmLive,
    [string]$ConfigRoot,
    [string]$EndpointOverride
)

$ErrorActionPreference = 'Stop'
if (@($PlanOnly,$DryRun,$Live | Where-Object { $_ }).Count -ne 1) { throw 'Select exactly one mode: PlanOnly, DryRun, or Live.' }
if ($Action -eq 'Status' -and $Live) { throw 'Status is read-only; use DryRun.' }
if ($Live -and -not $ConfirmLive) { throw 'Live first-login password validation modification requires ConfirmLive; an explicit user enable/disable instruction supplies this confirmation.' }
if (-not [string]::IsNullOrWhiteSpace($EndpointOverride) -and [Environment]::GetEnvironmentVariable('PUC_CONFIG_TEST_MODE') -ne '1') { throw 'EndpointOverride is available only in test mode.' }

Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$desiredFlag = switch ($Action) { 'Enable' { 1 } 'Disable' { 0 } default { $null } }

if ($PlanOnly) {
    [pscustomobject]@{
        status='planned-offline'; action=$Action; environment=$Environment
        queryCommand='conf_query_dc_pwd_config_request'; editCommand='conf_edit_dc_pwd_config_req'
        desiredFlag=$desiredFlag; dynamicConfigurationGuidRequired=$true
        networkUsed=$false; writeUsed=$false
    } | ConvertTo-Json -Compress
    return
}

$root = Get-PucConfigRoot $ConfigRoot
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
if ([string]::IsNullOrWhiteSpace($EndpointOverride)) {
    $validation = & (Join-Path $PSScriptRoot 'Invoke-PucAuth.ps1') -Action Validate -Environment $Environment -ConfigRoot $root | ConvertFrom-Json
    if ($validation.valid -ne $true) { throw "Saved token is not usable ($($validation.reason)). Complete the login workflow first." }
    $environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
}
$endpoint = if ([string]::IsNullOrWhiteSpace($EndpointOverride)) { $environmentConfig.baseUrl.TrimEnd('/') + '/confs' } else { $EndpointOverride }
$headers = @{ token=[string]$environmentConfig.token }

function Assert-ApiSuccess($Response,[string]$Operation) {
    if ($null -eq $Response) { throw "$Operation returned an empty response. No retry was attempted." }
    $resultProperty = $Response.PSObject.Properties['result']
    if ($null -eq $resultProperty) { throw "$Operation response did not contain result. No retry was attempted." }
    if ([string]$resultProperty.Value -ne '0') { throw "$Operation failed: result=$([string]$resultProperty.Value); msg=$([string]$Response.msg). No retry was attempted." }
}

function Invoke-PolicyRequest($Body) {
    return Invoke-PucJsonRequest -Uri ([uri]$endpoint) -Body $Body -Headers $headers -AllowInsecureTls ($environmentConfig.allowInsecureTls -eq $true)
}

function Get-CurrentPolicy {
    $body = [ordered]@{
        product_name='PUC'; version='10'; cmd_name='conf_query_dc_pwd_config_request'
        cmd_guid=[guid]::NewGuid().ToString(); guid=[guid]::NewGuid().ToString()
        puc_id=[string]$environmentConfig.pucId; user_id=[string]$environmentConfig.adminAccount; realm=[string]$environmentConfig.realm
    }
    $response = Invoke-PolicyRequest $body
    Assert-ApiSuccess $response 'First-login password validation query'
    $config = $response.dispatcher_password_config
    if ($null -eq $config) { throw 'First-login password validation query succeeded but dispatcher_password_config was empty.' }
    $configurationGuid = [string]$config.guid
    if ([string]::IsNullOrWhiteSpace($configurationGuid)) { throw 'First-login password validation query succeeded but dispatcher_password_config.guid was empty.' }
    $flagProperty = $config.PSObject.Properties['first_login_change_flag']
    $flagDefaulted = $null -eq $flagProperty -or $null -eq $flagProperty.Value
    $flag = 0
    if (-not $flagDefaulted -and (-not [int]::TryParse([string]$flagProperty.Value,[ref]$flag) -or $flag -notin @(0,1))) {
        throw "First-login password validation query returned unsupported first_login_change_flag '$([string]$flagProperty.Value)'."
    }
    return [pscustomobject]@{ Guid=$configurationGuid; Flag=$flag; FlagDefaulted=$flagDefaulted }
}

$current = Get-CurrentPolicy
if ($DryRun -or $Action -eq 'Status') {
    [pscustomobject]@{
        status=if ($Action -eq 'Status') { 'current' } elseif ($current.Flag -eq $desiredFlag) { 'no-change' } else { 'ready' }
        action=$Action; environment=$Environment; configurationGuid=$current.Guid
        currentFlag=$current.Flag; currentEnabled=($current.Flag -eq 1); flagDefaulted=$current.FlagDefaulted
        desiredFlag=$desiredFlag; writeRequired=($null -ne $desiredFlag -and $current.Flag -ne $desiredFlag)
        networkUsed=$true; writeUsed=$false
    } | ConvertTo-Json -Compress
    return
}

if ($current.Flag -eq $desiredFlag) {
    [pscustomobject]@{
        status='unchanged'; action=$Action; environment=$Environment; configurationGuid=$current.Guid
        currentFlag=$current.Flag; currentEnabled=($current.Flag -eq 1); flagDefaulted=$current.FlagDefaulted; writeUsed=$false; verified=$true
    } | ConvertTo-Json -Compress
    return
}

$editBody = [ordered]@{
    cmd_name='conf_edit_dc_pwd_config_req'; cmd_guid=[guid]::NewGuid().ToString(); guid=$current.Guid
    puc_id=[string]$environmentConfig.pucId; user_id=[string]$environmentConfig.adminAccount; realm=[string]$environmentConfig.realm
    first_login_change_flag=$desiredFlag
}
$editResponse = Invoke-PolicyRequest $editBody
Assert-ApiSuccess $editResponse 'First-login password validation edit'
$verified = Get-CurrentPolicy
if ($verified.Guid -ne $current.Guid) { throw "First-login password validation edit succeeded but verification returned a different configuration GUID. No retry was attempted." }
if ($verified.Flag -ne $desiredFlag) { throw "First-login password validation edit succeeded but verification returned flag '$($verified.Flag)'. No retry was attempted." }
[pscustomobject]@{
    status='updated'; action=$Action; environment=$Environment; configurationGuid=$verified.Guid
    previousFlag=$current.Flag; currentFlag=$verified.Flag; currentEnabled=($verified.Flag -eq 1); flagDefaulted=$verified.FlagDefaulted
    writeUsed=$true; verified=$true
} | ConvertTo-Json -Compress
