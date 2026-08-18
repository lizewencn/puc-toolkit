Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-PucIncidentCodePoints([int[]]$Codes) {
    return -join @($Codes | ForEach-Object { [char]$_ })
}

function Get-PucIncidentAlarmLevelDefinitions {
    $star = ConvertFrom-PucIncidentCodePoints 0x661f,0x6807
    $yellow = ConvertFrom-PucIncidentCodePoints 0x9ec4,0x6807
    $normal = ConvertFrom-PucIncidentCodePoints 0x666e,0x901a
    $warning = ConvertFrom-PucIncidentCodePoints 0x9884,0x8b66
    $instruction = ConvertFrom-PucIncidentCodePoints 0x6307,0x4ee4
    $suffix = ConvertFrom-PucIncidentCodePoints 0x8b66,0x60c5,0x7b49,0x7ea7,0x8bf4,0x660e
    return @(
        [pscustomobject]@{Code='00';Name=$normal;Description=$normal+$suffix;Color='#73cb6d';Tone='MediumAlarm.wav'},
        [pscustomobject]@{Code='01';Name=$star;Description=$star+$suffix;Color='#E56659';Tone='CriticalAlarm.wav'},
        [pscustomobject]@{Code='02';Name=$yellow;Description=$yellow+$suffix;Color='#eba54d';Tone='MediumAlarm.wav'},
        [pscustomobject]@{Code='03';Name=$warning;Description=$warning+$suffix;Color='#73cb6d';Tone='CommonlyAlarm.wav'},
        [pscustomobject]@{Code='04';Name=$instruction;Description=$instruction+$suffix;Color='#73cb6d';Tone='CommonlyAlarm.wav'}
    )
}

function Resolve-PucIncidentAlarmLevelAssets {
    param([Parameter(Mandatory)][string]$AssetDirectory)
    if (-not [IO.Path]::IsPathRooted($AssetDirectory)) { throw 'AssetDirectory must be an absolute path.' }
    $resolvedDirectory = [IO.Path]::GetFullPath($AssetDirectory)
    if (-not (Test-Path -LiteralPath $resolvedDirectory -PathType Container)) { throw "Incident asset directory does not exist: $resolvedDirectory" }
    foreach ($item in @(Get-PucIncidentAlarmLevelDefinitions)) {
        $selected = Join-Path $resolvedDirectory ($item.Name + '.zip')
        if (-not (Test-Path -LiteralPath $selected -PathType Leaf)) { throw "Incident ZIP does not exist for level '$($item.Code)'." }
        [pscustomobject]@{
            Code=$item.Code;Name=$item.Name;Description=$item.Description;Color=$item.Color;Tone=$item.Tone
            ZipPath=[IO.Path]::GetFullPath($selected);ZipFileName=[IO.Path]::GetFileName($selected)
        }
    }
}

function Test-PucIncidentZip {
    param([Parameter(Mandatory)][string]$Path)
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) { throw "ZIP does not exist: $resolvedPath" }
    $file = Get-Item -LiteralPath $resolvedPath
    if ($file.Length -le 0) { throw 'ZIP is empty.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = $null
    try { $archive = [IO.Compression.ZipFile]::OpenRead($resolvedPath) }
    catch { throw "File is not a valid ZIP: $($_.Exception.Message)" }
    try {
        $files = @($archive.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
        if ($files.Count -eq 0) { throw 'ZIP contains no files.' }
        foreach ($entry in $files) {
            $name = [string]$entry.FullName
            $normalized = $name.Replace('\','/')
            if ([IO.Path]::IsPathRooted($name) -or $normalized.StartsWith('/') -or $normalized -match '(^|/)\.\.(/|$)' -or $normalized -match '^[A-Za-z]:') {
                throw "ZIP contains unsafe ZIP entry '$name'."
            }
            if ([IO.Path]::GetExtension($entry.Name) -ine '.svg' -or $entry.Length -le 0) { throw 'ZIP must contain only non-empty SVG files.' }
        }
    } finally { $archive.Dispose() }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($resolvedPath)
        try { $hash = (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '').ToUpperInvariant() }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
    return [pscustomobject]@{Path=$resolvedPath;FileName=$file.Name;Length=$file.Length;Sha256=$hash;EntryCount=$files.Count}
}

function Get-PucIncidentProperty($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = @($Object.PSObject.Properties.Match($Name)) | Select-Object -First 1
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function New-PucIncidentAlarmLevelPreview {
    param(
        [Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][object[]]$Assets,
        [AllowNull()][object[]]$Tones,
        [AllowNull()][object[]]$ExistingLevels
    )
    $toneItems = @($Tones | Where-Object { $null -ne $_ })
    foreach ($requiredTone in @($Assets | ForEach-Object { [string]$_.Tone } | Select-Object -Unique)) {
        $matches = @($toneItems | Where-Object { [string](Get-PucIncidentProperty $_ 'file_name' '') -ceq $requiredTone })
        if ($matches.Count -ne 1) { throw "Tone '$requiredTone' resolved to $($matches.Count) matches; expected exactly one." }
    }
    $levels = @($ExistingLevels | Where-Object { $null -ne $_ })
    $items = foreach ($target in $Assets) {
        $codeMatches = @($levels | Where-Object { [string](Get-PucIncidentProperty $_ 'level_code' '') -ceq [string]$target.Code })
        $nameMatches = @($levels | Where-Object { [string](Get-PucIncidentProperty $_ 'level_name' '') -ceq [string]$target.Name })
        $classification = 'missing'
        $reason = ''
        if ($codeMatches.Count -gt 0 -or $nameMatches.Count -gt 0) {
            $classification = 'conflict'; $reason = 'existing-code-or-name'
        }
        [pscustomobject]@{
            Code=[string]$target.Code;Name=[string]$target.Name;Description=[string]$target.Description
            Color=[string]$target.Color;Tone=[string]$target.Tone;ZipPath=[string]$target.ZipPath
            ZipFileName=[string]$target.ZipFileName;ZipSha256=[string]$target.ZipSha256
            Classification=$classification;Reason=$reason
        }
    }
    $projection = [ordered]@{
        environment=$Environment
        items=@($items | ForEach-Object { [ordered]@{
            code=$_.Code;name=$_.Name;description=$_.Description;color=$_.Color.ToUpperInvariant()
            tone=$_.Tone;zipFileName=$_.ZipFileName;zipSha256=$_.ZipSha256;classification=$_.Classification;reason=$_.Reason
        }})
    }
    $json = $projection | ConvertTo-Json -Depth 10 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)) | ForEach-Object { $_.ToString('x2') }) -join '').ToUpperInvariant() }
    finally { $sha.Dispose() }
    return [pscustomobject]@{
        Status='previewed';Environment=$Environment;Items=@($items)
        PlannedWrites=@($items | Where-Object Classification -eq 'missing').Count
        HasConflict=@($items | Where-Object Classification -eq 'conflict').Count -gt 0
        PreviewHash=$hash
    }
}

Export-ModuleMember -Function Get-PucIncidentAlarmLevelDefinitions,Resolve-PucIncidentAlarmLevelAssets,Test-PucIncidentZip,New-PucIncidentAlarmLevelPreview
