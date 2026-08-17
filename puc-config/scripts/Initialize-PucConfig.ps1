[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$Name = '',
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
Initialize-PucEnvironmentConfig -ConfigRoot $root -Name $Name -BaseUrl $BaseUrl -Realm $Realm -AdminAccount $AdminAccount -AllowInsecureTls ([bool]$AllowInsecureTls) -TemplateEnvironment $TemplateEnvironment | ConvertTo-Json -Compress
