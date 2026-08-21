[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][string]$Query,
    [ValidateRange(1,100)][int]$Limit = 30,
    [string]$ConfigRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($Query)) { throw 'APP member search query is required.' }
if ($Query.IndexOfAny([char[]]@('"', "`r", "`n", '%')) -ge 0) { throw 'APP member search query contains unsupported characters.' }

$stage = 'script-path initialization'
try {
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { throw 'PSScriptRoot is empty.' }
    $modulePath = Join-Path $PSScriptRoot 'PucConfig.psm1'
    $authPath = Join-Path $PSScriptRoot 'Invoke-PucAuth.ps1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw "Module does not exist: $modulePath" }
    if (-not (Test-Path -LiteralPath $authPath -PathType Leaf)) { throw "Authentication script does not exist: $authPath" }

    $stage = 'config module loading'
    Import-Module $modulePath -Force
    $stage = 'config root resolution'
    $root = Get-PucConfigRoot $ConfigRoot
    if ([string]::IsNullOrWhiteSpace([string]$root)) { throw 'Resolved config root is empty.' }
    $stage = 'authentication validation'
    $validation = & $authPath -Action Ensure -Environment $Environment -ConfigRoot $root | ConvertFrom-Json
    if ($validation.valid -ne $true) { throw "Saved token is not usable ($($validation.reason))." }
    $stage = 'environment loading'
    $environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
$body = [ordered]@{
    cmd_name='account_list_request'
    puc_id=[string]$environmentConfig.pucId
    user_id=[string]$environmentConfig.adminAccount
    realm=[string]$environmentConfig.realm
    page_sizes=$Limit
    page_index=1
    querykey=$Query
    lock_query=0
    online_query=0
    is_fuzzy_qry=1
}
    $stage = 'dispatcher request'
    $uri = [uri](([uri]$environmentConfig.baseUrl).AbsoluteUri.TrimEnd('/') + '/confs')
    $response = Invoke-PucJsonRequest -Uri $uri -Body $body -Headers @{token=[string]$environmentConfig.token} -AllowInsecureTls ([bool]$environmentConfig.allowInsecureTls) -TimeoutSec 60 -Depth 60
if ($null -eq $response) { throw 'account_list_request returned an empty response.' }
$resultProperty = $response.PSObject.Properties['result']
if ($null -eq $resultProperty) { throw 'account_list_request returned a response without result.' }
if ([string]$resultProperty.Value -ne '0') { throw (New-PucApiFailureMessage -Operation 'account_list_request' -Response $response) }

    $stage = 'result conversion'
    $accountListProperty = $response.PSObject.Properties['account_list']
    $accountList = if ($null -eq $accountListProperty -or $null -eq $accountListProperty.Value) { @() } else { @($accountListProperty.Value) }
    $rows = @($accountList | ForEach-Object {
    $account = [string]$_.dispatcher_account
    $appPucId = [string]$_.dispatcher_no
    if ([string]::IsNullOrWhiteSpace($account) -or [string]::IsNullOrWhiteSpace($appPucId)) { return }
    $name = [string]$_.dispatcher_name
    [pscustomobject]@{
        account=$account
        name=$name
        appPucId=$appPucId
        label=if (-not [string]::IsNullOrWhiteSpace($name) -and $name -ne $account) { "$name($account)" } else { $account }
    }
    } | Sort-Object account -Unique)
    [pscustomobject]@{status='app-member-search';query=$Query;count=$rows.Count;results=$rows} | ConvertTo-Json -Depth 10 -Compress
} catch {
    $line = if ($null -ne $_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber -gt 0) { ", line $($_.InvocationInfo.ScriptLineNumber)" } else { '' }
    throw "APP member search failed during '$stage'$line`: $($_.Exception.Message)"
}
