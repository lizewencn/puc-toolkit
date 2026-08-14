[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export','Import')][string]$Action,
    [Parameter(Mandatory)][string]$Environment,
    [string]$FilePath,
    [string]$OutputDirectory,
    [switch]$PlanOnly,
    [switch]$DryRun,
    [switch]$Live,
    [switch]$ConfirmImport,
    [string]$ExpectedPreviewHash,
    [string]$ConfigRoot
)

$ErrorActionPreference = 'Stop'
if ($PlanOnly -and $DryRun) { throw 'Use only one of PlanOnly or DryRun.' }
if ($Action -eq 'Export' -and ($PlanOnly -or $DryRun -or $Live -or $ConfirmImport -or -not [string]::IsNullOrWhiteSpace($FilePath))) {
    throw 'Export accepts only Environment, OutputDirectory, and ConfigRoot.'
}
if ($Action -eq 'Import') {
    if ([string]::IsNullOrWhiteSpace($FilePath)) { throw 'FilePath is required for Import.' }
    if (($PlanOnly -and $DryRun) -or ($PlanOnly -and $Live) -or ($DryRun -and $Live)) { throw 'Use exactly one of PlanOnly, DryRun, or Live.' }
    if (-not $PlanOnly -and -not $DryRun -and -not $Live) { throw 'Import requires PlanOnly, DryRun, or Live.' }
    if ($Live -and -not $ConfirmImport) { throw 'Live License import requires ConfirmImport.' }
    if ($Live -and [string]::IsNullOrWhiteSpace($ExpectedPreviewHash)) { throw 'Live License import requires ExpectedPreviewHash from DryRun.' }
}

Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$root = Get-PucConfigRoot $ConfigRoot
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment

$resolvedFilePath = $null
$licenseFile = $null
$fileHash = $null
if ($Action -eq 'Import') {
    $resolvedFilePath = [IO.Path]::GetFullPath($FilePath)
    if (-not (Test-Path -LiteralPath $resolvedFilePath -PathType Leaf)) { throw "License file does not exist: $resolvedFilePath" }
    $licenseFile = Get-Item -LiteralPath $resolvedFilePath
    if ($licenseFile.Extension.ToLowerInvariant() -ne '.enc') { throw 'License file must have a .enc extension.' }
    if ($licenseFile.Name -notmatch '^[0-9A-Za-z.-]+$') { throw 'License file name may contain only ASCII letters, digits, hyphens, and periods.' }
    if ($licenseFile.Length -le 0) { throw 'License file must not be empty.' }
    $fileHash = (Get-FileHash -LiteralPath $resolvedFilePath -Algorithm SHA256).Hash
    if ($PlanOnly) {
        [pscustomobject]@{
            status='planned'; action='Import'; environment=$Environment; filePath=$resolvedFilePath
            bytes=$licenseFile.Length; sha256=$fileHash; networkUsed=$false
        } | ConvertTo-Json -Compress
        return
    }
}

$validation = & (Join-Path $PSScriptRoot 'Invoke-PucAuth.ps1') -Action Ensure -Environment $Environment -ConfigRoot $root | ConvertFrom-Json
if ($validation.valid -ne $true) { throw "Saved token is not usable ($($validation.reason)). Complete the login workflow first." }
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
$baseUri = [uri]$environmentConfig.baseUrl

function Invoke-PucLicenseJsonRequest([hashtable]$Body) {
    $response = Invoke-PucJsonRequest -Uri ([uri]($baseUri.AbsoluteUri.TrimEnd('/') + '/confs')) -Body $Body -Headers @{token=[string]$environmentConfig.token} -AllowInsecureTls ([bool]$environmentConfig.allowInsecureTls) -TimeoutSec 60 -Depth 30
    if ($null -eq $response) { throw "The $($Body.cmd_name) response was empty. No retry was attempted." }
    return $response
}

function Invoke-PucLicenseMultipartRequest([System.Collections.IDictionary]$Fields, [string]$UploadPath) {
    $multipart = New-PucMultipartFormData -Fields $Fields -Files @([pscustomobject]@{
        Name='file'; FileName=[IO.Path]::GetFileName($UploadPath); ContentType='application/octet-stream'; Bytes=[IO.File]::ReadAllBytes($UploadPath)
    })
    $responseEnvelope = Invoke-PucHttpRequest -Method POST -Uri ([uri]($baseUri.AbsoluteUri.TrimEnd('/') + '/confs')) -Headers @{
        Accept='application/json, text/plain, */*'; token=[string]$environmentConfig.token; 'Content-Type'=$multipart.ContentType
    } -Body $multipart.BodyBytes -AllowInsecureTls ([bool]$environmentConfig.allowInsecureTls) -TimeoutSec 60
    $response = ConvertFrom-PucJsonHttpResponse -Response $responseEnvelope
    if ($null -eq $response) { throw "The $($Fields.cmd_name) response was empty. No retry was attempted." }
    return $response
}

function Assert-PucLicenseSuccess($Response, [string]$Operation) {
    $result = [string]$Response.result
    $message = [string]$Response.msg
    if ($result -ne '0') { throw (New-PucApiFailureMessage -Operation $Operation -Response $Response) }
}

function Get-PucLicensePreview {
    $currentResponse = Invoke-PucLicenseJsonRequest @{
        cmd_name='puc_get_license_info_list'; realm=[string]$environmentConfig.realm; puc_id=[string]$environmentConfig.pucId
    }
    $currentResult = [string]$currentResponse.result
    if ($currentResult -ne '0' -and $currentResult -ne '51800015' -and $currentResult -ne '51800017') {
        throw (New-PucApiFailureMessage -Operation 'puc_get_license_info_list' -Response $currentResponse)
    }
    $currentType = [string]$currentResponse.lic_info_list.license_base_info.licType
    $replacementRequired = $currentType -in @('Business','Temp')
    $incomingType = ''
    if ($replacementRequired) {
        $analysis = Invoke-PucLicenseMultipartRequest ([ordered]@{
            cmd_name='puc_analyze_license'; puc_id=[string]$environmentConfig.pucId; realm=[string]$environmentConfig.realm
        }) $resolvedFilePath
        Assert-PucLicenseSuccess $analysis 'puc_analyze_license'
        $incomingType = if ([string]$analysis.license_type -eq '1') { 'Business' } else { 'Temp' }
    }
    $snapshotText = "$Environment|$resolvedFilePath|$fileHash|$currentType|$incomingType|$replacementRequired"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $previewHash = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($snapshotText)) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
    return [pscustomobject]@{
        currentLicenseType=$currentType; incomingLicenseType=$incomingType
        replacementRequired=$replacementRequired; previewHash=$previewHash
    }
}

if ($Action -eq 'Export') {
        $response = Invoke-PucLicenseJsonRequest @{ cmd_name='license_download'; realm=[string]$environmentConfig.realm }
        Assert-PucLicenseSuccess $response 'license_download'
        $remotePath = [string]$response.file_url
        $downloadToken = [string]$response.token
        if ([string]::IsNullOrWhiteSpace($remotePath) -or [string]::IsNullOrWhiteSpace($downloadToken)) {
            throw 'license_download completed without both file_url and token.'
        }
        if ($remotePath.IndexOf('/frs/licensedownload/', [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw 'license_download returned an unexpected file_url.'
        }
        $downloadUri = if ([uri]::IsWellFormedUriString($remotePath, [UriKind]::Absolute)) { [uri]$remotePath } else { [uri]::new($baseUri, $remotePath) }
        $remoteName = [IO.Path]::GetFileName($downloadUri.AbsolutePath)
        if ([string]::IsNullOrWhiteSpace($remoteName)) { throw 'license_download returned an empty file name.' }
        $remoteName = $remoteName -replace '[^A-Za-z0-9_.-]', '_'
        $safeEnvironment = $Environment -replace '[^A-Za-z0-9_.-]', '_'
        $baseDirectory = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { Join-Path $root 'configExport' } else { [IO.Path]::GetFullPath($OutputDirectory) }
        $directory = Join-Path $baseDirectory $safeEnvironment
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
        $outputPath = Join-Path $directory "pucLicense-$safeEnvironment-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$remoteName.enc"
        if (Test-Path -LiteralPath $outputPath) { throw "License export target already exists: $outputPath" }
        $downloadResponse = Invoke-PucHttpRequest -Method GET -Uri $downloadUri -Headers @{Authorization="Bearer $downloadToken"} -AllowInsecureTls ([bool]$environmentConfig.allowInsecureTls) -TimeoutSec 60
        if ($null -eq $downloadResponse.BodyBytes -or $downloadResponse.BodyBytes.Count -le 0) { throw 'Downloaded License file was empty.' }
        Write-PucBytesAtomically -Path $outputPath -Bytes $downloadResponse.BodyBytes
        $output = Get-Item -LiteralPath $outputPath
        [pscustomobject]@{
            status='exported'; action='Export'; environment=$Environment; filePath=$output.FullName
            bytes=$output.Length; sha256=(Get-FileHash -LiteralPath $output.FullName -Algorithm SHA256).Hash
        } | ConvertTo-Json -Compress
        return
}

$preview = Get-PucLicensePreview
if ($DryRun) {
        [pscustomobject]@{
            status='previewed'; action='Import'; environment=$Environment; filePath=$resolvedFilePath
            bytes=$licenseFile.Length; sha256=$fileHash; currentLicenseType=$preview.currentLicenseType
            incomingLicenseType=$preview.incomingLicenseType; replacementRequired=$preview.replacementRequired
            previewHash=$preview.previewHash; networkUsed=$true; writeUsed=$false
        } | ConvertTo-Json -Compress
        return
    }
    if (-not [string]::Equals($ExpectedPreviewHash, $preview.previewHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'License state or file changed after preview. Run DryRun again before importing.'
    }
    $importResponse = Invoke-PucLicenseMultipartRequest ([ordered]@{ cmd_name='puc_pull_license_info' }) $resolvedFilePath
    Assert-PucLicenseSuccess $importResponse 'puc_pull_license_info'
    [pscustomobject]@{
        status='imported'; action='Import'; environment=$Environment; filePath=$resolvedFilePath
        bytes=$licenseFile.Length; sha256=$fileHash; previousLicenseType=$preview.currentLicenseType
        importedLicenseType=$preview.incomingLicenseType; replacement=$preview.replacementRequired
} | ConvertTo-Json -Compress
