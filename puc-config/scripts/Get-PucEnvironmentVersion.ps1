[CmdletBinding()]
param(
    [string]$Environment,
    [string]$ConfigRoot,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PucConfig.psm1') -Force

function ConvertFrom-PucEnvironmentVersionContent([string]$Content) {
    if ([string]::IsNullOrWhiteSpace($Content)) { throw 'env.js 返回内容为空。' }
    $source = $Content.Trim().TrimStart([char]0xFEFF)
    $jsonText = $source

    if (-not $source.StartsWith('{')) {
        $objectStart = $source.IndexOf('{')
        $objectEnd = $source.LastIndexOf('}')
        if ($objectStart -lt 0 -or $objectEnd -le $objectStart) {
            throw 'env.js 中未找到 JSON 对象。'
        }

        $prefix = $source.Substring(0, $objectStart).Trim()
        $suffix = $source.Substring($objectEnd + 1).Trim()
        if ($prefix -notmatch '^export\s+default$' -or ($suffix -ne '' -and $suffix -ne ';')) {
            throw 'env.js 使用了不支持的内容格式。'
        }

        $jsonText = $source.Substring($objectStart, $objectEnd - $objectStart + 1)
    }

    $document = $jsonText | ConvertFrom-Json
    $version = [string]$document.PUC_CONFIG_VERSION
    if ([string]::IsNullOrWhiteSpace($version)) { throw 'env.js 缺少 PUC_CONFIG_VERSION。' }
    if ($version.Length -gt 120 -or $version -match '[\r\n]') { throw 'PUC_CONFIG_VERSION 格式不正确。' }
    return $version.Trim()
}

if ($SelfTest) {
    $jsonVersion = ConvertFrom-PucEnvironmentVersionContent '{"PUC_CONFIG_VERSION":"V4.3.00.012.003.x86.pg"}'
    $moduleVersion = ConvertFrom-PucEnvironmentVersionContent 'export default {"PUC_CONFIG_VERSION":"V4.1.01.010 "};'
    if ($jsonVersion -ne 'V4.3.00.012.003.x86.pg' -or $moduleVersion -ne 'V4.1.01.010') { throw '版本解析自检失败。' }
    [pscustomobject]@{status='self-test-passed';jsonVersion=$jsonVersion;moduleVersion=$moduleVersion} | ConvertTo-Json -Compress
    return
}

if ([string]::IsNullOrWhiteSpace($Environment) -or $Environment -notmatch '^[A-Za-z0-9_.-]+$') {
    throw 'Environment 包含不支持的字符。'
}

$root = Get-PucConfigRoot -Override $ConfigRoot
$environmentConfig = Get-PucEnvironment -ConfigRoot $root -Name $Environment
$baseUri = [uri]$environmentConfig.baseUrl
$versionUri = [uri]($baseUri.AbsoluteUri.TrimEnd('/') + '/env.js')
$response = Invoke-PucHttpRequest -Method GET -Uri $versionUri -Headers @{Accept='application/json, text/javascript, */*'} -AllowInsecureTls ([bool]$environmentConfig.allowInsecureTls) -TimeoutSec 15
$content = [Text.Encoding]::UTF8.GetString($response.BodyBytes)
$version = ConvertFrom-PucEnvironmentVersionContent $content

[pscustomobject]@{
    status='version-resolved'
    environment=$Environment
    version=$version
} | ConvertTo-Json -Compress
