[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$failures = [Collections.Generic.List[string]]::new()
$files = Get-ChildItem -LiteralPath $root -File -Recurse -Force | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }

foreach ($file in $files) {
    $relative = $file.FullName.Substring($root.Length).TrimStart('\','/')
    if ($file.Name -in @('manager_config.json','module_config.json','login_config.json')) { $failures.Add("Local configuration: $relative") }
    if ($file.Extension -ieq '.har') { $failures.Add("HAR capture: $relative") }
    if ($relative -match '(^|[\\/])reports([\\/]|$)') { $failures.Add("Report file: $relative") }
    if ($file.Name -match '(?i)captcha|\.env$|^\.env\.') { $failures.Add("Sensitive filename: $relative") }
    if ($file.Extension -notin @('.ps1','.psm1','.cmd','.json','.md','.yaml','.yml','.gitignore')) { continue }
    $content = Get-Content -Raw -LiteralPath $file.FullName
    if ($content -match '(?<!\d)(?:10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.)\d{1,3}\.\d{1,3}(?!\d)') {
        $failures.Add("Private IPv4 address: $relative")
    }
    $contentWithoutTestCipher = $content.Replace('00112233445566778899aabbccddeeff','')
    if ($contentWithoutTestCipher -match '(?i)(?<![0-9a-f])[0-9a-f]{32}(?![0-9a-f])') {
        $failures.Add("Possible 32-hex credential: $relative")
    }
}

if ($failures.Count -gt 0) {
    $failures | Sort-Object -Unique | ForEach-Object { Write-Error $_ }
    throw 'Repository safety check failed.'
}
Write-Host 'Repository safety check passed.'
