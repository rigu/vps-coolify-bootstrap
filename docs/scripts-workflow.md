---
---

# Script Workflow

This page documents the detailed local workflow for:
- `scripts/generate-secrets.sh` / `scripts/generate-secrets.ps1`
- `scripts/prepare-vps-coolify-init.sh` / `scripts/prepare-vps-coolify-init.ps1`
- `scripts/generate-infra-secrets.sh` / `scripts/generate-infra-secrets.ps1`
- `scripts/prepare-infra-compose.sh` / `scripts/prepare-infra-compose.ps1`
- `scripts/setup-infra.sh`
- `scripts/generate-plane-secrets.sh` / `scripts/generate-plane-secrets.ps1`

## PowerShell note (Windows)

Recommended:

```powershell
winget install --id Microsoft.PowerShell --source winget
```

Fallback if `pwsh` is not available:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\generate-secrets.ps1
```

Use the same `pwsh` -> `powershell -ExecutionPolicy Bypass -File` replacement for
other PowerShell examples.

## What `generate-secrets.*` does

- creates `bootstrap-artifacts/bootstrap.env` from `env/bootstrap.env.example` when missing
- fills placeholder/empty secrets (non-destructive by default)
- auto-detects local SSH public key and fills both:
  - `SSH_PUBLIC_KEY`
  - `SSH_PUBLIC_KEY_PATH`
- Bash version sets strict file mode (`chmod 600`)

What it does not do:
- does not provision VPS
- does not render VPS init YAML
- does not rotate already valid values unless force flags are used

## Detailed local workflow

1. Initialize env for fresh clone:

```bash
bash scripts/generate-secrets.sh
```

2. Edit required business values in `bootstrap-artifacts/bootstrap.env`:
- `COOLIFY_PUBLIC_DOMAIN`
- `COOLIFY_ROOT_USERNAME`
- `COOLIFY_ROOT_USER_EMAIL`
- all remaining `CHANGE_ME` placeholders

3. Optional: rotate only Coolify root password:

```bash
bash scripts/generate-secrets.sh --force-password
```

PowerShell:

```powershell
pwsh -File scripts/generate-secrets.ps1 -ForcePassword
```

4. Optional: rotate only encryption password:

```bash
bash scripts/generate-secrets.sh --force-encryption-password
```

PowerShell:

```powershell
pwsh -File scripts/generate-secrets.ps1 -ForceEncryptionPassword
```

5. Optional: force SSH key re-detection:

```bash
bash scripts/generate-secrets.sh --force-ssh-key
```

PowerShell:

```powershell
pwsh -File scripts/generate-secrets.ps1 -ForceSshKey
```

6. Optional: custom env path (parent folders auto-created, env example copied if missing):

```bash
bash scripts/generate-secrets.sh --env-file envs/prod/bootstrap.env
```

PowerShell:

```powershell
pwsh -File scripts/generate-secrets.ps1 -EnvFile envs/prod/bootstrap.env
```

7. Render VPS init YAML:

```bash
bash scripts/prepare-vps-coolify-init.sh --overwrite
```

PowerShell:

```powershell
pwsh -File scripts/prepare-vps-coolify-init.ps1 -Overwrite
```

8. Re-render after env changes:

```bash
bash scripts/prepare-vps-coolify-init.sh --env-file bootstrap-artifacts/bootstrap.env --overwrite
```

PowerShell:

```powershell
pwsh -File scripts/prepare-vps-coolify-init.ps1 -EnvFile bootstrap-artifacts/bootstrap.env -Overwrite
```

Path resolution note for external env files:
- when `--env-file` / `-EnvFile` points outside repo, default `TEMPLATE_FILE` and `OUTPUT_FILE` are resolved with repo fallback
- practical result: you can keep defaults from `env/bootstrap.env.example`; output still lands in repo `bootstrap-artifacts/` by default
- if you want custom output location, set absolute `OUTPUT_FILE`

## Validation behavior in `prepare-vps-coolify-init.*`

- rejects unresolved required placeholders (`CHANGE_ME`)
- validates formats (SSH port, usernames, email, domain, booleans)
- enforces realtime cross-field rule:
  - when `CLOSE_COOLIFY_REALTIME_PORTS=true`, effective realtime domain is
    `COOLIFY_REALTIME_DOMAIN` or fallback `COOLIFY_PUBLIC_DOMAIN`
- fails if output exists and overwrite is missing
- fails if generated file exceeds provider user-data size limits

## `SSH_KEY_ROTATE` practical behavior

Applies only to:
- `DEVOPS_USER`
- users from `ADDITIONAL_SUDO_USERS`

Does not apply to:
- `COOLIFY_SUDO_NOPASSWD_USER` (dedicated localhost key flow)
- `root`

Modes:
- `SSH_KEY_ROTATE=0` (default): keep existing keys, append current `SSH_PUBLIC_KEY` only if missing
- `SSH_KEY_ROTATE=1`: replace `authorized_keys` with current `SSH_PUBLIC_KEY`

Example controlled key replacement:

```env
SSH_PUBLIC_KEY='ssh-ed25519 AAAA...new_key'
SSH_KEY_ROTATE=1
```

Replay on host:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

Then return to default append mode:

```env
SSH_KEY_ROTATE=0
```

## Plane env secret workflow (for Plane deployment)

Use this only when deploying Plane on top of this bootstrap.

Local-first rule:
- generate infra env locally first (`bootstrap-artifacts/production-infra.env`)
- copy infra env to VPS and run infra setup there (server-side render/deploy)
- generate Plane env locally second (`bootstrap-artifacts/plane.env`)
- Plane generator syncs infra-dependent values automatically

Default generation:

```bash
bash scripts/generate-plane-secrets.sh
```

PowerShell:

```powershell
pwsh -File scripts/generate-plane-secrets.ps1
```

Default output:
- `bootstrap-artifacts/plane.env`

Default infra source:
- `bootstrap-artifacts/production-infra.env`

If `production-infra.env` is missing:
- Plane generator does not fail; it prints a warning and skips infra sync
- script still generates local Plane secrets/passwords in `bootstrap-artifacts/plane.env`
- `DATABASE_URL`, `REDIS_URL`, and `AMQP_URL` are generated from current Plane env values
- after generating infra env, rerun Plane generator to sync infra-derived values

Rerun after infra env creation:

```bash
bash scripts/generate-plane-secrets.sh
```

```powershell
pwsh -File scripts/generate-plane-secrets.ps1
```

Override infra source:
- Bash: `--infra-env-file <path>`
- PowerShell: `-InfraEnvFile <path>`

Disable infra sync (advanced/testing only):
- Bash: `--no-infra-sync`
- PowerShell: `-NoInfraSync`

Force rotation:
- passwords only: `--force-passwords` / `-ForcePasswords`
- secrets only: `--force-secrets` / `-ForceSecrets`
- everything generated by script: `--force-all` / `-ForceAll`

Infra -> Plane sync mapping:
- `POSTGRES_APPS_USER` -> `POSTGRES_USER`
- `POSTGRES_APPS_PASSWORD` -> `POSTGRES_PASSWORD`
- `POSTGRES_PLANE_DB` -> `POSTGRES_DB`
- `POSTGRES_APPS_CONTAINER_NAME` -> `POSTGRES_HOST`
- `APPS_VALKEY_PASSWORD` -> `REDIS_PASSWORD`
- `VALKEY_APPS_CONTAINER_NAME` -> `REDIS_HOST`
- `PLANE_RABBITMQ_USER` -> `RABBITMQ_DEFAULT_USER`
- `PLANE_RABBITMQ_PASSWORD` -> `RABBITMQ_DEFAULT_PASS`
- `PLANE_RABBITMQ_VHOST` -> `RABBITMQ_VHOST` + `RABBITMQ_DEFAULT_VHOST`
- `RABBITMQ_PLANE_CONTAINER_NAME` -> `RABBITMQ_HOST`
- `PLANE_S3_ACCESS_KEY` -> `AWS_ACCESS_KEY_ID`
- `PLANE_S3_SECRET_KEY` -> `AWS_SECRET_ACCESS_KEY`
- `PLANE_S3_BUCKET` -> `AWS_S3_BUCKET_NAME` + `BUCKET_NAME`

URLs regenerated when needed:
- `DATABASE_URL`
- `REDIS_URL`
- `AMQP_URL`

Details and deployment usage:
- [Install Plane on Coolify](install-plane-on-coolify.md)

## Infra env + compose workflow (internal service layer)

Generate infra env locally:

```bash
bash scripts/generate-infra-secrets.sh
```

PowerShell:

```powershell
pwsh -File scripts/generate-infra-secrets.ps1
```

Default local output:
- `bootstrap-artifacts/production-infra.env`

Deployment and network preparation:
- [Create Infra Network](create-infra-network.md)

Copy env to VPS, then run server-side setup:

Linux/macOS:

```bash
scp bootstrap-artifacts/production-infra.env devops@<server-ip>:/tmp/production-infra.env
ssh devops@<server-ip>
sudo bash /opt/vps-coolify-bootstrap/scripts/setup-infra.sh --env-file /tmp/production-infra.env
```

Windows (PowerShell):

```powershell
scp .\bootstrap-artifacts\production-infra.env devops@<server-ip>:/tmp/production-infra.env
ssh devops@<server-ip>
sudo bash /opt/vps-coolify-bootstrap/scripts/setup-infra.sh --env-file /tmp/production-infra.env
```

What happens server-side:
- optional fill of unresolved placeholders in copied env
- compose/config render on VPS
- network ensure + deploy + validation

All-in-one server run is also available:

```bash
sudo bash scripts/setup-infra.sh
```

Useful options:
- `--env-file <path>`: use a specific infra env file
- `--force-passwords` / `--force-secrets`: rotate generated values
- `--runtime-dir <path>`: change runtime directory (default `/srv/infra`)
- `--skip-deploy`: generate/sync only, without `docker compose up -d`
- `--skip-validate`: skip health/network/exposure validation

Port conflict check (before deploy/redeploy):

```bash
sudo ss -lntp | grep -E ':(5434|6379|5672|15672|8333)\b' || true
```

If a port is already occupied by another service, update the corresponding
`*_HOST_PORT` in `production-infra.env` and rerun `setup-infra.sh`.

Back to [Getting Started](getting-started.md)
