[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$batchScript = Join-Path $PSScriptRoot 'PucBatchAccounts.ps1'
$adapterPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'references\adapter.json'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("puc-account-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

$probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$probe.Start()
$port = ([Net.IPEndPoint]$probe.LocalEndpoint).Port
$probe.Stop()

$server = Start-Job -ArgumentList $port -ScriptBlock {
    param($port)
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
    $listener.Start()
    try {
        while ($true) {
            $client = $listener.AcceptTcpClient()
            $stopAfterResponse = $false
            try {
                $stream = $client.GetStream()
                $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 4096, $true)
                $requestLine = $reader.ReadLine()
                if ([string]::IsNullOrWhiteSpace($requestLine)) { continue }
                $target = $requestLine.Split(' ')[1]
                $contentLength = 0
                $expectContinue = $false
                while ($true) {
                    $line = $reader.ReadLine()
                    if ([string]::IsNullOrEmpty($line)) { break }
                    if ($line -match '(?i)^Content-Length:\s*(\d+)') { $contentLength = [int]$Matches[1] }
                    if ($line -match '(?i)^Expect:\s*100-continue') { $expectContinue = $true }
                }
                if ($expectContinue) {
                    $continueBytes = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
                    $stream.Write($continueBytes, 0, $continueBytes.Length)
                    $stream.Flush()
                }
                $body = ''
                if ($contentLength -gt 0) {
                    $buffer = New-Object char[] $contentLength
                    $read = $reader.ReadBlock($buffer, 0, $contentLength)
                    $body = -join $buffer[0..($read - 1)]
                }
                $payload = if ($body) { $body | ConvertFrom-Json } else { $null }
                $status = 200
                if ($target -eq '/shutdown') {
                    $stopAfterResponse = $true
                    $response = '{"stopped":true}'
                } else {
                    $response = switch ([string]$payload.cmd_name) {
                        'puc_get_captcha' { '{"cmd_name":"puc_get_captcha_ack","uuid":"captcha-1","captcha":"data:image/png;base64,iVBORw0KGgo="}' }
                        'login_puc_account' {
                            if ($payload.captcha_id -eq 'captcha-1' -and $payload.captcha_value -eq '1234') { '{"result":0,"token":"mock-token"}' }
                            else { $status = 401; '{"result":1,"msg":"bad captcha"}' }
                        }
                        'role_request' { '{"result":0,"role_list":[{"guid":"role-super","role_alias":"superadministrator"}]}' }
                        'system_list_request' { '{"result":0,"system_list":[{"system_id":"070","system_alias":"RTSP"},{"system_id":"912","system_alias":"Dispatch"}]}' }
                        'sap_list_request' { '{"result":0,"sap_base_list":[{"sap_guid":"base-070","sap_alias":"RTSP","sap_list":[{"puc_id":"00001","system_id":"070","domain_name":"puc.com","ssi":"7001","guid":"sap-070"}]},{"sap_guid":"base-912","sap_alias":"Dispatch","sap_list":[{"puc_id":"00001","system_id":"912","domain_name":"puc.com","ssi":"9001","guid":"sap-912"}]}]}' }
                        'short_organization_list_request' { '{"result":0,"organization_info_list":[{"org_identifier":"00","org_alias":"Dispatch"}]}' }
                        'personnel_organization_list_req' { '{"result":0,"organization_info_list":[{"custom_org_id":"00","custom_org_alias":"Dispatch"}]}' }
                        'account_list_request' {
                            if ($payload.querykey -eq 'lzw168011') { '{"result":0,"account_list":[{"dispatcher_account":"lzw168011","dispatcher_no":"1700000000000"}]}' }
                            else { '{"result":0,"account_list":[]}' }
                        }
                        'add_account' {
                            $dispatchSap = $payload.dispatch_sap_list | ConvertFrom-Json
                            $valid = $payload.dispatcher_account -eq 'lzw168012' -and $payload.dispatcher_name -eq 'alias012' -and
                                [string]$payload.dispatcher_no -match '^\d{13}$' -and $payload.dispatcher_pwd -eq '00112233445566778899aabbccddeeff' -and
                                $payload.role -eq 'superadministrator' -and
                                $payload.role_guid -eq 'role-super' -and $payload.system_id_list -eq '070;912' -and
                                $payload.org_identifier -eq '00' -and $payload.org_identifier_list -eq '00' -and
                                $payload.custom_org_id -eq '00' -and $payload.custom_org_identifier_list -eq '00' -and
                                @($dispatchSap.sapList).Count -eq 2 -and @($payload.imei_list).Count -eq 0
                            if ($valid) { '{"result":0,"msg":""}' } else { $status = 422; '{"result":1,"msg":"invalid payload"}' }
                        }
                        default { $status = 404; '{"result":1,"msg":"unknown command"}' }
                    }
                }
                $reason = if ($status -eq 200) { 'OK' } elseif ($status -eq 401) { 'Unauthorized' } elseif ($status -eq 422) { 'Unprocessable Entity' } else { 'Not Found' }
                $bytes = [Text.Encoding]::UTF8.GetBytes($response)
                $header = "HTTP/1.1 $status $reason`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
                $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
                $stream.Write($headerBytes, 0, $headerBytes.Length)
                $stream.Write($bytes, 0, $bytes.Length)
            } finally {
                $client.Dispose()
            }
            if ($stopAfterResponse) { break }
        }
    } finally {
        $listener.Stop()
    }
}

try {
    Start-Sleep -Milliseconds 500
    if ($server.State -ne 'Running') { throw 'Mock PUC command server failed to start.' }
    $config = @{
        baseUrl="http://127.0.0.1:$port";allowInsecureTls=$false;realm='puc.com';ipSuffix='168';startSequence=11;count=1
        accountPrefix='lzw';aliasPrefix='alias';defaultAccountPassword='00112233445566778899aabbccddeeff';loginUserEnv='PUC_TEST_ADMIN_USER'
        loginPasswordEnv='PUC_TEST_ADMIN_PASSWORD';captchaValueEnv='PUC_TEST_CAPTCHA';openCaptchaImage=$false
        captchaImagePath=(Join-Path $tempRoot 'captcha.png');highestRoleName='superadministrator';rootOrganizationName='Dispatch'
        requestDelayMs=0;maxReadRetries=0;maxScanCount=10;reportDirectory=(Join-Path $tempRoot 'reports')
    }
    $configPath = Join-Path $tempRoot 'config.json'
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding UTF8
    $env:PUC_TEST_ADMIN_USER = 'admin'
    $env:PUC_TEST_ADMIN_PASSWORD = 'admin-password'
    $env:PUC_TEST_CAPTCHA = '1234'
    & $batchScript -ConfigPath $configPath -AdapterPath $adapterPath -Confirm:$false
    $report = Get-ChildItem (Join-Path $tempRoot 'reports') -Filter '*.json' | Select-Object -First 1
    $parsed = Get-Content -Raw $report.FullName | ConvertFrom-Json
    $rows = if ($parsed -is [array]) { $parsed } else { @($parsed) }
    if (@($rows | Where-Object status -eq 'skipped').Count -ne 1) { throw 'Expected one duplicate skip.' }
    if (@($rows | Where-Object status -eq 'created').Count -ne 1) { throw 'Expected one created account.' }
    $createdRow = @($rows | Where-Object status -eq 'created')[0]
    if ($createdRow.createRequest.dispatcher_pwd -ne '00112233445566778899aabbccddeeff') { throw 'Create request was not recorded completely.' }
    if ([int]$createdRow.createResponse.result -ne 0) { throw 'Create response was not recorded completely.' }
    $csvReport = Get-ChildItem (Join-Path $tempRoot 'reports') -Filter '*.csv' | Select-Object -First 1
    $csvCreatedRow = @(Import-Csv $csvReport.FullName | Where-Object status -eq 'created')[0]
    $csvRequest = $csvCreatedRow.createRequestJson | ConvertFrom-Json
    $csvResponse = $csvCreatedRow.createResponseJson | ConvertFrom-Json
    if ($csvRequest.dispatcher_pwd -ne '00112233445566778899aabbccddeeff' -or [int]$csvResponse.result -ne 0) { throw 'CSV create trace was not recorded completely.' }
    Write-Host 'PUC account module self-test passed.'
} finally {
    foreach ($name in @('PUC_TEST_ADMIN_USER','PUC_TEST_ADMIN_PASSWORD','PUC_TEST_NEW_PASSWORD','PUC_TEST_CAPTCHA')) {
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    if ($server -and $server.State -eq 'Running') {
        try {
            $shutdown = [Net.Sockets.TcpClient]::new('127.0.0.1', $port)
            $stream = $shutdown.GetStream()
            $bytes = [Text.Encoding]::ASCII.GetBytes("GET /shutdown HTTP/1.1`r`nHost: localhost`r`nConnection: close`r`n`r`n")
            $stream.Write($bytes, 0, $bytes.Length)
            $shutdown.Dispose()
            Wait-Job $server -Timeout 5 | Out-Null
        } catch {}
    }
    if ($server) {
        if ($server.State -eq 'Running') { Stop-Job $server -ErrorAction SilentlyContinue }
        Remove-Job $server -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
