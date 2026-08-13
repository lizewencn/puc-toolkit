[CmdletBinding()]
param(
    [Parameter(ParameterSetName = 'Custom', Mandatory = $true)][string]$Path,
    [Parameter(ParameterSetName = 'Default', Mandatory = $true)][switch]$UseDefault,
    [Parameter(ParameterSetName = 'Status', Mandatory = $true)][switch]$Status
)
$ErrorActionPreference = 'Stop'
$defaultRoot = Join-Path ([Environment]::GetFolderPath('Desktop')) 'agentSkillLocalConfig\ssh-config'
$settingsPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ssh-config\setting.json'
$templatePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\environments.local.template.json'
if ($Status) {
    $settings = if (Test-Path -LiteralPath $settingsPath) { Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json } else { $null }
    $configured = $null -ne $settings -and -not [string]::IsNullOrWhiteSpace([string]$settings.configRoot)
    [pscustomobject]@{ status = if ($configured) {'configured'} else {'first-use-required'}; configured = $configured; configRoot = if ($configured) {[IO.Path]::GetFullPath([string]$settings.configRoot)} else {$null}; defaultConfigRoot = $defaultRoot; settingsPath = $settingsPath } | ConvertTo-Json -Compress
    return
}
$selectedRoot = if ($UseDefault) { $defaultRoot } else { if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) { throw 'Path must be a non-empty absolute path.' }; [IO.Path]::GetFullPath($Path) }
New-Item -ItemType Directory -Force -Path $selectedRoot | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $settingsPath) | Out-Null
[ordered]@{ configRoot = $selectedRoot } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
$configPath = Join-Path $selectedRoot 'environments.local.json'
if (-not (Test-Path -LiteralPath $configPath)) { Copy-Item -LiteralPath $templatePath -Destination $configPath }
[pscustomobject]@{ status = 'configured'; configRoot = $selectedRoot; settingsPath = $settingsPath; configPath = $configPath; configCreated = Test-Path -LiteralPath $configPath } | ConvertTo-Json -Compress
