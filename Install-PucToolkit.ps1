[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $HOME '.codex' } else { $env:CODEX_HOME }
$skillsRoot = Join-Path $codexHome 'skills'
New-Item -ItemType Directory -Force -Path $skillsRoot | Out-Null

$skills = @('puc-config-manager','puc-batch-create-accounts','puc-batch-create-personnel')
foreach ($name in $skills) {
    $source = Join-Path $repoRoot $name
    $destination = Join-Path $skillsRoot $name
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Get-ChildItem -LiteralPath $source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $destination -Recurse -Force
    }
}

$localConfigs = @(
    @{ Example='puc-config-manager\manager_config.example.json'; Local='puc-config-manager\manager_config.json' },
    @{ Example='puc-batch-create-accounts\module_config.example.json'; Local='puc-batch-create-accounts\module_config.json' },
    @{ Example='puc-batch-create-personnel\module_config.example.json'; Local='puc-batch-create-personnel\module_config.json' }
)
foreach ($item in $localConfigs) {
    $destination = Join-Path $skillsRoot $item.Local
    if (-not (Test-Path -LiteralPath $destination)) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $item.Example) -Destination $destination
        Write-Host "Created local configuration: $destination"
    } else {
        Write-Host "Preserved existing local configuration: $destination"
    }
}

Write-Host "Installed PUC toolkit skills under: $skillsRoot"
Write-Host 'Edit the three local JSON configuration files before running PucConfigManager.cmd.'
