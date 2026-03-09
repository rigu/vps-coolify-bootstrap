[CmdletBinding()]
param(
    [string]$EnvFile = "bootstrap-artifacts/production-infra.env",
    [switch]$ForcePasswords,
    [switch]$ForceSecrets,
    [switch]$ForceAll
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($ForceAll) {
    $ForcePasswords = $true
    $ForceSecrets = $true
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$envPath = if ([System.IO.Path]::IsPathRooted($EnvFile)) { $EnvFile } else { Join-Path $repoRoot $EnvFile }
$envExamplePath = Join-Path $repoRoot "env/infra.env.example"

if (-not (Test-Path -LiteralPath $envExamplePath -PathType Leaf)) {
    throw "Missing template env file: $envExamplePath"
}

if (Test-Path -LiteralPath $envPath -PathType Container) {
    throw "--env-file points to a directory, expected a file: $envPath"
}

$envDir = Split-Path -Parent $envPath
if (-not [string]::IsNullOrWhiteSpace($envDir) -and -not (Test-Path -LiteralPath $envDir -PathType Container)) {
    New-Item -ItemType Directory -Path $envDir -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
    Copy-Item -LiteralPath $envExamplePath -Destination $envPath
    Write-Host "Created: $envPath (from $envExamplePath)"
}

function New-HexSecret {
    param([int]$HexLength)
    $byteLen = [int][Math]::Ceiling($HexLength / 2.0)
    $bytes = New-Object byte[] $byteLen
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    $hex = [System.BitConverter]::ToString($bytes).Replace("-", "").ToLowerInvariant()
    return $hex.Substring(0, $HexLength)
}

function Format-EnvValue {
    param([string]$Value)
    if (-not $Value.Contains("'")) { return "'$Value'" }
    $escaped = $Value.Replace('\\', '\\\\').Replace('"', '\\"').Replace('$', '\\$')
    return '"' + $escaped + '"'
}

function Strip-EnvQuotes {
    param([string]$Value)
    if ($Value.StartsWith("'") -and $Value.EndsWith("'")) { return $Value.Substring(1, $Value.Length - 2) }
    if ($Value.StartsWith('"') -and $Value.EndsWith('"')) { return $Value.Substring(1, $Value.Length - 2) }
    return $Value
}

function Test-EmptyOrPlaceholder {
    param([string]$Value)
    return [string]::IsNullOrWhiteSpace($Value) -or $Value.Contains("CHANGE_ME")
}

$kv = @{}
foreach ($line in Get-Content -LiteralPath $envPath) {
    if ($line -match '^[\s]*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
    $idx = $line.IndexOf('=')
    if ($idx -lt 1) { continue }
    $key = $line.Substring(0, $idx).Trim()
    $value = $line.Substring($idx + 1).Trim()
    $kv[$key] = Strip-EnvQuotes -Value $value
}

$postgresAppsPassword = [string]($kv["POSTGRES_APPS_PASSWORD"])
$appsValkeyPassword = [string]($kv["APPS_VALKEY_PASSWORD"])
$planeRabbitmqPassword = [string]($kv["PLANE_RABBITMQ_PASSWORD"])
$planeS3AccessKey = [string]($kv["PLANE_S3_ACCESS_KEY"])
$planeS3SecretKey = [string]($kv["PLANE_S3_SECRET_KEY"])

$passwordsChanged = $false
$secretsChanged = $false

if ($ForcePasswords -or (Test-EmptyOrPlaceholder -Value $postgresAppsPassword)) {
    $postgresAppsPassword = New-HexSecret -HexLength 32
    $passwordsChanged = $true
}
if ($ForcePasswords -or (Test-EmptyOrPlaceholder -Value $appsValkeyPassword)) {
    $appsValkeyPassword = New-HexSecret -HexLength 32
    $passwordsChanged = $true
}
if ($ForcePasswords -or (Test-EmptyOrPlaceholder -Value $planeRabbitmqPassword)) {
    $planeRabbitmqPassword = New-HexSecret -HexLength 32
    $passwordsChanged = $true
}
if ($ForceSecrets -or (Test-EmptyOrPlaceholder -Value $planeS3AccessKey)) {
    $planeS3AccessKey = "PLN" + (New-HexSecret -HexLength 18).ToUpperInvariant()
    $secretsChanged = $true
}
if ($ForceSecrets -or (Test-EmptyOrPlaceholder -Value $planeS3SecretKey)) {
    $planeS3SecretKey = New-HexSecret -HexLength 64
    $secretsChanged = $true
}

$newLines = New-Object System.Collections.Generic.List[string]
$saw = @{
    "POSTGRES_APPS_PASSWORD" = $false
    "APPS_VALKEY_PASSWORD" = $false
    "PLANE_RABBITMQ_PASSWORD" = $false
    "PLANE_S3_ACCESS_KEY" = $false
    "PLANE_S3_SECRET_KEY" = $false
}

$updated = @{
    "POSTGRES_APPS_PASSWORD" = $postgresAppsPassword
    "APPS_VALKEY_PASSWORD" = $appsValkeyPassword
    "PLANE_RABBITMQ_PASSWORD" = $planeRabbitmqPassword
    "PLANE_S3_ACCESS_KEY" = $planeS3AccessKey
    "PLANE_S3_SECRET_KEY" = $planeS3SecretKey
}

foreach ($line in Get-Content -LiteralPath $envPath) {
    $handled = $false
    foreach ($key in $updated.Keys) {
        if ($line.StartsWith("$key=")) {
            $newLines.Add("$key=$(Format-EnvValue -Value ([string]$updated[$key]))")
            $saw[$key] = $true
            $handled = $true
            break
        }
    }
    if (-not $handled) {
        $newLines.Add($line)
    }
}

foreach ($key in $updated.Keys) {
    if (-not $saw[$key]) {
        $newLines.Add("$key=$(Format-EnvValue -Value ([string]$updated[$key]))")
    }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($envPath, $newLines, $utf8NoBom)

Write-Host "Updated: $envPath"
if ($passwordsChanged) {
    Write-Host "Infra passwords generated/refreshed (POSTGRES_APPS_PASSWORD, APPS_VALKEY_PASSWORD, PLANE_RABBITMQ_PASSWORD)."
} else {
    Write-Host "Infra passwords kept (use -ForcePasswords to rotate)."
}
if ($secretsChanged) {
    Write-Host "Infra secrets generated/refreshed (PLANE_S3_ACCESS_KEY, PLANE_S3_SECRET_KEY)."
} else {
    Write-Host "Infra secrets kept (use -ForceSecrets to rotate)."
}
