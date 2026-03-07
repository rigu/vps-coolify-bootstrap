---
layout: page
title: Getting Started
description: End-to-end setup steps for preparing env values, rendering VPS-Coolify init, and provisioning the VPS.
---

# Getting Started

## 1) Prepare env values

Linux/macOS:

```bash
mkdir -p bootstrap-artifacts
cp env/bootstrap.env.example bootstrap-artifacts/bootstrap.env
bash scripts/generate-secrets.sh --env-file bootstrap-artifacts/bootstrap.env
```

Windows PowerShell (`pwsh` preferred, `powershell` fallback):

```powershell
New-Item -ItemType Directory -Path bootstrap-artifacts -Force | Out-Null
Copy-Item env/bootstrap.env.example bootstrap-artifacts/bootstrap.env
pwsh -File scripts/generate-secrets.ps1 -EnvFile bootstrap-artifacts/bootstrap.env
```

PowerShell compatibility note:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\generate-secrets.ps1 -EnvFile bootstrap-artifacts/bootstrap.env
```

Use the same `pwsh` -> `powershell -ExecutionPolicy Bypass -File` replacement
for PowerShell commands shown later in this document.

Install PowerShell 7 (`pwsh`) on Windows (optional but recommended):

```powershell
winget install --id Microsoft.PowerShell --source winget
```

If `winget` is unavailable, install from:
<https://github.com/PowerShell/PowerShell/releases/latest>

On shared Windows systems, verify ACLs for generated secret files
(`bootstrap-artifacts/bootstrap.env`, `bootstrap-artifacts/vps-coolify-init.generated.yml`)
after running PowerShell scripts.

`generate-secrets.*` attempts **AUTO-DETECTED** SSH key discovery on your local machine.
It checks common public key files in `~/.ssh` (for example `id_ed25519.pub`,
`id_ecdsa.pub`, `id_rsa.pub`, then other `*.pub`) and fills `SSH_PUBLIC_KEY`
when the current value is empty or still `CHANGE_ME`.
If no valid key is found, set `SSH_PUBLIC_KEY` or `SSH_PUBLIC_KEY_PATH` manually.

## Bootstrap env quick reference

For full behavior details and replay implications, see:
[Operations and Security](operations-security.md#bootstrap-env-reference).

### A) Auto-resolved on host

| Variable | Runtime behavior | Must change |
|---|---|---|
| `PRIMARY_SUDO_USER` | If empty, resolved from first `SUDO_USERS` value, fallback `deploy` | NO |
| `SSH_KEY_ROTATE` | Default `0` append SSH key, `1` replace `authorized_keys` | NO |
| `ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS` | Default `0` blocks public `6001/6002`, `1` skips guards | NO |

### B) Coolify admin variables

| Variable | Runtime behavior | Must change |
|---|---|---|
| `COOLIFY_PUBLIC_DOMAIN` | Public URL/domain used for onboarding and output | YES |
| `COOLIFY_ROOT_USERNAME` | Passed to Coolify installer | YES |
| `COOLIFY_ROOT_USER_EMAIL` | Passed to Coolify installer; login identifier is email | YES |
| `COOLIFY_ROOT_USER_PASSWORD` | **AUTO-GENERATED** locally only when value is empty/`CHANGE_ME` (`openssl rand -hex 12`) | NO |

### C) Server user variables

| Variable | Runtime behavior | Must change |
|---|---|---|
| `SSH_PUBLIC_KEY` or `SSH_PUBLIC_KEY_PATH` | Required for SSH access; **AUTO-DETECTED** if a valid key exists on your machine, otherwise set manually | YES |
| `SSH_PORT` | Applied in SSH config and service restart flow | NO |
| `SECONDARY_SUDO_USER` | Validated against `CREATE_USERS` | NO |
| `CREATE_USERS` / `SUDO_USERS` / `DOCKER_USERS` / `COOLIFY_GROUP_USERS` | Users/groups and policy reconciliation at bootstrap/replay | NO |
| `TIMEZONE` | Applied by cloud-init during first boot | NO |

### D) Generated passwords and secrets

| Variable | Runtime behavior | Must change |
|---|---|---|
| `USER_PASSWORDS_ENCRYPTION_PASSWORD` | **AUTO-GENERATED** locally only when value is empty/`CHANGE_ME` (`openssl rand -hex 16`); used to encrypt user vault | NO |
| account passwords for `CREATE_USERS` | `ensure-user-passwords.sh` runs on the VPS host during bootstrap/replay (not as a local pre-generation step), sets passwords only for locked/unset users, then stores them encrypted in `/etc/vps-coolify-bootstrap/user-passwords.enc` | YES (set local password for `PRIMARY_SUDO_USER` on first login) |

Other bootstrap source variables (usually unchanged):
- `BOOTSTRAP_REPO_URL=https://github.com/rigu/vps-coolify-bootstrap.git`
- `BOOTSTRAP_REPO_REF=main`

Change `BOOTSTRAP_REPO_URL` only if you use a fork/mirror, and
`BOOTSTRAP_REPO_REF` only if you intentionally target a different branch/tag.

See `env/bootstrap.env.example` for all options.

Input validation enforced by scripts:

- `COOLIFY_ROOT_USERNAME` must match `^[A-Za-z0-9._-]+$`
- `COOLIFY_ROOT_USER_EMAIL` must be valid email format
- `COOLIFY_ROOT_USER_PASSWORD` and `USER_PASSWORDS_ENCRYPTION_PASSWORD` must be at least 16 characters
- `SSH_PORT` must be numeric in range `1-65535`
- usernames in user lists must match `^[a-z_][a-z0-9_-]*[$]?$` and must not contain `:`

Bootstrap runtime also terminates stale `sshd` listeners on port `22` when
`SSH_PORT` is configured to a different value, to avoid parallel legacy
listeners outside `ssh.service`.

## 2) Generate VPS-Coolify init file

Linux/macOS:

```bash
bash scripts/prepare-vps-coolify-init.sh --env-file bootstrap-artifacts/bootstrap.env --overwrite
```

PowerShell:

```powershell
pwsh -File scripts/prepare-vps-coolify-init.ps1 -EnvFile bootstrap-artifacts/bootstrap.env -Overwrite
```

Generated output defaults to `bootstrap-artifacts/vps-coolify-init.generated.yml`.

## 3) Provision VPS

Use `bootstrap-artifacts/vps-coolify-init.generated.yml` as cloud-init user-data in your VPS provider.

How to apply it at VPS creation time (example: Hetzner Cloud):

1. Start a new server creation flow and select Ubuntu 24.04.
2. In the create-server form, open the `Cloud config` / `User data` section.
3. Open `bootstrap-artifacts/vps-coolify-init.generated.yml` locally and copy the full file content (including the first line `#cloud-config`).
4. Paste that content into the provider `User data` field before clicking create.
5. Create the server. This init file is executed on first boot.
6. Important: adding/changing user-data after the VPS was already created does not apply retroactively to that existing server.

If your provider has no user-data/cloud-init field:

1. Check provider API/CLI first; many providers support user-data there even if the UI does not.
2. If user-data is not available at all, use provider console access and run bootstrap manually on the host.
3. Create `/etc/vps-coolify-bootstrap/bootstrap.env` from your local `bootstrap-artifacts/bootstrap.env`.
4. Clone this repo to `/opt/vps-coolify-bootstrap`.
5. Run `sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env`.
6. For this manual path, follow the full validation checklist below and the recovery runbook.

At first boot, cloud-init clones `BOOTSTRAP_REPO_URL` at `BOOTSTRAP_REPO_REF` and runs `scripts/bootstrap-host.sh`.

After first boot, use this checklist:

1. Wait for cloud-init/bootstrap to finish on the server (provider console):

   ```bash
   sudo cloud-init status --wait
   sudo tail -n 200 /var/log/cloud-init-output.log
   ```

2. Connect by SSH from your machine using configured values from `bootstrap-artifacts/bootstrap.env`:

   ```bash
   ssh -p <SSH_PORT> <PRIMARY_SUDO_USER>@<SERVER_IP>
   ```

   Default port is `2222` unless you changed `SSH_PORT`.
   Use `PRIMARY_SUDO_USER` for operational work that needs `sudo`.

3. IMPORTANT: On first login, set a local password for `PRIMARY_SUDO_USER`:

   ```bash
   sudo passwd "$(whoami)"
   ```

   Do this before handing operational access to other admins.
   `PRIMARY_SUDO_USER` has passwordless sudo by policy, but a local password is
   still required for emergency recovery paths (for example console login).

4. Validate host baseline after login:

   ```bash
   whoami
   id
   sudo ufw status verbose
   sudo systemctl status ssh --no-pager
   sudo docker ps
   ```

5. Open Coolify and complete onboarding:

   Use `https://<COOLIFY_PUBLIC_DOMAIN>`.
   Log in with `COOLIFY_ROOT_USER_EMAIL` and `COOLIFY_ROOT_USER_PASSWORD` from your env file.
   `COOLIFY_ROOT_USERNAME` is still required during bootstrap, but the normal login identifier is email.

6. Deploy workloads from private/project repositories:

   In Coolify, create/select a Project, connect your Git provider, pick repository + branch, configure runtime env vars, then deploy.
   Verify deployment health, logs, and exposed domains before sending production traffic.

## 4) Advanced operations

- Replay bootstrap policy: [Operations and Security](operations-security.md#replay-bootstrap-policy-idempotent)
- Failed first boot recovery: [Bootstrap Failure Recovery](bootstrap-failure-recovery.md)

Back to [Docs Home](index.md)
