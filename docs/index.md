---
title: Home
nav_order: 1
---

# VPS Coolify Bootstrap

Production-ready bootstrap for **Coolify on Ubuntu 24.04 LTS** — from first boot to running workloads.

## Quick Start

```bash
git clone https://github.com/rigu/vps-coolify-bootstrap.git
cd vps-coolify-bootstrap
bash scripts/generate-secrets.sh
# Edit bootstrap-artifacts/bootstrap.env with your values
bash scripts/prepare-vps-coolify-init.sh --overwrite
# Use bootstrap-artifacts/vps-coolify-init.generated.yml as VPS user-data
```

→ Full walkthrough: [Getting Started](getting-started.md)

## What You Get

| Feature | Description |
|---------|-------------|
| First-boot provisioning | VPS init user-data with full hardening |
| SSH hardening | `AllowUsers`, pubkey-only, custom port |
| Firewall baseline | UFW + fail2ban + unattended upgrades |
| Coolify access flow | Onboarding on `:8000`, then domain/TLS on `80/443` |
| Realtime policy | Configurable `6001/6002` exposure via env |
| Cross-platform | Bash + PowerShell render scripts |
| Verification | Post-bootstrap state validation script |
| Recovery | Emergency SSH recovery + failure runbook |
| Credential vault | Encrypted server-side user passwords |

## Implementation Guide

Follow these pages in order for a complete deployment:

| Step | Page | What it covers |
|------|------|----------------|
| 1 | [Getting Started](getting-started.md) | Generate env, render init, provision VPS |
| 2 | [Onboarding Troubleshooting](onboarding-troubleshooting.md) | Fix common Coolify onboarding issues |
| 3 | [Create Infra Network](create-infra-network.md) | Deploy shared services (Postgres, Valkey, RabbitMQ, SeaweedFS) |
| 4 | [Install Docmost on Coolify](install-docmost-on-coolify.md) | Deploy Docmost knowledge base |
| 5 | [Install Plane on Coolify](install-plane-on-coolify.md) | Deploy Plane project management |

## Reference Pages

| Page | Purpose |
|------|---------|
| [Backup Strategy](backup-strategy.md) | Production backup design |
| [Maintenance Runbook](maintenance-runbook.md) | Daily/weekly/monthly checks |
| [Script Workflow](scripts-workflow.md) | Detailed script usage and flags |
| [Bootstrap Env Reference](bootstrap-env-reference.md) | All env variables documented |
| [Bootstrap Flow](bootstrap-flow.md) | First-boot execution order |
| [Operations & Security](operations-security.md) | Post-bootstrap hardening and updates |
| [Deployment Modes](vps-coolify-deployment-modes.md) | All supported deployment paths |
| [Realtime Modes](vps-coolify-realtime-modes.md) | Realtime port exposure options |
| [Failure Recovery](bootstrap-failure-recovery.md) | Step-by-step recovery runbook |
| [Plane Incident Prevention](plane-community-v1.2.3-incident-prevention.md) | Known Plane issues and fixes |
| [GitHub Promotion](github-promotion.md) | Maintainer checklist |

## Repository Layout

```
env/              Env templates (.env.example files)
scripts/          Bootstrap + helper scripts (Bash + PowerShell)
templates/        VPS init + compose templates
docs/             This documentation site
bootstrap-artifacts/  Generated output (not committed)
```

## Primary Sources

- [Docker packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
- [Docker iptables and DOCKER-USER](https://docs.docker.com/engine/network/firewall-iptables/)
- [Coolify firewall guidance](https://coolify.io/docs/knowledge-base/server/firewall)
- [Coolify auto-update behavior](https://coolify.io/docs/knowledge-base/server/auto-update)
- [OpenSSH AllowUsers](https://man.openbsd.org/sshd_config#AllowUsers)

_Last verified: March 7, 2026._

---

**License:** [MIT](../LICENSE) — Use at your own risk; see the [README disclaimer](https://github.com/rigu/vps-coolify-bootstrap#disclaimer).
