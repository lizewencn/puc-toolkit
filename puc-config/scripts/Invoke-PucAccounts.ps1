[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_]+$')][string]$Prefix,
    [Parameter(Mandatory)][ValidateRange(0,999)][int]$StartSequence,
    [ValidateRange(1,1000)][int]$Count = 1,
    [long]$DispatchStart,
    [string]$RoleName = '',
    [string]$RootOrganizationName = '',
    [switch]$PlanOnly,
    [switch]$DryRun,
    [switch]$Live,
    [switch]$ConfirmLive,
    [switch]$ContinueWhenMoreThan30Accounts,
    [string]$ConfigRoot
)

$ErrorActionPreference = 'Stop'
if (@($PlanOnly,$DryRun,$Live | Where-Object { $_ }).Count -ne 1) { throw 'Select exactly one mode: PlanOnly, DryRun, or Live.' }
if ($Live -and -not $ConfirmLive) { throw 'Live creation requires ConfirmLive after explicit user approval.' }
Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$root = Get-PucConfigRoot $ConfigRoot
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
if (-not $PlanOnly) {
    $validation = & (Join-Path $PSScriptRoot 'Invoke-PucAuth.ps1') -Action Ensure -Environment $Environment -ConfigRoot $root | ConvertFrom-Json
    if ($validation.valid -ne $true) { throw "Saved token is not usable ($($validation.reason)). Complete the login workflow first." }
    $environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
}
$uri = [uri]$environmentConfig.baseUrl
$ipAddress = $null
if (-not [Net.IPAddress]::TryParse($uri.Host, [ref]$ipAddress) -or $ipAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
    throw "Environment '$Environment' baseUrl host must be an IPv4 address so the account suffix can be derived."
}
$ipSuffix = [string]$ipAddress.GetAddressBytes()[-1]
$passwordCipher = '00000000000000000000000000000000'
if (-not $PlanOnly) {
    $newAccountPassword = [string]$environmentConfig.newAccountPassword
    if ([string]::IsNullOrWhiteSpace($newAccountPassword)) { throw "newAccountPassword is empty for environment '$Environment'. Fill it in config.json locally." }
    $passwordCipher = ConvertTo-PucDesHex $newAccountPassword
}
$temporaryPath = Join-Path ([IO.Path]::GetTempPath()) ("puc-config-accounts-" + [guid]::NewGuid().ToString('N') + '.json')
$batchConfig = [ordered]@{
    baseUrl=$environmentConfig.baseUrl; realm=$environmentConfig.realm; pucId=[string]$environmentConfig.pucId
    ipSuffix=$ipSuffix; startSequence=$StartSequence; count=$Count; accountPrefix=$Prefix; aliasPrefix=''
    dispatchStart=if ($PSBoundParameters.ContainsKey('DispatchStart')) { $DispatchStart } else { $null }
    defaultAccountPassword=$passwordCipher; highestRoleName=$RoleName; loginTerminalName='Dispatch APP'; rootOrganizationName=$RootOrganizationName
    allowInsecureTls=[bool]$environmentConfig.allowInsecureTls; requestDelayMs=250; maxReadRetries=0; maxScanCount=[Math]::Max($Count * 10,100)
    accountSearchPageSize=30; continueWhenMoreThanPageSizeAccounts=[bool]$ContinueWhenMoreThan30Accounts
    loginUserEnv='PUC_CONFIG_ADMIN_USER'; loginPasswordEnv=''; tokenEnv='PUC_CONFIG_TOKEN'
}
$batchConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
$oldToken = [Environment]::GetEnvironmentVariable('PUC_CONFIG_TOKEN')
$oldUser = [Environment]::GetEnvironmentVariable('PUC_CONFIG_ADMIN_USER')
try {
    if (-not $PlanOnly) {
        [Environment]::SetEnvironmentVariable('PUC_CONFIG_TOKEN', [string]$environmentConfig.token)
        [Environment]::SetEnvironmentVariable('PUC_CONFIG_ADMIN_USER', [string]$environmentConfig.adminAccount)
    }
    $script = Join-Path $PSScriptRoot 'PucBatchAccounts.ps1'
    $adapter = Join-Path $PSScriptRoot '..\references\accounts-adapter.json'
    if ($PlanOnly) { & $script -ConfigPath $temporaryPath -PlanOnly }
    elseif ($DryRun) { & $script -ConfigPath $temporaryPath -AdapterPath $adapter -DryRun }
    else {
        & $script -ConfigPath $temporaryPath -AdapterPath $adapter -Confirm:$false
        try {
            $policy = & (Join-Path $PSScriptRoot 'Invoke-PucFirstLoginPasswordCheck.ps1') -Environment $Environment -Action Status -DryRun -ConfigRoot $root | ConvertFrom-Json
            [pscustomobject]@{
                status='post-create-login-policy'; environment=$Environment
                firstLoginPasswordValidation=[pscustomobject]@{
                    known=$true; enabled=([int]$policy.currentFlag -eq 1); firstLoginChangeFlag=[int]$policy.currentFlag
                    recommendation=$(if ([int]$policy.currentFlag -eq 1) { 'No policy change is required.' } else { 'Consider enabling first-login password validation.' })
                }
            } | ConvertTo-Json -Depth 5 -Compress
        } catch {
            [pscustomobject]@{
                status='post-create-login-policy'; environment=$Environment
                firstLoginPasswordValidation=[pscustomobject]@{ known=$false; enabled=$null; firstLoginChangeFlag=$null; recommendation='Policy status is unknown; query the login policy before deciding whether to enable it.'; error=$_.Exception.Message }
            } | ConvertTo-Json -Depth 5 -Compress
        }
    }
} finally {
    [Environment]::SetEnvironmentVariable('PUC_CONFIG_TOKEN', $oldToken)
    [Environment]::SetEnvironmentVariable('PUC_CONFIG_ADMIN_USER', $oldUser)
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
}
