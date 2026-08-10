[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export','Import')][string]$Action,
    [Parameter(Mandatory)][string]$Environment,
    [string]$FilePath,
    [string]$ProductName = 'PUC',
    [string]$Version = '10',
    [ValidateRange(1,60)][int]$PollIntervalSeconds = 5,
    [ValidateRange(30,3600)][int]$TimeoutSeconds = 1800,
    [switch]$PlanOnly,
    [switch]$ConfirmImport,
    [string]$ConfigRoot
)

$ErrorActionPreference = 'Stop'
if ($PlanOnly -and $Action -ne 'Import') { throw 'PlanOnly is supported only for Import.' }
if ($Action -eq 'Import' -and [string]::IsNullOrWhiteSpace($FilePath)) { throw 'FilePath is required for Import.' }
if ($Action -eq 'Import' -and -not $PlanOnly -and -not $ConfirmImport) {
    throw 'Import requires ConfirmImport after explicit confirmation of the environment and file.'
}
if ([string]::IsNullOrWhiteSpace($ProductName)) { throw 'ProductName must not be empty.' }
if ([string]::IsNullOrWhiteSpace($Version)) { throw 'Version must not be empty.' }

Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$root = Get-PucConfigRoot $ConfigRoot
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment

$resolvedImportPath = $null
$importFile = $null
$fileHash = $null
if ($Action -eq 'Import') {
    $resolvedImportPath = [IO.Path]::GetFullPath($FilePath)
    if (-not (Test-Path -LiteralPath $resolvedImportPath -PathType Leaf)) { throw "Import file does not exist: $resolvedImportPath" }
    $extension = [IO.Path]::GetExtension($resolvedImportPath).ToLowerInvariant()
    if ($extension -notin @('.json','.txt')) { throw 'Import file must have a .json or .txt extension.' }
    $importFile = Get-Item -LiteralPath $resolvedImportPath
    if ($importFile.Length -le 0) { throw 'Import file must not be empty.' }
    $fileHash = (Get-FileHash -LiteralPath $resolvedImportPath -Algorithm SHA256).Hash
    if ($PlanOnly) {
        [pscustomobject]@{
            status='planned'; action='Import'; environment=$Environment; filePath=$resolvedImportPath
            bytes=$importFile.Length; sha256=$fileHash; networkUsed=$false
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

function Invoke-PucTransferRequest([hashtable]$Body) {
    [byte[]]$jsonBody = ConvertTo-PucJsonBytes -Value $Body -Depth 30
    $params = @{
        Method='POST'
        Uri=$baseUri.AbsoluteUri.TrimEnd('/') + '/confs'
        ContentType='application/json; charset=utf-8'
        Headers=@{ Accept='application/json, text/plain, */*'; token=[string]$environmentConfig.token }
        Body=$jsonBody
        TimeoutSec=60
    }
    if ($environmentConfig.allowInsecureTls -eq $true -and (Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')) {
        $params.SkipCertificateCheck = $true
    }
    $result = ConvertFrom-PucResponseEncoding -Value (Invoke-RestMethod @params)
    if ($null -eq $result) { throw "The $($Body.cmd_name) response was empty. No retry was attempted." }
    return $result
}

function Get-SuccessResponse($Envelope, [string]$Operation) {
    $response = $Envelope.response
    if ($null -eq $response) { throw "$Operation response.response was missing. No retry was attempted." }
    $code = [string]$response.code_info.code
    $message = [string]$response.code_info.message
    if ([string]::IsNullOrWhiteSpace($message)) { $message = [string]$response.code_info.msg }
    if ($code -ne '0') { throw "$Operation failed: code=$code; msg=$message. No retry was attempted." }
    return $response
}

function Wait-PucTransfer([string]$ProgressCommand, [string]$TaskId) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        $envelope = Invoke-PucTransferRequest @{
            cmd_name=$ProgressCommand; product_name=$ProductName; version=$Version
            request=[ordered]@{ task_id=$TaskId; user=[string]$environmentConfig.adminAccount }
        }
        $response = Get-SuccessResponse $envelope $ProgressCommand
        $percentage = 0
        if (-not [int]::TryParse([string]$response.progress.percentage, [ref]$percentage)) {
            throw "$ProgressCommand returned an invalid percentage."
        }
        if ($percentage -ge 100) { return $response }
        if ($percentage -lt 0) { throw "$ProgressCommand reported failure percentage $percentage." }
        if ([DateTimeOffset]::UtcNow -ge $deadline) { throw "$ProgressCommand timed out after $TimeoutSeconds seconds." }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

try {
    if ($Action -eq 'Export') {
        $requestedTaskId = [guid]::NewGuid().ToString()
        $envelope = Invoke-PucTransferRequest @{
            cmd_name='export_request'; product_name=$ProductName; version=$Version
            request=[ordered]@{ task_id=$requestedTaskId; user=[string]$environmentConfig.adminAccount }
        }
        $response = Get-SuccessResponse $envelope 'export_request'
        $taskId = [string]$response.task_id
        if ([string]::IsNullOrWhiteSpace($taskId)) { throw 'export_request did not return a task ID. No retry was attempted.' }
        $completed = Wait-PucTransfer 'export_progress' $taskId
        $remoteFilePath = [string]$completed.progress.file_path
        $downloadToken = [string]$completed.progress.token
        if ([string]::IsNullOrWhiteSpace($remoteFilePath) -or [string]::IsNullOrWhiteSpace($downloadToken)) {
            throw 'export_progress completed without both file_path and token.'
        }

        $downloadUri = if ([uri]::IsWellFormedUriString($remoteFilePath, [UriKind]::Absolute)) { [uri]$remoteFilePath } else { [uri]::new($baseUri, $remoteFilePath) }
        $safeEnvironment = $Environment -replace '[^A-Za-z0-9_.-]', '_'
        $exportDirectory = Join-Path (Join-Path $root 'configExport') $safeEnvironment
        New-Item -ItemType Directory -Force -Path $exportDirectory | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $outputPath = Join-Path $exportDirectory "pucConfig-$safeEnvironment-$stamp-$taskId.json"
        $partialPath = $outputPath + '.partial'
        if (Test-Path -LiteralPath $outputPath) { throw "Export target already exists: $outputPath" }
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
            if ($downloaded.Length -le 0) { throw 'Downloaded export file was empty.' }
            Move-Item -LiteralPath $partialPath -Destination $outputPath
        } finally {
            if (Test-Path -LiteralPath $partialPath) { Remove-Item -LiteralPath $partialPath -Force }
        }
        $output = Get-Item -LiteralPath $outputPath
        try {
            $licenseEnvelope = Invoke-PucTransferRequest @{
                cmd_name='license_download'; realm=[string]$environmentConfig.realm
            }
            $licenseResult = [string]$licenseEnvelope.result
            $licenseMessage = [string]$licenseEnvelope.msg
            if ($licenseResult -ne '0') {
                throw "license_download failed: result=$licenseResult; msg=$licenseMessage. No retry was attempted."
            }
            $licenseRemotePath = [string]$licenseEnvelope.file_url
            $licenseDownloadToken = [string]$licenseEnvelope.token
            if ([string]::IsNullOrWhiteSpace($licenseRemotePath) -or [string]::IsNullOrWhiteSpace($licenseDownloadToken)) {
                throw 'license_download completed without both file_url and token.'
            }
            if ($licenseRemotePath.IndexOf('/frs/licensedownload/', [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                throw 'license_download returned an unexpected file_url.'
            }

            $licenseDownloadUri = if ([uri]::IsWellFormedUriString($licenseRemotePath, [UriKind]::Absolute)) {
                [uri]$licenseRemotePath
            } else {
                [uri]::new($baseUri, $licenseRemotePath)
            }
            $licenseRemoteName = [IO.Path]::GetFileName($licenseDownloadUri.AbsolutePath)
            if ([string]::IsNullOrWhiteSpace($licenseRemoteName)) { throw 'license_download returned an empty file name.' }
            $licenseRemoteName = $licenseRemoteName -replace '[^A-Za-z0-9_.-]', '_'
            $licenseOutputPath = Join-Path $exportDirectory "pucLicense-$safeEnvironment-$stamp-$licenseRemoteName.enc"
            $licensePartialPath = $licenseOutputPath + '.partial'
            if (Test-Path -LiteralPath $licenseOutputPath) { throw "License export target already exists: $licenseOutputPath" }
            try {
                $licenseDownloadParams = @{
                    Uri=$licenseDownloadUri; Headers=@{ Authorization="Bearer $licenseDownloadToken" }
                    OutFile=$licensePartialPath; TimeoutSec=60; UseBasicParsing=$true
                }
                if ($environmentConfig.allowInsecureTls -eq $true -and (Get-Command Invoke-WebRequest).Parameters.ContainsKey('SkipCertificateCheck')) {
                    $licenseDownloadParams.SkipCertificateCheck = $true
                }
                Invoke-WebRequest @licenseDownloadParams | Out-Null
                $downloadedLicense = Get-Item -LiteralPath $licensePartialPath
                if ($downloadedLicense.Length -le 0) { throw 'Downloaded License file was empty.' }
                Move-Item -LiteralPath $licensePartialPath -Destination $licenseOutputPath
            } finally {
                if (Test-Path -LiteralPath $licensePartialPath) { Remove-Item -LiteralPath $licensePartialPath -Force }
            }
            $licenseOutput = Get-Item -LiteralPath $licenseOutputPath
        } catch {
            throw "License export failed after the configuration file was saved at '$outputPath': $($_.Exception.Message)"
        }
        [pscustomobject]@{
            status='exported'; environment=$Environment; taskId=$taskId
            filePath=$output.FullName; bytes=$output.Length; sha256=(Get-FileHash -LiteralPath $output.FullName -Algorithm SHA256).Hash
            configFilePath=$output.FullName; configBytes=$output.Length
            configSha256=(Get-FileHash -LiteralPath $output.FullName -Algorithm SHA256).Hash
            licenseFilePath=$licenseOutput.FullName; licenseBytes=$licenseOutput.Length
            licenseSha256=(Get-FileHash -LiteralPath $licenseOutput.FullName -Algorithm SHA256).Hash
        } | ConvertTo-Json -Compress
        return
    }

    $requestedTaskId = [guid]::NewGuid().ToString()
    $encodedFile = [Convert]::ToBase64String([IO.File]::ReadAllBytes($resolvedImportPath))
    $envelope = Invoke-PucTransferRequest @{
        cmd_name='import_request'; product_name=$ProductName; version=$Version
        request=[ordered]@{ task_id=$requestedTaskId; user=[string]$environmentConfig.adminAccount; file=$encodedFile }
    }
    $encodedFile = $null
    $response = Get-SuccessResponse $envelope 'import_request'
    $returnedTaskId = [string]$response.task_id
    if ([string]::IsNullOrWhiteSpace($returnedTaskId)) { throw 'import_request did not return a task ID. No retry was attempted.' }
    $completed = Wait-PucTransfer 'import_progress' $returnedTaskId
    [pscustomobject]@{
        status='imported'; environment=$Environment; taskId=$returnedTaskId; filePath=$resolvedImportPath
        bytes=$importFile.Length; sha256=$fileHash; percentage=[int]$completed.progress.percentage
    } | ConvertTo-Json -Compress
} finally {
    if ($callbackChanged) { [Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCallback }
}
