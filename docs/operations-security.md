---
layout: page
title: Operations and Security
description: Production operations guidance for post-bootstrap hardening, monitoring, and Coolify-safe server operation.
---

# Operations and Security

## User and group policy

`env/bootstrap.env.example` policy lists:

- `CREATE_USERS`
- `SUDO_USERS`
- `DOCKER_USERS`
- `COOLIFY_GROUP_USERS`

Default values: `deploy,coolify`

Bootstrap also uses:

- `PRIMARY_SUDO_USER`
- `SECONDARY_SUDO_USER`

Keep both aligned with policy lists.

### More than 2 sudo users

Example:

```env
PRIMARY_SUDO_USER=deploy
SECONDARY_SUDO_USER=coolify
CREATE_USERS=deploy,coolify,admin,ops,dev
SUDO_USERS=deploy,coolify,admin,ops,dev
DOCKER_USERS=deploy,coolify,ops
COOLIFY_GROUP_USERS=deploy,coolify,ops
```

Re-render cloud-init or replay bootstrap to apply.

Important: extra users beyond the first two can SSH only after `bootstrap-host.sh`
completes successfully and re-syncs `AllowUsers` from `CREATE_USERS`.

## Post-onboarding security (required)

Docker-published ports can bypass UFW because Docker writes iptables rules directly.
Do not assume UFW alone blocks container `-p host:container` exposure.

Validate exposed ports:

```bash
sudo ss -tulpen
sudo docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

Pay special attention to Coolify internal ports `6001` and `6002`; they should not be public unless explicitly required.

Mitigation options:

- explicit `DOCKER-USER` chain rules
- `ufw-docker` policy management
- Docker `"iptables": false` only if equivalent firewall rules are fully managed

## Traefik security headers

For production apps behind Coolify/Traefik, apply at least:

- `Strict-Transport-Security`
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options` (or CSP `frame-ancestors`)
- `Referrer-Policy`
- `Content-Security-Policy` (app-specific)

## Coolify update strategy

For production:

- disable auto-updates in Coolify
- schedule upgrades in maintenance windows
- validate backup + rollback before upgrade

## Monitoring minimum baseline

- disk usage + inode alerts
- memory pressure / OOM events
- container health + restart loops
- TLS expiry checks
- backup success verification

## Logging and retention

Configure Docker log retention (`max-size`, `max-file`) and verify host logrotate.

## Known operational notes

- minimum `COOLIFY_ROOT_USER_PASSWORD` length: 16
- `cloud-init.generated.yml` contains secrets and must not be committed
- bootstrap replay resets UFW baseline each run
- `SSH_KEY_ROTATE=0` appends keys, `SSH_KEY_ROTATE=1` replaces keys

Back to [Docs Home](index.md)
