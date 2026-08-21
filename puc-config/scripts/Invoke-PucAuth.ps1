[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Ensure','Validate','InteractiveLogin','Captcha','Login')][string]$Action,
    [Parameter(Mandatory)][string]$Environment,
    [string]$CaptchaValue,
    [string]$ConfigRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$root = Get-PucConfigRoot $ConfigRoot
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
$adapter = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\references\accounts-adapter.json') | ConvertFrom-Json
$baseUri = [uri]$environmentConfig.baseUrl

function Invoke-JsonRequest($Body, [hashtable]$Headers) {
    $effectiveHeaders = if ($null -eq $Headers) { @{} } else { $Headers }
    return Invoke-PucJsonRequest -Uri ([uri]($baseUri.AbsoluteUri.TrimEnd('/') + '/confs')) -Body $Body -Headers $effectiveHeaders -AllowInsecureTls ([bool]$environmentConfig.allowInsecureTls)
}

function New-RuntimeEntry($PendingLogin) {
    return [ordered]@{ name=$Environment; pendingLogin=$PendingLogin }
}

function Set-EnvironmentAuth([string]$Token,[string]$PucId) {
    $configPath = Join-Path $root 'config.json'
    $document = Read-PucJson -Path $configPath -Default $null
    $entry = Get-PucEntry -Document $document -Name $Environment
    if ($null -eq $entry) { throw "Environment '$Environment' no longer exists in config.json." }
    $entry | Add-Member -NotePropertyName token -NotePropertyValue $Token -Force
    $entry | Add-Member -NotePropertyName pucId -NotePropertyValue $PucId -Force
    Write-PucJson -Path $configPath -Value (Set-PucEntry -Document $document -Name $Environment -Entry $entry)
}

function Clear-EnvironmentAuth {
    Set-EnvironmentAuth -Token '' -PucId ''
}

function Get-SessionPaths([string]$SessionId) {
    if ($SessionId -notmatch '^[a-f0-9]{32}$') { throw 'Pending login session ID is invalid.' }
    $directory = Join-Path (Join-Path $root 'login-runtime') $SessionId
    return [pscustomobject]@{
        Directory=$directory
        Ready=Join-Path $directory 'ready.json'
        Input=Join-Path $directory 'input.json'
        Result=Join-Path $directory 'result.json'
        Error=Join-Path $directory 'worker-error.log'
        Image=Join-Path $root ("captcha-$SessionId.png")
    }
}

function Clear-PendingLogin([string]$SessionId) {
    Set-PucRuntimeEntry -ConfigRoot $root -Name $Environment -Entry (New-RuntimeEntry -PendingLogin $null)
    if ([string]::IsNullOrWhiteSpace($SessionId) -or $SessionId -notmatch '^[a-f0-9]{32}$') { return }
    $paths = Get-SessionPaths $SessionId
    foreach ($file in @($paths.Ready,$paths.Input,$paths.Input+'.tmp',$paths.Result,$paths.Result+'.tmp',$paths.Error,$paths.Image)) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    if (Test-Path -LiteralPath $paths.Directory) {
        $remaining = @(Get-ChildItem -LiteralPath $paths.Directory -Force)
        if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $paths.Directory -Force }
    }
}

function Write-AtomicJson([string]$Path,$Value) {
    $temporaryPath = $Path + '.tmp'
    $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

try {
    if ($Action -eq 'Ensure') {
        $validationJson = & $PSCommandPath -Action Validate -Environment $Environment -ConfigRoot $root
        $validation = $validationJson | ConvertFrom-Json
        if ($validation.valid -eq $true) {
            $validationJson
            return
        }
        if ([string]$validation.reason -notin @('missing','rejected')) {
            throw "Saved token validation did not return a recoverable state: $([string]$validation.reason)"
        }
        if ([string]$validation.reason -eq 'rejected' -and -not [string]::IsNullOrWhiteSpace([string]$validation.responsePreview)) {
            Write-Warning ("Saved token was rejected. Full API response preview (credential fields redacted):`n" + [string]$validation.responsePreview)
        }
        $loginJson = & $PSCommandPath -Action InteractiveLogin -Environment $Environment -ConfigRoot $root
        $login = $loginJson | ConvertFrom-Json
        [pscustomobject]@{
            status='auth_ready'; environment=$Environment; valid=$true; reason='interactive_login'
            tokenSaved=([bool]$login.tokenSaved); previousTokenReason=[string]$validation.reason
        } | ConvertTo-Json -Compress
        return
    }

    if ($Action -eq 'Validate') {
        if ([string]::IsNullOrWhiteSpace([string]$environmentConfig.token)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$environmentConfig.pucId)) {
                Clear-EnvironmentAuth
            }
            [pscustomobject]@{status='token_checked';environment=$Environment;valid=$false;reason='missing'} | ConvertTo-Json -Compress
            return
        }
        $token = [string]$environmentConfig.token
        $headers = @{Accept='application/json, text/plain, */*';([string]$adapter.token.headerName)=([string]$adapter.token.prefix+$token)}
        $body = [ordered]@{cmd_name='role_request';puc_id=[string]$environmentConfig.pucId;user_id=[string]$environmentConfig.adminAccount;realm=[string]$environmentConfig.realm}
        try { $response = Invoke-JsonRequest -Body $body -Headers $headers }
        catch {
            $statusCode = $null
            if ($_.Exception.Data.Contains('PucHttpStatusCode')) { $statusCode = [int]$_.Exception.Data['PucHttpStatusCode'] }
            elseif ($_.Exception.Response) { try{$statusCode=[int]$_.Exception.Response.StatusCode}catch{$statusCode=$null} }
            if ($statusCode -notin @(401,403)) { throw }
            Clear-EnvironmentAuth
            [pscustomobject]@{
                status='token_checked';environment=$Environment;valid=$false;reason='rejected';httpStatus=$statusCode
                responsePreview=$(if ($_.Exception.Data.Contains('PucHttpResponsePreview')) { [string]$_.Exception.Data['PucHttpResponsePreview'] } else { '' })
            } | ConvertTo-Json -Compress
            return
        }
        $resultProperty = $response.PSObject.Properties['result']
        if ($null -eq $resultProperty) { throw 'Saved-token validation returned a response without result; the token was preserved.' }
        if ([string]$resultProperty.Value -eq '0') {
            [pscustomobject]@{status='token_checked';environment=$Environment;valid=$true;reason=''} | ConvertTo-Json -Compress
            return
        }
        if (-not (Test-PucSavedTokenRejected -Response $response)) {
            throw (New-PucApiFailureMessage -Operation 'Saved-token validation' -Response $response)
        }
        Clear-EnvironmentAuth
        [pscustomobject]@{
            status='token_checked';environment=$Environment;valid=$false;reason='rejected'
            result=[string]$response.result;msg=[string]$response.msg
            responsePreview=Format-PucApiResponsePreview -Response $response
        } | ConvertTo-Json -Compress
        return
    }

    $runtime = Get-PucRuntimeEntry -ConfigRoot $root -Name $Environment
    $pendingLogin = Get-PucPropertyPath -Object $runtime -Path 'pendingLogin'
    if ($Action -in @('InteractiveLogin','Captcha')) {
        [void](Test-PucConfigWriteAccess -ConfigRoot $root)
        [void](Resolve-PucNodeExecutable)
        if ($Action -eq 'InteractiveLogin' -and -not [Environment]::UserInteractive) {
            throw 'Interactive login requires a visible desktop session. Run this command with desktop/GUI permission.'
        }
        if ($null -ne $pendingLogin) {
            $oldSessionId = [string](Get-PucPropertyPath -Object $pendingLogin -Path 'sessionId')
            $oldProcessId = [int](Get-PucPropertyPath -Object $pendingLogin -Path 'processId')
            $oldProcess = Get-Process -Id $oldProcessId -ErrorAction SilentlyContinue
            if ($null -ne $oldProcess -and -not $oldProcess.HasExited) {
                throw "A login worker is already waiting for captcha input for environment '$Environment'."
            }
            Clear-PendingLogin $oldSessionId
        }
        $sessionId = [guid]::NewGuid().ToString('N')
        $paths = Get-SessionPaths $sessionId
        New-Item -ItemType Directory -Force -Path $paths.Directory | Out-Null
        $workerPath = Join-Path $PSScriptRoot 'PucLoginWorker.ps1'
        $interactiveArgument = if ($Action -eq 'InteractiveLogin') { ' -Interactive' } else { '' }
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$workerPath`" -Environment `"$Environment`" -SessionId $sessionId -ConfigRoot `"$root`" -InputTimeoutSeconds 55$interactiveArgument"
        $windowStyle = 'Hidden'
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle $windowStyle -RedirectStandardError $paths.Error -PassThru
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
        while (-not (Test-Path -LiteralPath $paths.Ready)) {
            if (Test-Path -LiteralPath $paths.Result) {
                $failure = Get-Content -Raw -LiteralPath $paths.Result | ConvertFrom-Json
                Clear-PendingLogin $sessionId
                throw "Captcha worker failed: $([string]$failure.detail)"
            }
            if ($process.HasExited) {
                $workerError = if (Test-Path -LiteralPath $paths.Error) { (Get-Content -Raw -LiteralPath $paths.Error).Trim() } else { '' }
                Clear-PendingLogin $sessionId
                if ($workerError) { throw "Captcha worker exited before returning a captcha (exit code $($process.ExitCode)): $workerError" }
                throw "Captcha worker exited before returning a captcha (exit code $($process.ExitCode))."
            }
            if ([DateTimeOffset]::UtcNow -ge $deadline) {
                throw 'Captcha worker did not become ready within 30 seconds.'
            }
            Start-Sleep -Milliseconds 100
            $process.Refresh()
        }
        $ready = Get-Content -Raw -LiteralPath $paths.Ready | ConvertFrom-Json
        $pending = [ordered]@{
            sessionId=$sessionId; processId=$process.Id; processStartTime=$process.StartTime.ToUniversalTime().ToString('o')
            fetchedAt=[string]$ready.fetchedAt
        }
        Set-PucRuntimeEntry -ConfigRoot $root -Name $Environment -Entry (New-RuntimeEntry -PendingLogin $pending)
        if ($Action -eq 'InteractiveLogin') {
            $resultDeadline = [DateTimeOffset]::Parse([string]$ready.fetchedAt).AddSeconds(65)
            while (-not (Test-Path -LiteralPath $paths.Result)) {
                if ([DateTimeOffset]::UtcNow -ge $resultDeadline) {
                    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
                    Clear-PendingLogin $sessionId
                    throw 'Interactive login did not finish before the captcha expired. No retry was attempted.'
                }
                Start-Sleep -Milliseconds 100
            }
            $result = Get-Content -Raw -LiteralPath $paths.Result | ConvertFrom-Json
            try { $process.WaitForExit(5000) | Out-Null } catch {}
            Clear-PendingLogin $sessionId
            if ([string]$result.status -ne 'login_succeeded') {
                $parts = @()
                if (-not [string]::IsNullOrWhiteSpace([string]$result.result)) { $parts += "result=$([string]$result.result)" }
                if (-not [string]::IsNullOrWhiteSpace([string]$result.msg)) { $parts += "msg=$([string]$result.msg)" }
                if (-not [string]::IsNullOrWhiteSpace([string]$result.responsePreview)) { $parts += "Full API response preview (credential fields redacted):`n$([string]$result.responsePreview)" }
                if ($parts.Count -eq 0) { $parts += [string]$result.detail }
                throw ('Login was rejected: ' + ($parts -join '; ') + '. No retry was attempted.')
            }
            [pscustomobject]@{status='login_succeeded';environment=$Environment;tokenSaved=$true;sameProcess=$true;interactive=$true} | ConvertTo-Json -Compress
            return
        }
        [pscustomobject]@{status='captcha_ready';environment=$Environment;imagePath=[string]$ready.imagePath;sessionId=$sessionId;workerProcessId=$process.Id} | ConvertTo-Json -Compress
        return
    }

    if ([string]::IsNullOrWhiteSpace($CaptchaValue)) { throw 'CaptchaValue is required for login.' }
    if ($null -eq $pendingLogin) { throw 'No pending same-process login exists. Fetch a fresh captcha first.' }
    $sessionId = [string](Get-PucPropertyPath -Object $pendingLogin -Path 'sessionId')
    $paths = Get-SessionPaths $sessionId
    if (Test-Path -LiteralPath $paths.Result) {
        $earlyResult = Get-Content -Raw -LiteralPath $paths.Result | ConvertFrom-Json
        Clear-PendingLogin $sessionId
        throw "Login worker is no longer waiting: $([string]$earlyResult.detail)"
    }
    $processId = [int](Get-PucPropertyPath -Object $pendingLogin -Path 'processId')
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $process -or $process.HasExited) {
        Clear-PendingLogin $sessionId
        throw 'The same-process login worker is no longer running. Fetch a fresh captcha before another explicit attempt.'
    }
    $inputDocument = [ordered]@{captchaValue=Protect-PucString $CaptchaValue;submittedAt=[DateTimeOffset]::UtcNow.ToString('o')}
    Write-AtomicJson -Path $paths.Input -Value $inputDocument
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(60)
    while (-not (Test-Path -LiteralPath $paths.Result)) {
        if ([DateTimeOffset]::UtcNow -ge $deadline) { throw 'Login worker did not return a result within 60 seconds; no retry was attempted.' }
        Start-Sleep -Milliseconds 100
    }
    $result = Get-Content -Raw -LiteralPath $paths.Result | ConvertFrom-Json
    try { $process.WaitForExit(5000) | Out-Null } catch {}
    Clear-PendingLogin $sessionId
    if ([string]$result.status -ne 'login_succeeded') {
        $parts = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$result.result)) { $parts += "result=$([string]$result.result)" }
        if (-not [string]::IsNullOrWhiteSpace([string]$result.msg)) { $parts += "msg=$([string]$result.msg)" }
        if (-not [string]::IsNullOrWhiteSpace([string]$result.responsePreview)) { $parts += "Full API response preview (credential fields redacted):`n$([string]$result.responsePreview)" }
        if ($parts.Count -eq 0) { $parts += [string]$result.detail }
        throw ('Login was rejected: ' + ($parts -join '; ') + '. No retry was attempted.')
    }
    [pscustomobject]@{status='login_succeeded';environment=$Environment;tokenSaved=$true;sameProcess=$true} | ConvertTo-Json -Compress
} finally {}
