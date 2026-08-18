$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$searchCommand = Join-Path $skillRoot 'scripts\Invoke-PucDispatcherSearch.ps1'
$personnelCommand = Join-Path $skillRoot 'scripts\Invoke-PucPersonnel.ps1'
$modulePath = Join-Path $skillRoot 'scripts\PucConfig.psm1'
$bundledNode = 'C:\Users\250600074\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
$node = if (Test-Path -LiteralPath $bundledNode) { $bundledNode } else { (Get-Command node.exe,node -ErrorAction Stop | Select-Object -First 1).Source }

function Assert-Equal($Actual,$Expected,[string]$Message) {
    if ([string]$Actual -cne [string]$Expected) { throw "$Message. Expected '$Expected', got '$Actual'." }
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

    $personnelLines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $personnelCommand -Environment 127.0.0.1 -ExactAlias vehicle-test -DispatcherAccount mhw19001 -NumberType 104 -DryRun -ConfigRoot $root)
    $summary = Get-LastJson $personnelLines
    Assert-Equal $summary.status 'previewed' 'Personnel preview status'
    Assert-Equal $summary.results[0].dispatcherAccount 'mhw19001' 'Selected dispatcher binding'
    $traces = @($personnelLines | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } | Where-Object recordType -eq 'api-response')
    if ($traces.Count -lt 2) { throw 'Personnel workflow did not emit API response trace records.' }

    Import-Module $modulePath -Force
    $response = Invoke-PucHttpRequest -Method GET -Uri ([uri]"http://127.0.0.1:$port/writes")
    $requests = [Text.Encoding]::UTF8.GetString($response.BodyBytes) | ConvertFrom-Json
    Assert-Equal $requests.accountQueries[0].is_fuzzy_qry 1 'GUI dispatcher search fuzzy flag'
    Assert-Equal @($requests.personnelRequests | Where-Object number_type -eq 104).Count 1 'Personnel number type propagation'
    Write-Output 'PASS PersonnelLauncher'
} finally {
    if ($null -ne $server) { if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }; $server.Dispose() }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
