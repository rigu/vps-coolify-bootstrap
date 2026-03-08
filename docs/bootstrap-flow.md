---
layout: page
title: Bootstrap Flow
description: Detailed first-boot execution order, VPS init behavior, and bootstrap flow for Coolify provisioning.
---

# Bootstrap Flow

## What the VPS-Coolify init YAML does

`prepare-vps-coolify-init.sh` or `prepare-vps-coolify-init.ps1` renders
`bootstrap-artifacts/vps-coolify-init.generated.yml` from:

- `templates/vps-init.template.yml` (VPS init template)
- `bootstrap-artifacts/bootstrap.env`

On first boot, the VPS init agent:

1. sets the timezone and runs package update/upgrade
2. creates initial users (`PRIMARY_SUDO_USER`, `SECONDARY_SUDO_USER`) and SSH bootstrap key
   (additional users from `CREATE_USERS` are created later by `bootstrap-host.sh`)
3. disables root SSH login and SSH password auth
4. installs baseline packages (`curl`, `git`, `openssl`, `ufw`, `fail2ban`, `unattended-upgrades`, ...)
5. writes hardening and runtime files
6. clones bootstrap repo at selected URL/ref
7. applies `sysctl --system`
8. runs `scripts/bootstrap-host.sh`

## First-boot execution order

```mermaid
flowchart TD
  A[Prepare env + secrets] --> B[Render VPS-Coolify init]
  B --> C[Provision Ubuntu 24 VPS]
  C --> D["VPS init first boot (cloud-init)"]
  D --> E[Install packages + write baseline files]
  E --> F[Clone BOOTSTRAP_REPO_URL at BOOTSTRAP_REPO_REF]
  F --> G[Apply sysctl --system]
  G --> H[Run scripts/bootstrap-host.sh]
  H --> H1[Validate inputs]
  H1 --> I[Ensure users + SSH keys (including COOLIFY_SUDO_NOPASSWD_USER)]
  I --> J[Run ensure-user-passwords.sh]
  J --> K[Set/rotate user passwords if needed]
  K --> L[Write encrypted vault /etc/vps-coolify-bootstrap/user-passwords.enc]
  L --> M[Sync SSH AllowUsers from CREATE_USERS]
  M --> N[Switch to ssh.service + validate + cleanup :22]
  N --> O[Apply UFW rules and enable fail2ban + unattended-upgrades]
  O --> P[Install Coolify if missing]
  P --> R[Apply groups + sudo policy]
  R --> Q[Sync Coolify localhost SSH user + key + port]
  Q --> Q1[Sync realtime host env from COOLIFY_REALTIME_DOMAIN]
  R --> S[Sync DOCKER-USER guards for 6001/6002 based on CLOSE_COOLIFY_REALTIME_PORTS]
  S --> T[SSH login on hardened port]
  T --> U[Finish Coolify onboarding]
```

Important: `ensure-user-passwords.sh` runs on the VPS host during bootstrap/replay.
User account passwords are not pre-generated locally during env preparation.

## Runtime outputs

- Coolify URL printed by bootstrap: `https://<COOLIFY_PUBLIC_DOMAIN>`
- Encrypted credential vault: `/etc/vps-coolify-bootstrap/user-passwords.enc`

To decrypt on the server (must be run as `PRIMARY_SUDO_USER` or `COOLIFY_SUDO_NOPASSWD_USER`, both passwordless sudo by policy), use the recommended sequence below:

```bash
export USER_PASSWORDS_ENCRYPTION_PASSWORD="$(
  sudo sed -n "s/^USER_PASSWORDS_ENCRYPTION_PASSWORD=//p" /etc/vps-coolify-bootstrap/bootstrap.env | tr -d "'\r"
)"

sudo env USER_PASSWORDS_ENCRYPTION_PASSWORD="$USER_PASSWORDS_ENCRYPTION_PASSWORD" \
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in /etc/vps-coolify-bootstrap/user-passwords.enc \
  -pass env:USER_PASSWORDS_ENCRYPTION_PASSWORD
```

Note: other sudo users require their password to run `sudo`, but their
password is inside this vault. Only `PRIMARY_SUDO_USER` or
`COOLIFY_SUDO_NOPASSWD_USER` (passwordless sudo) or root via provider console
can decrypt it.

Back to [Docs Home](index.md)
