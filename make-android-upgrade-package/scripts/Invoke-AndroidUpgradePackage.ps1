[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Inspect','Preview','Build')][string]$Action,
    [string]$ApkPath,
    [string]$ManifestPath,
    [string]$AaptPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($AaptPath)) { $AaptPath = Join-Path $PSScriptRoot '..\tools\aapt.exe' }
Import-Module (Join-Path $PSScriptRoot 'AndroidUpgradePackage.psm1') -Force

function Write-Result($Value) { $Value | ConvertTo-Json -Compress -Depth 8 }

try {
    if ($Action -eq 'Inspect') {
        if ([string]::IsNullOrWhiteSpace($ApkPath)) { throw 'Inspect 操作必须提供 APK 路径。' }
        $info = Get-AndroidApkInfo -ApkPath $ApkPath -AaptPath $AaptPath
        Write-Result ([ordered]@{status='inspected';packageName=$info.PackageName;versionCode=$info.VersionCode;versionName=$info.VersionName;apkMd5=$info.Md5;apkSize=$info.Size;apkPath=$info.Path;results=@([ordered]@{item=$info.FileName;status='inspected'})})
        exit 0
    }
    if ([string]::IsNullOrWhiteSpace($ManifestPath) -or -not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw '预览或制作操作必须提供有效的清单文件。' }
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $ManifestPath | ConvertFrom-Json
    foreach ($name in @('apkPath','description','versionCode','versionName','apkMd5','apkSize')) {
        if ($null -eq $manifest.$name -or [string]::IsNullOrWhiteSpace([string]$manifest.$name)) { throw "清单缺少 $name。" }
    }
    $info = Get-AndroidApkInfo -ApkPath ([string]$manifest.apkPath) -AaptPath $AaptPath
    if ([long]$manifest.versionCode -ne $info.VersionCode -or [string]$manifest.versionName -ne $info.VersionName -or [string]$manifest.apkMd5 -ne $info.Md5 -or [long]$manifest.apkSize -ne $info.Size) { throw 'APK 在检查后发生变化，请重新选择。' }
    $finalName = Get-AndroidUpgradePackageName -VersionName $info.VersionName -VersionCode $info.VersionCode
    $outputDirectory = Split-Path -Parent $info.Path
    if ($Action -eq 'Preview') {
        Write-Result ([ordered]@{status='previewed';packageName=$info.PackageName;versionCode=$info.VersionCode;versionName=$info.VersionName;apkMd5=$info.Md5;apkSize=$info.Size;description=[string]$manifest.description;force=[bool]$manifest.force;outputDirectory=$outputDirectory;finalName=$finalName;results=@([ordered]@{item=$info.FileName;status='ready'})})
        exit 0
    }
    $finalPath = New-AndroidUpgradePackage -ApkInfo $info -Description ([string]$manifest.description) -Force:([bool]$manifest.force) -OutputDirectory $outputDirectory
    $validation = Assert-AndroidUpgradePackage -PackagePath $finalPath -ExpectedApkInfo $info -ExpectedDescription ([string]$manifest.description) -ExpectedForce:([bool]$manifest.force)
    Write-Result ([ordered]@{status='created';finalPath=$finalPath;finalName=(Split-Path $finalPath -Leaf);packageName=$info.PackageName;versionCode=$info.VersionCode;versionName=$info.VersionName;apkMd5=$info.Md5;upgradeZipMd5=$validation.UpgradeZipMd5;outputSize=$validation.OutputSize;results=@([ordered]@{item=(Split-Path $finalPath -Leaf);status='build-complete';path=$finalPath})})
    exit 0
} catch {
    Write-Result ([ordered]@{status='failed';message=$_.Exception.Message;results=@([ordered]@{item='upgrade-package';status='failed';reason=$_.Exception.Message})})
    exit 1
}
