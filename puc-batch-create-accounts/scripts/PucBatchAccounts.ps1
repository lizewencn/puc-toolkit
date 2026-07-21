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

trap {
    Restore-CertificateCallback
    throw $_
}

if ($config.allowInsecureTls -eq $true -and -not (Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')) {
    $script:originalCertificateCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    $script:certificateCallbackChanged = $true
}

foreach ($name in @('ipSuffix','startSequence','count','accountPrefix','aliasPrefix','reportDirectory')) {
    if ($null -eq $config.$name -or [string]::IsNullOrWhiteSpace([string]$config.$name)) {
        throw "Required configuration value is missing: $name"
    }
}
if ([string]$config.ipSuffix -notmatch '^\d{1,3}$') { throw 'ipSuffix must contain one to three digits.' }
if ([int]$config.startSequence -lt 0 -or [int]$config.startSequence -gt 999) { throw 'startSequence must be between 0 and 999.' }
if ([int]$config.count -lt 1 -or [int]$config.count -gt 1000) { throw 'count must be between 1 and 1000.' }
if ([int]$config.startSequence + [int]$config.count -gt 1000) { throw 'The requested sequence range exceeds 999.' }

function Write-Results($items) {
    $reportDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($config.reportDirectory)
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $items | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath (Join-Path $reportDir "puc-accounts-$stamp.json") -Encoding UTF8
    $csvItems = foreach ($item in $items) {
        [pscustomobject]@{
            sequence = $item.sequence
            account = $item.account
            alias = $item.alias
            dispatchNumber = $item.dispatchNumber
            status = $item.status
            reason = $item.reason
            createRequestJson = if ($null -ne $item.createRequest) { $item.createRequest | ConvertTo-Json -Depth 50 -Compress } else { '' }
            createResponseJson = if ($null -ne $item.createResponse) { $item.createResponse | ConvertTo-Json -Depth 50 -Compress } else { '' }
        }
    }
    $csvItems | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath (Join-Path $reportDir "puc-accounts-$stamp.csv")
    $items | Format-Table -AutoSize
}

$script:lastDispatchTimestamp = [int64]0
function New-DispatchNumber {
    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($timestamp -le $script:lastDispatchTimestamp) { $timestamp = $script:lastDispatchTimestamp + 1 }
    $script:lastDispatchTimestamp = $timestamp
    return $timestamp.ToString()
}

if ($PlanOnly) {
    $planned = for ($offset = 0; $offset -lt [int]$config.count; $offset++) {
        $sequence = [int]$config.startSequence + $offset
        $suffix = $sequence.ToString('000')
        [pscustomobject]@{
            sequence = $sequence
            account = "$($config.accountPrefix)$($config.ipSuffix)$suffix"
            alias = "$($config.aliasPrefix)$suffix"
            dispatchNumber = New-DispatchNumber
            status = 'planned-offline'
            reason = 'duplicates-not-checked'
        }
    }
    Write-Results @($planned)
    return
}

if ([string]::IsNullOrWhiteSpace($AdapterPath)) { throw 'AdapterPath is required unless PlanOnly is used.' }
$adapter = Get-Content -Raw -LiteralPath $AdapterPath | ConvertFrom-Json
if (($adapter | ConvertTo-Json -Depth 50) -match 'REVIEW_REQUIRED') {
    throw 'Adapter contains REVIEW_REQUIRED fields. Resolve them before execution.'
}

function Get-RequiredEnvironment([string]$name) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Required environment variable is missing: $name" }
    return $value
}

function Get-OptionalEnvironment([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    return [Environment]::GetEnvironmentVariable($name)
}

function Get-PropertyPath($object, [string]$path) {
    $current = $object
    foreach ($part in $path.Split('.')) {
        if ($null -eq $current) { return $null }
        $current = $current.$part
    }
    return $current
}

function Get-Selector([string]$operationName, [string]$selectorName) {
    $operation = $adapter.operations.$operationName
    $value = $operation.selectors.$selectorName
    if ([string]::IsNullOrWhiteSpace([string]$value)) { $value = $adapter.selectors.$selectorName }
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        throw "Selector is missing: $operationName.$selectorName"
    }
    return [string]$value
}

function Expand-Template($value, [hashtable]$variables) {
    if ($null -eq $value) { return $null }
    if ($value -is [pscustomobject]) {
        $copy = [ordered]@{}
        foreach ($property in $value.PSObject.Properties) {
            $copy[$property.Name] = Expand-Template $property.Value $variables
        }
        return [pscustomobject]$copy
    }
    if (($value -is [System.Collections.IEnumerable]) -and -not ($value -is [string])) {
        $expandedItems = @($value | ForEach-Object { Expand-Template $_ $variables })
        return ,$expandedItems
    }
    if ($value -isnot [string]) { return $value }
    if ($value -match '^\{\{([^{}]+)\}\}$') {
        $key = $Matches[1]
        if (-not $variables.ContainsKey($key)) { throw "Template variable is missing: $key" }
        return $variables[$key]
    }
    $expanded = $value
    foreach ($key in $variables.Keys) {
        if ($variables[$key] -isnot [string] -and $null -ne $variables[$key]) { continue }
        $expanded = $expanded.Replace("{{${key}}}", [string]$variables[$key])
    }
    if ($expanded -match '\{\{[^{}]+\}\}') { throw "Unresolved template value: $expanded" }
    return $expanded
}

$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$authHeader = @{}

function Invoke-Operation([string]$name, [hashtable]$variables) {
    $operation = $adapter.operations.$name
    if ($null -eq $operation) { throw "Adapter operation is missing: $name" }
    $uri = $config.baseUrl.TrimEnd('/') + (Expand-Template ([string]$operation.path) $variables)
    $headers = @{}
    foreach ($property in $operation.headers.PSObject.Properties) {
        $headers[$property.Name] = Expand-Template $property.Value $variables
    }
    foreach ($key in $authHeader.Keys) { $headers[$key] = $authHeader[$key] }
    $body = Expand-Template $operation.bodyTemplate $variables
    $params = @{
        Method = $operation.method
        Uri = $uri
        Headers = $headers
        WebSession = $session
        ContentType = 'application/json'
    }
    if ($config.allowInsecureTls -eq $true) {
        if ((Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')) {
            $params.SkipCertificateCheck = $true
        }
    }
    if ($null -ne $body) { $params.Body = $body | ConvertTo-Json -Depth 50 -Compress }
    $maxRetries = if ($name -eq 'createAccount') { 0 } elseif ($null -ne $config.maxReadRetries) { [int]$config.maxReadRetries } else { 2 }
    for ($attempt = 0; ; $attempt++) {
        try {
            return Invoke-RestMethod @params
        } catch {
            if ($attempt -ge $maxRetries) {
                $responseBody = $null
                if ($_.Exception.Response) {
                    try {
                        $stream = $_.Exception.Response.GetResponseStream()
                        if ($stream) {
                            $reader = New-Object IO.StreamReader($stream)
                            $responseBody = $reader.ReadToEnd()
                            $reader.Dispose()
                        }
                    } catch { $responseBody = $null }
                }
                if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
                    throw "$($_.Exception.Message) Response: $responseBody"
                }
                throw
            }
            $statusCode = $null
            if ($_.Exception.Response) {
                try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = $null }
            }
            if ($null -ne $statusCode -and $statusCode -notin @(408, 429) -and $statusCode -lt 500) { throw }
            Start-Sleep -Milliseconds ([Math]::Min(5000, 500 * [Math]::Pow(2, $attempt)))
        }
    }
}

$adminUser = Get-RequiredEnvironment $config.loginUserEnv
$newPassword = [string]$config.defaultAccountPassword
if ($newPassword -notmatch '^[0-9a-fA-F]{32}$') {
    throw 'defaultAccountPassword must be a 32-character hexadecimal ciphertext. Plaintext account passwords are not allowed.'
}
$newPassword = $newPassword.ToLowerInvariant()

$token = Get-OptionalEnvironment $config.tokenEnv
if ([string]::IsNullOrWhiteSpace($token)) {
    $adminPassword = Get-RequiredEnvironment $config.loginPasswordEnv
    $captchaId = $null
    $captchaValue = $null
    if ($adapter.operations.captcha) {
        $captchaResponse = Invoke-Operation 'captcha' @{}
        $captchaId = Get-PropertyPath $captchaResponse $adapter.captcha.idResponsePath
        $captchaImage = [string](Get-PropertyPath $captchaResponse $adapter.captcha.imageResponsePath)
        if ([string]::IsNullOrWhiteSpace($captchaId) -or [string]::IsNullOrWhiteSpace($captchaImage)) {
            throw 'Captcha response did not contain both an ID and an image.'
        }
        $imagePath = if ($config.captchaImagePath) {
            $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath([string]$config.captchaImagePath)
        } else {
            Join-Path ([IO.Path]::GetTempPath()) 'puc-login-captcha.png'
        }
        $imageParent = Split-Path -Parent $imagePath
        if ($imageParent) { New-Item -ItemType Directory -Force -Path $imageParent | Out-Null }
        $base64 = if ($captchaImage.Contains(',')) { $captchaImage.Substring($captchaImage.IndexOf(',') + 1) } else { $captchaImage }
        [IO.File]::WriteAllBytes($imagePath, [Convert]::FromBase64String($base64))
        Write-Host "Captcha image: $imagePath"
        if ($config.openCaptchaImage -eq $true) { Start-Process -FilePath $imagePath }
        $captchaValue = Get-OptionalEnvironment $config.captchaValueEnv
        if ([string]::IsNullOrWhiteSpace($captchaValue)) { $captchaValue = Read-Host 'Enter the captcha shown in the image' }
        if ([string]::IsNullOrWhiteSpace($captchaValue)) { throw 'Captcha value is required.' }
    }
    $loginResponse = Invoke-Operation 'login' @{
        username = $adminUser
        password = $adminPassword
        realm = $config.realm
        captchaId = $captchaId
        captchaValue = $captchaValue
    }
    $loginSuccessPath = $adapter.operations.login.selectors.success
    if ($loginSuccessPath) {
        $loginSuccess = Get-PropertyPath $loginResponse $loginSuccessPath
        $loginExpected = $adapter.operations.login.selectors.successExpected
        if ([string]$loginSuccess -ne [string]$loginExpected) { throw 'Login API response reported failure.' }
    }
    $token = Get-PropertyPath $loginResponse $adapter.token.responsePath
}
if ([string]::IsNullOrWhiteSpace($token)) { throw 'Authentication did not return a token.' }
$authHeader[$adapter.token.headerName] = $adapter.token.prefix + $token

function Get-LookupId([string]$operationName, [string]$wantedName) {
    $response = Invoke-Operation $operationName @{ realm = $config.realm; username = $adminUser }
    $rows = @(Get-PropertyPath $response (Get-Selector $operationName 'rows'))
    $nameSelector = Get-Selector $operationName 'name'
    $idSelector = Get-Selector $operationName 'id'
    $match = @($rows | Where-Object { (Get-PropertyPath $_ $nameSelector) -eq $wantedName })
    if ($match.Count -ne 1) { throw "$operationName lookup for '$wantedName' returned $($match.Count) matches" }
    return Get-PropertyPath $match[0] $idSelector
}

$roleId = Get-LookupId 'roles' $config.highestRoleName
$systemResponse = Invoke-Operation 'systems' @{ realm = $config.realm; username = $adminUser }
$systemIds = @((Get-PropertyPath $systemResponse (Get-Selector 'systems' 'rows')) | ForEach-Object { Get-PropertyPath $_ (Get-Selector 'systems' 'id') })
if ($systemIds.Count -eq 0 -or @($systemIds | Where-Object { $null -eq $_ }).Count -gt 0) {
    throw 'System lookup returned no usable IDs; refusing to create an account without full system authorization.'
}
$accessResponse = Invoke-Operation 'accessPoints' @{ realm = $config.realm; username = $adminUser }
$accessRows = @(Get-PropertyPath $accessResponse (Get-Selector 'accessPoints' 'rows'))
$accessPointIds = @($accessRows | ForEach-Object { Get-PropertyPath $_ (Get-Selector 'accessPoints' 'id') })
if ($accessPointIds.Count -eq 0 -or @($accessPointIds | Where-Object { $null -eq $_ }).Count -gt 0) {
    throw 'Access-point lookup returned no usable IDs; refusing to create an account without full access-point authorization.'
}
$deviceRootId = Get-LookupId 'deviceOrganizations' $config.rootOrganizationName
$addressRootId = Get-LookupId 'addressBookOrganizations' $config.rootOrganizationName

$dispatchSapList = $null
if ($adapter.protocol -eq 'puc-command') {
    $sapItems = foreach ($accessPoint in $accessRows) {
        foreach ($sap in @($accessPoint.sap_list)) {
            [ordered]@{
                pucid = $sap.puc_id
                systemid = $sap.system_id
                grpname = $accessPoint.sap_alias
                realm = $sap.domain_name
                ssi = @([ordered]@{ label = [string]$sap.ssi; value = $sap.guid })
            }
        }
    }
    # The API expects this field to contain serialized JSON, not a nested object.
    $dispatchSapList = ([ordered]@{ sapList = @($sapItems) } | ConvertTo-Json -Depth 20 -Compress)
}

$results = [System.Collections.Generic.List[object]]::new()
$created = 0
$sequence = [int]$config.startSequence
$scanned = 0
$maxScanCount = if ($config.maxScanCount) { [int]$config.maxScanCount } else { [Math]::Max([int]$config.count * 10, 100) }
while ($created -lt [int]$config.count) {
    $scanned++
    if ($scanned -gt $maxScanCount) { throw "Stopped after scanning $maxScanCount sequences without finding enough available accounts." }
    if ($sequence -gt 999) { throw 'No more three-digit sequence values are available.' }
    $suffix = $sequence.ToString('000')
    $account = "$($config.accountPrefix)$($config.ipSuffix)$suffix"
    $alias = "$($config.aliasPrefix)$suffix"
    $dispatch = New-DispatchNumber
    $searchResponse = Invoke-Operation 'searchAccounts' @{ query = $account; realm = $config.realm; username = $adminUser }
    $rows = @(Get-PropertyPath $searchResponse (Get-Selector 'searchAccounts' 'rows'))
    $accountSelector = Get-Selector 'searchAccounts' 'account'
    $dispatchSelector = Get-Selector 'searchAccounts' 'dispatchNumber'
    $accountExists = @($rows | Where-Object { (Get-PropertyPath $_ $accountSelector) -eq $account }).Count -gt 0
    $dispatchResponse = Invoke-Operation 'searchAccounts' @{ query = $dispatch; realm = $config.realm; username = $adminUser }
    $dispatchRows = @(Get-PropertyPath $dispatchResponse (Get-Selector 'searchAccounts' 'rows'))
    $dispatchExists = @($dispatchRows | Where-Object { [string](Get-PropertyPath $_ $dispatchSelector) -eq $dispatch }).Count -gt 0
    if ($accountExists -or $dispatchExists) {
        $results.Add([pscustomobject]@{ sequence=$sequence; account=$account; dispatchNumber=$dispatch; status='skipped'; reason='duplicate' })
        $sequence++
        continue
    }
    $variables = @{
        account=$account; alias=$alias; dispatchNumber=$dispatch; password=$newPassword; realm=$config.realm
        roleId=$roleId; roleName=$config.highestRoleName; systemIds=$systemIds; systemIdList=($systemIds -join ';')
        accessPointIds=$accessPointIds; dispatchSapList=$dispatchSapList
        authorizedDeviceOrgId=$deviceRootId; ownedDeviceOrgId=$deviceRootId
        authorizedAddressOrgId=$addressRootId; ownedAddressOrgId=$addressRootId
        loginTerminalName=$config.loginTerminalName
    }
    if ($DryRun) {
        $results.Add([pscustomobject]@{ sequence=$sequence; account=$account; alias=$alias; dispatchNumber=$dispatch; status='planned'; reason='' })
    } elseif ($PSCmdlet.ShouldProcess($account, 'Create PUC account')) {
        $createRequest = Expand-Template $adapter.operations.createAccount.bodyTemplate $variables
        $response = $null
        try {
            $response = Invoke-Operation 'createAccount' $variables
            $successSelector = Get-Selector 'createAccount' 'success'
            $success = Get-PropertyPath $response $successSelector
            $successExpected = $adapter.operations.createAccount.selectors.successExpected
            if ($null -eq $successExpected) { $successExpected = $adapter.selectors.successExpected }
            if ($null -eq $successExpected) { $successExpected = $true }
            if ($null -eq $success -or [string]$success -ne [string]$successExpected) { throw 'API response reported failure' }
            $results.Add([pscustomobject]@{ sequence=$sequence; account=$account; alias=$alias; dispatchNumber=$dispatch; status='created'; reason=''; createRequest=$createRequest; createResponse=$response })
        } catch {
            $results.Add([pscustomobject]@{ sequence=$sequence; account=$account; alias=$alias; dispatchNumber=$dispatch; status='failed'; reason=$_.Exception.Message; createRequest=$createRequest; createResponse=$response })
        }
    }
    $created++
    $sequence++
    Start-Sleep -Milliseconds ([int]$config.requestDelayMs)
}

Write-Results $results
Restore-CertificateCallback
