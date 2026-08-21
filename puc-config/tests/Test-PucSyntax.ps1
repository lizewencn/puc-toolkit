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

foreach ($scriptName in @('Invoke-PucAccountPasswordReset.ps1','Invoke-PucAccountPasswordResetBatch.ps1')) {
    $scriptPath = Join-Path $skillRoot "scripts\$scriptName"
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-PropertyValue'
    },$true)
    if ($null -eq $functionAst) { throw "$scriptName does not define Get-PropertyValue." }
    Invoke-Expression $functionAst.Extent.Text
    if ((Get-PropertyValue $null 'missing' 'fallback') -ne 'fallback') {
        throw "$scriptName does not safely return the default for a null response item."
    }
}
Write-Output 'PASS PasswordResetNullResponseHandling'

$repoRoot = Split-Path -Parent $skillRoot
$upgradeScripts = @(Get-ChildItem (Join-Path $repoRoot 'make-android-upgrade-package\scripts') -File | Where-Object Extension -in @('.ps1','.psm1'))
foreach ($file in $upgradeScripts) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) { throw "$($file.Name) has parser errors: $($errors.Message -join '; ')" }
}
Write-Output 'PASS AndroidUpgradeSyntax'

$updaterScripts = @(Get-ChildItem (Join-Path $repoRoot 'puc-toolkit-updater\scripts') -File | Where-Object Extension -in @('.ps1','.psm1'))
foreach ($file in $updaterScripts) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) { throw "$($file.Name) has parser errors: $($errors.Message -join '; ')" }
}
Write-Output 'PASS ToolkitUpdaterSyntax'
