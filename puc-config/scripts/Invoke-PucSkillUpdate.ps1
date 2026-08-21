[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SkillPath,
    [ValidateSet('Check','Apply')][string]$Mode = 'Apply',
    [string]$Repository = 'https://github.com/lizewencn/puc-toolkit.git',
    [string]$Branch = 'main',
    [string]$RepositoryRoot = '',
    [string]$RemoteCommitOverride = '',
    [string]$StatePathOverride = '',
    [string]$StageRootOverride = '',
    [string]$ResultPathOverride = ''
)

$ErrorActionPreference='Stop'
$resolvedSkillPath=[IO.Path]::GetFullPath($SkillPath)
if(-not(Test-Path -LiteralPath $resolvedSkillPath -PathType Container)){throw "Skill directory does not exist: $resolvedSkillPath"}
$packagesRoot=Split-Path -Parent $resolvedSkillPath
$updater=Join-Path $packagesRoot 'puc-toolkit-updater\scripts\Invoke-PucToolkitUpdate.ps1'
if(-not(Test-Path -LiteralPath $updater -PathType Leaf)){throw "独立更新组件未安装：$updater"}
$arguments=@{PackagesRoot=$packagesRoot;Mode=$(if($Mode-eq'Check'){'Check'}else{'Stage'});Repository=$Repository;Branch=$Branch}
if($RepositoryRoot){$arguments.RepositoryRoot=$RepositoryRoot}
if($RemoteCommitOverride){$arguments.RemoteCommitOverride=$RemoteCommitOverride}
if($StatePathOverride){$arguments.StatePathOverride=$StatePathOverride}
if($StageRootOverride){$arguments.StageRootOverride=$StageRootOverride}
if($ResultPathOverride){$arguments.ResultPathOverride=$ResultPathOverride}
& $updater @arguments
