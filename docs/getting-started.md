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

Generate-secrets scripts auto-detect the current user SSH public key (local machine)
and fill `SSH_PUBLIC_KEY` when it is empty or still `CHANGE_ME`.

Configure `env/bootstrap.env` by group:

### A) Auto-resolved on host

- <span style="color:#2563eb;"><code>PRIMARY_SUDO_USER</code></span>
  - <span style="color:#166534;"><strong>When:</strong></span> at bootstrap/replay runtime, before sudo policy is written.
  - <span style="color:#a16207;"><strong>How:</strong></span> if empty, `bootstrap-host.sh` resolves it from the first value in `SUDO_USERS`; if still empty, it falls back to `deploy`.
  - <span style="color:#2563eb;"><strong>Must change: NO</strong></span> (keep default unless you want a different primary operator username).
- <span style="color:#2563eb;"><code>SSH_KEY_ROTATE</code></span>
  - <span style="color:#166534;"><strong>When:</strong></span> runtime, while synchronizing `authorized_keys`.
  - <span style="color:#a16207;"><strong>How:</strong></span> if missing, default is `0` (append). `1` replaces existing `authorized_keys` content with `SSH_PUBLIC_KEY`.
  - <span style="color:#2563eb;"><strong>Must change: NO</strong></span> (use `1` only for controlled key replacement).
- <span style="color:#2563eb;"><code>ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS</code></span>
  - <span style="color:#166534;"><strong>When:</strong></span> runtime, while applying `DOCKER-USER` rules.
  - <span style="color:#a16207;"><strong>How:</strong></span> if missing, default is `0` (block public ingress to `6001/6002`). `1` skips those guards.
  - <span style="color:#2563eb;"><strong>Must change: NO</strong></span> (default `0` is recommended for most deployments).

Example:

```env
PRIMARY_SUDO_USER=deploy
SSH_KEY_ROTATE=0
ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS=0
```

### B) Coolify admin variables

- <span style="color:#2563eb;"><code>COOLIFY_PUBLIC_DOMAIN</code></span>
  - <span style="color:#166534;"><strong>When:</strong></span> injected into cloud-init and used during bootstrap output/onboarding flow.
  - <span style="color:#a16207;"><strong>How:</strong></span> static env value, validated as a hostname.
  - <span style="color:#b91c1c;"><strong>Must change: YES</strong></span> (required; do not keep `CHANGE_ME`).
- <span style="color:#2563eb;"><code>COOLIFY_ROOT_USERNAME</code></span>
  - <span style="color:#166534;"><strong>When:</strong></span> during Coolify install/upgrade step.
  - <span style="color:#a16207;"><strong>How:</strong></span> passed as environment to the Coolify installer.
  - <span style="color:#b91c1c;"><strong>Must change: YES</strong></span> (required; use a non-default username).
- <span style="color:#2563eb;"><code>COOLIFY_ROOT_USER_EMAIL</code></span>
  - <span style="color:#166534;"><strong>When:</strong></span> during Coolify install/upgrade step.
  - <span style="color:#a16207;"><strong>How:</strong></span> passed to installer and validated as email format.
  - <span style="color:#b91c1c;"><strong>Must change: YES</strong></span> (required).
- <span style="color:#2563eb;"><code>COOLIFY_ROOT_USER_PASSWORD</code></span>
  - <span style="color:#166534;"><strong>When:</strong></span> generated locally by `generate-secrets.*` before provisioning (if empty/`CHANGE_ME`), then used during Coolify install.
  - <span style="color:#a16207;"><strong>How:</strong></span> Bash uses `openssl rand -hex 12` (24 hex chars); PowerShell script uses equivalent random generation.
  - <span style="color:#2563eb;"><strong>Must change: NO</strong></span> (auto-generated is valid; rotate with `--force-password` when needed).

Example:

```env
COOLIFY_PUBLIC_DOMAIN=hub.example.com
COOLIFY_ROOT_USERNAME=ops-admin
COOLIFY_ROOT_USER_EMAIL=ops@example.com
COOLIFY_ROOT_USER_PASSWORD=<generated-by-generate-secrets>
```

### C) Server user variables

- <span style="color:#2563eb;"><code>SSH_PUBLIC_KEY</code></span> / <span style="color:#2563eb;"><code>SSH_PUBLIC_KEY_PATH</code></span>
  - <span style="color:#166534;"><strong>When:</strong></span> local preparation phase, then host bootstrap when writing `authorized_keys`.
  - <span style="color:#a16207;"><strong>How:</strong></span> `generate-secrets.*` tries local auto-detection from `~/.ssh/*.pub` and populates `SSH_PUBLIC_KEY`; alternatively set `SSH_PUBLIC_KEY_PATH` explicitly.
  - <span style="color:#b91c1c;"><strong>Must change: YES</strong></span> (one valid SSH public key must be resolved, manually or via auto-detection).
- <span style="color:#2563eb;"><code>SSH_PORT</code></span>
  - <span style="color:#166534;"><strong>When:</strong></span> applied at bootstrap/replay in SSH config.
  - <span style="color:#a16207;"><strong>How:</strong></span> written to `sshd_config.d`, then `ssh.service` is restarted; stale listeners on `22` are cleaned when port is not `22`.
  - <span style="color:#2563eb;"><strong>Must change: NO</strong></span> (`2222` default works; a dedicated non-default port is recommended).
- <span style="color:#2563eb;"><code>SECONDARY_SUDO_USER</code></span>, <span style="color:#2563eb;"><code>CREATE_USERS</code></span>, <span style="color:#2563eb;"><code>SUDO_USERS</code></span>, <span style="color:#2563eb;"><code>DOCKER_USERS</code></span>, <span style="color:#2563eb;"><code>COOLIFY_GROUP_USERS</code></span>
  - <span style="color:#166534;"><strong>When:</strong></span> runtime, before group/sudo policy is enforced.
  - <span style="color:#a16207;"><strong>How:</strong></span> users in `CREATE_USERS` are created if missing; other lists must be subsets of `CREATE_USERS`; memberships and sudo policy are then reconciled.
  - <span style="color:#2563eb;"><strong>Must change: NO</strong></span> (change only if your team model differs from the default `deploy,coolify` setup).
- <span style="color:#2563eb;"><code>TIMEZONE</code></span>
  - <span style="color:#166534;"><strong>When:</strong></span> early cloud-init stage.
  - <span style="color:#a16207;"><strong>How:</strong></span> applied as system timezone.
  - <span style="color:#2563eb;"><strong>Must change: NO</strong></span> (`UTC` is recommended for servers).

Example:

```env
SSH_PORT=2288
SECONDARY_SUDO_USER=coolify
CREATE_USERS=deploy,coolify,ci
SUDO_USERS=deploy,coolify
DOCKER_USERS=deploy,coolify,ci
COOLIFY_GROUP_USERS=deploy,coolify
TIMEZONE=UTC
```

### D) Generated passwords and secrets

- <span style="color:#2563eb;"><code>USER_PASSWORDS_ENCRYPTION_PASSWORD</code></span>
  - <span style="color:#166534;"><strong>When:</strong></span> generated locally by `generate-secrets.*` before provisioning (if empty/`CHANGE_ME`), then reused on host in every bootstrap/replay.
  - <span style="color:#a16207;"><strong>How:</strong></span> Bash uses `openssl rand -hex 16` (32 hex chars); used by `ensure-user-passwords.sh` for AES-256-CBC (`pbkdf2`, `iter 200000`) encryption of `/etc/vps-coolify-bootstrap/user-passwords.enc`.
  - <span style="color:#2563eb;"><strong>Must change: NO</strong></span> (auto-generated is valid; do not change post-provision without a rotation plan).
- system passwords for users in `CREATE_USERS` (not separate env vars)
  - <span style="color:#166534;"><strong>When:</strong></span> on host, in `ensure-user-passwords.sh`, during bootstrap/replay.
  - <span style="color:#a16207;"><strong>How:</strong></span> for locked/unset accounts, script generates `openssl rand -hex 12`, sets password via `chpasswd`, and stores credentials encrypted in `user-passwords.enc`.
  - <span style="color:#b91c1c;"><strong>Must change: YES</strong></span> for `PRIMARY_SUDO_USER` on first login (`sudo passwd "$(whoami)"`); for other users based on your internal policy.

Example:

```bash
# local (before provisioning): generate or refresh secrets in env/bootstrap.env
bash scripts/generate-secrets.sh --env-file env/bootstrap.env

# server (after bootstrap): decrypt generated user-password vault if needed
export USER_PASSWORDS_ENCRYPTION_PASSWORD="<value-from-bootstrap.env>"
sudo openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in /etc/vps-coolify-bootstrap/user-passwords.enc \
  -pass env:USER_PASSWORDS_ENCRYPTION_PASSWORD
```

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
   Log in with `COOLIFY_ROOT_USERNAME` / `COOLIFY_ROOT_USER_EMAIL` and `COOLIFY_ROOT_USER_PASSWORD` from your env file.

6. Deploy workloads from private/project repositories:

   In Coolify, create/select a Project, connect your Git provider, pick repository + branch, configure runtime env vars, then deploy.
   Verify deployment health, logs, and exposed domains before sending production traffic.

## 4) Replay bootstrap policy (idempotent)

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

Use this when you want to re-apply the server baseline from
`/etc/vps-coolify-bootstrap/bootstrap.env` without reprovisioning the VPS.

Idempotent means repeated runs converge to the same final state.
If the server already matches policy, replay should keep it aligned, not
create duplicate state.

When to run replay:

- after changing `bootstrap.env` policy values (`SSH_PORT`, users, sudo policy, group lists)
- after a partial/failed first boot where baseline was only partially applied
- after emergency manual fixes that may have drifted from the bootstrap policy
- after pulling a newer `bootstrap-host.sh` and wanting to apply new safeguards

What replay does not do:

- it does not deploy your application workloads from private repositories
- it does not remove your Docker volumes/databases
- it does not replace your SSH key unless `SSH_KEY_ROTATE=1`

What replay enforces:

- SSH hardening from bootstrap policy (`sshd_config`, `AllowUsers`, service state)
- sudo policy (`PRIMARY_SUDO_USER` passwordless, other sudo users password-based)
- user/group memberships for `sudo`, `docker`, and `coolify`
- UFW baseline (allow SSH on configured `SSH_PORT`, plus `80` and `443`)
- fail2ban and unattended-upgrades enabled

Important operational note:

- run replay as `PRIMARY_SUDO_USER` (passwordless sudo) or root via provider console
- replay always resets UFW to baseline, so custom manual UFW rules must be re-applied after replay
- replay restarts SSH service; keep a fallback console session open
- replay can terminate stale `sshd` listeners on `22` when `SSH_PORT` is not `22`
- replay can enforce `DOCKER-USER` guards for `6001/6002` (default behavior)

Safe run checklist:

1. Keep provider console access open.
2. Confirm you can open a second SSH session on the configured port.
3. Run replay.
4. Verify baseline immediately:

```bash
sudo systemctl is-active ssh.service fail2ban unattended-upgrades
sudo ss -lntp | grep -E ':(22|<SSH_PORT>|6001|6002|8000)\b' || true
sudo ufw status verbose
sudo iptables -S DOCKER-USER | grep -E '6001|6002' || true
```

Examples:

1. Add a new operator user: update `CREATE_USERS`, `SUDO_USERS`, and optional group lists in `bootstrap.env`, then run replay. Verify with:

```bash
id newuser
getent group sudo docker coolify
sudo cat /etc/ssh/sshd_config.d/10-bootstrap-hardening.conf | grep '^AllowUsers'
```

2. Recover after partial first boot: if cloud-init applied only part of the baseline, replay enforces missing policy in one step. Verify with:

```bash
sudo systemctl is-active ssh.service fail2ban unattended-upgrades
sudo ufw status verbose
```

3. Rotate SSH access policy: update `SSH_PORT` and/or `CREATE_USERS` in `bootstrap.env`, run replay, then test from a second terminal before closing the current session:

```bash
ssh -p <NEW_SSH_PORT> <PRIMARY_SUDO_USER>@<SERVER_IP>
```

4. Lock down Coolify realtime ports: keep `ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS=0`, run replay, then confirm guard rules exist:

```bash
sudo iptables -S DOCKER-USER | grep -E '6001|6002'
sudo ip6tables -S DOCKER-USER 2>/dev/null | grep -E '6001|6002' || true
```

Back to [Docs Home](index.md)
