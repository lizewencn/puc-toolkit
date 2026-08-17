[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$SelfTest,
    [string]$ConfigRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force

if ($SelfTest) {
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('puc-environment-name-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    try {
        $configPath = Join-Path $testRoot 'config.json'
        $credentialMarker = 'PRESERVE-CREDENTIAL-MARKER'
        $fixture = [ordered]@{
            version = 1
            environments = @([ordered]@{
                name='30_163';baseUrl='https://10.161.30.163:16890';realm='puc.com';adminAccount='admin'
                adminPassword=$credentialMarker;newAccountPassword='888';token=$credentialMarker;pucId='00001';allowInsecureTls=$true
            })
        }
        Write-PucJson -Path $configPath -Value $fixture

        $resolved = Get-PucEnvironment -ConfigRoot $testRoot -Name '30_163'
        $updated = Read-PucJson -Path $configPath -Default $null
        if ([string]$resolved.name -ne '10.161.30.163' -or [string]$updated.environments[0].name -ne '10.161.30.163') {
            throw 'Legacy environment name was not normalized to the complete host.'
        }
        if ([string]$updated.environments[0].adminPassword -ne $credentialMarker -or [string]$updated.environments[0].token -ne $credentialMarker) {
            throw 'Environment-name normalization changed protected configuration fields.'
        }
        $null = Get-PucEnvironment -ConfigRoot $testRoot -Name '10.161.30.163'

        $collision = [ordered]@{
            version = 1
            environments = @(
                [ordered]@{name='legacy-a';baseUrl='https://10.161.30.163:16890'},
                [ordered]@{name='legacy-b';baseUrl='https://10.161.30.163:16890'}
            )
        }
        Write-PucJson -Path $configPath -Value $collision
        $beforeCollision = [IO.File]::ReadAllBytes($configPath)
        $collisionRejected = $false
        try { $null = Get-PucEnvironment -ConfigRoot $testRoot -Name '10.161.30.163' } catch { $collisionRejected = $_.Exception.Message -match 'same complete host' }
        $afterCollision = [IO.File]::ReadAllBytes($configPath)
        if (-not $collisionRejected -or [Convert]::ToBase64String($beforeCollision) -ne [Convert]::ToBase64String($afterCollision)) {
            throw 'Complete-host collision was not rejected without modifying the file.'
        }

        [pscustomobject]@{status='self-test-passed';legacyName='accepted';normalizedName='10.161.30.163';fieldsPreserved=$true;collisionWriteUsed=$false} | ConvertTo-Json -Compress
    } finally {
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolvedTestRoot.StartsWith($resolvedTempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTestRoot)) {
            Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
        }
    }
    return
}

$root = Get-PucConfigRoot $ConfigRoot
Repair-PucEnvironmentNames -ConfigRoot $root -Apply:$Apply | ConvertTo-Json -Depth 8 -Compress
