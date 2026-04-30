---
title: Onboarding Troubleshooting
nav_order: 3
---

# Onboarding Troubleshooting

Use this page when Coolify onboarding or server validation fails.

## 1) `403 Forbidden` on `COOLIFY_PUBLIC_DOMAIN`

Usually DNS points to a different host.

Check:
- `A` record points to the correct IPv4
- `AAAA` record points to the correct IPv6 host address

Important IPv6 format:
- valid host example: `2001:db8:1c1c:ad5f::1`
- invalid host format: `2001:db8:1c1c:ad5f::1/64`

## 2) `Start Proxy` fails with `ParseAddr(".../64")`

Replay bootstrap (default mitigation is enabled by env):

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
docker version
sudo docker info --format '{{.IPv6}}'
```

Relevant env toggle:
- `DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX=true` (default)

## 3) `Connection refused` during local server validation

Verify SSH listen configuration and runtime listeners:

```bash
sudo grep -Rns '^[[:space:]]*Port ' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf
sudo ss -lntp | grep sshd
```

For local server in same Coolify instance:
- host should be `host.docker.internal` (not `127.0.0.1`)
- user should be `COOLIFY_SUDO_NOPASSWD_USER` (default `coolify`)

## 4) Web ports state unclear

Check current listeners and published ports:

```bash
sudo ss -lntp | grep -E ':(80|443|8000)\b' || true
sudo docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

Expected before onboarding completes:
- `8000` is used for initial Coolify access
- `80/443` may not listen yet until proxy/domain setup in UI

## 5) SSH host key changed warning

When reconnecting after reprovision/reinstall, clear stale local key entry.

Windows PowerShell:

```powershell
ssh-keygen -R "[<SERVER_IP>]:<SSH_PORT>"
```

Linux/macOS:

```bash
ssh-keygen -R "[<SERVER_IP>]:<SSH_PORT>"
```

If warning persists, remove the offending line from local `known_hosts` and reconnect.

## 6) Need deeper recovery

Use full recovery runbook:
- [Bootstrap Failure Recovery](bootstrap-failure-recovery.md)

## 7) `Permission denied` under `/data/coolify/services/...`

Example error:
- `bash: line 2: cd: /data/coolify/services/<service-id>: Permission denied`

This means the localhost SSH user configured in Coolify (for this repo, usually
`COOLIFY_SUDO_NOPASSWD_USER`, default `coolify`) cannot traverse/write
Coolify runtime paths.

Apply fix by replaying bootstrap:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

Quick temporary fix (before replay) if needed:

```bash
sudo chgrp coolify /data/coolify
sudo chmod g+rx /data/coolify
sudo chgrp -R coolify /data/coolify/services /data/coolify/proxy 2>/dev/null || true
sudo chmod -R g+rwX /data/coolify/services /data/coolify/proxy 2>/dev/null || true
sudo find /data/coolify/services /data/coolify/proxy -type d -exec chmod g+s {} + 2>/dev/null || true
sudo find /data/coolify -type f -name 'ssh_key@*' -exec chmod 600 {} + 2>/dev/null || true
```

Then retry the action in Coolify UI.

## 8) Port 22 still listening after bootstrap (existing server)

Symptom:
- `bootstrap-host.sh` fails with: `port 22 is still listening after stale-listener cleanup`
- `bootstrap expects only SSH_PORT=<custom_port>; inspect ssh.socket and SSH config fragments`

Cause:
- On Ubuntu 24.04, the default SSH service uses `ssh.socket` (systemd socket activation)
  which listens on port 22.
- Bootstrap disables `ssh.socket` and restarts `ssh.service` on the custom port, but the
  original sshd process (spawned by socket activation before bootstrap ran) keeps its
  file descriptors open on port 22.
- This is most common on existing servers where SSH was already active before bootstrap.

Fix:

```bash
# Identify the stale sshd process on :22
sudo ss -lntp | grep ':22 '
# Output shows pid=XXXXX

# Kill the stale listener
sudo kill <PID>

# Verify only custom port remains
sudo ss -lntp | grep ssh
# Should show only :2278 (or your SSH_PORT)

# Re-run bootstrap
sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

Prevention:
- On a fresh server, stop the default SSH before running bootstrap:

```bash
sudo systemctl disable --now ssh.socket
sudo systemctl stop ssh.service
sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

Important: keep provider console access open when killing SSH processes.
Do not disconnect your current session until you confirm access on the new port
from a separate terminal.

## 9) `UNPROTECTED PRIVATE KEY FILE` for Coolify localhost key

Example error:
- `Permissions 0660 for '/var/www/html/storage/app/ssh/keys/ssh_key@...' are too open`
- `Load key "...": bad permissions`
- `Permission denied (publickey)`

Fix immediately:

```bash
sudo find /data/coolify -type f -name 'ssh_key@*' -exec chmod 600 {} +
```

Then replay bootstrap so the policy is reapplied consistently:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

Back to [Getting Started](getting-started.md)
