[CmdletBinding()]
param(
    [string]$EnvFile = "env/bootstrap.env",
    [switch]$ForcePassword,
    [switch]$ForceEncryptionPassword,
    [switch]$ForceSshKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$envPath = if ([System.IO.Path]::IsPathRooted($EnvFile)) { $EnvFile } else { Join-Path $repoRoot $EnvFile }
if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
    throw "Env file not found: $envPath`nCreate it first from env/bootstrap.env.example"
}

function New-RandomSecret {
    param([ValidateSet(24, 32)][int]$Length = 24)

    $byteLen = [int][Math]::Ceiling($Length / 2.0)
    $bytes = New-Object byte[] $byteLen
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    $hex = [System.BitConverter]::ToString($bytes).Replace("-", "").ToLowerInvariant()
    return $hex.Substring(0, $Length)
}

function Test-ValidSshPublicKey {
    param([string]$Key)
    return $Key -match '^ssh-(ed25519|rsa|ecdsa-[^\s]+)\s+'
}

function Get-DetectedSshPublicKey {
    $homes = @()
    if ($HOME) { $homes += $HOME }
    if ($env:USERPROFILE -and $env:USERPROFILE -ne $HOME) { $homes += $env:USERPROFILE }
    $homes = $homes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($home in $homes) {
        foreach ($name in @("id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub")) {
            $path = Join-Path $home ".ssh/$name"
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $key = (Get-Content -LiteralPath $path -TotalCount 1).Trim()
                if (Test-ValidSshPublicKey -Key $key) { return $key }
            }
        }
    }

    foreach ($home in $homes) {
        $sshDir = Join-Path $home ".ssh"
        if (-not (Test-Path -LiteralPath $sshDir -PathType Container)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $sshDir -Filter "*.pub" -File -ErrorAction SilentlyContinue) {
            $key = (Get-Content -LiteralPath $file.FullName -TotalCount 1).Trim()
            if (Test-ValidSshPublicKey -Key $key) { return $key }
        }
    }

    return $null
}

$detectedSshKey = Get-DetectedSshPublicKey
$hasDetectedSshKey = -not [string]::IsNullOrWhiteSpace($detectedSshKey)

$sawCoolifyPassword = $false
$sawEncryptionPassword = $false
$sawSshPublicKey = $false
$newLines = New-Object System.Collections.Generic.List[string]

foreach ($line in Get-Content -LiteralPath $envPath) {
    if ($line.StartsWith("SSH_PUBLIC_KEY=")) {
        $sawSshPublicKey = $true
        $current = $line.Substring("SSH_PUBLIC_KEY=".Length)
        $shouldReplace = $ForceSshKey -or [string]::IsNullOrWhiteSpace($current) -or $current -match "CHANGE_ME"
        if ($shouldReplace -and $hasDetectedSshKey) {
            $newLines.Add("SSH_PUBLIC_KEY=$detectedSshKey")
        } else {
            $newLines.Add($line)
        }
        continue
    }

    if ($line.StartsWith("COOLIFY_ROOT_USER_PASSWORD=")) {
        $sawCoolifyPassword = $true
        $current = $line.Substring("COOLIFY_ROOT_USER_PASSWORD=".Length)
        if ($ForcePassword -or [string]::IsNullOrWhiteSpace($current) -or $current -match "CHANGE_ME") {
            $newLines.Add("COOLIFY_ROOT_USER_PASSWORD=$(New-RandomSecret -Length 24)")
        } else {
            $newLines.Add($line)
        }
        continue
    }

    if ($line.StartsWith("USER_PASSWORDS_ENCRYPTION_PASSWORD=")) {
        $sawEncryptionPassword = $true
        $current = $line.Substring("USER_PASSWORDS_ENCRYPTION_PASSWORD=".Length)
        if ($ForceEncryptionPassword -or [string]::IsNullOrWhiteSpace($current) -or $current -match "CHANGE_ME") {
            $newLines.Add("USER_PASSWORDS_ENCRYPTION_PASSWORD=$(New-RandomSecret -Length 32)")
        } else {
            $newLines.Add($line)
        }
        continue
    }

    $newLines.Add($line)
}

if (-not $sawCoolifyPassword) {
    $newLines.Add("COOLIFY_ROOT_USER_PASSWORD=$(New-RandomSecret -Length 24)")
}

if (-not $sawEncryptionPassword) {
    $newLines.Add("USER_PASSWORDS_ENCRYPTION_PASSWORD=$(New-RandomSecret -Length 32)")
}

if (-not $sawSshPublicKey -and $hasDetectedSshKey) {
    $newLines.Add("SSH_PUBLIC_KEY=$detectedSshKey")
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($envPath, $newLines, $utf8NoBom)

Write-Host "Updated: $envPath"
Write-Host "WARNING: Env file contains secrets. On shared Windows systems, verify ACLs (for example with icacls)."
if ($hasDetectedSshKey) {
    Write-Host "SSH public key auto-detected and applied when needed."
} else {
    Write-Host "No local SSH public key detected; set SSH_PUBLIC_KEY or SSH_PUBLIC_KEY_PATH manually."
}
