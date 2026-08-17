[CmdletBinding()]
param(
    [string]$ShortcutName = 'PUC Toolkit'
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ShortcutName)) {
    throw 'ShortcutName cannot be empty.'
}

$invalidNameChars = [System.IO.Path]::GetInvalidFileNameChars()
if ($ShortcutName.IndexOfAny($invalidNameChars) -ge 0 -or
    [System.IO.Path]::GetFileName($ShortcutName) -ne $ShortcutName) {
    throw 'ShortcutName must be a file name without path characters.'
}

if (-not $ShortcutName.EndsWith('.lnk', [System.StringComparison]::OrdinalIgnoreCase)) {
    $ShortcutName += '.lnk'
}

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillDirectory = Split-Path -Parent $scriptDirectory
$launcherPath = Join-Path $scriptDirectory 'Start-PucConfigTool.vbs'
$desktopDirectory = [System.Environment]::GetFolderPath('DesktopDirectory')
$windowsDirectory = [System.Environment]::GetFolderPath('Windows')
$wscriptPath = Join-Path $windowsDirectory 'System32\wscript.exe'
$iconPath = Join-Path $skillDirectory 'assets\puc-config.ico'
$shortcutPath = Join-Path $desktopDirectory $ShortcutName
$legacyShortcutPath = Join-Path $desktopDirectory 'PUC Configuration Tool.lnk'

foreach ($requiredPath in @($launcherPath, $wscriptPath, $iconPath, $desktopDirectory)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required path does not exist: $requiredPath"
    }
}

if ($ShortcutName.Equals('PUC Toolkit.lnk', [System.StringComparison]::OrdinalIgnoreCase) -and
    -not (Test-Path -LiteralPath $shortcutPath) -and
    (Test-Path -LiteralPath $legacyShortcutPath -PathType Leaf)) {
    Move-Item -LiteralPath $legacyShortcutPath -Destination $shortcutPath
}

$shell = $null
$shortcut = $null
try {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $wscriptPath
    $shortcut.Arguments = '"' + $launcherPath + '"'
    $shortcut.WorkingDirectory = $scriptDirectory
    $shortcut.IconLocation = "$iconPath,0"
    $shortcut.Description = 'PUC Toolkit'
    $shortcut.Save()
}
finally {
    if ($null -ne $shortcut) {
        [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
    }
    if ($null -ne $shell) {
        [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    }
}

[pscustomobject]@{
    shortcutPath = $shortcutPath
    targetPath = $wscriptPath
    launcherPath = $launcherPath
    updated = $true
} | ConvertTo-Json -Depth 2
