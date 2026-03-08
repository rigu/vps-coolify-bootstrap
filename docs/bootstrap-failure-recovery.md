---
layout: page
title: Bootstrap Failure Recovery
description: Step-by-step runbook to recover failed first-boot cloud-init/bootstrap execution.
---

# Bootstrap Failure Recovery

Use this runbook when first-boot cloud-init does not finish successfully.
The sequence is explicit and safe to execute end-to-end.

## 0) Preparation (do not skip)

1. Keep provider web console access open (rescue path if SSH is broken).
2. Run recovery as `root` (provider console) or as `PRIMARY_SUDO_USER` / `COOLIFY_SUDO_NOPASSWD_USER` (passwordless `sudo`).
3. Keep local source of truth ready:
   - local repo: `public-vps-coolify-bootstrap`
   - local env file: `bootstrap-artifacts/bootstrap.env`
4. Set shell variables on your machine for faster copy/paste:

```bash
export SERVER_IP="<server-ip>"
export SSH_PORT="<ssh-port>"
export PRIMARY_SUDO_USER="<primary-sudo-user>"
```

## 1) Confirm cloud-init failure state

```bash
sudo cloud-init status --wait
sudo cloud-init status --long
sudo cloud-init query --all | head -n 40
```

If status is `done`, cloud-init finished, and you should troubleshoot service-level issues instead.
If status is `error` or still not complete, continue.

## 2) Collect first error evidence

```bash
sudo tail -n 250 /var/log/cloud-init-output.log
sudo journalctl -u cloud-init -u cloud-config -u cloud-final --no-pager -n 250
sudo grep -Rni "error\\|failed\\|traceback" /var/log/cloud-init* 2>/dev/null | tail -n 80
```

Typical root causes:
- unresolved `CHANGE_ME` values in generated VPS-Coolify init file
- invalid `SSH_PUBLIC_KEY` format
- clone failure for `BOOTSTRAP_REPO_URL` / `BOOTSTRAP_REPO_REF`
- transient apt/network failures during bootstrap

## 3) Validate minimum host baseline

```bash
# Extract PRIMARY/SECONDARY sudo users from server-side bootstrap env.
primary_user="$(sudo sed -n 's/^PRIMARY_SUDO_USER=//p' /etc/vps-coolify-bootstrap/bootstrap.env | tr -d \"'\\r\")"
secondary_user="$(sudo sed -n 's/^SECONDARY_SUDO_USER=//p' /etc/vps-coolify-bootstrap/bootstrap.env | tr -d \"'\\r\")"
primary_user="${primary_user:-deploy}"
secondary_user="${secondary_user:-coolify}"
id "$primary_user" || true
id "$secondary_user" || true
command -v docker || true
sudo systemctl is-active ssh.service fail2ban unattended-upgrades || true
sudo ufw status verbose || true
```

If core services are missing or inactive, continue with manual bootstrap replay.

## 4) Ensure bootstrap repo exists on server

Check if cloud-init cloned the bootstrap repo:

```bash
sudo test -d /opt/vps-coolify-bootstrap && echo "repo present" || echo "repo missing"
```

If missing, recreate it with the same ref used by your env:

```bash
sudo rm -rf /opt/vps-coolify-bootstrap
sudo git clone --depth 1 --branch <BOOTSTRAP_REPO_REF> <BOOTSTRAP_REPO_URL> /opt/vps-coolify-bootstrap
```

Validate script path:

```bash
sudo test -f /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh && echo "script ok"
```

## 5) Ensure server env file exists and is correct

Required server env path:
- `/etc/vps-coolify-bootstrap/bootstrap.env`

If missing or incorrect, recreate it from your local `bootstrap-artifacts/bootstrap.env` values.
Then verify required keys on server:

```bash
sudo awk -F= '
/^(SSH_PORT|PRIMARY_SUDO_USER|SECONDARY_SUDO_USER|COOLIFY_SUDO_NOPASSWD_USER|SSH_PUBLIC_KEY|COOLIFY_SSH_PUBLIC_KEY|CREATE_USERS|SUDO_USERS|DOCKER_USERS|COOLIFY_GROUP_USERS|COOLIFY_PUBLIC_DOMAIN|CLOSE_COOLIFY_REALTIME_PORTS|COOLIFY_REALTIME_DOMAIN|COOLIFY_ROOT_USERNAME|COOLIFY_ROOT_USER_EMAIL|COOLIFY_ROOT_USER_PASSWORD|USER_PASSWORDS_ENCRYPTION_PASSWORD)=/ {
  print $1"=<set>"
}
' /etc/vps-coolify-bootstrap/bootstrap.env
```

Hard checks before replay:

```bash
if sudo grep -n "CHANGE_ME" /etc/vps-coolify-bootstrap/bootstrap.env; then
  echo "replace placeholders first"
fi
sudo sed -n 's/^COOLIFY_ROOT_USER_PASSWORD=//p' /etc/vps-coolify-bootstrap/bootstrap.env | tr -d "'\r" | awk '{print length($0)}'
sudo sed -n 's/^USER_PASSWORDS_ENCRYPTION_PASSWORD=//p' /etc/vps-coolify-bootstrap/bootstrap.env | tr -d "'\r" | awk '{print length($0)}'
```

Password length must be at least 16.

## 6) Replay bootstrap manually (authoritative recovery step)

Run:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

This script is idempotent and executes the following actions in order:
- create/repair users and SSH keys (including `COOLIFY_SUDO_NOPASSWD_USER` with `COOLIFY_SSH_PUBLIC_KEY`)
- during this on-host replay, set passwords for `CREATE_USERS` accounts that are currently locked/unset (not a local pre-generation step)
- store generated credentials encrypted in `/etc/vps-coolify-bootstrap/user-passwords.enc`
- sync `AllowUsers` from `CREATE_USERS`
- enforce SSH runtime/config checks
- terminate stale `sshd` listeners on `22` when `SSH_PORT` is not `22`
- reset/apply UFW baseline rules (`SSH_PORT`, `80`, `443`)
- enable `fail2ban` and `unattended-upgrades`
- install/start Coolify if missing
- sync Coolify localhost server connection to `COOLIFY_SUDO_NOPASSWD_USER` + `SSH_PORT` and dedicated localhost SSH key
- sync realtime host env (`PUSHER_HOST`, `PUSHER_PORT`, `PUSHER_SCHEME`) from `COOLIFY_REALTIME_DOMAIN`
- enforce sudo/docker/coolify memberships and sudo policy (passwordless for `PRIMARY_SUDO_USER` and `COOLIFY_SUDO_NOPASSWD_USER` by default)
- sync `DOCKER-USER` guards for `6001/6002` based on `CLOSE_COOLIFY_REALTIME_PORTS`

Important: Docker-published ports can bypass UFW rules. Validate exposed ports
after recovery with `ss -tulpen` and `docker ps --format 'table {{.Names}}\t{{.Ports}}'`.

## 7) Validate recovery on server

```bash
sudo systemctl is-active ssh.service fail2ban unattended-upgrades
sudo ufw status verbose
sudo docker ps --format 'table {{.Names}}\t{{.Status}}'
sudo iptables -S DOCKER-USER | grep -E '6001|6002' || true
sudo ip6tables -S DOCKER-USER 2>/dev/null | grep -E '6001|6002' || true
primary_user="$(sudo sed -n 's/^PRIMARY_SUDO_USER=//p' /etc/vps-coolify-bootstrap/bootstrap.env | tr -d \"'\\r\")"
primary_user="${primary_user:-deploy}"
id "$primary_user" || true
getent group sudo docker coolify
sudo bash /opt/vps-coolify-bootstrap/scripts/verify-bootstrap-state.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

Expected:
- SSH service active (not socket-activated)
- UFW enabled and allowing configured SSH port + `80/443`
- Docker available
- Coolify container running (name usually `coolify`)
- Coolify localhost server (id `0`) uses `COOLIFY_SUDO_NOPASSWD_USER` and configured `SSH_PORT`
- `DOCKER-USER` rules present for `6001/6002` when `CLOSE_COOLIFY_REALTIME_PORTS=true`

## 8) Validate remote access from your machine

```bash
ssh -p "$SSH_PORT" "$PRIMARY_SUDO_USER@$SERVER_IP" "whoami && hostname && id"
```

If login fails but provider console works, re-check:
- `SSH_PORT` value in server env
- firewall rule for that port (`ufw status`)
- user presence in `/etc/passwd` and authorized key content
- `REMOTE HOST IDENTIFICATION HAS CHANGED` warning (Windows/Linux/macOS):
  verify host fingerprint in provider console (`sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`),
  then run `ssh-keygen -R "[$SERVER_IP]:$SSH_PORT"` locally and reconnect

## 8A) Recover Coolify "Server is not reachable" onboarding errors

Use this section when Coolify UI shows:
- `ssh: connect to host ... port ...: Connection refused`
- `sudo: a terminal is required ...` / `sudo: a password is required`
- `ParseAddr(".../64"): unexpected character`

### A) Validate host/port/user used by Coolify

For a local server managed by the same Coolify instance:
- Host: `host.docker.internal`
- Port: `SSH_PORT` from `bootstrap.env`
- User: `COOLIFY_SUDO_NOPASSWD_USER` (recommended, default `coolify`) or another user with explicit passwordless sudo policy

Important: bootstrap replay already syncs the local Coolify server to
`COOLIFY_SUDO_NOPASSWD_USER`. If UI still shows `root`, run Step 6 again.

Do not use `127.0.0.1` for this case.

```bash
sudo docker exec coolify getent hosts host.docker.internal
sudo ss -lntp | grep sshd
```

### B) Clear fail2ban/UFW blocks against Docker bridge source IPs

```bash
sudo fail2ban-client status sshd
sudo ufw status numbered
```

If you see a banned Docker bridge IP (for example `10.0.1.5`), unban it and remove the related UFW reject rule:

```bash
sudo fail2ban-client set sshd unbanip 10.0.1.5
sudo ufw delete <rule-number-for-reject>
sudo ufw insert 1 allow from 10.0.0.0/8 to any port "$SSH_PORT" proto tcp
sudo ufw reload
```

Optional persistent fail2ban allow-list for private bridge ranges:

```bash
sudo tee /etc/fail2ban/jail.d/20-local-ignore-docker.conf >/dev/null <<'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
EOF
sudo systemctl restart fail2ban
```

### C) Fix sudo policy for Coolify-managed SSH user

Coolify server validation runs non-interactively and needs passwordless sudo.
By default, `PRIMARY_SUDO_USER` and `COOLIFY_SUDO_NOPASSWD_USER` are passwordless.

Check effective sudo mode:

```bash
sudo -u <coolify-ssh-user> -H bash -lc 'sudo -n true && echo OK_NOPASSWD'
```

If this fails, set policy permanently by updating `COOLIFY_SUDO_NOPASSWD_USER` in server `bootstrap.env` and replaying bootstrap, or add an explicit override file loaded after bootstrap policy:

```bash
sudo tee /etc/sudoers.d/zz-coolify-nopasswd >/dev/null <<'EOF'
coolify ALL=(ALL:ALL) NOPASSWD:ALL
EOF
sudo chmod 440 /etc/sudoers.d/zz-coolify-nopasswd
sudo visudo -c
```

### D) Fix invalid IPv6 format in Coolify server settings

If logs show `ParseAddr(".../64")`, remove CIDR suffix from host IPv6.
- valid host example: `2a01:4f8:1c1c:ad5f::1`
- invalid for host field: `2a01:4f8:1c1c:ad5f::1/64`

Then revalidate server connection in Coolify UI.

## 9) If replay still fails, capture focused diagnostics

```bash
sudo journalctl -xe --no-pager -n 200
sudo tail -n 200 /var/log/auth.log
sudo tail -n 200 /var/log/ufw.log 2>/dev/null || true
sudo docker logs coolify --tail 200 2>/dev/null || true
```

Fix the specific failing cause, then rerun Step 6.

## 10) Clean rebuild path (last resort)

Use this only if server state is inconsistent or unrecoverable.

PowerShell note for this section:
- Prefer `pwsh -File ...`
- If `pwsh` is unavailable, run the same script with `powershell -ExecutionPolicy Bypass -File ...`
- Optional install (`pwsh`): `winget install --id Microsoft.PowerShell --source winget`
- If `winget` is unavailable: <https://github.com/PowerShell/PowerShell/releases/latest>

1. On local machine, reset to clean env baseline:
```bash
mkdir -p bootstrap-artifacts
cp env/bootstrap.env.example bootstrap-artifacts/bootstrap.env
bash scripts/generate-secrets.sh --env-file bootstrap-artifacts/bootstrap.env
```
   Windows PowerShell:
```powershell
New-Item -ItemType Directory -Path bootstrap-artifacts -Force | Out-Null
Copy-Item env/bootstrap.env.example bootstrap-artifacts/bootstrap.env
pwsh -File scripts/generate-secrets.ps1 -EnvFile bootstrap-artifacts/bootstrap.env
```
2. Fill all required values in `bootstrap-artifacts/bootstrap.env` (no `CHANGE_ME`).
3. Regenerate VPS-Coolify init:
```bash
bash scripts/prepare-vps-coolify-init.sh --env-file bootstrap-artifacts/bootstrap.env --overwrite
```
   Windows PowerShell:
```powershell
pwsh -File scripts/prepare-vps-coolify-init.ps1 -EnvFile bootstrap-artifacts/bootstrap.env -Overwrite
```
4. Verify generated file is placeholder-free:
```bash
if grep -n "CHANGE_ME\\|_HERE" bootstrap-artifacts/vps-coolify-init.generated.yml; then
  echo "fix placeholders before provisioning"
fi
```
5. Recreate the VPS and paste `bootstrap-artifacts/vps-coolify-init.generated.yml` into the provider user-data/cloud-init field during server creation (first-boot execution). If the provider UI has no such field, use provider API/CLI for user-data or run manual bootstrap from the provider console as described in Getting Started.
6. Re-validate using Steps 1, 7, and 8.

## Decrypt generated user credentials (when needed)

Must be run as `PRIMARY_SUDO_USER` or `COOLIFY_SUDO_NOPASSWD_USER` (both
passwordless sudo) or root via provider console. Other sudo users cannot decrypt because they need their
password for `sudo`, and their password is inside this vault.

```bash
export USER_PASSWORDS_ENCRYPTION_PASSWORD="$(
  sudo sed -n "s/^USER_PASSWORDS_ENCRYPTION_PASSWORD=//p" /etc/vps-coolify-bootstrap/bootstrap.env | tr -d "'\r"
)"

sudo env USER_PASSWORDS_ENCRYPTION_PASSWORD="$USER_PASSWORDS_ENCRYPTION_PASSWORD" \
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in /etc/vps-coolify-bootstrap/user-passwords.enc \
  -pass env:USER_PASSWORDS_ENCRYPTION_PASSWORD
```

Back to [Docs Home](index.md)
