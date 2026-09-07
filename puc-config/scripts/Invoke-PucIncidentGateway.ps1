[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [ValidateRange(1,65535)][int]$ServicePort = 17060,
    [switch]$DryRun,
    [switch]$Live,
    [switch]$ConfirmLive,
    [string]$ExpectedSnapshotHash,
    [string]$ConfigRoot,
    [string]$EndpointOverride,
    [string]$GatewayConfigEndpointOverride
)

$ErrorActionPreference = 'Stop'
if (@($DryRun,$Live | Where-Object { $_ }).Count -ne 1) { throw 'Select exactly one mode: DryRun or Live.' }
if ($Live -and -not $ConfirmLive) { throw 'Live incident gateway creation requires ConfirmLive after explicit confirmation.' }
if ($Live -and [string]::IsNullOrWhiteSpace($ExpectedSnapshotHash)) { throw 'Live incident gateway creation requires ExpectedSnapshotHash from the authenticated dry run.' }
$hasOverride = -not [string]::IsNullOrWhiteSpace($EndpointOverride) -or -not [string]::IsNullOrWhiteSpace($GatewayConfigEndpointOverride)
if ($hasOverride -and [Environment]::GetEnvironmentVariable('PUC_CONFIG_TEST_MODE') -ne '1') { throw 'Endpoint overrides are available only in test mode.' }
if ($hasOverride -and ([string]::IsNullOrWhiteSpace($EndpointOverride) -or [string]::IsNullOrWhiteSpace($GatewayConfigEndpointOverride))) { throw 'Both endpoint overrides are required in test mode.' }

Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$root = Get-PucConfigRoot $ConfigRoot
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
if (-not $hasOverride) {
    $validation = & (Join-Path $PSScriptRoot 'Invoke-PucAuth.ps1') -Action Ensure -Environment $Environment -ConfigRoot $root | ConvertFrom-Json
    if ($validation.valid -ne $true) { throw "Saved token is not usable ($($validation.reason)). Complete the login workflow first." }
    $environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
}

$baseUri = [uri]$environmentConfig.baseUrl
$environmentIp = [string]$baseUri.Host
$parsedIp = $null
if (-not [Net.IPAddress]::TryParse($environmentIp, [ref]$parsedIp)) { throw "Selected environment baseUrl host '$environmentIp' is not an IP address." }
$confsEndpoint = if ($hasOverride) { [uri]$EndpointOverride } else { [uri]($baseUri.AbsoluteUri.TrimEnd('/') + '/confs') }
$gatewayConfigEndpoint = if ($hasOverride) { [uri]$GatewayConfigEndpointOverride } else { [uri]($baseUri.AbsoluteUri.TrimEnd('/') + '/nmpuc/gateway/getConfig') }

function Get-Value($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { if ([string]$key -ieq $Name) { return $Object[$key] } }
        return $Default
    }
    $property = @($Object.PSObject.Properties.Match($Name)) | Select-Object -First 1
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function ConvertFrom-CodePoints([int[]]$Codes) {
    return -join @($Codes | ForEach-Object { [char]$_ })
}

$missingSystemMessage = ConvertFrom-CodePoints @(0x65b0,0x589e,0x6240,0x5c5e,0x7cfb,0x7edf,0x5217,0x8868,0x4e2d,0x4e0d,0x5b58,0x5728,0x0020,0x0032,0x0039,0x0038,0x0020,0x8b66,0x60c5,0x76f8,0x5173,0x7c7b,0x578b)
$missingGatewayMessage = ConvertFrom-CodePoints @(0x65b0,0x589e,0x7f51,0x5173,0x7c7b,0x578b,0x5217,0x8868,0x4e2d,0x4e0d,0x5b58,0x5728,0x8b66,0x60c5,0x76f8,0x5173,0x7c7b,0x578b)
$wuxiIncidentLabel = ConvertFrom-CodePoints @(0x65e0,0x9521,0x8b66,0x60c5)
$alreadyExistsMessage = ConvertFrom-CodePoints @(0x670d,0x52a1,0x63a5,0x5165,0x70b9,0x522b,0x540d,0x0020,0x0033,0x0072,0x0064,0x0077,0x0078,0x0020,0x5df2,0x7ecf,0x5b58,0x5728,0xff0c,0x5df2,0x7ec8,0x6b62,0x65b0,0x589e,0x3002)

function Assert-ConfsResponse($Response, [string]$Operation) {
    if ($null -eq $Response) { throw "$Operation returned an empty response. No retry was attempted." }
    $resultProperty = @($Response.PSObject.Properties.Match('result')) | Select-Object -First 1
    if ($null -eq $resultProperty) { throw "$Operation response did not contain result. No retry was attempted." }
    if ([string]$resultProperty.Value -ne '0') { throw (New-PucApiFailureMessage -Operation $Operation -Response $Response) }
    return $Response
}

function Invoke-ConfsRequest([System.Collections.IDictionary]$Body) {
    $response = Invoke-PucJsonRequest -Uri $confsEndpoint -Body $Body -Headers @{token=[string]$environmentConfig.token} -AllowInsecureTls ([bool]$environmentConfig.allowInsecureTls) -TimeoutSec 60 -Depth 80
    return Assert-ConfsResponse $response ([string]$Body.cmd_name)
}

function Get-AllSapBaseItems {
    $page = 1
    $items = [Collections.Generic.List[object]]::new()
    while ($true) {
        $response = Invoke-ConfsRequest ([ordered]@{cmd_name='sap_list_request';page_index=$page;page_sizes=1000;puc_id=[string]$environmentConfig.pucId;realm=[string]$environmentConfig.realm})
        $pageItems = @((Get-Value $response 'sap_base_list' @()) | Where-Object { $null -ne $_ })
        foreach ($item in $pageItems) { $items.Add($item) }
        $total = 0
        [void][int]::TryParse([string](Get-Value $response 'count' $items.Count), [ref]$total)
        if ($pageItems.Count -eq 0 -or $total -le 0 -or $items.Count -ge $total) { break }
        if ($page -ge 1000) { throw 'sap_list_request exceeded 1000 pages.' }
        $page++
    }
    return @($items)
}

function Get-IncidentSystem {
    $response = Invoke-ConfsRequest ([ordered]@{cmd_name='system_list_request';puc_id=[string]$environmentConfig.pucId;user_id=[string]$environmentConfig.adminAccount;realm=[string]$environmentConfig.realm})
    $matches = @((Get-Value $response 'system_list' @()) | Where-Object { [string](Get-Value $_ 'system_id' '') -ceq '298' })
    if ($matches.Count -eq 0) { throw $missingSystemMessage }
    if ($matches.Count -ne 1) { throw "The system list contains $($matches.Count) records whose system_id is 298; selection is ambiguous." }
    return $matches[0]
}

function Get-WuxiGatewayOption {
    $response = Invoke-PucJsonHttpRequest -Method GET -Uri $gatewayConfigEndpoint -Headers @{token=[string]$environmentConfig.token} -AllowInsecureTls ([bool]$environmentConfig.allowInsecureTls) -TimeoutSec 60 -Depth 80
    if ($null -eq $response) { throw 'gateway getConfig returned an empty response.' }
    $codeProperty = @($response.PSObject.Properties.Match('code')) | Select-Object -First 1
    if ($null -eq $codeProperty -or [string]$codeProperty.Value -ne '0') { throw (New-PucApiFailureMessage -Operation 'gateway getConfig' -Response $response) }
    $sapRules = @(Get-Value $response 'data' @())
    $typeRules = @($sapRules | Where-Object { [string](Get-Value $_ 'value' '') -ceq '97' })
    $options = [Collections.Generic.List[object]]::new()
    foreach ($rule in $typeRules) {
        foreach ($parameter in @((Get-Value $rule 'param' @()))) {
            if ([string](Get-Value $parameter 'node' '') -ceq 'base_info' -and [string](Get-Value $parameter 'name' '') -ceq 'gateway_type') {
                foreach ($option in @((Get-Value $parameter 'options' @()))) { if ($null -ne $option) { $options.Add($option) } }
            }
        }
    }
    $matches = @($options | Where-Object {
        $label = ([string](Get-Value $_ 'label' '')).TrimStart('*')
        [string](Get-Value $_ 'value' '') -ceq '18' -and $label -in @($wuxiIncidentLabel,'gateway.options.3rddata_type.18','Wuxi Police Incident')
    })
    if ($matches.Count -eq 0) { throw $missingGatewayMessage }
    if ($matches.Count -ne 1) { throw "The gateway type list contains $($matches.Count) Wuxi incident records; selection is ambiguous." }
    return $matches[0]
}

function New-IncidentGatewayPayload([string]$OuterSapGuid, [string]$InnerSapGuid, [string]$RecordGuid, $SystemId) {
    return [ordered]@{
        sap_type=97; sap_alias='3rdwx'; system_id=$SystemId; domain_name=[string]$environmentConfig.realm
        gateway_type=18; auto_report=0; system_ip=$environmentIp; local_port=$null; local_path='/puc/ws'
        cmd_name='add_sap'; puc_id=[string]$environmentConfig.pucId; user_id=[string]$environmentConfig.adminAccount
        sap_guid=$OuterSapGuid; fleet_mon_reg_num=@(); redirect_list=@()
        sap_list=@([ordered]@{
            ssi='6060'; is_authen=0; account='admin'; password='123456'; system_url="http://${environmentIp}:$ServicePort"
            access_key='65095'; access_secret=''; data_type=0; nm_type=0; city_ip=''; pull_interval='60m'; time_zone='+8:00'
            associate_system_id=''; third_gb_id=''; third_sip_ip=''; third_sip_port=$null; heartbeat_interval=60
            sip_concurrency=100; local_sip_port=$null; Protocol=0; name_suffix=0; device_start_gb_id=''; organization_root=''
            police_update_insert=1; user_id=''; police_no=''; app_id=''; token_path=''; user_path=''; pgis_org_list=''
            intf_type=0; db_type=0; third_db_name='mydb'; third_db_ip=$environmentIp; third_db_port=4333; table_name=''
            sync_interval=$null; name_prefix=''; mounted_org_code=''; heartbeat_url=''; log_url=''; user_system_id=''; verify_code=''
            zero_trust_account=''; zero_trust_password=''; zero_trust_app_id=''; zero_trust_app_caller_id=''; zero_trust_app_sign_key=''
            zero_trust_task_id='RWd940b16af1ee46c3924ebbf2650001ff'; zero_trust_auth_type='1'
            zero_trust_url='https://141.49.19.90:7008/portal-web/api/nointeractionlogin'; xsp_client_id=''; xsp_client_secret=''
            xsp_api_host='http://141.49.19.166:8999'; auth_api_host='https://141.49.19.166:8443'; server_time_offset='15m'
            local_tcp_port=$ServicePort; pull_data_size=100; report_limit=10; pull_last_day=1; operator_name=''; operator_org=''; operator_id=''
            client_id=''; client_secret=''; access_token_url=''; refresh_token_url=''; request_hander_url=$environmentIp; duty_url=$environmentIp
            avatar_server=''; audio_file_url="http://${environmentIp}:$ServicePort/api/bps/alarm/getZfzy"; get_token_interval='60m'; token_url=''; ai_service_url=''; agent_id=''
            wxsms_send_method=0; extend_field_list=''; sync_device_type_list=@(); area_num_list=@(); sync_data_type_list=@()
            contacted_system_list=@(); tsc_list=@(); sap_guid=$InnerSapGuid; system_id=$SystemId; puc_id=[string]$environmentConfig.pucId
            guid=$RecordGuid; domain_name=[string]$environmentConfig.realm
        })
    }
}

function Get-SnapshotHash($SapItems, $System, $GatewayOption) {
    $selectedSystemId = Get-Value $System 'system_id' $null
    $snapshot = [ordered]@{
        environment=$Environment; environmentIp=$environmentIp; servicePort=$ServicePort; domainName=[string]$environmentConfig.realm; pucId=[string]$environmentConfig.pucId
        sapAliases=@($SapItems | ForEach-Object { ([string](Get-Value $_ 'sap_alias' '')).Trim() } | Sort-Object)
        system=[ordered]@{system_id=$selectedSystemId;system_id_type=$(if($null -eq $selectedSystemId){''}else{$selectedSystemId.GetType().FullName});system_alias=[string](Get-Value $System 'system_alias' '');system_type=[string](Get-Value $System 'system_type' '')}
        gateway=[ordered]@{value=[string](Get-Value $GatewayOption 'value' '');label=[string](Get-Value $GatewayOption 'label' '')}
        template=(New-IncidentGatewayPayload 'OUTER_GUID' 'INNER_GUID' 'RECORD_GUID' $selectedSystemId)
    }
    $bytes = ConvertTo-PucJsonBytes -Value $snapshot -Depth 80
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

function Get-CurrentState {
    $sapItems = @(Get-AllSapBaseItems)
    $duplicates = @($sapItems | Where-Object { [string]::Equals(([string](Get-Value $_ 'sap_alias' '')).Trim(), '3rdwx', [StringComparison]::OrdinalIgnoreCase) })
    if ($duplicates.Count -gt 0) {
        return [pscustomobject]@{AlreadyExists=$true;SapItems=$sapItems;DuplicateCount=$duplicates.Count;System=$null;GatewayOption=$null;SnapshotHash=''}
    }
    $system = Get-IncidentSystem
    $gatewayOption = Get-WuxiGatewayOption
    return [pscustomobject]@{AlreadyExists=$false;SapItems=$sapItems;DuplicateCount=0;System=$system;GatewayOption=$gatewayOption;SnapshotHash=(Get-SnapshotHash $sapItems $system $gatewayOption)}
}

$state = Get-CurrentState
if ($state.AlreadyExists) {
    [pscustomobject]@{status='already-exists';action='AddIncidentGateway';environment=$Environment;sapAlias='3rdwx';duplicateCount=$state.DuplicateCount;message=$alreadyExistsMessage;writesUsed=0} | ConvertTo-Json -Depth 10 -Compress
    return
}

$selectedSystemId = Get-Value $state.System 'system_id' $null
$previewPayload = New-IncidentGatewayPayload 'GENERATED_AT_LIVE' 'GENERATED_AT_LIVE' 'GENERATED_AT_LIVE' $selectedSystemId
if ($DryRun) {
    [pscustomobject]@{
        status='ready';action='AddIncidentGateway';environment=$Environment;environmentIp=$environmentIp;servicePort=$ServicePort;sapAlias='3rdwx'
        systemId=$selectedSystemId;systemAlias=[string](Get-Value $state.System 'system_alias' '');gatewayType=18
        gatewayLabel=[string](Get-Value $state.GatewayOption 'label' '');snapshotHash=$state.SnapshotHash;writesUsed=0
        systemUrl="http://${environmentIp}:$ServicePort";localTcpPort=$ServicePort;audioFileUrl="http://${environmentIp}:$ServicePort/api/bps/alarm/getZfzy"
        endpoints=[ordered]@{systemUrl="http://${environmentIp}:$ServicePort";localTcpPort=$ServicePort;thirdDbIp=$environmentIp;requestHanderUrl=$environmentIp;dutyUrl=$environmentIp;audioFileUrl="http://${environmentIp}:$ServicePort/api/bps/alarm/getZfzy"}
        requestPreview=(ConvertTo-PucDisplayValue -Value $previewPayload)
    } | ConvertTo-Json -Depth 80 -Compress
    return
}

if (-not [string]::Equals($state.SnapshotHash, $ExpectedSnapshotHash, [StringComparison]::OrdinalIgnoreCase)) { throw 'Incident gateway state changed after preview. Run DryRun again before creating.' }
$outerSapGuid = [guid]::NewGuid().ToString()
$innerSapGuid = [guid]::NewGuid().ToString()
$recordGuid = [guid]::NewGuid().ToString()
$payload = New-IncidentGatewayPayload $outerSapGuid $innerSapGuid $recordGuid $selectedSystemId
$createResponse = Invoke-ConfsRequest $payload

$verificationItems = @(Get-AllSapBaseItems)
$matches = @($verificationItems | Where-Object { [string]::Equals(([string](Get-Value $_ 'sap_alias' '')).Trim(), '3rdwx', [StringComparison]::OrdinalIgnoreCase) })
if ($matches.Count -ne 1) { throw "add_sap returned success but verification found $($matches.Count) 3rdwx records. No retry was attempted." }
$created = $matches[0]
$children = @((Get-Value $created 'sap_list' @()))
$validChildren = @($children | Where-Object {
    [string](Get-Value $_ 'system_id' '') -ceq [string]$selectedSystemId -and
    [string](Get-Value $_ 'system_url' '') -ceq "http://${environmentIp}:$ServicePort" -and
    [string](Get-Value $_ 'local_tcp_port' '') -ceq [string]$ServicePort -and
    [string](Get-Value $_ 'third_db_ip' '') -ceq $environmentIp -and
    [string](Get-Value $_ 'request_hander_url' '') -ceq $environmentIp -and
    [string](Get-Value $_ 'duty_url' '') -ceq $environmentIp -and
    [string](Get-Value $_ 'audio_file_url' '') -ceq "http://${environmentIp}:$ServicePort/api/bps/alarm/getZfzy"
})
if ([string](Get-Value $created 'sap_type' '') -cne '97' -or [string](Get-Value $created 'system_id' '') -cne [string]$selectedSystemId -or [string](Get-Value $created 'gateway_type' '') -cne '18' -or [string](Get-Value $created 'system_ip' '') -cne $environmentIp -or $validChildren.Count -ne 1) {
    throw 'add_sap returned success but the created 3rdwx record did not match the fixed incident gateway configuration. No retry was attempted.'
}

[pscustomobject]@{
    status='created';action='AddIncidentGateway';environment=$Environment;environmentIp=$environmentIp;servicePort=$ServicePort;sapAlias='3rdwx'
    systemId=$selectedSystemId;gatewayType=18;systemUrl="http://${environmentIp}:$ServicePort";localTcpPort=$ServicePort;audioFileUrl="http://${environmentIp}:$ServicePort/api/bps/alarm/getZfzy"
    sapGuid=$outerSapGuid;result=[string](Get-Value $createResponse 'result' '');writesUsed=1;verified=$true
} | ConvertTo-Json -Depth 20 -Compress
