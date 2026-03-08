---
---

# Getting Started

## 0) Clone repository

Linux/macOS:

```bash
git clone https://github.com/rigu/vps-coolify-bootstrap.git
cd vps-coolify-bootstrap
```

Windows PowerShell:

```powershell
git clone https://github.com/rigu/vps-coolify-bootstrap.git
Set-Location .\vps-coolify-bootstrap
```

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
- sets strict permissions for generated env file in Bash (`chmod 600`); in PowerShell it writes the file and prints an ACL warning for manual verification on shared systems

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
If no valid key is found, `prepare-vps-coolify-init.*` now generates YML with a
separate warning block and skips the `DEVOPS_USER` `ssh_authorized_keys` entry.
Bootstrap continues, but first remote SSH access will require an alternate method
(provider console, password-based recovery path, or manual key injection).

### Detailed script workflow

Use this practical sequence when you want deterministic, repeatable local preparation.

1. Step 1: initialize local env from scratch

   Use this on a fresh clone:

   ```bash
   bash scripts/generate-secrets.sh
   ```

   Expected result:
   - `bootstrap-artifacts/bootstrap.env` is created automatically
   - placeholder secret values are replaced
   - SSH key is auto-filled if detected locally

2. Step 2: inspect and set required business values manually

   Edit `bootstrap-artifacts/bootstrap.env` and set at least:
   - `COOLIFY_PUBLIC_DOMAIN`
   - `COOLIFY_ROOT_USERNAME`
   - `COOLIFY_ROOT_USER_EMAIL`
   - any other values still containing `CHANGE_ME`

   Keep generated values unless you intentionally want new secrets.

3. Step 3: force only Coolify root password regeneration (optional)

   Bash:

   ```bash
   bash scripts/generate-secrets.sh --force-password
   ```

   PowerShell:

   ```powershell
   pwsh -File scripts/generate-secrets.ps1 -ForcePassword
   ```

4. Step 4: force only vault encryption password regeneration (optional)

   Bash:

   ```bash
   bash scripts/generate-secrets.sh --force-encryption-password
   ```

   PowerShell:

   ```powershell
   pwsh -File scripts/generate-secrets.ps1 -ForceEncryptionPassword
   ```

5. Step 5: force SSH key re-detection (optional)

   Use this after rotating local SSH keys:

   Bash:

   ```bash
   bash scripts/generate-secrets.sh --force-ssh-key
   ```

   PowerShell:

   ```powershell
   pwsh -File scripts/generate-secrets.ps1 -ForceSshKey
   ```

6. Step 6: run with a custom env file path (optional)

   Scripts create missing parent folders and copy `env/bootstrap.env.example` if the file is missing.

   Bash:

   ```bash
   bash scripts/generate-secrets.sh --env-file envs/prod/bootstrap.env
   ```

   PowerShell:

   ```powershell
   pwsh -File scripts/generate-secrets.ps1 -EnvFile envs/prod/bootstrap.env
   ```

7. Step 7: render VPS init YAML from prepared env

   Bash (default path):

   ```bash
   bash scripts/prepare-vps-coolify-init.sh --overwrite
   ```

   PowerShell (default path):

   ```powershell
   pwsh -File scripts/prepare-vps-coolify-init.ps1 -Overwrite
   ```

   Expected output: `bootstrap-artifacts/vps-coolify-init.generated.yml`

8. Step 8: rerender safely after env changes

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
- enforces cross-field rule: `COOLIFY_REALTIME_DOMAIN` is required when `CLOSE_COOLIFY_REALTIME_PORTS=true`, and if set it must not contain `CHANGE_ME`
- fails if output exists and overwrite is not enabled
- fails if generated file exceeds provider size limit (Hetzner VPS init: 32768 bytes)

### `SSH_KEY_ROTATE`: exact scope and practical key-rotation example

`SSH_KEY_ROTATE` controls how bootstrap applies `SSH_PUBLIC_KEY` into
`authorized_keys` for:
- `DEVOPS_USER`
- users from `ADDITIONAL_SUDO_USERS`

It does not apply to:
- `COOLIFY_SUDO_NOPASSWD_USER` (uses dedicated localhost/private-only key flow)
- `root` (root login is disabled)

- `SSH_KEY_ROTATE=0` (default): append mode
  - keeps existing keys
  - adds current `SSH_PUBLIC_KEY` only if missing
- `SSH_KEY_ROTATE=1`: replace mode
  - rewrites `authorized_keys` with the current `SSH_PUBLIC_KEY`
  - useful when you intentionally want to remove old/stale keys

Example use case:

You rotated your operator key and want `DEVOPS_USER` and other managed users to
accept only the new key.

1. Set in `bootstrap-artifacts/bootstrap.env`:

   ```env
   SSH_PUBLIC_KEY='ssh-ed25519 AAAA...new_key'
   SSH_KEY_ROTATE=1
   ```

2. Replay bootstrap on server:

   ```bash
   sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
   ```

3. After successful key cleanup, set back to safe default for normal operations:

   ```env
   SSH_KEY_ROTATE=0
   ```

## Bootstrap env quick reference

For full behavior details and replay implications, see:
[Operations and Security](operations-security.md#bootstrap-env-reference).

### A) Auto-resolved on host

**Variable Details**
- `DEVOPS_USER`: main operational account used for day-to-day admin work, replay, and controlled sudo operations. If missing, scripts use `devops`.
- `SSH_KEY_ROTATE`: controls key sync behavior for `DEVOPS_USER` and `ADDITIONAL_SUDO_USERS`. `0` keeps existing keys and ensures current key is present; `1` replaces `authorized_keys` with current key.
- `CLOSE_COOLIFY_REALTIME_PORTS`: controls host-level exposure of `6001/6002` through `DOCKER-USER` rules. `false` keeps direct public ingress possible; `true` blocks public ingress and expects domain-based realtime path.

| Variable | Default value | Autogenerated / source | Required |
|---|---|---|---|
| `DEVOPS_USER` | `devops` | No | NO |
| `SSH_KEY_ROTATE` | `0` | No | NO |
| `CLOSE_COOLIFY_REALTIME_PORTS` | `false` | No | NO |

### B) Coolify admin variables

**Variable Details**
- `COOLIFY_PUBLIC_DOMAIN`: canonical public domain for Coolify UI and reverse-proxy entrypoint after onboarding.
- `COOLIFY_ROOT_USERNAME`: root account username created by installer workflow.
- `COOLIFY_ROOT_USER_EMAIL`: root account email used as login identifier in UI.
- `COOLIFY_ROOT_USER_PASSWORD`: bootstrap/root login password for initial access. If placeholder/empty, `generate-secrets.*` creates one locally.

| Variable | Default value | Autogenerated / source | Required |
|---|---|---|---|
| `COOLIFY_PUBLIC_DOMAIN` | none (`CHANGE_ME` placeholder) | No | YES |
| `COOLIFY_ROOT_USERNAME` | none (`CHANGE_ME` placeholder) | No | YES |
| `COOLIFY_ROOT_USER_EMAIL` | none (`CHANGE_ME` placeholder) | No | YES |
| `COOLIFY_ROOT_USER_PASSWORD` | none (`CHANGE_ME` placeholder) | Yes: local via `generate-secrets.*` when empty/`CHANGE_ME` | YES |

### C) Server user variables

**Variable Details**
- `SSH_PUBLIC_KEY` / `SSH_PUBLIC_KEY_PATH`: operator key source used for first SSH key injection and later key reconciliation. Missing values no longer stop bootstrap, but initial SSH key access may require manual recovery path.
- `COOLIFY_SUDO_NOPASSWD_USER`: dedicated localhost automation user for Coolify server integration. It is forced into managed groups and gets dedicated localhost/private-only SSH key restrictions.
- `ADDITIONAL_SUDO_USERS`: optional extra admin users (space/comma/semicolon separated). They are validated, created if missing, and added to sudo/docker/coolify groups.
- `COOLIFY_REALTIME_DOMAIN`: optional dedicated realtime host. When set, bootstrap writes `PUSHER_HOST`, `PUSHER_PORT=443`, `PUSHER_SCHEME=https`.
- `SSH_PORT`: hardened SSH listen port applied through `ssh.service` flow.
- `TIMEZONE`: host timezone applied during VPS init stage.

| Variable | Default value | Autogenerated / source | Required |
|---|---|---|---|
| `SSH_PUBLIC_KEY` or `SSH_PUBLIC_KEY_PATH` | `CHANGE_ME_or_leave_empty` / `CHANGE_ME_ssh_public_key` | Yes: local auto-detect via `generate-secrets.*` when empty/placeholder | NO (recommended YES for direct SSH key-based access) |
| `COOLIFY_SUDO_NOPASSWD_USER` | `coolify` | No | NO |
| `ADDITIONAL_SUDO_USERS` | empty | No | NO |
| `COOLIFY_REALTIME_DOMAIN` | empty | No | CONDITIONAL (YES when `CLOSE_COOLIFY_REALTIME_PORTS=true`, otherwise NO) |
| `SSH_PORT` | `2222` | No | NO |
| `TIMEZONE` | `UTC` | No | NO |

### D) Generated passwords and secrets

**Variable Details**
- `USER_PASSWORDS_ENCRYPTION_PASSWORD`: encryption key used to protect `/etc/vps-coolify-bootstrap/user-passwords.enc`. Keep this value in a secure external vault.

| Variable | Default value | Autogenerated / source | Required |
|---|---|---|---|
| `USER_PASSWORDS_ENCRYPTION_PASSWORD` | none (`CHANGE_ME` placeholder) | Yes: local via `generate-secrets.*` when empty/`CHANGE_ME` | YES |

Runtime output (not env variable):
- account passwords for managed users are generated on-host by `ensure-user-passwords.sh` only when needed (locked/unset user or missing vault entry). Existing unlocked users with vault entries are preserved.

Other bootstrap source variables (usually unchanged):
- `BOOTSTRAP_REPO_URL=https://github.com/rigu/vps-coolify-bootstrap.git`
- `BOOTSTRAP_REPO_REF=main`

Change `BOOTSTRAP_REPO_URL` only if you use a fork/mirror, and
`BOOTSTRAP_REPO_REF` only if you intentionally target a different branch/tag.

See `env/bootstrap.env.example` for all options.

Required column meaning:
- `YES`: bootstrap/prepare requires an effective non-empty value (manual, default, or autogenerated).
- `NO`: bootstrap can continue when value is empty/unset.
- `CONDITIONAL`: requirement depends on other variables (documented in row).

Input validation enforced by scripts:

- `COOLIFY_ROOT_USERNAME` must match `^[A-Za-z0-9._-]+$`
- `COOLIFY_ROOT_USER_EMAIL` must be valid email format
- `COOLIFY_ROOT_USER_PASSWORD` and `USER_PASSWORDS_ENCRYPTION_PASSWORD` must be at least 16 characters
- `SSH_PORT` must be numeric in range `1-65535`
- `CLOSE_COOLIFY_REALTIME_PORTS` must be `true/false` (or `1/0`)
- `COOLIFY_REALTIME_DOMAIN` is required when `CLOSE_COOLIFY_REALTIME_PORTS=true`
- usernames in user lists must match `^[a-z_][a-z0-9_-]*[$]?$` and must not contain `:`
- `root` is forbidden for `DEVOPS_USER`, `COOLIFY_SUDO_NOPASSWD_USER`, and in `ADDITIONAL_SUDO_USERS`
- `DEVOPS_USER` and `COOLIFY_SUDO_NOPASSWD_USER` must be different users
- `ADDITIONAL_SUDO_USERS` must not contain `COOLIFY_SUDO_NOPASSWD_USER`

Bootstrap runtime also terminates stale `sshd` listeners on port `22` when
`SSH_PORT` is configured to a different value, to avoid parallel legacy
listeners outside `ssh.service`.

### Realtime routing summary

For detailed behavior, risk analysis, update commands, and per-mode diagrams:
[VPS Coolify Realtime Modes](vps-coolify-realtime-modes.md).

Quick rule:
- `CLOSE_COOLIFY_REALTIME_PORTS=false`: direct `6001/6002` may remain reachable.
- `CLOSE_COOLIFY_REALTIME_PORTS=true`: realtime must use domain `443`; compose hardening + `DOCKER-USER` guards block direct public `6001/6002`.

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
   sudo tail -n 200 /var/log/vps-bootstrap.log
   ```

   `vps-bootstrap.log` contains timestamped, script-context log entries prefixed with:
   - `[SUCCESS]` for completed bootstrap steps
   - `[WARNING]` for non-fatal issues
   - `[ERROR]` for fatal failures

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
   sudo passwd <DEVOPS_USER>
   ```

   Replace `<DEVOPS_USER>` with the value from `bootstrap-artifacts/bootstrap.env`.

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
- VPS deployment lifecycle modes: [VPS Coolify Deployment Modes](vps-coolify-deployment-modes.md)
- Realtime exposure modes and switch/update procedure: [VPS Coolify Realtime Modes](vps-coolify-realtime-modes.md)

Back to [Docs Home](index.md)
