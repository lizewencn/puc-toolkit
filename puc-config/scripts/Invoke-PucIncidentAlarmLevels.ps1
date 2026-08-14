[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [switch]$PlanOnly,
    [switch]$DryRun,
    [switch]$Live,
    [switch]$ConfirmLive,
    [string]$ExpectedPreviewHash,
    [string]$ConfigRoot,
    [string]$EndpointOverride
)

$ErrorActionPreference = 'Stop'
if (@($PlanOnly,$DryRun,$Live | Where-Object { $_ }).Count -ne 1) { throw 'Select exactly one mode: PlanOnly, DryRun, or Live.' }
if ($Live -and -not $ConfirmLive) { throw 'Live incident alarm-level configuration requires ConfirmLive after explicit confirmation.' }
if ($Live -and [string]::IsNullOrWhiteSpace($ExpectedPreviewHash)) { throw 'Live incident alarm-level configuration requires ExpectedPreviewHash from the authenticated dry run.' }
if (-not [string]::IsNullOrWhiteSpace($EndpointOverride) -and [Environment]::GetEnvironmentVariable('PUC_CONFIG_TEST_MODE') -ne '1') { throw 'EndpointOverride is available only in test mode.' }

Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PucIncidentAlarmLevels.psm1') -Force
$assetDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\assets\incident'))

if ($PlanOnly) {
    $assets = @(Resolve-PucIncidentAlarmLevelAssets -AssetDirectory $assetDirectory)
    [pscustomobject]@{
        status='planned-offline';action='ConfigureIncidentAlarmLevels';environment=$Environment
        itemCount=$assets.Count;items=@($assets | Select-Object Code,Name,Description,Color,Tone,ZipFileName)
        assetDirectory=$assetDirectory;networkUsed=$false;writesUsed=0
    } | ConvertTo-Json -Depth 10 -Compress
    return
}

$root = Get-PucConfigRoot $ConfigRoot
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
if ([string]::IsNullOrWhiteSpace($EndpointOverride)) {
    $validation = & (Join-Path $PSScriptRoot 'Invoke-PucAuth.ps1') -Action Ensure -Environment $Environment -ConfigRoot $root | ConvertFrom-Json
    if ($validation.valid -ne $true) { throw "Saved token is not usable ($($validation.reason)). Complete the login workflow first." }
    $environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
}
$endpoint = if ([string]::IsNullOrWhiteSpace($EndpointOverride)) { $environmentConfig.baseUrl.TrimEnd('/') + '/confs' } else { $EndpointOverride }

function Get-ResponseProperty($Object,[string]$Name,$Default=$null) {
    if ($null -eq $Object) { return $Default }
    $property=@($Object.PSObject.Properties.Match($Name))|Select-Object -First 1
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Assert-IncidentResponse($Value,[string]$Operation) {
    if ($null -eq $Value) { throw "$Operation returned an empty response. No retry was attempted." }
    $result=Get-ResponseProperty $value 'result' $null
    if ($null -eq $result) { throw "$Operation response did not contain result. No retry was attempted." }
    if ([string]$result -ne '0') { throw (New-PucApiFailureMessage -Operation $Operation -Response $value) }
    return $value
}

function Invoke-JsonRequest([hashtable]$Body) {
    $response=Invoke-PucJsonRequest -Uri ([uri]$endpoint) -Body $Body -Headers @{token=[string]$environmentConfig.token} -AllowInsecureTls ([bool]$environmentConfig.allowInsecureTls) -TimeoutSec 60 -Depth 30
    return Assert-IncidentResponse $response ([string]$Body.cmd_name)
}

function Get-AllTones {
    $page=1;$all=[Collections.Generic.List[object]]::new()
    while ($true) {
        $response=Invoke-JsonRequest ([ordered]@{cmd_guid=[guid]::NewGuid().ToString();cmd_name='query_alert_tone';puc_id=[string]$environmentConfig.pucId;realm=[string]$environmentConfig.realm;user_id=[string]$environmentConfig.adminAccount;page_index=$page;page_size=100})
        foreach($item in @((Get-ResponseProperty $response 'data' @()))){if($null-ne$item){$all.Add($item)}}
        $total=0;[void][int]::TryParse([string](Get-ResponseProperty $response 'total' $all.Count),[ref]$total)
        if($all.Count-ge$total-or$total-le 0){break};if($page-ge 1000){throw 'Tone lookup exceeded 1000 pages.'};$page++
    }
    return @($all)
}

function Get-AllLevels {
    $page=1;$all=[Collections.Generic.List[object]]::new()
    while ($true) {
        $response=Invoke-JsonRequest ([ordered]@{cmd_guid=[guid]::NewGuid().ToString();cmd_name='taskmgr_query_police_incident_alarm_level';puc_id=[string]$environmentConfig.pucId;realm=[string]$environmentConfig.realm;user_id=[string]$environmentConfig.adminAccount;page_number=$page;page_size=100;is_icon_list=$true})
        foreach($item in @((Get-ResponseProperty $response 'alarm_level_list' @()))){if($null-ne$item){$all.Add($item)}}
        $pageInfo=Get-ResponseProperty $response 'page_info' $null
        $maxPage=0;[void][int]::TryParse([string](Get-ResponseProperty $pageInfo 'max_page' 0),[ref]$maxPage)
        if($maxPage-le 0-or$page-ge$maxPage){break};if($page-ge 1000){throw 'Alarm-level lookup exceeded 1000 pages.'};$page++
    }
    return @($all)
}

function New-CurrentPreview {
    $assets=@(Resolve-PucIncidentAlarmLevelAssets -AssetDirectory $assetDirectory|ForEach-Object{$zip=Test-PucIncidentZip $_.ZipPath;[pscustomobject]@{Code=$_.Code;Name=$_.Name;Description=$_.Description;Color=$_.Color;Tone=$_.Tone;ZipPath=$_.ZipPath;ZipFileName=$_.ZipFileName;ZipSha256=$zip.Sha256}})
    return New-PucIncidentAlarmLevelPreview -Environment $Environment -Assets $assets -Tones @(Get-AllTones) -ExistingLevels @(Get-AllLevels)
}

function Invoke-CreateLevel($Item) {
    $multipart=New-PucMultipartFormData -Fields ([ordered]@{
        cmd_guid=[guid]::NewGuid().ToString();cmd_name='taskmgr_add_police_incident_alarm_level'
        puc_id=[string]$environmentConfig.pucId;realm=[string]$environmentConfig.realm;user_id=[string]$environmentConfig.adminAccount
        level_code=$Item.Code;level_name=$Item.Name;level_desc=$Item.Description;icon_color=$Item.Color;icon_zip_name=$Item.ZipFileName;tone_id=$Item.Tone
    }) -Files @([pscustomobject]@{Name='icon_zip_file';FileName=$Item.ZipFileName;ContentType='application/x-zip-compressed';Bytes=[IO.File]::ReadAllBytes($Item.ZipPath)})
    $envelope=Invoke-PucHttpRequest -Method POST -Uri ([uri]$endpoint) -Headers @{
        Accept='application/json, text/plain, */*';token=[string]$environmentConfig.token;'Content-Type'=$multipart.ContentType
    } -Body $multipart.BodyBytes -AllowInsecureTls ([bool]$environmentConfig.allowInsecureTls) -TimeoutSec 60
    return Assert-IncidentResponse (ConvertFrom-PucJsonHttpResponse -Response $envelope) 'taskmgr_add_police_incident_alarm_level'
}

$preview=New-CurrentPreview
    if($DryRun){$preview|ConvertTo-Json -Depth 12 -Compress;return}
    if(-not[string]::Equals($preview.PreviewHash,$ExpectedPreviewHash,[StringComparison]::OrdinalIgnoreCase)){throw 'Incident alarm-level state or assets changed after preview. Run DryRun again before configuring.'}
    $results=[Collections.Generic.List[object]]::new();$failed=$false
    foreach($item in $preview.Items){
        if($item.Classification-eq'conflict'){$results.Add([pscustomobject]@{code=$item.Code;name=$item.Name;status='conflict-skipped';reason=$item.Reason});continue}
        if($failed){$results.Add([pscustomobject]@{code=$item.Code;name=$item.Name;status='not-attempted';reason='earlier-write-failed'});continue}
        try{$response=Invoke-CreateLevel $item;$results.Add([pscustomobject]@{code=$item.Code;name=$item.Name;status='created';result=[string]$response.result;reason=''})}
        catch{
            $createError=$_.Exception.Message;$isConflict=$false
            try{$isConflict=@(Get-AllLevels|Where-Object { [string](Get-ResponseProperty $_ 'level_code' '') -ceq $item.Code -or [string](Get-ResponseProperty $_ 'level_name' '') -ceq $item.Name }).Count-gt 0}catch{$isConflict=$false}
            if($isConflict){$results.Add([pscustomobject]@{code=$item.Code;name=$item.Name;status='conflict-skipped';reason='create-time-code-or-name-conflict'})}
            else{$failed=$true;$results.Add([pscustomobject]@{code=$item.Code;name=$item.Name;status='failed';reason=$createError})}
        }
    }
    if($failed){[pscustomobject]@{status='partial-failure';action='ConfigureIncidentAlarmLevels';environment=$Environment;previewHash=$preview.PreviewHash;results=@($results);verified=$false}|ConvertTo-Json -Depth 12 -Compress;exit 1}
    $levels=@(Get-AllLevels)
    foreach($result in @($results|Where-Object status -eq 'created')){
        $target=@($preview.Items|Where-Object Code -ceq $result.code)|Select-Object -First 1
        $matches=@($levels|Where-Object { [string](Get-ResponseProperty $_ 'level_code' '') -ceq $target.Code -and [string](Get-ResponseProperty $_ 'level_name' '') -ceq $target.Name })
        if($matches.Count-ne 1){throw 'Created incident alarm level was not found during final verification. No retry was attempted.'}
        $record=$matches[0];$toneInfo=Get-ResponseProperty $record 'toneInfo' $null
        if([string](Get-ResponseProperty $record 'level_desc' '') -cne $target.Description -or [string](Get-ResponseProperty $record 'icon_color' '').ToUpperInvariant() -cne $target.Color.ToUpperInvariant() -or [string](Get-ResponseProperty $record 'icon_zip_name' '') -cne $target.ZipFileName -or [string](Get-ResponseProperty $toneInfo 'file_name' '') -cne $target.Tone){throw 'Created incident alarm level did not match the fixed configuration during final verification. No retry was attempted.'}
    }
[pscustomobject]@{status='configured';action='ConfigureIncidentAlarmLevels';environment=$Environment;previewHash=$preview.PreviewHash;results=@($results);writesUsed=@($results|Where-Object status -eq 'created').Count;verified=$true}|ConvertTo-Json -Depth 12 -Compress
