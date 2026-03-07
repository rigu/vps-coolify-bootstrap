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

Windows PowerShell:

```powershell
Copy-Item env/bootstrap.env.example env/bootstrap.env
pwsh -File scripts/generate-secrets.ps1 -EnvFile env/bootstrap.env
```

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

## 2) Generate cloud-init

Linux/macOS:

```bash
bash scripts/prepare-cloud-init.sh --env-file env/bootstrap.env --overwrite
```

PowerShell:

```powershell
pwsh -File scripts/prepare-cloud-init.ps1 -EnvFile env/bootstrap.env -Overwrite
```

Generated output defaults to `cloud-init.generated.yml`.

## 3) Provision VPS

Use `cloud-init.generated.yml` as user-data in your VPS provider.

At first boot, cloud-init clones `BOOTSTRAP_REPO_URL` at `BOOTSTRAP_REPO_REF` and runs `scripts/bootstrap-host.sh`.

After first boot:

- connect using the configured SSH port (default `2278`)
- open `https://<COOLIFY_PUBLIC_DOMAIN>` and finish Coolify onboarding
- deploy app stacks from private/project repositories

## 4) Replay bootstrap policy (idempotent)

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

Notes:

- replay resets UFW to baseline each time
- replay re-syncs SSH `AllowUsers` from `CREATE_USERS`
- replay enforces sudo policy and group memberships

Back to [Docs Home](index.md)
