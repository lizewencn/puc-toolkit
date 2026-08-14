[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$SessionId,
    [Parameter(Mandatory)][string]$ConfigRoot,
    [ValidateRange(10,55)][int]$InputTimeoutSeconds = 55,
    [switch]$Interactive
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$root = Get-PucConfigRoot $ConfigRoot
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
$adapter = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\references\accounts-adapter.json') | ConvertFrom-Json
$baseUri = [uri]$environmentConfig.baseUrl
$sessionDirectory = Join-Path (Join-Path $root 'login-runtime') $SessionId
$readyPath = Join-Path $sessionDirectory 'ready.json'
$inputPath = Join-Path $sessionDirectory 'input.json'
$resultPath = Join-Path $sessionDirectory 'result.json'
$imagePath = Join-Path $root ("captcha-$SessionId.png")
New-Item -ItemType Directory -Force -Path $sessionDirectory | Out-Null

function Write-AtomicJson([string]$Path, $Value) {
    $temporaryPath = $Path + '.tmp'
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Get-ResponseFailureSummary($Response) {
    $parts = @()
    foreach ($name in @('result','error_code','errorCode','msg','message','reason')) {
        if ($null -eq $Response -or $null -eq $Response.PSObject.Properties[$name]) { continue }
        $value = [string]$Response.$name
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $value = ($value -replace '[\r\n]+',' ').Trim()
        if ($value.Length -gt 500) { $value = $value.Substring(0,500) + '...' }
        $parts += "$name=$value"
    }
    if ($parts.Count -eq 0) { return 'server returned no success result or token' }
    return ($parts -join '; ')
}

function Set-EnvironmentAuth([string]$Token, [string]$PucId) {
    $configPath = Join-Path $root 'config.json'
    $document = Read-PucJson -Path $configPath -Default $null
    $entry = Get-PucEntry -Document $document -Name $Environment
    if ($null -eq $entry) { throw "Environment '$Environment' no longer exists in config.json." }
    $entry | Add-Member -NotePropertyName token -NotePropertyValue $Token -Force
    $entry | Add-Member -NotePropertyName pucId -NotePropertyValue $PucId -Force
    Write-PucJson -Path $configPath -Value (Set-PucEntry -Document $document -Name $Environment -Entry $entry)
}

function Read-CaptchaInteractively([string]$ImagePath, [DateTimeOffset]$Deadline) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PucConsoleWindow {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@
    $consoleHandle = [PucConsoleWindow]::GetConsoleWindow()
    if ($consoleHandle -ne [IntPtr]::Zero) { [PucConsoleWindow]::ShowWindow($consoleHandle,0) | Out-Null }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'PUC Login Verification'
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.ClientSize = New-Object System.Drawing.Size(360,190)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = 'Enter the captcha before it expires.'
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point(24,18)
    $form.Controls.Add($titleLabel)

    $picture = New-Object System.Windows.Forms.PictureBox
    $picture.Location = New-Object System.Drawing.Point(24,52)
    $picture.Size = New-Object System.Drawing.Size(120,34)
    $picture.SizeMode = 'StretchImage'
    $imageBytes = [IO.File]::ReadAllBytes($ImagePath)
    $imageStream = New-Object IO.MemoryStream(,$imageBytes)
    $sourceImage = [Drawing.Image]::FromStream($imageStream)
    $picture.Image = New-Object Drawing.Bitmap($sourceImage)
    $sourceImage.Dispose()
    $imageStream.Dispose()
    $form.Controls.Add($picture)

    $captchaTextBox = New-Object System.Windows.Forms.TextBox
    $captchaTextBox.Location = New-Object System.Drawing.Point(164,52)
    $captchaTextBox.Size = New-Object System.Drawing.Size(170,28)
    $captchaTextBox.Font = New-Object System.Drawing.Font('Segoe UI',12)
    $captchaTextBox.MaxLength = 16
    $form.Controls.Add($captchaTextBox)

    $countdown = New-Object System.Windows.Forms.Label
    $countdown.AutoSize = $true
    $countdown.Location = New-Object System.Drawing.Point(24,105)
    $form.Controls.Add($countdown)

    $submit = New-Object System.Windows.Forms.Button
    $submit.Text = 'Login'
    $submit.Location = New-Object System.Drawing.Point(164,130)
    $submit.Size = New-Object System.Drawing.Size(80,30)
    $form.Controls.Add($submit)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(254,130)
    $cancel.Size = New-Object System.Drawing.Size(80,30)
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({
        $remaining = [Math]::Max(0,[Math]::Ceiling(($Deadline - [DateTimeOffset]::UtcNow).TotalSeconds))
        $countdown.Text = "Expires in $remaining seconds"
        if ($remaining -le 0) {
            $timer.Stop()
            $form.Tag = 'expired'
            $form.Close()
        }
    })
    $submit.Add_Click({
        if ([string]::IsNullOrWhiteSpace($captchaTextBox.Text)) {
            [Windows.Forms.MessageBox]::Show('Enter the captcha first.','PUC Login') | Out-Null
            return
        }
        $timer.Stop()
        $form.Tag = $captchaTextBox.Text.Trim()
        $form.DialogResult = [Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.AcceptButton = $submit
    $form.CancelButton = $cancel
    $form.Add_Shown({ $captchaTextBox.Focus(); $timer.Start() })

    try {
        $dialogResult = $form.ShowDialog()
        if ([string]$form.Tag -eq 'expired' -or [DateTimeOffset]::UtcNow -ge $Deadline) {
            throw 'Captcha expired before submission (55-second client deadline).'
        }
        if ($dialogResult -ne [Windows.Forms.DialogResult]::OK) {
            throw 'Captcha entry was cancelled.'
        }
        return [string]$form.Tag
    } finally {
        $timer.Stop()
        if ($null -ne $picture.Image) { $picture.Image.Dispose() }
        $form.Dispose()
    }
}

try {
    [void](Test-PucConfigWriteAccess -ConfigRoot $root)
    $cookieJar = @{}
    function Invoke-JsonRequest($Body) {
        return Invoke-PucJsonRequest -Uri ([uri]($baseUri.AbsoluteUri.TrimEnd('/') + '/confs')) -Body $Body -AllowInsecureTls ([bool]$environmentConfig.allowInsecureTls) -CookieJar $cookieJar
    }

    # Match the working manager: common configuration, captcha, user input, then login in one process.
    $common = Invoke-JsonRequest ([ordered]@{ cmd_name='common_cfg_request' })
    $pucId = [string](Get-PucPropertyPath -Object $common -Path ([string]$adapter.pucId.responsePath))
    if ([string]::IsNullOrWhiteSpace($pucId)) { throw 'Common configuration did not return a PUC ID.' }

    $captcha = Invoke-JsonRequest ([ordered]@{ cmd_name='puc_get_captcha'; height=34; width=120 })
    $captchaFetchedAt = [DateTimeOffset]::UtcNow
    $captchaId = [string](Get-PucPropertyPath -Object $captcha -Path ([string]$adapter.captcha.idResponsePath))
    $captchaImage = [string](Get-PucPropertyPath -Object $captcha -Path ([string]$adapter.captcha.imageResponsePath))
    if ([string]::IsNullOrWhiteSpace($captchaId) -or [string]::IsNullOrWhiteSpace($captchaImage)) {
        throw 'Captcha response is incomplete.'
    }
    $encoded = if ($captchaImage.Contains(',')) { $captchaImage.Substring($captchaImage.IndexOf(',') + 1) } else { $captchaImage }
    [IO.File]::WriteAllBytes($imagePath,[Convert]::FromBase64String($encoded))
    Write-AtomicJson -Path $readyPath -Value ([ordered]@{
        status='captcha_ready'; environment=$Environment; sessionId=$SessionId; processId=$PID
        imagePath=$imagePath; fetchedAt=$captchaFetchedAt.ToString('o'); expiresAt=$captchaFetchedAt.AddSeconds(60).ToString('o')
    })

    $deadline = $captchaFetchedAt.AddSeconds($InputTimeoutSeconds)
    if ($Interactive) {
        $captchaValue = Read-CaptchaInteractively -ImagePath $imagePath -Deadline $deadline
    } else {
        while (-not (Test-Path -LiteralPath $inputPath)) {
            if ([DateTimeOffset]::UtcNow -ge $deadline) { throw "Captcha input timed out after $InputTimeoutSeconds seconds." }
            Start-Sleep -Milliseconds 200
        }
        $inputDocument = Get-Content -Raw -LiteralPath $inputPath | ConvertFrom-Json
        Remove-Item -LiteralPath $inputPath -Force
        $captchaValue = Unprotect-PucString ([string]$inputDocument.captchaValue)
    }
    if ([string]::IsNullOrWhiteSpace($captchaValue)) { throw 'Captcha value is empty.' }
    if ([DateTimeOffset]::UtcNow -ge $deadline) { throw 'Captcha expired before the login request was sent.' }

    $password = [string]$environmentConfig.adminPassword
    if ([string]::IsNullOrWhiteSpace($password)) { throw "adminPassword is empty for environment '$Environment'." }
    $response = Invoke-JsonRequest ([ordered]@{
        realm=[string]$environmentConfig.realm
        puc_account=[string]$environmentConfig.adminAccount
        puc_passwd=ConvertTo-PucDesHex $password
        captcha_id=$captchaId
        captcha_value=$captchaValue
        puc_id=$pucId
        cmd_name='login_puc_account'
    })
    if ([string]$response.result -ne '0' -or [string]::IsNullOrWhiteSpace([string]$response.token)) {
        Write-AtomicJson -Path $resultPath -Value ([ordered]@{
            status='failed'; environment=$Environment; result=[string]$response.result
            msg=[string]$response.msg; detail=Get-ResponseFailureSummary $response
            responsePreview=Format-PucApiResponsePreview -Response $response
        })
        return
    }
    Set-EnvironmentAuth -Token ([string]$response.token) -PucId $pucId
    Write-AtomicJson -Path $resultPath -Value ([ordered]@{
        status='login_succeeded'; environment=$Environment; tokenSaved=$true
    })
} catch {
    Write-AtomicJson -Path $resultPath -Value ([ordered]@{
        status='failed'; environment=$Environment; result=''; msg=$_.Exception.Message; detail=$_.Exception.Message
    })
} finally {}
