[CmdletBinding()]
param(
    [ValidateSet('Module','Transport','LoginContext','AuthLifecycle','RuntimeCompatibility','AccountsFile','SinglePasswordReset','LiveFlow','AccountCreation','AccountCompletion','All')][string]$Case = 'All',
    [int]$ExternalServerPort
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $skillRoot 'scripts\PucConfig.psm1'
$bundledNode = 'C:\Users\250600074\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
$nodeCommand = Get-Command node.exe,node -ErrorAction SilentlyContinue | Select-Object -First 1
$node = if ($nodeCommand) { $nodeCommand.Source } elseif (Test-Path -LiteralPath $bundledNode) { $bundledNode } else { throw 'Node.js test runtime was not found.' }
$oldNode = $env:PUC_NODE_EXE
$env:PUC_NODE_EXE = $node

function Assert-Equal($Actual,$Expected,[string]$Message) { if ([string]$Actual -cne [string]$Expected) { throw "$Message. Expected '$Expected', got '$Actual'." } }
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action,[string]$Pattern) { try { & $Action; throw "Expected error matching '$Pattern'." } catch { if ($_.Exception.Message -notmatch $Pattern) { throw "Expected '$Pattern', got '$($_.Exception.Message)'." } } }
function New-TempDirectory { $path=Join-Path ([IO.Path]::GetTempPath()) ('puc-core-'+[guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $path|Out-Null; return $path }
function Get-FreePort { $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();try{return ([Net.IPEndPoint]$listener.LocalEndpoint).Port}finally{$listener.Stop()} }
function Start-FakeServer([int]$Port) {
    $serverPath=Join-Path $PSScriptRoot 'puc_fake_server.js'
    $source=[IO.File]::ReadAllText($serverPath,[Text.Encoding]::UTF8)
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source))
    $arguments='-e "process.argv[2]='''+$Port+''';eval(Buffer.from('''+$encoded+''',''base64'').toString(''utf8''))"'
    $process=Start-Process -FilePath $node -ArgumentList $arguments -WindowStyle Hidden -PassThru
    for($i=0;$i-lt 50;$i++){try{$client=[Net.Sockets.TcpClient]::new();$client.Connect('127.0.0.1',$Port);$client.Dispose();return $process}catch{Start-Sleep -Milliseconds 100}}
    throw 'Fake server did not start.'
}
function Stop-FakeServer($Process) {
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue }
        try { $Process.WaitForExit(5000) | Out-Null } catch {}
    } finally { $Process.Dispose() }
}
function New-TestConfig([string]$Root,[int]$Port) {
    $config=[ordered]@{version=1;environments=@([ordered]@{name='fake';baseUrl="http://127.0.0.1:$Port";realm='puc.com';adminAccount='admin';adminPassword='admin-secret';newAccountPassword='new-secret';token='test-token';pucId='00001';allowInsecureTls=$false})}
    $config|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $Root 'config.json') -Encoding UTF8
}

function Test-Module {
    Import-Module $modulePath -Force
    $dir=New-TempDirectory
    try {
        $path=Join-Path $dir 'config.json'
        Write-PucJson -Path $path -Value ([ordered]@{version=1;value='first'})
        Write-PucJson -Path $path -Value ([ordered]@{version=1;value='second'})
        Assert-Equal (Read-PucJson -Path $path -Default $null).value 'second' 'Atomic JSON write'
        Assert-Equal @(Get-ChildItem -LiteralPath $dir -Filter '*.tmp.*').Count 0 'Temporary files remain'
        Assert-Equal @(Get-ChildItem -LiteralPath $dir -Filter '*.backup.*').Count 0 'Backup files remain'
        $preview=Format-PucApiResponsePreview -Response ([pscustomobject]@{result=42;msg='failure';details=[pscustomobject]@{code='nested';token='secret-token';dispatcher_pwd='secret-cipher'}})
        Assert-True ($preview -match '"result"\s*:\s*42') 'Failure preview omitted the result field'
        Assert-True ($preview -match '"code"\s*:\s*"nested"') 'Failure preview omitted a nested non-secret field'
        Assert-True ($preview -notmatch 'secret-token|secret-cipher') 'Failure preview exposed credential material'
        Assert-True (([regex]::Matches($preview,'\[REDACTED\]')).Count -eq 2) 'Failure preview did not preserve redacted credential fields'
        Assert-True (Test-PucSavedTokenRejected -Response ([pscustomobject]@{result=51800032;msg='verify-token failed'})) 'Known invalid-token result was not recognized'
        Assert-True (Test-PucSavedTokenRejected -Response ([pscustomobject]@{result='51800032'})) 'String invalid-token result was not recognized'
        Assert-True (-not (Test-PucSavedTokenRejected -Response ([pscustomobject]@{result=42;msg='business failure'}))) 'Unrelated business failure was treated as token rejection'
        Assert-True (-not (Test-PucSavedTokenRejected -Response ([pscustomobject]@{result=0}))) 'Successful response was treated as token rejection'
        $legacyRuntime=[pscustomobject]@{name='fake'}
        Assert-True ($null -eq (Get-PucPropertyPath -Object $legacyRuntime -Path 'pendingLogin')) 'Missing legacy runtime property did not resolve to null'
        $currentRuntime=[ordered]@{name='fake';pendingLogin=[ordered]@{sessionId='abc'}}
        Assert-Equal (Get-PucPropertyPath -Object $currentRuntime -Path 'pendingLogin.sessionId') 'abc' 'Dictionary runtime property path'
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
}
function Test-Transport {
    Import-Module $modulePath -Force
    $dir=New-TempDirectory;$port=if($ExternalServerPort){$ExternalServerPort}else{Get-FreePort};$server=if($ExternalServerPort){$null}else{Start-FakeServer $port}
    try {
        $cookies=@{}
        $response=Invoke-PucHttpRequest -Method GET -Uri ([uri]"http://127.0.0.1:$port/health") -CookieJar $cookies
        Assert-Equal $response.StatusCode 200 'Transport status'
        Assert-Equal $cookies.session 'abc' 'Cookie capture'
        Assert-True ([Text.Encoding]::UTF8.GetString($response.BodyBytes) -match '"ok":true') 'Transport response body'
        $sourceBytes=[byte[]]@(0,1,2,253,254,255)
        $multipart=New-PucMultipartFormData -Fields ([ordered]@{alpha='value-one'}) -Files @([pscustomobject]@{Name='upload';FileName='sample.bin';ContentType='application/octet-stream';Bytes=$sourceBytes})
        $multipartResponse=Invoke-PucHttpRequest -Method POST -Uri ([uri]"http://127.0.0.1:$port/multipart") -Headers @{'Content-Type'=$multipart.ContentType} -Body $multipart.BodyBytes
        $multipartResult=ConvertFrom-PucJsonHttpResponse -Response $multipartResponse
        Assert-True ($multipartResult.contentType -match '^multipart/form-data; boundary=') 'Multipart content type'
        Assert-True ([bool]$multipartResult.hasField) 'Multipart field missing'
        Assert-True ([bool]$multipartResult.hasFile) 'Multipart file missing'
        $binaryResponse=Invoke-PucHttpRequest -Method GET -Uri ([uri]"http://127.0.0.1:$port/binary")
        $outputPath=Join-Path $dir 'nested\download.bin'
        Write-PucBytesAtomically -Path $outputPath -Bytes $binaryResponse.BodyBytes
        Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($outputPath))) ([Convert]::ToBase64String($sourceBytes)) 'Binary download bytes'
        Write-PucBytesAtomically -Path $outputPath -Bytes ([byte[]]@(9,8,7))
        Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($outputPath))) ([Convert]::ToBase64String([byte[]]@(9,8,7))) 'Atomic binary replacement'
        Assert-Equal @(Get-ChildItem -LiteralPath (Split-Path -Parent $outputPath) -Filter '*.tmp.*').Count 0 'Binary temporary files remain'
    } finally { Stop-FakeServer $server;Remove-Item -LiteralPath $dir -Recurse -Force }
}
function Test-LoginContext {
    $dir=New-TempDirectory;$port=if($ExternalServerPort){$ExternalServerPort}else{Get-FreePort};$server=if($ExternalServerPort){$null}else{Start-FakeServer $port};$process=$null
    try {
        $config=[ordered]@{version=1;environments=@([ordered]@{name='fake';baseUrl="http://127.0.0.1:$port";realm='puc.com';adminAccount='admin';adminPassword='admin-secret';newAccountPassword='new-secret';token='';pucId='';allowInsecureTls=$false})}
        $config|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $dir 'config.json') -Encoding UTF8
        $sessionId=[guid]::NewGuid().ToString('N')
        $sessionDirectory=Join-Path (Join-Path $dir 'login-runtime') $sessionId
        New-Item -ItemType Directory -Path $sessionDirectory -Force|Out-Null
        $worker=Join-Path $skillRoot 'scripts\PucLoginWorker.ps1'
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$worker,'-Environment','fake','-SessionId',$sessionId,'-ConfigRoot',$dir,'-InputTimeoutSeconds','20')
        $process=Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $readyPath=Join-Path $sessionDirectory 'ready.json'
        $resultPath=Join-Path $sessionDirectory 'result.json'
        for($index=0;$index-lt 100 -and -not (Test-Path -LiteralPath $readyPath);$index++){
            if($process.HasExited){throw "Login worker exited before captcha readiness with code $($process.ExitCode)."}
            Start-Sleep -Milliseconds 100
            $process.Refresh()
        }
        Assert-True (Test-Path -LiteralPath $readyPath) 'Login worker did not become ready'
        Import-Module $modulePath -Force
        Write-PucJson -Path (Join-Path $sessionDirectory 'input.json') -Value ([ordered]@{captchaValue=Protect-PucString '1234'})
        for($index=0;$index-lt 100 -and -not (Test-Path -LiteralPath $resultPath);$index++){Start-Sleep -Milliseconds 100}
        Assert-True (Test-Path -LiteralPath $resultPath) 'Login worker did not return a result'
        $result=Read-PucJson -Path $resultPath -Default $null
        Assert-Equal $result.status 'login_succeeded' 'Login worker status'
        $updated=Get-PucEnvironment -ConfigRoot $dir -Name 'fake'
        Assert-Equal $updated.token 'test-token' 'Saved login token'
        Assert-Equal $updated.pucId '00018' 'Saved authenticated effective PUC ID'
        $writesResponse=Invoke-PucHttpRequest -Method GET -Uri ([uri]"http://127.0.0.1:$port/writes")
        $observed=[Text.Encoding]::UTF8.GetString($writesResponse.BodyBytes)|ConvertFrom-Json
        Assert-Equal @($observed.loginPucIds).Count 1 'Login request count'
        Assert-Equal $observed.loginPucIds[0] '03093' 'Login bootstrap PUC ID'
        Assert-Equal $observed.authenticatedCommonQueries 1 'Authenticated common configuration query count'
    } finally {
        if($null-ne$process){try{if(-not$process.HasExited){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue}}finally{$process.Dispose()}}
        Stop-FakeServer $server;Remove-Item -LiteralPath $dir -Recurse -Force
    }
}
function Test-AuthLifecycle {
    $dir=New-TempDirectory;$port=if($ExternalServerPort){$ExternalServerPort}else{Get-FreePort};$server=if($ExternalServerPort){$null}else{Start-FakeServer $port}
    try {
        New-TestConfig $dir $port
        Import-Module $modulePath -Force
        $configPath=Join-Path $dir 'config.json'
        $document=Read-PucJson -Path $configPath -Default $null
        $document.environments[0].token='rejected-token'
        $document.environments[0].pucId='stale-puc-id'
        Write-PucJson -Path $configPath -Value $document
        $command=Join-Path $skillRoot 'scripts\Invoke-PucAuth.ps1'
        $rejected=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Action Validate -Environment fake -ConfigRoot $dir|ConvertFrom-Json
        Assert-Equal $rejected.reason 'rejected' 'Rejected token reason'
        $updated=Get-PucEnvironment -ConfigRoot $dir -Name 'fake'
        Assert-Equal $updated.token '' 'Rejected token was not cleared'
        Assert-Equal $updated.pucId '' 'PUC ID was not cleared with rejected token'

        $document=Read-PucJson -Path $configPath -Default $null
        $document.environments[0].token=''
        $document.environments[0].pucId='stale-puc-id'
        Write-PucJson -Path $configPath -Value $document
        $missing=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Action Validate -Environment fake -ConfigRoot $dir|ConvertFrom-Json
        Assert-Equal $missing.reason 'missing' 'Missing token reason'
        $normalized=Get-PucEnvironment -ConfigRoot $dir -Name 'fake'
        Assert-Equal $normalized.token '' 'Missing token changed unexpectedly'
        Assert-Equal $normalized.pucId '' 'Stale PUC ID was not cleared with missing token'

    } finally { Stop-FakeServer $server;Remove-Item -LiteralPath $dir -Recurse -Force }
}
function Test-RuntimeCompatibility {
    Import-Module $modulePath -Force
    $dir=New-TempDirectory
    try {
        $environmentName='127.0.0.1'
        $config=[ordered]@{version=1;environments=@([ordered]@{name=$environmentName;baseUrl='http://127.0.0.1:1';realm='puc.com';adminAccount='admin';adminPassword='';newAccountPassword='';token='';pucId='';allowInsecureTls=$false})}
        Write-PucJson -Path (Join-Path $dir 'config.json') -Value $config
        Write-PucJson -Path (Join-Path $dir 'runtime.json') -Value ([ordered]@{version=1;environments=@([ordered]@{name=$environmentName})})
        $command=Join-Path $skillRoot 'scripts\Invoke-PucAuth.ps1'
        Assert-Throws { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Action Login -Environment $environmentName -CaptchaValue unused -ConfigRoot $dir 2>&1 } 'No pending same-process login exists'
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
}
function Test-AccountsFile {
    $dir=New-TempDirectory
    try {
        $accounts=Join-Path $dir 'accounts.json';[IO.File]::WriteAllText($accounts,'["mhw19001","mhw19002"]')
        $command=Join-Path $skillRoot 'scripts\Invoke-PucAccountPasswordResetBatch.ps1'
        $result=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Environment fake -AccountsPath $accounts -PlanOnly|ConvertFrom-Json
        Assert-Equal $result.accountCount 2 'Exact account count'
        $duplicate=Join-Path $dir 'duplicate.json';[IO.File]::WriteAllText($duplicate,'["mhw19001","MHW19001"]')
        Assert-Throws { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Environment fake -AccountsPath $duplicate -PlanOnly 2>&1 } 'duplicate account'
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
}
function Test-LiveFlow {
    $dir=New-TempDirectory;$port=if($ExternalServerPort){$ExternalServerPort}else{Get-FreePort};$server=if($ExternalServerPort){$null}else{Start-FakeServer $port}
    try {
        New-TestConfig $dir $port
        $accounts=Join-Path $dir 'accounts.json';[IO.File]::WriteAllText($accounts,'["mhw19001","mhw19002"]')
        $manifest=Join-Path $dir 'manifest.json';$command=Join-Path $skillRoot 'scripts\Invoke-PucAccountPasswordResetBatch.ps1'
        $preview=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Environment fake -AccountsPath $accounts -DryRun -ManifestPath $manifest -ConfigRoot $dir|ConvertFrom-Json
        Assert-Equal $preview.accountCount 2 'Preview count'
        $live=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Environment fake -Live -ConfirmLive -ManifestPath $manifest -ConfigRoot $dir|ConvertFrom-Json
        Assert-Equal $live.succeeded 2 'Live success count';Assert-Equal $live.failed 0 'Live failure count'
        Assert-True ($live.firstLoginPasswordValidation.known -eq $true) 'Batch policy status is known'
        Assert-True ($live.firstLoginPasswordValidation.enabled -eq $true) 'Batch policy is enabled'
        Import-Module $modulePath -Force
        $writesResponse=Invoke-PucHttpRequest -Method GET -Uri ([uri]"http://127.0.0.1:$port/writes")
        $writes=[Text.Encoding]::UTF8.GetString($writesResponse.BodyBytes)|ConvertFrom-Json
        # /writes ignores the request body and records exactly two ordered writes per account.
        Assert-Equal @($writes.writes).Count 4 'Write count'
        Assert-Equal $writes.policyQueries 1 'Batch policy query count'
        foreach($account in @('mhw19001','mhw19002')){Assert-Equal @($writes.writes|Where-Object account -eq $account).Count 2 "Writes for $account"}
    } finally { Stop-FakeServer $server;Remove-Item -LiteralPath $dir -Recurse -Force }
}
function Test-SinglePasswordReset {
    $dir=New-TempDirectory;$port=if($ExternalServerPort){$ExternalServerPort}else{Get-FreePort};$server=if($ExternalServerPort){$null}else{Start-FakeServer $port}
    try {
        New-TestConfig $dir $port
        $command=Join-Path $skillRoot 'scripts\Invoke-PucAccountPasswordReset.ps1'
        $preview=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Environment fake -Account mhw19001 -DryRun -ConfigRoot $dir|ConvertFrom-Json
        $live=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Environment fake -Account mhw19001 -Live -ConfirmLive -ExpectedSnapshotHash $preview.snapshotHash -ConfigRoot $dir|ConvertFrom-Json
        Assert-Equal $live.status 'password-reset' 'Single reset status'
        Assert-True ($live.firstLoginPasswordValidation.known -eq $true) 'Single reset policy status is known'
        Assert-True ($live.firstLoginPasswordValidation.enabled -eq $true) 'Single reset policy is enabled'
        Import-Module $modulePath -Force
        $writesResponse=Invoke-PucHttpRequest -Method GET -Uri ([uri]"http://127.0.0.1:$port/writes")
        $writes=[Text.Encoding]::UTF8.GetString($writesResponse.BodyBytes)|ConvertFrom-Json
        Assert-Equal @($writes.writes|Where-Object account -eq 'mhw19001').Count 2 'Single reset write count'
        Assert-Equal $writes.policyQueries 1 'Single reset policy query count'
    } finally { Stop-FakeServer $server;Remove-Item -LiteralPath $dir -Recurse -Force }
}
function Test-AccountCreation {
    $dir=New-TempDirectory;$port=if($ExternalServerPort){$ExternalServerPort}else{Get-FreePort};$server=if($ExternalServerPort){$null}else{Start-FakeServer $port}
    try {
        New-TestConfig $dir $port
        $command=Join-Path $skillRoot 'scripts\Invoke-PucAccounts.ps1'
        $output=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Environment fake -Prefix new -Live -ConfirmLive -ConfigRoot $dir)
        $jsonLine=@($output|Where-Object { ([string]$_).TrimStart().StartsWith('{') })|Select-Object -Last 1
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$jsonLine)) 'Account creation policy output is missing'
        $policyResult=$jsonLine|ConvertFrom-Json
        Assert-Equal $policyResult.status 'post-create-login-policy' 'Account creation policy output status'
        Assert-True ($policyResult.firstLoginPasswordValidation.known -eq $true) 'Account creation policy status is known'
        Assert-True ($policyResult.firstLoginPasswordValidation.enabled -eq $true) 'Account creation policy is enabled'
        Import-Module $modulePath -Force
        $writesResponse=Invoke-PucHttpRequest -Method GET -Uri ([uri]"http://127.0.0.1:$port/writes")
        $writes=[Text.Encoding]::UTF8.GetString($writesResponse.BodyBytes)|ConvertFrom-Json
        $createdAccounts=@($writes.writes|Where-Object operation -eq 'add_account')
        Assert-Equal $createdAccounts.Count 1 'Created account count'
        Assert-Equal $createdAccounts[0].account 'new1005' 'Created account should increment the highest existing sequence without filling gaps'
        Assert-Equal $writes.policyQueries 1 'Account creation policy query count'
    } finally { Stop-FakeServer $server;Remove-Item -LiteralPath $dir -Recurse -Force }
}
function Test-AccountCompletion {
    $dir=New-TempDirectory;$port=if($ExternalServerPort){$ExternalServerPort}else{Get-FreePort};$server=if($ExternalServerPort){$null}else{Start-FakeServer $port}
    try {
        New-TestConfig $dir $port
        $command=Join-Path $skillRoot 'scripts\Invoke-PucAccountCompletion.ps1'
        $singleManifest=Join-Path $dir 'single.json'
        $single=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Environment fake -Account mhw19001 -DryRun -ManifestPath $singleManifest -ConfigRoot $dir|ConvertFrom-Json
        Assert-Equal $single.accountCount 1 'Single completion target count'
        Assert-Equal $single.alreadyComplete 1 'Single already-complete count'
        $batchManifest=Join-Path $dir 'batch.json'
        $preview=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Environment fake -Query mhw -NormalizeGeneratedAlias -DryRun -ManifestPath $batchManifest -ConfigRoot $dir|ConvertFrom-Json
        Assert-Equal $preview.accountCount 2 'Batch completion target count'
        Assert-Equal $preview.updateCount 2 'Batch completion update count'
        $live=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Environment fake -Live -ConfirmLive -ManifestPath $batchManifest -ConfigRoot $dir|ConvertFrom-Json
        Assert-Equal $live.succeeded 2 'Batch completion success count'
        Import-Module $modulePath -Force
        $writesResponse=Invoke-PucHttpRequest -Method GET -Uri ([uri]"http://127.0.0.1:$port/writes")
        $writes=[Text.Encoding]::UTF8.GetString($writesResponse.BodyBytes)|ConvertFrom-Json
        $completionWrites=@($writes.writes|Where-Object { [int]$_.isChangePassword -eq 0 })
        Assert-Equal $completionWrites.Count 2 'Completion write count'
        Assert-Equal $completionWrites[0].account 'mhw19001' 'Completion write order first'
        Assert-Equal $completionWrites[1].account 'mhw19002' 'Completion write order second'
    } finally { Stop-FakeServer $server;Remove-Item -LiteralPath $dir -Recurse -Force }
}

try {
    $cases=if($Case-eq'All'){@('Module','Transport','LoginContext','AuthLifecycle','RuntimeCompatibility','AccountsFile','SinglePasswordReset','LiveFlow','AccountCreation','AccountCompletion')}else{@($Case)}
    foreach($name in $cases){& "Test-$name";Write-Output "PASS $name"}
} finally { $env:PUC_NODE_EXE=$oldNode }
