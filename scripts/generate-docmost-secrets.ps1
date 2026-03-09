[CmdletBinding()]
param(
    [string]$EnvFile = "bootstrap-artifacts/docmost.env",
    [string]$InfraEnvFile = "bootstrap-artifacts/production-infra.env",
    [switch]$NoInfraSync,
    [switch]$ForceAppSecret,
    [switch]$ForceAll
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Host "[$Level] [$ts] [generate-docmost-secrets.ps1] $Message"
}

function Write-Info([string]$Message) { Write-Log -Level "INFO" -Message $Message }
function Write-Warn([string]$Message) { Write-Log -Level "WARNING" -Message $Message }
function Write-Success([string]$Message) { Write-Log -Level "SUCCESS" -Message $Message }
function Write-ErrorLog([string]$Message) { Write-Log -Level "ERROR" -Message $Message }

function Strip-EnvQuotes {
    param([string]$Value)
    if ($Value.StartsWith("'") -and $Value.EndsWith("'")) { return $Value.Substring(1, $Value.Length - 2) }
    if ($Value.StartsWith('"') -and $Value.EndsWith('"')) { return $Value.Substring(1, $Value.Length - 2) }
    return $Value
}

function Load-EnvMap {
    param([string]$Path)
    $map = @{}
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) { continue }
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { continue }
        $key = $line.Substring(0, $idx).Trim()
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
        $value = $line.Substring($idx + 1).Trim()
        $map[$key] = Strip-EnvQuotes -Value $value
    }
    return $map
}

function Format-EnvValue {
    param([string]$Value)
    if ($Value -notmatch "'") {
        return "'$Value'"
    }
    $escaped = $Value.Replace('\\', '\\\\').Replace('"', '\\"').Replace('$', '\\$')
    return '"' + $escaped + '"'
}

function Test-EmptyOrPlaceholder {
    param([string]$Value)
    return ([string]::IsNullOrWhiteSpace($Value) -or $Value.Contains("CHANGE_ME"))
}

function Test-UsableInfraValue {
    param([string]$Value)
    return (-not [string]::IsNullOrWhiteSpace($Value) -and -not $Value.Contains("CHANGE_ME"))
}

function New-HexSecret {
    param([int]$Bytes)
    if ($Bytes -lt 1) {
        throw "Bytes must be >= 1"
    }
    $buffer = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($buffer)
    } finally {
        $rng.Dispose()
    }
    return ([System.BitConverter]::ToString($buffer).Replace("-", "").ToLowerInvariant())
}

try {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $envPath = if ([System.IO.Path]::IsPathRooted($EnvFile)) { $EnvFile } else { Join-Path $repoRoot $EnvFile }
    $infraEnvPath = if ([System.IO.Path]::IsPathRooted($InfraEnvFile)) { $InfraEnvFile } else { Join-Path $repoRoot $InfraEnvFile }
    $envExamplePath = Join-Path $repoRoot "env/docmost-coolify.env.example"

    if (Test-Path -LiteralPath $envPath -PathType Container) { throw "--env-file points to a directory, expected a file: $envPath" }
    if (Test-Path -LiteralPath $infraEnvPath -PathType Container) { throw "--infra-env-file points to a directory, expected a file: $infraEnvPath" }
    if (-not (Test-Path -LiteralPath $envExamplePath -PathType Leaf)) { throw "missing template env file: $envExamplePath" }

    $envDir = Split-Path -Parent $envPath
    if (-not [string]::IsNullOrWhiteSpace($envDir) -and -not (Test-Path -LiteralPath $envDir -PathType Container)) {
        New-Item -ItemType Directory -Path $envDir -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
        Copy-Item -LiteralPath $envExamplePath -Destination $envPath
        Write-Success "Created env file from template: $envPath"
    }

    $cfg = Load-EnvMap -Path $envPath
    $infra = @{}
    $infraSyncApplied = $false

    if (-not $NoInfraSync) {
        if (Test-Path -LiteralPath $infraEnvPath -PathType Leaf) {
            $infra = Load-EnvMap -Path $infraEnvPath
        } else {
            Write-Warn "Infra env file not found, skipping infra sync: $infraEnvPath"
        }
    }

    $docmostImage = if ($cfg.ContainsKey("DOCMOST_IMAGE") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["DOCMOST_IMAGE"])) { [string]$cfg["DOCMOST_IMAGE"] } else { "docmost/docmost:latest" }
    $appUrl = if ($cfg.ContainsKey("APP_URL") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["APP_URL"])) { [string]$cfg["APP_URL"] } else { "https://docs.example.com" }
    $appSecret = if ($cfg.ContainsKey("APP_SECRET")) { [string]$cfg["APP_SECRET"] } else { "" }
    $databaseUrl = if ($cfg.ContainsKey("DATABASE_URL")) { [string]$cfg["DATABASE_URL"] } else { "" }
    $redisUrl = if ($cfg.ContainsKey("REDIS_URL")) { [string]$cfg["REDIS_URL"] } else { "" }
    $infraNetworkName = if ($cfg.ContainsKey("INFRA_NETWORK_NAME") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["INFRA_NETWORK_NAME"])) { [string]$cfg["INFRA_NETWORK_NAME"] } else { "infra" }
    $port = if ($cfg.ContainsKey("PORT") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["PORT"])) { [string]$cfg["PORT"] } else { "3000" }
    $storageDriver = if ($cfg.ContainsKey("STORAGE_DRIVER") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["STORAGE_DRIVER"])) { [string]$cfg["STORAGE_DRIVER"] } else { "s3" }
    $mailDriver = if ($cfg.ContainsKey("MAIL_DRIVER") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["MAIL_DRIVER"])) { [string]$cfg["MAIL_DRIVER"] } else { "smtp" }
    $smtpHost = if ($cfg.ContainsKey("SMTP_HOST") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["SMTP_HOST"])) { [string]$cfg["SMTP_HOST"] } else { "CHANGE_ME_smtp_host" }
    $smtpPort = if ($cfg.ContainsKey("SMTP_PORT") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["SMTP_PORT"])) { [string]$cfg["SMTP_PORT"] } else { "587" }
    $smtpUsername = if ($cfg.ContainsKey("SMTP_USERNAME") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["SMTP_USERNAME"])) { [string]$cfg["SMTP_USERNAME"] } else { "CHANGE_ME_smtp_username" }
    $smtpPassword = if ($cfg.ContainsKey("SMTP_PASSWORD") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["SMTP_PASSWORD"])) { [string]$cfg["SMTP_PASSWORD"] } else { "CHANGE_ME_smtp_password" }
    $smtpSecure = if ($cfg.ContainsKey("SMTP_SECURE") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["SMTP_SECURE"])) { [string]$cfg["SMTP_SECURE"] } else { "false" }
    $mailFromAddress = if ($cfg.ContainsKey("MAIL_FROM_ADDRESS") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["MAIL_FROM_ADDRESS"])) { [string]$cfg["MAIL_FROM_ADDRESS"] } else { "CHANGE_ME_mail_from_address" }
    $mailFromName = if ($cfg.ContainsKey("MAIL_FROM_NAME") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["MAIL_FROM_NAME"])) { [string]$cfg["MAIL_FROM_NAME"] } else { "Docmost" }
    $drawioUrl = if ($cfg.ContainsKey("DRAWIO_URL") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["DRAWIO_URL"])) { [string]$cfg["DRAWIO_URL"] } else { "https://embed.diagrams.net/?spin=1&proto=json&configure=1" }
    $awsS3AccessKeyId = if ($cfg.ContainsKey("AWS_S3_ACCESS_KEY_ID") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["AWS_S3_ACCESS_KEY_ID"])) { [string]$cfg["AWS_S3_ACCESS_KEY_ID"] } else { "CHANGE_ME_plane_s3_access_key" }
    $awsS3SecretAccessKey = if ($cfg.ContainsKey("AWS_S3_SECRET_ACCESS_KEY") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["AWS_S3_SECRET_ACCESS_KEY"])) { [string]$cfg["AWS_S3_SECRET_ACCESS_KEY"] } else { "CHANGE_ME_plane_s3_secret_key" }
    $awsS3Region = if ($cfg.ContainsKey("AWS_S3_REGION") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["AWS_S3_REGION"])) { [string]$cfg["AWS_S3_REGION"] } else { "eu-central-1" }
    $awsS3Bucket = if ($cfg.ContainsKey("AWS_S3_BUCKET") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["AWS_S3_BUCKET"])) { [string]$cfg["AWS_S3_BUCKET"] } else { "plane-uploads" }
    $awsS3Endpoint = if ($cfg.ContainsKey("AWS_S3_ENDPOINT") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["AWS_S3_ENDPOINT"])) { [string]$cfg["AWS_S3_ENDPOINT"] } else { "http://seaweedfs-plane:8333" }
    $awsS3ForcePathStyle = if ($cfg.ContainsKey("AWS_S3_FORCE_PATH_STYLE") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["AWS_S3_FORCE_PATH_STYLE"])) { [string]$cfg["AWS_S3_FORCE_PATH_STYLE"] } else { "true" }
    $disableTelemetry = if ($cfg.ContainsKey("DISABLE_TELEMETRY") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["DISABLE_TELEMETRY"])) { [string]$cfg["DISABLE_TELEMETRY"] } else { "true" }
    $searchDriver = if ($cfg.ContainsKey("SEARCH_DRIVER") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["SEARCH_DRIVER"])) { [string]$cfg["SEARCH_DRIVER"] } else { "typesense" }
    $typesenseUrl = if ($cfg.ContainsKey("TYPESENSE_URL") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["TYPESENSE_URL"])) { [string]$cfg["TYPESENSE_URL"] } else { "CHANGE_ME_typesense_url" }
    $typesenseApiKey = if ($cfg.ContainsKey("TYPESENSE_API_KEY") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["TYPESENSE_API_KEY"])) { [string]$cfg["TYPESENSE_API_KEY"] } else { "CHANGE_ME_typesense_api_key" }
    $typesenseLocale = if ($cfg.ContainsKey("TYPESENSE_LOCALE") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["TYPESENSE_LOCALE"])) { [string]$cfg["TYPESENSE_LOCALE"] } else { "en" }

    if ($ForceAll -or $ForceAppSecret -or (Test-EmptyOrPlaceholder -Value $appSecret)) {
        $appSecret = New-HexSecret -Bytes 32
    }

    if (-not $NoInfraSync -and $infra.Count -gt 0) {
        $postgresUser = if (Test-UsableInfraValue -Value ([string]$infra["POSTGRES_APPS_USER"])) { [string]$infra["POSTGRES_APPS_USER"] } else { "apps_admin" }
        $postgresPass = [string]$infra["POSTGRES_APPS_PASSWORD"]
        $postgresDb = if (Test-UsableInfraValue -Value ([string]$infra["POSTGRES_DOCMOST_DB"])) { [string]$infra["POSTGRES_DOCMOST_DB"] } else { "docmost" }
        $postgresHost = if (Test-UsableInfraValue -Value ([string]$infra["POSTGRES_APPS_CONTAINER_NAME"])) { [string]$infra["POSTGRES_APPS_CONTAINER_NAME"] } else { "postgres-apps" }

        $valkeyPass = [string]$infra["APPS_VALKEY_PASSWORD"]
        $valkeyHost = if (Test-UsableInfraValue -Value ([string]$infra["VALKEY_APPS_CONTAINER_NAME"])) { [string]$infra["VALKEY_APPS_CONTAINER_NAME"] } else { "valkey-apps" }
        $seaweedfsHost = if (Test-UsableInfraValue -Value ([string]$infra["SEAWEEDFS_PLANE_CONTAINER_NAME"])) { [string]$infra["SEAWEEDFS_PLANE_CONTAINER_NAME"] } else { "seaweedfs-plane" }

        if (Test-UsableInfraValue -Value ([string]$infra["INFRA_NETWORK_NAME"])) {
            $infraNetworkName = [string]$infra["INFRA_NETWORK_NAME"]
            $infraSyncApplied = $true
        }

        if (Test-UsableInfraValue -Value $postgresPass) {
            $databaseUrl = "postgresql://${postgresUser}:${postgresPass}@${postgresHost}:5432/${postgresDb}?schema=public"
            $infraSyncApplied = $true
        }

        if (Test-UsableInfraValue -Value $valkeyPass) {
            $redisUrl = "redis://default:${valkeyPass}@${valkeyHost}:6379/1"
            $infraSyncApplied = $true
        }

        if (Test-UsableInfraValue -Value ([string]$infra["MAIL_DRIVER"])) { $mailDriver = [string]$infra["MAIL_DRIVER"]; $infraSyncApplied = $true }
        if (Test-UsableInfraValue -Value ([string]$infra["SMTP_HOST"])) { $smtpHost = [string]$infra["SMTP_HOST"]; $infraSyncApplied = $true }
        if (Test-UsableInfraValue -Value ([string]$infra["SMTP_PORT"])) { $smtpPort = [string]$infra["SMTP_PORT"]; $infraSyncApplied = $true }
        if (Test-UsableInfraValue -Value ([string]$infra["SMTP_USERNAME"])) { $smtpUsername = [string]$infra["SMTP_USERNAME"]; $infraSyncApplied = $true }
        if (Test-UsableInfraValue -Value ([string]$infra["SMTP_PASSWORD"])) { $smtpPassword = [string]$infra["SMTP_PASSWORD"]; $infraSyncApplied = $true }
        if (Test-UsableInfraValue -Value ([string]$infra["SMTP_SECURE"])) { $smtpSecure = [string]$infra["SMTP_SECURE"]; $infraSyncApplied = $true }
        if (Test-UsableInfraValue -Value ([string]$infra["MAIL_FROM_ADDRESS"])) { $mailFromAddress = [string]$infra["MAIL_FROM_ADDRESS"]; $infraSyncApplied = $true }
        if (Test-UsableInfraValue -Value ([string]$infra["MAIL_FROM_NAME"])) { $mailFromName = [string]$infra["MAIL_FROM_NAME"]; $infraSyncApplied = $true }
        if (Test-UsableInfraValue -Value ([string]$infra["DRAWIO_URL"])) { $drawioUrl = [string]$infra["DRAWIO_URL"]; $infraSyncApplied = $true }

        if (Test-UsableInfraValue -Value ([string]$infra["PLANE_S3_ACCESS_KEY"])) { $awsS3AccessKeyId = [string]$infra["PLANE_S3_ACCESS_KEY"]; $infraSyncApplied = $true }
        if (Test-UsableInfraValue -Value ([string]$infra["PLANE_S3_SECRET_KEY"])) { $awsS3SecretAccessKey = [string]$infra["PLANE_S3_SECRET_KEY"]; $infraSyncApplied = $true }
        if (Test-UsableInfraValue -Value ([string]$infra["PLANE_S3_BUCKET"])) { $awsS3Bucket = [string]$infra["PLANE_S3_BUCKET"]; $infraSyncApplied = $true }
        if (Test-UsableInfraValue -Value ([string]$infra["AWS_S3_REGION"])) { $awsS3Region = [string]$infra["AWS_S3_REGION"]; $infraSyncApplied = $true }
        if (Test-UsableInfraValue -Value ([string]$infra["AWS_S3_ENDPOINT"])) {
            $awsS3Endpoint = [string]$infra["AWS_S3_ENDPOINT"]
            $infraSyncApplied = $true
        } elseif (Test-UsableInfraValue -Value $seaweedfsHost) {
            $awsS3Endpoint = "http://${seaweedfsHost}:8333"
            $infraSyncApplied = $true
        }
        if (Test-UsableInfraValue -Value ([string]$infra["AWS_S3_FORCE_PATH_STYLE"])) { $awsS3ForcePathStyle = [string]$infra["AWS_S3_FORCE_PATH_STYLE"]; $infraSyncApplied = $true }
        if (Test-UsableInfraValue -Value ([string]$infra["DISABLE_TELEMETRY"])) { $disableTelemetry = [string]$infra["DISABLE_TELEMETRY"]; $infraSyncApplied = $true }
        if (Test-UsableInfraValue -Value ([string]$infra["SEARCH_DRIVER"])) { $searchDriver = [string]$infra["SEARCH_DRIVER"]; $infraSyncApplied = $true }
        if (Test-UsableInfraValue -Value ([string]$infra["TYPESENSE_URL"])) { $typesenseUrl = [string]$infra["TYPESENSE_URL"]; $infraSyncApplied = $true }
        if (Test-UsableInfraValue -Value ([string]$infra["TYPESENSE_API_KEY"])) { $typesenseApiKey = [string]$infra["TYPESENSE_API_KEY"]; $infraSyncApplied = $true }
        if (Test-UsableInfraValue -Value ([string]$infra["TYPESENSE_LOCALE"])) { $typesenseLocale = [string]$infra["TYPESENSE_LOCALE"]; $infraSyncApplied = $true }
    }

    $managed = @(
        "DOCMOST_IMAGE", "APP_URL", "APP_SECRET", "DATABASE_URL", "REDIS_URL", "INFRA_NETWORK_NAME", "PORT", "STORAGE_DRIVER",
        "MAIL_DRIVER", "SMTP_HOST", "SMTP_PORT", "SMTP_USERNAME", "SMTP_PASSWORD", "SMTP_SECURE", "MAIL_FROM_ADDRESS", "MAIL_FROM_NAME",
        "DRAWIO_URL",
        "AWS_S3_ACCESS_KEY_ID", "AWS_S3_SECRET_ACCESS_KEY", "AWS_S3_REGION", "AWS_S3_BUCKET", "AWS_S3_ENDPOINT", "AWS_S3_FORCE_PATH_STYLE",
        "DISABLE_TELEMETRY", "SEARCH_DRIVER", "TYPESENSE_URL", "TYPESENSE_API_KEY", "TYPESENSE_LOCALE"
    )
    $values = @{
        "DOCMOST_IMAGE" = $docmostImage
        "APP_URL" = $appUrl
        "APP_SECRET" = $appSecret
        "DATABASE_URL" = $databaseUrl
        "REDIS_URL" = $redisUrl
        "INFRA_NETWORK_NAME" = $infraNetworkName
        "PORT" = $port
        "STORAGE_DRIVER" = $storageDriver
        "MAIL_DRIVER" = $mailDriver
        "SMTP_HOST" = $smtpHost
        "SMTP_PORT" = $smtpPort
        "SMTP_USERNAME" = $smtpUsername
        "SMTP_PASSWORD" = $smtpPassword
        "SMTP_SECURE" = $smtpSecure
        "MAIL_FROM_ADDRESS" = $mailFromAddress
        "MAIL_FROM_NAME" = $mailFromName
        "DRAWIO_URL" = $drawioUrl
        "AWS_S3_ACCESS_KEY_ID" = $awsS3AccessKeyId
        "AWS_S3_SECRET_ACCESS_KEY" = $awsS3SecretAccessKey
        "AWS_S3_REGION" = $awsS3Region
        "AWS_S3_BUCKET" = $awsS3Bucket
        "AWS_S3_ENDPOINT" = $awsS3Endpoint
        "AWS_S3_FORCE_PATH_STYLE" = $awsS3ForcePathStyle
        "DISABLE_TELEMETRY" = $disableTelemetry
        "SEARCH_DRIVER" = $searchDriver
        "TYPESENSE_URL" = $typesenseUrl
        "TYPESENSE_API_KEY" = $typesenseApiKey
        "TYPESENSE_LOCALE" = $typesenseLocale
    }

    $seen = @{}
    foreach ($key in $managed) { $seen[$key] = $false }

    $outLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in Get-Content -LiteralPath $envPath) {
        $m = [regex]::Match($line, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=')
        if (-not $m.Success) {
            $outLines.Add($line)
            continue
        }

        $key = $m.Groups[1].Value
        if ($key -eq "POSTMARK_TOKEN") {
            continue
        }
        if ($managed -contains $key) {
            $seen[$key] = $true
            $outLines.Add("$key=$(Format-EnvValue -Value ([string]$values[$key]))")
            continue
        }

        $outLines.Add($line)
    }

    foreach ($key in $managed) {
        if (-not $seen[$key]) {
            $outLines.Add("$key=$(Format-EnvValue -Value ([string]$values[$key]))")
        }
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($envPath, ($outLines -join "`n") + "`n", $utf8NoBom)

    Write-Success "Updated: $envPath"
    if ($infraSyncApplied) {
        Write-Success "Infra-derived Docmost values synchronized from: $infraEnvPath"
    } elseif (-not $NoInfraSync) {
        Write-Info "Infra sync not applied (missing or unresolved values in: $infraEnvPath)"
    } else {
        Write-Info "Infra sync disabled (-NoInfraSync)."
    }
    Write-Info "APP_SECRET generated/refreshed when needed."
} catch {
    Write-ErrorLog $_.Exception.Message
    exit 1
}
