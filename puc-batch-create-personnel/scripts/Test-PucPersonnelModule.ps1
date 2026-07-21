$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$entry = Join-Path $PSScriptRoot 'PucBatchPersonnel.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("puc-personnel-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
$config = Get-Content -Raw (Join-Path $root 'module_config.example.json') | ConvertFrom-Json
$config | Add-Member -NotePropertyName ipSuffix -NotePropertyValue '168' -Force
$config.startSequence = 0
$config.count = 2
$config | Add-Member -NotePropertyName reportDirectory -NotePropertyValue (Join-Path $tempRoot 'reports') -Force
$configPath = Join-Path $tempRoot 'config.json'
$config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding UTF8
$output = & $entry -ConfigPath $configPath -PlanOnly | Out-String
if ($output -notmatch 'person168000' -or $output -notmatch '16800000' -or $output -notmatch '91680000' -or $output -notmatch '13916800000') { throw 'Sequence 000 generation failed.' }
if ($output -notmatch 'person168001' -or $output -notmatch '16800001' -or $output -notmatch '91680001' -or $output -notmatch '13916800001') { throw 'Sequence 001 generation failed.' }
$adapter = Get-Content -Raw (Join-Path $root 'references\adapter.json') | ConvertFrom-Json
if ($adapter.operations.createPersonnel.bodyTemplate.cmd_name -ne 'conf_add_personnel_info_req') { throw 'Create command mismatch.' }
if ($adapter.operations.createPersonnel.bodyTemplate.personnel_info.device_guid_list.Count -ne 0) { throw 'device_guid_list must be empty.' }
Remove-Item -LiteralPath $tempRoot -Recurse -Force
Write-Host 'PUC personnel module self-test passed.'
