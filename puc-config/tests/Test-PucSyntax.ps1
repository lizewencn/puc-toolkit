$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$files = @(
    'scripts\PucConfig.psm1',
    'scripts\Invoke-PucAuth.ps1',
    'scripts\PucLoginWorker.ps1',
    'scripts\Invoke-PucAccountPasswordReset.ps1',
    'scripts\Invoke-PucAccountPasswordResetBatch.ps1',
    'scripts\Invoke-PucAccounts.ps1',
    'scripts\Invoke-PucFirstLoginPasswordCheck.ps1',
    'scripts\Test-PucEnvironment.ps1'
    'scripts\Invoke-PucScript.ps1'
)
foreach ($relativePath in $files) {
    $tokens = $null
    $errors = $null
    $path = Join-Path $skillRoot $relativePath
    [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) { throw "$relativePath has parser errors: $($errors.Message -join '; ')" }
}
Write-Output 'PASS PowerShellSyntax'
