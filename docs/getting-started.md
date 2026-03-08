---
layout: page
title: Getting Started
description: End-to-end setup steps for preparing env values, rendering VPS-Coolify init, and provisioning the VPS.
---

# Getting Started

## 1) Prepare env values

Run secret generation first. This is the local preparation step that creates or updates
`bootstrap-artifacts/bootstrap.env`.

Linux/macOS (default path):

```bash
bash scripts/generate-secrets.sh
```

Windows PowerShell (default path, `pwsh` preferred):

```powershell
pwsh -File scripts/generate-secrets.ps1
```

PowerShell compatibility note:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\generate-secrets.ps1
```

Use the same `pwsh` -> `powershell -ExecutionPolicy Bypass -File` replacement
for PowerShell commands shown later in this document.

Install PowerShell 7 (`pwsh`) on Windows (optional but recommended):

```powershell
winget install --id Microsoft.PowerShell --source winget
```

If `winget` is unavailable, install from:
<https://github.com/PowerShell/PowerShell/releases/latest>

What `generate-secrets.*` does:

- if `bootstrap-artifacts/bootstrap.env` does not exist, creates parent folder and copies `env/bootstrap.env.example`
- updates only placeholder/empty values by default (non-destructive for already-set values)
- auto-detects SSH public key from local machine and fills both `SSH_PUBLIC_KEY` and `SSH_PUBLIC_KEY_PATH` when needed
- sets secure file permissions for generated env file (`chmod 600` in Bash; file write in PowerShell)

What it does not do:

- does not provision the VPS
- does not render the VPS init YAML
- does not rotate already valid values unless force flags are provided

On shared Windows systems, verify ACLs for generated secret files
(`bootstrap-artifacts/bootstrap.env`, `bootstrap-artifacts/vps-coolify-init.generated.yml`)
after running PowerShell scripts.

`generate-secrets.*` performs **AUTO-DETECTED** SSH key lookup on your local machine.
It checks common public key files in `~/.ssh` (for example `id_ed25519.pub`,
`id_ecdsa.pub`, `id_rsa.pub`, then other `*.pub`) and fills both
`SSH_PUBLIC_KEY` and `SSH_PUBLIC_KEY_PATH` when current values are empty or still `CHANGE_ME`.
If no valid key is found, set `SSH_PUBLIC_KEY` or `SSH_PUBLIC_KEY_PATH` manually.

### Detailed script workflow (8 iterations)

Use this practical sequence when you want deterministic, repeatable local preparation.

1. Iteration 1: initialize local env from scratch

   Use this on a fresh clone:

   ```bash
   bash scripts/generate-secrets.sh
   ```

   Expected result:
   - `bootstrap-artifacts/bootstrap.env` is created automatically
   - placeholder secret values are replaced
   - SSH key is auto-filled if detected locally

2. Iteration 2: inspect and set required business values manually

   Edit `bootstrap-artifacts/bootstrap.env` and set at least:
   - `COOLIFY_PUBLIC_DOMAIN`
   - `COOLIFY_ROOT_USERNAME`
   - `COOLIFY_ROOT_USER_EMAIL`
   - any other values still containing `CHANGE_ME`

   Keep generated values unless you intentionally want new secrets.

3. Iteration 3: force only Coolify root password regeneration (optional)

   Bash:

   ```bash
   bash scripts/generate-secrets.sh --force-password
   ```

   PowerShell:

   ```powershell
   pwsh -File scripts/generate-secrets.ps1 -ForcePassword
   ```

4. Iteration 4: force only vault encryption password regeneration (optional)

   Bash:

   ```bash
   bash scripts/generate-secrets.sh --force-encryption-password
   ```

   PowerShell:

   ```powershell
   pwsh -File scripts/generate-secrets.ps1 -ForceEncryptionPassword
   ```

5. Iteration 5: force SSH key re-detection (optional)

   Use this after rotating local SSH keys:

   Bash:

   ```bash
   bash scripts/generate-secrets.sh --force-ssh-key
   ```

   PowerShell:

   ```powershell
   pwsh -File scripts/generate-secrets.ps1 -ForceSshKey
   ```

6. Iteration 6: run with a custom env file path (optional)

   Scripts create missing parent folders and copy `env/bootstrap.env.example` if the file is missing.

   Bash:

   ```bash
   bash scripts/generate-secrets.sh --env-file envs/prod/bootstrap.env
   ```

   PowerShell:

   ```powershell
   pwsh -File scripts/generate-secrets.ps1 -EnvFile envs/prod/bootstrap.env
   ```

7. Iteration 7: render VPS init YAML from prepared env

   Bash (default path):

   ```bash
   bash scripts/prepare-vps-coolify-init.sh --overwrite
   ```

   PowerShell (default path):

   ```powershell
   pwsh -File scripts/prepare-vps-coolify-init.ps1 -Overwrite
   ```

   Expected output: `bootstrap-artifacts/vps-coolify-init.generated.yml`

8. Iteration 8: rerender safely after env changes

   After any change in `bootstrap.env`, rerun prepare with overwrite.
   This updates only the generated YAML file; your `bootstrap.env` remains the source of truth.

   Bash:

   ```bash
   bash scripts/prepare-vps-coolify-init.sh --env-file bootstrap-artifacts/bootstrap.env --overwrite
   ```

   PowerShell:

   ```powershell
   pwsh -File scripts/prepare-vps-coolify-init.ps1 -EnvFile bootstrap-artifacts/bootstrap.env -Overwrite
   ```

Validation notes for `prepare-vps-coolify-init.*`:

- rejects unresolved required values (for example `CHANGE_ME`)
- validates input formats (`SSH_PORT`, usernames, email, hostname, booleans)
- enforces cross-field rule: `COOLIFY_REALTIME_DOMAIN` is required when `CLOSE_COOLIFY_REALTIME_PORTS=true`
- fails if output exists and overwrite is not enabled
- fails if generated file exceeds provider size limit (Hetzner VPS init: 32768 bytes)

## Bootstrap env quick reference

For full behavior details and replay implications, see:
[Operations and Security](operations-security.md#bootstrap-env-reference).

### A) Auto-resolved on host

| Variable | Runtime behavior | Required to set? |
|---|---|---|
| `DEVOPS_USER` | Primary operational account; defaults to `devops` if not set | NO |
| `SSH_KEY_ROTATE` | Default `0`: append SSH key; `1`: replace `authorized_keys` | NO |
| `CLOSE_COOLIFY_REALTIME_PORTS` | Default `false`: keep public `6001/6002`; set `true` to enforce `DOCKER-USER` guards and close public ingress | NO |

### B) Coolify admin variables

| Variable | Runtime behavior | Required to set? |
|---|---|---|
| `COOLIFY_PUBLIC_DOMAIN` | Public URL/domain used for onboarding and output | YES |
| `COOLIFY_ROOT_USERNAME` | Passed to Coolify installer | YES |
| `COOLIFY_ROOT_USER_EMAIL` | Passed to Coolify installer; login identifier is email | YES |
| `COOLIFY_ROOT_USER_PASSWORD` | **AUTO-GENERATED** locally only when value is empty/`CHANGE_ME` (`openssl rand -hex 12`) | NO |

### C) Server user variables

| Variable | Runtime behavior | Required to set? |
|---|---|---|
| `SSH_PUBLIC_KEY` or `SSH_PUBLIC_KEY_PATH` | Required for SSH access; **AUTO-DETECTED** if a valid key exists on your machine, otherwise set manually | YES |
| `COOLIFY_SUDO_NOPASSWD_USER` | Dedicated user for Coolify localhost SSH operations; auto-managed, forced into user/group lists, granted passwordless sudo, and configured with a dedicated localhost/private-only SSH key (not for direct public SSH access) | NO |
| `ADDITIONAL_SUDO_USERS` | Optional comma-separated additional admins; effective managed users are `DEVOPS_USER` + `COOLIFY_SUDO_NOPASSWD_USER` + `ADDITIONAL_SUDO_USERS` | NO |
| `COOLIFY_REALTIME_DOMAIN` | Dedicated realtime host. If set, bootstrap writes `PUSHER_HOST`, `PUSHER_PORT=443`, `PUSHER_SCHEME=https` in Coolify `.env`; if empty, bootstrap removes those keys. Required when `CLOSE_COOLIFY_REALTIME_PORTS=true` | NO (YES when closing `6001/6002`) |
| `SSH_PORT` | Applied in SSH config and service restart flow | NO |
| `TIMEZONE` | Applied during first-boot VPS init phase | NO |

### D) Generated passwords and secrets

| Variable | Runtime behavior | Required to set? |
|---|---|---|
| `USER_PASSWORDS_ENCRYPTION_PASSWORD` | **AUTO-GENERATED** locally only when value is empty/`CHANGE_ME` (`openssl rand -hex 16`); used to encrypt user vault | NO |
| account passwords for managed users | `ensure-user-passwords.sh` runs on the VPS host during bootstrap/replay (not as a local pre-generation step). It sets a new password only when needed: account is locked/unset in `/etc/shadow` (empty hash or starts with `!` / `*`) or account has no entry in the encrypted vault yet. Existing unlocked accounts with existing vault entries are not rotated. Managed users are `DEVOPS_USER` + `COOLIFY_SUDO_NOPASSWD_USER` + `ADDITIONAL_SUDO_USERS`. | YES (set local password for `DEVOPS_USER` on first login) |

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
- `CLOSE_COOLIFY_REALTIME_PORTS` must be `true/false` (or `1/0`)
- `COOLIFY_REALTIME_DOMAIN` is required when `CLOSE_COOLIFY_REALTIME_PORTS=true`
- usernames in user lists must match `^[a-z_][a-z0-9_-]*[$]?$` and must not contain `:`

Bootstrap runtime also terminates stale `sshd` listeners on port `22` when
`SSH_PORT` is configured to a different value, to avoid parallel legacy
listeners outside `ssh.service`.

## 2) Generate VPS-Coolify init file

Linux/macOS:

```bash
bash scripts/prepare-vps-coolify-init.sh --overwrite
```

PowerShell:

```powershell
pwsh -File scripts/prepare-vps-coolify-init.ps1 -Overwrite
```

Generated output defaults to `bootstrap-artifacts/vps-coolify-init.generated.yml`.
Use `--env-file <path>` / `-EnvFile <path>` when you work with multiple environments.

## 3) Provision VPS

Use `bootstrap-artifacts/vps-coolify-init.generated.yml` as user-data (VPS init format) in your VPS provider.

How to apply it at VPS creation time (example: Hetzner):

1. Start a new server creation flow and select Ubuntu 24.04.
2. In the create-server form, open the `VPS init` / `User data` section.
3. Open `bootstrap-artifacts/vps-coolify-init.generated.yml` locally and copy the full file content (including the first line `#cloud-config`).
4. Paste that content into the provider `User data` field before clicking create.
5. Create the server. This init file is executed on first boot.
6. Important: adding/changing user-data after the VPS was already created does not apply retroactively to that existing server.

If your provider has no user-data field:

1. Check provider API/CLI first; many providers support user-data there even if the UI does not.
2. If user-data is not available at all, use provider console access and run the bootstrap manually on the host.
3. Create `/etc/vps-coolify-bootstrap/bootstrap.env` from your local `bootstrap-artifacts/bootstrap.env`.
4. Clone this repo to `/opt/vps-coolify-bootstrap`.
5. Run `sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env`.
6. For this manual path, follow the full validation checklist below and the recovery runbook.

At first boot, the VPS init service clones `BOOTSTRAP_REPO_URL` at `BOOTSTRAP_REPO_REF` and runs `scripts/bootstrap-host.sh`.

After first boot, use this checklist:

1. Wait for first-boot VPS init/bootstrap to finish on the server (provider console):

   ```bash
   sudo cloud-init status --wait
   sudo tail -n 200 /var/log/cloud-init-output.log
   ```

2. Connect by SSH from your machine using configured values from `bootstrap-artifacts/bootstrap.env`:

   ```bash
   ssh -p <SSH_PORT> <DEVOPS_USER>@<SERVER_IP>
   ```

   Default port is `2222` unless you changed `SSH_PORT`.
   Use `DEVOPS_USER` for operational work that needs `sudo`.

   Host key change note (`REMOTE HOST IDENTIFICATION HAS CHANGED`):
   this usually happens after VPS reprovision/reinstall (new SSH host keys).
   Verify the new server fingerprint in provider console first:

   ```bash
   sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```

   If the fingerprint matches what SSH shows, remove the old local key entry and reconnect.

   Windows PowerShell:

   ```powershell
   ssh-keygen -R "[<SERVER_IP>]:<SSH_PORT>"
   ssh -p <SSH_PORT> <DEVOPS_USER>@<SERVER_IP>
   ```

   Linux/macOS:

   ```bash
   ssh-keygen -R "[<SERVER_IP>]:<SSH_PORT>"
   ssh -p <SSH_PORT> <DEVOPS_USER>@<SERVER_IP>
   ```

3. IMPORTANT: On first login, set a local password for `DEVOPS_USER`:

   ```bash
   sudo passwd "$(whoami)"
   ```

   Do this before handing operational access to other admins.
   `DEVOPS_USER` has passwordless sudo by policy, but a local password is
   still required for emergency recovery paths (for example console login).

4. Validate host baseline after login:

   ```bash
   whoami
   id
   sudo ufw status verbose
   sudo systemctl status ssh --no-pager
   sudo docker ps
   ```

   Full post-bootstrap verification script:

   ```bash
   sudo bash /opt/vps-coolify-bootstrap/scripts/verify-bootstrap-state.sh /etc/vps-coolify-bootstrap/bootstrap.env
   ```

5. Open Coolify and complete onboarding:

   Use `https://<COOLIFY_PUBLIC_DOMAIN>`.
   Log in with `COOLIFY_ROOT_USER_EMAIL` and `COOLIFY_ROOT_USER_PASSWORD` from your env file.
   `COOLIFY_ROOT_USERNAME` is still required during bootstrap, but the normal login identifier is email.
   Bootstrap automatically syncs the local Coolify server connection (`server id 0`) to use
   `COOLIFY_SUDO_NOPASSWD_USER` and `SSH_PORT`; if onboarding shows a different user/port, run a bootstrap replay.
   If `80/443` is not available yet, use temporary bootstrap URL `http://<SERVER_IP>:8000`.

### Onboarding troubleshooting (common)

- `403 Forbidden` on `<COOLIFY_PUBLIC_DOMAIN>`:
  usually DNS points to a different host. Verify `A`/`AAAA` records.
- `AAAA` record format:
  use a host IPv6 address only (for example `2a01:4f8:1c1c:ad5f::1`), never CIDR (`/64`).
- `Connection refused` during Coolify server validation:
  verify SSH port from server config and runtime listeners:

  ```bash
  sudo grep -Rns '^[[:space:]]*Port ' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf
  sudo ss -lntp | grep sshd
  ```

- Local server validation from the same Coolify instance:
  use `host.docker.internal` as host, not `127.0.0.1`.
- Coolify SSH user:
  bootstrap sets local server user to `COOLIFY_SUDO_NOPASSWD_USER` (default `coolify`).
- Validate published web ports:

  ```bash
  sudo ss -lntp | grep -E ':(80|443|8000)\b' || true
  sudo docker ps --format 'table {{.Names}}\t{{.Ports}}'
  ```

  If only `8000` is listening, finish onboarding first, then configure/redeploy proxy.

6. Deploy workloads from private/project repositories:

   In Coolify, create or select a Project, connect your Git provider, pick a repository and branch, configure runtime environment variables, then deploy.
   Verify deployment health, logs, and exposed domains before sending production traffic.

## 4) Advanced operations

- Replay bootstrap policy: [Operations and Security](operations-security.md#replay-bootstrap-policy-idempotent)
- Failed first boot recovery: [Bootstrap Failure Recovery](bootstrap-failure-recovery.md)

Back to [Docs Home](index.md)
