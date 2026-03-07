# VPS Coolify Bootstrap

[![CI](https://github.com/rigu/vps-coolify-bootstrap/actions/workflows/ci.yml/badge.svg)](https://github.com/rigu/vps-coolify-bootstrap/actions/workflows/ci.yml)
[![Pages](https://github.com/rigu/vps-coolify-bootstrap/actions/workflows/pages.yml/badge.svg)](https://github.com/rigu/vps-coolify-bootstrap/actions/workflows/pages.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Latest Release](https://img.shields.io/github/v/release/rigu/vps-coolify-bootstrap)](https://github.com/rigu/vps-coolify-bootstrap/releases)
[![Last Commit](https://img.shields.io/github/last-commit/rigu/vps-coolify-bootstrap)](https://github.com/rigu/vps-coolify-bootstrap/commits/main)

Production-ready **VPS bootstrap for Coolify on Ubuntu 24.04 LTS** with cloud-init, SSH hardening, UFW baseline, fail2ban, unattended upgrades, user password vault encryption, and replay-safe bootstrap scripts.

![Bootstrap Overview](docs/assets/bootstrap-overview.svg)

## Why this repo

- secure-by-default baseline for first boot
- reproducible cloud-init rendering from env templates
- Linux/macOS + PowerShell support for operators
- explicit recovery runbook for failed first boot
- public/generic templates with no private data

## Quick Start

1. Prepare env + secrets:
```bash
cp env/bootstrap.env.example env/bootstrap.env
bash scripts/generate-secrets.sh --env-file env/bootstrap.env
```
2. Generate cloud-init:
```bash
bash scripts/prepare-cloud-init.sh --env-file env/bootstrap.env --overwrite
```
3. Provision VPS using `cloud-init.generated.yml` as user-data.

## Documentation (GitHub Pages)

Canonical instructions were moved to GitHub Pages docs:

- Site: `https://rigu.github.io/vps-coolify-bootstrap/`
- Local source: [docs/index.md](docs/index.md)
- Getting started: [docs/getting-started.md](docs/getting-started.md)
- Bootstrap flow: [docs/bootstrap-flow.md](docs/bootstrap-flow.md)
- Operations and security: [docs/operations-security.md](docs/operations-security.md)
- Failure recovery: [docs/bootstrap-failure-recovery.md](docs/bootstrap-failure-recovery.md)
- GitHub promotion checklist: [docs/github-promotion.md](docs/github-promotion.md)

## Ubuntu Target

This bootstrap is adapted for **Ubuntu 24.04 LTS**.

## Disclaimer

These scripts and templates are provided for operational convenience and must be used at your own risk. You are solely responsible for validating configuration, security hardening, compliance, backups, and production suitability in your environment. The author and contributors are not liable for any direct, indirect, incidental, or consequential damages, data loss, downtime, security incidents, or other consequences resulting from use of this repository.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
