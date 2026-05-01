---
title: Getting Started
nav_order: 2
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

## 1) Generate local env + secrets

Fresh clone default command:

Linux/macOS:

```bash
bash scripts/generate-secrets.sh
```

Windows PowerShell:

```powershell
pwsh -File scripts/generate-secrets.ps1
```

This creates/updates `bootstrap-artifacts/bootstrap.env`.

Detailed usage (force flags, custom env path, rerender workflow):
- [Script Workflow](scripts-workflow.md)

Variable-by-variable reference:
- [Bootstrap Env Reference](bootstrap-env-reference.md)

## 2) Generate VPS-Coolify init file

Linux/macOS:

```bash
bash scripts/prepare-vps-coolify-init.sh --overwrite
```

PowerShell:

```powershell
pwsh -File scripts/prepare-vps-coolify-init.ps1 -Overwrite
```

Default output:
- `bootstrap-artifacts/vps-coolify-init.generated.yml`

## 3) Provision VPS

Use `bootstrap-artifacts/vps-coolify-init.generated.yml` as provider user-data (VPS init format)
when you create the VPS.

Important:
- paste full file content including first line `#cloud-config`
- this runs only on first boot
- changing user-data later does not re-apply automatically to an existing VPS

If your provider has no user-data field:
1. check API/CLI support first (many providers support user-data there)
2. if no user-data support exists, use the existing server workflow below

### Alternative: Bootstrap on an existing server (no cloud-init)

Use this path when:
- your provider does not support user-data (e.g., OVH VPS reinstall)
- the server was already provisioned without this bootstrap
- you want to apply bootstrap hardening to a running server

Prerequisites:
- Ubuntu 24.04 LTS (recommended) or 22.04 LTS
- root or sudo access (provider console or SSH)
- `bootstrap-artifacts/bootstrap.env` prepared locally (steps 1-2 above)

#### On the server (as root or via provider console):

```bash
# Clone the bootstrap repository
git clone https://github.com/rigu/vps-coolify-bootstrap.git /opt/vps-coolify-bootstrap

# Create env directory
mkdir -p /etc/vps-coolify-bootstrap
```

#### Copy env from local machine to server:

```bash
scp bootstrap-artifacts/bootstrap.env root@<SERVER_IP>:/etc/vps-coolify-bootstrap/bootstrap.env
```

Or create/edit directly on server:

```bash
nano /etc/vps-coolify-bootstrap/bootstrap.env
chmod 600 /etc/vps-coolify-bootstrap/bootstrap.env
```

#### Run preparation + bootstrap:

```bash
# Install packages, sysctl hardening, fail2ban jail
sudo bash /opt/vps-coolify-bootstrap/scripts/prepare-existing-server.sh /etc/vps-coolify-bootstrap/bootstrap.env

# Run full bootstrap (SSH hardening, UFW, users, Coolify install)
sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

What `prepare-existing-server.sh` does:
- waits for apt lock release (max 60s)
- detects Ubuntu version and warns if not 24.04 LTS
- installs required packages: `ca-certificates`, `curl`, `git`, `openssl`, `python3`, `ufw`, `fail2ban`, `unattended-upgrades`
- writes kernel hardening sysctl config (`/etc/sysctl.d/99-hardening.conf`)
- writes fail2ban SSH jail config with your configured `SSH_PORT`

After both scripts complete, the server is at full parity with a cloud-init provisioned server.

Important notes:
- keep provider console open during first run (SSH port changes)
- after bootstrap, connect via: `ssh -p <SSH_PORT> <DEVOPS_USER>@<SERVER_IP>`
- set local password on first login: `sudo passwd <DEVOPS_USER>`

## 4) After first boot checklist

Run this on the VPS (provider console if SSH is not ready yet):

```bash
sudo cloud-init status --wait
sudo tail -n 200 /var/log/vps-bootstrap.log
```

Note:
- `cloud-init` is the Ubuntu first-boot service from the base image
- it is not created by this repository; bootstrap runs inside that flow

Ready-for-SSH quick check:

```bash
sudo cloud-init status --wait
sudo ss -lntp | grep -E ':(<SSH_PORT>)\b' || true
sudo ufw status verbose
```

Replace `<SSH_PORT>` with your configured value from
`/etc/vps-coolify-bootstrap/bootstrap.env` (default `2222`).

Connect by SSH:

```bash
ssh -p <SSH_PORT> <DEVOPS_USER>@<SERVER_IP>
```

If host key changed after reprovision/reinstall, clear stale local key entry.

Windows PowerShell:

```powershell
ssh-keygen -R "[<SERVER_IP>]:<SSH_PORT>"
```

Linux/macOS:

```bash
ssh-keygen -R "[<SERVER_IP>]:<SSH_PORT>"
```

On first login, set local password for `DEVOPS_USER`:

```bash
sudo passwd <DEVOPS_USER>
```

Validate baseline:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/verify-bootstrap-state.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

Complete Coolify onboarding:
- first access: `http://<SERVER_IP>:8000`
- after domain setup in UI: `https://<COOLIFY_PUBLIC_DOMAIN>`
- login: `COOLIFY_ROOT_USER_EMAIL` + `COOLIFY_ROOT_USER_PASSWORD`

Troubleshooting onboarding and server validation errors:
- [Onboarding Troubleshooting](onboarding-troubleshooting.md)

Deploy workloads after onboarding:
- create/select project in Coolify
- connect Git provider
- configure runtime env vars
- deploy and validate health

Recommended next sequence for workloads:
1. Create internal service layer: [Create Infra Network](create-infra-network.md)
2. Deploy Docmost workload: [Install Docmost on Coolify](install-docmost-on-coolify.md)
3. Deploy Plane workload: [Install Plane on Coolify](install-plane-on-coolify.md)

## 5) Advanced operations

After the server is running and Coolify onboarding is complete:

- **Policy changes**: replay bootstrap after editing server-side `bootstrap.env` — see [Operations and Security](operations-security.md#replay-bootstrap-policy-idempotent)
- **Coolify upgrades**: follow the update runbook — see [Operations and Security](operations-security.md#coolify-update-runbook-recommended)
- **Failed first boot**: step-by-step recovery — see [Bootstrap Failure Recovery](bootstrap-failure-recovery.md)
- **Realtime modes**: switch between public/closed — see [VPS Coolify Realtime Modes](vps-coolify-realtime-modes.md)

Back to [Docs Home](index.md)
