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

foreach ($name in @('count','accountPrefix')) {
    if ($null -eq $config.$name -or [string]::IsNullOrWhiteSpace([string]$config.$name)) {
        throw "Required configuration value is missing: $name"
    }
}
if ([string]$config.ipSuffix -notmatch '^\d{1,3}$' -or [int]$config.ipSuffix -lt 0 -or [int]$config.ipSuffix -gt 255) {
    throw 'ipSuffix must be the final decimal octet of the target environment IPv4 address.'
}
$effectiveAccountPrefix = "$($config.accountPrefix)$([int]$config.ipSuffix)"
if ([int]$config.count -lt 1 -or [int]$config.count -gt 1000) { throw 'count must be between 1 and 1000.' }

function Write-Results($items) {
    $rows = @($items)
    $failedCount = @($rows | Where-Object status -eq 'failed').Count
    $createdCount = @($rows | Where-Object status -eq 'created').Count
    $overallStatus = if ($failedCount -gt 0) {
        'partial-failure'
    } elseif ($PlanOnly) {
        'planned-offline'
    } elseif ($DryRun) {
        'previewed'
    } else {
        'created'
    }

    [pscustomobject]@{
        status = $overallStatus
        action = 'CreateDispatcherAccounts'
        count = $rows.Count
        succeeded = $createdCount
        failed = $failedCount
        results = $rows
    } | ConvertTo-Json -Depth 20 -Compress
}

$script:lastDispatchTimestamp = [int64]0
$script:dispatchOffset = [int64]0
function New-DispatchNumber {
    if ($null -ne $config.dispatchStart -and -not [string]::IsNullOrWhiteSpace([string]$config.dispatchStart)) {
        $value = [int64]$config.dispatchStart + $script:dispatchOffset
        $script:dispatchOffset++
        return $value.ToString()
    }
    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($timestamp -le $script:lastDispatchTimestamp) { $timestamp = $script:lastDispatchTimestamp + 1 }
    $script:lastDispatchTimestamp = $timestamp
    return $timestamp.ToString()
}

if ($PlanOnly) {
    Write-Results @([pscustomobject]@{
        accountPrefix = $effectiveAccountPrefix
        count = [int]$config.count
        status = 'planned-offline'
        reason = 'sequence-requires-account-lookup'
    })
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

$cookieJar = @{}
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
    $maxRetries = if ($name -eq 'createAccount') { 0 } elseif ($null -ne $config.maxReadRetries) { [int]$config.maxReadRetries } else { 0 }
    for ($attempt = 0; ; $attempt++) {
        try {
            return Invoke-PucJsonHttpRequest -Method ([string]$operation.method) -Uri ([uri]$uri) -Headers $headers -Body $body -AllowInsecureTls ([bool]$config.allowInsecureTls) -TimeoutSec 60 -CookieJar $cookieJar -Depth 50
        } catch {
            if ($attempt -ge $maxRetries) {
                throw
            }
            Start-Sleep -Milliseconds ([Math]::Min(5000, 500 * [Math]::Pow(2, $attempt)))
        }
    }
}

$adminUser = Get-RequiredEnvironment $config.loginUserEnv
$newPassword = [string]$config.defaultAccountPassword
if ($newPassword -notmatch '^(?:[0-9a-fA-F]{16})+$') {
    throw 'defaultAccountPassword must be hexadecimal ciphertext containing one or more complete DES blocks. Plaintext account passwords are not allowed in the generated batch configuration.'
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
        pucId = $config.pucId
        captchaId = $captchaId
        captchaValue = $captchaValue
    }
    $loginSuccessPath = $adapter.operations.login.selectors.success
    if ($loginSuccessPath) {
        $loginSuccess = Get-PropertyPath $loginResponse $loginSuccessPath
        $loginExpected = $adapter.operations.login.selectors.successExpected
        if ([string]$loginSuccess -ne [string]$loginExpected) { throw (New-PucApiFailureMessage -Operation 'Login API' -Response $loginResponse) }
    }
    $token = Get-PropertyPath $loginResponse $adapter.token.responsePath
}
if ([string]::IsNullOrWhiteSpace($token)) { throw 'Authentication did not return a token.' }
$authHeader[$adapter.token.headerName] = $adapter.token.prefix + $token

function Get-LookupId([string]$operationName, [string]$wantedName, [switch]$AllowEmpty) {
    $response = Invoke-Operation $operationName @{ realm = $config.realm; username = $adminUser; pucId = $config.pucId }
    $rawRows = Get-PropertyPath $response (Get-Selector $operationName 'rows')
    $rows = if ($null -eq $rawRows) { @() } else { @($rawRows) }
    if ($rows.Count -eq 0 -and $AllowEmpty) { return '' }
    $nameSelector = Get-Selector $operationName 'name'
    $idSelector = Get-Selector $operationName 'id'
    if ([string]::IsNullOrWhiteSpace($wantedName)) {
        if ($rows.Count -eq 1) {
            $match = @($rows[0])
        } else {
            $match = @($rows | Where-Object {
                $parentValues = @($_.parent_org_identifier, $_.parent_identifier, $_.parent_custom_org_id, $_.parent_id) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
                $parentValues.Count -eq 0
            })
        }
    } else {
        $match = @($rows | Where-Object { (Get-PropertyPath $_ $nameSelector) -eq $wantedName })
    }
    if ($match.Count -ne 1) { throw "$operationName lookup for '$wantedName' returned $($match.Count) matches" }
    $id = Get-PropertyPath $match[0] $idSelector
    if ([string]::IsNullOrWhiteSpace([string]$id)) { throw "$operationName lookup for '$wantedName' returned an entry without a usable ID" }
    return $id
}

function Get-HighestRole([string]$preferredName) {
    $response = Invoke-Operation 'roles' @{ realm = $config.realm; username = $adminUser; pucId = $config.pucId }
    $rawRows = Get-PropertyPath $response (Get-Selector 'roles' 'rows')
    $rows = if ($null -eq $rawRows) { @() } else { @($rawRows) }
    $nameSelector = Get-Selector 'roles' 'name'
    $idSelector = Get-Selector 'roles' 'id'
    if ($rows.Count -eq 0) { throw 'roles lookup returned no roles' }

    $selected = $null
    $selectionReason = ''
    if (-not [string]::IsNullOrWhiteSpace($preferredName)) {
        $matches = @($rows | Where-Object { [string](Get-PropertyPath $_ $nameSelector) -ieq $preferredName })
        if ($matches.Count -ne 1) { throw "Exact role '$preferredName' returned $($matches.Count) matches" }
        $selected = $matches[0]
        $selectionReason = "explicit:$preferredName"
    } else {
        foreach ($priorityName in @('superadministrator','administrator','operations')) {
            $matches = @($rows | Where-Object { [string](Get-PropertyPath $_ $nameSelector) -ieq $priorityName })
            if ($matches.Count -gt 1) { throw "Priority role '$priorityName' returned $($matches.Count) matches" }
            if ($matches.Count -eq 1) {
                $selected = $matches[0]
                $selectionReason = "priority:$priorityName"
                break
            }
        }
    }
    if ($null -eq $selected) {
        $ranked = @($rows | ForEach-Object {
            [pscustomobject]@{
                Row = $_
                PermissionCount = @($_.permission_list | Where-Object { [string]$_.permission_value -eq '1' }).Count
            }
        })
        $highestPermissionCount = ($ranked | Measure-Object -Property PermissionCount -Maximum).Maximum
        $highestRoles = @($ranked | Where-Object PermissionCount -eq $highestPermissionCount | ForEach-Object Row)
        if ($highestRoles.Count -ne 1) {
            throw "roles lookup remained ambiguous after permission-count ranking ($($highestRoles.Count) matches)"
        }
        $selected = $highestRoles[0]
        $selectionReason = 'permission-count'
    }
    $permissionCount = @($selected.permission_list | Where-Object { [string]$_.permission_value -eq '1' }).Count
    $id = Get-PropertyPath $selected $idSelector
    $name = Get-PropertyPath $selected $nameSelector
    if ([string]::IsNullOrWhiteSpace([string]$id)) { throw 'Selected highest role did not contain a usable ID' }
    if ([string]::IsNullOrWhiteSpace([string]$name)) { throw 'Selected highest role did not contain a usable name' }
    return [pscustomobject]@{ Id = $id; Name = $name; PermissionCount = $permissionCount; SelectionReason = $selectionReason }
}

function Get-AllMatchingAccounts([string]$query, [switch]$RequireLargeResultConfirmation) {
    $pageSize = if ($config.accountSearchPageSize) { [int]$config.accountSearchPageSize } else { 30 }
    if ($pageSize -ne 30) { throw 'accountSearchPageSize must be 30.' }
    $pageIndex = 1
    $allRows = [System.Collections.Generic.List[object]]::new()
    while ($true) {
        $response = Invoke-Operation 'searchAccounts' @{
            query=$query; pageSize=$pageSize; pageIndex=$pageIndex
            realm=$config.realm; username=$adminUser
        }
        if ($null -ne $response.PSObject.Properties['result'] -and [string]$response.result -ne '0') {
            throw (New-PucApiFailureMessage -Operation "Account lookup for '$query'" -Response $response)
        }
        $rawRows = Get-PropertyPath $response (Get-Selector 'searchAccounts' 'rows')
        $rows = if ($null -eq $rawRows) { @() } else { @($rawRows) }
        foreach ($row in $rows) { $allRows.Add($row) }
        $pageCount = [int](Get-PropertyPath $response (Get-Selector 'searchAccounts' 'pageCount'))
        $totalCount = [int](Get-PropertyPath $response (Get-Selector 'searchAccounts' 'totalCount'))
        $projectedCount = $totalCount + [int]$config.count
        if ($pageIndex -eq 1 -and $RequireLargeResultConfirmation -and
            -not [bool]$config.continueWhenMoreThanPageSizeAccounts -and
            ($totalCount -gt $pageSize -or $pageCount -gt 1 -or $projectedCount -gt $pageSize)) {
            $knownCount = if ($totalCount -gt 0) { [string]$totalCount } else { "more than $pageSize" }
            throw "ACCOUNT_LOOKUP_DECISION_REQUIRED: query '$query' matched $knownCount accounts and the requested batch projects $projectedCount. Ask whether to continue creating accounts or update existing account information. Continue creation only after an explicit choice, then rerun with -ContinueWhenMoreThan30Accounts."
        }
        if ($pageCount -le 0 -or $pageIndex -ge $pageCount) { break }
        if ($pageIndex -ge 1000) { throw "Account lookup for '$query' exceeded 1000 pages" }
        $pageIndex++
    }
    return @($allRows)
}

$selectedRole = Get-HighestRole $config.highestRoleName
$systemResponse = Invoke-Operation 'systems' @{ realm = $config.realm; username = $adminUser; pucId = $config.pucId }
$rawSystemRows = Get-PropertyPath $systemResponse (Get-Selector 'systems' 'rows')
$systemRows = if ($null -eq $rawSystemRows) { @() } else { @($rawSystemRows) }
$systemIds = @($systemRows | ForEach-Object { Get-PropertyPath $_ (Get-Selector 'systems' 'id') })
if (@($systemIds | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
    throw 'System lookup returned entries without usable IDs; refusing to create an account with incomplete system authorization.'
}
$accessResponse = Invoke-Operation 'accessPoints' @{ realm = $config.realm; username = $adminUser; pucId = $config.pucId }
$rawAccessRows = Get-PropertyPath $accessResponse (Get-Selector 'accessPoints' 'rows')
$accessRows = if ($null -eq $rawAccessRows) { @() } else { @($rawAccessRows) }
$accessPointIds = @($accessRows | ForEach-Object { Get-PropertyPath $_ (Get-Selector 'accessPoints' 'id') })
if (@($accessPointIds | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
    throw 'Access-point lookup returned entries without usable IDs; refusing to create an account with incomplete access-point authorization.'
}
$deviceRootId = Get-LookupId 'deviceOrganizations' $config.rootOrganizationName -AllowEmpty
$addressRootId = Get-LookupId 'addressBookOrganizations' $config.rootOrganizationName -AllowEmpty
$accountSelector = Get-Selector 'searchAccounts' 'account'
$dispatchSelector = Get-Selector 'searchAccounts' 'dispatchNumber'
$existingAccounts = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$existingDispatchNumbers = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$existingRows = @(Get-AllMatchingAccounts $effectiveAccountPrefix -RequireLargeResultConfirmation)
foreach ($row in $existingRows) {
    $existingAccount = [string](Get-PropertyPath $row $accountSelector)
    if (-not [string]::IsNullOrWhiteSpace($existingAccount)) { $existingAccounts.Add($existingAccount) | Out-Null }
    $existingDispatch = [string](Get-PropertyPath $row $dispatchSelector)
    if (-not [string]::IsNullOrWhiteSpace($existingDispatch)) { $existingDispatchNumbers.Add($existingDispatch) | Out-Null }
}

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
$prepared = [System.Collections.Generic.List[object]]::new()
$sequencePattern = '^' + [regex]::Escape($effectiveAccountPrefix) + '(?<sequence>\d{3})$'
$highestSequence = 0
foreach ($existingAccount in $existingAccounts) {
    $match = [regex]::Match($existingAccount, $sequencePattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        $existingSequence = [int]$match.Groups['sequence'].Value
        if ($existingSequence -gt $highestSequence) { $highestSequence = $existingSequence }
    }
}
$sequence = $highestSequence + 1
if ($sequence -gt 999 -or $sequence + [int]$config.count - 1 -gt 999) {
    throw 'The next generated account sequence range exceeds 999.'
}
$scanned = 0
$maxScanCount = if ($config.maxScanCount) { [int]$config.maxScanCount } else { [Math]::Max([int]$config.count * 10, 100) }
while ($prepared.Count -lt [int]$config.count) {
    $scanned++
    if ($scanned -gt $maxScanCount) { throw "Stopped after scanning $maxScanCount sequences without finding enough available accounts." }
    if ($sequence -gt 999) { throw 'No more three-digit sequence values are available.' }
    $suffix = $sequence.ToString('000')
    $account = "$effectiveAccountPrefix$suffix"
    $alias = "${account}_alias"
    $dispatch = New-DispatchNumber
    $accountExists = $existingAccounts.Contains($account)
    $dispatchExists = $existingDispatchNumbers.Contains($dispatch)
    if ($accountExists -or $dispatchExists) {
        $results.Add([pscustomobject]@{ sequence=$sequence; account=$account; dispatchNumber=$dispatch; role=$selectedRole.Name; roleGuid=$selectedRole.Id; roleSelection=$selectedRole.SelectionReason; status='skipped'; reason='duplicate' })
        $sequence++
        continue
    }
    $variables = @{
        account=$account; accountGuid=[guid]::NewGuid().ToString(); alias=$alias; dispatchNumber=$dispatch; password=$newPassword; realm=$config.realm
        pucId=$config.pucId; roleId=$selectedRole.Id; roleName=$selectedRole.Name; systemIds=$systemIds; systemIdList=($systemIds -join ';')
        accessPointIds=$accessPointIds; dispatchSapList=$dispatchSapList
        authorizedDeviceOrgId=$deviceRootId; ownedDeviceOrgId=$deviceRootId
        authorizedAddressOrgId=$addressRootId; ownedAddressOrgId=$addressRootId
        loginTerminalName=$config.loginTerminalName
    }
    $createRequest = Expand-Template $adapter.operations.createAccount.bodyTemplate $variables
    $prepared.Add([pscustomobject]@{
        sequence=$sequence; account=$account; alias=$alias; dispatchNumber=$dispatch
        role=$selectedRole.Name; roleGuid=$selectedRole.Id; roleSelection=$selectedRole.SelectionReason
        variables=$variables; createRequest=$createRequest
    })
    $existingAccounts.Add($account) | Out-Null
    $existingDispatchNumbers.Add($dispatch) | Out-Null
    $sequence++
}

if ($DryRun) {
    foreach ($candidate in $prepared) {
        $results.Add([pscustomobject]@{
            sequence=$candidate.sequence; account=$candidate.account; alias=$candidate.alias; dispatchNumber=$candidate.dispatchNumber
            role=$candidate.role; roleGuid=$candidate.roleGuid; roleSelection=$candidate.roleSelection; status='planned'; reason=''
        })
    }
} else {
    foreach ($candidate in $prepared) {
        if ($PSCmdlet.ShouldProcess($candidate.account, 'Create PUC account')) {
        $response = $null
        try {
            $response = Invoke-Operation 'createAccount' $candidate.variables
            $successSelector = Get-Selector 'createAccount' 'success'
            $success = Get-PropertyPath $response $successSelector
            $successExpected = $adapter.operations.createAccount.selectors.successExpected
            if ($null -eq $successExpected) { $successExpected = $adapter.selectors.successExpected }
            if ($null -eq $successExpected) { $successExpected = $true }
            if ($null -eq $success -or [string]$success -ne [string]$successExpected) { throw (New-PucApiFailureMessage -Operation 'add_account' -Response $response) }
            $results.Add([pscustomobject]@{
                sequence=$candidate.sequence; account=$candidate.account; alias=$candidate.alias; dispatchNumber=$candidate.dispatchNumber
                role=$candidate.role; roleGuid=$candidate.roleGuid; roleSelection=$candidate.roleSelection; status='created'; reason=''
            })
        } catch {
            $results.Add([pscustomobject]@{
                sequence=$candidate.sequence; account=$candidate.account; alias=$candidate.alias; dispatchNumber=$candidate.dispatchNumber
                role=$candidate.role; roleGuid=$candidate.roleGuid; roleSelection=$candidate.roleSelection; status='failed'; reason=$_.Exception.Message
            })
            Write-Results $results
            throw
        }
        Start-Sleep -Milliseconds ([int]$config.requestDelayMs)
        }
    }
}

Write-Results $results
