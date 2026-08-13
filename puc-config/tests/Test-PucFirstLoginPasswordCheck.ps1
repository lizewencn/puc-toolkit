$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$command = Join-Path $skillRoot 'scripts\Invoke-PucFirstLoginPasswordCheck.ps1'
$modulePath = Join-Path $skillRoot 'scripts\PucConfig.psm1'
$bundledNode = 'C:\Users\250600074\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
$node = if (Test-Path -LiteralPath $bundledNode) { $bundledNode } else { (Get-Command node.exe,node -ErrorAction Stop | Select-Object -First 1).Source }

function Assert-Equal($Actual,$Expected,[string]$Message) { if ([string]$Actual -cne [string]$Expected) { throw "$Message. Expected '$Expected', got '$Actual'." } }
function Get-FreePort { $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();try{return ([Net.IPEndPoint]$listener.LocalEndpoint).Port}finally{$listener.Stop()} }

$root = Join-Path ([IO.Path]::GetTempPath()) ('puc-first-login-'+[guid]::NewGuid().ToString('N'))
$port = Get-FreePort
$serverPath = Join-Path $PSScriptRoot 'first_login_policy_fake_server.js'
$server = $null
$oldTestMode = $env:PUC_CONFIG_TEST_MODE
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $config=[ordered]@{version=1;environments=@([ordered]@{name='fake';baseUrl="http://127.0.0.1:$port";realm='puc.com';adminAccount='admin';token='test-token';pucId='00018';allowInsecureTls=$false})}
    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'config.json') -Encoding UTF8
    $source=[IO.File]::ReadAllText($serverPath,[Text.Encoding]::UTF8)
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source))
    $arguments='-e "process.argv[2]='''+$port+''';eval(Buffer.from('''+$encoded+''',''base64'').toString(''utf8''))"'
    $server = Start-Process -FilePath $node -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $ready=$false
    for($i=0;$i-lt 50;$i++){try{$client=[Net.Sockets.TcpClient]::new();$client.Connect('127.0.0.1',$port);$client.Dispose();$ready=$true;break}catch{Start-Sleep -Milliseconds 100}}
    if (-not $ready) { throw 'First-login policy fake server did not start.' }
    $env:PUC_CONFIG_TEST_MODE = '1'
    $endpoint = "http://127.0.0.1:$port/confs"
    $status = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Environment fake -Action Status -DryRun -ConfigRoot $root -EndpointOverride $endpoint | ConvertFrom-Json
    Assert-Equal $status.currentFlag 0 'Initial status flag'
    Assert-Equal $status.configurationGuid 'DynamicConfigGuid@common' 'Queried configuration GUID'
    Import-Module $modulePath -Force
    $null = Invoke-PucHttpRequest -Method GET -Uri ([uri]"http://127.0.0.1:$port/null-flag-once")
    $nullStatus = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Environment fake -Action Status -DryRun -ConfigRoot $root -EndpointOverride $endpoint | ConvertFrom-Json
    Assert-Equal $nullStatus.currentFlag 0 'Null flag defaults to zero'
    Assert-Equal $nullStatus.flagDefaulted $true 'Null flag default marker'
    $updated = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Environment fake -Action Enable -Live -ConfirmLive -ConfigRoot $root -EndpointOverride $endpoint | ConvertFrom-Json
    Assert-Equal $updated.status 'updated' 'Enable status'
    Assert-Equal $updated.currentFlag 1 'Enabled flag'
    $unchanged = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $command -Environment fake -Action Enable -Live -ConfirmLive -ConfigRoot $root -EndpointOverride $endpoint | ConvertFrom-Json
    Assert-Equal $unchanged.status 'unchanged' 'No-change status'
    $response = Invoke-PucHttpRequest -Method GET -Uri ([uri]"http://127.0.0.1:$port/requests")
    $requests = ([Text.Encoding]::UTF8.GetString($response.BodyBytes) | ConvertFrom-Json).requests
    Assert-Equal @($requests | Where-Object cmd_name -eq 'conf_edit_dc_pwd_config_req').Count 1 'Edit request count'
    $edit = @($requests | Where-Object cmd_name -eq 'conf_edit_dc_pwd_config_req')[0]
    Assert-Equal $edit.guid 'DynamicConfigGuid@common' 'Edit uses queried GUID'
    Assert-Equal $edit.first_login_change_flag 1 'Edit flag'
    $query = @($requests | Where-Object cmd_name -eq 'conf_query_dc_pwd_config_request')[0]
    Assert-Equal $query.product_name 'PUC' 'Query product name'
    Assert-Equal $query.version '10' 'Query version'
    Assert-Equal $query.puc_id '00018' 'Query PUC ID'
    Write-Output 'PASS FirstLoginPasswordCheck'
} finally {
    $env:PUC_CONFIG_TEST_MODE = $oldTestMode
    if ($null -ne $server) { if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }; $server.Dispose() }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
