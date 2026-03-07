[CmdletBinding()]
param(
    [string]$EnvFile = "env/bootstrap.env",
    [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$envPath = if ([System.IO.Path]::IsPathRooted($EnvFile)) { $EnvFile } else { Join-Path $repoRoot $EnvFile }
if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
    throw "Env file not found: $envPath"
}

$cfg = @{}
foreach ($line in Get-Content -LiteralPath $envPath) {
    $t = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($t) -or $t.StartsWith("#")) { continue }
    $i = $t.IndexOf("=")
    if ($i -lt 1) { throw "Invalid env line: $line" }
    $key = $t.Substring(0, $i).Trim()
    $value = $t.Substring($i + 1).Trim()
    if ($value.Length -ge 2) {
        if (($value.StartsWith("'") -and $value.EndsWith("'")) -or ($value.StartsWith('"') -and $value.EndsWith('"'))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
    }
    $cfg[$key] = $value
}

foreach ($k in @(
    "TIMEZONE","SSH_PORT","PRIMARY_SUDO_USER","SECONDARY_SUDO_USER",
    "CREATE_USERS","SUDO_USERS","DOCKER_USERS","COOLIFY_GROUP_USERS",
    "COOLIFY_PUBLIC_DOMAIN","COOLIFY_ROOT_USERNAME","COOLIFY_ROOT_USER_EMAIL","COOLIFY_ROOT_USER_PASSWORD","USER_PASSWORDS_ENCRYPTION_PASSWORD",
    "BOOTSTRAP_REPO_URL","BOOTSTRAP_REPO_REF"
)) {
    if (-not $cfg.ContainsKey($k) -or [string]::IsNullOrWhiteSpace([string]$cfg[$k])) {
        throw "Missing required key: $k"
    }
}

$sshPort = [string]$cfg["SSH_PORT"]
if ($sshPort -notmatch '^\d+$') { throw "SSH_PORT must be numeric (1-65535)." }
$sshPortNum = [int]$sshPort
if ($sshPortNum -lt 1 -or $sshPortNum -gt 65535) { throw "SSH_PORT must be between 1 and 65535." }
if ([string]$cfg["TIMEZONE"] -notmatch '^[A-Za-z0-9_+./-]+$') { throw "TIMEZONE contains invalid characters." }

$coolifyPublicDomain = [string]$cfg["COOLIFY_PUBLIC_DOMAIN"]
if ($coolifyPublicDomain -match '[\s/]') { throw "COOLIFY_PUBLIC_DOMAIN must be a hostname without spaces or /." }
if ($cfg["COOLIFY_ROOT_USER_EMAIL"] -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') { throw "COOLIFY_ROOT_USER_EMAIL must be a valid email format." }
if ($cfg["COOLIFY_ROOT_USERNAME"] -notmatch '^[A-Za-z0-9._-]+$') { throw "COOLIFY_ROOT_USERNAME must match ^[A-Za-z0-9._-]+$." }

$createUsers = ([string]$cfg["CREATE_USERS"]).Split(",") | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$primarySudoUser = [string]$cfg["PRIMARY_SUDO_USER"]
$secondarySudoUser = [string]$cfg["SECONDARY_SUDO_USER"]
if (-not ($createUsers -contains $primarySudoUser)) { throw "PRIMARY_SUDO_USER must be present in CREATE_USERS." }
if (-not ($createUsers -contains $secondarySudoUser)) { throw "SECONDARY_SUDO_USER must be present in CREATE_USERS." }
function Test-ValidUnixUsername {
    param([string]$User)
    return ($User -match '^[a-z_][a-z0-9_-]*[$]?$')
}

function Validate-UserListSubset {
    param(
        [string]$ListName,
        [string]$Csv,
        [string[]]$CreateUsers
    )

    $users = $Csv.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($user in $users) {
        if ($user.Contains(":")) { throw "${ListName} contains invalid username (colon not allowed): $user" }
        if (-not (Test-ValidUnixUsername -User $user)) { throw "${ListName} contains invalid UNIX username: $user" }
        if (-not ($CreateUsers -contains $user)) { throw "${ListName} contains user not present in CREATE_USERS: $user" }
    }
}

foreach ($user in $createUsers) {
    if ($user.Contains(":")) { throw "CREATE_USERS contains invalid username (colon not allowed): $user" }
    if (-not (Test-ValidUnixUsername -User $user)) { throw "CREATE_USERS contains invalid UNIX username: $user" }
}
Validate-UserListSubset -ListName "SUDO_USERS" -Csv ([string]$cfg["SUDO_USERS"]) -CreateUsers $createUsers
Validate-UserListSubset -ListName "DOCKER_USERS" -Csv ([string]$cfg["DOCKER_USERS"]) -CreateUsers $createUsers
Validate-UserListSubset -ListName "COOLIFY_GROUP_USERS" -Csv ([string]$cfg["COOLIFY_GROUP_USERS"]) -CreateUsers $createUsers

$templatePath = if ($cfg.ContainsKey("TEMPLATE_FILE") -and $cfg["TEMPLATE_FILE"]) { $cfg["TEMPLATE_FILE"] } else { "../templates/cloud-init.template.yml" }
$outputPath = if ($cfg.ContainsKey("OUTPUT_FILE") -and $cfg["OUTPUT_FILE"]) { $cfg["OUTPUT_FILE"] } else { "../cloud-init.generated.yml" }
if (-not [System.IO.Path]::IsPathRooted($templatePath)) { $templatePath = Join-Path (Split-Path -Parent $envPath) $templatePath }
if (-not [System.IO.Path]::IsPathRooted($outputPath)) { $outputPath = Join-Path (Split-Path -Parent $envPath) $outputPath }
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw "Template file not found: $templatePath" }

$ssh = if ($cfg.ContainsKey("SSH_PUBLIC_KEY") -and $cfg["SSH_PUBLIC_KEY"] -and $cfg["SSH_PUBLIC_KEY"] -notmatch "CHANGE_ME") {
    [string]$cfg["SSH_PUBLIC_KEY"]
} else {
    if (-not $cfg.ContainsKey("SSH_PUBLIC_KEY_PATH") -or [string]::IsNullOrWhiteSpace([string]$cfg["SSH_PUBLIC_KEY_PATH"]) -or [string]$cfg["SSH_PUBLIC_KEY_PATH"] -match "CHANGE_ME") {
        throw "Set SSH_PUBLIC_KEY or SSH_PUBLIC_KEY_PATH in env file"
    }
    $k = [string]$cfg["SSH_PUBLIC_KEY_PATH"]
    if (-not [System.IO.Path]::IsPathRooted($k)) { $k = Join-Path (Split-Path -Parent $envPath) $k }
    if (-not (Test-Path -LiteralPath $k -PathType Leaf)) { throw "SSH public key file not found: $k" }
    (Get-Content -LiteralPath $k -Raw).Trim()
}

if ($ssh -notmatch '^ssh-(ed25519|rsa|ecdsa-[^\s]+)\s') { throw "Invalid SSH public key format." }
if ([string]$cfg["COOLIFY_ROOT_USER_PASSWORD"].Length -lt 16) { throw "COOLIFY_ROOT_USER_PASSWORD must be at least 16 characters." }
if ([string]$cfg["USER_PASSWORDS_ENCRYPTION_PASSWORD"].Length -lt 16) { throw "USER_PASSWORDS_ENCRYPTION_PASSWORD must be at least 16 characters." }
$sshKeyRotate = if ($cfg.ContainsKey("SSH_KEY_ROTATE") -and -not [string]::IsNullOrWhiteSpace([string]$cfg["SSH_KEY_ROTATE"])) { [string]$cfg["SSH_KEY_ROTATE"] } else { "0" }
if ($sshKeyRotate -ne "0" -and $sshKeyRotate -ne "1") { throw "SSH_KEY_ROTATE must be 0 or 1." }

foreach ($v in @(
    [string]$cfg["COOLIFY_ROOT_USERNAME"],
    [string]$cfg["COOLIFY_ROOT_USER_EMAIL"],
    [string]$cfg["COOLIFY_ROOT_USER_PASSWORD"],
    [string]$cfg["COOLIFY_PUBLIC_DOMAIN"],
    [string]$cfg["USER_PASSWORDS_ENCRYPTION_PASSWORD"],
    [string]$cfg["PRIMARY_SUDO_USER"],
    [string]$cfg["SECONDARY_SUDO_USER"],
    [string]$cfg["CREATE_USERS"],
    [string]$cfg["SUDO_USERS"],
    [string]$cfg["DOCKER_USERS"],
    [string]$cfg["COOLIFY_GROUP_USERS"],
    [string]$cfg["BOOTSTRAP_REPO_URL"],
    [string]$cfg["BOOTSTRAP_REPO_REF"]
)) {
    if ($v -match "CHANGE_ME") { throw "Replace CHANGE_ME values in env file." }
}

foreach ($v in @(
    [string]$ssh,
    [string]$cfg["TIMEZONE"],
    [string]$cfg["COOLIFY_PUBLIC_DOMAIN"],
    [string]$cfg["COOLIFY_ROOT_USERNAME"],
    [string]$cfg["COOLIFY_ROOT_USER_EMAIL"],
    [string]$cfg["COOLIFY_ROOT_USER_PASSWORD"],
    [string]$cfg["USER_PASSWORDS_ENCRYPTION_PASSWORD"],
    [string]$cfg["BOOTSTRAP_REPO_URL"],
    [string]$cfg["BOOTSTRAP_REPO_REF"]
)) {
    if ($v.Contains("'")) { throw "Values used in template must not contain single quotes (')." }
}

$content = Get-Content -LiteralPath $templatePath -Raw
$map = [ordered]@{
    "TIMEZONE_HERE" = [string]$cfg["TIMEZONE"]
    "SSH_PORT_HERE" = [string]$cfg["SSH_PORT"]
    "PRIMARY_SUDO_USER_HERE" = [string]$cfg["PRIMARY_SUDO_USER"]
    "SECONDARY_SUDO_USER_HERE" = [string]$cfg["SECONDARY_SUDO_USER"]
    "SSH_PUBLIC_KEY_HERE" = [string]$ssh
    "SSH_KEY_ROTATE_HERE" = [string]$sshKeyRotate
    "CREATE_USERS_HERE" = [string]$cfg["CREATE_USERS"]
    "SUDO_USERS_HERE" = [string]$cfg["SUDO_USERS"]
    "DOCKER_USERS_HERE" = [string]$cfg["DOCKER_USERS"]
    "COOLIFY_GROUP_USERS_HERE" = [string]$cfg["COOLIFY_GROUP_USERS"]
    "COOLIFY_PUBLIC_DOMAIN_HERE" = [string]$cfg["COOLIFY_PUBLIC_DOMAIN"]
    "COOLIFY_ROOT_USERNAME_HERE" = [string]$cfg["COOLIFY_ROOT_USERNAME"]
    "COOLIFY_ROOT_USER_EMAIL_HERE" = [string]$cfg["COOLIFY_ROOT_USER_EMAIL"]
    "COOLIFY_ROOT_USER_PASSWORD_HERE" = [string]$cfg["COOLIFY_ROOT_USER_PASSWORD"]
    "USER_PASSWORDS_ENCRYPTION_PASSWORD_HERE" = [string]$cfg["USER_PASSWORDS_ENCRYPTION_PASSWORD"]
    "BOOTSTRAP_REPO_URL_HERE" = [string]$cfg["BOOTSTRAP_REPO_URL"]
    "BOOTSTRAP_REPO_REF_HERE" = [string]$cfg["BOOTSTRAP_REPO_REF"]
}
foreach ($k in $map.Keys) { $content = $content.Replace($k, $map[$k]) }

foreach ($token in $map.Keys) {
    if ($content.Contains($token)) {
        throw "Unreplaced placeholder: $token"
    }
}

if ((Test-Path -LiteralPath $outputPath -PathType Leaf) -and -not $Overwrite) {
    throw "Output file exists: $outputPath (use -Overwrite)."
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outputPath, $content, $utf8NoBom)
$size = (Get-Item -LiteralPath $outputPath).Length
if ($size -gt 32768) { throw "Generated cloud-init is ${size} bytes (>32768 Hetzner limit)." }
Write-Host "Generated: $outputPath"
Write-Host "WARNING: Generated cloud-init contains secrets. On shared Windows systems, verify ACLs (for example with icacls)."
