---
layout: page
title: Bootstrap Flow
description: Detailed first-boot execution order, cloud-init behavior, and bootstrap flow for Coolify provisioning.
---

# Bootstrap Flow

## What the cloud-init YAML does

`prepare-cloud-init.sh` or `prepare-cloud-init.ps1` renders `cloud-init.generated.yml` from:

- `templates/cloud-init.template.yml`
- `env/bootstrap.env`

On first boot, cloud-init:

1. sets timezone and runs package update/upgrade
2. creates initial users (`PRIMARY_SUDO_USER`, `SECONDARY_SUDO_USER`) and SSH key
3. disables root SSH login and SSH password auth
4. installs baseline packages (`curl`, `git`, `openssl`, `ufw`, `fail2ban`, `unattended-upgrades`, ...)
5. writes hardening and runtime files
6. clones bootstrap repo at selected URL/ref
7. applies `sysctl --system`
8. runs `scripts/bootstrap-host.sh`

## First-boot execution order

```mermaid
flowchart TD
  A[Prepare env/bootstrap.env + generate secrets] --> B[Render cloud-init.generated.yml]
  B --> C[Create Ubuntu 24 VPS with cloud-init user-data]
  C --> D[cloud-init first boot]
  D --> E[Install baseline packages + write hardening files + bootstrap env]
  E --> F[Clone BOOTSTRAP_REPO_URL at BOOTSTRAP_REPO_REF]
  F --> G[Apply sysctl --system]
  G --> H[Run scripts/bootstrap-host.sh]
  H --> H1[Validate inputs: usernames/email/domain/passwords/SSH key + subset checks]
  H1 --> I[Ensure CREATE_USERS exist + SSH keys]
  I --> J[Run ensure-user-passwords.sh]
  J --> K[Set/rotate user passwords if needed]
  K --> L[Write encrypted vault /etc/vps-coolify-bootstrap/user-passwords.enc]
  L --> M[Sync SSH AllowUsers from CREATE_USERS]
  M --> N[Validate/restart SSH on configured port]
  N --> O[Apply UFW rules and enable fail2ban + unattended-upgrades]
  O --> P[Install Coolify if missing]
  P --> Q[Apply sudo/docker/coolify groups + sudo policy]
  Q --> R[SSH login on hardened port]
  R --> S[Finish Coolify onboarding]
```

## Runtime outputs

- Coolify URL printed by bootstrap:
  - `https://<COOLIFY_PUBLIC_DOMAIN>`
- encrypted credential vault:
  - `/etc/vps-coolify-bootstrap/user-passwords.enc`

To decrypt on server:

```bash
export USER_PASSWORDS_ENCRYPTION_PASSWORD="<value-from-bootstrap.env>"
sudo openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in /etc/vps-coolify-bootstrap/user-passwords.enc \
  -pass env:USER_PASSWORDS_ENCRYPTION_PASSWORD
```

Back to [Docs Home](index.md)
