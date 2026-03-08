---
---

# VPS Coolify Bootstrap

Production-ready public bootstrap for **Coolify on Ubuntu 24.04 LTS**.

## What this gives you

- first-boot provisioning via VPS init user-data
- hardened SSH baseline (`AllowUsers`, no password auth, custom port)
- dedicated `COOLIFY_SUDO_NOPASSWD_USER` (default `coolify`) for non-root Coolify SSH operations
- UFW baseline + fail2ban + unattended upgrades
- optional `DOCKER-USER` guards for Coolify realtime ports (`6001/6002`) controlled by env
- deterministic env-driven render flow (Bash + PowerShell)
- post-bootstrap verification script (`scripts/verify-bootstrap-state.sh`)
- encrypted server-side user password vault
- explicit first-boot failure recovery runbook

## Documentation Map

- [Getting Started](getting-started.md)
- [Bootstrap Flow](bootstrap-flow.md)
- [Coolify Deployment Modes](coolify-deployment-modes.md)
- [Operations & Security](operations-security.md)
- [Failure Recovery Runbook](bootstrap-failure-recovery.md)
- [GitHub Promotion Checklist](github-promotion.md)

## Repository Layout

- `env/` env templates
- `bootstrap-artifacts/` local generated secrets and VPS-Coolify init output (not committed)
- `scripts/` bootstrap + helper scripts (Bash + PowerShell)
- `templates/` `vps-init.template.yml`
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
