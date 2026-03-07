---
layout: page
title: Getting Started
description: End-to-end setup steps for preparing env values, rendering cloud-init, and provisioning the VPS.
---

# Getting Started

## 1) Prepare env values

Linux/macOS:

```bash
cp env/bootstrap.env.example env/bootstrap.env
bash scripts/generate-secrets.sh --env-file env/bootstrap.env
```

Windows PowerShell (`pwsh` preferred, `powershell` fallback):

```powershell
Copy-Item env/bootstrap.env.example env/bootstrap.env
pwsh -File scripts/generate-secrets.ps1 -EnvFile env/bootstrap.env
```

If `pwsh` is not installed:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\generate-secrets.ps1 -EnvFile env/bootstrap.env
```

Install PowerShell 7 (`pwsh`) on Windows (optional but recommended):

```powershell
winget install --id Microsoft.PowerShell --source winget
```

If `winget` is unavailable, install from:
<https://github.com/PowerShell/PowerShell/releases/latest>

On shared Windows systems, verify ACLs for generated secret files
(`env/bootstrap.env`, `cloud-init.generated.yml`) after running PowerShell scripts.

Generate-secrets scripts auto-detect the current user SSH public key and fill `SSH_PUBLIC_KEY` when it is empty or still `CHANGE_ME`.

Then edit `env/bootstrap.env` and set:

- `SSH_PUBLIC_KEY` or `SSH_PUBLIC_KEY_PATH`
- `SSH_KEY_ROTATE` (`0` append / `1` replace)
- `COOLIFY_PUBLIC_DOMAIN`
- `COOLIFY_ROOT_USERNAME`, `COOLIFY_ROOT_USER_EMAIL`, `COOLIFY_ROOT_USER_PASSWORD`
- `USER_PASSWORDS_ENCRYPTION_PASSWORD`
- `CREATE_USERS`, `SUDO_USERS`, `DOCKER_USERS`, `COOLIFY_GROUP_USERS`
- `BOOTSTRAP_REPO_URL` only if you use a fork/mirror
- `BOOTSTRAP_REPO_REF` if you need a different branch/tag

Default `BOOTSTRAP_REPO_URL`:
`https://github.com/rigu/vps-coolify-bootstrap.git`

Other configurable defaults:

- `TIMEZONE=UTC`
- `SSH_PORT=2222`
- `PRIMARY_SUDO_USER=deploy`
- `SECONDARY_SUDO_USER=coolify`

See `env/bootstrap.env.example` for all options.

Input validation enforced by scripts:

- `COOLIFY_ROOT_USERNAME` must match `^[A-Za-z0-9._-]+$`
- `COOLIFY_ROOT_USER_EMAIL` must be valid email format
- `COOLIFY_ROOT_USER_PASSWORD` and `USER_PASSWORDS_ENCRYPTION_PASSWORD` must be at least 16 characters
- `SSH_PORT` must be numeric in range `1-65535`
- usernames in user lists must match `^[a-z_][a-z0-9_-]*[$]?$` and must not contain `:`

## 2) Generate cloud-init

Linux/macOS:

```bash
bash scripts/prepare-cloud-init.sh --env-file env/bootstrap.env --overwrite
```

PowerShell (`pwsh` preferred, `powershell` fallback):

```powershell
pwsh -File scripts/prepare-cloud-init.ps1 -EnvFile env/bootstrap.env -Overwrite
```

If `pwsh` is not installed:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\prepare-cloud-init.ps1 -EnvFile env/bootstrap.env -Overwrite
```

Generated output defaults to `cloud-init.generated.yml`.

## 3) Provision VPS

Use `cloud-init.generated.yml` as user-data in your VPS provider.

At first boot, cloud-init clones `BOOTSTRAP_REPO_URL` at `BOOTSTRAP_REPO_REF` and runs `scripts/bootstrap-host.sh`.

After first boot, use this checklist:

1. Wait for cloud-init/bootstrap to finish on the server (provider console):

   ```bash
   sudo cloud-init status --wait
   sudo tail -n 200 /var/log/cloud-init-output.log
   ```

2. Connect by SSH from your machine using configured values from `env/bootstrap.env`:

   ```bash
   ssh -p <SSH_PORT> <PRIMARY_SUDO_USER>@<SERVER_IP>
   ```

   Default port is `2222` unless you changed `SSH_PORT`.
   Use `PRIMARY_SUDO_USER` for operational work that needs `sudo`.

3. Validate host baseline after login:

   ```bash
   whoami
   id
   sudo ufw status verbose
   sudo systemctl status ssh --no-pager
   sudo docker ps
   ```

4. Open Coolify and complete onboarding:

   Use `https://<COOLIFY_PUBLIC_DOMAIN>`.
   Log in with `COOLIFY_ROOT_USERNAME` / `COOLIFY_ROOT_USER_EMAIL` and `COOLIFY_ROOT_USER_PASSWORD` from your env file.

5. Deploy workloads from private/project repositories:

   In Coolify, create/select a Project, connect your Git provider, pick repository + branch, configure runtime env vars, then deploy.
   Verify deployment health, logs, and exposed domains before sending production traffic.

## 4) Replay bootstrap policy (idempotent)

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

Notes:

- run replay as `PRIMARY_SUDO_USER` (passwordless sudo) or as `root` via provider console
- replay resets UFW to baseline each time
- replay re-syncs SSH `AllowUsers` from `CREATE_USERS`
- replay enforces sudo policy and group memberships

Back to [Docs Home](index.md)
