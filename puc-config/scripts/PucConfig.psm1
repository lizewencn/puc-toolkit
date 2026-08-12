Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PucConfigRoot {
    param([string]$ConfigRoot)
    if (-not [string]::IsNullOrWhiteSpace($ConfigRoot)) { return [IO.Path]::GetFullPath($ConfigRoot) }
    return 'F:\puc-word\agentSkillLocalConfig\puc-config'
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
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding UTF8
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

Export-ModuleMember -Function Get-PucConfigRoot,Read-PucJson,Write-PucJson,Get-PucEnvironment,Get-PucEntry,Set-PucEntry,Protect-PucString,Unprotect-PucString,ConvertTo-PucJsonBytes,ConvertFrom-PucResponseEncoding,ConvertTo-PucDesHex,Get-PucRuntimeEntry,Set-PucRuntimeEntry,Get-PucPropertyPath
