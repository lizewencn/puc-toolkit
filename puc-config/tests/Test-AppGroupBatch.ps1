[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$launcher = Join-Path $PSScriptRoot '..\scripts\PucConfigLauncher.ps1'
$lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -UiSelfTest)
if ($LASTEXITCODE -ne 0) { throw "Launcher UI self-test failed: $($lines -join [Environment]::NewLine)" }

$json = $lines | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1
if ([string]::IsNullOrWhiteSpace($json)) { throw 'Launcher UI self-test did not emit a JSON summary.' }
$summary = $json | ConvertFrom-Json

foreach ($check in @(
    'appBatchControls',
    'appBatchMemberValidation',
    'appBatchCountValidation',
    'appBatchCommand',
    'appBatchStartPath',
    'appBatchGenerationIsolation',
    'appBatchProgress',
    'appBatchSummary',
    'appBatchDisconnectRecovery',
    'appBatchResultIsolation',
    'appBatchFlexibleLayout'
)) {
    if ([string]$summary.$check -ne 'passed') { throw "APP group batch check failed: $check" }
}

Write-Output 'PASS AppGroupBatch'
