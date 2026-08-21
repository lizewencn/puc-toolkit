$ErrorActionPreference='Stop'
$skillRoot=Split-Path -Parent $PSScriptRoot
$workspaceWorkRoot=Split-Path -Parent $skillRoot
$compatibilityUpdater=Join-Path $skillRoot 'scripts\Invoke-PucSkillUpdate.ps1'
$updaterSource=Join-Path $workspaceWorkRoot 'puc-toolkit-updater'
$tempRoot=Join-Path $workspaceWorkRoot ('.puc-update-test-'+[guid]::NewGuid().ToString('N'))

function Write-TestFile([string]$Path,[string]$Value){New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)|Out-Null;[IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))}
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
function Copy-Directory([string]$Source,[string]$Target){New-Item -ItemType Directory -Force -Path $Target|Out-Null;foreach($item in @(Get-ChildItem -LiteralPath $Source -Force)){Copy-Item -LiteralPath $item.FullName -Destination $Target -Recurse -Force}}

function New-TestInstallation([string]$Root){
    Write-TestFile (Join-Path $Root 'puc-config\SKILL.md') 'old-puc'
    Write-TestFile (Join-Path $Root 'puc-config\stale.txt') 'remove-me'
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'puc-config\scripts')|Out-Null
    Copy-Item -LiteralPath (Join-Path $skillRoot 'scripts\PucConfig.psm1') -Destination (Join-Path $Root 'puc-config\scripts\PucConfig.psm1') -Force
    Write-TestFile (Join-Path $Root 'get-business-log\SKILL.md') 'old-log'
    Copy-Directory $updaterSource (Join-Path $Root 'puc-toolkit-updater')
}

function New-TestRepository([string]$Root){
    foreach($name in @('puc-config','get-business-log','refresh-puc-language','replace-env-dist')){
        Write-TestFile (Join-Path $Root "$name\SKILL.md") "---`nname: $name`ndescription: test`n---"
        Write-TestFile (Join-Path $Root "$name\scripts\marker.txt") "new-$name"
    }
    Copy-Item -LiteralPath (Join-Path $skillRoot 'scripts\PucConfig.psm1') -Destination (Join-Path $Root 'puc-config\scripts\PucConfig.psm1') -Force
    Write-TestFile (Join-Path $Root 'make-android-upgrade-package\scripts\marker.txt') 'new-android'
    Copy-Directory $updaterSource (Join-Path $Root 'puc-toolkit-updater')
    Write-TestFile (Join-Path $Root 'docs\guide.md') 'not-installable'
}

function Stage-Update([string]$Installed,[string]$Repository,[string]$Commit,[string]$State,[string]$Stage,[string]$Result){
    $output=& $compatibilityUpdater -SkillPath (Join-Path $Installed 'puc-config') -Mode Apply -RepositoryRoot $Repository -RemoteCommitOverride $Commit -StatePathOverride $State -StageRootOverride $Stage -ResultPathOverride $Result
    @($output)[-1]|ConvertFrom-Json
}

try{
    $repositoryRoot=Join-Path $tempRoot 'repository';New-TestRepository $repositoryRoot
    $installedRoot=Join-Path $tempRoot 'installed';New-TestInstallation $installedRoot
    $statePath=Join-Path $tempRoot 'state\update-state.json';$resultPath=Join-Path $tempRoot 'state\update-result.json';$stageRoot=Join-Path $tempRoot 'stage';$commitA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    Write-TestFile $statePath ('{"skills":{"puc-config":{"commitId":"'+$commitA+'"}}}')

    $incompleteRepository=Join-Path $tempRoot 'incomplete-repository'
    Write-TestFile (Join-Path $incompleteRepository 'puc-config\SKILL.md') 'puc-config-only'
    $incompleteError=''
    try{
        [void](Stage-Update $installedRoot $incompleteRepository 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' $statePath (Join-Path $tempRoot 'incomplete-stage') (Join-Path $tempRoot 'incomplete-result.json'))
    }catch{$incompleteError=$_.Exception.Message}
    Assert-True ($incompleteError-match'puc-toolkit-updater') 'Incomplete repository did not report the missing updater package.'

    $staged=Stage-Update $installedRoot $repositoryRoot $commitA $statePath $stageRoot $resultPath
    Assert-True ($staged.status-eq'staged'-and[int]$staged.packageCount-eq6) 'Update was not staged with all packages.'
    Assert-True ((Get-Content -Raw (Join-Path $installedRoot 'puc-config\SKILL.md'))-eq'old-puc') 'Staging modified the installed package.'
    Assert-True (Test-Path -LiteralPath $staged.workerPath -PathType Leaf) 'Staged worker is missing.'
    $workerArguments='-NoProfile -ExecutionPolicy Bypass -File "'+$staged.workerPath+'" -ManifestPath "'+$staged.manifestPath+'" -NoRelaunch'
    $workerDirectory=Split-Path -Parent $staged.workerPath
    Assert-True (-not $workerDirectory.StartsWith($installedRoot,[StringComparison]::OrdinalIgnoreCase)) 'Worker directory must be outside the installed package root.'
    $workerOutputPath=Join-Path $tempRoot 'worker-output.txt';$workerErrorPath=Join-Path $tempRoot 'worker-error.txt'
    $workerProcess=Start-Process -FilePath 'powershell.exe' -ArgumentList $workerArguments -WorkingDirectory $workerDirectory -WindowStyle Hidden -RedirectStandardOutput $workerOutputPath -RedirectStandardError $workerErrorPath -PassThru -Wait
    if($workerProcess.ExitCode-ne0){
        $resultExists=Test-Path -LiteralPath $resultPath
        $workerError=if($resultExists){[string]((Get-Content -Raw -LiteralPath $resultPath|ConvertFrom-Json).error)}else{[IO.File]::ReadAllText($workerErrorPath)}
        $workerOutput=[IO.File]::ReadAllText($workerOutputPath)
        throw "Worker failed from the isolated staging directory. Worker=$($staged.workerPath); Manifest=$($staged.manifestPath); ResultExists=$resultExists; Output=$workerOutput; Error=$workerError"
    }
    $result=Get-Content -Raw -LiteralPath $resultPath|ConvertFrom-Json
    Assert-True ($result.status-eq'updated'-and[int]$result.updatedCount-eq3-and[int]$result.installedCount-eq3) 'Worker package counts are incorrect.'
    Assert-True (@($result.results).Count-eq6-and@($result.results|Where-Object{[string]$_.package-eq'puc-config'}).Count-eq1-and@($result.results|Where-Object{[string]$_.status-eq'installed'}).Count-eq3) 'Worker package result rows are incomplete.'
    Assert-True (-not(Test-Path -LiteralPath (Join-Path $installedRoot 'puc-config\stale.txt'))) 'Replacement left a stale file.'
    Assert-True (Test-Path -LiteralPath (Join-Path $installedRoot 'make-android-upgrade-package\scripts\marker.txt')) 'Missing support package was not installed.'
    Assert-True (-not(Test-Path -LiteralPath (Join-Path $installedRoot 'docs'))) 'Non-package directory was installed.'
    $state=Get-Content -Raw -LiteralPath $statePath|ConvertFrom-Json
    Assert-True ($state.repository.commitId-eq$commitA-and@($state.repository.packages).Count-eq6) 'Repository state is incomplete.'

    $latest=& $compatibilityUpdater -SkillPath (Join-Path $installedRoot 'puc-config') -Mode Apply -RepositoryRoot $repositoryRoot -RemoteCommitOverride $commitA -StatePathOverride $statePath
    Assert-True ((@($latest)[-1]|ConvertFrom-Json).status-eq'latest') 'Matching commit did not skip staging.'

    $rollbackRoot=Join-Path $tempRoot 'rollback-installed';New-TestInstallation $rollbackRoot
    $blockedParent=Join-Path $tempRoot 'blocked-parent';Write-TestFile $blockedParent 'not-a-directory'
    $rollbackResult=Join-Path $tempRoot 'rollback-result.json';$rollbackStage=Join-Path $tempRoot 'rollback-stage'
    $rollbackStaged=Stage-Update $rollbackRoot $repositoryRoot 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' (Join-Path $blockedParent 'state.json') $rollbackStage $rollbackResult
    $failed=$false
    try{& $rollbackStaged.workerPath -ManifestPath $rollbackStaged.manifestPath -NoRelaunch}catch{$failed=$true}
    Assert-True $failed 'Worker failure was not reported.'
    Assert-True ((Get-Content -Raw (Join-Path $rollbackRoot 'puc-config\SKILL.md'))-eq'old-puc') 'Rollback did not restore puc-config.'
    Assert-True ((Get-Content -Raw (Join-Path $rollbackRoot 'get-business-log\SKILL.md'))-eq'old-log') 'Rollback did not restore get-business-log.'
    Assert-True (-not(Test-Path -LiteralPath (Join-Path $rollbackRoot 'make-android-upgrade-package'))) 'Rollback left an installed package.'
    Assert-True ((Get-Content -Raw -LiteralPath $rollbackResult|ConvertFrom-Json).status-eq'update-failed') 'Rollback result was not recorded.'

    $resultFailureRoot=Join-Path $tempRoot 'result-failure-installed';New-TestInstallation $resultFailureRoot
    $resultFailureState=Join-Path $tempRoot 'result-failure-state.json'
    Write-TestFile $resultFailureState '{"repository":{"commitId":"cccccccccccccccccccccccccccccccccccccccc","packages":["puc-config"]}}'
    $blockedResultParent=Join-Path $tempRoot 'blocked-result-parent';Write-TestFile $blockedResultParent 'not-a-directory'
    $resultFailureStaged=Stage-Update $resultFailureRoot $repositoryRoot 'dddddddddddddddddddddddddddddddddddddddd' $resultFailureState (Join-Path $tempRoot 'result-failure-stage') (Join-Path $blockedResultParent 'result.json')
    $resultWriteFailed=$false
    try{& $resultFailureStaged.workerPath -ManifestPath $resultFailureStaged.manifestPath -NoRelaunch}catch{$resultWriteFailed=$true}
    Assert-True $resultWriteFailed 'Result write failure was not reported.'
    Assert-True ((Get-Content -Raw (Join-Path $resultFailureRoot 'puc-config\SKILL.md'))-eq'old-puc') 'Result failure did not roll back packages.'
    Assert-True ((Get-Content -Raw $resultFailureState|ConvertFrom-Json).repository.commitId-eq'cccccccccccccccccccccccccccccccccccccccc') 'Result failure did not restore the previous commit state.'

    $launcherSource=[IO.File]::ReadAllText((Join-Path $skillRoot 'scripts\PucConfigLauncher.ps1'),[Text.Encoding]::UTF8)
    Assert-True ($launcherSource-match'(?s)Start-Process\s+-FilePath\s+''powershell\.exe''.*?-WorkingDirectory\s+\$workerDirectory') 'Launcher does not isolate the update worker working directory.'
    'PUC staged repository update tests passed.'
}finally{Set-Location -LiteralPath $workspaceWorkRoot;[Environment]::CurrentDirectory=$workspaceWorkRoot;if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force}}
