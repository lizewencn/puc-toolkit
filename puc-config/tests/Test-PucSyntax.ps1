$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem (Join-Path $skillRoot 'scripts') -File | Where-Object Extension -in @('.ps1','.psm1'))
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) { throw "$($file.Name) has parser errors: $($errors.Message -join '; ')" }
    $source = Get-Content -Raw -LiteralPath $file.FullName
    foreach ($forbidden in @('Invoke-RestMethod','Invoke-WebRequest','System.Net.Http.HttpClient','Net.Http.HttpClient','ServerCertificateValidationCallback')) {
        if ($source.Contains($forbidden)) { throw "$($file.Name) contains forbidden Schannel transport '$forbidden'." }
    }
}
Write-Output 'PASS PowerShellSyntax'
Write-Output 'PASS NodeTransportOnly'

$repoRoot = Split-Path -Parent $skillRoot
$upgradeScripts = @(Get-ChildItem (Join-Path $repoRoot 'make-android-upgrade-package\scripts') -File | Where-Object Extension -in @('.ps1','.psm1'))
foreach ($file in $upgradeScripts) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) { throw "$($file.Name) has parser errors: $($errors.Message -join '; ')" }
}
Write-Output 'PASS AndroidUpgradeSyntax'
