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
$root = Get-PucConfigRoot $ConfigRoot
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

$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
if ([string]::IsNullOrWhiteSpace($EndpointOverride)) {
    $validation = & (Join-Path $PSScriptRoot 'Invoke-PucAuth.ps1') -Action Validate -Environment $Environment -ConfigRoot $root | ConvertFrom-Json
    if ($validation.valid -ne $true) { throw "Saved token is not usable ($($validation.reason)). Complete the login workflow first." }
    $environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
}
$endpoint = if ([string]::IsNullOrWhiteSpace($EndpointOverride)) { $environmentConfig.baseUrl.TrimEnd('/') + '/confs' } else { $EndpointOverride }

Add-Type -AssemblyName System.Net.Http
$oldCertificateCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
$certificateCallbackChanged = $false
if ($environmentConfig.allowInsecureTls -eq $true) {
    if ($null -eq ('PucIncidentTls' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class PucIncidentTls {
    public static bool Accept(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors) { return true; }
    public static readonly RemoteCertificateValidationCallback Callback = Accept;
}
'@
    }
    [Net.ServicePointManager]::ServerCertificateValidationCallback = [PucIncidentTls]::Callback
    $certificateCallbackChanged = $true
}
$handler = [Net.Http.HttpClientHandler]::new()
$client = [Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(60)
$client.DefaultRequestHeaders.Accept.ParseAdd('application/json, text/plain, */*')
$client.DefaultRequestHeaders.Add('token',[string]$environmentConfig.token)

function Get-ResponseProperty($Object,[string]$Name,$Default=$null) {
    if ($null -eq $Object) { return $Default }
    $property=@($Object.PSObject.Properties.Match($Name))|Select-Object -First 1
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function ConvertFrom-HttpResponse([Net.Http.HttpResponseMessage]$Response,[string]$Operation) {
    $text=$Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $Response.IsSuccessStatusCode) { throw "$Operation failed: HTTP $([int]$Response.StatusCode). No retry was attempted." }
    if ([string]::IsNullOrWhiteSpace($text)) { throw "$Operation returned an empty response. No retry was attempted." }
    try { $value=$text|ConvertFrom-Json } catch { throw "$Operation returned invalid JSON. No retry was attempted." }
    $value=ConvertFrom-PucResponseEncoding -Value $value
    $result=Get-ResponseProperty $value 'result' $null
    if ($null -eq $result) { throw "$Operation response did not contain result. No retry was attempted." }
    if ([string]$result -ne '0') { throw "$Operation failed: result=$result; msg=$([string](Get-ResponseProperty $value 'msg' '')). No retry was attempted." }
    return $value
}

function Invoke-JsonRequest([hashtable]$Body) {
    [byte[]]$bytes=ConvertTo-PucJsonBytes -Value $Body -Depth 30
    $content=[Net.Http.ByteArrayContent]::new($bytes)
    try {
        $content.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/json; charset=utf-8')
        $response=$client.PostAsync($endpoint,$content).GetAwaiter().GetResult()
        try { return ConvertFrom-HttpResponse $response ([string]$Body.cmd_name) } finally { $response.Dispose() }
    } finally { $content.Dispose() }
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

function Add-TextPart([Net.Http.MultipartFormDataContent]$Form,[string]$Name,[string]$Value) {
    $part=[Net.Http.StringContent]::new($Value,[Text.Encoding]::UTF8)
    $Form.Add($part,$Name)
}

function Invoke-CreateLevel($Item) {
    $form=[Net.Http.MultipartFormDataContent]::new()
    $stream=$null
    try {
        $stream=[IO.File]::OpenRead($Item.ZipPath)
        $file=[Net.Http.StreamContent]::new($stream)
        $file.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/x-zip-compressed')
        $form.Add($file,'icon_zip_file',$Item.ZipFileName)
        Add-TextPart $form 'cmd_guid' ([guid]::NewGuid().ToString())
        Add-TextPart $form 'cmd_name' 'taskmgr_add_police_incident_alarm_level'
        Add-TextPart $form 'puc_id' ([string]$environmentConfig.pucId)
        Add-TextPart $form 'realm' ([string]$environmentConfig.realm)
        Add-TextPart $form 'user_id' ([string]$environmentConfig.adminAccount)
        Add-TextPart $form 'level_code' $Item.Code
        Add-TextPart $form 'level_name' $Item.Name
        Add-TextPart $form 'level_desc' $Item.Description
        Add-TextPart $form 'icon_color' $Item.Color
        Add-TextPart $form 'icon_zip_name' $Item.ZipFileName
        Add-TextPart $form 'tone_id' $Item.Tone
        $response=$client.PostAsync($endpoint,$form).GetAwaiter().GetResult()
        try { return ConvertFrom-HttpResponse $response 'taskmgr_add_police_incident_alarm_level' } finally { $response.Dispose() }
    } finally { $form.Dispose();if($null-ne$stream){$stream.Dispose()} }
}

try {
    $preview=New-CurrentPreview
    if($DryRun){$preview|ConvertTo-Json -Depth 12 -Compress;return}
    if($preview.HasConflict){throw "Incident alarm-level preflight found conflicts. No writes were attempted. previewHash=$($preview.PreviewHash)"}
    if(-not[string]::Equals($preview.PreviewHash,$ExpectedPreviewHash,[StringComparison]::OrdinalIgnoreCase)){throw 'Incident alarm-level state or assets changed after preview. Run DryRun again before configuring.'}
    $results=[Collections.Generic.List[object]]::new();$failed=$false
    foreach($item in $preview.Items){
        if($item.Classification-eq'unchanged'){$results.Add([pscustomobject]@{code=$item.Code;name=$item.Name;status='unchanged';reason='' });continue}
        if($failed){$results.Add([pscustomobject]@{code=$item.Code;name=$item.Name;status='not-attempted';reason='earlier-write-failed'});continue}
        try{$response=Invoke-CreateLevel $item;$results.Add([pscustomobject]@{code=$item.Code;name=$item.Name;status='created';result=[string]$response.result;reason=''})}
        catch{$failed=$true;$results.Add([pscustomobject]@{code=$item.Code;name=$item.Name;status='failed';reason=$_.Exception.Message})}
    }
    if($failed){[pscustomobject]@{status='partial-failure';action='ConfigureIncidentAlarmLevels';environment=$Environment;previewHash=$preview.PreviewHash;results=@($results);verified=$false}|ConvertTo-Json -Depth 12 -Compress;exit 1}
    $verified=New-CurrentPreview
    if($verified.HasConflict-or$verified.PlannedWrites-ne 0){throw 'All writes succeeded, but final incident alarm-level verification did not match the fixed configuration. No retry was attempted.'}
    [pscustomobject]@{status='configured';action='ConfigureIncidentAlarmLevels';environment=$Environment;previewHash=$preview.PreviewHash;results=@($results);writesUsed=@($results|Where-Object status -eq 'created').Count;verified=$true}|ConvertTo-Json -Depth 12 -Compress
} finally {
    $client.Dispose();$handler.Dispose()
    if ($certificateCallbackChanged) { [Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCertificateCallback }
}
