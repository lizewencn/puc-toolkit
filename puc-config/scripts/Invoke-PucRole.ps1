[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][string]$RoleAlias,
    [switch]$DryRun,
    [switch]$Live,
    [switch]$ConfirmLive,
    [string]$ConfigRoot
)

$ErrorActionPreference = 'Stop'
if (@($DryRun,$Live | Where-Object { $_ }).Count -ne 1) { throw 'Select exactly one mode: DryRun or Live.' }
if ($Live -and -not $ConfirmLive) { throw 'Live role creation requires ConfirmLive after explicit confirmation.' }
if ([string]::IsNullOrWhiteSpace($RoleAlias)) { throw 'RoleAlias must not be empty.' }
if ($RoleAlias.Length -gt 32) { throw 'RoleAlias must not exceed 32 characters.' }
if ($RoleAlias -match '[\r\n\"%]') { throw 'RoleAlias contains unsupported characters.' }

Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$root = Get-PucConfigRoot $ConfigRoot
$validation = & (Join-Path $PSScriptRoot 'Invoke-PucAuth.ps1') -Action Ensure -Environment $Environment -ConfigRoot $root | ConvertFrom-Json
if ($validation.valid -ne $true) { throw "Saved token is not usable ($($validation.reason)). Complete the login workflow first." }
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
$baseUri = [uri]$environmentConfig.baseUrl

function Get-Value($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = @($Object.PSObject.Properties.Match($Name)) | Select-Object -First 1
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Invoke-RoleRequest([hashtable]$Body) {
    $response = Invoke-PucJsonRequest -Uri ([uri]($baseUri.AbsoluteUri.TrimEnd('/') + '/confs')) -Body $Body -Headers @{token=[string]$environmentConfig.token} -AllowInsecureTls ([bool]$environmentConfig.allowInsecureTls) -TimeoutSec 60 -Depth 80
    if ($null -eq $response) { throw "$($Body.cmd_name) returned an empty response. No retry was attempted." }
    $result = Get-Value $response 'result' 0
    if ([string]$result -ne '0') { throw (New-PucApiFailureMessage -Operation ([string]$Body.cmd_name) -Response $response) }
    return $response
}

function Set-AllChecked($Nodes) {
    $result = [Collections.Generic.List[object]]::new()
    foreach ($node in @($Nodes)) {
        if ($null -ne $node) {
            $copy = [ordered]@{}
            foreach ($property in $node.PSObject.Properties) { if ($property.Name -notin @('isCheck','disabled','child')) { $copy[$property.Name] = $property.Value } }
            $copy.isCheck = 1
            $copy.disabled = 0
            $children = Get-Value $node 'child' @()
            if (@($children).Count -gt 0) { $copy.child = @(Set-AllChecked $children) }
            $result.Add([pscustomobject]$copy)
        }
    }
    return @($result)
}

function Redact-Response($Value, [string]$Name = '') {
    if ($Name -match '(?i)(token|cookie|password|passwd|secret|psw|cipher|authorization|captcha|informationSysPsw|origin_)') { return '[REDACTED]' }
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}; foreach ($key in $Value.Keys) { $out[$key] = Redact-Response $Value[$key] ([string]$key) }; return [pscustomobject]$out
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { return @($Value | ForEach-Object { Redact-Response $_ $Name }) }
    if ($Value -is [pscustomobject]) {
        $out = [ordered]@{}; foreach ($property in $Value.PSObject.Properties) { $out[$property.Name] = Redact-Response $property.Value $property.Name }; return [pscustomobject]$out
    }
    return $Value
}

function New-PermissionList($Groups) {
    $items = [Collections.Generic.List[object]]::new()
    foreach ($group in @($Groups)) {
        $name = [string](Get-Value $group 'group_name' '')
        if ($name) { $items.Add([pscustomobject]@{permission_name=$name;permission_value='1'}) }
        foreach ($item in @(Get-Value $group 'permission_list' @())) {
            $permissionName = [string](Get-Value $item 'permission_name' '')
            if ($permissionName) { $items.Add([pscustomobject]@{permission_name=$permissionName;permission_value='1'}) }
        }
    }
    return @($items)
}

$permissionNames = @(
    'CallCtrl','individualcall','Groupcall','pstn','Environmentmonitor','RecordPlay',
    'HyteraEVK','Individualvideo','GroupVideo','PullVedioCall','PushVedioCall','Monitor',
    'SDS','Textmessage','Statusmessage','MultiMediaMessage','GPS','GetGPS','Subscrible','RegionAlarm','OverSpeedAlarm',
    'SecurityService','Encryption','StunOrRevive','Kill','SupremeAuthorityControl',
    'Other','DynaGroups','CrossPatch','Listen','Interrupt','ForcedRelease','VideoConference','Report','HistoryTrack','Record','BaseStationMonitor','CrossRealmCallIn','CrossRealmCallOut',
    'DataSync','BaseDataSync','GunState','AVL','Map','MapAdvancedFeatures','Fax','Fax','WebOps','WebOpsLogin','SwitchAccount','DataBoard','DataBoardLogin','DataBoardEdit',
    'LoginService','WepPucLogin','MobileAppLogin','ConfigMgrLogin'
)

$pucId = [string]$environmentConfig.pucId
$userId = [string]$environmentConfig.adminAccount
$realm = [string]$environmentConfig.realm
$guid = [guid]::NewGuid().ToString()

$roleListResponse = Invoke-RoleRequest ([ordered]@{cmd_name='role_request';puc_id=$pucId;user_id=$userId;page_sizes=1000;page_index=1;realm=$realm})
$existing = @((Get-Value $roleListResponse 'role_list' @()) | Where-Object { [string]::Equals([string](Get-Value $_ 'role_alias' ''),$RoleAlias,[StringComparison]::OrdinalIgnoreCase) })
if ($existing.Count -gt 0) { throw "Role '$RoleAlias' already exists." }

$abilityResponse = Invoke-RoleRequest ([ordered]@{cmd_guid=([guid]::NewGuid().ToString());realm=$realm;puc_id=$pucId;cmd_name='puc_get_function_ability'})
$functionInfo = Get-Value $abilityResponse 'function_info' ([pscustomobject]@{})
$ability = @(Set-AllChecked @(([string](Get-Value $functionInfo 'ability' '[]')) | ConvertFrom-Json)) | ConvertTo-Json -Depth 80 -Compress
$appAbility = [string](Get-Value $functionInfo 'app_ability' '[]')
if ([string]::IsNullOrWhiteSpace($appAbility)) { $appAbility = '[]' }
$configAbility = @(Set-AllChecked @(([string](Get-Value $functionInfo 'config_ability' '[]')) | ConvertFrom-Json)) | ConvertTo-Json -Depth 80 -Compress

$systemResponse = Invoke-RoleRequest ([ordered]@{cmd_name='system_list_request';puc_id=$pucId;user_id=$userId;realm=$realm})
$systems = @(Get-Value $systemResponse 'system_list' @())
$systemIds = @($systems | ForEach-Object { [string](Get-Value $_ 'system_id' '') } | Where-Object { $_ }) -join ';'

$sapResponse = Invoke-RoleRequest ([ordered]@{cmd_name='sap_list_request';puc_id=$pucId;realm=$realm})
$sapItems = [Collections.Generic.List[object]]::new()
foreach ($group in @(Get-Value $sapResponse 'sap_base_list' @())) {
    $grpName = [string](Get-Value $group 'sap_alias' (Get-Value $group 'domain_name' ''))
    foreach ($sap in @(Get-Value $group 'sap_list' @())) {
        $sapItems.Add([pscustomobject]@{pucid=$pucId;systemid=[string](Get-Value $sap 'system_id' '');grpname=$grpName;realm=$realm;ssi=@([pscustomobject]@{label=[string](Get-Value $sap 'ssi' '');value=[string](Get-Value $sap 'guid' '')})})
    }
}
$sapGroups = @($sapItems | Group-Object grpname | ForEach-Object { [pscustomobject]@{pucid=$pucId;systemid=[string]$_.Group[0].systemid;grpname=[string]$_.Name;realm=$realm;ssi=@($_.Group | ForEach-Object { $_.ssi[0] })} })
$shortOrgResponse = Invoke-RoleRequest ([ordered]@{cmd_name='short_organization_request';puc_id=$pucId;user_id=$userId;realm=$realm;org_identifiers=@('00')})
$shortOrg = @((Get-Value $shortOrgResponse 'organization_info_list' @()))[0]
$personOrgResponse = Invoke-RoleRequest ([ordered]@{cmd_name='personnel_organization_info_req';user_id=$userId;realm=$realm;custom_org_ids=@('00')})
$personOrg = @((Get-Value $personOrgResponse 'organization_info_list' @()))[0]
$orgAlias = [string](Get-Value $shortOrg 'org_alias' '00')
$customAlias = [string](Get-Value $personOrg 'custom_org_alias' (Get-Value $personOrg 'org_alias' $orgAlias))
$orgPermission = [ordered]@{
    system_id_list=$systemIds
    dispatch_sap_list=([ordered]@{sapList=$sapGroups} | ConvertTo-Json -Depth 30 -Compress)
    org_identifier_list='00';org_name_list=$orgAlias;org_identifier='00';org_alias=$orgAlias
    custom_org_identifier_list='00';custom_org_name_list=$customAlias;custom_org_id='00';custom_org_alias=$customAlias
}
$payload = [ordered]@{
    cmd_name='add_role';guid=$guid;puc_id=$pucId;role_alias=$RoleAlias
    permission_list=@()
    enable_flag=1;ability=$ability;app_ability=$appAbility;config_ability=$configAbility
    data_permission=([ordered]@{auth_third_system=@()} | ConvertTo-Json -Compress)
    org_permission=($orgPermission | ConvertTo-Json -Depth 30 -Compress);realm=$realm
}
$payload.permission_list = @($permissionNames | ForEach-Object { [pscustomobject]@{permission_name=$_;permission_value='1'} })

if ($DryRun) {
    [pscustomobject]@{status='previewed';environment=$Environment;roleAlias=$RoleAlias;permissionCount=@($payload.permission_list).Count;systemCount=@($systems).Count;sapCount=@($sapItems).Count;rootOrganization=$orgAlias;request=[pscustomobject]@{cmd_name='add_role';role_alias=$RoleAlias;permission_list=@($payload.permission_list);enable_flag=1;ability=$ability;app_ability=$appAbility;config_ability=$configAbility;data_permission=$payload.data_permission;org_permission=$payload.org_permission;realm=$realm};apiResponses=[ordered]@{role_request=Redact-Response $roleListResponse;puc_get_function_ability=Redact-Response $abilityResponse;system_list_request=Redact-Response $systemResponse;sap_list_request=Redact-Response $sapResponse;short_organization_request=Redact-Response $shortOrgResponse;personnel_organization_info_req=Redact-Response $personOrgResponse}} | ConvertTo-Json -Depth 80 -Compress
    return
}
$response = Invoke-RoleRequest $payload
[pscustomobject]@{status='created';environment=$Environment;roleAlias=$RoleAlias;guid=$guid;result=$response.result;apiResponse=$response} | ConvertTo-Json -Depth 30 -Compress
