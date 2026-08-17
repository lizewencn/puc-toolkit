[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Inspect','Preview','Build')][string]$Action,
    [string]$ApkPath,
    [string]$ManifestPath
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$command = Join-Path $repoRoot 'make-android-upgrade-package\scripts\Invoke-AndroidUpgradePackage.ps1'
if (-not (Test-Path -LiteralPath $command -PathType Leaf)) { throw 'Android 升级包制作模块不存在。' }
$arguments = @{Action=$Action}
if (-not [string]::IsNullOrWhiteSpace($ApkPath)) { $arguments.ApkPath=$ApkPath }
if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) { $arguments.ManifestPath=$ManifestPath }
& $command @arguments
exit $LASTEXITCODE
