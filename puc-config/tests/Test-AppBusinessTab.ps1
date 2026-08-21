[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$launcher = Join-Path $PSScriptRoot '..\scripts\PucConfigLauncher.ps1'
$lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -UiSelfTest)
if ($LASTEXITCODE -ne 0) { throw "Launcher UI self-test failed: $($lines -join [Environment]::NewLine)" }

$json = $lines | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1
if ([string]::IsNullOrWhiteSpace($json)) { throw 'Launcher UI self-test did not emit a JSON summary.' }
$summary = $json | ConvertFrom-Json
if ($summary.mainTabs -ne 2) { throw "Expected two main tabs, got '$($summary.mainTabs)'." }
$expectedConfigTab = 'PUC ' + [char]0x914D + [char]0x7F6E
$expectedAppTab = 'APP ' + [char]0x4E1A + [char]0x52A1
if ($summary.configTabText -ne $expectedConfigTab -or $summary.appTabText -ne $expectedAppTab) { throw 'Main tab titles are incorrect.' }
if ($summary.appEnvironmentControl -ne 'passed') { throw 'APP environment control was not initialized.' }
if ($summary.appServerAddressControl -ne 'passed') { throw 'APP server address control was not initialized.' }
if ($summary.appFollowEnvironment -ne 'passed') { throw 'APP follow-environment behavior was not initialized.' }
if ($summary.appBatchOfflineDisabled -ne 'passed') { throw 'APP batch action must be disabled while offline.' }
Write-Output 'PASS AppBusinessTab'
