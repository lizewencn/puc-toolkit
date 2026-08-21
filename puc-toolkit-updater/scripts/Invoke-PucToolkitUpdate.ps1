[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagesRoot,
    [ValidateSet('Check','Stage')][string]$Mode = 'Stage',
    [string]$Repository = 'https://github.com/lizewencn/puc-toolkit.git',
    [string]$Branch = 'main',
    [string]$RepositoryRoot = '',
    [string]$RemoteCommitOverride = '',
    [string]$StatePathOverride = '',
    [string]$StageRootOverride = '',
    [string]$ResultPathOverride = '',
    [string]$RelaunchPath = ''
)

$ErrorActionPreference='Stop'
$resolvedPackagesRoot=[IO.Path]::GetFullPath($PackagesRoot)
$pucModule=Join-Path $resolvedPackagesRoot 'puc-config\scripts\PucConfig.psm1'
if (-not (Test-Path -LiteralPath $pucModule -PathType Leaf)) { throw "PUC transport module is missing: $pucModule" }
Import-Module $pucModule -Force
$repositoryUri=[uri]$Repository
if ($repositoryUri.Host -ne 'github.com' -or $repositoryUri.AbsolutePath -notmatch '^/[^/]+/[^/]+(?:\.git)?/?$') { throw 'Repository must be a GitHub repository URL.' }
$repositoryPath=$repositoryUri.AbsolutePath.Trim('/') -replace '\.git$',''
$headers=@{Accept='application/vnd.github+json';'User-Agent'='puc-toolkit-updater'}

function Invoke-GitHubGet([uri]$Uri) {
    $response=Invoke-PucHttpRequest -Method GET -Uri $Uri -Headers $headers -TimeoutSec 60
    if($response.StatusCode -ne 200){throw "GitHub request returned HTTP $($response.StatusCode)."}
    $response
}
function Get-RemoteCommit {
    $remoteRef="refs/heads/$Branch"
    $git=Get-Command git.exe -ErrorAction SilentlyContinue
    $gitFailure=''
    if($null-ne$git){
        $previousPrompt=$env:GIT_TERMINAL_PROMPT
        $previousErrorAction=$ErrorActionPreference
        try{
            $env:GIT_TERMINAL_PROMPT='0'
            $ErrorActionPreference='Continue'
            $gitOutput=@(& $git.Source -c http.sslBackend=openssl ls-remote --exit-code $Repository $remoteRef 2>&1)
            $gitExitCode=$LASTEXITCODE
        }finally{
            $ErrorActionPreference=$previousErrorAction
            if($null-eq$previousPrompt){Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue}else{$env:GIT_TERMINAL_PROMPT=$previousPrompt}
        }
        if($gitExitCode-eq0){
            $match=@($gitOutput|ForEach-Object{[regex]::Match([string]$_,"^([0-9a-fA-F]{40,64})\s+$([regex]::Escape($remoteRef))$")}|Where-Object Success)
            if($match.Count-eq1){return $match[0].Groups[1].Value.ToLowerInvariant()}
            $gitFailure='Git returned an unexpected remote-reference response.'
        }else{$gitFailure=(@($gitOutput)-join[Environment]::NewLine).Trim()}
    }
    try{
        $response=Invoke-GitHubGet ([uri]("https://api.github.com/repos/$repositoryPath/commits?sha=$Branch&per_page=1"))
        return [string]@(([Text.Encoding]::UTF8.GetString($response.BodyBytes)|ConvertFrom-Json))[0].sha
    }catch{
        if($_.Exception.Message-match'403.*rate limit'){
            $hint=if($null-eq$git){'本机未检测到 Git，无法改用远端引用查询。'}else{"Git 远端引用查询也失败：$gitFailure"}
            throw "GitHub API 查询频率已达上限。$hint"
        }
        if($gitFailure){throw "无法查询远端 commit。Git：$gitFailure；GitHub API：$($_.Exception.Message)"}
        throw
    }
}
function Get-Packages([string]$Root) {
    @((Get-ChildItem -LiteralPath $Root -Directory -Force | Sort-Object Name) | ForEach-Object {
        if($_.Name -notmatch '^[a-z0-9][a-z0-9-]{0,62}$'){return}
        $hasSkill=Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') -PathType Leaf
        $hasScripts=Test-Path -LiteralPath (Join-Path $_.FullName 'scripts') -PathType Container
        if($hasSkill -or $hasScripts){[pscustomobject]@{name=$_.Name;kind=$(if($hasSkill){'skill'}else{'support'});source=$_.FullName}}
    })
}

$statePath=if($StatePathOverride){[IO.Path]::GetFullPath($StatePathOverride)}else{Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'puc-config\update-state.json'}
$state=if(Test-Path -LiteralPath $statePath -PathType Leaf){try{[IO.File]::ReadAllText($statePath,[Text.Encoding]::UTF8)|ConvertFrom-Json}catch{[pscustomobject]@{}}}else{[pscustomobject]@{}}
$localCommit=if($null-ne$state.repository){[string]$state.repository.commitId}else{''}
if($RemoteCommitOverride){if($RemoteCommitOverride-notmatch'^[0-9a-fA-F]{7,64}$'){throw 'Invalid commit ID.'};$remoteCommit=$RemoteCommitOverride}else{$remoteCommit=Get-RemoteCommit}
$isLatest=[string]::Equals($localCommit,$remoteCommit,[StringComparison]::OrdinalIgnoreCase)
if($Mode-eq'Check'-or$isLatest){[pscustomobject]@{status=$(if($isLatest){'latest'}else{'update-available'});scope='repository';localCommit=$localCommit;remoteCommit=$remoteCommit;updated=$false}|ConvertTo-Json -Compress;return}

$stageRoot=if($StageRootOverride){[IO.Path]::GetFullPath($StageRootOverride)}else{Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('puc-config\updates\'+[guid]::NewGuid().ToString('N'))}
$stageRepository=Join-Path $stageRoot 'repository'
New-Item -ItemType Directory -Force -Path $stageRepository|Out-Null
if($RepositoryRoot){$sourceRoot=[IO.Path]::GetFullPath($RepositoryRoot)}else{$zip=Join-Path $stageRoot 'source.zip';$extract=Join-Path $stageRoot 'extract';New-Item -ItemType Directory -Force -Path $extract|Out-Null;$archive=Invoke-GitHubGet ([uri]("https://codeload.github.com/$repositoryPath/zip/$remoteCommit"));[IO.File]::WriteAllBytes($zip,$archive.BodyBytes);Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force;$roots=@(Get-ChildItem -LiteralPath $extract -Directory);if($roots.Count-ne1){throw 'Unexpected archive layout.'};$sourceRoot=$roots[0].FullName}
$packages=@(Get-Packages $sourceRoot)
$requiredPackages=@('puc-config','puc-toolkit-updater')
$invalidPackages=@($requiredPackages|Where-Object{@($packages|Where-Object name -eq $_).Count-ne1})
if($packages.Count-eq0-or$invalidPackages.Count-gt0){
    $details=if($invalidPackages.Count-gt0){$invalidPackages-join', '}else{'未发现任何可安装包'}
    throw "远端仓库的版本包集合不完整：$details。为避免破坏后续更新能力，本次未修改本地文件；请先将缺失目录提交并推送到 $Branch 分支。"
}
foreach($package in $packages){$target=Join-Path $stageRepository $package.name;New-Item -ItemType Directory -Force -Path $target|Out-Null;foreach($item in @(Get-ChildItem -LiteralPath $package.source -Force)){Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse -Force}}
$workerSource=Join-Path $PSScriptRoot 'PucToolkitUpdateWorker.ps1';$workerPath=Join-Path $stageRoot 'PucToolkitUpdateWorker.ps1';Copy-Item -LiteralPath $workerSource -Destination $workerPath -Force
$resultPath=if($ResultPathOverride){[IO.Path]::GetFullPath($ResultPathOverride)}else{Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'puc-config\update-result.json'}
if(-not$RelaunchPath){$RelaunchPath=Join-Path $resolvedPackagesRoot 'puc-config\scripts\Start-PucConfigTool.vbs'}
$manifestPath=Join-Path $stageRoot 'manifest.json'
Write-PucJson -Path $manifestPath -Value ([ordered]@{schemaVersion=1;stageRoot=$stageRoot;repositoryRoot=$stageRepository;packagesRoot=$resolvedPackagesRoot;statePath=$statePath;resultPath=$resultPath;relaunchPath=[IO.Path]::GetFullPath($RelaunchPath);repository=$Repository;branch=$Branch;localCommit=$localCommit;remoteCommit=$remoteCommit;packages=@($packages|ForEach-Object{[ordered]@{name=$_.name;kind=$_.kind}})})
[pscustomobject]@{status='staged';scope='repository';message='版本包已下载并校验，GUI 退出后将自动安装。';localCommit=$localCommit;remoteCommit=$remoteCommit;packageCount=$packages.Count;packageNames=(@($packages.name)-join', ');manifestPath=$manifestPath;workerPath=$workerPath;updated=$false;restartRequired=$true}|ConvertTo-Json -Depth 10 -Compress
