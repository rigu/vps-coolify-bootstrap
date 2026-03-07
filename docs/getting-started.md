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
- `ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS` (`0` recommended, blocks public ingress to `6001/6002`)
- `BOOTSTRAP_REPO_URL` only if you use a fork/mirror
- `BOOTSTRAP_REPO_REF` if you need a different branch/tag

Default `BOOTSTRAP_REPO_URL`:
`https://github.com/rigu/vps-coolify-bootstrap.git`

Other configurable defaults:

- `TIMEZONE=UTC`
- `SSH_PORT=2222`
- `PRIMARY_SUDO_USER=deploy`
- `SECONDARY_SUDO_USER=coolify`
- `ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS=0`

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
sudo ss -lntp | egrep ':(22|<SSH_PORT>|6001|6002|8000)\b' || true
sudo ufw status verbose
sudo iptables -S DOCKER-USER | egrep '6001|6002' || true
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
sudo iptables -S DOCKER-USER | egrep '6001|6002'
sudo ip6tables -S DOCKER-USER 2>/dev/null | egrep '6001|6002' || true
```

Back to [Docs Home](index.md)
