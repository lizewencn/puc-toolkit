$ErrorActionPreference = 'Stop'
$AllArguments = @($args)
if ($AllArguments.Count -eq 0) { throw 'Usage: Invoke-PucScript.cmd <script-name.ps1> [arguments...]' }
$ScriptName = [string]$AllArguments[0]
$ScriptArguments = @($AllArguments | Select-Object -Skip 1)
if ([IO.Path]::GetFileName($ScriptName) -cne $ScriptName) { throw 'Script name must not contain a directory path.' }
if ([IO.Path]::GetExtension($ScriptName) -ine '.ps1') { throw 'Script name must end with .ps1.' }
if ($ScriptName -ieq 'Invoke-PucScript.ps1') { throw 'The launcher cannot invoke itself.' }
$path = Join-Path $PSScriptRoot $ScriptName
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Unknown PUC script: $ScriptName" }
& $path @ScriptArguments
exit $LASTEXITCODE
