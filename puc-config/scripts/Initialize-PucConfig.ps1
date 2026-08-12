[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Name,
    [Parameter(Mandatory)][uri]$BaseUrl,
    [Parameter(Mandatory)][string]$Realm,
    [Parameter(Mandatory)][string]$AdminAccount,
    [switch]$AllowInsecureTls,
    [string]$TemplateEnvironment,
    [string]$ConfigRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$root = Get-PucConfigRoot $ConfigRoot
New-Item -ItemType Directory -Force -Path $root | Out-Null
$configPath = Join-Path $root 'config.json'
$existing = Read-PucJson -Path $configPath -Default $null
$previous = Get-PucEntry -Document $existing -Name $Name
$template = $null
if (-not [string]::IsNullOrWhiteSpace($TemplateEnvironment)) {
    if ($TemplateEnvironment -eq $Name) { throw 'TemplateEnvironment must differ from Name.' }
    $template = Get-PucEntry -Document $existing -Name $TemplateEnvironment
    if ($null -eq $template) { throw "Template environment '$TemplateEnvironment' does not exist in config.json." }
}

function Get-LocalValue([string]$PropertyName) {
    if ($null -ne $previous -and $null -ne $previous.PSObject.Properties[$PropertyName]) {
        return [string]$previous.$PropertyName
    }
    if ($null -ne $template -and $null -ne $template.PSObject.Properties[$PropertyName]) {
        return [string]$template.$PropertyName
    }
    return ''
}

$entry = [ordered]@{
    name = $Name
    baseUrl = $BaseUrl.AbsoluteUri.TrimEnd('/')
    realm = $Realm
    adminAccount = $AdminAccount
    adminPassword = Get-LocalValue 'adminPassword'
    newAccountPassword = Get-LocalValue 'newAccountPassword'
    token = if ($null -ne $previous -and $null -ne $previous.PSObject.Properties['token']) { [string]$previous.token } else { '' }
    pucId = if ($null -ne $previous -and $null -ne $previous.PSObject.Properties['pucId']) { [string]$previous.pucId } else { '' }
    allowInsecureTls = if ($null -ne $template) { $true } else { [bool]$AllowInsecureTls }
}
Write-PucJson -Path $configPath -Value (Set-PucEntry -Document $existing -Name $Name -Entry $entry)
New-Item -ItemType Directory -Force -Path (Join-Path $root 'reports') | Out-Null
[pscustomobject]@{
    status = 'initialized'
    environment = $Name
    templateEnvironment = if ($null -ne $template) { $TemplateEnvironment } else { '' }
    configPath = $configPath
    accountPasswordConfigured = -not [string]::IsNullOrWhiteSpace([string]$entry.newAccountPassword)
} | ConvertTo-Json -Compress
