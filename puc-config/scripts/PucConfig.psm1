Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PucDefaultConfigRoot {
    return Join-Path ([Environment]::GetFolderPath('Desktop')) 'agentSkillLocalConfig\puc-config'
}

function Get-PucSettingsPath {
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData)) { throw 'Windows LocalApplicationData is unavailable.' }
    return Join-Path $localAppData 'puc-config\setting.json'
}

function Get-PucConfigRoot {
    param([string]$ConfigRoot)
    if (-not [string]::IsNullOrWhiteSpace($ConfigRoot)) { return [IO.Path]::GetFullPath($ConfigRoot) }

    $settingsPath = Get-PucSettingsPath
    $settings = Read-PucJson -Path $settingsPath -Default $null
    if ($null -eq $settings -or [string]::IsNullOrWhiteSpace([string]$settings.configRoot)) {
        $defaultRoot = Get-PucDefaultConfigRoot
        throw "PUC config path is empty in '$settingsPath'. Confirm whether to use the default path '$defaultRoot' or choose another path, then run Set-PucConfigRoot.ps1."
    }
    return [IO.Path]::GetFullPath([string]$settings.configRoot)
}

function Read-PucJson {
    param([Parameter(Mandatory)][string]$Path, $Default)
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Write-PucJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $temporaryPath = $resolvedPath + '.tmp.' + [guid]::NewGuid().ToString('N')
    $backupPath = $resolvedPath + '.backup.' + [guid]::NewGuid().ToString('N')
    try {
        $json = $Value | ConvertTo-Json -Depth 30
        [IO.File]::WriteAllText($temporaryPath,$json,[Text.UTF8Encoding]::new($true))
        [void](Get-Content -Raw -LiteralPath $temporaryPath | ConvertFrom-Json)
        if (Test-Path -LiteralPath $resolvedPath) {
            [IO.File]::Replace($temporaryPath,$resolvedPath,$backupPath,$true)
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        } else {
            [IO.File]::Move($temporaryPath,$resolvedPath)
        }
    } catch {
        if (Test-Path -LiteralPath $backupPath) {
            if (-not (Test-Path -LiteralPath $resolvedPath)) { [IO.File]::Move($backupPath,$resolvedPath) }
        }
        throw
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-PucNodeExecutable {
    if (-not [string]::IsNullOrWhiteSpace($env:PUC_NODE_EXE)) {
        $explicit = [IO.Path]::GetFullPath($env:PUC_NODE_EXE)
        if (-not (Test-Path -LiteralPath $explicit -PathType Leaf)) { throw "PUC_NODE_EXE does not exist: $explicit" }
        return $explicit
    }
    $command = Get-Command node.exe,node -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    $bundled = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
    if (Test-Path -LiteralPath $bundled -PathType Leaf) { return $bundled }
    throw 'Node.js is required for PUC HTTPS transport. Install Node.js or set PUC_NODE_EXE to node.exe.'
}

function Update-PucCookieJar {
    param([hashtable]$CookieJar, [object[]]$SetCookieHeaders)
    if ($null -eq $CookieJar) { return }
    foreach ($header in @($SetCookieHeaders)) {
        $pair = ([string]$header).Split(';',2)[0]
        $separator = $pair.IndexOf('=')
        if ($separator -le 0) { continue }
        $name = $pair.Substring(0,$separator).Trim()
        $value = $pair.Substring($separator + 1).Trim()
        if ($value) { $CookieJar[$name] = $value } else { $CookieJar.Remove($name) }
    }
}

function Invoke-PucHttpRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','DELETE','HEAD')][string]$Method,
        [Parameter(Mandatory)][uri]$Uri,
        [hashtable]$Headers = @{},
        [byte[]]$Body = @(),
        [bool]$AllowInsecureTls = $false,
        [ValidateRange(1,300)][int]$TimeoutSec = 60,
        [hashtable]$CookieJar
    )
    $effectiveHeaders = @{}
    foreach ($key in $Headers.Keys) { $effectiveHeaders[[string]$key] = [string]$Headers[$key] }
    if ($null -ne $CookieJar -and $CookieJar.Count -gt 0) {
        $effectiveHeaders['Cookie'] = (($CookieJar.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')
    }
    if ($Body.Count -gt 0 -and -not $effectiveHeaders.ContainsKey('Content-Length')) { $effectiveHeaders['Content-Length'] = [string]$Body.Count }
    $descriptor = [ordered]@{
        method=$Method; uri=$Uri.AbsoluteUri; headers=$effectiveHeaders
        bodyBase64=[Convert]::ToBase64String($Body); allowInsecureTls=$AllowInsecureTls; timeoutMs=$TimeoutSec*1000
    }
    $transportSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'PucHttpTransport.js'),[Text.Encoding]::UTF8)
    $transportBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($transportSource))
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Resolve-PucNodeExecutable
    $startInfo.Arguments = '-e "eval(Buffer.from(''' + $transportBase64 + ''',''base64'').toString(''utf8''))"'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Could not start the PUC HTTP transport.' }
        $process.StandardInput.Write(($descriptor | ConvertTo-Json -Depth 10 -Compress))
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw $(if ($stderr.Trim()) { $stderr.Trim() } else { 'PUC HTTP transport failed without an error message.' }) }
        $result = $stdout | ConvertFrom-Json
        if ([int]$result.statusCode -lt 200 -or [int]$result.statusCode -ge 300) {
            $exception = [InvalidOperationException]::new("PUC HTTP request failed: HTTP $([int]$result.statusCode) $([string]$result.statusMessage).")
            $exception.Data['PucHttpStatusCode'] = [int]$result.statusCode
            $exception.Data['PucHttpStatusMessage'] = [string]$result.statusMessage
            try {
                $bodyBytes = [Convert]::FromBase64String([string]$result.bodyBase64)
                if ($bodyBytes.Count -gt 0) {
                    $bodyText = [Text.Encoding]::UTF8.GetString($bodyBytes)
                    $bodyValue = ConvertFrom-PucResponseEncoding -Value ($bodyText | ConvertFrom-Json)
                    $exception.Data['PucHttpResponsePreview'] = Format-PucApiResponsePreview -Response $bodyValue
                }
            } catch {}
            throw $exception
        }
        $setCookie = @()
        if ($null -ne $result.headers -and $null -ne $result.headers.PSObject.Properties['set-cookie']) { $setCookie = @($result.headers.'set-cookie') }
        Update-PucCookieJar -CookieJar $CookieJar -SetCookieHeaders $setCookie
        return [pscustomobject]@{
            StatusCode=[int]$result.statusCode; Headers=$result.headers; TlsProtocol=[string]$result.tlsProtocol
            BodyBytes=[Convert]::FromBase64String([string]$result.bodyBase64)
        }
    } finally { $process.Dispose() }
}

function Invoke-PucJsonRequest {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)]$Body,
        [hashtable]$Headers = @{},
        [bool]$AllowInsecureTls = $false,
        [ValidateRange(1,300)][int]$TimeoutSec = 60,
        [hashtable]$CookieJar,
        [ValidateRange(2,100)][int]$Depth = 30
    )
    return Invoke-PucJsonHttpRequest -Method POST -Uri $Uri -Body $Body -Headers $Headers -AllowInsecureTls $AllowInsecureTls -TimeoutSec $TimeoutSec -CookieJar $CookieJar -Depth $Depth
}

function ConvertFrom-PucJsonHttpResponse {
    param([AllowNull()]$Response)
    if ($null -eq $Response -or $null -eq $Response.BodyBytes -or $Response.BodyBytes.Count -eq 0) { return $null }
    $text = [Text.Encoding]::UTF8.GetString($Response.BodyBytes)
    try { return ConvertFrom-PucResponseEncoding -Value ($text | ConvertFrom-Json) }
    catch { throw "PUC response is not valid JSON: $($_.Exception.Message)" }
}

function Invoke-PucJsonHttpRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','DELETE','HEAD')][string]$Method,
        [Parameter(Mandatory)][uri]$Uri,
        $Body,
        [hashtable]$Headers = @{},
        [bool]$AllowInsecureTls = $false,
        [ValidateRange(1,300)][int]$TimeoutSec = 60,
        [hashtable]$CookieJar,
        [ValidateRange(2,100)][int]$Depth = 30
    )
    $effectiveHeaders = @{ Accept='application/json, text/plain, */*' }
    foreach ($key in $Headers.Keys) { $effectiveHeaders[[string]$key] = [string]$Headers[$key] }
    [byte[]]$bodyBytes = @()
    if ($null -ne $Body) {
        $effectiveHeaders['Content-Type'] = 'application/json; charset=utf-8'
        $bodyBytes = ConvertTo-PucJsonBytes -Value $Body -Depth $Depth
    }
    $response = Invoke-PucHttpRequest -Method $Method -Uri $Uri -Headers $effectiveHeaders -Body $bodyBytes -AllowInsecureTls $AllowInsecureTls -TimeoutSec $TimeoutSec -CookieJar $CookieJar
    return ConvertFrom-PucJsonHttpResponse -Response $response
}

function New-PucMultipartFormData {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Fields,
        [object[]]$Files = @()
    )
    $boundary = '----------------PucConfig' + [guid]::NewGuid().ToString('N')
    $stream = [IO.MemoryStream]::new()
    try {
        foreach ($entry in $Fields.GetEnumerator()) {
            $name = [string]$entry.Key
            if ($name -match '["\r\n]') { throw "Invalid multipart field name: $name" }
            $header = "--$boundary`r`nContent-Disposition: form-data; name=`"$name`"`r`n`r`n$([string]$entry.Value)`r`n"
            $bytes = [Text.Encoding]::UTF8.GetBytes($header)
            $stream.Write($bytes,0,$bytes.Length)
        }
        foreach ($file in @($Files)) {
            $name = [string]$file.Name
            $fileName = [string]$file.FileName
            $contentType = [string]$file.ContentType
            if ($name -match '["\r\n]' -or $fileName -match '["\r\n]') { throw 'Invalid multipart file name.' }
            if ([string]::IsNullOrWhiteSpace($contentType)) { $contentType = 'application/octet-stream' }
            $header = "--$boundary`r`nContent-Disposition: form-data; name=`"$name`"; filename=`"$fileName`"`r`nContent-Type: $contentType`r`n`r`n"
            $headerBytes = [Text.Encoding]::UTF8.GetBytes($header)
            $stream.Write($headerBytes,0,$headerBytes.Length)
            [byte[]]$fileBytes = @($file.Bytes)
            $stream.Write($fileBytes,0,$fileBytes.Length)
            $footerBytes = [Text.Encoding]::UTF8.GetBytes("`r`n")
            $stream.Write($footerBytes,0,$footerBytes.Length)
        }
        $endBytes = [Text.Encoding]::UTF8.GetBytes("--$boundary--`r`n")
        $stream.Write($endBytes,0,$endBytes.Length)
        return [pscustomobject]@{ ContentType="multipart/form-data; boundary=$boundary"; BodyBytes=$stream.ToArray() }
    } finally { $stream.Dispose() }
}

function Write-PucBytesAtomically {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][byte[]]$Bytes)
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $resolvedPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $temporaryPath = $resolvedPath + '.tmp.' + [guid]::NewGuid().ToString('N')
    $backupPath = $resolvedPath + '.backup.' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllBytes($temporaryPath,$Bytes)
        if (Test-Path -LiteralPath $resolvedPath) {
            [IO.File]::Replace($temporaryPath,$resolvedPath,$backupPath,$true)
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        } else { [IO.File]::Move($temporaryPath,$resolvedPath) }
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-PucEnvironment {
    param([Parameter(Mandatory)][string]$ConfigRoot, [Parameter(Mandatory)][string]$Name)
    $path = Join-Path $ConfigRoot 'config.json'
    $config = Read-PucJson -Path $path -Default $null
    if ($null -eq $config) { throw "Missing config file: $path" }
    $matches = @($config.environments | Where-Object { $_.name -eq $Name })
    if ($matches.Count -ne 1) { throw "Environment '$Name' resolved to $($matches.Count) entries in $path" }
    return $matches[0]
}

function Test-PucConfigWriteAccess {
    param([Parameter(Mandatory)][string]$ConfigRoot)
    if (-not (Test-Path -LiteralPath $ConfigRoot -PathType Container)) { throw "PUC config root does not exist: $ConfigRoot" }
    $probe = Join-Path $ConfigRoot ('.write-test-' + [guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllBytes($probe,[byte[]]@(0x50,0x55,0x43)) }
    catch { throw "PUC config root is not writable: $ConfigRoot. Obtain write approval before login or configuration changes. $($_.Exception.Message)" }
    finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
    return $true
}

function Get-PucEntry {
    param($Document, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Document) { return $null }
    return @($Document.environments | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
}

function Set-PucEntry {
    param($Document, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Entry)
    $items = @()
    if ($null -ne $Document -and $null -ne $Document.environments) { $items = @($Document.environments | Where-Object { $_.name -ne $Name }) }
    $items += $Entry
    return [ordered]@{ version = 1; environments = $items }
}

function Protect-PucString {
    param([Parameter(Mandatory)][string]$Value)
    return ConvertFrom-SecureString -SecureString (ConvertTo-SecureString -String $Value -AsPlainText -Force)
}

function Unprotect-PucString {
    param([Parameter(Mandatory)][string]$Value)
    $secure = ConvertTo-SecureString -String $Value
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function ConvertTo-PucJsonBytes {
    param(
        [Parameter(Mandatory)]$Value,
        [ValidateRange(2,100)][int]$Depth = 30
    )
    $json = $Value | ConvertTo-Json -Depth $Depth -Compress
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $json.ToCharArray()) {
        $codePoint = [int][char]$character
        if ($codePoint -le 0x7f) {
            [void]$builder.Append($character)
        } else {
            [void]$builder.Append(('\u{0:x4}' -f $codePoint))
        }
    }
    return ,([System.Text.Encoding]::UTF8.GetBytes($builder.ToString()))
}

function ConvertFrom-PucResponseEncoding {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        $hasExtendedByte = $false
        foreach ($character in $Value.ToCharArray()) {
            $codePoint = [int][char]$character
            if ($codePoint -gt 0xff) { return $Value }
            if ($codePoint -gt 0x7f) { $hasExtendedByte = $true }
        }
        if (-not $hasExtendedByte) { return $Value }
        $bytes = New-Object byte[] $Value.Length
        for ($index = 0; $index -lt $Value.Length; $index++) { $bytes[$index] = [byte][char]$Value[$index] }
        try {
            $decoded = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
            return $decoded
        } catch [System.Text.DecoderFallbackException] {
            return $Value
        }
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) { $Value[$key] = ConvertFrom-PucResponseEncoding -Value $Value[$key] }
        return $Value
    }
    if ($Value -is [System.Collections.IList]) {
        for ($index = 0; $index -lt $Value.Count; $index++) { $Value[$index] = ConvertFrom-PucResponseEncoding -Value $Value[$index] }
        return ,$Value
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) { $property.Value = ConvertFrom-PucResponseEncoding -Value $property.Value }
    }
    return $Value
}

function ConvertTo-PucDisplayValue {
    param([AllowNull()]$Value, [string]$PropertyName = '')
    if ($PropertyName -match '(?i)(authorization|cookie|token|password|passwd|pwd|captcha|secret)') {
        if ($null -eq $Value) { return $null }
        return '[REDACTED]'
    }
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) { $copy[[string]$key] = ConvertTo-PucDisplayValue -Value $Value[$key] -PropertyName ([string]$key) }
        return [pscustomobject]$copy
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return ,@($Value | ForEach-Object { ConvertTo-PucDisplayValue -Value $_ })
    }
    if ($Value -is [pscustomobject]) {
        $copy = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $copy[$property.Name] = ConvertTo-PucDisplayValue -Value $property.Value -PropertyName $property.Name
        }
        return [pscustomobject]$copy
    }
    return [string]$Value
}

function Format-PucApiResponsePreview {
    param([AllowNull()]$Response)
    return (ConvertTo-PucDisplayValue -Value $Response | ConvertTo-Json -Depth 100)
}

function New-PucApiFailureMessage {
    param([Parameter(Mandatory)][string]$Operation, [AllowNull()]$Response)
    $preview = Format-PucApiResponsePreview -Response $Response
    return "$Operation failed. Full API response preview (credential fields redacted):`n$preview`nNo retry was attempted."
}

function Test-PucSavedTokenRejected {
    param([AllowNull()]$Response)
    if ($null -eq $Response) { return $false }
    $resultProperty = $Response.PSObject.Properties['result']
    return ($null -ne $resultProperty -and [string]$resultProperty.Value -eq '51800032')
}

function ConvertTo-PucDesHex {
    param([Parameter(Mandatory)][string]$Value)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $key = [Text.Encoding]::UTF8.GetBytes('HytBSoft')
    $des = [Security.Cryptography.DES]::Create()
    try {
        $des.Mode = [Security.Cryptography.CipherMode]::CBC
        $des.Padding = [Security.Cryptography.PaddingMode]::PKCS7
        $des.Key = $key
        $des.IV = $key
        $encrypted = $des.CreateEncryptor().TransformFinalBlock($bytes, 0, $bytes.Length)
        return (($encrypted | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $des.Dispose() }
}

function Get-PucRuntimeEntry {
    param([Parameter(Mandatory)][string]$ConfigRoot, [Parameter(Mandatory)][string]$Name)
    return Get-PucEntry -Document (Read-PucJson -Path (Join-Path $ConfigRoot 'runtime.json') -Default $null) -Name $Name
}

function Set-PucRuntimeEntry {
    param([Parameter(Mandatory)][string]$ConfigRoot, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Entry)
    $path = Join-Path $ConfigRoot 'runtime.json'
    Write-PucJson -Path $path -Value (Set-PucEntry -Document (Read-PucJson -Path $path -Default $null) -Name $Name -Entry $Entry)
}

function Get-PucPropertyPath {
    param($Object, [Parameter(Mandatory)][string]$Path)
    $current = $Object
    foreach ($part in $Path.Split('.')) { if ($null -eq $current) { return $null }; $current = $current.$part }
    return $current
}

Export-ModuleMember -Function Get-PucDefaultConfigRoot,Get-PucSettingsPath,Get-PucConfigRoot,Read-PucJson,Write-PucJson,Get-PucEnvironment,Test-PucConfigWriteAccess,Get-PucEntry,Set-PucEntry,Protect-PucString,Unprotect-PucString,ConvertTo-PucJsonBytes,ConvertFrom-PucResponseEncoding,ConvertTo-PucDisplayValue,Format-PucApiResponsePreview,New-PucApiFailureMessage,Test-PucSavedTokenRejected,ConvertTo-PucDesHex,Get-PucRuntimeEntry,Set-PucRuntimeEntry,Get-PucPropertyPath,Resolve-PucNodeExecutable,Invoke-PucHttpRequest,Invoke-PucJsonRequest,Invoke-PucJsonHttpRequest,ConvertFrom-PucJsonHttpResponse,New-PucMultipartFormData,Write-PucBytesAtomically
