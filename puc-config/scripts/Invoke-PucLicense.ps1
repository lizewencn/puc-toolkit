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

$validation = & (Join-Path $PSScriptRoot 'Invoke-PucAuth.ps1') -Action Validate -Environment $Environment -ConfigRoot $root | ConvertFrom-Json
if ($validation.valid -ne $true) { throw "Saved token is not usable ($($validation.reason)). Complete the login workflow first." }
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
$baseUri = [uri]$environmentConfig.baseUrl
$oldCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
$callbackChanged = $false
if ($environmentConfig.allowInsecureTls -eq $true -and -not (Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')) {
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    $callbackChanged = $true
}

function Invoke-PucLicenseJsonRequest([hashtable]$Body) {
    [byte[]]$jsonBody = ConvertTo-PucJsonBytes -Value $Body -Depth 30
    $params = @{
        Method='POST'; Uri=$baseUri.AbsoluteUri.TrimEnd('/') + '/confs'
        ContentType='application/json; charset=utf-8'
        Headers=@{ Accept='application/json, text/plain, */*'; token=[string]$environmentConfig.token }
        Body=$jsonBody; TimeoutSec=60
    }
    if ($environmentConfig.allowInsecureTls -eq $true -and (Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')) {
        $params.SkipCertificateCheck = $true
    }
    $response = ConvertFrom-PucResponseEncoding -Value (Invoke-RestMethod @params)
    if ($null -eq $response) { throw "The $($Body.cmd_name) response was empty. No retry was attempted." }
    return $response
}

function Invoke-PucLicenseMultipartRequest([System.Collections.IDictionary]$Fields, [string]$UploadPath) {
    $boundary = '----------------PucLicense' + [guid]::NewGuid().ToString('N')
    $stream = New-Object IO.MemoryStream
    try {
        foreach ($entry in $Fields.GetEnumerator()) {
            $part = "--$boundary`r`nContent-Disposition: form-data; name=`"$($entry.Key)`"`r`n`r`n$($entry.Value)`r`n"
            $partBytes = [Text.Encoding]::UTF8.GetBytes($part)
            $stream.Write($partBytes, 0, $partBytes.Length)
        }
        $fileName = [IO.Path]::GetFileName($UploadPath)
        $fileHeader = "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"$fileName`"`r`nContent-Type: application/octet-stream`r`n`r`n"
        $fileHeaderBytes = [Text.Encoding]::UTF8.GetBytes($fileHeader)
        $stream.Write($fileHeaderBytes, 0, $fileHeaderBytes.Length)
        $fileBytes = [IO.File]::ReadAllBytes($UploadPath)
        $stream.Write($fileBytes, 0, $fileBytes.Length)
        $footerBytes = [Text.Encoding]::UTF8.GetBytes("`r`n--$boundary--`r`n")
        $stream.Write($footerBytes, 0, $footerBytes.Length)
        [byte[]]$body = $stream.ToArray()
    } finally {
        $stream.Dispose()
    }
    $params = @{
        Method='POST'; Uri=$baseUri.AbsoluteUri.TrimEnd('/') + '/confs'
        ContentType="multipart/form-data; boundary=$boundary"
        Headers=@{ Accept='application/json, text/plain, */*'; token=[string]$environmentConfig.token }
        Body=$body; TimeoutSec=60
    }
    if ($environmentConfig.allowInsecureTls -eq $true -and (Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')) {
        $params.SkipCertificateCheck = $true
    }
    $response = ConvertFrom-PucResponseEncoding -Value (Invoke-RestMethod @params)
    if ($null -eq $response) { throw "The $($Fields.cmd_name) response was empty. No retry was attempted." }
    return $response
}

function Assert-PucLicenseSuccess($Response, [string]$Operation) {
    $result = [string]$Response.result
    $message = [string]$Response.msg
    if ($result -ne '0') { throw "$Operation failed: result=$result; msg=$message. No retry was attempted." }
}

function Get-PucLicensePreview {
    $currentResponse = Invoke-PucLicenseJsonRequest @{
        cmd_name='puc_get_license_info_list'; realm=[string]$environmentConfig.realm; puc_id=[string]$environmentConfig.pucId
    }
    $currentResult = [string]$currentResponse.result
    if ($currentResult -ne '0' -and $currentResult -ne '51800015' -and $currentResult -ne '51800017') {
        throw "puc_get_license_info_list failed: result=$currentResult; msg=$([string]$currentResponse.msg). No retry was attempted."
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

try {
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
        $partialPath = $outputPath + '.partial'
        try {
            $downloadParams = @{
                Uri=$downloadUri; Headers=@{ Authorization="Bearer $downloadToken" }
                OutFile=$partialPath; TimeoutSec=60; UseBasicParsing=$true
            }
            if ($environmentConfig.allowInsecureTls -eq $true -and (Get-Command Invoke-WebRequest).Parameters.ContainsKey('SkipCertificateCheck')) {
                $downloadParams.SkipCertificateCheck = $true
            }
            Invoke-WebRequest @downloadParams | Out-Null
            $downloaded = Get-Item -LiteralPath $partialPath
            if ($downloaded.Length -le 0) { throw 'Downloaded License file was empty.' }
            Move-Item -LiteralPath $partialPath -Destination $outputPath
        } finally {
            if (Test-Path -LiteralPath $partialPath) { Remove-Item -LiteralPath $partialPath -Force }
        }
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
} finally {
    if ($callbackChanged) { [Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCallback }
}
