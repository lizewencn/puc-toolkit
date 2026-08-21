[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [int]$ParentProcessId = 0,
    [switch]$NoRelaunch
)

$ErrorActionPreference = 'Stop'

function Write-JsonAtomically([string]$Path,$Value) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = "$fullPath.tmp.$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($true))
        [void]([IO.File]::ReadAllText($temporary,[Text.Encoding]::UTF8) | ConvertFrom-Json)
        Move-Item -LiteralPath $temporary -Destination $fullPath -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Write-BytesAtomically([string]$Path,[byte[]]$Bytes) {
    $fullPath=[IO.Path]::GetFullPath($Path)
    $directory=Split-Path -Parent $fullPath
    New-Item -ItemType Directory -Force -Path $directory|Out-Null
    $temporary="$fullPath.tmp.$([guid]::NewGuid().ToString('N'))"
    try{[IO.File]::WriteAllBytes($temporary,$Bytes);Move-Item -LiteralPath $temporary -Destination $fullPath -Force}
    finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}}
}

function Test-Package([string]$Path,[string]$Kind) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Package directory is missing: $Path" }
    if ($Kind -eq 'skill' -and -not (Test-Path -LiteralPath (Join-Path $Path 'SKILL.md') -PathType Leaf)) { throw "Skill package is missing SKILL.md: $Path" }
    if ($Kind -eq 'support' -and -not (Test-Path -LiteralPath (Join-Path $Path 'scripts') -PathType Container)) { throw "Support package is missing scripts: $Path" }
}

function Start-ToolkitGui([string]$Path) {
    if ($NoRelaunch -or [string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $Path + '"') -WindowStyle Hidden | Out-Null
}

$manifestFullPath = [IO.Path]::GetFullPath($ManifestPath)
if (-not (Test-Path -LiteralPath $manifestFullPath -PathType Leaf)) { throw "Update manifest does not exist: $manifestFullPath" }
$manifest = [IO.File]::ReadAllText($manifestFullPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
$packagesRoot = [IO.Path]::GetFullPath([string]$manifest.packagesRoot)
$stageRoot = [IO.Path]::GetFullPath([string]$manifest.stageRoot)
$repositoryRoot = [IO.Path]::GetFullPath([string]$manifest.repositoryRoot)
$backupRoot = Join-Path $stageRoot 'backup'
$resultPath = [IO.Path]::GetFullPath([string]$manifest.resultPath)
$relaunchPath = [IO.Path]::GetFullPath([string]$manifest.relaunchPath)
$statePath = [IO.Path]::GetFullPath([string]$manifest.statePath)
$stateExisted = Test-Path -LiteralPath $statePath -PathType Leaf
$originalStateBytes = if($stateExisted){[IO.File]::ReadAllBytes($statePath)}else{[byte[]]@()}
$stateWritten = $false
$entries = New-Object System.Collections.Generic.List[object]
$failedMessage = ''

try {
    if ($ParentProcessId -gt 0) {
        $parent = Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue
        if ($null -ne $parent) {
            if (-not $parent.WaitForExit(60000)) { throw 'PUC Toolkit did not exit within 60 seconds; update was not applied.' }
            $parent.Dispose()
        }
    }
    if ((Split-Path -Parent $repositoryRoot) -ne $stageRoot) { throw 'Unsafe staged repository path.' }
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

    foreach ($package in @($manifest.packages)) {
        $name = [string]$package.name
        if ($name -notmatch '^[a-z0-9][a-z0-9-]{0,62}$') { throw "Unsafe package name: $name" }
        $source = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $name))
        $target = [IO.Path]::GetFullPath((Join-Path $packagesRoot $name))
        if ((Split-Path -Parent $source) -ne $repositoryRoot -or (Split-Path -Parent $target) -ne $packagesRoot) { throw "Unsafe package path: $name" }
        Test-Package -Path $source -Kind ([string]$package.kind)
        $entry = [pscustomobject]@{Name=$name;Kind=[string]$package.kind;Source=$source;Target=$target;Backup=(Join-Path $backupRoot $name);Existed=(Test-Path -LiteralPath $target);Moved=$false;Created=$false}
        $entries.Add($entry)
        if ($entry.Existed) { Move-Item -LiteralPath $target -Destination $entry.Backup; $entry.Moved=$true }
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        $entry.Created=$true
        foreach ($item in @(Get-ChildItem -LiteralPath $source -Force)) { Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse -Force }
        Test-Package -Path $target -Kind $entry.Kind
    }

    $packageNames = @($manifest.packages | ForEach-Object { [string]$_.name })
    $state = if ($stateExisted) { [IO.File]::ReadAllText($statePath,[Text.Encoding]::UTF8) | ConvertFrom-Json } else { [pscustomobject]@{} }
    $state | Add-Member -NotePropertyName repository -NotePropertyValue ([pscustomobject]@{commitId=[string]$manifest.remoteCommit;updatedAt=[DateTimeOffset]::Now.ToString('o');repository=[string]$manifest.repository;branch=[string]$manifest.branch;packages=$packageNames}) -Force
    Write-JsonAtomically -Path $statePath -Value $state
    $stateWritten=$true
    $results = @($entries | ForEach-Object { [pscustomobject]@{package=$_.Name;status=$(if ($_.Existed) {'updated'} else {'installed'})} })
    Write-JsonAtomically -Path $resultPath -Value ([pscustomobject]@{status='updated';scope='repository';message='所有版本包更新完成。';remoteCommit=[string]$manifest.remoteCommit;packageCount=$entries.Count;packageNames=($packageNames -join ', ');updatedCount=@($entries | Where-Object Existed).Count;installedCount=@($entries | Where-Object {-not $_.Existed}).Count;results=$results;restartRequired=$false})
} catch {
    $failedMessage = $_.Exception.Message
    $items = $entries.ToArray()
    for ($index=$items.Count-1;$index -ge 0;$index--) {
        $entry=$items[$index]
        if ($entry.Created -and (Test-Path -LiteralPath $entry.Target)) { Remove-Item -LiteralPath $entry.Target -Recurse -Force -ErrorAction SilentlyContinue }
        if ($entry.Moved -and (Test-Path -LiteralPath $entry.Backup)) { Move-Item -LiteralPath $entry.Backup -Destination $entry.Target -ErrorAction SilentlyContinue }
    }
    if($stateWritten){if($stateExisted){Write-BytesAtomically -Path $statePath -Bytes $originalStateBytes}else{Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue}}
    Write-JsonAtomically -Path $resultPath -Value ([pscustomobject]@{status='update-failed';scope='repository';message='版本包更新失败，已恢复更新前版本。';error=$failedMessage;remoteCommit=[string]$manifest.remoteCommit;updated=$false})
} finally {
    Start-ToolkitGui $relaunchPath
}

if ($failedMessage) { throw $failedMessage }
