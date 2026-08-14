[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][ValidateSet('Status','Enable','Disable')][string]$Action,
    [switch]$PlanOnly,
    [switch]$DryRun,
    [switch]$Live,
    [switch]$ConfirmLive,
    [string]$ConfigRoot
)

$ErrorActionPreference = 'Stop'
if (@($PlanOnly,$DryRun,$Live | Where-Object { $_ }).Count -ne 1) { throw 'Select exactly one mode: PlanOnly, DryRun, or Live.' }
if ($Action -eq 'Status' -and $Live) { throw 'Status is read-only; use DryRun.' }
if ($Live -and -not $ConfirmLive) { throw 'Live modification requires ConfirmLive after explicit user approval.' }

Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$root = Get-PucConfigRoot $ConfigRoot
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
$baseUri = [uri]$environmentConfig.baseUrl
$neType = 'pucregcommon'
$desiredValue = switch ($Action) {
    'Enable' { 'True' }
    'Disable' { 'False' }
    default { '' }
}
$modifyCommand = if ($Action -eq 'Status') { '' } else {
    'MOD FunctionSwitchs : Indx = 0, Value = "{0}", Key = "FORCE_LOGIN", Description = "IS Allow Forced Login";' -f $desiredValue
}

if ($PlanOnly) {
    [pscustomobject]@{
        status='planned'; action=$Action; environment=$Environment
        endpoint=$baseUri.AbsoluteUri.TrimEnd('/') + '/nmpuc/mml/sendMML'
        neType=$neType; topologyDiscoveryRequired=$true; desiredValue=$desiredValue; command=$modifyCommand
        networkUsed=$false; writeUsed=$false
    } | ConvertTo-Json -Compress
    return
}

$validation = & (Join-Path $PSScriptRoot 'Invoke-PucAuth.ps1') -Action Ensure -Environment $Environment -ConfigRoot $root | ConvertFrom-Json
if ($validation.valid -ne $true) { throw "Saved token is not usable ($($validation.reason)). Complete the login workflow first." }
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
$baseUri = [uri]$environmentConfig.baseUrl

function Invoke-PlatformRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query,
        $Body
    )
    $builder = [UriBuilder]($baseUri.AbsoluteUri.TrimEnd('/') + $Path)
    if ($null -ne $Query -and $Query.Count -gt 0) {
        Add-Type -AssemblyName System.Web
        $queryString = [System.Web.HttpUtility]::ParseQueryString('')
        foreach ($key in $Query.Keys) { $queryString[$key] = [string]$Query[$key] }
        $builder.Query = $queryString.ToString()
    }
    return Invoke-PucJsonHttpRequest -Method $Method -Uri $builder.Uri -Body $Body -Headers @{token=[string]$environmentConfig.token} -AllowInsecureTls ([bool]$environmentConfig.allowInsecureTls) -TimeoutSec 60 -Depth 30
}

function Get-DataItems($Value) {
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Collections.IDictionary]) { return @($Value.Values) }
    if ($Value -is [pscustomobject] -and $null -eq $Value.PSObject.Properties['neId'] -and $null -eq $Value.PSObject.Properties['moName']) {
        return @($Value.PSObject.Properties | ForEach-Object { $_.Value })
    }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) { return @($Value) }
    return @($Value)
}

function Assert-OuterSuccess($Response, [string]$Operation) {
    if ($null -eq $Response) { throw "$Operation returned an empty response." }
    if ([string]$Response.code -ne '0') { throw (New-PucApiFailureMessage -Operation $Operation -Response $Response) }
}

function Assert-MmlSuccess($Response, [string]$Operation) {
    Assert-OuterSuccess -Response $Response -Operation $Operation
    $inner = $Response.data.Response
    if ($null -eq $inner) { throw "$Operation did not return data.Response." }
    if ([string]$inner.ErrorCode -ne '0') {
        $message = [string]$inner.ErrorMsg
        if ([string]::IsNullOrWhiteSpace($message)) { $message = [string]$inner.ErrorMessage }
        throw (New-PucApiFailureMessage -Operation $Operation -Response $Response)
    }
    return $inner
}

function Get-ForceLoginRecord($MmlResponse) {
    $records = @($MmlResponse.Data)
    $matches = @($records | Where-Object { [string]$_.Indx -eq '0' -and [string]$_.Key -eq 'FORCE_LOGIN' })
    if ($matches.Count -ne 1) { throw "FORCE_LOGIN query returned $($matches.Count) exact records." }
    $value = [string]$matches[0].Value
    if ($value -notin @('True','False')) { throw "FORCE_LOGIN returned unsupported Value '$value'." }
    return $matches[0]
}

$topologyResponse = Invoke-PlatformRequest -Method GET -Path '/nmpuc/mml/getValidTopoInfo'
    Assert-OuterSuccess -Response $topologyResponse -Operation 'getValidTopoInfo'
    $topologyItems = @(Get-DataItems $topologyResponse.data)
    $topologyMatches = @($topologyItems | Where-Object {
        $derivedType = if ([string]$_.pid -eq '0' -and -not [string]::IsNullOrWhiteSpace([string]$_.serviceName)) { '{0}common' -f [string]$_.serviceName } else { '' }
        [string]$_.type -ieq $neType -or [string]$_.title -ieq $neType -or $derivedType -ieq $neType
    })
    if ($topologyMatches.Count -ne 1) { throw "Topology lookup for '$neType' returned $($topologyMatches.Count) matches." }
    $topology = $topologyMatches[0]
    $neId = $topology.neId
    $rawVersion = [string]$topology.imageVersion
    if ([string]::IsNullOrWhiteSpace($rawVersion)) { $rawVersion = [string]$topology.version }
    $neVersion = $rawVersion -replace '\.',''
    if ($null -eq $neId -or [string]::IsNullOrWhiteSpace([string]$neId)) { throw 'The pucregcommon topology node did not contain neId.' }
    if ([string]::IsNullOrWhiteSpace($neVersion)) { throw 'The pucregcommon topology node did not contain a usable version.' }

    $moResponse = Invoke-PlatformRequest -Method GET -Path '/nmpuc/mml/getMoConfigByType' -Query @{ type=$neType; imageVersion=$neVersion }
    Assert-OuterSuccess -Response $moResponse -Operation 'getMoConfigByType'
    $moItems = @(Get-DataItems $moResponse.data | ForEach-Object { if ($_ -is [string]) { $_ | ConvertFrom-Json } else { $_ } })
    $moMatches = @($moItems | Where-Object { [string]$_.moName -eq 'FunctionSwitchs' })
    if ($moMatches.Count -ne 1) { throw "FunctionSwitchs MO lookup returned $($moMatches.Count) matches." }
    $queryCommands = @($moMatches[0].commands | Where-Object { [string]$_.type -eq 'QRY' })
    if ($queryCommands.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$queryCommands[0].name)) { throw "FunctionSwitchs QRY command lookup returned $($queryCommands.Count) usable commands." }
    $queryCommand = '{0} FunctionSwitchs ;' -f [string]$queryCommands[0].name
    $queryBody = [ordered]@{ cmd=$queryCommand; neId=$neId; neType=$neType; neVersion=$neVersion }
    $queryResponse = Invoke-PlatformRequest -Method POST -Path '/nmpuc/mml/sendMML' -Body $queryBody
    $currentRecord = Get-ForceLoginRecord (Assert-MmlSuccess -Response $queryResponse -Operation 'FORCE_LOGIN query')
    $currentValue = [string]$currentRecord.Value

    if ($DryRun -or $Action -eq 'Status') {
        [pscustomobject]@{
            status=if ($Action -eq 'Status') { 'current' } elseif ($currentValue -eq $desiredValue) { 'no-change' } else { 'ready' }
            action=$Action; environment=$Environment; neId=$neId; neType=$neType; neVersion=$neVersion
            currentValue=$currentValue; desiredValue=$desiredValue; command=$modifyCommand
            networkUsed=$true; writeUsed=$false
        } | ConvertTo-Json -Compress
        return
    }

    if ($currentValue -eq $desiredValue) {
        [pscustomobject]@{
            status='unchanged'; action=$Action; environment=$Environment; neId=$neId; neType=$neType; neVersion=$neVersion
            currentValue=$currentValue; desiredValue=$desiredValue; writeUsed=$false; verified=$true
        } | ConvertTo-Json -Compress
        return
    }

    $modifyBody = [ordered]@{ cmd=$modifyCommand; neId=$neId; neType=$neType; neVersion=$neVersion }
    $modifyResponse = Invoke-PlatformRequest -Method POST -Path '/nmpuc/mml/sendMML' -Body $modifyBody
    $null = Assert-MmlSuccess -Response $modifyResponse -Operation 'FORCE_LOGIN modification'
    $verifyResponse = Invoke-PlatformRequest -Method POST -Path '/nmpuc/mml/sendMML' -Body $queryBody
    $verifiedRecord = Get-ForceLoginRecord (Assert-MmlSuccess -Response $verifyResponse -Operation 'FORCE_LOGIN verification')
    $verifiedValue = [string]$verifiedRecord.Value
    if ($verifiedValue -ne $desiredValue) { throw "FORCE_LOGIN modification was accepted but verification returned '$verifiedValue'. No retry was attempted." }
    [pscustomobject]@{
        status='updated'; action=$Action; environment=$Environment; neId=$neId; neType=$neType; neVersion=$neVersion
        previousValue=$currentValue; currentValue=$verifiedValue; desiredValue=$desiredValue; writeUsed=$true; verified=$true
    } | ConvertTo-Json -Compress
