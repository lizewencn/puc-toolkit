[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [string]$ConfigRoot,
    [switch]$RequireWriteAccess,
    [switch]$RequireNewAccountPassword,
    [switch]$ValidateToken
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$root = Get-PucConfigRoot $ConfigRoot
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
$node = Resolve-PucNodeExecutable
$configPath = Join-Path $root 'config.json'
$writable = $null
if ($RequireWriteAccess) { $writable = [bool](Test-PucConfigWriteAccess -ConfigRoot $root) }
if ($RequireNewAccountPassword -and [string]::IsNullOrWhiteSpace([string]$environmentConfig.newAccountPassword)) {
    throw "newAccountPassword is empty for environment '$Environment'. Fill it in config.json locally."
}
$tokenStatus = 'not-checked'
if ($ValidateToken) {
    $validation = & (Join-Path $PSScriptRoot 'Invoke-PucAuth.ps1') -Action Validate -Environment $Environment -ConfigRoot $root | ConvertFrom-Json
    $tokenStatus = if ($validation.valid -eq $true) { 'valid' } else { [string]$validation.reason }
}
[pscustomobject]@{
    status='environment-checked'; environment=$Environment; baseUrl=[string]$environmentConfig.baseUrl
    configRoot=$root; configReadable=(Test-Path -LiteralPath $configPath -PathType Leaf); configWritable=$writable
    nodeAvailable=$true; nodeExecutable=[IO.Path]::GetFileName($node)
    newAccountPasswordConfigured=(-not [string]::IsNullOrWhiteSpace([string]$environmentConfig.newAccountPassword))
    tokenStatus=$tokenStatus
} | ConvertTo-Json -Compress
