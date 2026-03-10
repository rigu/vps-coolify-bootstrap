---
title: Maintenance Runbook
nav_order: 8
---

# Maintenance Runbook

Use this page as a generic production maintenance checklist for a
Coolify VPS.

## Daily checks

Verify:

- public endpoints return expected status codes
- required containers are running and healthy
- backup jobs succeeded recently
- off-site replication succeeded recently
- disk usage is within safe limits

Typical checks:

```bash
sudo docker ps --format 'table {{.Names}}\t{{.Status}}'
df -h /
sudo docker system df
```

## Weekly checks

Verify:

- backup logs are clean
- no unexpected public listeners exist
- TLS/domain routing still matches intended public entry points
- recent changes did not bypass the firewall model

## Monthly checks

Run at least one restore test:

- PostgreSQL dump restore into a temporary database
- file/object archive extraction test
- config inventory check

## Upgrade workflow

For host, Coolify, infra, or workload updates:

1. take fresh backups
2. create a provider snapshot when the change is material
3. apply the update in a maintenance window
4. run post-update validation

Post-update validation should cover:

- container health
- public endpoints
- application login/critical paths
- backup timers/services

## Production rules

- keep bootstrap policy env as the source of truth
- prefer deterministic replay/automation over ad hoc manual fixes
- avoid uncontrolled auto-updates in production
- close legacy/bootstrap ports when onboarding is complete

## What should be documented privately

Each production environment should keep a private runbook with:

- exact backup destinations
- exact restore procedure
- exact RPO/RTO targets
- contact/escalation path
- scheduled maintenance window

Back to [Docs Home](index.md)
