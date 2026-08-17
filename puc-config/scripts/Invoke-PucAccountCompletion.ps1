[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [string]$Account,
    [string]$Query,
    [switch]$NormalizeGeneratedAlias,
    [switch]$PlanOnly,
    [switch]$DryRun,
    [switch]$Live,
    [switch]$ConfirmLive,
    [string]$ManifestPath,
    [string]$ConfigRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (@($PlanOnly,$DryRun,$Live | Where-Object { $_ }).Count -ne 1) { throw 'Select exactly one mode: PlanOnly, DryRun, or Live.' }
if (($PlanOnly -or $DryRun) -and ([string]::IsNullOrWhiteSpace($Account) -eq [string]::IsNullOrWhiteSpace($Query))) {
    throw 'PlanOnly and DryRun require exactly one target: Account or Query.'
}
if (($DryRun -or $Live) -and [string]::IsNullOrWhiteSpace($ManifestPath)) { throw 'DryRun and Live require ManifestPath.' }
if ($Live -and -not $ConfirmLive) { throw 'Live account completion requires ConfirmLive after explicit confirmation.' }
if ($Environment -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Environment contains unsupported characters.' }
if ($Account -and $Account -notmatch '^[A-Za-z0-9_.@-]+$') { throw 'Account contains unsupported characters.' }
if ($Query -and $Query -notmatch '^[A-Za-z0-9_.@-]+$') { throw 'Query contains unsupported characters.' }

Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$root = Get-PucConfigRoot $ConfigRoot
$singleUpdateScript = Join-Path $PSScriptRoot 'Invoke-PucAccountUpdate.ps1'

function Get-PropertyValue($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = @($Object.PSObject.Properties.Match($Name)) | Select-Object -First 1
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Assert-Success($Response, [string]$Command) {
    if ($null -eq $Response) { throw "$Command returned an empty response. No retry was attempted." }
    $resultProperty = @($Response.PSObject.Properties.Match('result')) | Select-Object -First 1
    if ($null -eq $resultProperty) { throw "$Command returned a response without result. No retry was attempted." }
    if ([string]$resultProperty.Value -ne '0') {
        throw (New-PucApiFailureMessage -Operation $Command -Response $Response)
    }
}

function Invoke-PucRead([hashtable]$Body, $EnvironmentConfig) {
    $uri = [uri](([uri]$EnvironmentConfig.baseUrl).AbsoluteUri.TrimEnd('/') + '/confs')
    $response = Invoke-PucJsonRequest -Uri $uri -Body $Body -Headers @{ token=[string]$EnvironmentConfig.token } -AllowInsecureTls ([bool]$EnvironmentConfig.allowInsecureTls) -TimeoutSec 60 -Depth 60
    Assert-Success $response ([string]$Body.cmd_name)
    return $response
}

function Get-TargetRecords($EnvironmentConfig) {
    $search = if ($Account) { $Account } else { $Query }
    $records = [Collections.Generic.List[object]]::new()
    $pageIndex = 1
    while ($true) {
        $response = Invoke-PucRead ([ordered]@{
            cmd_name='account_list_request'; user_id=[string]$EnvironmentConfig.adminAccount; realm=[string]$EnvironmentConfig.realm
            page_sizes=30; page_index=$pageIndex; querykey=$search; lock_query=0; filter=[ordered]@{by_role='';by_state=0}
        }) $EnvironmentConfig
        foreach ($row in @((Get-PropertyValue $response 'account_list' @()))) {
            $name = [string](Get-PropertyValue $row 'dispatcher_account' '')
            $matches = if ($Account) {
                [string]::Equals($name,$Account,[StringComparison]::OrdinalIgnoreCase)
            } else {
                $name.StartsWith($Query,[StringComparison]::OrdinalIgnoreCase)
            }
            if ($matches) { $records.Add($row) }
        }
        $pageCount = 0
        [void][int]::TryParse([string](Get-PropertyValue $response 'page_count' 0),[ref]$pageCount)
        if ($pageCount -le 0 -or $pageIndex -ge $pageCount) { break }
        if ($pageIndex -ge 1000) { throw 'Account discovery exceeded 1000 pages.' }
        $pageIndex++
    }
    if ($Account -and $records.Count -ne 1) { throw "Exact account lookup for '$Account' returned $($records.Count) matches." }
    if ($records.Count -eq 0) { throw 'No dispatcher accounts matched the selected target.' }
    return @($records | Sort-Object { [string](Get-PropertyValue $_ 'dispatcher_account' '') })
}

function Get-CompletionBaseline($EnvironmentConfig) {
    $common = @{ puc_id=[string]$EnvironmentConfig.pucId; user_id=[string]$EnvironmentConfig.adminAccount; realm=[string]$EnvironmentConfig.realm }
    $systems = Invoke-PucRead ([ordered]@{cmd_name='system_list_request';puc_id=$common.puc_id;user_id=$common.user_id;realm=$common.realm}) $EnvironmentConfig
    $access = Invoke-PucRead ([ordered]@{cmd_name='sap_list_request';puc_id=$common.puc_id;realm=$common.realm}) $EnvironmentConfig
    $device = Invoke-PucRead ([ordered]@{cmd_name='short_organization_list_request';puc_id=$common.puc_id;user_id=$common.user_id;realm=$common.realm;org_identifier='';is_recursive_qry=0}) $EnvironmentConfig
    $address = Invoke-PucRead ([ordered]@{cmd_name='personnel_organization_list_req';puc_id=$common.puc_id;user_id=$common.user_id;realm=$common.realm;custom_org_id='';is_recursive_qry=0}) $EnvironmentConfig

    $systemIds = @((Get-PropertyValue $systems 'system_list' @()) | ForEach-Object { [string](Get-PropertyValue $_ 'system_id' '') } | Where-Object { $_ })
    if ($systemIds.Count -eq 0) { throw 'System lookup succeeded but returned no usable system IDs.' }
    $sapItems = foreach ($group in @((Get-PropertyValue $access 'sap_base_list' @()))) {
        foreach ($sap in @((Get-PropertyValue $group 'sap_list' @()))) {
            [ordered]@{
                pucid=[string](Get-PropertyValue $sap 'puc_id' ''); systemid=[string](Get-PropertyValue $sap 'system_id' '')
                grpname=[string](Get-PropertyValue $group 'sap_alias' ''); realm=[string](Get-PropertyValue $sap 'domain_name' '')
                ssi=@([ordered]@{label=[string](Get-PropertyValue $sap 'ssi' '');value=[string](Get-PropertyValue $sap 'guid' '')})
            }
        }
    }
    $deviceRoots = @((Get-PropertyValue $device 'organization_info_list' @()) | Where-Object {
        [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $_ 'parent_org_identifier' ''))
    })
    $addressRoots = @((Get-PropertyValue $address 'organization_info_list' @()) | Where-Object {
        [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $_ 'parent_custom_org_id' ''))
    })
    if ($deviceRoots.Count -ne 1) { throw "Device organization lookup returned $($deviceRoots.Count) roots; exactly one is required." }
    if ($addressRoots.Count -ne 1) { throw "Address-book organization lookup returned $($addressRoots.Count) roots; exactly one is required." }
    $deviceId = [string](Get-PropertyValue $deviceRoots[0] 'org_identifier' '')
    $deviceName = [string](Get-PropertyValue $deviceRoots[0] 'org_alias' '')
    $addressId = [string](Get-PropertyValue $addressRoots[0] 'custom_org_id' '')
    if ([string]::IsNullOrWhiteSpace($deviceId) -or [string]::IsNullOrWhiteSpace($deviceName) -or [string]::IsNullOrWhiteSpace($addressId)) {
        throw 'A unique root organization is missing a required ID or name.'
    }
    return [pscustomobject]@{
        SystemIdList=($systemIds -join ';'); SystemCount=$systemIds.Count
        DispatchSapList=([ordered]@{sapList=@($sapItems)} | ConvertTo-Json -Depth 30 -Compress); AccessCount=@($sapItems).Count
        DeviceId=$deviceId; DeviceName=$deviceName; AddressId=$addressId
    }
}

function New-Changes($Record, $Baseline) {
    $changes = [ordered]@{}
    $accountName = [string](Get-PropertyValue $Record 'dispatcher_account' '')
    $displayName = [string](Get-PropertyValue $Record 'dispatcher_name' '')
    if ([string]::IsNullOrWhiteSpace($displayName) -or ($NormalizeGeneratedAlias -and $displayName -ne ($accountName + '_alias'))) {
        $changes.dispatcher_name = $accountName + '_alias'
    }
    if ([string](Get-PropertyValue $Record 'org_identifier' '') -ne $Baseline.DeviceId -or [string](Get-PropertyValue $Record 'org_alias' '') -ne $Baseline.DeviceName) {
        $changes.org_identifier = $Baseline.DeviceId; $changes.org_alias = $Baseline.DeviceName
    }
    if ([string](Get-PropertyValue $Record 'org_identifier_list' '') -ne $Baseline.DeviceId) { $changes.org_identifier_list = $Baseline.DeviceId }
    if ([string](Get-PropertyValue $Record 'custom_org_identifier_list' '') -ne $Baseline.AddressId) { $changes.custom_org_identifier_list = $Baseline.AddressId }
    if ([string](Get-PropertyValue $Record 'custom_org_id' '') -ne $Baseline.AddressId) { $changes.custom_org_id = $Baseline.AddressId }
    if ([string](Get-PropertyValue $Record 'system_id_list' '') -ne $Baseline.SystemIdList) { $changes.system_id_list = $Baseline.SystemIdList }
    if ([string](Get-PropertyValue $Record 'dispatch_sap_list' '') -ne $Baseline.DispatchSapList) { $changes.dispatch_sap_list = $Baseline.DispatchSapList | ConvertFrom-Json }
    return [pscustomobject]$changes
}

if ($PlanOnly) {
    [pscustomobject]@{status='planned-offline';action='CompleteAccountInformation';environment=$Environment;targetSource=$(if($Account){'account'}else{'query-prefix'});account=$Account;query=$Query;normalizeGeneratedAlias=[bool]$NormalizeGeneratedAlias;networkUsed=$false;writesUsed=0} | ConvertTo-Json -Depth 5 -Compress
    return
}

if ($DryRun) {
    $validation = & (Join-Path $PSScriptRoot 'Invoke-PucAuth.ps1') -Action Ensure -Environment $Environment -ConfigRoot $root | ConvertFrom-Json
    if ($validation.valid -ne $true) { throw "Saved token is not usable ($($validation.reason)). Complete the login workflow first." }
    $environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
    $baseline = Get-CompletionBaseline $environmentConfig
    $records = @(Get-TargetRecords $environmentConfig)
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($record in $records) {
        $targetAccount = [string](Get-PropertyValue $record 'dispatcher_account' '')
        $changes = New-Changes $record $baseline
        if (@($changes.PSObject.Properties).Count -eq 0) {
            $entries.Add([pscustomobject]@{account=$targetAccount;status='already-complete';snapshotHash='';changes=$changes})
            continue
        }
        $changesJson = $changes | ConvertTo-Json -Depth 30 -Compress
        $preview = & $singleUpdateScript -Environment $Environment -Account $targetAccount -ChangesJson $changesJson -DryRun -ConfigRoot $root | ConvertFrom-Json
        $entries.Add([pscustomobject]@{account=$targetAccount;status='previewed';snapshotHash=[string]$preview.snapshotHash;changes=$changes;changeSummary=@($preview.changes)})
    }
    $manifest = [ordered]@{
        version=1;environment=$Environment;targetSource=$(if($Account){'account'}else{'query-prefix'});account=$Account;query=$Query
        normalizeGeneratedAlias=[bool]$NormalizeGeneratedAlias;generatedAt=[DateTimeOffset]::UtcNow.ToString('o')
        baseline=[ordered]@{systemCount=$baseline.SystemCount;accessCount=$baseline.AccessCount;deviceRootId=$baseline.DeviceId;deviceRootName=$baseline.DeviceName;addressRootId=$baseline.AddressId}
        accounts=@($entries)
    }
    $resolvedManifestPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ManifestPath)
    Write-PucJson -Path $resolvedManifestPath -Value $manifest
    [pscustomobject]@{status='previewed';action='CompleteAccountInformation';environment=$Environment;targetSource=$manifest.targetSource;accountCount=$entries.Count;updateCount=@($entries|Where-Object status -eq 'previewed').Count;alreadyComplete=@($entries|Where-Object status -eq 'already-complete').Count;baseline=$manifest.baseline;accounts=@($entries);manifestPath=$resolvedManifestPath;writesUsed=0} | ConvertTo-Json -Depth 30 -Compress
    return
}

$resolvedManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
$manifest = Read-PucJson -Path $resolvedManifestPath -Default $null
if ($null -eq $manifest -or [int](Get-PropertyValue $manifest 'version' 0) -ne 1) { throw 'Unsupported or invalid account-completion manifest.' }
if (-not [string]::Equals([string]$manifest.environment,$Environment,[StringComparison]::Ordinal)) { throw 'Manifest environment does not match the selected environment.' }
$entries = @($manifest.accounts)
if ($entries.Count -eq 0) { throw 'The account-completion manifest contains no accounts.' }
$results = [Collections.Generic.List[object]]::new()
foreach ($entry in $entries) {
    $targetAccount = [string](Get-PropertyValue $entry 'account' '')
    if ([string](Get-PropertyValue $entry 'status' '') -eq 'already-complete') {
        $results.Add([pscustomobject]@{status='already-complete';account=$targetAccount})
        continue
    }
    $hash = [string](Get-PropertyValue $entry 'snapshotHash' '')
    if ($hash -notmatch '^[A-Fa-f0-9]{64}$') { throw "Account '$targetAccount' has an invalid snapshot hash." }
    $changesJson = (Get-PropertyValue $entry 'changes' $null) | ConvertTo-Json -Depth 30 -Compress
    try {
        $updated = & $singleUpdateScript -Environment $Environment -Account $targetAccount -ChangesJson $changesJson -Live -ConfirmLive -ExpectedSnapshotHash $hash -ConfigRoot $root | ConvertFrom-Json
        $results.Add($updated)
    } catch {
        [pscustomobject]@{status='partial-failure';action='CompleteAccountInformation';environment=$Environment;accountCount=$entries.Count;succeeded=@($results|Where-Object status -eq 'updated').Count;failedAccount=$targetAccount;error=$_.Exception.Message;results=@($results)} | ConvertTo-Json -Depth 20 -Compress
        exit 1
    }
}
[pscustomobject]@{status='completed';action='CompleteAccountInformation';environment=$Environment;accountCount=$entries.Count;succeeded=@($results|Where-Object status -eq 'updated').Count;alreadyComplete=@($results|Where-Object status -eq 'already-complete').Count;results=@($results)} | ConvertTo-Json -Depth 20 -Compress
