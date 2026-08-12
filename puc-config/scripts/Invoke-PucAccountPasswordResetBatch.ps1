[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [string]$Query,
    [string]$ManifestPath,
    [switch]$PlanOnly,
    [switch]$DryRun,
    [switch]$Live,
    [switch]$ConfirmLive,
    [string]$ConfigRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (@($PlanOnly,$DryRun,$Live | Where-Object { $_ }).Count -ne 1) { throw 'Select exactly one mode: PlanOnly, DryRun, or Live.' }
if (($PlanOnly -or $DryRun) -and [string]::IsNullOrWhiteSpace($Query)) { throw 'PlanOnly and DryRun require Query.' }
if (($DryRun -or $Live) -and [string]::IsNullOrWhiteSpace($ManifestPath)) { throw 'DryRun and Live require ManifestPath.' }
if ($Live -and -not $ConfirmLive) { throw 'Live batch reset requires ConfirmLive after explicit confirmation.' }
if ($Environment -notmatch '^[A-Za-z0-9_-]+$') { throw 'Environment contains unsupported characters.' }

Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force
$root = Get-PucConfigRoot $ConfigRoot
$singleResetScript = Join-Path $PSScriptRoot 'Invoke-PucAccountPasswordReset.ps1'

function Get-PropertyValue($Object, [string]$Name, $Default = $null) {
    $property = @($Object.PSObject.Properties.Match($Name)) | Select-Object -First 1
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function ConvertTo-ProcessArgument([string]$Value) {
    if ($Value.Contains('"')) { throw 'A child-process argument contains an unsupported quote character.' }
    return '"' + $Value + '"'
}

function Start-ResetChildren([object[]]$Entries, [ValidateSet('DryRun','Live')][string]$Mode) {
    $powershellExe = Join-Path $PSHOME 'powershell.exe'
    $children = foreach ($entry in $Entries) {
        $account = [string](Get-PropertyValue $entry 'account' '')
        if ($account -notmatch '^[A-Za-z0-9_.@-]+$') { throw "Account '$account' contains unsupported characters." }

        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$singleResetScript,'-Environment',$Environment,'-Account',$account,'-ConfigRoot',$root)
        if ($Mode -eq 'DryRun') {
            $arguments += '-DryRun'
        } else {
            $hash = [string](Get-PropertyValue $entry 'snapshotHash' '')
            if ($hash -notmatch '^[A-Fa-f0-9]{64}$') { throw "Account '$account' has an invalid snapshot hash." }
            $arguments += @('-Live','-ConfirmLive','-ExpectedSnapshotHash',$hash)
        }

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $powershellExe
        $startInfo.Arguments = (($arguments | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }) -join ' ')
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw "Could not start reset process for '$account'." }
        [pscustomobject]@{ account=$account; process=$process }
    }

    # All child processes are started before waiting for any one account.
    $results = foreach ($child in $children) {
        $stdout = $child.process.StandardOutput.ReadToEnd().Trim()
        $stderr = $child.process.StandardError.ReadToEnd().Trim()
        $child.process.WaitForExit()
        if ($child.process.ExitCode -eq 0) {
            try {
                [pscustomobject]@{ account=$child.account; ok=$true; data=($stdout | ConvertFrom-Json); error=$null }
            } catch {
                [pscustomobject]@{ account=$child.account; ok=$false; data=$null; error='Child reset returned unreadable output.' }
            }
        } else {
            [pscustomobject]@{ account=$child.account; ok=$false; data=$null; error=$(if ($stderr) { $stderr } else { 'Child reset process failed.' }) }
        }
        $child.process.Dispose()
    }
    return @($results)
}

function Get-MatchingAccounts([string]$AccountQuery) {
    $environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
    $validation = & (Join-Path $PSScriptRoot 'Invoke-PucAuth.ps1') -Action Validate -Environment $Environment -ConfigRoot $root | ConvertFrom-Json
    if ($validation.valid -ne $true) { throw "Saved token is not usable ($($validation.reason)). Complete the login workflow first." }
    $environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
    $baseUri = [uri]$environmentConfig.baseUrl
    $oldCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
    $callbackChanged = $false
    if ($environmentConfig.allowInsecureTls -eq $true -and -not (Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')) {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        $callbackChanged = $true
    }
    try {
        $pageIndex = 1
        $accounts = [Collections.Generic.List[string]]::new()
        while ($true) {
            $body = [ordered]@{
                cmd_name='account_list_request'; user_id=[string]$environmentConfig.adminAccount; realm=[string]$environmentConfig.realm
                page_sizes=30; page_index=$pageIndex; querykey=$AccountQuery; lock_query=0; filter=[ordered]@{by_role='';by_state=0}
            }
            [byte[]]$jsonBody = ConvertTo-PucJsonBytes -Value $body -Depth 60
            $params = @{
                Method='POST'; Uri=$baseUri.AbsoluteUri.TrimEnd('/') + '/confs'; ContentType='application/json; charset=utf-8'
                Headers=@{ Accept='application/json, text/plain, */*'; token=[string]$environmentConfig.token }; Body=$jsonBody; TimeoutSec=60
            }
            if ($environmentConfig.allowInsecureTls -eq $true -and (Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')) { $params.SkipCertificateCheck = $true }
            $response = ConvertFrom-PucResponseEncoding -Value (Invoke-RestMethod @params)
            if ($null -eq $response -or [string](Get-PropertyValue $response 'result' '') -ne '0') {
                throw "Account discovery failed on page $pageIndex. No retry was attempted."
            }
            foreach ($row in @((Get-PropertyValue $response 'account_list' @()))) {
                $account = [string](Get-PropertyValue $row 'dispatcher_account' '')
                if ($account.IndexOf($AccountQuery,[StringComparison]::OrdinalIgnoreCase) -ge 0) { $accounts.Add($account) }
            }
            $pageCount = 0
            [void][int]::TryParse([string](Get-PropertyValue $response 'page_count' 0),[ref]$pageCount)
            if ($pageCount -le 0 -or $pageIndex -ge $pageCount) { break }
            if ($pageIndex -ge 1000) { throw 'Account discovery exceeded 1000 pages.' }
            $pageIndex++
        }
        return @($accounts | Where-Object { $_ } | Sort-Object -Unique)
    } finally {
        if ($callbackChanged) { [Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCallback }
    }
}

if ($PlanOnly) {
    [pscustomobject]@{ status='planned-offline'; action='BatchResetAccountPassword'; environment=$Environment; query=$Query; accountConcurrency='parallel'; perAccountOrder=@('timestamp-password','newAccountPassword'); writesUsed=0 } | ConvertTo-Json -Depth 5 -Compress
    return
}

if ($DryRun) {
    $accounts = @(Get-MatchingAccounts $Query)
    if ($accounts.Count -eq 0) { throw "No dispatcher accounts matched '$Query'." }
    $preview = @(Start-ResetChildren -Entries @($accounts | ForEach-Object { [pscustomobject]@{account=$_} }) -Mode DryRun)
    $failed = @($preview | Where-Object { -not $_.ok })
    if ($failed.Count -gt 0) {
        [pscustomobject]@{ status='preview-failed'; action='BatchResetAccountPassword'; environment=$Environment; results=$preview } | ConvertTo-Json -Depth 8 -Compress
        exit 1
    }
    $manifest = [ordered]@{
        version=1; environment=$Environment; query=$Query; generatedAt=[DateTimeOffset]::UtcNow.ToString('o')
        accounts=@($preview | ForEach-Object { [ordered]@{account=$_.account;snapshotHash=[string]$_.data.snapshotHash} })
    }
    $resolvedManifestPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ManifestPath)
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resolvedManifestPath -Encoding UTF8
    [pscustomobject]@{ status='previewed'; action='BatchResetAccountPassword'; environment=$Environment; query=$Query; accountCount=$manifest.accounts.Count; accounts=$manifest.accounts; manifestPath=$resolvedManifestPath; writesUsed=0 } | ConvertTo-Json -Depth 8 -Compress
    return
}

$resolvedManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
$manifest = Get-Content -LiteralPath $resolvedManifestPath -Raw | ConvertFrom-Json
if ([int](Get-PropertyValue $manifest 'version' 0) -ne 1) { throw 'Unsupported batch reset manifest version.' }
if (-not [string]::Equals([string]$manifest.environment,$Environment,[StringComparison]::Ordinal)) { throw 'Manifest environment does not match the selected environment.' }
$entries = @($manifest.accounts)
if ($entries.Count -eq 0) { throw 'The batch reset manifest contains no accounts.' }

$children = @(Start-ResetChildren -Entries $entries -Mode Live)
$results = @($children | ForEach-Object {
    if ($_.ok) { $_.data }
    else { [pscustomobject]@{status='failed';account=$_.account;error=$_.error} }
})
$failed = @($children | Where-Object { -not $_.ok })
[pscustomobject]@{ status=$(if ($failed.Count -eq 0) {'password-reset'} else {'partial-failure'}); action='BatchResetAccountPassword'; environment=$Environment; accountCount=$entries.Count; succeeded=($entries.Count-$failed.Count); failed=$failed.Count; results=$results } | ConvertTo-Json -Depth 10 -Compress
if ($failed.Count -gt 0) { exit 1 }
