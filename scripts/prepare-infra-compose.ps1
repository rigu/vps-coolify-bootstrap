[CmdletBinding()]
param(
    [string]$EnvFile = "bootstrap-artifacts/production-infra.env",
    [string]$OutputDir = "bootstrap-artifacts/infra",
    [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$envPath = if ([System.IO.Path]::IsPathRooted($EnvFile)) { $EnvFile } else { Join-Path $repoRoot $EnvFile }
$outDir = if ([System.IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $repoRoot $OutputDir }

$envExamplePath = Join-Path $repoRoot "env/infra.env.example"
$composeTemplatePath = Join-Path $repoRoot "templates/infra-compose.template.yml"
$valkeyTemplatePath = Join-Path $repoRoot "templates/infra-valkey.conf.template"
$seaweedfsTemplatePath = Join-Path $repoRoot "templates/infra-seaweedfs-s3-config.template.json"
$postgresInitTemplatePath = Join-Path $repoRoot "templates/infra-postgres-apps-init.sh"

foreach ($requiredPath in @($envExamplePath, $composeTemplatePath, $valkeyTemplatePath, $seaweedfsTemplatePath, $postgresInitTemplatePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required file missing: $requiredPath"
    }
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

function Strip-EnvQuotes {
    param([string]$Value)
    if ($Value.StartsWith("'") -and $Value.EndsWith("'")) { return $Value.Substring(1, $Value.Length - 2) }
    if ($Value.StartsWith('"') -and $Value.EndsWith('"')) { return $Value.Substring(1, $Value.Length - 2) }
    return $Value
}

$cfg = @{}
foreach ($rawLine in Get-Content -LiteralPath $envPath) {
    $line = $rawLine.Trim()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) { continue }
    $idx = $line.IndexOf("=")
    if ($idx -lt 1) { throw "Invalid env line: $rawLine" }
    $key = $line.Substring(0, $idx).Trim()
    $value = $line.Substring($idx + 1).Trim()
    $cfg[$key] = Strip-EnvQuotes -Value $value
}

$requiredKeys = @(
    "INFRA_NETWORK_NAME",
    "POSTGRES_IMAGE", "VALKEY_IMAGE", "RABBITMQ_IMAGE", "SEAWEEDFS_IMAGE",
    "POSTGRES_APPS_USER", "POSTGRES_APPS_PASSWORD", "POSTGRES_APPS_DB", "POSTGRES_PLANE_DB", "POSTGRES_DOCMOST_DB", "POSTGRES_APPS_HOST_PORT",
    "APPS_VALKEY_PASSWORD", "VALKEY_HOST_PORT",
    "PLANE_RABBITMQ_USER", "PLANE_RABBITMQ_PASSWORD", "PLANE_RABBITMQ_VHOST", "RABBITMQ_AMQP_HOST_PORT", "RABBITMQ_UI_HOST_PORT",
    "PLANE_S3_ACCESS_KEY", "PLANE_S3_SECRET_KEY", "PLANE_S3_BUCKET", "SEAWEEDFS_S3_HOST_PORT"
)

foreach ($key in $requiredKeys) {
    if (-not $cfg.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$cfg[$key])) {
        throw "Missing required key: $key"
    }
}

if (-not $cfg.ContainsKey("POSTGRES_APPS_CONTAINER_NAME")) { $cfg["POSTGRES_APPS_CONTAINER_NAME"] = "postgres-apps" }
if (-not $cfg.ContainsKey("VALKEY_APPS_CONTAINER_NAME")) { $cfg["VALKEY_APPS_CONTAINER_NAME"] = "valkey-apps" }
if (-not $cfg.ContainsKey("RABBITMQ_PLANE_CONTAINER_NAME")) { $cfg["RABBITMQ_PLANE_CONTAINER_NAME"] = "rabbitmq-plane" }
if (-not $cfg.ContainsKey("SEAWEEDFS_PLANE_CONTAINER_NAME")) { $cfg["SEAWEEDFS_PLANE_CONTAINER_NAME"] = "seaweedfs-plane" }

foreach ($key in @("POSTGRES_APPS_PASSWORD", "APPS_VALKEY_PASSWORD", "PLANE_RABBITMQ_PASSWORD", "PLANE_S3_ACCESS_KEY", "PLANE_S3_SECRET_KEY", "POSTGRES_REPLICATION_PASSWORD")) {
    if ([string]$cfg[$key] -like "*CHANGE_ME*") {
        throw "$key still contains CHANGE_ME placeholder"
    }
}

function Test-ValidSimpleName {
    param([string]$Value)
    return $Value -match '^[A-Za-z0-9][A-Za-z0-9_.-]*$'
}

function Test-ValidUserName {
    param([string]$Value)
    return $Value -match '^[A-Za-z0-9_][A-Za-z0-9_.-]*$'
}

foreach ($key in @("POSTGRES_APPS_USER", "PLANE_RABBITMQ_USER")) {
    if (-not (Test-ValidUserName -Value ([string]$cfg[$key]))) {
        throw "$key has invalid format: $($cfg[$key])"
    }
}

foreach ($key in @("INFRA_NETWORK_NAME", "POSTGRES_APPS_DB", "POSTGRES_PLANE_DB", "POSTGRES_DOCMOST_DB", "PLANE_RABBITMQ_VHOST", "PLANE_S3_BUCKET", "POSTGRES_APPS_CONTAINER_NAME", "VALKEY_APPS_CONTAINER_NAME", "RABBITMQ_PLANE_CONTAINER_NAME", "SEAWEEDFS_PLANE_CONTAINER_NAME")) {
    if (-not (Test-ValidSimpleName -Value ([string]$cfg[$key]))) {
        throw "$key has invalid format: $($cfg[$key])"
    }
}

foreach ($key in @("POSTGRES_APPS_HOST_PORT", "VALKEY_HOST_PORT", "RABBITMQ_AMQP_HOST_PORT", "RABBITMQ_UI_HOST_PORT", "SEAWEEDFS_S3_HOST_PORT")) {
    $port = [string]$cfg[$key]
    if ($port -notmatch '^\d+$') {
        throw "$key must be numeric (1-65535)"
    }
    $portNum = [int]$port
    if ($portNum -lt 1 -or $portNum -gt 65535) {
        throw "$key must be between 1 and 65535"
    }
}

if (-not (Test-Path -LiteralPath $outDir -PathType Container)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$composeOut = Join-Path $outDir "docker-compose.yml"
$valkeyOut = Join-Path $outDir "valkey.conf"
$seaweedfsOut = Join-Path $outDir "seaweedfs-s3-config.json"
$postgresInitOut = Join-Path $outDir "postgres-apps-init.sh"
$outputEnv = Join-Path $outDir "production-infra.env"

if (-not $Overwrite) {
    foreach ($path in @($composeOut, $valkeyOut, $seaweedfsOut, $postgresInitOut, $outputEnv)) {
        if (Test-Path -LiteralPath $path) {
            throw "Output already exists: $path (use -Overwrite)"
        }
    }
}

function Render-Template {
    param(
        [string]$TemplatePath,
        [hashtable]$Tokens
    )
    $content = Get-Content -LiteralPath $TemplatePath -Raw
    foreach ($token in $Tokens.Keys) {
        $content = $content.Replace([string]$token, [string]$Tokens[$token])
    }
    return $content
}

$composeTokens = @{
    "INFRA_NETWORK_NAME_HERE" = [string]$cfg["INFRA_NETWORK_NAME"]
    "POSTGRES_IMAGE_HERE" = [string]$cfg["POSTGRES_IMAGE"]
    "VALKEY_IMAGE_HERE" = [string]$cfg["VALKEY_IMAGE"]
    "RABBITMQ_IMAGE_HERE" = [string]$cfg["RABBITMQ_IMAGE"]
    "SEAWEEDFS_IMAGE_HERE" = [string]$cfg["SEAWEEDFS_IMAGE"]
    "POSTGRES_APPS_CONTAINER_NAME_HERE" = [string]$cfg["POSTGRES_APPS_CONTAINER_NAME"]
    "POSTGRES_APPS_USER_HERE" = [string]$cfg["POSTGRES_APPS_USER"]
    "POSTGRES_APPS_PASSWORD_HERE" = [string]$cfg["POSTGRES_APPS_PASSWORD"]
    "POSTGRES_APPS_DB_HERE" = [string]$cfg["POSTGRES_APPS_DB"]
    "POSTGRES_PLANE_DB_HERE" = [string]$cfg["POSTGRES_PLANE_DB"]
    "POSTGRES_DOCMOST_DB_HERE" = [string]$cfg["POSTGRES_DOCMOST_DB"]
    "POSTGRES_APPS_HOST_PORT_HERE" = [string]$cfg["POSTGRES_APPS_HOST_PORT"]
    "POSTGRES_REPLICATION_USER_HERE" = [string]$cfg["POSTGRES_REPLICATION_USER"]
    "POSTGRES_REPLICATION_PASSWORD_HERE" = [string]$cfg["POSTGRES_REPLICATION_PASSWORD"]
    "POSTGRES_ARCHIVE_MODE_HERE" = if ([string]$cfg["POSTGRES_ENABLE_WAL_ARCHIVE"] -eq "true") { "on" } else { "off" }
    "POSTGRES_WAL_ARCHIVE_TIMEOUT_HERE" = if ([string]$cfg["POSTGRES_WAL_ARCHIVE_TIMEOUT_SECONDS"]) { [string]$cfg["POSTGRES_WAL_ARCHIVE_TIMEOUT_SECONDS"] } else { "0" }
    "POSTGRES_MAX_WAL_SENDERS_HERE" = if ([string]$cfg["POSTGRES_MAX_WAL_SENDERS"]) { [string]$cfg["POSTGRES_MAX_WAL_SENDERS"] } else { "3" }
    "VALKEY_APPS_CONTAINER_NAME_HERE" = [string]$cfg["VALKEY_APPS_CONTAINER_NAME"]
    "VALKEY_HOST_PORT_HERE" = [string]$cfg["VALKEY_HOST_PORT"]
    "RABBITMQ_PLANE_CONTAINER_NAME_HERE" = [string]$cfg["RABBITMQ_PLANE_CONTAINER_NAME"]
    "PLANE_RABBITMQ_USER_HERE" = [string]$cfg["PLANE_RABBITMQ_USER"]
    "PLANE_RABBITMQ_PASSWORD_HERE" = [string]$cfg["PLANE_RABBITMQ_PASSWORD"]
    "PLANE_RABBITMQ_VHOST_HERE" = [string]$cfg["PLANE_RABBITMQ_VHOST"]
    "RABBITMQ_AMQP_HOST_PORT_HERE" = [string]$cfg["RABBITMQ_AMQP_HOST_PORT"]
    "RABBITMQ_UI_HOST_PORT_HERE" = [string]$cfg["RABBITMQ_UI_HOST_PORT"]
    "SEAWEEDFS_PLANE_CONTAINER_NAME_HERE" = [string]$cfg["SEAWEEDFS_PLANE_CONTAINER_NAME"]
    "SEAWEEDFS_S3_HOST_PORT_HERE" = [string]$cfg["SEAWEEDFS_S3_HOST_PORT"]
}

$composeContent = Render-Template -TemplatePath $composeTemplatePath -Tokens $composeTokens
$valkeyContent = Render-Template -TemplatePath $valkeyTemplatePath -Tokens @{ "APPS_VALKEY_PASSWORD_HERE" = [string]$cfg["APPS_VALKEY_PASSWORD"] }
$seaweedfsContent = Render-Template -TemplatePath $seaweedfsTemplatePath -Tokens @{
    "PLANE_S3_ACCESS_KEY_HERE" = [string]$cfg["PLANE_S3_ACCESS_KEY"]
    "PLANE_S3_SECRET_KEY_HERE" = [string]$cfg["PLANE_S3_SECRET_KEY"]
    "PLANE_S3_BUCKET_HERE" = [string]$cfg["PLANE_S3_BUCKET"]
}

if ($composeContent.Contains("_HERE") -or $valkeyContent.Contains("_HERE") -or $seaweedfsContent.Contains("_HERE")) {
    throw "Unresolved template placeholders detected in rendered output"
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($composeOut, $composeContent, $utf8NoBom)
[System.IO.File]::WriteAllText($valkeyOut, $valkeyContent, $utf8NoBom)
[System.IO.File]::WriteAllText($seaweedfsOut, $seaweedfsContent, $utf8NoBom)
Copy-Item -LiteralPath $postgresInitTemplatePath -Destination $postgresInitOut -Force
Copy-Item -LiteralPath $envPath -Destination $outputEnv -Force

Write-Host "Generated internal service layer files:"
Write-Host "- $composeOut"
Write-Host "- $valkeyOut"
Write-Host "- $seaweedfsOut"
Write-Host "- $postgresInitOut"
Write-Host "- $outputEnv"
