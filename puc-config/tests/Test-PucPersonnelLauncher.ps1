$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$searchCommand = Join-Path $skillRoot 'scripts\Invoke-PucDispatcherSearch.ps1'
$personnelCommand = Join-Path $skillRoot 'scripts\Invoke-PucPersonnel.ps1'
$batchResetCommand = Join-Path $skillRoot 'scripts\Invoke-PucAccountPasswordResetBatch.ps1'
$modulePath = Join-Path $skillRoot 'scripts\PucConfig.psm1'
$bundledNode = 'C:\Users\250600074\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
$node = if (Test-Path -LiteralPath $bundledNode) { $bundledNode } else { (Get-Command node.exe,node -ErrorAction Stop | Select-Object -First 1).Source }

function Assert-Equal($Actual,$Expected,[string]$Message) {
    if ([string]$Actual -cne [string]$Expected) { throw "$Message. Expected '$Expected', got '$Actual'." }
}
function Assert-TimestampCredentials($Person,[string]$Message) {
    $timestamp = [string]$Person.idNumber
    if ($timestamp -notmatch '^\d{13}$') { throw "$Message ID number is not a 13-digit millisecond timestamp: '$timestamp'." }
    Assert-Equal $Person.officerId $timestamp.Substring($timestamp.Length - 8) "$Message officer ID"
    Assert-Equal $Person.mobile $timestamp.Substring(0,11) "$Message mobile"
}
function Get-FreePort {
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
}
function Get-LastJson([string[]]$Lines) {
    for ($index=$Lines.Count-1;$index-ge 0;$index--) {
        $candidate=[string]$Lines[$index]
        if (-not $candidate.Trim().StartsWith('{')) { continue }
        try { return $candidate | ConvertFrom-Json } catch {}
    }
    return $null
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('puc-personnel-launcher-'+[guid]::NewGuid().ToString('N'))
$port = Get-FreePort
$server = $null
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $config=[ordered]@{version=1;environments=@([ordered]@{name='127.0.0.1';baseUrl="http://127.0.0.1:$port";realm='puc.com';adminAccount='admin';token='test-token';pucId='00018';allowInsecureTls=$false})}
    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'config.json') -Encoding UTF8
    $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'puc_fake_server.js'),[Text.Encoding]::UTF8)
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source))
    $arguments='-e "process.argv[2]='''+$port+''';eval(Buffer.from('''+$encoded+''',''base64'').toString(''utf8''))"'
    $server = Start-Process -FilePath $node -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $ready=$false
    for($i=0;$i-lt 50;$i++){try{$client=[Net.Sockets.TcpClient]::new();$client.Connect('127.0.0.1',$port);$client.Dispose();$ready=$true;break}catch{Start-Sleep -Milliseconds 100}}
    if (-not $ready) { throw 'PUC fake server did not start.' }

    $searchLines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $searchCommand -Environment 127.0.0.1 -Query mhw -ConfigRoot $root)
    $search = Get-LastJson $searchLines
    Assert-Equal $search.status 'dispatcher-search' 'Dispatcher search status'
    Assert-Equal $search.count 2 'Dispatcher fuzzy result count'
    Assert-Equal $search.results[0].label 'User 1(mhw19001)' 'Dispatcher display label'

    $batchManifest = Join-Path $root 'batch-reset-manifest.json'
    $batchLines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $batchResetCommand -Environment 127.0.0.1 -Query mhw -DryRun -ManifestPath $batchManifest -ConfigRoot $root)
    $batchPreview = Get-LastJson $batchLines
    Assert-Equal $batchPreview.status 'previewed' 'Batch reset preview status'
    Assert-Equal $batchPreview.accountCount 2 'Batch reset fuzzy account count'

    $emptyManifest = Join-Path $root 'empty-batch-reset-manifest.json'
    $emptyBatchLines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $batchResetCommand -Environment 127.0.0.1 -Query missing -DryRun -ManifestPath $emptyManifest -ConfigRoot $root)
    $emptyBatchPreview = Get-LastJson $emptyBatchLines
    Assert-Equal $emptyBatchPreview.status 'no-match' 'Empty batch reset query status'
    Assert-Equal $emptyBatchPreview.accountCount 0 'Empty batch reset query account count'
    Assert-Equal $emptyBatchPreview.message '未查询到匹配的调度账号，请调整查询关键字后重试。' 'Empty batch reset query message'
    if (Test-Path -LiteralPath $emptyManifest) { throw 'Empty batch reset query must not create a live manifest.' }

    $personnelLines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $personnelCommand -Environment 127.0.0.1 -ExactAlias vehicle-test -DispatcherAccount mhw19001 -NumberType 104 -DryRun -ConfigRoot $root)
    $summary = Get-LastJson $personnelLines
    Assert-Equal $summary.status 'previewed' 'Personnel preview status'
    Assert-Equal $summary.results[0].dispatcherAccount 'mhw19001' 'Selected dispatcher binding'
    Assert-TimestampCredentials $summary.results[0] 'Exact personnel timestamp credentials'
    $traces = @($personnelLines | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } | Where-Object recordType -eq 'api-response')
    if ($traces.Count -lt 2) { throw 'Personnel workflow did not emit API response trace records.' }

    $batchPersonnelLines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $personnelCommand -Environment 127.0.0.1 -AliasPrefix person-test -Count 2 -NumberType 102 -DryRun -ConfigRoot $root)
    $batchPersonnel = Get-LastJson $batchPersonnelLines
    Assert-Equal $batchPersonnel.results.Count 2 'Batch personnel preview count'
    Assert-TimestampCredentials $batchPersonnel.results[0] 'First batch personnel timestamp credentials'
    Assert-TimestampCredentials $batchPersonnel.results[1] 'Second batch personnel timestamp credentials'
    if ([string]$batchPersonnel.results[0].idNumber -eq [string]$batchPersonnel.results[1].idNumber) { throw 'Batch personnel timestamps must be unique.' }
    if ([string]$batchPersonnel.results[0].mobile -eq [string]$batchPersonnel.results[1].mobile) { throw 'Batch personnel mobile values must be unique.' }

    $livePersonnelLines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $personnelCommand -Environment 127.0.0.1 -ExactAlias vehicle-live-test -NumberType 104 -Live -ConfirmLive -ConfigRoot $root)
    $livePersonnel = Get-LastJson $livePersonnelLines
    Assert-TimestampCredentials $livePersonnel.results[0] 'Live exact personnel timestamp credentials'

    Import-Module $modulePath -Force
    $response = Invoke-PucHttpRequest -Method GET -Uri ([uri]"http://127.0.0.1:$port/writes")
    $requests = [Text.Encoding]::UTF8.GetString($response.BodyBytes) | ConvertFrom-Json
    Assert-Equal $requests.accountQueries[0].is_fuzzy_qry 1 'GUI dispatcher search fuzzy flag'
    $batchQuery = @($requests.accountQueries | Where-Object { $_.querykey -eq 'mhw' -and $_.hasPucId -eq $false } | Select-Object -First 1)
    Assert-Equal $batchQuery.Count 1 'Batch reset fuzzy query request count'
    Assert-Equal $batchQuery[0].is_fuzzy_qry 1 'Batch reset fuzzy query flag'
    Assert-Equal $batchQuery[0].online_query 0 'Batch reset online query flag'
    $createdPersonnelRequests = @($requests.personnelRequests | Where-Object { $_.command -eq 'conf_add_personnel_info_req' -and $_.number_type -eq 104 })
    Assert-Equal $createdPersonnelRequests.Count 1 'Personnel number type propagation'
    $createdPersonnel = $createdPersonnelRequests[0]
    Assert-Equal $createdPersonnel.officer_id $createdPersonnel.id_number.Substring($createdPersonnel.id_number.Length - 8) 'Created personnel officer ID payload'
    Assert-Equal $createdPersonnel.mobile $createdPersonnel.id_number.Substring(0,11) 'Created personnel mobile payload'
    Write-Output 'PASS PersonnelLauncher'
} finally {
    if ($null -ne $server) { if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }; $server.Dispose() }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
