---
layout: page
title: VPS Coolify Bootstrap Docs
description: Canonical documentation for production VPS bootstrapping with Coolify on Ubuntu 24.04.
---

# VPS Coolify Bootstrap

Production-ready public bootstrap for **Coolify on Ubuntu 24.04 LTS**.

## What this gives you

- cloud-init-based first-boot provisioning
- hardened SSH baseline (`AllowUsers`, no password auth, custom port)
- UFW baseline + fail2ban + unattended upgrades
- deterministic env-driven render flow (Bash + PowerShell)
- encrypted server-side user password vault
- explicit first-boot failure recovery runbook

## Documentation Map

- [Getting Started](getting-started.md)
- [Bootstrap Flow](bootstrap-flow.md)
- [Operations & Security](operations-security.md)
- [Failure Recovery Runbook](bootstrap-failure-recovery.md)
- [GitHub Promotion Checklist](github-promotion.md)

## Repository Layout

- `env/` env templates
- `scripts/` bootstrap + helper scripts (Bash + PowerShell)
- `templates/` `cloud-init.template.yml`
- `docs/` operational runbooks and documentation

## Primary Sources

- Docker packet filtering and firewalls: <https://docs.docker.com/engine/network/packet-filtering-firewalls/>
- Docker iptables and `DOCKER-USER`: <https://docs.docker.com/engine/network/firewall-iptables/>
- Coolify firewall guidance: <https://coolify.io/docs/knowledge-base/server/firewall>
- Coolify auto-update behavior: <https://coolify.io/docs/knowledge-base/server/auto-update>
- OpenSSH `AllowUsers`: <https://man.openbsd.org/sshd_config#AllowUsers>

_Last verified: March 7, 2026._

## License and Liability

- License: [MIT](../LICENSE)
- Use at your own risk; see the repository [README disclaimer](https://github.com/rigu/vps-coolify-bootstrap#disclaimer).
