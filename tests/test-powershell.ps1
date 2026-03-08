Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$GenerateScript = Join-Path $RepoRoot "scripts/generate-secrets.ps1"
$PrepareScript = Join-Path $RepoRoot "scripts/prepare-vps-coolify-init.ps1"
$TemplatePath = Join-Path $RepoRoot "templates/vps-init.template.yml"

$script:Total = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Match {
    param([string]$Text, [string]$Regex, [string]$Message)
    if ($Text -notmatch $Regex) { throw $Message }
}

function Env-Value {
    param([string]$File, [string]$Key)
    $line = Select-String -Path $File -Pattern "^$Key=" | Select-Object -Last 1
    if (-not $line) { return "" }
    return ($line.Line -replace "^$Key=", "")
}

function Strip-Quotes {
    param([string]$Value)
    if ($Value.StartsWith("'") -and $Value.EndsWith("'")) { return $Value.Substring(1, $Value.Length - 2) }
    if ($Value.StartsWith('"') -and $Value.EndsWith('"')) { return $Value.Substring(1, $Value.Length - 2) }
    return $Value
}

function New-TempDir {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("vps-tests-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Run-Test {
    param([string]$Name, [scriptblock]$Body)
    $script:Total++
    try {
        & $Body
        Write-Host "[PASS] $Name"
    } catch {
        $script:Failed++
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Invoke-NativeCommand {
    param(
        [scriptblock]$Command,
        [string]$Description,
        [switch]$ExpectFailure
    )

    $global:LASTEXITCODE = 0
    & $Command | Out-Null
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }

    if ($ExpectFailure) {
        if ($exitCode -eq 0) {
            throw "$Description should fail, but exited with code 0."
        }
        return
    }

    if ($exitCode -ne 0) {
        throw "$Description failed with exit code $exitCode."
    }
}

function Test-NativeCommandAvailable {
    param(
        [string]$Command,
        [string[]]$ProbeArgs = @("--version")
    )

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        $global:LASTEXITCODE = 0
        & $Command @ProbeArgs *> $null
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        return ($exitCode -eq 0)
    } catch {
        return $false
    }
}

Run-Test "generate-secrets.ps1 creates env + secrets + ssh autodetect" {
    $tmp = New-TempDir
    try {
        $homeFake = Join-Path $tmp "home"
        $sshDir = Join-Path $homeFake ".ssh"
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        Set-Content -Path (Join-Path $sshDir "id_ed25519.pub") -Value "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILocalPsKey local@test" -NoNewline

        $env:HOME = $homeFake
        $env:USERPROFILE = $homeFake

        $envFile = Join-Path $tmp "bootstrap/bootstrap.env"
        Invoke-NativeCommand -Description "generate-secrets (create env + autodetect)" -Command {
            & pwsh -NoLogo -NoProfile -File $GenerateScript -EnvFile $envFile
        }

        Assert-True (Test-Path -LiteralPath $envFile -PathType Leaf) "Env file should be created"
        $pw = Strip-Quotes (Env-Value -File $envFile -Key "COOLIFY_ROOT_USER_PASSWORD")
        $enc = Strip-Quotes (Env-Value -File $envFile -Key "USER_PASSWORDS_ENCRYPTION_PASSWORD")
        $ssh = Strip-Quotes (Env-Value -File $envFile -Key "SSH_PUBLIC_KEY")
        $sshPath = Strip-Quotes (Env-Value -File $envFile -Key "SSH_PUBLIC_KEY_PATH")

        Assert-Match $pw '^[0-9a-f]{24}$' "COOLIFY_ROOT_USER_PASSWORD should be 24 hex chars"
        Assert-Match $enc '^[0-9a-f]{32}$' "USER_PASSWORDS_ENCRYPTION_PASSWORD should be 32 hex chars"
        Assert-Match $ssh '^ssh-ed25519\s+' "SSH_PUBLIC_KEY should be auto-detected"
        Assert-Match $sshPath 'id_ed25519\.pub$' "SSH_PUBLIC_KEY_PATH should be auto-detected"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Run-Test "generate-secrets.ps1 force-encryption-password rotates only when requested" {
    $tmp = New-TempDir
    try {
        $homeFake = Join-Path $tmp "home"
        $sshDir = Join-Path $homeFake ".ssh"
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        Set-Content -Path (Join-Path $sshDir "id_ed25519.pub") -Value "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILocalPsKey local@test" -NoNewline

        $env:HOME = $homeFake
        $env:USERPROFILE = $homeFake

        $envFile = Join-Path $tmp "bootstrap.env"
        Copy-Item -LiteralPath (Join-Path $RepoRoot "env/bootstrap.env.example") -Destination $envFile

        Invoke-NativeCommand -Description "generate-secrets (initial)" -Command {
            & pwsh -NoLogo -NoProfile -File $GenerateScript -EnvFile $envFile
        }
        $first = Strip-Quotes (Env-Value -File $envFile -Key "USER_PASSWORDS_ENCRYPTION_PASSWORD")

        Invoke-NativeCommand -Description "generate-secrets (second run without force)" -Command {
            & pwsh -NoLogo -NoProfile -File $GenerateScript -EnvFile $envFile
        }
        $second = Strip-Quotes (Env-Value -File $envFile -Key "USER_PASSWORDS_ENCRYPTION_PASSWORD")
        Assert-True ($first -eq $second) "Encryption password should stay unchanged without -ForceEncryptionPassword"

        Invoke-NativeCommand -Description "generate-secrets (forced encryption password rotate)" -Command {
            & pwsh -NoLogo -NoProfile -File $GenerateScript -EnvFile $envFile -ForceEncryptionPassword
        }
        $third = Strip-Quotes (Env-Value -File $envFile -Key "USER_PASSWORDS_ENCRYPTION_PASSWORD")
        Assert-True ($third -ne $second) "Encryption password should rotate with -ForceEncryptionPassword"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Run-Test "generate-secrets.ps1 force-ssh-key replaces existing key/path" {
    $tmp = New-TempDir
    try {
        $homeFake = Join-Path $tmp "home"
        $sshDir = Join-Path $homeFake ".ssh"
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        Set-Content -Path (Join-Path $sshDir "id_ed25519.pub") -Value "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINewPsDetectedKey local@test" -NoNewline

        $env:HOME = $homeFake
        $env:USERPROFILE = $homeFake

        $envFile = Join-Path $tmp "bootstrap.env"
        Copy-Item -LiteralPath (Join-Path $RepoRoot "env/bootstrap.env.example") -Destination $envFile
        (Get-Content -LiteralPath $envFile -Raw).
            Replace("SSH_PUBLIC_KEY_PATH=CHANGE_ME_or_leave_empty", "SSH_PUBLIC_KEY_PATH='/old/path/old.pub'").
            Replace("SSH_PUBLIC_KEY=CHANGE_ME_ssh_public_key", "SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOldPsKey old@test'") |
            Set-Content -LiteralPath $envFile -NoNewline

        Invoke-NativeCommand -Description "generate-secrets (without -ForceSshKey)" -Command {
            & pwsh -NoLogo -NoProfile -File $GenerateScript -EnvFile $envFile
        }
        $noForcePath = Strip-Quotes (Env-Value -File $envFile -Key "SSH_PUBLIC_KEY_PATH")
        Assert-True ($noForcePath -eq "/old/path/old.pub") "SSH_PUBLIC_KEY_PATH should stay unchanged without -ForceSshKey"

        Invoke-NativeCommand -Description "generate-secrets (with -ForceSshKey)" -Command {
            & pwsh -NoLogo -NoProfile -File $GenerateScript -EnvFile $envFile -ForceSshKey
        }
        $forcedPath = Strip-Quotes (Env-Value -File $envFile -Key "SSH_PUBLIC_KEY_PATH")
        Assert-Match $forcedPath 'id_ed25519\.pub$' "SSH_PUBLIC_KEY_PATH should be replaced with detected path when forced"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Run-Test "prepare-vps-coolify-init.ps1 generates YAML for valid env" {
    $tmp = New-TempDir
    try {
        $envFile = Join-Path $tmp "bootstrap.env"
        $outFile = Join-Path $tmp "out.yml"
        $keyFile = Join-Path $tmp "id_ed25519.pub"
        Set-Content -Path $keyFile -Value "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPsPrepareKey test@ps" -NoNewline

        @"
TIMEZONE=UTC
SSH_PORT=2278
DEVOPS_USER=devops
COOLIFY_SUDO_NOPASSWD_USER=coolify
ADDITIONAL_SUDO_USERS=ops, qa;sec
SSH_PUBLIC_KEY=CHANGE_ME_ssh_public_key
SSH_PUBLIC_KEY_PATH=$keyFile
SSH_KEY_ROTATE=0
CLOSE_COOLIFY_REALTIME_PORTS=false
COOLIFY_REALTIME_DOMAIN=
COOLIFY_PUBLIC_DOMAIN=hub.example.com
COOLIFY_ROOT_USERNAME=admin_main
COOLIFY_ROOT_USER_EMAIL=admin@example.com
COOLIFY_ROOT_USER_PASSWORD=0123456789abcdef01234567
USER_PASSWORDS_ENCRYPTION_PASSWORD=0123456789abcdef0123456789abcdef
BOOTSTRAP_REPO_URL=https://github.com/rigu/vps-coolify-bootstrap.git
BOOTSTRAP_REPO_REF=main
TEMPLATE_FILE=$TemplatePath
OUTPUT_FILE=$outFile
"@ | Set-Content -Path $envFile -NoNewline

        Invoke-NativeCommand -Description "prepare-vps-coolify-init (valid env)" -Command {
            & pwsh -NoLogo -NoProfile -File $PrepareScript -EnvFile $envFile
        }
        Assert-True (Test-Path -LiteralPath $outFile -PathType Leaf) "Output YAML should be generated"

        $content = Get-Content -LiteralPath $outFile -Raw
        Assert-True (-not $content.Contains("_HERE")) "Output should not contain unreplaced placeholders"
        Assert-Match $content 'ssh_authorized_keys:' "Output should include ssh_authorized_keys"

        if (Test-NativeCommandAvailable -Command "python3" -ProbeArgs @("--version")) {
            Invoke-NativeCommand -Description "python3 yaml parse" -Command {
                & python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1], 'r', encoding='utf-8').read())" "$outFile"
            }
        } else {
            Write-Host "[INFO] python3 not available (or only Windows Store alias); skipping YAML parse check on this host."
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Run-Test "prepare-vps-coolify-init.ps1 closed mode falls back to COOLIFY_PUBLIC_DOMAIN when realtime domain missing" {
    $tmp = New-TempDir
    try {
        $envFile = Join-Path $tmp "bootstrap.env"
        $outFile = Join-Path $tmp "out.yml"

        @"
TIMEZONE=UTC
SSH_PORT=2278
DEVOPS_USER=devops
COOLIFY_SUDO_NOPASSWD_USER=coolify
ADDITIONAL_SUDO_USERS=
SSH_PUBLIC_KEY=
SSH_PUBLIC_KEY_PATH=
SSH_KEY_ROTATE=0
CLOSE_COOLIFY_REALTIME_PORTS=true
COOLIFY_REALTIME_DOMAIN=
COOLIFY_PUBLIC_DOMAIN=hub.example.com
COOLIFY_ROOT_USERNAME=admin_main
COOLIFY_ROOT_USER_EMAIL=admin@example.com
COOLIFY_ROOT_USER_PASSWORD=0123456789abcdef01234567
USER_PASSWORDS_ENCRYPTION_PASSWORD=0123456789abcdef0123456789abcdef
BOOTSTRAP_REPO_URL=https://github.com/rigu/vps-coolify-bootstrap.git
BOOTSTRAP_REPO_REF=main
TEMPLATE_FILE=$TemplatePath
OUTPUT_FILE=$outFile
"@ | Set-Content -Path $envFile -NoNewline

        Invoke-NativeCommand -Description "prepare-vps-coolify-init (close=true, realtime domain missing)" -Command {
            & pwsh -NoLogo -NoProfile -File $PrepareScript -EnvFile $envFile
        }
        Assert-True (Test-Path -LiteralPath $outFile -PathType Leaf) "Output YAML should be generated in closed mode with fallback domain"
        $content = Get-Content -LiteralPath $outFile -Raw
        Assert-Match $content "CLOSE_COOLIFY_REALTIME_PORTS=true" "Output should preserve close=true"
        Assert-Match $content "COOLIFY_REALTIME_DOMAIN=''" "Output should keep realtime domain empty when relying on fallback"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Run-Test "prepare-vps-coolify-init.ps1 fails when close=true and realtime domain is placeholder" {
    $tmp = New-TempDir
    try {
        $envFile = Join-Path $tmp "bootstrap.env"
        $outFile = Join-Path $tmp "out.yml"

        @"
TIMEZONE=UTC
SSH_PORT=2278
DEVOPS_USER=devops
COOLIFY_SUDO_NOPASSWD_USER=coolify
ADDITIONAL_SUDO_USERS=
SSH_PUBLIC_KEY=
SSH_PUBLIC_KEY_PATH=
SSH_KEY_ROTATE=0
CLOSE_COOLIFY_REALTIME_PORTS=true
COOLIFY_REALTIME_DOMAIN=CHANGE_ME_realtime.example.com
COOLIFY_PUBLIC_DOMAIN=hub.example.com
COOLIFY_ROOT_USERNAME=admin_main
COOLIFY_ROOT_USER_EMAIL=admin@example.com
COOLIFY_ROOT_USER_PASSWORD=0123456789abcdef01234567
USER_PASSWORDS_ENCRYPTION_PASSWORD=0123456789abcdef0123456789abcdef
BOOTSTRAP_REPO_URL=https://github.com/rigu/vps-coolify-bootstrap.git
BOOTSTRAP_REPO_REF=main
TEMPLATE_FILE=$TemplatePath
OUTPUT_FILE=$outFile
"@ | Set-Content -Path $envFile -NoNewline

        Invoke-NativeCommand -Description "prepare-vps-coolify-init (close=true, realtime domain placeholder)" -ExpectFailure -Command {
            & pwsh -NoLogo -NoProfile -File $PrepareScript -EnvFile $envFile
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Run-Test "prepare-vps-coolify-init.ps1 supports -EnvFile + -Overwrite together" {
    $tmp = New-TempDir
    try {
        $envFile = Join-Path $tmp "nested/config/bootstrap.env"
        $outFile = Join-Path $tmp "nested/output/out.yml"
        $keyFile = Join-Path $tmp "id_ed25519.pub"
        New-Item -ItemType Directory -Path (Split-Path -Parent $envFile) -Force | Out-Null
        Set-Content -Path $keyFile -Value "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPsPrepareKey test@ps" -NoNewline

        @"
TIMEZONE=UTC
SSH_PORT=2278
DEVOPS_USER=devops
COOLIFY_SUDO_NOPASSWD_USER=coolify
ADDITIONAL_SUDO_USERS=ops
SSH_PUBLIC_KEY=CHANGE_ME_ssh_public_key
SSH_PUBLIC_KEY_PATH=$keyFile
SSH_KEY_ROTATE=0
CLOSE_COOLIFY_REALTIME_PORTS=false
COOLIFY_REALTIME_DOMAIN=
COOLIFY_PUBLIC_DOMAIN=hub.example.com
COOLIFY_ROOT_USERNAME=admin_main
COOLIFY_ROOT_USER_EMAIL=admin@example.com
COOLIFY_ROOT_USER_PASSWORD=0123456789abcdef01234567
USER_PASSWORDS_ENCRYPTION_PASSWORD=0123456789abcdef0123456789abcdef
BOOTSTRAP_REPO_URL=https://github.com/rigu/vps-coolify-bootstrap.git
BOOTSTRAP_REPO_REF=main
TEMPLATE_FILE=$TemplatePath
OUTPUT_FILE=$outFile
"@ | Set-Content -Path $envFile -NoNewline

        Invoke-NativeCommand -Description "prepare-vps-coolify-init (initial render)" -Command {
            & pwsh -NoLogo -NoProfile -File $PrepareScript -EnvFile $envFile
        }
        $firstHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $outFile).Hash

        (Get-Content -LiteralPath $envFile -Raw).Replace("COOLIFY_PUBLIC_DOMAIN=hub.example.com", "COOLIFY_PUBLIC_DOMAIN=hub2.example.com") |
            Set-Content -LiteralPath $envFile -NoNewline

        Invoke-NativeCommand -Description "prepare-vps-coolify-init (-Overwrite rerender)" -Command {
            & pwsh -NoLogo -NoProfile -File $PrepareScript -EnvFile $envFile -Overwrite
        }
        $secondHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $outFile).Hash

        Assert-True ($firstHash -ne $secondHash) "Output should change on -EnvFile + -Overwrite rerender"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Run-Test "prepare-vps-coolify-init.ps1 defaults DEVOPS_USER when key is missing" {
    $tmp = New-TempDir
    try {
        $envFile = Join-Path $tmp "bootstrap.env"
        $outFile = Join-Path $tmp "out.yml"
        $keyFile = Join-Path $tmp "id_ed25519.pub"
        Set-Content -Path $keyFile -Value "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPsPrepareKey test@ps" -NoNewline

        @"
TIMEZONE=UTC
SSH_PORT=2278
COOLIFY_SUDO_NOPASSWD_USER=coolify
ADDITIONAL_SUDO_USERS=ops
SSH_PUBLIC_KEY=CHANGE_ME_ssh_public_key
SSH_PUBLIC_KEY_PATH=$keyFile
SSH_KEY_ROTATE=0
CLOSE_COOLIFY_REALTIME_PORTS=false
COOLIFY_REALTIME_DOMAIN=
COOLIFY_PUBLIC_DOMAIN=hub.example.com
COOLIFY_ROOT_USERNAME=admin_main
COOLIFY_ROOT_USER_EMAIL=admin@example.com
COOLIFY_ROOT_USER_PASSWORD=0123456789abcdef01234567
USER_PASSWORDS_ENCRYPTION_PASSWORD=0123456789abcdef0123456789abcdef
BOOTSTRAP_REPO_URL=https://github.com/rigu/vps-coolify-bootstrap.git
BOOTSTRAP_REPO_REF=main
TEMPLATE_FILE=$TemplatePath
OUTPUT_FILE=$outFile
"@ | Set-Content -Path $envFile -NoNewline

        Invoke-NativeCommand -Description "prepare-vps-coolify-init (default DEVOPS_USER)" -Command {
            & pwsh -NoLogo -NoProfile -File $PrepareScript -EnvFile $envFile
        }
        $content = Get-Content -LiteralPath $outFile -Raw
        Assert-Match $content 'name: devops' "Missing DEVOPS_USER should default to devops"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Run-Test "prepare-vps-coolify-init.ps1 fails when required env keys are missing or empty" {
    $requiredKeys = @(
        "TIMEZONE",
        "SSH_PORT",
        "COOLIFY_PUBLIC_DOMAIN",
        "COOLIFY_ROOT_USERNAME",
        "COOLIFY_ROOT_USER_EMAIL",
        "COOLIFY_ROOT_USER_PASSWORD",
        "USER_PASSWORDS_ENCRYPTION_PASSWORD",
        "BOOTSTRAP_REPO_URL",
        "BOOTSTRAP_REPO_REF"
    )

    foreach ($missingKey in $requiredKeys) {
        $tmp = New-TempDir
        try {
            $envFile = Join-Path $tmp "bootstrap.env"
            $outFile = Join-Path $tmp "out.yml"
            $keyFile = Join-Path $tmp "id_ed25519.pub"
            Set-Content -Path $keyFile -Value "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPsPrepareKey test@ps" -NoNewline

            @"
TIMEZONE=UTC
SSH_PORT=2278
DEVOPS_USER=devops
COOLIFY_SUDO_NOPASSWD_USER=coolify
ADDITIONAL_SUDO_USERS=ops
SSH_PUBLIC_KEY=CHANGE_ME_ssh_public_key
SSH_PUBLIC_KEY_PATH=$keyFile
SSH_KEY_ROTATE=0
CLOSE_COOLIFY_REALTIME_PORTS=false
COOLIFY_REALTIME_DOMAIN=
COOLIFY_PUBLIC_DOMAIN=hub.example.com
COOLIFY_ROOT_USERNAME=admin_main
COOLIFY_ROOT_USER_EMAIL=admin@example.com
COOLIFY_ROOT_USER_PASSWORD=0123456789abcdef01234567
USER_PASSWORDS_ENCRYPTION_PASSWORD=0123456789abcdef0123456789abcdef
BOOTSTRAP_REPO_URL=https://github.com/rigu/vps-coolify-bootstrap.git
BOOTSTRAP_REPO_REF=main
TEMPLATE_FILE=$TemplatePath
OUTPUT_FILE=$outFile
"@ | Set-Content -Path $envFile -NoNewline

            $lines = Get-Content -LiteralPath $envFile
            $lines = $lines | Where-Object { $_ -notmatch "^$missingKey=" }
            Set-Content -LiteralPath $envFile -Value $lines

            Invoke-NativeCommand -Description "prepare-vps-coolify-init (missing required key: $missingKey)" -ExpectFailure -Command {
                & pwsh -NoLogo -NoProfile -File $PrepareScript -EnvFile $envFile
            }
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Also verify present-but-empty required key fails.
    $tmp = New-TempDir
    try {
        $envFile = Join-Path $tmp "bootstrap.env"
        $outFile = Join-Path $tmp "out.yml"
        $keyFile = Join-Path $tmp "id_ed25519.pub"
        Set-Content -Path $keyFile -Value "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPsPrepareKey test@ps" -NoNewline
        @"
TIMEZONE=UTC
SSH_PORT=2278
DEVOPS_USER=devops
COOLIFY_SUDO_NOPASSWD_USER=coolify
ADDITIONAL_SUDO_USERS=ops
SSH_PUBLIC_KEY=CHANGE_ME_ssh_public_key
SSH_PUBLIC_KEY_PATH=$keyFile
SSH_KEY_ROTATE=0
CLOSE_COOLIFY_REALTIME_PORTS=false
COOLIFY_REALTIME_DOMAIN=
COOLIFY_PUBLIC_DOMAIN=
COOLIFY_ROOT_USERNAME=admin_main
COOLIFY_ROOT_USER_EMAIL=admin@example.com
COOLIFY_ROOT_USER_PASSWORD=0123456789abcdef01234567
USER_PASSWORDS_ENCRYPTION_PASSWORD=0123456789abcdef0123456789abcdef
BOOTSTRAP_REPO_URL=https://github.com/rigu/vps-coolify-bootstrap.git
BOOTSTRAP_REPO_REF=main
TEMPLATE_FILE=$TemplatePath
OUTPUT_FILE=$outFile
"@ | Set-Content -Path $envFile -NoNewline

        Invoke-NativeCommand -Description "prepare-vps-coolify-init (empty required value)" -ExpectFailure -Command {
            & pwsh -NoLogo -NoProfile -File $PrepareScript -EnvFile $envFile
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "PowerShell tests total: $script:Total"
Write-Host "PowerShell tests failed: $script:Failed"
if ($script:Failed -gt 0) {
    exit 1
}
