$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\scripts\PucConfig.psm1'
Import-Module $modulePath -Force
$root = Join-Path ([IO.Path]::GetTempPath()) ('puc-environment-names-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $configPath = Join-Path $root 'config.json'
    $document = [ordered]@{version=1;environments=@(
        [ordered]@{name='30_163';baseUrl='https://10.161.30.163:16890';realm='puc.com';adminAccount='admin';adminPassword='secret-a';newAccountPassword='new-a';token='token-a';pucId='1';allowInsecureTls=$true},
        [ordered]@{name='30_163_alt';baseUrl='https://10.110.30.163:16890';realm='puc.com';adminAccount='admin';adminPassword='secret-b';newAccountPassword='new-b';token='token-b';pucId='2';allowInsecureTls=$true}
    )}
    Write-PucJson -Path $configPath -Value $document
    $result = Repair-PucEnvironmentNames -ConfigRoot $root -Apply
    if ($result.status -ne 'normalized' -or $result.changed -ne 2) { throw 'Legacy environment names were not normalized.' }
    $updated = Read-PucJson -Path $configPath -Default $null
    $names = @($updated.environments.name)
    if ('10.161.30.163' -notin $names -or '10.110.30.163' -notin $names) { throw 'Complete environment hosts were not preserved as distinct keys.' }
    if ([string]($updated.environments | Where-Object name -eq '10.161.30.163').token -ne 'token-a') { throw 'Normalization did not preserve environment credentials.' }

    $initializeRoot = Join-Path $root 'initialize'
    $initializeScript = Join-Path $PSScriptRoot '..\scripts\Initialize-PucConfig.ps1'
    & $initializeScript -BaseUrl 'https://10.161.42.196:16890' -Realm 'puc.com' -AdminAccount 'admin' -ConfigRoot $initializeRoot | Out-Null
    $initialized = Read-PucJson -Path (Join-Path $initializeRoot 'config.json') -Default $null
    if ([string]$initialized.environments[0].name -ne '10.161.42.196') { throw 'Environment initialization did not derive the complete host key.' }
    $providedResult = Initialize-PucEnvironmentConfig -ConfigRoot $initializeRoot -BaseUrl 'https://10.161.42.197:16890' -Realm 'puc.com' -AdminAccount 'admin' -AllowInsecureTls $true -UseProvidedPasswords -AdminPassword 'local-admin-secret' -NewAccountPassword 'local-account-secret'
    $provided = Get-PucEnvironment -ConfigRoot $initializeRoot -Name '10.161.42.197'
    if ([string]$provided.adminPassword -ne 'local-admin-secret' -or [string]$provided.newAccountPassword -ne 'local-account-secret') { throw 'In-memory GUI password initialization did not persist both password fields.' }
    if (($providedResult | ConvertTo-Json -Compress) -match 'local-(admin|account)-secret') { throw 'Environment initialization result exposed password material.' }
    $mismatchDetected = $false
    try { & $initializeScript -Name '42_196' -BaseUrl 'https://10.161.42.196:16890' -Realm 'puc.com' -AdminAccount 'admin' -ConfigRoot $initializeRoot | Out-Null } catch { $mismatchDetected = $_.Exception.Message -match 'complete baseUrl host' }
    if (-not $mismatchDetected) { throw 'Environment initialization accepted an abbreviated key.' }

    $updated.environments += [pscustomobject]@{name='duplicate';baseUrl='https://10.161.30.163:16900';realm='puc.com';adminAccount='admin'}
    Write-PucJson -Path $configPath -Value $updated
    $collisionDetected = $false
    try { $null = Repair-PucEnvironmentNames -ConfigRoot $root -Apply } catch { $collisionDetected = $_.Exception.Message -match 'same complete host' }
    if (-not $collisionDetected) { throw 'Duplicate complete environment hosts were not rejected.' }
    'PASS EnvironmentNames'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
