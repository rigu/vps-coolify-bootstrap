---
---

# VPS Coolify Bootstrap

Production-ready public bootstrap for **Coolify on Ubuntu 24.04 LTS**.

## What this gives you

- first-boot provisioning via VPS init user-data
- hardened SSH baseline (`AllowUsers`, no password auth, custom port)
- dedicated `COOLIFY_SUDO_NOPASSWD_USER` (default `coolify`) for non-root Coolify SSH operations
- UFW baseline + fail2ban + unattended upgrades
- official Coolify access flow: onboarding on `http://<server-ip>:8000`, then domain/TLS on `80/443`; realtime `6001/6002` policy is controlled by env
- deterministic env-driven render flow (Bash + PowerShell)
- post-bootstrap verification script (`scripts/verify-bootstrap-state.sh`)
- emergency SSH recovery helper for provider console (`scripts/recover-ssh-access.sh`)
- encrypted server-side user password vault
- explicit first-boot failure recovery runbook

## Documentation Map

- Recommended implementation order:
  1. Bootstrap: [Getting Started](getting-started.md)
  2. Coolify onboarding: [Onboarding Troubleshooting](onboarding-troubleshooting.md)
  3. Internal service layer: [Create Infra Network](create-infra-network.md)
  4. Workload deployment: [Install Docmost on Coolify](install-docmost-on-coolify.md)
  5. Workload deployment: [Install Plane on Coolify](install-plane-on-coolify.md)

- [Getting Started](getting-started.md)
- [Onboarding Troubleshooting](onboarding-troubleshooting.md)
- [Create Infra Network](create-infra-network.md)
- [Install Docmost on Coolify](install-docmost-on-coolify.md)
- [Install Plane on Coolify](install-plane-on-coolify.md)
- [Script Workflow](scripts-workflow.md)
- [Bootstrap Env Reference](bootstrap-env-reference.md)
- [Bootstrap Flow](bootstrap-flow.md)
- [Plane Incident Prevention Notes](plane-community-v1.2.3-incident-prevention.md)
- [VPS Coolify Deployment Modes](vps-coolify-deployment-modes.md)
- [VPS Coolify Realtime Modes](vps-coolify-realtime-modes.md)
- [Operations & Security](operations-security.md)
- [Failure Recovery Runbook](bootstrap-failure-recovery.md)
- [GitHub Promotion Checklist](github-promotion.md)

## Repository Layout

- `env/` env templates (`bootstrap.env.example`, `infra.env.example`, `docmost-coolify.env.example`, `plane-coolify.env.example`)
- `bootstrap-artifacts/` local generated secrets and VPS-Coolify init output (not committed)
- `scripts/` bootstrap + helper scripts (Bash + PowerShell)
- `templates/` `vps-init.template.yml` + infra/Docmost/Plane compose templates
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
