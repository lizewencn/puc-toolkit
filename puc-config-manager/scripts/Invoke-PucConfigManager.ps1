[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $root 'manager_config.json'
$manifestPath = Join-Path $root 'modules.json'
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$managerConfig = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
$RunMode = [string]$managerConfig.runMode
if ($RunMode -notin @('plan','dry-run','live')) { throw 'manager_config.json runMode must be plan, dry-run, or live.' }
$PlanOnly = $RunMode -eq 'plan'
$Live = $RunMode -eq 'live'
$parsedIp = $null
if (-not [Net.IPAddress]::TryParse([string]$managerConfig.serverIp, [ref]$parsedIp)) { throw 'manager_config.json serverIp is invalid.' }
if ([int]$managerConfig.port -lt 1 -or [int]$managerConfig.port -gt 65535) { throw 'manager_config.json port must be between 1 and 65535.' }
if ([string]$managerConfig.scheme -notin @('http','https')) { throw 'manager_config.json scheme must be http or https.' }
if ([string]$managerConfig.adminPassword -notmatch '^[0-9a-fA-F]{32}$') { throw 'Admin password must be a 32-character hexadecimal ciphertext.' }
$baseUrl = "$($managerConfig.scheme)://$($managerConfig.serverIp):$($managerConfig.port)"
$ipSuffix = ([string]$managerConfig.serverIp).Split('.')[-1]

$selected = @($manifest.modules | Where-Object { $_.enabled -eq $true })
if ($selected.Count -eq 0) { throw 'No enabled module was selected.' }

function Resolve-ManagerPath([string]$relativePath) {
    return [IO.Path]::GetFullPath((Join-Path $root $relativePath))
}

function New-ModuleConfig($module) {
    $config = Get-Content -Raw -LiteralPath (Resolve-ManagerPath $module.config) | ConvertFrom-Json
    $runtimeValues = @{
        baseUrl = $baseUrl
        realm = [string]$managerConfig.realm
        ipSuffix = $ipSuffix
        allowInsecureTls = ($managerConfig.allowInsecureTls -eq $true)
        reportDirectory = Join-Path $root ([string]$module.reportDirectory)
        loginUserEnv = 'PUC_ADMIN_USER'
        loginPasswordEnv = 'PUC_ADMIN_PASSWORD'
        tokenEnv = 'PUC_TOKEN'
    }
    foreach ($name in $runtimeValues.Keys) {
        $config | Add-Member -NotePropertyName $name -NotePropertyValue $runtimeValues[$name] -Force
    }
    return $config
}

$oldToken = [Environment]::GetEnvironmentVariable('PUC_TOKEN')
$oldUser = [Environment]::GetEnvironmentVariable('PUC_ADMIN_USER')
$tempFiles = @()
try {
    if (-not $PlanOnly) {
        Import-Module (Join-Path $PSScriptRoot 'PucSession.psm1') -Force
        $loginAdapter = Get-Content -Raw -LiteralPath (Resolve-ManagerPath $selected[0].adapter) | ConvertFrom-Json
        $session = Connect-PucSession -LoginConfig $managerConfig -Adapter $loginAdapter -CaptchaImagePath (Join-Path $root 'reports\puc-captcha.png')
        [Environment]::SetEnvironmentVariable('PUC_TOKEN', $session.Token)
        [Environment]::SetEnvironmentVariable('PUC_ADMIN_USER', [string]$managerConfig.adminUser)
    }

    foreach ($module in $selected) {
        $moduleConfig = New-ModuleConfig $module
        $tempPath = Join-Path ([IO.Path]::GetTempPath()) ("puc-manager-$($module.name)-" + [guid]::NewGuid().ToString('N') + '.json')
        $tempFiles += $tempPath
        $moduleConfig | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $tempPath -Encoding UTF8
        $scriptPath = Resolve-ManagerPath $module.script
        $adapterPath = Resolve-ManagerPath $module.adapter
        Write-Host "[$($module.name)] starting"
        if ($PlanOnly) { & $scriptPath -ConfigPath $tempPath -PlanOnly }
        elseif ($Live) { & $scriptPath -ConfigPath $tempPath -AdapterPath $adapterPath -Confirm:$false }
        else { & $scriptPath -ConfigPath $tempPath -AdapterPath $adapterPath -DryRun }
    }
} finally {
    [Environment]::SetEnvironmentVariable('PUC_TOKEN', $oldToken)
    [Environment]::SetEnvironmentVariable('PUC_ADMIN_USER', $oldUser)
    foreach ($path in $tempFiles) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
}
