---
layout: page
title: Operations and Security
description: Production operations guidance for post-bootstrap hardening, monitoring, and Coolify-safe server operation.
---

# Operations and Security

This page covers post-bootstrap operational tasks. Read the sections relevant to your
current task (user policy, replay, hardening, updates, monitoring).

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

### More than two sudo users

Example:

```env
PRIMARY_SUDO_USER=deploy
SECONDARY_SUDO_USER=coolify
CREATE_USERS=deploy,coolify,admin,ops,dev
SUDO_USERS=deploy,coolify,admin,ops,dev
DOCKER_USERS=deploy,coolify,ops
COOLIFY_GROUP_USERS=deploy,coolify,ops
```

Re-render the VPS-Coolify init file or replay bootstrap to apply changes.
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

## Bootstrap env reference

Use this section when you need detailed runtime behavior for `bootstrap.env`
variables beyond the quick reference in Getting Started.

### A) Auto-resolved on host

- `PRIMARY_SUDO_USER`
  - When: bootstrap/replay runtime, before sudo policy is written
  - How: if empty, resolved from first `SUDO_USERS` entry; fallback `deploy`
  - Must change: NO
- `SSH_KEY_ROTATE`
  - When: runtime during SSH key synchronization
  - How: default `0` appends key; `1` replaces `authorized_keys`
  - Must change: NO
- `ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS`
  - When: runtime during `DOCKER-USER` guard application
  - How: default `0` blocks public ingress to `6001/6002`; `1` skips guards
  - Must change: NO

### B) Coolify admin variables

- `COOLIFY_PUBLIC_DOMAIN`
  - When: used by bootstrap output and onboarding flow
  - How: validated as hostname
  - Must change: YES
- `COOLIFY_ROOT_USERNAME`
  - When: passed to Coolify installer
  - How: installer environment variable
  - Must change: YES
- `COOLIFY_ROOT_USER_EMAIL`
  - When: passed to Coolify installer and used as login identifier
  - How: installer environment variable, email format validated
  - Must change: YES
- `COOLIFY_ROOT_USER_PASSWORD`
  - When: local generation before provisioning if placeholder/empty
  - How: **AUTO-GENERATED** by `generate-secrets.*` only when value is empty/`CHANGE_ME` (`openssl rand -hex 12` in Bash)
  - Must change: NO

### C) Server user variables

- `SSH_PUBLIC_KEY` / `SSH_PUBLIC_KEY_PATH`
  - When: local preparation step and host bootstrap key installation
  - How: **AUTO-DETECTED** if a valid key exists on your machine (`~/.ssh/*.pub`); `generate-secrets.*` fills both `SSH_PUBLIC_KEY` and `SSH_PUBLIC_KEY_PATH` when placeholders are present
  - Must change: YES (valid key required)
- `SSH_PORT`
  - When: bootstrap/replay SSH hardening
  - How: applied via `sshd_config.d` and service restart
  - Must change: NO
- `SECONDARY_SUDO_USER`, `CREATE_USERS`, `SUDO_USERS`, `DOCKER_USERS`, `COOLIFY_GROUP_USERS`
  - When: runtime user/group reconciliation
  - How: validated subsets and applied memberships/policy
  - Must change: NO unless team model differs
- `TIMEZONE`
  - When: early cloud-init
  - How: applied as system timezone
  - Must change: NO

### D) Generated passwords and secrets

- `USER_PASSWORDS_ENCRYPTION_PASSWORD`
  - When: local generation before provisioning if placeholder/empty
  - How: **AUTO-GENERATED** by `generate-secrets.*` only when value is empty/`CHANGE_ME` (`openssl rand -hex 16` in Bash)
  - Must change: NO after secure generation
- account passwords for users in `CREATE_USERS`
  - When: during bootstrap/replay runtime on the VPS host in `ensure-user-passwords.sh`
  - How: not pre-generated locally; set only for locked/unset accounts, then encrypted to `/etc/vps-coolify-bootstrap/user-passwords.enc`
  - Must change: YES for `PRIMARY_SUDO_USER` on first login (`sudo passwd "$(whoami)"`)

## Replay bootstrap policy (idempotent)

Run:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

Use replay to re-apply baseline policy from server-side `bootstrap.env` without
reprovisioning.

When to run replay:

- after changing policy values (`SSH_PORT`, users, sudo/group lists)
- after partial first-boot execution
- after emergency manual fixes that may have introduced drift
- after updating bootstrap scripts and wanting to apply new safeguards

What replay does not do:

- it does not deploy application workloads
- it does not remove Docker volumes/databases
- it does not replace SSH keys unless `SSH_KEY_ROTATE=1`
- it does not rotate already-set (unlocked) account passwords; it only sets passwords for locked/unset accounts
- it does not pre-generate server user account passwords locally before bootstrap

What replay enforces:

- SSH hardening (`sshd_config`, `AllowUsers`, service state)
- sudo policy (`PRIMARY_SUDO_USER` passwordless by default)
- user/group memberships (`sudo`, `docker`, `coolify`)
- on-host password generation for locked/unset users in `CREATE_USERS` (during bootstrap/replay) and encrypted vault update
- UFW baseline (`SSH_PORT`, `80`, `443`)
- `fail2ban` and `unattended-upgrades`
- `DOCKER-USER` guards for `6001/6002` unless `ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS=1`

Operational notes:

- run replay as `PRIMARY_SUDO_USER` or root via provider console
- replay resets UFW baseline; re-apply custom rules after replay
- replay restarts SSH service; keep provider console open
- replay can terminate stale `sshd` listeners on `22` when `SSH_PORT` is not `22`

Quick verification after replay:

```bash
sudo systemctl is-active ssh.service fail2ban unattended-upgrades
sudo ufw status verbose
sudo ss -lntp | grep -E ':(22|6001|6002|8000)\b' || true
sudo iptables -S DOCKER-USER | grep -E '6001|6002' || true
```

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

Reference:
- <https://doc.traefik.io/traefik-hub/api-gateway/secure/middleware/headers>

## Coolify update strategy

For production:

- disable auto-updates in Coolify
- schedule upgrades in maintenance windows
- validate backup and rollback plans before upgrade

References:
- <https://coolify.io/docs/knowledge-base/server/auto-update>
- <https://coolify.io/docs/knowledge-base/server/upgrade>

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
- `bootstrap-artifacts/vps-coolify-init.generated.yml` contains secrets and must not be committed
- bootstrap replay resets UFW baseline each run
- `SSH_KEY_ROTATE=0` appends keys, `SSH_KEY_ROTATE=1` replaces keys

## Input validation rules

See [Getting Started](getting-started.md#1-prepare-env-values) for the
authoritative validation rules and required input format.

Back to [Docs Home](index.md)
