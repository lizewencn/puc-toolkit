[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][string]$FilePath,
    [ValidateSet('WebPUC','APP','WebConfs')][string]$Target = 'WebPUC',
    [switch]$PlanOnly,
    [switch]$ConfirmImport,
    [string]$ConfigRoot
)

$ErrorActionPreference = 'Stop'
if (-not $PlanOnly -and -not $ConfirmImport) {
    throw 'Permission menu import requires ConfirmImport after explicit confirmation of the environment, file, and target.'
}

Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$root = Get-PucConfigRoot $ConfigRoot
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment

$resolvedPath = [IO.Path]::GetFullPath($FilePath)
if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) { throw "Permission menu file does not exist: $resolvedPath" }
if ([IO.Path]::GetExtension($resolvedPath).ToLowerInvariant() -ne '.json') { throw 'Permission menu file must have a .json extension.' }
$file = Get-Item -LiteralPath $resolvedPath
if ($file.Length -le 0) { throw 'Permission menu file must not be empty.' }

$strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
try { $fileContent = [IO.File]::ReadAllText($resolvedPath, $strictUtf8) }
catch { throw "Permission menu file must be valid UTF-8: $($_.Exception.Message)" }
$trimmed = $fileContent.Trim()
if (-not ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) { throw 'Permission menu JSON top level must be an array.' }
try {
    $parsedMenu = $fileContent | ConvertFrom-Json
    $menu = @($parsedMenu)
}
catch { throw "Permission menu file is not valid JSON: $($_.Exception.Message)" }
if ($menu.Count -eq 0) { throw 'Permission menu JSON array must not be empty.' }

$keys = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$nodeCount = 0
function Test-MenuNodes {
    param([object[]]$Nodes, [int]$Depth)
    if ($Depth -gt 50) { throw 'Permission menu tree exceeds the maximum depth of 50.' }
    foreach ($node in $Nodes) {
        if ($null -eq $node -or $node -isnot [pscustomobject]) { throw 'Every permission menu entry must be a JSON object.' }
        $script:nodeCount++
        if ($script:nodeCount -gt 10000) { throw 'Permission menu tree exceeds the maximum of 10000 nodes.' }

        $keyProperty = @($node.PSObject.Properties.Match('key')) | Select-Object -First 1
        $nameProperty = @($node.PSObject.Properties.Match('name')) | Select-Object -First 1
        $checkProperty = @($node.PSObject.Properties.Match('isCheck')) | Select-Object -First 1
        if ($null -eq $keyProperty -or [string]::IsNullOrWhiteSpace([string]$keyProperty.Value)) { throw 'Every permission menu entry must have a non-empty key.' }
        if ($null -eq $nameProperty -or [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) { throw "Permission menu entry '$([string]$keyProperty.Value)' must have a non-empty name." }
        $checkValue = 0
        if ($null -eq $checkProperty -or -not [int]::TryParse([string]$checkProperty.Value, [ref]$checkValue) -or $checkValue -notin @(0,1)) {
            throw "Permission menu entry '$([string]$keyProperty.Value)' must have isCheck equal to 0 or 1."
        }
        if (-not $script:keys.Add([string]$keyProperty.Value)) { throw "Duplicate permission menu key: $([string]$keyProperty.Value)" }

        $childProperty = @($node.PSObject.Properties.Match('child')) | Select-Object -First 1
        if ($null -ne $childProperty -and $null -ne $childProperty.Value) {
            Test-MenuNodes -Nodes @($childProperty.Value) -Depth ($Depth + 1)
        }
    }
}
Test-MenuNodes -Nodes $menu -Depth 1

$targetMap = @{ WebPUC=0; APP=1; WebConfs=2 }
$fileTarget = [int]$targetMap[$Target]
$fileHash = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash
if ($PlanOnly) {
    [pscustomobject]@{
        status='planned'; action='PermissionMenuImport'; environment=$Environment; filePath=$resolvedPath
        target=$Target; fileTarget=$fileTarget; bytes=$file.Length; sha256=$fileHash; nodeCount=$nodeCount; networkUsed=$false
    } | ConvertTo-Json -Compress
    return
}

$validation = & (Join-Path $PSScriptRoot 'Invoke-PucAuth.ps1') -Action Ensure -Environment $Environment -ConfigRoot $root | ConvertFrom-Json
if ($validation.valid -ne $true) { throw "Saved token is not usable ($($validation.reason)). Complete the login workflow first." }
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
$baseUri = [uri]$environmentConfig.baseUrl

$body = [ordered]@{
        cmd_guid=[guid]::NewGuid().ToString(); cmd_name='puc_upload_custom_system'
        puc_id=[string]$environmentConfig.pucId; realm=[string]$environmentConfig.realm
        version=0; file_content=$fileContent; file_target=$fileTarget
    }
    $response = Invoke-PucJsonRequest -Uri ([uri]($baseUri.AbsoluteUri.TrimEnd('/') + '/confs')) -Body $body -Headers @{token=[string]$environmentConfig.token} -AllowInsecureTls ([bool]$environmentConfig.allowInsecureTls) -TimeoutSec 60 -Depth 30
    if ($null -eq $response) { throw 'puc_upload_custom_system returned an empty response. No retry was attempted.' }

    $code = [string]$response.result
    $message = [string]$response.msg
    if ([string]::IsNullOrWhiteSpace($code) -and $null -ne $response.common) { $code = [string]$response.common.result }
    if ([string]::IsNullOrWhiteSpace($message) -and $null -ne $response.common) { $message = [string]$response.common.msg }
    if ([string]::IsNullOrWhiteSpace($code) -and $null -ne $response.extbody) { $code = [string]$response.extbody.result }
    if ([string]::IsNullOrWhiteSpace($message) -and $null -ne $response.extbody) { $message = [string]$response.extbody.msg }
    if ($code -ne '0') { throw (New-PucApiFailureMessage -Operation 'puc_upload_custom_system' -Response $response) }

    [pscustomobject]@{
        status='imported'; action='PermissionMenuImport'; environment=$Environment; filePath=$resolvedPath
        target=$Target; fileTarget=$fileTarget; bytes=$file.Length; sha256=$fileHash; nodeCount=$nodeCount; result=$code
    } | ConvertTo-Json -Compress
