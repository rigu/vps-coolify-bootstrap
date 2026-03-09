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
    if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
        throw "openssl is required for secret generation."
    }
    $output = & openssl rand -hex $Bytes
    if ($LASTEXITCODE -ne 0) {
        throw "openssl rand failed"
    }
    return ([string]$output).Trim()
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
    $storageDriver = if ($cfg.ContainsKey("STORAGE_DRIVER") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["STORAGE_DRIVER"])) { [string]$cfg["STORAGE_DRIVER"] } else { "local" }

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
    }

    $managed = @("DOCMOST_IMAGE", "APP_URL", "APP_SECRET", "DATABASE_URL", "REDIS_URL", "INFRA_NETWORK_NAME", "PORT", "STORAGE_DRIVER")
    $values = @{
        "DOCMOST_IMAGE" = $docmostImage
        "APP_URL" = $appUrl
        "APP_SECRET" = $appSecret
        "DATABASE_URL" = $databaseUrl
        "REDIS_URL" = $redisUrl
        "INFRA_NETWORK_NAME" = $infraNetworkName
        "PORT" = $port
        "STORAGE_DRIVER" = $storageDriver
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
