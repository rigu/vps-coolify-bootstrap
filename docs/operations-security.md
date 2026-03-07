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
`bootstrap-host.sh` enforces this at runtime: every user in `SUDO_USERS`,
`DOCKER_USERS`, and `COOLIFY_GROUP_USERS` must also exist in `CREATE_USERS`,
and usernames must match `^[a-z_][a-z0-9_-]*[$]?$`.

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
Other required variables are omitted for brevity; keep required `CHANGE_ME`
values (domain, credentials, encryption password, SSH key) fully configured.

Important: extra users beyond the first two can SSH only after `bootstrap-host.sh`
completes successfully and re-syncs `AllowUsers` from `CREATE_USERS`.

### First-login password hardening

On the first SSH login as `PRIMARY_SUDO_USER`, set a local account password:

```bash
sudo passwd "$(whoami)"
```

`PRIMARY_SUDO_USER` has passwordless sudo for operations, but setting a local
password is still required for emergency/recovery flows (for example provider
console access when SSH key auth is unavailable).

### Password vault access

Generated user passwords are stored encrypted at
`/etc/vps-coolify-bootstrap/user-passwords.enc`. Decrypting requires `sudo`.

Only `PRIMARY_SUDO_USER` has passwordless sudo (`NOPASSWD:ALL`). All other
sudo users need their password to run `sudo` — but their password is inside
the vault. This is by design: `PRIMARY_SUDO_USER` is the operational
recovery account.

To retrieve passwords for other users, log in as `PRIMARY_SUDO_USER` and
decrypt:

```bash
export USER_PASSWORDS_ENCRYPTION_PASSWORD="<value-from-bootstrap.env>"
sudo openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in /etc/vps-coolify-bootstrap/user-passwords.enc \
  -pass env:USER_PASSWORDS_ENCRYPTION_PASSWORD
```

Alternative: use the provider web console as root.

## Post-onboarding security (required)

Docker-published ports can bypass UFW because Docker writes iptables rules directly.
Do not assume UFW alone blocks container `-p host:container` exposure.

Validate exposed ports:

```bash
sudo ss -tulpen
sudo docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

Pay special attention to Coolify internal ports `6001` and `6002`; they should not be public unless explicitly required.

Bootstrap default behavior:

- if `ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS=0` (default), bootstrap adds
  `DOCKER-USER` guard rules to block public ingress to `6001/6002`
- if `ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS=1`, bootstrap skips those guards

Check effective rules:

```bash
sudo iptables -S DOCKER-USER
sudo ip6tables -S DOCKER-USER 2>/dev/null || true
```

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

## Input validation rules

- `COOLIFY_ROOT_USERNAME` must match `^[A-Za-z0-9._-]+$`
- `COOLIFY_ROOT_USER_EMAIL` must be valid email format
- `COOLIFY_ROOT_USER_PASSWORD` and `USER_PASSWORDS_ENCRYPTION_PASSWORD` must be at least 16 characters
- `SSH_PORT` must be numeric in range `1-65535`
- usernames in user lists must match `^[a-z_][a-z0-9_-]*[$]?$` and must not contain `:`

Back to [Docs Home](index.md)
