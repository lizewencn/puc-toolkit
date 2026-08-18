[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][string]$Query,
    [ValidateRange(1,100)][int]$Limit = 30,
    [string]$ConfigRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($Query)) { throw 'Dispatcher search query is required.' }
if ($Query.IndexOfAny([char[]]@('"', "`r", "`n", '%')) -ge 0) { throw 'Dispatcher search query contains unsupported characters.' }

Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$root = Get-PucConfigRoot $ConfigRoot
$validation = & (Join-Path $PSScriptRoot 'Invoke-PucAuth.ps1') -Action Ensure -Environment $Environment -ConfigRoot $root | ConvertFrom-Json
if ($validation.valid -ne $true) { throw "Saved token is not usable ($($validation.reason))." }
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
$uri = [uri](([uri]$environmentConfig.baseUrl).AbsoluteUri.TrimEnd('/') + '/confs')
$response = Invoke-PucJsonRequest -Uri $uri -Body $body -Headers @{token=[string]$environmentConfig.token} -AllowInsecureTls ([bool]$environmentConfig.allowInsecureTls) -TimeoutSec 60 -Depth 60
if ($null -eq $response) { throw 'account_list_request returned an empty response.' }
$resultProperty = $response.PSObject.Properties['result']
if ($null -eq $resultProperty) { throw 'account_list_request returned a response without result.' }
if ([string]$resultProperty.Value -ne '0') { throw (New-PucApiFailureMessage -Operation 'account_list_request' -Response $response) }

$accountListProperty = $response.PSObject.Properties['account_list']
$accountList = if ($null -eq $accountListProperty -or $null -eq $accountListProperty.Value) { @() } else { @($accountListProperty.Value) }
$rows = @($accountList | ForEach-Object {
    $account = [string]$_.dispatcher_account
    if ([string]::IsNullOrWhiteSpace($account)) { return }
    $name = [string]$_.dispatcher_name
    [pscustomobject]@{
        account=$account
        name=$name
        label=if (-not [string]::IsNullOrWhiteSpace($name) -and $name -ne $account) { "$name($account)" } else { $account }
    }
} | Sort-Object account -Unique)
[pscustomobject]@{status='dispatcher-search';query=$Query;count=$rows.Count;results=$rows} | ConvertTo-Json -Depth 10 -Compress
