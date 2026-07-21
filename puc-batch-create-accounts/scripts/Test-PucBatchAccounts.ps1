[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$batchScript = Join-Path $PSScriptRoot 'PucBatchAccounts.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("puc-batch-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

$listenerProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listenerProbe.Start()
$port = ([Net.IPEndPoint]$listenerProbe.LocalEndpoint).Port
$listenerProbe.Stop()

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
                $parts = $requestLine.Split(' ')
                $method = $parts[0]
                $target = $parts[1]
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
                $status = 200
                $response = switch -Regex ($target) {
                    '^/shutdown$' { $stopAfterResponse = $true; '{"stopped":true}'; break }
                    '^/login$' { '{"token":"mock-token"}'; break }
                    '^/roles$' { '{"rows":[{"id":"role-1","name":"superadministrator"}]}'; break }
                    '^/systems$' { '{"rows":[{"id":"sys-1","name":"System A"},{"id":"sys-2","name":"System B"}]}'; break }
                    '^/access-points$' { '{"rows":[{"id":"ap-1","name":"AP A"},{"id":"ap-2","name":"AP B"}]}'; break }
                    '^/device-orgs$' { '{"rows":[{"id":"device-root","name":"Dispatch"}]}'; break }
                    '^/address-orgs$' { '{"rows":[{"id":"address-root","name":"Dispatch"}]}'; break }
                    '^/accounts\?query=(lzw93012|93012)$' { '{"rows":[{"id":"existing","name":"Existing","account":"lzw93012","dispatchNumber":"93012"}]}'; break }
                    '^/accounts\?query=' { '{"rows":[]}'; break }
                    '^/accounts$' {
                        $payload = $body | ConvertFrom-Json
                        $valid = $method -eq 'POST' -and
                            $payload.password -eq '00112233445566778899aabbccddeeff' -and
                            @($payload.systemIds).Count -eq 2 -and @($payload.accessPointIds).Count -eq 2 -and
                            $payload.authorizedDeviceOrgId -eq 'device-root' -and $payload.ownedDeviceOrgId -eq 'device-root' -and
                            $payload.authorizedAddressOrgId -eq 'address-root' -and $payload.ownedAddressOrgId -eq 'address-root'
                        if ($valid) { '{"success":true}' } else { $status = 422; '{"success":false}' }
                        break
                    }
                    default { $status = 404; '{"error":"not found"}' }
                }
                $reason = if ($status -eq 200) { 'OK' } elseif ($status -eq 422) { 'Unprocessable Entity' } else { 'Not Found' }
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
    if ($server.State -ne 'Running') {
        $details = Receive-Job $server -ErrorAction SilentlyContinue | Out-String
        throw "Mock server failed to start. $details"
    }
    $adapter = @{
        token = @{ responsePath='token'; headerName='Authorization'; prefix='Bearer ' }
        selectors = @{ rows='rows'; account='account'; dispatchNumber='dispatchNumber'; id='id'; name='name'; success='success' }
        operations = @{
            login=@{method='POST';path='/login';headers=@{};bodyTemplate=@{username='{{username}}';password='{{password}}'}}
            searchAccounts=@{method='GET';path='/accounts?query={{query}}';headers=@{};bodyTemplate=$null}
            roles=@{method='GET';path='/roles';headers=@{};bodyTemplate=$null}
            systems=@{method='GET';path='/systems';headers=@{};bodyTemplate=$null}
            accessPoints=@{method='GET';path='/access-points';headers=@{};bodyTemplate=$null}
            deviceOrganizations=@{method='GET';path='/device-orgs';headers=@{};bodyTemplate=$null}
            addressBookOrganizations=@{method='GET';path='/address-orgs';headers=@{};bodyTemplate=$null}
            createAccount=@{method='POST';path='/accounts';headers=@{};bodyTemplate=@{
                account='{{account}}';alias='{{alias}}';dispatchNumber='{{dispatchNumber}}';password='{{password}}'
                roleId='{{roleId}}';systemIds='{{systemIds}}';accessPointIds='{{accessPointIds}}'
                authorizedDeviceOrgId='{{authorizedDeviceOrgId}}';ownedDeviceOrgId='{{ownedDeviceOrgId}}'
                authorizedAddressOrgId='{{authorizedAddressOrgId}}';ownedAddressOrgId='{{ownedAddressOrgId}}'
            }}
        }
    }
    $config = @{
        baseUrl="http://127.0.0.1:$port";realm='puc.com';ipSuffix='93';startSequence=12;count=2
        accountPrefix='lzw';aliasPrefix='alias';defaultAccountPassword='00112233445566778899aabbccddeeff'
        loginUserEnv='PUC_TEST_ADMIN_USER';loginPasswordEnv='PUC_TEST_ADMIN_PASSWORD'
        highestRoleName='superadministrator';rootOrganizationName='Dispatch';requestDelayMs=0
        maxReadRetries=0;maxScanCount=10;reportDirectory=(Join-Path $tempRoot 'reports')
    }
    $adapterPath = Join-Path $tempRoot 'adapter.json'
    $configPath = Join-Path $tempRoot 'config.json'
    $adapter | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $adapterPath -Encoding UTF8
    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
    $oldAdmin = $env:PUC_TEST_ADMIN_USER
    $oldAdminPassword = $env:PUC_TEST_ADMIN_PASSWORD
    $env:PUC_TEST_ADMIN_USER = 'admin'
    $env:PUC_TEST_ADMIN_PASSWORD = 'admin-password'
    $env:PUC_TEST_NEW_PASSWORD = 'plaintext-should-be-ignored'
    & $batchScript -ConfigPath $configPath -AdapterPath $adapterPath -Confirm:$false
    $report = Get-ChildItem (Join-Path $tempRoot 'reports') -Filter '*.json' | Select-Object -First 1
    $parsed = Get-Content -Raw $report.FullName | ConvertFrom-Json
    $rows = if ($parsed -is [array]) { $parsed } else { @($parsed) }
    if (@($rows | Where-Object status -eq 'skipped').Count -ne 1) { throw 'Expected one duplicate skip.' }
    if (@($rows | Where-Object status -eq 'created').Count -ne 2) { throw 'Expected two created accounts.' }
    if (@($rows | Where-Object status -eq 'failed').Count -ne 0) { throw 'Mock creation reported a failure.' }
    Write-Host 'PUC batch self-test passed.'
} finally {
    $env:PUC_TEST_ADMIN_USER = $oldAdmin
    $env:PUC_TEST_ADMIN_PASSWORD = $oldAdminPassword
    [Environment]::SetEnvironmentVariable('PUC_TEST_NEW_PASSWORD', $null)
    if ($server -and $server.State -eq 'Running') {
        try {
            $shutdownClient = [Net.Sockets.TcpClient]::new('127.0.0.1', $port)
            $shutdownStream = $shutdownClient.GetStream()
            $shutdownBytes = [Text.Encoding]::ASCII.GetBytes("GET /shutdown HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n")
            $shutdownStream.Write($shutdownBytes, 0, $shutdownBytes.Length)
            $shutdownClient.Dispose()
            Wait-Job $server -Timeout 5 | Out-Null
        } catch {}
    }
    if ($server) {
        if ($server.State -eq 'Running') { Stop-Job $server -ErrorAction SilentlyContinue }
        Remove-Job $server -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
