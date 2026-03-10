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
2. if no user-data support exists, run manual bootstrap from provider console:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

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

- Replay bootstrap policy: [Operations and Security](operations-security.md#replay-bootstrap-policy-idempotent)
- Coolify update runbook: [Operations and Security](operations-security.md#coolify-update-runbook-recommended)
- Failed first boot recovery: [Bootstrap Failure Recovery](bootstrap-failure-recovery.md)
- VPS deployment lifecycle modes: [VPS Coolify Deployment Modes](vps-coolify-deployment-modes.md)
- Realtime exposure modes and update procedure: [VPS Coolify Realtime Modes](vps-coolify-realtime-modes.md)
- Create infra for workloads: [Create Infra Network](create-infra-network.md)
- Docmost install guide (Coolify): [Install Docmost on Coolify](install-docmost-on-coolify.md)
- Plane install guide (Coolify): [Install Plane on Coolify](install-plane-on-coolify.md)

Back to [Docs Home](index.md)
