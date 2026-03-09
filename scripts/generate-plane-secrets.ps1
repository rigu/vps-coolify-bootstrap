[CmdletBinding()]
param(
    [string]$EnvFile = "bootstrap-artifacts/plane.env",
    [string]$InfraEnvFile = "bootstrap-artifacts/production-infra.env",
    [switch]$NoInfraSync,
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
$infraEnvPath = if ([System.IO.Path]::IsPathRooted($InfraEnvFile)) { $InfraEnvFile } else { Join-Path $repoRoot $InfraEnvFile }
$envExamplePath = Join-Path $repoRoot "env/plane-coolify.env.example"

if (-not (Test-Path -LiteralPath $envExamplePath -PathType Leaf)) {
    throw "Missing template env file: $envExamplePath"
}

if (Test-Path -LiteralPath $envPath -PathType Container) {
    throw "--env-file points to a directory, expected a file: $envPath"
}

if (Test-Path -LiteralPath $infraEnvPath -PathType Container) {
    throw "--infra-env-file points to a directory, expected a file: $infraEnvPath"
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

function Test-UsableInfraValue {
    param([string]$Value)
    return (-not [string]::IsNullOrWhiteSpace($Value)) -and (-not $Value.Contains("CHANGE_ME"))
}

function Load-EnvMap {
    param([string]$Path)

    $map = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^[\s]*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
        $idx = $line.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $line.Substring(0, $idx).Trim()
        $value = $line.Substring($idx + 1).Trim()
        $map[$key] = Strip-EnvQuotes -Value $value
    }
    return $map
}

$kv = Load-EnvMap -Path $envPath

$infra = @{}
$infraSyncApplied = $false
if (-not $NoInfraSync) {
    if (Test-Path -LiteralPath $infraEnvPath -PathType Leaf) {
        $infra = Load-EnvMap -Path $infraEnvPath
    } else {
        Write-Warning "Infra env file not found, skipping infra sync: $infraEnvPath"
    }
}

$secretKey = [string]($kv["SECRET_KEY"])
$postgresPassword = [string]($kv["POSTGRES_PASSWORD"])
$redisPassword = [string]($kv["REDIS_PASSWORD"])
$rabbitmqPassword = [string]($kv["RABBITMQ_DEFAULT_PASS"])
$awsAccessKey = [string]($kv["AWS_ACCESS_KEY_ID"])
$awsSecretKey = [string]($kv["AWS_SECRET_ACCESS_KEY"])
$siloSecret = [string]($kv["SILO_HMAC_SECRET_KEY"])
$liveSecret = [string]($kv["LIVE_SERVER_SECRET_KEY"])
$databaseUrl = [string]($kv["DATABASE_URL"])
$redisUrl = [string]($kv["REDIS_URL"])
$amqpUrl = [string]($kv["AMQP_URL"])

$postgresUser = if ($kv.ContainsKey("POSTGRES_USER") -and -not [string]::IsNullOrWhiteSpace([string]$kv["POSTGRES_USER"])) { [string]$kv["POSTGRES_USER"] } else { "apps_admin" }
$postgresHost = if ($kv.ContainsKey("POSTGRES_HOST") -and -not [string]::IsNullOrWhiteSpace([string]$kv["POSTGRES_HOST"])) { [string]$kv["POSTGRES_HOST"] } else { "postgres-apps" }
$postgresDb = if ($kv.ContainsKey("POSTGRES_DB") -and -not [string]::IsNullOrWhiteSpace([string]$kv["POSTGRES_DB"])) { [string]$kv["POSTGRES_DB"] } else { "plane" }
$redisHost = if ($kv.ContainsKey("REDIS_HOST") -and -not [string]::IsNullOrWhiteSpace([string]$kv["REDIS_HOST"])) { [string]$kv["REDIS_HOST"] } else { "valkey-apps" }
$redisPort = if ($kv.ContainsKey("REDIS_PORT") -and -not [string]::IsNullOrWhiteSpace([string]$kv["REDIS_PORT"])) { [string]$kv["REDIS_PORT"] } else { "6379" }
$rabbitmqUser = if ($kv.ContainsKey("RABBITMQ_DEFAULT_USER") -and -not [string]::IsNullOrWhiteSpace([string]$kv["RABBITMQ_DEFAULT_USER"])) { [string]$kv["RABBITMQ_DEFAULT_USER"] } else { "plane" }
$rabbitmqHost = if ($kv.ContainsKey("RABBITMQ_HOST") -and -not [string]::IsNullOrWhiteSpace([string]$kv["RABBITMQ_HOST"])) { [string]$kv["RABBITMQ_HOST"] } else { "rabbitmq-plane" }
$rabbitmqPort = if ($kv.ContainsKey("RABBITMQ_PORT") -and -not [string]::IsNullOrWhiteSpace([string]$kv["RABBITMQ_PORT"])) { [string]$kv["RABBITMQ_PORT"] } else { "5672" }
$rabbitmqVhost = if ($kv.ContainsKey("RABBITMQ_VHOST") -and -not [string]::IsNullOrWhiteSpace([string]$kv["RABBITMQ_VHOST"])) { [string]$kv["RABBITMQ_VHOST"] } elseif ($kv.ContainsKey("RABBITMQ_DEFAULT_VHOST") -and -not [string]::IsNullOrWhiteSpace([string]$kv["RABBITMQ_DEFAULT_VHOST"])) { [string]$kv["RABBITMQ_DEFAULT_VHOST"] } else { "plane" }
$awsS3BucketName = if ($kv.ContainsKey("AWS_S3_BUCKET_NAME") -and -not [string]::IsNullOrWhiteSpace([string]$kv["AWS_S3_BUCKET_NAME"])) { [string]$kv["AWS_S3_BUCKET_NAME"] } else { "plane-uploads" }
$bucketName = if ($kv.ContainsKey("BUCKET_NAME") -and -not [string]::IsNullOrWhiteSpace([string]$kv["BUCKET_NAME"])) { [string]$kv["BUCKET_NAME"] } else { "plane-uploads" }

$postgresPasswordFromInfra = $false
$redisPasswordFromInfra = $false
$rabbitmqPasswordFromInfra = $false
$awsAccessKeyFromInfra = $false
$awsSecretKeyFromInfra = $false

if (-not $NoInfraSync -and $infra.Count -gt 0) {
    if (Test-UsableInfraValue -Value ([string]$infra["POSTGRES_APPS_USER"])) {
        $postgresUser = [string]$infra["POSTGRES_APPS_USER"]
        $infraSyncApplied = $true
    }
    if (Test-UsableInfraValue -Value ([string]$infra["POSTGRES_APPS_CONTAINER_NAME"])) {
        $postgresHost = [string]$infra["POSTGRES_APPS_CONTAINER_NAME"]
        $infraSyncApplied = $true
    } elseif ((Test-UsableInfraValue -Value ([string]$infra["POSTGRES_APPS_USER"])) -or (Test-UsableInfraValue -Value ([string]$infra["POSTGRES_APPS_PASSWORD"]))) {
        $postgresHost = "postgres-apps"
        $infraSyncApplied = $true
    }
    if (Test-UsableInfraValue -Value ([string]$infra["POSTGRES_PLANE_DB"])) {
        $postgresDb = [string]$infra["POSTGRES_PLANE_DB"]
        $infraSyncApplied = $true
    }
    if (Test-UsableInfraValue -Value ([string]$infra["POSTGRES_APPS_PASSWORD"])) {
        $postgresPassword = [string]$infra["POSTGRES_APPS_PASSWORD"]
        $postgresPasswordFromInfra = $true
        $infraSyncApplied = $true
    }

    if (Test-UsableInfraValue -Value ([string]$infra["VALKEY_APPS_CONTAINER_NAME"])) {
        $redisHost = [string]$infra["VALKEY_APPS_CONTAINER_NAME"]
        $infraSyncApplied = $true
    } elseif (Test-UsableInfraValue -Value ([string]$infra["APPS_VALKEY_PASSWORD"])) {
        $redisHost = "valkey-apps"
        $infraSyncApplied = $true
    }
    if (Test-UsableInfraValue -Value ([string]$infra["APPS_VALKEY_PASSWORD"])) {
        $redisPassword = [string]$infra["APPS_VALKEY_PASSWORD"]
        $redisPasswordFromInfra = $true
        $infraSyncApplied = $true
    }

    if (Test-UsableInfraValue -Value ([string]$infra["RABBITMQ_PLANE_CONTAINER_NAME"])) {
        $rabbitmqHost = [string]$infra["RABBITMQ_PLANE_CONTAINER_NAME"]
        $infraSyncApplied = $true
    } elseif ((Test-UsableInfraValue -Value ([string]$infra["PLANE_RABBITMQ_USER"])) -or (Test-UsableInfraValue -Value ([string]$infra["PLANE_RABBITMQ_PASSWORD"]))) {
        $rabbitmqHost = "rabbitmq-plane"
        $infraSyncApplied = $true
    }
    if (Test-UsableInfraValue -Value ([string]$infra["PLANE_RABBITMQ_USER"])) {
        $rabbitmqUser = [string]$infra["PLANE_RABBITMQ_USER"]
        $infraSyncApplied = $true
    }
    if (Test-UsableInfraValue -Value ([string]$infra["PLANE_RABBITMQ_VHOST"])) {
        $rabbitmqVhost = [string]$infra["PLANE_RABBITMQ_VHOST"]
        $infraSyncApplied = $true
    }
    if (Test-UsableInfraValue -Value ([string]$infra["PLANE_RABBITMQ_PASSWORD"])) {
        $rabbitmqPassword = [string]$infra["PLANE_RABBITMQ_PASSWORD"]
        $rabbitmqPasswordFromInfra = $true
        $infraSyncApplied = $true
    }

    if (Test-UsableInfraValue -Value ([string]$infra["PLANE_S3_ACCESS_KEY"])) {
        $awsAccessKey = [string]$infra["PLANE_S3_ACCESS_KEY"]
        $awsAccessKeyFromInfra = $true
        $infraSyncApplied = $true
    }
    if (Test-UsableInfraValue -Value ([string]$infra["PLANE_S3_SECRET_KEY"])) {
        $awsSecretKey = [string]$infra["PLANE_S3_SECRET_KEY"]
        $awsSecretKeyFromInfra = $true
        $infraSyncApplied = $true
    }
    if (Test-UsableInfraValue -Value ([string]$infra["PLANE_S3_BUCKET"])) {
        $awsS3BucketName = [string]$infra["PLANE_S3_BUCKET"]
        $bucketName = [string]$infra["PLANE_S3_BUCKET"]
        $infraSyncApplied = $true
    }
}

$passwordsChanged = $false
$secretsChanged = $false

if ($ForceSecrets -or (Test-EmptyOrPlaceholder -Value $secretKey)) {
    $secretKey = New-HexSecret -HexLength 64
    $secretsChanged = $true
}

if ((-not $postgresPasswordFromInfra) -and ($ForcePasswords -or (Test-EmptyOrPlaceholder -Value $postgresPassword))) {
    $postgresPassword = New-HexSecret -HexLength 32
    $passwordsChanged = $true
}

if ((-not $redisPasswordFromInfra) -and ($ForcePasswords -or (Test-EmptyOrPlaceholder -Value $redisPassword))) {
    $redisPassword = New-HexSecret -HexLength 32
    $passwordsChanged = $true
}

if ((-not $rabbitmqPasswordFromInfra) -and ($ForcePasswords -or (Test-EmptyOrPlaceholder -Value $rabbitmqPassword))) {
    $rabbitmqPassword = New-HexSecret -HexLength 32
    $passwordsChanged = $true
}

if ((-not $awsAccessKeyFromInfra) -and ($ForceSecrets -or (Test-EmptyOrPlaceholder -Value $awsAccessKey))) {
    $awsAccessKey = "PLN" + (New-HexSecret -HexLength 18).ToUpperInvariant()
    $secretsChanged = $true
}

if ((-not $awsSecretKeyFromInfra) -and ($ForceSecrets -or (Test-EmptyOrPlaceholder -Value $awsSecretKey))) {
    $awsSecretKey = New-HexSecret -HexLength 64
    $secretsChanged = $true
}

if ($ForceSecrets -or (Test-EmptyOrPlaceholder -Value $siloSecret)) {
    $siloSecret = New-HexSecret -HexLength 64
    $secretsChanged = $true
}

if ($ForceSecrets -or (Test-EmptyOrPlaceholder -Value $liveSecret)) {
    $liveSecret = New-HexSecret -HexLength 64
    $secretsChanged = $true
}

if ($passwordsChanged -or $infraSyncApplied -or (Test-EmptyOrPlaceholder -Value $databaseUrl)) {
    $databaseUrl = "postgresql://$postgresUser`:$postgresPassword@$postgresHost`:5432/$postgresDb"
}

if ($passwordsChanged -or $infraSyncApplied -or (Test-EmptyOrPlaceholder -Value $redisUrl)) {
    $redisUrl = "redis://default`:$redisPassword@$redisHost`:$redisPort/0"
}

if ($passwordsChanged -or $infraSyncApplied -or (Test-EmptyOrPlaceholder -Value $amqpUrl)) {
    $amqpUrl = "amqp://$rabbitmqUser`:$rabbitmqPassword@$rabbitmqHost`:$rabbitmqPort/$rabbitmqVhost"
}

$newLines = New-Object System.Collections.Generic.List[string]
$saw = @{
    "SECRET_KEY" = $false
    "POSTGRES_PASSWORD" = $false
    "REDIS_PASSWORD" = $false
    "RABBITMQ_DEFAULT_PASS" = $false
    "AWS_ACCESS_KEY_ID" = $false
    "AWS_SECRET_ACCESS_KEY" = $false
    "SILO_HMAC_SECRET_KEY" = $false
    "LIVE_SERVER_SECRET_KEY" = $false
    "DATABASE_URL" = $false
    "REDIS_URL" = $false
    "AMQP_URL" = $false
    "POSTGRES_USER" = $false
    "POSTGRES_DB" = $false
    "POSTGRES_HOST" = $false
    "REDIS_HOST" = $false
    "RABBITMQ_HOST" = $false
    "RABBITMQ_DEFAULT_USER" = $false
    "RABBITMQ_DEFAULT_VHOST" = $false
    "RABBITMQ_VHOST" = $false
    "AWS_S3_BUCKET_NAME" = $false
    "BUCKET_NAME" = $false
}

$updated = @{
    "SECRET_KEY" = $secretKey
    "POSTGRES_PASSWORD" = $postgresPassword
    "REDIS_PASSWORD" = $redisPassword
    "RABBITMQ_DEFAULT_PASS" = $rabbitmqPassword
    "AWS_ACCESS_KEY_ID" = $awsAccessKey
    "AWS_SECRET_ACCESS_KEY" = $awsSecretKey
    "SILO_HMAC_SECRET_KEY" = $siloSecret
    "LIVE_SERVER_SECRET_KEY" = $liveSecret
    "DATABASE_URL" = $databaseUrl
    "REDIS_URL" = $redisUrl
    "AMQP_URL" = $amqpUrl
    "POSTGRES_USER" = $postgresUser
    "POSTGRES_DB" = $postgresDb
    "POSTGRES_HOST" = $postgresHost
    "REDIS_HOST" = $redisHost
    "RABBITMQ_HOST" = $rabbitmqHost
    "RABBITMQ_DEFAULT_USER" = $rabbitmqUser
    "RABBITMQ_DEFAULT_VHOST" = $rabbitmqVhost
    "RABBITMQ_VHOST" = $rabbitmqVhost
    "AWS_S3_BUCKET_NAME" = $awsS3BucketName
    "BUCKET_NAME" = $bucketName
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
    Write-Host "Plane passwords generated/refreshed (POSTGRES_PASSWORD, REDIS_PASSWORD, RABBITMQ_DEFAULT_PASS)."
} else {
    Write-Host "Plane passwords kept (use -ForcePasswords to rotate)."
}
if ($secretsChanged) {
    Write-Host "Plane secrets generated/refreshed (SECRET_KEY, AWS/SILO/LIVE secrets)."
} else {
    Write-Host "Plane secrets kept (use -ForceSecrets to rotate)."
}
Write-Host "Dependent URLs synchronized when needed: DATABASE_URL, REDIS_URL, AMQP_URL."
if ($infraSyncApplied) {
    Write-Host "Infra-derived Plane values synchronized from: $infraEnvPath"
} elseif (-not $NoInfraSync) {
    Write-Host "Infra sync not applied (missing or unresolved values in: $infraEnvPath)"
} else {
    Write-Host "Infra sync disabled (-NoInfraSync)."
}
