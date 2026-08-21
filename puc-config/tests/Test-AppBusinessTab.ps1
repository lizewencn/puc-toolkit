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
if ($summary.appEnvironmentLoad -ne 'passed') { throw 'Shared environment loading was not exercised.' }
if ($summary.appServerAddressControl -ne 'passed') { throw 'APP server address control was not initialized.' }
if ($summary.appFollowEnvironment -ne 'passed') { throw 'APP follow-environment behavior was not initialized.' }
if ($summary.appManualSelectionPreserved -ne 'passed') { throw 'Manual APP environment selection was not preserved.' }
if ($summary.sharedAddEnvironmentHandler -ne 'passed') { throw 'Environment buttons did not use the shared add handler.' }
if ($summary.configBoundsAfterShow -ne 'passed') { throw 'PUC controls were not checked after showing the form.' }
if ($summary.appLoginControls -ne 'passed') { throw 'APP login controls were not initialized.' }
if ($summary.appLoginLifecycle -ne 'passed') { throw 'APP login lifecycle states were not mapped.' }
if ($summary.appLoginIntermediateStates -ne 'passed') { throw 'APP login intermediate states were not preserved.' }
if ($summary.appLoginMessagePreserved -ne 'passed') { throw 'APP message events did not preserve the online session.' }
if ($summary.appLoginGenerationIsolation -ne 'passed') { throw 'Stale APP login generations were not ignored.' }
if ($summary.appSessionDisplay -ne 'passed') { throw 'APP account and app_puc_id were not displayed.' }
if ($summary.appBridgeCleanup -ne 'passed') { throw 'APP bridge cleanup was not initialized.' }
if ($summary.appBridgeTaskSafety -ne 'passed') { throw 'APP bridge task failures were not guarded.' }
if ($summary.appBatchOfflineDisabled -ne 'passed') { throw 'APP batch action must be disabled while offline.' }
if ($summary.appBatchOnlineEnabled -ne 'passed') { throw 'APP batch action must be enabled only after login success.' }
if ($summary.appBatchLayout -ne 'passed') { throw 'APP batch controls were not placed on the batch row.' }
Write-Output 'PASS AppBusinessTab'
