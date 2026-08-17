$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-LowerMd5([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm MD5).Hash.ToLowerInvariant()
}

function ConvertTo-SafePackageSegment([string]$Value) {
    $safe = [regex]::Replace($Value, '[<>:"/\\|?*\x00-\x1F]', '_').TrimEnd([char[]]@('.', ' '))
    if ([string]::IsNullOrWhiteSpace($safe)) { throw '版本值不能生成有效的文件名。' }
    $safe
}

function Get-AndroidUpgradePackageName([string]$VersionName, [long]$VersionCode) {
    '升级包_{0}_{1}.zip' -f (ConvertTo-SafePackageSegment $VersionName), $VersionCode
}

function Invoke-AaptBadging([string]$AaptPath, [string]$ApkPath) {
    $start = New-Object Diagnostics.ProcessStartInfo
    if ([IO.Path]::GetExtension($AaptPath) -ieq '.cmd') {
        $start.FileName = $env:ComSpec
        $start.Arguments = '/d /s /c ""{0}" dump badging "{1}""' -f $AaptPath,$ApkPath
    } else {
        $start.FileName = $AaptPath
        $start.Arguments = 'dump badging "{0}"' -f $ApkPath
    }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) { throw '无法启动内置 aapt。' }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "aapt 解析 APK 失败（退出码 $($process.ExitCode)）：$($stderr.Trim())" }
    $stdout
}

function Get-AndroidApkInfo {
    param([Parameter(Mandatory)][string]$ApkPath,[Parameter(Mandatory)][string]$AaptPath)
    if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) { throw "APK 文件不存在：$ApkPath" }
    if ([IO.Path]::GetExtension($ApkPath) -ine '.apk') { throw '请选择扩展名为 .apk 的文件。' }
    if (-not (Test-Path -LiteralPath $AaptPath -PathType Leaf)) { throw "内置 aapt 不存在：$AaptPath" }
    $resolvedApk = (Resolve-Path -LiteralPath $ApkPath).Path
    $resolvedAapt = (Resolve-Path -LiteralPath $AaptPath).Path
    $aaptApkPath = $resolvedApk
    $aaptTempDirectory = $null
    try {
        if ($resolvedApk -match '[^\x00-\x7F]') {
            $aaptTempDirectory = Join-Path ([IO.Path]::GetTempPath()) ('puc-aapt-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $aaptTempDirectory | Out-Null
            $aaptApkPath = Join-Path $aaptTempDirectory 'app.apk'
            Copy-Item -LiteralPath $resolvedApk -Destination $aaptApkPath
        }
        $output = Invoke-AaptBadging -AaptPath $resolvedAapt -ApkPath $aaptApkPath
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($aaptTempDirectory)) {
            Remove-Item -LiteralPath $aaptTempDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $match = [regex]::Match($output,"(?m)^package:\s+name='(?<package>[^']+)'\s+versionCode='(?<code>\d+)'\s+versionName='(?<name>[^']+)'(?:\s+.*)?$")
    if (-not $match.Success) { throw 'aapt 输出缺少有效的包名、versionCode 或 versionName。' }
    $code = 0L
    if (-not [long]::TryParse($match.Groups['code'].Value,[ref]$code)) { throw 'versionCode 超出支持范围。' }
    $file = Get-Item -LiteralPath $resolvedApk
    [pscustomobject]@{
        PackageName=$match.Groups['package'].Value
        VersionCode=$code
        VersionName=$match.Groups['name'].Value
        FileName=$file.Name
        Path=$file.FullName
        Size=[long]$file.Length
        Md5=Get-LowerMd5 $file.FullName
    }
}

function Get-ExactZipEntries([string]$Path) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try { @($zip.Entries | ForEach-Object FullName | Sort-Object) } finally { $zip.Dispose() }
}

function Assert-AndroidUpgradePackage {
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)]$ExpectedApkInfo,
        [Parameter(Mandatory)][string]$ExpectedDescription,
        [Parameter(Mandatory)][bool]$ExpectedForce
    )
    if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) { throw '待校验升级包不存在。' }
    if ((Get-ExactZipEntries $PackagePath) -join ',' -ne 'MD5.txt,upgrade.zip') { throw '外层升级包文件结构不正确。' }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('puc-upgrade-validate-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($PackagePath,$temp)
        $inner = Join-Path $temp 'upgrade.zip'
        $expectedInner = @($ExpectedApkInfo.FileName,'version.json') | Sort-Object
        if ((Get-ExactZipEntries $inner) -join ',' -ne ($expectedInner -join ',')) { throw 'upgrade.zip 文件结构不正确。' }
        $innerExtract = Join-Path $temp 'inner'
        [IO.Compression.ZipFile]::ExtractToDirectory($inner,$innerExtract)
        $archivedApk = Join-Path $innerExtract $ExpectedApkInfo.FileName
        $document = Get-Content -Raw -Encoding UTF8 (Join-Path $innerExtract 'version.json') | ConvertFrom-Json
        if ([long]$document.version_code -ne [long]$ExpectedApkInfo.VersionCode -or
            [string]$document.version_name -ne [string]$ExpectedApkInfo.VersionName -or
            [string]$document.md5 -ne [string]$ExpectedApkInfo.Md5 -or
            [bool]$document.force -ne $ExpectedForce -or
            [string]$document.description -ne $ExpectedDescription.Trim() -or
            [string]$document.terminal -ne 'android' -or
            [long]$document.apksize -ne [long]$ExpectedApkInfo.Size) { throw 'version.json 内容与预期不一致。' }
        if ((Get-LowerMd5 $archivedApk) -ne [string]$ExpectedApkInfo.Md5 -or (Get-Item $archivedApk).Length -ne [long]$ExpectedApkInfo.Size) { throw '归档内 APK 校验失败。' }
        $recordedMd5 = (Get-Content -Raw -Encoding ASCII (Join-Path $temp 'MD5.txt')).Trim()
        $innerMd5 = Get-LowerMd5 $inner
        if ($recordedMd5 -notmatch '^[a-f0-9]{32}$' -or $recordedMd5 -ne $innerMd5) { throw 'upgrade.zip MD5 校验失败。' }
        [pscustomobject]@{Valid=$true;UpgradeZipMd5=$innerMd5;OutputSize=[long](Get-Item $PackagePath).Length}
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-AndroidUpgradePackage {
    param(
        [Parameter(Mandatory)]$ApkInfo,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][bool]$Force,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    if ([string]::IsNullOrWhiteSpace($Description)) { throw '升级说明不能为空。' }
    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) { throw '输出目录不存在。' }
    $name = Get-AndroidUpgradePackageName -VersionName $ApkInfo.VersionName -VersionCode $ApkInfo.VersionCode
    $finalPath = Join-Path (Resolve-Path -LiteralPath $OutputDirectory).Path $name
    if (Test-Path -LiteralPath $finalPath) { throw "目标升级包已存在：$finalPath" }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('puc-upgrade-build-' + [guid]::NewGuid().ToString('N'))
    $pending = Join-Path (Split-Path -Parent $finalPath) ('.' + [guid]::NewGuid().ToString('N') + '.tmp.zip')
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $innerDir = Join-Path $work 'inner'
        New-Item -ItemType Directory -Path $innerDir | Out-Null
        Copy-Item -LiteralPath $ApkInfo.Path -Destination (Join-Path $innerDir $ApkInfo.FileName)
        $version = [ordered]@{version_code=[long]$ApkInfo.VersionCode;version_name=[string]$ApkInfo.VersionName;md5=[string]$ApkInfo.Md5;force=$Force;description=$Description.Trim();terminal='android';apksize=[long]$ApkInfo.Size}
        [IO.File]::WriteAllText((Join-Path $innerDir 'version.json'),($version | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        $innerZip = Join-Path $work 'upgrade.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($innerDir,$innerZip,[IO.Compression.CompressionLevel]::Optimal,$false)
        [IO.File]::WriteAllText((Join-Path $work 'MD5.txt'),((Get-LowerMd5 $innerZip) + "`n"),[Text.ASCIIEncoding]::new())
        $outerDir = Join-Path $work 'outer'
        New-Item -ItemType Directory -Path $outerDir | Out-Null
        Copy-Item $innerZip (Join-Path $outerDir 'upgrade.zip')
        Copy-Item (Join-Path $work 'MD5.txt') (Join-Path $outerDir 'MD5.txt')
        [IO.Compression.ZipFile]::CreateFromDirectory($outerDir,$pending,[IO.Compression.CompressionLevel]::Optimal,$false)
        [void](Assert-AndroidUpgradePackage -PackagePath $pending -ExpectedApkInfo $ApkInfo -ExpectedDescription $Description -ExpectedForce:$Force)
        Move-Item -LiteralPath $pending -Destination $finalPath
        $finalPath
    } finally {
        Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Get-AndroidApkInfo,Get-AndroidUpgradePackageName,New-AndroidUpgradePackage,Assert-AndroidUpgradePackage
