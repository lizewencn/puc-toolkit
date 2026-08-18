[CmdletBinding()]
param([ValidateSet('Definitions','ZipValidation','Preview','Module','Command','LiveFlow','SkillRouting','All')][string]$Case = 'All')

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $skillRoot 'scripts\PucIncidentAlarmLevels.psm1'
$bundledPython = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$pythonCommand = Get-Command python.exe,python -ErrorAction SilentlyContinue | Where-Object { $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1
$python = if(-not[string]::IsNullOrWhiteSpace($env:PUC_PYTHON_EXE)-and(Test-Path -LiteralPath $env:PUC_PYTHON_EXE)){$env:PUC_PYTHON_EXE}elseif($pythonCommand){$pythonCommand.Source}elseif(Test-Path -LiteralPath $bundledPython){$bundledPython}else{throw 'Python test runtime was not found. Set PUC_PYTHON_EXE to python.exe.'}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ([string]$Actual -cne [string]$Expected) { throw "$Message. Expected '$Expected', got '$Actual'." }
}
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action; throw "Expected error matching '$Pattern'." }
    catch { if ($_.Exception.Message -notmatch $Pattern) { throw "Expected error matching '$Pattern', got '$($_.Exception.Message)'." } }
}
function ConvertFrom-CodePoints([int[]]$Codes) { return -join @($Codes | ForEach-Object { [char]$_ }) }

function Test-Definitions {
    Import-Module $modulePath -Force
    $items = @(Get-PucIncidentAlarmLevelDefinitions)
    $star=ConvertFrom-CodePoints 0x661f,0x6807
    $yellow=ConvertFrom-CodePoints 0x9ec4,0x6807
    $normal=ConvertFrom-CodePoints 0x666e,0x901a
    $warning=ConvertFrom-CodePoints 0x9884,0x8b66
    $instruction=ConvertFrom-CodePoints 0x6307,0x4ee4
    $descriptionSuffix=ConvertFrom-CodePoints 0x8b66,0x60c5,0x7b49,0x7ea7,0x8bf4,0x660e
    $expected = @(
        @('00',$normal,'#73cb6d','MediumAlarm.wav'),
        @('01',$star,'#E56659','CriticalAlarm.wav'),
        @('02',$yellow,'#eba54d','MediumAlarm.wav'),
        @('03',$warning,'#73cb6d','CommonlyAlarm.wav'),
        @('04',$instruction,'#73cb6d','CommonlyAlarm.wav')
    )
    Assert-Equal $items.Count 5 'Definition count'
    for ($i=0; $i -lt 5; $i++) {
        Assert-Equal $items[$i].Code $expected[$i][0] "Code $i"
        Assert-Equal $items[$i].Name $expected[$i][1] "Name $i"
        Assert-Equal $items[$i].Color $expected[$i][2] "Color $i"
        Assert-Equal $items[$i].Tone $expected[$i][3] "Tone $i"
        Assert-Equal $items[$i].Description ($items[$i].Name + $descriptionSuffix) "Description $i"
    }
    $resolved = @(Resolve-PucIncidentAlarmLevelAssets -AssetDirectory (Join-Path $skillRoot 'assets\incident'))
    Assert-Equal $resolved[0].ZipFileName ($normal + '.zip') 'Normal ZIP'
    Assert-Equal $resolved[1].ZipFileName ($star + '.zip') 'Star ZIP'
    Assert-Equal $resolved[2].ZipFileName ($yellow + '.zip') 'Yellow ZIP'
    Assert-Equal $resolved[3].ZipFileName ($warning + '.zip') 'Warning ZIP'
    Assert-Equal $resolved[4].ZipFileName ($instruction + '.zip') 'Instruction ZIP'

    $strictDirectory=Join-Path ([IO.Path]::GetTempPath()) ('puc-incident-strict-assets-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $strictDirectory|Out-Null
    try {
        foreach($name in @($normal,$star,$yellow,$instruction)){
            New-TestZip (Join-Path $strictDirectory ($name+'.zip')) @{'icon.svg'='<svg></svg>'}
        }
        Assert-Throws { $null=@(Resolve-PucIncidentAlarmLevelAssets -AssetDirectory $strictDirectory) } "Incident ZIP does not exist for level '03'"
    } finally { Remove-Item -LiteralPath $strictDirectory -Recurse -Force }
}

function New-TestZip([string]$Path, [hashtable]$Entries) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Create)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
        try {
            foreach ($name in $Entries.Keys) {
                $entry = $archive.CreateEntry($name)
                $writer = [IO.StreamWriter]::new($entry.Open(),[Text.UTF8Encoding]::new($false))
                try { $writer.Write([string]$Entries[$name]) } finally { $writer.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

function Initialize-TestIncidentAssets {
    $directory=Join-Path $skillRoot 'assets\incident'
    if(Test-Path -LiteralPath $directory -PathType Container){return $false}
    New-Item -ItemType Directory -Path $directory|Out-Null
    foreach($name in @(
        (ConvertFrom-CodePoints 0x661f,0x6807),
        (ConvertFrom-CodePoints 0x9ec4,0x6807),
        (ConvertFrom-CodePoints 0x666e,0x901a),
        (ConvertFrom-CodePoints 0x9884,0x8b66),
        (ConvertFrom-CodePoints 0x6307,0x4ee4)
    )){New-TestZip (Join-Path $directory ($name+'.zip')) @{'icon.svg'='<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0h1v1z"/></svg>'}}
    return $true
}

function Test-ZipValidation {
    Import-Module $modulePath -Force
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('puc-incident-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        $valid=Join-Path $dir 'valid.zip'; New-TestZip $valid @{'icon.svg'='<svg></svg>'}
        $info=Test-PucIncidentZip -Path $valid
        Assert-Equal $info.EntryCount 1 'Valid ZIP entry count'
        Assert-True ($info.Sha256 -match '^[A-F0-9]{64}$') 'Valid ZIP hash missing'
        $empty=Join-Path $dir 'empty.zip'; New-TestZip $empty @{}
        Assert-Throws { Test-PucIncidentZip $empty } 'contains no files'
        $bad=Join-Path $dir 'bad.zip'; [IO.File]::WriteAllText($bad,'not zip')
        Assert-Throws { Test-PucIncidentZip $bad } 'valid ZIP'
        $traversal=Join-Path $dir 'traversal.zip'; New-TestZip $traversal @{'../icon.svg'='<svg />'}
        Assert-Throws { Test-PucIncidentZip $traversal } 'unsafe ZIP entry'
        $other=Join-Path $dir 'other.zip'; New-TestZip $other @{'readme.txt'='x'}
        Assert-Throws { Test-PucIncidentZip $other } 'only non-empty SVG'
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
}

function Test-Preview {
    Import-Module $modulePath -Force
    $assets = @(Resolve-PucIncidentAlarmLevelAssets -AssetDirectory (Join-Path $skillRoot 'assets\incident') | ForEach-Object {
        $zip=Test-PucIncidentZip $_.ZipPath
        [pscustomobject]@{Code=$_.Code;Name=$_.Name;Description=$_.Description;Color=$_.Color;Tone=$_.Tone;ZipPath=$_.ZipPath;ZipFileName=$_.ZipFileName;ZipSha256=$zip.Sha256}
    })
    $tones=@([pscustomobject]@{file_name='CriticalAlarm.wav'},[pscustomobject]@{file_name='MediumAlarm.wav'},[pscustomobject]@{file_name='CommonlyAlarm.wav'})
    $missing=New-PucIncidentAlarmLevelPreview -Environment 'test' -Assets $assets -Tones $tones -ExistingLevels $null
    Assert-Equal $missing.PlannedWrites 5 'Missing writes'
    Assert-True (-not $missing.HasConflict) 'Missing preview should not conflict'
    Assert-True ($missing.PreviewHash -match '^[A-F0-9]{64}$') 'Preview hash missing'
    Assert-Equal (New-PucIncidentAlarmLevelPreview -Environment 'test' -Assets $assets -Tones $tones -ExistingLevels $null).PreviewHash $missing.PreviewHash 'Preview hash stability'
    $existing=@($assets|ForEach-Object{[pscustomobject]@{level_code=$_.Code;level_name=$_.Name;level_desc=$_.Description;icon_color=$_.Color.ToUpperInvariant();icon_zip_name=$_.ZipFileName;toneInfo=[pscustomobject]@{file_name=$_.Tone}}})
    $same=New-PucIncidentAlarmLevelPreview -Environment 'test' -Assets $assets -Tones $tones -ExistingLevels $existing
    Assert-Equal $same.PlannedWrites 0 'Exact identity match writes'
    Assert-Equal @($same.Items|Where-Object Classification -eq 'conflict').Count 5 'Exact identity matches must conflict'
    $codeOnly=New-PucIncidentAlarmLevelPreview -Environment 'test' -Assets $assets -Tones $tones -ExistingLevels @([pscustomobject]@{level_code=$assets[0].Code;level_name='different-name'})
    Assert-Equal $codeOnly.Items[0].Classification 'conflict' 'Equal code must conflict'
    Assert-Equal $codeOnly.PlannedWrites 4 'Equal code must not block other writes'
    $nameOnly=New-PucIncidentAlarmLevelPreview -Environment 'test' -Assets $assets -Tones $tones -ExistingLevels @([pscustomobject]@{level_code='different-code';level_name=$assets[1].Name})
    Assert-Equal $nameOnly.Items[1].Classification 'conflict' 'Equal name must conflict'
    Assert-Equal $nameOnly.PlannedWrites 4 'Equal name must not block other writes'
    Assert-Throws { New-PucIncidentAlarmLevelPreview -Environment test -Assets $assets -Tones @($tones+$tones[0]) -ExistingLevels @() } 'exactly one'
}

function Test-Command {
    $commandPath=Join-Path $skillRoot 'scripts\Invoke-PucIncidentAlarmLevels.ps1'
    $output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $commandPath -Environment test -PlanOnly 2>&1
    if ($LASTEXITCODE -ne 0) { throw "PlanOnly failed: $($output -join ' ')" }
    $result=($output -join "`n")|ConvertFrom-Json
    Assert-Equal $result.status 'planned-offline' 'PlanOnly status'
    Assert-Equal $result.itemCount 5 'PlanOnly item count'
    Assert-Equal $result.networkUsed $false 'PlanOnly network use'
    $previousPreference=$ErrorActionPreference
    $ErrorActionPreference='Continue'
    try { $bad=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $commandPath -Environment test -Live -ConfirmLive 2>&1 }
    finally { $ErrorActionPreference=$previousPreference }
    Assert-True ($LASTEXITCODE -ne 0) 'Live without preview hash must fail'
    Assert-True (($bad -join ' ') -match 'ExpectedPreviewHash') 'Missing hash error not reported'
}

function Test-SkillRouting {
    $skill=Get-Content -Raw -LiteralPath (Join-Path $skillRoot 'SKILL.md')
    $referencePath=Join-Path $skillRoot 'references\incident-alarm-levels.md'
    Assert-True ($skill -match 'incident-alarm-levels\.md') 'SKILL route is missing'
    Assert-True (Test-Path -LiteralPath $referencePath) 'Incident workflow reference is missing'
    $reference=Get-Content -Raw -LiteralPath $referencePath
    foreach($term in @('DryRun','ExpectedPreviewHash','same level code','same level name','conflict-skipped','continue','partial','No retry')){Assert-True ($reference -match [regex]::Escape($term)) "Reference is missing '$term'"}
}

function Test-LiveFlow {
    $port=19000+(Get-Random -Minimum 1 -Maximum 500)
    $environmentName='127.0.0.1'
    $configRoot=Join-Path ([IO.Path]::GetTempPath()) ('puc-incident-config-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $configRoot|Out-Null
    $config=[ordered]@{version=1;environments=@([ordered]@{name=$environmentName;baseUrl="http://127.0.0.1:$port";realm='puc.com';adminAccount='admin';adminPassword='';newAccountPassword='';token='test-token';pucId='00001';allowInsecureTls=$false})}
    $config|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $configRoot 'config.json') -Encoding UTF8
    $server=Start-Process -FilePath $python -ArgumentList @((Join-Path $PSScriptRoot 'incident_fake_server.py'),'--port',$port) -WindowStyle Hidden -PassThru
    try {
        $ready=$false
        for($i=0;$i-lt 30;$i++){try{$tcp=[Net.Sockets.TcpClient]::new();$tcp.Connect('127.0.0.1',$port);$tcp.Dispose();$ready=$true;break}catch{Start-Sleep -Milliseconds 100}}
        Assert-True $ready 'Fake server did not start'
        $commandPath=Join-Path $skillRoot 'scripts\Invoke-PucIncidentAlarmLevels.ps1'
        $old=[Environment]::GetEnvironmentVariable('PUC_CONFIG_TEST_MODE');[Environment]::SetEnvironmentVariable('PUC_CONFIG_TEST_MODE','1')
        try {
            $previewText=& $commandPath -Environment $environmentName -DryRun -ConfigRoot $configRoot -EndpointOverride "http://127.0.0.1:$port/confs"
            $preview=$previewText|ConvertFrom-Json
            Assert-Equal $preview.PlannedWrites 4 'Fake preview writes'
            Assert-Equal $preview.Items[0].Classification 'conflict' 'Preflight code conflict'
            $liveText=& $commandPath -Environment $environmentName -Live -ConfirmLive -ExpectedPreviewHash $preview.PreviewHash -ConfigRoot $configRoot -EndpointOverride "http://127.0.0.1:$port/confs"
            $live=$liveText|ConvertFrom-Json
            Assert-Equal $live.status 'configured' 'Live status'
            Assert-Equal $live.writesUsed 3 'Live write count'
            Assert-True $live.verified 'Live verification'
            Assert-Equal (($live.results|Where-Object status -eq 'conflict-skipped'|ForEach-Object code)-join ',') '00,02' 'Conflict skips'
            Assert-Equal (($live.results|Where-Object status -eq 'created'|ForEach-Object code)-join ',') '01,03,04' 'Continued write order'
        } finally {[Environment]::SetEnvironmentVariable('PUC_CONFIG_TEST_MODE',$old)}
    } finally {
        if($null-ne$server-and-not$server.HasExited){Stop-Process -Id $server.Id -Force}
        Remove-Item -LiteralPath $configRoot -Recurse -Force
    }
}

$createdTestAssets=Initialize-TestIncidentAssets
try {
    $cases = if ($Case -eq 'All') { @('Definitions','ZipValidation','Preview','Command','LiveFlow','SkillRouting') } elseif ($Case -eq 'Module') { @('Definitions','ZipValidation','Preview') } else { @($Case) }
    foreach ($name in $cases) {
        switch ($name) {
            'Definitions' { Test-Definitions }
            'ZipValidation' { Test-ZipValidation }
            'Preview' { Test-Preview }
            'Command' { Test-Command }
            'LiveFlow' { Test-LiveFlow }
            'SkillRouting' { Test-SkillRouting }
            default { throw "Test case '$name' is not implemented yet." }
        }
        Write-Output "PASS $name"
    }
} finally {
    if($createdTestAssets){Remove-Item -LiteralPath (Join-Path $skillRoot 'assets\incident') -Recurse -Force}
}
