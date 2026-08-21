[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ([string]$Actual -cne [string]$Expected) {
        throw "$Message. Expected '$Expected', got '$Actual'."
    }
}

function Get-Python {
    if (-not [string]::IsNullOrWhiteSpace($env:PUC_PYTHON_EXE) -and (Test-Path -LiteralPath $env:PUC_PYTHON_EXE)) {
        return $env:PUC_PYTHON_EXE
    }
    $command = Get-Command python.exe, python -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike '*\WindowsApps\*' } |
        Select-Object -First 1
    if ($command) { return $command.Source }
    throw 'Python test runtime was not found. Set PUC_PYTHON_EXE to python.exe.'
}

function Start-Bridge {
    $python = Get-Python
    $bridge = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\AppPucBridge.py'
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $python
    $start.Arguments = '"' + $bridge + '"'
    $start.WorkingDirectory = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'APP bridge did not start.' }
    return $process
}

function Send-Command($Process, [hashtable]$Command) {
    $Process.StandardInput.WriteLine(($Command | ConvertTo-Json -Compress -Depth 10))
    $Process.StandardInput.Flush()
}

function Read-Event($Process) {
    $line = $Process.StandardOutput.ReadLine()
    if ([string]::IsNullOrWhiteSpace($line)) { throw 'APP bridge returned an empty output line.' }
    try { return $line | ConvertFrom-Json } catch { throw "APP bridge returned invalid JSON: $line" }
}

$process = $null
try {
    $process = Start-Bridge

    Send-Command $process @{ command = 'status' }
    $status = Read-Event $process
    Assert-Equal $status.type 'response' 'Status response type'
    Assert-Equal $status.command 'status' 'Status command name'
    Assert-True ([bool]$status.ok) 'Status should succeed without a client'
    Assert-True (-not [bool]$status.data.online) 'Initial status should be offline'

    Send-Command $process @{ command = 'stop' }
    $stop1 = Read-Event $process
    Assert-True ([bool]$stop1.ok) 'First stop should be idempotent'
    Send-Command $process @{ command = 'stop' }
    $stop2 = Read-Event $process
    Assert-True ([bool]$stop2.ok) 'Second stop should be idempotent'

    Send-Command $process @{ command = 'login'; account = 'demo'; server = 'http://127.0.0.1:1' }
    $invalid = Read-Event $process
    Assert-Equal $invalid.type 'response' 'Invalid login response type'
    Assert-True (-not [bool]$invalid.ok) 'Login without password should fail validation'
    Assert-True ([string]$invalid.error.message -match 'password') 'Login validation should identify password'

    Send-Command $process @{ command = 'batch_create_groups'; members = @(@{ account = 'member'; app_puc_id = '100' }); group_count = 1 }
    $batch = Read-Event $process
    Assert-Equal $batch.command 'batch_create_groups' 'Batch command name'
    Assert-True (-not [bool]$batch.ok) 'Batch without an authenticated session should fail'
    Assert-True ([string]$batch.error.message -match 'session') 'Batch error should explain missing session'

    Send-Command $process @{ command = 'login'; account = 'demo'; password = 'do-not-print'; server = 'http://127.0.0.1:1'; request_timeout = 0.2; websocket_timeout = 0.2 }
    $accepted = Read-Event $process
    Assert-True ([bool]$accepted.ok) 'Valid login request should be accepted'
    $state = Read-Event $process
    Assert-Equal $state.type 'event' 'Login lifecycle event type'
    Assert-Equal $state.event 'connecting' 'Login should emit connecting state'
    Assert-True (-not [bool]$state.online) 'Connecting state should be offline until authentication succeeds'
    $serialized = $accepted | ConvertTo-Json -Compress -Depth 10
    Assert-True ($serialized -notmatch 'do-not-print') 'Login response exposed the password'
    Assert-True (( $state | ConvertTo-Json -Compress -Depth 10) -notmatch 'do-not-print') 'Login event exposed the password'
} finally {
    if ($null -ne $process) {
        try {
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(5000)) { $process.Kill() }
        } catch {}
        $process.Dispose()
    }
}

Write-Output 'PASS AppPucBridgeContract'
