Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$GenerateScript = Join-Path $RepoRoot "scripts/generate-secrets.ps1"
$GenerateInfraScript = Join-Path $RepoRoot "scripts/generate-infra-secrets.ps1"
$GeneratePlaneScript = Join-Path $RepoRoot "scripts/generate-plane-secrets.ps1"
$PrepareInfraScript = Join-Path $RepoRoot "scripts/prepare-infra-compose.ps1"
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

        Assert-True ($pw.Length -ge 16) "COOLIFY_ROOT_USER_PASSWORD should be at least 16 chars"
        Assert-Match $pw '[a-z]' "COOLIFY_ROOT_USER_PASSWORD should contain lowercase"
        Assert-Match $pw '[A-Z]' "COOLIFY_ROOT_USER_PASSWORD should contain uppercase"
        Assert-Match $pw '[0-9]' "COOLIFY_ROOT_USER_PASSWORD should contain digits"
        Assert-Match $pw '[^A-Za-z0-9]' "COOLIFY_ROOT_USER_PASSWORD should contain symbols"
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

Run-Test "generate-plane-secrets.ps1 creates env + generated values" {
    $tmp = New-TempDir
    try {
        $envFile = Join-Path $tmp "plane/plane.env"
        Invoke-NativeCommand -Description "generate-plane-secrets (create env + generate values)" -Command {
            & pwsh -NoLogo -NoProfile -File $GeneratePlaneScript -EnvFile $envFile -NoInfraSync
        }

        Assert-True (Test-Path -LiteralPath $envFile -PathType Leaf) "Plane env file should be created"
        $secret = Strip-Quotes (Env-Value -File $envFile -Key "SECRET_KEY")
        $dbPass = Strip-Quotes (Env-Value -File $envFile -Key "POSTGRES_PASSWORD")
        $dbUrl = Strip-Quotes (Env-Value -File $envFile -Key "DATABASE_URL")
        $amqpPass = Strip-Quotes (Env-Value -File $envFile -Key "RABBITMQ_DEFAULT_PASS")
        $amqpUrl = Strip-Quotes (Env-Value -File $envFile -Key "AMQP_URL")

        Assert-Match $secret '^[0-9a-f]{64}$' "SECRET_KEY should be 64 hex chars"
        Assert-Match $dbPass '^[0-9a-f]{32}$' "POSTGRES_PASSWORD should be 32 hex chars"
        Assert-Match $amqpPass '^[0-9a-f]{32}$' "RABBITMQ_DEFAULT_PASS should be 32 hex chars"
        Assert-True ($dbUrl.Contains($dbPass)) "DATABASE_URL should contain generated POSTGRES_PASSWORD"
        Assert-True ($amqpUrl.Contains($amqpPass)) "AMQP_URL should contain generated RABBITMQ_DEFAULT_PASS"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Run-Test "generate-plane-secrets.ps1 supports force flags" {
    $tmp = New-TempDir
    try {
        $envFile = Join-Path $tmp "plane.env"
        Invoke-NativeCommand -Description "generate-plane-secrets (initial)" -Command {
            & pwsh -NoLogo -NoProfile -File $GeneratePlaneScript -EnvFile $envFile -NoInfraSync
        }
        $firstSecret = Strip-Quotes (Env-Value -File $envFile -Key "SECRET_KEY")
        $firstDbPass = Strip-Quotes (Env-Value -File $envFile -Key "POSTGRES_PASSWORD")

        Invoke-NativeCommand -Description "generate-plane-secrets (without force)" -Command {
            & pwsh -NoLogo -NoProfile -File $GeneratePlaneScript -EnvFile $envFile -NoInfraSync
        }
        $secondSecret = Strip-Quotes (Env-Value -File $envFile -Key "SECRET_KEY")
        $secondDbPass = Strip-Quotes (Env-Value -File $envFile -Key "POSTGRES_PASSWORD")
        Assert-True ($firstSecret -eq $secondSecret) "SECRET_KEY should stay unchanged without force"
        Assert-True ($firstDbPass -eq $secondDbPass) "POSTGRES_PASSWORD should stay unchanged without force"

        Invoke-NativeCommand -Description "generate-plane-secrets (force passwords)" -Command {
            & pwsh -NoLogo -NoProfile -File $GeneratePlaneScript -EnvFile $envFile -NoInfraSync -ForcePasswords
        }
        $thirdDbPass = Strip-Quotes (Env-Value -File $envFile -Key "POSTGRES_PASSWORD")
        Assert-True ($thirdDbPass -ne $secondDbPass) "POSTGRES_PASSWORD should rotate with -ForcePasswords"

        Invoke-NativeCommand -Description "generate-plane-secrets (force secrets)" -Command {
            & pwsh -NoLogo -NoProfile -File $GeneratePlaneScript -EnvFile $envFile -NoInfraSync -ForceSecrets
        }
        $thirdSecret = Strip-Quotes (Env-Value -File $envFile -Key "SECRET_KEY")
        Assert-True ($thirdSecret -ne $secondSecret) "SECRET_KEY should rotate with -ForceSecrets"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Run-Test "generate-plane-secrets.ps1 syncs values from infra env file" {
    $tmp = New-TempDir
    try {
        $envFile = Join-Path $tmp "plane.env"
        $infraFile = Join-Path $tmp "production-infra.env"
        @"
POSTGRES_APPS_USER=apps_admin_custom
POSTGRES_APPS_PASSWORD=InfraPgPass-42
POSTGRES_PLANE_DB=plane_main
POSTGRES_APPS_CONTAINER_NAME=postgres-infra
APPS_VALKEY_PASSWORD=InfraRedisPass-42
VALKEY_APPS_CONTAINER_NAME=valkey-infra
PLANE_RABBITMQ_USER=plane_custom
PLANE_RABBITMQ_PASSWORD=InfraRabbitPass-42
PLANE_RABBITMQ_VHOST=plane_vhost
RABBITMQ_PLANE_CONTAINER_NAME=rabbit-infra
PLANE_S3_ACCESS_KEY=PLNINFRAKEY123456789
PLANE_S3_SECRET_KEY=InfraS3SecretValue42
PLANE_S3_BUCKET=plane-artifacts
"@ | Set-Content -Path $infraFile -NoNewline

        Invoke-NativeCommand -Description "generate-plane-secrets (infra sync)" -Command {
            & pwsh -NoLogo -NoProfile -File $GeneratePlaneScript -EnvFile $envFile -InfraEnvFile $infraFile
        }

        Assert-True ((Strip-Quotes (Env-Value -File $envFile -Key "POSTGRES_USER")) -eq "apps_admin_custom") "POSTGRES_USER should sync from infra"
        Assert-True ((Strip-Quotes (Env-Value -File $envFile -Key "POSTGRES_HOST")) -eq "postgres-infra") "POSTGRES_HOST should sync from infra"
        Assert-True ((Strip-Quotes (Env-Value -File $envFile -Key "POSTGRES_DB")) -eq "plane_main") "POSTGRES_DB should sync from infra"
        Assert-True ((Strip-Quotes (Env-Value -File $envFile -Key "POSTGRES_PASSWORD")) -eq "InfraPgPass-42") "POSTGRES_PASSWORD should sync from infra"
        Assert-True ((Strip-Quotes (Env-Value -File $envFile -Key "REDIS_HOST")) -eq "valkey-infra") "REDIS_HOST should sync from infra"
        Assert-True ((Strip-Quotes (Env-Value -File $envFile -Key "REDIS_PASSWORD")) -eq "InfraRedisPass-42") "REDIS_PASSWORD should sync from infra"
        Assert-True ((Strip-Quotes (Env-Value -File $envFile -Key "RABBITMQ_HOST")) -eq "rabbit-infra") "RABBITMQ_HOST should sync from infra"
        Assert-True ((Strip-Quotes (Env-Value -File $envFile -Key "RABBITMQ_DEFAULT_USER")) -eq "plane_custom") "RABBITMQ_DEFAULT_USER should sync from infra"
        Assert-True ((Strip-Quotes (Env-Value -File $envFile -Key "RABBITMQ_VHOST")) -eq "plane_vhost") "RABBITMQ_VHOST should sync from infra"
        Assert-True ((Strip-Quotes (Env-Value -File $envFile -Key "RABBITMQ_DEFAULT_PASS")) -eq "InfraRabbitPass-42") "RABBITMQ_DEFAULT_PASS should sync from infra"
        Assert-True ((Strip-Quotes (Env-Value -File $envFile -Key "AWS_ACCESS_KEY_ID")) -eq "PLNINFRAKEY123456789") "AWS_ACCESS_KEY_ID should sync from infra"
        Assert-True ((Strip-Quotes (Env-Value -File $envFile -Key "AWS_SECRET_ACCESS_KEY")) -eq "InfraS3SecretValue42") "AWS_SECRET_ACCESS_KEY should sync from infra"
        Assert-True ((Strip-Quotes (Env-Value -File $envFile -Key "AWS_S3_BUCKET_NAME")) -eq "plane-artifacts") "AWS_S3_BUCKET_NAME should sync from infra"
        Assert-True ((Strip-Quotes (Env-Value -File $envFile -Key "BUCKET_NAME")) -eq "plane-artifacts") "BUCKET_NAME should sync from infra"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Run-Test "generate-infra-secrets.ps1 creates env + generated values" {
    $tmp = New-TempDir
    try {
        $envFile = Join-Path $tmp "infra/production-infra.env"
        Invoke-NativeCommand -Description "generate-infra-secrets (create env + generate values)" -Command {
            & pwsh -NoLogo -NoProfile -File $GenerateInfraScript -EnvFile $envFile
        }

        Assert-True (Test-Path -LiteralPath $envFile -PathType Leaf) "Infra env file should be created"
        $pg = Strip-Quotes (Env-Value -File $envFile -Key "POSTGRES_APPS_PASSWORD")
        $valkey = Strip-Quotes (Env-Value -File $envFile -Key "APPS_VALKEY_PASSWORD")
        $rabbit = Strip-Quotes (Env-Value -File $envFile -Key "PLANE_RABBITMQ_PASSWORD")
        $s3ak = Strip-Quotes (Env-Value -File $envFile -Key "PLANE_S3_ACCESS_KEY")
        $s3sk = Strip-Quotes (Env-Value -File $envFile -Key "PLANE_S3_SECRET_KEY")

        Assert-Match $pg '^[0-9a-f]{32}$' "POSTGRES_APPS_PASSWORD should be 32 hex chars"
        Assert-Match $valkey '^[0-9a-f]{32}$' "APPS_VALKEY_PASSWORD should be 32 hex chars"
        Assert-Match $rabbit '^[0-9a-f]{32}$' "PLANE_RABBITMQ_PASSWORD should be 32 hex chars"
        Assert-Match $s3ak '^PLN[0-9A-F]{18}$' "PLANE_S3_ACCESS_KEY should be PLN + 18 uppercase hex chars"
        Assert-Match $s3sk '^[0-9a-f]{64}$' "PLANE_S3_SECRET_KEY should be 64 hex chars"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Run-Test "generate-infra-secrets.ps1 supports force flags" {
    $tmp = New-TempDir
    try {
        $envFile = Join-Path $tmp "production-infra.env"
        Invoke-NativeCommand -Description "generate-infra-secrets (initial)" -Command {
            & pwsh -NoLogo -NoProfile -File $GenerateInfraScript -EnvFile $envFile
        }
        $firstPg = Strip-Quotes (Env-Value -File $envFile -Key "POSTGRES_APPS_PASSWORD")
        $firstS3 = Strip-Quotes (Env-Value -File $envFile -Key "PLANE_S3_SECRET_KEY")

        Invoke-NativeCommand -Description "generate-infra-secrets (without force)" -Command {
            & pwsh -NoLogo -NoProfile -File $GenerateInfraScript -EnvFile $envFile
        }
        $secondPg = Strip-Quotes (Env-Value -File $envFile -Key "POSTGRES_APPS_PASSWORD")
        $secondS3 = Strip-Quotes (Env-Value -File $envFile -Key "PLANE_S3_SECRET_KEY")
        Assert-True ($firstPg -eq $secondPg) "POSTGRES_APPS_PASSWORD should stay unchanged without force"
        Assert-True ($firstS3 -eq $secondS3) "PLANE_S3_SECRET_KEY should stay unchanged without force"

        Invoke-NativeCommand -Description "generate-infra-secrets (force passwords)" -Command {
            & pwsh -NoLogo -NoProfile -File $GenerateInfraScript -EnvFile $envFile -ForcePasswords
        }
        $thirdPg = Strip-Quotes (Env-Value -File $envFile -Key "POSTGRES_APPS_PASSWORD")
        Assert-True ($thirdPg -ne $secondPg) "POSTGRES_APPS_PASSWORD should rotate with -ForcePasswords"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Run-Test "prepare-infra-compose.ps1 generates infra runtime files" {
    $tmp = New-TempDir
    try {
        $envFile = Join-Path $tmp "production-infra.env"
        $outDir = Join-Path $tmp "out"
        Invoke-NativeCommand -Description "generate-infra-secrets (for prepare input)" -Command {
            & pwsh -NoLogo -NoProfile -File $GenerateInfraScript -EnvFile $envFile
        }
        Invoke-NativeCommand -Description "prepare-infra-compose (render outputs)" -Command {
            & pwsh -NoLogo -NoProfile -File $PrepareInfraScript -EnvFile $envFile -OutputDir $outDir
        }

        Assert-True (Test-Path -LiteralPath (Join-Path $outDir "docker-compose.yml") -PathType Leaf) "docker-compose.yml should be generated"
        Assert-True (Test-Path -LiteralPath (Join-Path $outDir "valkey.conf") -PathType Leaf) "valkey.conf should be generated"
        Assert-True (Test-Path -LiteralPath (Join-Path $outDir "seaweedfs-s3-config.json") -PathType Leaf) "seaweedfs-s3-config.json should be generated"
        Assert-True (Test-Path -LiteralPath (Join-Path $outDir "postgres-apps-init.sh") -PathType Leaf) "postgres-apps-init.sh should be generated"
        Assert-True (Test-Path -LiteralPath (Join-Path $outDir "production-infra.env") -PathType Leaf) "production-infra.env should be copied"

        $compose = Get-Content -LiteralPath (Join-Path $outDir "docker-compose.yml") -Raw
        Assert-True (-not $compose.Contains("_HERE")) "Rendered compose should not contain unresolved placeholders"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Run-Test "prepare-infra-compose.ps1 fails on unresolved placeholders" {
    $tmp = New-TempDir
    try {
        $envFile = Join-Path $tmp "production-infra.env"
        Copy-Item -LiteralPath (Join-Path $RepoRoot "env/infra.env.example") -Destination $envFile

        Invoke-NativeCommand -Description "prepare-infra-compose (placeholder env should fail)" -ExpectFailure -Command {
            & pwsh -NoLogo -NoProfile -File $PrepareInfraScript -EnvFile $envFile -OutputDir (Join-Path $tmp "out")
        }
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
COOLIFY_ROOT_USER_PASSWORD=Str0ng!Passw0rdAbC1
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
        Assert-Match $content 'DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX=true' "Output should default ParseAddr workaround toggle to true"

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
COOLIFY_ROOT_USER_PASSWORD=Str0ng!Passw0rdAbC1
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
COOLIFY_ROOT_USER_PASSWORD=Str0ng!Passw0rdAbC1
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
COOLIFY_ROOT_USER_PASSWORD=Str0ng!Passw0rdAbC1
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

Run-Test "prepare-vps-coolify-init.ps1 supports external env path with default template/output fallback" {
    $tmp = New-TempDir
    try {
        $envFile = Join-Path $tmp "bootstrap.env"
        $keyFile = Join-Path $tmp "id_ed25519.pub"
        Set-Content -Path $keyFile -Value "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPsPrepareKey test@ps" -NoNewline

        Copy-Item -LiteralPath (Join-Path $RepoRoot "env/bootstrap.env.example") -Destination $envFile
        (Get-Content -LiteralPath $envFile -Raw).
            Replace("SSH_PUBLIC_KEY_PATH=CHANGE_ME_or_leave_empty", "SSH_PUBLIC_KEY_PATH=$keyFile").
            Replace("SSH_PUBLIC_KEY=CHANGE_ME_ssh_public_key", "SSH_PUBLIC_KEY=CHANGE_ME_ssh_public_key").
            Replace("TIMEZONE=UTC", "TIMEZONE=UTC").
            Replace("SSH_PORT=2222", "SSH_PORT=2278").
            Replace("DEVOPS_USER=devops", "DEVOPS_USER=devops").
            Replace("COOLIFY_SUDO_NOPASSWD_USER=coolify", "COOLIFY_SUDO_NOPASSWD_USER=coolify").
            Replace("ADDITIONAL_SUDO_USERS=", "ADDITIONAL_SUDO_USERS=ops").
            Replace("CLOSE_COOLIFY_REALTIME_PORTS=false", "CLOSE_COOLIFY_REALTIME_PORTS=false").
            Replace("DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX=true", "DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX=true").
            Replace("COOLIFY_REALTIME_DOMAIN=", "COOLIFY_REALTIME_DOMAIN=").
            Replace("COOLIFY_PUBLIC_DOMAIN=CHANGE_ME_coolify_public_domain", "COOLIFY_PUBLIC_DOMAIN=hub.example.com").
            Replace("COOLIFY_ROOT_USERNAME=CHANGE_ME_coolify_admin_username", "COOLIFY_ROOT_USERNAME=admin_main").
            Replace("COOLIFY_ROOT_USER_EMAIL=CHANGE_ME_admin_email@example.com", "COOLIFY_ROOT_USER_EMAIL=admin@example.com").
            Replace("COOLIFY_ROOT_USER_PASSWORD=CHANGE_ME_min_16_with_upper_lower_digit_symbol", "COOLIFY_ROOT_USER_PASSWORD=Str0ng!Passw0rdAbC1").
            Replace("USER_PASSWORDS_ENCRYPTION_PASSWORD=CHANGE_ME_min_16_chars", "USER_PASSWORDS_ENCRYPTION_PASSWORD=0123456789abcdef0123456789abcdef").
            Replace("BOOTSTRAP_REPO_REF=main", "BOOTSTRAP_REPO_REF=main") |
            Set-Content -LiteralPath $envFile -NoNewline

        Invoke-NativeCommand -Description "prepare-vps-coolify-init (external env path with defaults)" -Command {
            & pwsh -NoLogo -NoProfile -File $PrepareScript -EnvFile $envFile -Overwrite
        }

        $expectedOut = Join-Path $RepoRoot "bootstrap-artifacts/vps-coolify-init.generated.yml"
        Assert-True (Test-Path -LiteralPath $expectedOut -PathType Leaf) "Fallback output should be generated in repo bootstrap-artifacts"
        $content = Get-Content -LiteralPath $expectedOut -Raw
        Assert-True (-not $content.Contains("_HERE")) "Fallback output should not contain unresolved placeholders"
        Remove-Item -LiteralPath $expectedOut -Force -ErrorAction SilentlyContinue
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
COOLIFY_ROOT_USER_PASSWORD=Str0ng!Passw0rdAbC1
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
COOLIFY_ROOT_USER_PASSWORD=Str0ng!Passw0rdAbC1
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
COOLIFY_ROOT_USER_PASSWORD=Str0ng!Passw0rdAbC1
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

Run-Test "prepare-vps-coolify-init.ps1 fails on invalid ParseAddr workaround toggle value" {
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
DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX=yes
COOLIFY_REALTIME_DOMAIN=
COOLIFY_PUBLIC_DOMAIN=hub.example.com
COOLIFY_ROOT_USERNAME=admin_main
COOLIFY_ROOT_USER_EMAIL=admin@example.com
COOLIFY_ROOT_USER_PASSWORD=Str0ng!Passw0rdAbC1
USER_PASSWORDS_ENCRYPTION_PASSWORD=0123456789abcdef0123456789abcdef
BOOTSTRAP_REPO_URL=https://github.com/rigu/vps-coolify-bootstrap.git
BOOTSTRAP_REPO_REF=main
TEMPLATE_FILE=$TemplatePath
OUTPUT_FILE=$outFile
"@ | Set-Content -Path $envFile -NoNewline

        Invoke-NativeCommand -Description "prepare-vps-coolify-init (invalid DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX)" -ExpectFailure -Command {
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
