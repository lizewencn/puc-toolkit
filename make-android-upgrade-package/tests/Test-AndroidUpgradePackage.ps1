$ErrorActionPreference = 'Stop'

function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -ne $Expected) { throw "$Name expected '$Expected', got '$Actual'." }
    Write-Output "PASS $Name"
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Name) {
    try { & $Action; throw "$Name did not throw." } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "$Name wrong error: $($_.Exception.Message)" }
    }
    Write-Output "PASS $Name"
}

function Get-ZipEntryNames([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try { @($zip.Entries | ForEach-Object FullName | Sort-Object) } finally { $zip.Dispose() }
}

$root = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $root 'scripts\AndroidUpgradePackage.psm1'
$fakeAapt = Join-Path $PSScriptRoot 'fixtures\fake-aapt.cmd'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('puc-upgrade-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $apkPath = Join-Path $testRoot 'puc.apk'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fixtureDir = Join-Path $testRoot 'fixture'
    New-Item -ItemType Directory -Path $fixtureDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixtureDir 'AndroidManifest.xml'),'<manifest package="com.smartone.puc"/>',[Text.UTF8Encoding]::new($false))
    [IO.Compression.ZipFile]::CreateFromDirectory($fixtureDir,$apkPath)

    Import-Module $modulePath -Force
    $info = Get-AndroidApkInfo -ApkPath $apkPath -AaptPath $fakeAapt
    Assert-Equal $info.PackageName 'com.smartone.puc' 'package name'
    Assert-Equal $info.VersionCode 4300016 'version code'
    Assert-Equal $info.VersionName '4.3.00.016' 'version name'
    if ($info.Md5 -notmatch '^[a-f0-9]{32}$') { throw 'APK MD5 format invalid.' }
    Write-Output 'PASS APK MD5'

    Assert-Equal (Get-AndroidUpgradePackageName -VersionName '4.3/00:016' -VersionCode 4300016) '升级包_4.3_00_016_4300016.zip' 'safe package name'
    Assert-Throws { Get-AndroidApkInfo -ApkPath (Join-Path $testRoot 'missing.apk') -AaptPath $fakeAapt } '不存在' 'missing APK'
    Assert-Throws { Get-AndroidApkInfo -ApkPath $apkPath -AaptPath (Join-Path $testRoot 'missing-aapt.exe') } 'aapt' 'missing aapt'

    $output = Join-Path $testRoot 'output'
    New-Item -ItemType Directory -Path $output | Out-Null
    $package = New-AndroidUpgradePackage -ApkInfo $info -Description '1. 修复登录问题' -Force:$false -OutputDirectory $output
    Assert-Equal (Split-Path $package -Leaf) '升级包_4.3.00.016_4300016.zip' 'final filename'
    Assert-Equal ((Get-ZipEntryNames $package) -join ',') 'MD5.txt,upgrade.zip' 'outer entries'
    $validated = Assert-AndroidUpgradePackage -PackagePath $package -ExpectedApkInfo $info -ExpectedDescription '1. 修复登录问题' -ExpectedForce:$false
    Assert-Equal $validated.Valid $true 'package validation'
    Assert-Throws { New-AndroidUpgradePackage -ApkInfo $info -Description 'again' -Force:$true -OutputDirectory $output } '已存在' 'overwrite protection'

    $command = Join-Path $root 'scripts\Invoke-AndroidUpgradePackage.ps1'
    $inspectJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Action Inspect -ApkPath $apkPath -AaptPath $fakeAapt | Select-Object -Last 1 | ConvertFrom-Json
    Assert-Equal $inspectJson.status 'inspected' 'inspect command status'
    $defaultToolResult = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Action Inspect -ApkPath $apkPath | Select-Object -Last 1 | ConvertFrom-Json
    if ($defaultToolResult.message -match 'Join-Path|empty string') { throw 'default bundled aapt path was not resolved after parameter binding.' }
    Write-Output 'PASS default bundled aapt path'
    $commandOutput = Join-Path $testRoot 'command-output'
    New-Item -ItemType Directory -Path $commandOutput | Out-Null
    $manifestPath = Join-Path $testRoot 'manifest.json'
    $manifest = [ordered]@{apkPath=$apkPath;description='命令测试';force=$true;outputDirectory=$commandOutput;versionCode=$info.VersionCode;versionName=$info.VersionName;apkMd5=$info.Md5;apkSize=$info.Size}
    [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $previewJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Action Preview -ManifestPath $manifestPath -AaptPath $fakeAapt | Select-Object -Last 1 | ConvertFrom-Json
    Assert-Equal $previewJson.status 'previewed' 'preview command status'
    $buildJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Action Build -ManifestPath $manifestPath -AaptPath $fakeAapt | Select-Object -Last 1 | ConvertFrom-Json
    Assert-Equal $buildJson.status 'created' 'build command status'
    Assert-Equal (Test-Path -LiteralPath $buildJson.finalPath -PathType Leaf) $true 'build command output'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
