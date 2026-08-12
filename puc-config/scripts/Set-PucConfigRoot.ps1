[CmdletBinding()]
param(
    [Parameter(ParameterSetName = 'Custom', Mandatory = $true)]
    [string]$Path,

    [Parameter(ParameterSetName = 'Default', Mandatory = $true)]
    [switch]$UseDefault,

    [Parameter(ParameterSetName = 'Status', Mandatory = $true)]
    [switch]$Status
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force

$settingsPath = Get-PucSettingsPath
$defaultRoot = Get-PucDefaultConfigRoot

if ($Status) {
    $settings = Read-PucJson -Path $settingsPath -Default $null
    $configured = $null -ne $settings -and -not [string]::IsNullOrWhiteSpace([string]$settings.configRoot)
    [pscustomobject]@{
        status = if ($configured) { 'configured' } else { 'first-use-required' }
        configured = $configured
        configRoot = if ($configured) { [IO.Path]::GetFullPath([string]$settings.configRoot) } else { $null }
        defaultConfigRoot = $defaultRoot
        settingsPath = $settingsPath
    } | ConvertTo-Json -Compress
    return
}

if ($UseDefault) {
    $selectedRoot = $defaultRoot
} else {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Path must not be empty.' }
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'Path must be an absolute path.' }
    $selectedRoot = [IO.Path]::GetFullPath($Path)
}

New-Item -ItemType Directory -Force -Path $selectedRoot | Out-Null
Write-PucJson -Path $settingsPath -Value ([ordered]@{
    configRoot = $selectedRoot
})

[pscustomobject]@{
    status = 'configured'
    configRoot = $selectedRoot
    settingsPath = $settingsPath
    configExists = Test-Path -LiteralPath (Join-Path $selectedRoot 'config.json')
} | ConvertTo-Json -Compress
