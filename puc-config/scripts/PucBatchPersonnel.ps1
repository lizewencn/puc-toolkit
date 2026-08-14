[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$AdapterPath,
    [switch]$DryRun,
    [switch]$PlanOnly
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json

foreach ($name in @('ipSuffix','startSequence','count','reportDirectory')) {
    if ($null -eq $config.$name -or [string]::IsNullOrWhiteSpace([string]$config.$name)) { throw "Required configuration value is missing: $name" }
}
if ([string]$config.ipSuffix -notmatch '^\d{1,3}$') { throw 'ipSuffix must contain one to three digits.' }
if ([int]$config.startSequence -lt 0 -or [int]$config.startSequence -gt 999) { throw 'startSequence must be between 0 and 999.' }
if ([int]$config.count -lt 1 -or [int]$config.count -gt 1000) { throw 'count must be between 1 and 1000.' }
if ([string]::IsNullOrWhiteSpace([string]$config.exactAlias) -and [string]::IsNullOrWhiteSpace([string]$config.aliasPrefix)) { throw 'Provide exactAlias or aliasPrefix.' }
if (-not [string]::IsNullOrWhiteSpace([string]$config.exactAlias) -and [int]$config.count -ne 1) { throw 'exactAlias supports exactly one personnel record.' }

function New-PersonValues([int]$sequence) {
    if (-not [string]::IsNullOrWhiteSpace([string]$config.exactAlias)) {
        return [pscustomobject]@{ sequence=$sequence; alias=[string]$config.exactAlias; officerId=''; idNumber=''; mobile='' }
    }
    $ip = ([int]$config.ipSuffix).ToString('000')
    $suffix = $sequence.ToString('000')
    [pscustomobject]@{
        sequence = $sequence
        alias = "$($config.aliasPrefix)$ip$suffix"
        officerId = "$ip$($sequence.ToString('00000'))"
        idNumber = "9$ip$($sequence.ToString('0000'))"
        mobile = "139$ip$($sequence.ToString('00000'))"
    }
}

function Write-Results($items) {
    $reportDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($config.reportDirectory)
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $items | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $reportDir "puc-personnel-$stamp.json") -Encoding UTF8
    $items | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath (Join-Path $reportDir "puc-personnel-$stamp.csv")
    $items | Format-Table -AutoSize
}

if ($PlanOnly) {
    $planned = for ($offset = 0; $offset -lt [int]$config.count; $offset++) {
        $person = New-PersonValues ([int]$config.startSequence + $offset)
        [pscustomobject]@{ sequence=$person.sequence; alias=$person.alias; dispatcherAccount=[string]$config.dispatcherAccount; officerId=$person.officerId; idNumber=$person.idNumber; mobile=$person.mobile; status='planned-offline'; reason='duplicates-not-checked' }
    }
    Write-Results @($planned)
    return
}

if ([string]::IsNullOrWhiteSpace($AdapterPath)) { throw 'AdapterPath is required unless PlanOnly is used.' }
$adapter = Get-Content -Raw -LiteralPath $AdapterPath | ConvertFrom-Json

function Get-EnvironmentValue([string]$name, [switch]$Required) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($Required -and [string]::IsNullOrWhiteSpace($value)) { throw "Required environment variable is missing: $name" }
    return $value
}
function Get-PropertyPath($object, [string]$path) {
    $current = $object
    foreach ($part in $path.Split('.')) { if ($null -eq $current) { return $null }; $current = $current.$part }
    return $current
}
function Expand-Template($value, [hashtable]$variables) {
    if ($null -eq $value) { return $null }
    if ($value -is [pscustomobject]) {
        $copy = [ordered]@{}
        foreach ($property in $value.PSObject.Properties) { $copy[$property.Name] = Expand-Template $property.Value $variables }
        return [pscustomobject]$copy
    }
    if (($value -is [System.Collections.IEnumerable]) -and -not ($value -is [string])) {
        $items = @($value | ForEach-Object { Expand-Template $_ $variables })
        return ,$items
    }
    if ($value -isnot [string]) { return $value }
    if ($value -match '^\{\{([^{}]+)\}\}$') {
        if (-not $variables.ContainsKey($Matches[1])) { throw "Template variable is missing: $($Matches[1])" }
        return $variables[$Matches[1]]
    }
    $expanded = $value
    foreach ($key in $variables.Keys) { if ($variables[$key] -is [string] -or $null -eq $variables[$key]) { $expanded = $expanded.Replace("{{${key}}}", [string]$variables[$key]) } }
    if ($expanded -match '\{\{[^{}]+\}\}') { throw "Unresolved template value: $expanded" }
    return $expanded
}

$cookieJar = @{}
$authHeader = @{}
function Invoke-Operation([string]$name, [hashtable]$variables) {
    $operation = $adapter.operations.$name
    if ($null -eq $operation) { throw "Adapter operation is missing: $name" }
    $headers = @{}
    foreach ($property in $operation.headers.PSObject.Properties) { $headers[$property.Name] = Expand-Template $property.Value $variables }
    foreach ($key in $authHeader.Keys) { $headers[$key] = $authHeader[$key] }
    $body = Expand-Template $operation.bodyTemplate $variables
    $maxRetries = if ($name -in @('createPersonnel','createExactPersonnel')) { 0 } elseif ($null -ne $config.maxReadRetries) { [int]$config.maxReadRetries } else { 0 }
    for ($attempt = 0; ; $attempt++) {
        try {
            return Invoke-PucJsonHttpRequest -Method ([string]$operation.method) -Uri ([uri]($config.baseUrl.TrimEnd('/') + $operation.path)) -Headers $headers -Body $body -AllowInsecureTls ([bool]$config.allowInsecureTls) -TimeoutSec 60 -CookieJar $cookieJar -Depth 50
        } catch {
            if ($attempt -ge $maxRetries) {
                throw
            }
            Start-Sleep -Milliseconds ([Math]::Min(5000, 500 * [Math]::Pow(2, $attempt)))
        }
    }
}

$adminUser = Get-EnvironmentValue $config.loginUserEnv -Required
$token = Get-EnvironmentValue $config.tokenEnv
if ([string]::IsNullOrWhiteSpace($token)) {
    $adminPassword = Get-EnvironmentValue $config.loginPasswordEnv -Required
    $captchaResponse = Invoke-Operation 'captcha' @{}
    $captchaId = Get-PropertyPath $captchaResponse $adapter.captcha.idResponsePath
    $captchaImage = [string](Get-PropertyPath $captchaResponse $adapter.captcha.imageResponsePath)
    if (-not $captchaId -or -not $captchaImage) { throw 'Captcha response did not contain both an ID and an image.' }
    $imagePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath([string]$config.captchaImagePath)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $imagePath) | Out-Null
    $base64 = if ($captchaImage.Contains(',')) { $captchaImage.Substring($captchaImage.IndexOf(',') + 1) } else { $captchaImage }
    [IO.File]::WriteAllBytes($imagePath, [Convert]::FromBase64String($base64))
    Write-Host "Captcha image: $imagePath"
    if ($config.openCaptchaImage -eq $true) { Start-Process -FilePath $imagePath }
    $captchaValue = Get-EnvironmentValue $config.captchaValueEnv
    if ([string]::IsNullOrWhiteSpace($captchaValue)) { $captchaValue = Read-Host 'Enter the captcha shown in the image' }
    $login = Invoke-Operation 'login' @{ username=$adminUser; password=$adminPassword; realm=$config.realm; pucId=$config.pucId; captchaId=$captchaId; captchaValue=$captchaValue }
    if ([string](Get-PropertyPath $login $adapter.operations.login.selectors.success) -ne [string]$adapter.operations.login.selectors.successExpected) { throw (New-PucApiFailureMessage -Operation 'Login API' -Response $login) }
    $token = Get-PropertyPath $login $adapter.token.responsePath
}
if ([string]::IsNullOrWhiteSpace($token)) { throw 'Authentication did not return a token.' }
$authHeader[$adapter.token.headerName] = $adapter.token.prefix + $token

$organizationId = ''
$organizationName = ''
if ([string]::IsNullOrWhiteSpace([string]$config.exactAlias)) {
$orgResponse = Invoke-Operation 'organizations' @{ username=$adminUser; realm=$config.realm; pucId=$config.pucId }
$orgRows = @(Get-PropertyPath $orgResponse $adapter.operations.organizations.selectors.rows)
$orgMatch = if ([string]::IsNullOrWhiteSpace([string]$config.rootOrganizationName)) {
    if ($orgRows.Count -eq 1) { @($orgRows[0]) }
    else {
        @($orgRows | Where-Object {
            $parents = @($_.parent_custom_org_id, $_.parent_org_identifier, $_.parent_id) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
            $parents.Count -eq 0
        })
    }
} else {
    @($orgRows | Where-Object { $_.custom_org_alias -eq $config.rootOrganizationName })
}
$orgMatchCount = @($orgMatch).Count
if ($orgMatchCount -ne 1) { throw "Root organization lookup returned $orgMatchCount matches." }
$organizationRecord = @($orgMatch)[0]
$organizationId = $organizationRecord.custom_org_id
$organizationName = [string]$organizationRecord.custom_org_alias
}

$dispatcher = $null
if (-not [string]::IsNullOrWhiteSpace([string]$config.dispatcherAccount)) {
    $accountResponse = Invoke-Operation 'searchAccount' @{ username=$adminUser; realm=$config.realm; pucId=$config.pucId; query=[string]$config.dispatcherAccount }
    $accountRows = @(Get-PropertyPath $accountResponse $adapter.operations.searchAccount.selectors.rows)
    $accountSelector = [string]$adapter.operations.searchAccount.selectors.account
    $accountMatches = @($accountRows | Where-Object { [string](Get-PropertyPath $_ $accountSelector) -eq [string]$config.dispatcherAccount })
    if ($accountMatches.Count -ne 1) { throw "Dispatcher account '$($config.dispatcherAccount)' lookup returned $($accountMatches.Count) exact matches." }
    $dispatcherName = [string](Get-PropertyPath $accountMatches[0] ([string]$adapter.operations.searchAccount.selectors.name))
    $dispatcherDisplayName = if (-not [string]::IsNullOrWhiteSpace($dispatcherName) -and $dispatcherName -ne [string]$config.dispatcherAccount) { "$dispatcherName($($config.dispatcherAccount))" } else { [string]$config.dispatcherAccount }
    $dispatcher = [pscustomobject]@{ account=[string]$config.dispatcherAccount; displayName=$dispatcherDisplayName }
}
$dispatcherAccountValue = if ($null -ne $dispatcher) { $dispatcher.account } else { '' }
$dispatcherNameValue = if ($null -ne $dispatcher) { $dispatcher.displayName } else { '' }

function Find-Duplicate($person) {
    foreach ($field in @('alias','officerId','idNumber','mobile')) {
        $value = [string]$person.$field
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $response = Invoke-Operation 'searchPersonnel' @{ username=$adminUser; realm=$config.realm; pucId=$config.pucId; query=$value; commandGuid=[guid]::NewGuid().ToString() }
        $rows = @(Get-PropertyPath $response $adapter.operations.searchPersonnel.selectors.rows)
        $selector = [string]$adapter.operations.searchPersonnel.selectors.$field
        if (@($rows | Where-Object { [string](Get-PropertyPath $_ $selector) -eq $value }).Count -gt 0) { return $field }
    }
    return $null
}

$results = [System.Collections.Generic.List[object]]::new()
$created = 0
$sequence = [int]$config.startSequence
$scanned = 0
$maxScan = if ($config.maxScanCount) { [int]$config.maxScanCount } else { [Math]::Max([int]$config.count * 10,100) }
while ($created -lt [int]$config.count) {
    $scanned++
    if ($scanned -gt $maxScan) { throw "Stopped after scanning $maxScan sequences." }
    if ($sequence -gt 999) { throw 'No more three-digit sequence values are available.' }
    $person = New-PersonValues $sequence
    $duplicateField = Find-Duplicate $person
    if ($duplicateField) {
        $results.Add([pscustomobject]@{ sequence=$sequence; alias=$person.alias; dispatcherAccount=$dispatcherAccountValue; officerId=$person.officerId; idNumber=$person.idNumber; mobile=$person.mobile; status='skipped'; reason="duplicate-$duplicateField" })
        if (-not [string]::IsNullOrWhiteSpace([string]$config.exactAlias)) { break }
        $sequence++
        continue
    }
    if ($DryRun) {
        $results.Add([pscustomobject]@{ sequence=$sequence; alias=$person.alias; dispatcherAccount=$dispatcherAccountValue; officerId=$person.officerId; idNumber=$person.idNumber; mobile=$person.mobile; status='planned'; reason='' })
        $created++
    } elseif ($PSCmdlet.ShouldProcess($person.alias, 'Create PUC personnel')) {
        try {
            $createOperation = if (-not [string]::IsNullOrWhiteSpace([string]$config.exactAlias)) { 'createExactPersonnel' } else { 'createPersonnel' }
            $response = Invoke-Operation $createOperation @{ username=$adminUser; realm=$config.realm; pucId=$config.pucId; commandGuid=[guid]::NewGuid().ToString(); officerId=$person.officerId; alias=$person.alias; policeTypeGuid=$config.policeTypeGuid; organizationId=$organizationId; organizationName=$organizationName; idNumber=$person.idNumber; mobile=$person.mobile; dispatcherAccount=$dispatcherAccountValue; dispatcherName=$dispatcherNameValue }
            if ([string](Get-PropertyPath $response $adapter.operations.$createOperation.selectors.success) -ne [string]$adapter.operations.$createOperation.selectors.successExpected) { throw (New-PucApiFailureMessage -Operation $createOperation -Response $response) }
            $results.Add([pscustomobject]@{ sequence=$sequence; alias=$person.alias; dispatcherAccount=$dispatcherAccountValue; officerId=$person.officerId; idNumber=$person.idNumber; mobile=$person.mobile; status='created'; reason='' })
            $created++
        } catch {
            $results.Add([pscustomobject]@{ sequence=$sequence; alias=$person.alias; dispatcherAccount=$dispatcherAccountValue; officerId=$person.officerId; idNumber=$person.idNumber; mobile=$person.mobile; status='failed'; reason=$_.Exception.Message })
            Write-Results $results
            throw
        }
    }
    $sequence++
    Start-Sleep -Milliseconds ([int]$config.requestDelayMs)
}

Write-Results $results
