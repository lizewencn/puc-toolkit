[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HarPath,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$harText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $HarPath).Path, [Text.UTF8Encoding]::new($false, $true))
$har = $harText | ConvertFrom-Json

function Convert-Headers($headers) {
    $result = [ordered]@{}
    foreach ($header in $headers) {
        if ($header.name -match '^(cookie|authorization|proxy-authorization|token)$') { continue }
        if ($header.name -match '(?i)token|secret|api.?key|csrf|xsrf') {
            $result[$header.name] = 'REVIEW_REQUIRED_SENSITIVE_HEADER'
        } else {
            $result[$header.name] = $header.value
        }
    }
    return $result
}

function Get-JsonBody($entry) {
    $text = $entry.request.postData.text
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { return $text | ConvertFrom-Json } catch { return $text }
}

function Protect-BodyValue($value, [string]$parentKey = '') {
    if ($null -eq $value) { return $null }
    if ($value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $value.Keys) { $copy[$key] = Protect-BodyValue $value[$key] ([string]$key) }
        return $copy
    }
    if ($value -is [pscustomobject]) {
        $copy = [ordered]@{}
        foreach ($property in $value.PSObject.Properties) {
            $copy[$property.Name] = Protect-BodyValue $property.Value $property.Name
        }
        return $copy
    }
    if (($value -is [System.Collections.IEnumerable]) -and -not ($value -is [string])) {
        return @($value | ForEach-Object { Protect-BodyValue $_ $parentKey })
    }
    if ($parentKey -match '(?i)password|passwd|pwd') { return '{{password}}' }
    if ($parentKey -match '(?i)^user(name)?$|login.?name|admin.?user') { return '{{username}}' }
    if ($parentKey -match '(?i)token|secret|authorization|cookie') { return '{{sensitiveValue}}' }
    return $value
}

function Convert-DynamicBody($value, [string]$operation, [string]$parentKey = '') {
    if ($null -eq $value) { return $null }
    if ($value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $value.Keys) { $copy[$key] = Convert-DynamicBody $value[$key] $operation ([string]$key) }
        return $copy
    }
    if ($value -is [pscustomobject]) {
        $copy = [ordered]@{}
        foreach ($property in $value.PSObject.Properties) {
            $copy[$property.Name] = Convert-DynamicBody $property.Value $operation $property.Name
        }
        return $copy
    }
    if (($value -is [System.Collections.IEnumerable]) -and -not ($value -is [string])) {
        return @($value | ForEach-Object { Convert-DynamicBody $_ $operation $parentKey })
    }
    if ($parentKey -match '(?i)password|passwd|pwd') { return '{{password}}' }
    if ($parentKey -match '(?i)^realm$|domain') { return '{{realm}}' }
    if ($operation -eq 'captcha' -and $parentKey -match '(?i)captcha.?id') { return '{{captchaId}}' }
    if ($operation -eq 'captcha' -and $parentKey -match '(?i)captcha.?value') { return '{{captchaValue}}' }
    if ($operation -eq 'login' -and $parentKey -match '(?i)^user(name)?$|login.?name|account|puc_account') { return '{{username}}' }
    if ($operation -eq 'login' -and $parentKey -match '(?i)captcha.?id') { return '{{captchaId}}' }
    if ($operation -eq 'login' -and $parentKey -match '(?i)captcha.?value') { return '{{captchaValue}}' }
    if ($parentKey -match '(?i)^user_id$') { return '{{username}}' }
    if ($operation -eq 'searchAccounts' -and $parentKey -match '(?i)^querykey$') { return '{{query}}' }
    if ($operation -ne 'createAccount') { return $value }
    if ($parentKey -match '(?i)^account$|^user(name)?$|login.?name|dispatcher_account') { return '{{account}}' }
    if ($parentKey -match '(?i)^alias$|nick.?name|^dispatcher_name$') { return '{{alias}}' }
    if ($parentKey -match '(?i)dispatch.*(number|no|id)|^(number|dispatch)$|dispatcher_no') { return '{{dispatchNumber}}' }
    if ($parentKey -match '(?i)^role$') { return '{{roleName}}' }
    if ($parentKey -match '(?i)^role.?id$|role_guid') { return '{{roleId}}' }
    if ($parentKey -match '(?i)^system_id_list$') { return '{{systemIdList}}' }
    if ($parentKey -match '(?i)^dispatch_sap_list$') { return '{{dispatchSapList}}' }
    if ($parentKey -match '(?i)^systemIds?$') { return '{{systemIds}}' }
    if ($parentKey -match '(?i)(access.?point|gateway).*ids?$') { return '{{accessPointIds}}' }
    if ($parentKey -match '(?i)^org_identifier_list$') { return '{{authorizedDeviceOrgId}}' }
    if ($parentKey -match '(?i)^org_identifier$') { return '{{ownedDeviceOrgId}}' }
    if ($parentKey -match '(?i)^custom_org_identifier_list$') { return '{{authorizedAddressOrgId}}' }
    if ($parentKey -match '(?i)^custom_org_id$') { return '{{ownedAddressOrgId}}' }
    if ($parentKey -match '(?i)(authorized|auth).*device.*org.*id') { return '{{authorizedDeviceOrgId}}' }
    if ($parentKey -match '(?i)(owned|belong).*device.*org.*id') { return '{{ownedDeviceOrgId}}' }
    if ($parentKey -match '(?i)(authorized|auth).*(address|contact).*org.*id') { return '{{authorizedAddressOrgId}}' }
    if ($parentKey -match '(?i)(owned|belong).*(address|contact).*org.*id') { return '{{ownedAddressOrgId}}' }
    if ($parentKey -match '(?i)terminal.*name') { return '{{loginTerminalName}}' }
    return $value
}

function Convert-PathTemplate([string]$path, [string]$operation) {
    $result = $path
    if ($operation -eq 'searchAccounts') {
        $result = $result -replace '(?i)([?&](q|query|search|keyword|account|username|dispatch(number|no)?)=)[^&]*', '$1{{query}}'
    }
    $result = $result -replace '(?i)([?&](realm|domain)=)[^&]*', '$1{{realm}}'
    return $result
}

function Get-CommandEntry([string]$commandName) {
    return @($har.log.entries | Where-Object {
        $body = Get-JsonBody $_
        $body -is [pscustomobject] -and $body.cmd_name -eq $commandName
    }) | Select-Object -Last 1
}

function New-CommandOperation($entry, [string]$operation, $selectors = $null) {
    if ($null -eq $entry) { throw "Required HAR command is missing for operation: $operation" }
    $body = Get-JsonBody $entry
    $result = [ordered]@{
        method = $entry.request.method
        path = ([uri]$entry.request.url).PathAndQuery
        headers = [ordered]@{ Accept = 'application/json, text/plain, */*' }
        bodyTemplate = Convert-DynamicBody (Protect-BodyValue $body) $operation
    }
    if ($selectors) { $result.selectors = $selectors }
    return $result
}

$createCommand = Get-CommandEntry 'add_account'
if ($createCommand) {
    $operations = [ordered]@{
        captcha = New-CommandOperation (Get-CommandEntry 'puc_get_captcha') 'captcha'
        login = New-CommandOperation (Get-CommandEntry 'login_puc_account') 'login' ([ordered]@{
            success='result'; successExpected=0
        })
        searchAccounts = New-CommandOperation (Get-CommandEntry 'account_list_request') 'searchAccounts' ([ordered]@{
            rows='account_list'; account='dispatcher_account'; dispatchNumber='dispatcher_no'
        })
        roles = New-CommandOperation (Get-CommandEntry 'role_request') 'roles' ([ordered]@{
            rows='role_list'; id='guid'; name='role_alias'
        })
        systems = New-CommandOperation (Get-CommandEntry 'system_list_request') 'systems' ([ordered]@{
            rows='system_list'; id='system_id'; name='system_alias'
        })
        accessPoints = New-CommandOperation (Get-CommandEntry 'sap_list_request') 'accessPoints' ([ordered]@{
            rows='sap_base_list'; id='sap_guid'; name='sap_alias'
        })
        deviceOrganizations = New-CommandOperation (Get-CommandEntry 'short_organization_list_request') 'deviceOrganizations' ([ordered]@{
            rows='organization_info_list'; id='org_identifier'; name='org_alias'
        })
        addressBookOrganizations = New-CommandOperation (Get-CommandEntry 'personnel_organization_list_req') 'addressBookOrganizations' ([ordered]@{
            rows='organization_info_list'; id='custom_org_id'; name='custom_org_alias'
        })
        createAccount = New-CommandOperation $createCommand 'createAccount' ([ordered]@{
            success='result'; successExpected=0
        })
    }
    $adapter = [ordered]@{
        generatedFrom = (Split-Path -Leaf $HarPath)
        generatedAt = (Get-Date).ToString('o')
        protocol = 'puc-command'
        token = [ordered]@{ responsePath='token'; headerName='token'; prefix='' }
        captcha = [ordered]@{ idResponsePath='uuid'; imageResponsePath='captcha' }
        operations = $operations
    }
    $parent = Split-Path -Parent $OutputPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $adapter | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    Write-Host "PUC command adapter written to $OutputPath"
    return
}

$candidates = foreach ($entry in $har.log.entries) {
    $url = [uri]$entry.request.url
    $body = Get-JsonBody $entry
    $haystack = ($url.AbsolutePath + ' ' + ($body | ConvertTo-Json -Depth 20 -Compress)).ToLowerInvariant()
    $kind = switch -Regex ($haystack) {
        'login|signin|token' { 'login'; break }
        'role' { 'roles'; break }
        'access.?point|gateway' { 'accessPoints'; break }
        'address|contact.?org' { 'addressBookOrganizations'; break }
        'organization|organisation|org' { 'deviceOrganizations'; break }
        'system' { 'systems'; break }
        'account|user' {
            if ($entry.request.method -in @('POST','PUT') -and $haystack -match 'password|dispatch|alias') { 'createAccount' }
            else { 'searchAccounts' }
            break
        }
        default { $null }
    }
    if ($kind) {
        [pscustomobject]@{
            operation = $kind
            method = $entry.request.method
            path = Convert-PathTemplate $url.PathAndQuery $kind
            headers = Convert-Headers $entry.request.headers
            bodyTemplate = Convert-DynamicBody (Protect-BodyValue $body) $kind
            status = $entry.response.status
        }
    }
}

$operations = [ordered]@{}
foreach ($name in @('login','searchAccounts','roles','systems','accessPoints','deviceOrganizations','addressBookOrganizations','createAccount')) {
    $matches = @($candidates | Where-Object operation -eq $name)
    if ($matches.Count -eq 1) {
        $operations[$name] = $matches[0]
    } else {
        $operations[$name] = [ordered]@{
            review = 'REVIEW_REQUIRED'
            candidates = $matches
        }
    }
}

$adapter = [ordered]@{
    generatedFrom = (Split-Path -Leaf $HarPath)
    generatedAt = (Get-Date).ToString('o')
    token = [ordered]@{
        responsePath = 'REVIEW_REQUIRED'
        headerName = 'Authorization'
        prefix = 'Bearer '
    }
    selectors = [ordered]@{
        rows = 'REVIEW_REQUIRED'
        account = 'REVIEW_REQUIRED'
        dispatchNumber = 'REVIEW_REQUIRED'
        id = 'REVIEW_REQUIRED'
        name = 'REVIEW_REQUIRED'
        success = 'REVIEW_REQUIRED'
    }
    operations = $operations
}

$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
$adapter | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Draft adapter written to $OutputPath"
Write-Host "Resolve every REVIEW_REQUIRED field before live use."
