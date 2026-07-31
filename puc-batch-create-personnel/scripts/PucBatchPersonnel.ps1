[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$AdapterPath,
    [switch]$DryRun,
    [switch]$PlanOnly
)

$ErrorActionPreference = 'Stop'
$config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
$script:originalCertificateCallback = $null
$script:certificateCallbackChanged = $false

function Restore-CertificateCallback {
    if ($script:certificateCallbackChanged) {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $script:originalCertificateCallback
        $script:certificateCallbackChanged = $false
    }
}
trap { Restore-CertificateCallback; throw $_ }

if ($config.allowInsecureTls -eq $true -and -not (Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')) {
    $script:originalCertificateCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    $script:certificateCallbackChanged = $true
}

foreach ($name in @('ipSuffix','startSequence','count','aliasPrefix','reportDirectory')) {
    if ($null -eq $config.$name -or [string]::IsNullOrWhiteSpace([string]$config.$name)) { throw "Required configuration value is missing: $name" }
}
if ([string]$config.ipSuffix -notmatch '^\d{1,3}$') { throw 'ipSuffix must contain one to three digits.' }
if ([int]$config.startSequence -lt 0 -or [int]$config.startSequence -gt 999) { throw 'startSequence must be between 0 and 999.' }
if ([int]$config.count -lt 1 -or [int]$config.count -gt 1000) { throw 'count must be between 1 and 1000.' }

function New-PersonValues([int]$sequence) {
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
        [pscustomobject]@{ sequence=$person.sequence; alias=$person.alias; officerId=$person.officerId; idNumber=$person.idNumber; mobile=$person.mobile; status='planned-offline'; reason='duplicates-not-checked' }
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

$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$authHeader = @{}
function Invoke-Operation([string]$name, [hashtable]$variables) {
    $operation = $adapter.operations.$name
    if ($null -eq $operation) { throw "Adapter operation is missing: $name" }
    $headers = @{}
    foreach ($property in $operation.headers.PSObject.Properties) { $headers[$property.Name] = Expand-Template $property.Value $variables }
    foreach ($key in $authHeader.Keys) { $headers[$key] = $authHeader[$key] }
    $params = @{ Method=$operation.method; Uri=$config.baseUrl.TrimEnd('/') + $operation.path; Headers=$headers; WebSession=$session; ContentType='application/json' }
    $body = Expand-Template $operation.bodyTemplate $variables
    if ($null -ne $body) { $params.Body = $body | ConvertTo-Json -Depth 50 -Compress }
    if ($config.allowInsecureTls -eq $true -and (Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')) { $params.SkipCertificateCheck = $true }
    $maxRetries = if ($name -eq 'createPersonnel') { 0 } elseif ($null -ne $config.maxReadRetries) { [int]$config.maxReadRetries } else { 2 }
    for ($attempt = 0; ; $attempt++) {
        try { return Invoke-RestMethod @params } catch {
            if ($attempt -ge $maxRetries) {
                $responseBody = $null
                if ($_.Exception.Response) { try { $reader=New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $responseBody=$reader.ReadToEnd(); $reader.Dispose() } catch {} }
                if ($responseBody) { throw "$($_.Exception.Message) Response: $responseBody" }
                throw
            }
            $statusCode = $null
            if ($_.Exception.Response) { try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {} }
            if ($null -ne $statusCode -and $statusCode -notin @(408,429) -and $statusCode -lt 500) { throw }
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
    if ([string](Get-PropertyPath $login $adapter.operations.login.selectors.success) -ne [string]$adapter.operations.login.selectors.successExpected) { throw 'Login API response reported failure.' }
    $token = Get-PropertyPath $login $adapter.token.responsePath
}
if ([string]::IsNullOrWhiteSpace($token)) { throw 'Authentication did not return a token.' }
$authHeader[$adapter.token.headerName] = $adapter.token.prefix + $token

$orgResponse = Invoke-Operation 'organizations' @{ username=$adminUser; realm=$config.realm; pucId=$config.pucId }
$orgRows = @(Get-PropertyPath $orgResponse $adapter.operations.organizations.selectors.rows)
$orgMatch = @($orgRows | Where-Object { $_.custom_org_alias -eq $config.rootOrganizationName })
if ($orgMatch.Count -ne 1) { throw "Root organization lookup returned $($orgMatch.Count) matches." }
$organizationId = $orgMatch[0].custom_org_id

function Find-Duplicate($person) {
    foreach ($field in @('officerId','idNumber','mobile')) {
        $value = [string]$person.$field
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
        $results.Add([pscustomobject]@{ sequence=$sequence; alias=$person.alias; officerId=$person.officerId; idNumber=$person.idNumber; mobile=$person.mobile; status='skipped'; reason="duplicate-$duplicateField" })
        $sequence++
        continue
    }
    if ($DryRun) {
        $results.Add([pscustomobject]@{ sequence=$sequence; alias=$person.alias; officerId=$person.officerId; idNumber=$person.idNumber; mobile=$person.mobile; status='planned'; reason='' })
        $created++
    } elseif ($PSCmdlet.ShouldProcess($person.alias, 'Create PUC personnel')) {
        try {
            $response = Invoke-Operation 'createPersonnel' @{ username=$adminUser; realm=$config.realm; pucId=$config.pucId; commandGuid=[guid]::NewGuid().ToString(); officerId=$person.officerId; alias=$person.alias; policeTypeGuid=$config.policeTypeGuid; organizationId=$organizationId; organizationName=$config.rootOrganizationName; idNumber=$person.idNumber; mobile=$person.mobile }
            if ([string](Get-PropertyPath $response $adapter.operations.createPersonnel.selectors.success) -ne [string]$adapter.operations.createPersonnel.selectors.successExpected) { throw "API response reported failure: $($response | ConvertTo-Json -Compress)" }
            $results.Add([pscustomobject]@{ sequence=$sequence; alias=$person.alias; officerId=$person.officerId; idNumber=$person.idNumber; mobile=$person.mobile; status='created'; reason='' })
            $created++
        } catch {
            $results.Add([pscustomobject]@{ sequence=$sequence; alias=$person.alias; officerId=$person.officerId; idNumber=$person.idNumber; mobile=$person.mobile; status='failed'; reason=$_.Exception.Message })
            Write-Results $results
            throw
        }
    }
    $sequence++
    Start-Sleep -Milliseconds ([int]$config.requestDelayMs)
}

Write-Results $results
Restore-CertificateCallback
