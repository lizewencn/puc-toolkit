$ErrorActionPreference = 'Stop'

function Get-PucPropertyPath($Object, [string]$Path) {
    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        $current = $current.$part
    }
    return $current
}

function Invoke-PucJsonRequest([string]$Uri, $Body, [bool]$AllowInsecureTls) {
    $params = @{
        Method = 'POST'
        Uri = $Uri
        Headers = @{ Accept = 'application/json, text/plain, */*' }
        ContentType = 'application/json'
        Body = $Body | ConvertTo-Json -Depth 30 -Compress
    }
    if ($AllowInsecureTls -and (Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')) {
        $params.SkipCertificateCheck = $true
    }
    return Invoke-RestMethod @params
}

function Connect-PucSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$LoginConfig,
        [Parameter(Mandatory)]$Adapter,
        [string]$CaptchaValue,
        [Parameter(Mandatory)][string]$CaptchaImagePath
    )

    $baseUrl = "$($LoginConfig.scheme)://$($LoginConfig.serverIp):$($LoginConfig.port)"
    $uri = $baseUrl.TrimEnd('/') + [string]$Adapter.operations.login.path
    $oldCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
    $callbackChanged = $false
    try {
        if ($LoginConfig.allowInsecureTls -eq $true -and -not (Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')) {
            [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            $callbackChanged = $true
        }
        $commonOperation = $Adapter.operations.commonConfig
        if ($null -eq $commonOperation) { throw 'Adapter does not define the commonConfig operation required to discover the PUC ID.' }
        $commonUri = $baseUrl.TrimEnd('/') + [string]$commonOperation.path
        $commonResponse = Invoke-PucJsonRequest -Uri $commonUri -Body $commonOperation.bodyTemplate -AllowInsecureTls ($LoginConfig.allowInsecureTls -eq $true)
        $pucId = [string](Get-PucPropertyPath $commonResponse ([string]$Adapter.pucId.responsePath))
        if ([string]::IsNullOrWhiteSpace($pucId)) { throw 'Common configuration response did not return a PUC ID.' }

        if ([string]::IsNullOrWhiteSpace($CaptchaValue)) {
            $captcha = Invoke-PucJsonRequest -Uri $uri -Body $Adapter.operations.captcha.bodyTemplate -AllowInsecureTls ($LoginConfig.allowInsecureTls -eq $true)
            $captchaId = Get-PucPropertyPath $captcha ([string]$Adapter.captcha.idResponsePath)
            $captchaImage = [string](Get-PucPropertyPath $captcha ([string]$Adapter.captcha.imageResponsePath))
            if (-not $captchaId -or [string]::IsNullOrWhiteSpace($captchaImage)) { throw 'Captcha response is incomplete.' }
            $directory = Split-Path -Parent $CaptchaImagePath
            if ($directory) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
            $base64 = if ($captchaImage.Contains(',')) { $captchaImage.Substring($captchaImage.IndexOf(',') + 1) } else { $captchaImage }
            [IO.File]::WriteAllBytes($CaptchaImagePath, [Convert]::FromBase64String($base64))
            try { Start-Process -FilePath $CaptchaImagePath | Out-Null } catch { Write-Warning "Open captcha image manually: $CaptchaImagePath" }
            $CaptchaValue = Read-Host 'Enter the captcha shown in the image'
        } else {
            throw 'CaptchaValue requires an existing captcha ID; use interactive login or PUC_TOKEN.'
        }
        if ([string]::IsNullOrWhiteSpace($CaptchaValue)) { throw 'Captcha value is required.' }
        $body = [ordered]@{
            realm = [string]$LoginConfig.realm
            puc_account = [string]$LoginConfig.adminUser
            puc_passwd = [string]$LoginConfig.adminPassword
            captcha_id = $captchaId
            captcha_value = $CaptchaValue
            puc_id = $pucId
            cmd_name = 'login_puc_account'
        }
        $response = Invoke-PucJsonRequest -Uri $uri -Body $body -AllowInsecureTls ($LoginConfig.allowInsecureTls -eq $true)
        $success = Get-PucPropertyPath $response ([string]$Adapter.operations.login.selectors.success)
        if ([string]$success -ne [string]$Adapter.operations.login.selectors.successExpected) { throw 'Login API response reported failure.' }
        $token = [string](Get-PucPropertyPath $response ([string]$Adapter.token.responsePath))
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'Authentication did not return a token.' }
        [pscustomobject]@{ Token = $token; User = [string]$LoginConfig.adminUser; BaseUrl = $baseUrl; PucId = $pucId }
    } finally {
        if ($callbackChanged) { [Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCallback }
    }
}

Export-ModuleMember -Function Connect-PucSession
