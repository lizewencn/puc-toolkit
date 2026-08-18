[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [string]$AliasPrefix = '',
    [ValidateRange(0,999)][int]$StartSequence = 0,
    [ValidateRange(1,1000)][int]$Count = 1,
    [string]$ExactAlias = '',
    [string]$DispatcherAccount = '',
    [ValidateSet(102,103,104)][int]$NumberType = 102,
    [string]$PersonnelTypeGuid = '',
    [string]$RootOrganizationName = '',
    [switch]$PlanOnly,
    [switch]$DryRun,
    [switch]$Live,
    [switch]$ConfirmLive,
    [string]$ConfigRoot
)

$ErrorActionPreference = 'Stop'
if (@($PlanOnly,$DryRun,$Live | Where-Object { $_ }).Count -ne 1) { throw 'Select exactly one mode: PlanOnly, DryRun, or Live.' }
if ($Live -and -not $ConfirmLive) { throw 'Live creation requires ConfirmLive after explicit user approval.' }
if ([string]::IsNullOrWhiteSpace($ExactAlias) -and [string]::IsNullOrWhiteSpace($AliasPrefix)) { throw 'Provide AliasPrefix or ExactAlias.' }
if (-not [string]::IsNullOrWhiteSpace($ExactAlias) -and $Count -ne 1) { throw 'ExactAlias supports exactly one personnel record.' }
Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$root = Get-PucConfigRoot $ConfigRoot
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
if (-not $PlanOnly) {
    $validation = & (Join-Path $PSScriptRoot 'Invoke-PucAuth.ps1') -Action Ensure -Environment $Environment -ConfigRoot $root | ConvertFrom-Json
    if ($validation.valid -ne $true) { throw "Saved token is not usable ($($validation.reason)). Complete the login workflow first." }
    $environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
}
$uri = [uri]$environmentConfig.baseUrl
$temporaryPath = Join-Path ([IO.Path]::GetTempPath()) ("puc-config-personnel-" + [guid]::NewGuid().ToString('N') + '.json')
$batchConfig = [ordered]@{
    baseUrl=$environmentConfig.baseUrl; realm=$environmentConfig.realm; pucId=[string]$environmentConfig.pucId
    ipSuffix=$uri.Host.Split('.')[-1]; startSequence=$StartSequence; count=$Count; aliasPrefix=$AliasPrefix
    exactAlias=$ExactAlias; dispatcherAccount=$DispatcherAccount
    rootOrganizationName=$RootOrganizationName; numberType=$NumberType; policeTypeGuid=$PersonnelTypeGuid; allowInsecureTls=[bool]$environmentConfig.allowInsecureTls
    requestDelayMs=250; maxReadRetries=0; maxScanCount=[Math]::Max($Count * 10,100)
    reportDirectory=Join-Path $root "reports\$Environment\personnel"; loginUserEnv='PUC_CONFIG_ADMIN_USER'; loginPasswordEnv=''; tokenEnv='PUC_CONFIG_TOKEN'
    captchaImagePath=Join-Path $root 'captcha.png'
}
$batchConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
$oldToken = [Environment]::GetEnvironmentVariable('PUC_CONFIG_TOKEN')
$oldUser = [Environment]::GetEnvironmentVariable('PUC_CONFIG_ADMIN_USER')
try {
    if (-not $PlanOnly) {
        [Environment]::SetEnvironmentVariable('PUC_CONFIG_TOKEN', [string]$environmentConfig.token)
        [Environment]::SetEnvironmentVariable('PUC_CONFIG_ADMIN_USER', [string]$environmentConfig.adminAccount)
    }
    $script = Join-Path $PSScriptRoot 'PucBatchPersonnel.ps1'
    $adapter = Join-Path $PSScriptRoot '..\references\personnel-adapter.json'
    if ($PlanOnly) { & $script -ConfigPath $temporaryPath -PlanOnly }
    elseif ($DryRun) { & $script -ConfigPath $temporaryPath -AdapterPath $adapter -DryRun }
    else { & $script -ConfigPath $temporaryPath -AdapterPath $adapter -Confirm:$false }
} finally {
    [Environment]::SetEnvironmentVariable('PUC_CONFIG_TOKEN', $oldToken)
    [Environment]::SetEnvironmentVariable('PUC_CONFIG_ADMIN_USER', $oldUser)
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
}
