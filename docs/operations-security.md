---
---

# Operations and Security

This page covers post-bootstrap operational tasks. Read the sections relevant to your
current task (user policy, replay, hardening, updates, monitoring).

## User and group policy

`env/bootstrap.env.example` now defines user policy by role:

- `DEVOPS_USER` (default `devops`)
- `COOLIFY_SUDO_NOPASSWD_USER` (default `coolify`)
- `ADDITIONAL_SUDO_USERS` (optional list; separators: space, comma, or semicolon)

Effective managed users are:
`DEVOPS_USER` + `COOLIFY_SUDO_NOPASSWD_USER` + `ADDITIONAL_SUDO_USERS`.

`bootstrap-host.sh` enforces this at runtime:
- each managed user is created if missing
- each managed user is added to `sudo`, `docker`, and `coolify`
- usernames must match `^[a-z_][a-z0-9_-]*[$]?$`
- `root` is forbidden for `DEVOPS_USER`, `COOLIFY_SUDO_NOPASSWD_USER`, and in `ADDITIONAL_SUDO_USERS`
- `DEVOPS_USER` and `COOLIFY_SUDO_NOPASSWD_USER` must be different
- `ADDITIONAL_SUDO_USERS` must not contain `COOLIFY_SUDO_NOPASSWD_USER`

### More than two sudo users

Example:

```env
DEVOPS_USER=devops
COOLIFY_SUDO_NOPASSWD_USER=coolify
ADDITIONAL_SUDO_USERS=admin ops;dev
```

Apply path depends on server lifecycle:
- for a new VPS not yet provisioned: re-render VPS-Coolify init and provision with the new file
- for an existing VPS already running: update server `/etc/vps-coolify-bootstrap/bootstrap.env` and replay bootstrap
Other required variables are omitted for brevity; keep required `CHANGE_ME`
values (domain, credentials, encryption password, SSH key) fully configured.

Important: users listed in `ADDITIONAL_SUDO_USERS` can SSH only after
`bootstrap-host.sh` completes successfully and re-syncs `AllowUsers` from the
effective managed user set.

### First-login password hardening

On the first SSH login as `DEVOPS_USER`, set a local account password:

```bash
sudo passwd <DEVOPS_USER>
```

Replace `<DEVOPS_USER>` with the value from `/etc/vps-coolify-bootstrap/bootstrap.env`.

`DEVOPS_USER` has passwordless sudo for operations, but setting a local
password is still required for emergency/recovery flows (for example provider
console access when SSH key auth is unavailable).

### Password vault access

Generated user passwords are stored encrypted at
`/etc/vps-coolify-bootstrap/user-passwords.enc`. Decrypting requires `sudo`.

`DEVOPS_USER` and `COOLIFY_SUDO_NOPASSWD_USER` have passwordless sudo
(`NOPASSWD:ALL`). Other sudo users need their password to run `sudo` — but
their password is inside the vault.

To retrieve passwords for other users, log in as `DEVOPS_USER` or
`COOLIFY_SUDO_NOPASSWD_USER` and
run this recommended sequence (reads the exact password from server
`bootstrap.env` and preserves it through `sudo`):

```bash
export USER_PASSWORDS_ENCRYPTION_PASSWORD="$(
  sudo sed -n "s/^USER_PASSWORDS_ENCRYPTION_PASSWORD=//p" /etc/vps-coolify-bootstrap/bootstrap.env | tr -d "'\r"
)"

sudo env USER_PASSWORDS_ENCRYPTION_PASSWORD="$USER_PASSWORDS_ENCRYPTION_PASSWORD" \
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in /etc/vps-coolify-bootstrap/user-passwords.enc \
  -pass env:USER_PASSWORDS_ENCRYPTION_PASSWORD
```

Alternative: use the provider web console as root.

### Using `coolify` as the managed SSH user

Set `COOLIFY_SUDO_NOPASSWD_USER=coolify` (default) in server-side
`/etc/vps-coolify-bootstrap/bootstrap.env`, then run replay:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

Bootstrap now syncs Coolify localhost server connection settings automatically:
- server host -> `host.docker.internal`
- server user -> `COOLIFY_SUDO_NOPASSWD_USER`
- server port -> `SSH_PORT`
- localhost private key -> `/data/coolify/ssh/keys/id.<COOLIFY_SUDO_NOPASSWD_USER>@host.docker.internal`
- `authorized_keys` entry for that key is restricted with `from="..."` to localhost/private ranges
- operator key (`SSH_PUBLIC_KEY`) is not kept for this user

If UI still shows drift, run replay again and verify with:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/verify-bootstrap-state.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

Validation command:

```bash
sudo -u coolify -H bash -lc 'sudo -n true && echo OK_NOPASSWD'
```

Temporary/manual override (when replay is not yet possible):

```bash
sudo tee /etc/sudoers.d/zz-coolify-nopasswd >/dev/null <<'EOF'
coolify ALL=(ALL:ALL) NOPASSWD:ALL
EOF
sudo chmod 440 /etc/sudoers.d/zz-coolify-nopasswd
sudo visudo -c
```

Why `zz-` prefix: bootstrap writes `/etc/sudoers.d/99-bootstrap-sudo-policy`.
Files loaded later can override prior sudo tag behavior (`PASSWD`/`NOPASSWD`).

## Bootstrap env reference

Use this section when you need detailed runtime behavior for `bootstrap.env`
variables beyond the quick reference in Getting Started.

### A) Auto-resolved on host

- `DEVOPS_USER`
  - When: bootstrap/replay runtime, before sudo policy is written
  - How: defaults to `devops` when unset
  - Required: NO
- `COOLIFY_SUDO_NOPASSWD_USER`
  - When: bootstrap/replay runtime
  - How: defaults to `coolify`; auto-added to managed user/group lists and passwordless sudo policy
  - Required: NO
- `SSH_KEY_ROTATE`
  - When: runtime during SSH key synchronization
  - How: applies to `DEVOPS_USER` + `ADDITIONAL_SUDO_USERS`; default `0` appends key, `1` replaces their `authorized_keys`; does not apply to `COOLIFY_SUDO_NOPASSWD_USER`
  - Required: NO
  - Example:
    - `SSH_KEY_ROTATE=0`: keep existing keys and ensure current `SSH_PUBLIC_KEY` is present for `DEVOPS_USER` + `ADDITIONAL_SUDO_USERS`
    - `SSH_KEY_ROTATE=1`: replace keys for `DEVOPS_USER` + `ADDITIONAL_SUDO_USERS` with current `SSH_PUBLIC_KEY` during replay/boot
- `CLOSE_COOLIFY_REALTIME_PORTS`
  - When: runtime during `DOCKER-USER` guard sync
  - How: default `false` keeps ports public; `true` adds guards to block public ingress to `6001/6002`
  - Required: NO

### B) Coolify admin variables

- `COOLIFY_PUBLIC_DOMAIN`
  - When: used by bootstrap output and onboarding flow
  - How: validated as hostname
  - Required: YES
- `COOLIFY_ROOT_USERNAME`
  - When: passed to Coolify installer
  - How: installer environment variable
  - Required: YES
- `COOLIFY_ROOT_USER_EMAIL`
  - When: passed to Coolify installer and used as login identifier
  - How: installer environment variable, email format validated
  - Required: YES
- `COOLIFY_ROOT_USER_PASSWORD`
  - When: local generation before provisioning if placeholder/empty
  - How: **AUTO-GENERATED** by `generate-secrets.*` only when value is empty/`CHANGE_ME` (24 chars with lowercase, uppercase, digit, and symbol)
  - Required: NO

### C) Server user variables

- `SSH_PUBLIC_KEY` / `SSH_PUBLIC_KEY_PATH`
  - When: local preparation step and host bootstrap key installation
  - How: **AUTO-DETECTED** if a valid key exists on your machine (`~/.ssh/*.pub`); `generate-secrets.*` fills `SSH_PUBLIC_KEY` and `SSH_PUBLIC_KEY_PATH` when placeholders are present
  - Required: NO for bootstrap execution; YES recommended for direct SSH key-based first access
- `COOLIFY_REALTIME_DOMAIN`
  - When: runtime when value is set
  - How: written as `PUSHER_HOST`, `PUSHER_PORT=443`, and `PUSHER_SCHEME=https` in `/data/coolify/source/.env` whenever value is set; when `CLOSE_COOLIFY_REALTIME_PORTS=true` and this value is empty, bootstrap falls back to `COOLIFY_PUBLIC_DOMAIN`
  - Required: NO (fallback exists via `COOLIFY_PUBLIC_DOMAIN` in closed mode)
- `SSH_PORT`
  - When: bootstrap/replay SSH hardening
  - How: applied via `sshd_config.d` and service restart
  - Required: NO
- `ADDITIONAL_SUDO_USERS`
  - When: runtime user/group reconciliation
  - How: optional list separated by space/comma/semicolon; each user is validated and merged into effective managed users
  - Required: NO unless team model differs
- `TIMEZONE`
  - When: early VPS init phase
  - How: applied as system timezone
  - Required: NO

### D) Generated passwords and secrets

- `USER_PASSWORDS_ENCRYPTION_PASSWORD`
  - When: local generation before provisioning if placeholder/empty
  - How: **AUTO-GENERATED** by `generate-secrets.*` only when value is empty/`CHANGE_ME` (`openssl rand -hex 16` in Bash)
  - Required: NO after secure generation
- account passwords for managed users (`DEVOPS_USER`, `COOLIFY_SUDO_NOPASSWD_USER`, `ADDITIONAL_SUDO_USERS`)
  - When: during bootstrap/replay runtime on the VPS host in `ensure-user-passwords.sh`
  - How: not pre-generated locally; password is generated only when account is locked/unset (`/etc/shadow` empty hash or prefixed `!`/`*`) or when vault has no entry for that user; unlocked accounts already present in vault are not rotated; then vault is encrypted to `/etc/vps-coolify-bootstrap/user-passwords.enc`
  - Required: YES for `DEVOPS_USER` on first login (`sudo passwd "$(whoami)"`)

## Replay bootstrap policy (idempotent)

Run:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

Use replay to re-apply baseline policy from server-side `bootstrap.env` without
reprovisioning.

When to run replay:

- after changing policy values (`SSH_PORT`, `DEVOPS_USER`, `COOLIFY_SUDO_NOPASSWD_USER`, `ADDITIONAL_SUDO_USERS`)
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
- sudo policy (`DEVOPS_USER` and `COOLIFY_SUDO_NOPASSWD_USER` passwordless by default)
- user/group memberships (`sudo`, `docker`, `coolify`)
- on-host password generation for locked/unset managed users (during bootstrap/replay) and encrypted vault update
- UFW baseline (`SSH_PORT`, `80`, `443`)
- `fail2ban` and `unattended-upgrades`
- Coolify localhost connection user/port/private-key synchronization (`COOLIFY_SUDO_NOPASSWD_USER`, `SSH_PORT`)
- realtime host env synchronization (`PUSHER_HOST`, `PUSHER_PORT`, `PUSHER_SCHEME`) from effective realtime domain (`COOLIFY_REALTIME_DOMAIN` or `COOLIFY_PUBLIC_DOMAIN` fallback)
- when `CLOSE_COOLIFY_REALTIME_PORTS=true`, enforces `DOCKER-USER` public-drop guards for `6001/6002`

Operational notes:

- run replay as `DEVOPS_USER`, `COOLIFY_SUDO_NOPASSWD_USER`, or root via provider console
- replay resets UFW baseline; re-apply custom rules after replay
- replay restarts SSH service; keep provider console open
- replay enforces single SSH port policy (`SSH_PORT` only): disables legacy `Port` directives and fails if `:22` still listens

Quick verification after replay:

```bash
sudo systemctl is-active ssh.service fail2ban unattended-upgrades
sudo ufw status verbose
sudo ss -lntp | grep -E ':(22|6001|6002|8000)\b' || true
sudo iptables -S DOCKER-USER | grep -E '6001|6002' || true
sudo bash /opt/vps-coolify-bootstrap/scripts/verify-bootstrap-state.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

UFW SSH policy detail:
- public SSH remains `LIMIT IN` on `SSH_PORT`
- bootstrap also adds explicit `ALLOW IN` rules to `SSH_PORT` for localhost/private ranges
  (`127.0.0.1`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`, `::1`, `fc00::/7`, `fe80::/10`)
- this prevents Coolify localhost validation traffic (from Docker bridge networks) from being rejected by SSH rate limiting

## Post-onboarding security (required)

Docker-published ports can bypass UFW because Docker writes iptables rules directly.
Do not assume UFW alone blocks container `-p host:container` exposure.

Validate exposed ports:

```bash
sudo ss -tulpen
sudo docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

Pay special attention to Coolify internal ports `8000`, `6001`, and `6002`.

Bootstrap behavior:

- if `CLOSE_COOLIFY_REALTIME_PORTS=true`, bootstrap adds `DOCKER-USER`
  guard rules to block public ingress to `6001/6002`
- if `CLOSE_COOLIFY_REALTIME_PORTS=false` (default), bootstrap removes only `6001/6002` guards
- if `COOLIFY_REALTIME_DOMAIN` is set, bootstrap always configures app-level
  realtime routing via `PUSHER_HOST=<domain>`, `PUSHER_PORT=443`,
  `PUSHER_SCHEME=https` (even when `CLOSE_COOLIFY_REALTIME_PORTS=false`)
- if `COOLIFY_REALTIME_DOMAIN` is empty and `CLOSE_COOLIFY_REALTIME_PORTS=true`,
  bootstrap configures app-level realtime routing using `COOLIFY_PUBLIC_DOMAIN`
- bootstrap does not force-close `8000`; official Coolify onboarding remains available on `http://<server-ip>:8000` until domain proxy is configured in UI

Operational interpretation:

- `CLOSE_COOLIFY_REALTIME_PORTS=false` + `COOLIFY_REALTIME_DOMAIN` set means
  "domain routing enabled, direct `6001/6002` still reachable".
- `CLOSE_COOLIFY_REALTIME_PORTS=true` means
  "domain routing enabled on effective realtime domain (`COOLIFY_REALTIME_DOMAIN`
  or `COOLIFY_PUBLIC_DOMAIN` fallback), direct public `6001/6002` blocked by
  `DOCKER-USER` guards".
- `8000` behavior follows official Coolify onboarding flow (initial access on `:8000`, domain/TLS after UI configuration).
- Domain routing on `443` is application-level behavior from `PUSHER_*`
  values, not an automatic host-level NAT redirect.

Fast mode-switch helper:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/update-realtime-mode.sh --mode public --clear-domain
sudo bash /opt/vps-coolify-bootstrap/scripts/update-realtime-mode.sh --mode closed --domain realtime.example.com
```

Detailed behavior and mode-by-mode guidance:
[VPS Coolify Realtime Modes](vps-coolify-realtime-modes.md)

`CLOSE_COOLIFY_REALTIME_PORTS=true` exact enforcement path:

1. Validation stage resolves effective realtime domain:
   - `COOLIFY_REALTIME_DOMAIN` when set
   - otherwise `COOLIFY_PUBLIC_DOMAIN`
2. Bootstrap writes realtime app endpoint in Coolify env:
   - `PUSHER_HOST=<effective_realtime_domain>`
   - `PUSHER_PORT=443`
   - `PUSHER_SCHEME=https`
3. Bootstrap restarts `coolify` and `coolify-realtime` containers if `PUSHER_*` values changed.
4. Bootstrap installs `DOCKER-USER` ingress guards to block public forwarded traffic to `6001/6002`.
5. Bootstrap keeps UFW `80/443` ALLOW baseline for domain-facing traffic.

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

### Coolify update runbook (recommended)

Use this procedure for every Coolify upgrade so hardening policy is re-applied
after the upstream installer changes files/containers.

Common drift after upgrade (important):
- domain drift: if `COOLIFY_PUBLIC_DOMAIN` (or `COOLIFY_REALTIME_DOMAIN`) was changed in Coolify UI but not in `/etc/vps-coolify-bootstrap/bootstrap.env`, replay can re-apply old domain-based realtime settings from env.
- firewall drift: manual Docker/firewall edits can remove or reorder `DOCKER-USER` rules for realtime ports (`6001/6002`), so closed mode may no longer be enforced.

Post-upgrade quick re-sync (recommended every time):

```bash
cd /opt/vps-coolify-bootstrap
sudo git pull --ff-only origin main
sudo bash scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
sudo bash scripts/verify-bootstrap-state.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

1. Keep provider console access open and connect by SSH.

   ```bash
   ssh -p <SSH_PORT> <DEVOPS_USER>@<SERVER_IP>
   ```

2. Create local backups for policy + Coolify env before upgrade.

   ```bash
   sudo cp /etc/vps-coolify-bootstrap/bootstrap.env /root/bootstrap.env.bak.$(date +%F-%H%M%S)
   sudo cp /data/coolify/source/.env /root/coolify.env.bak.$(date +%F-%H%M%S)
   ```

3. Pull latest bootstrap scripts (contains hardening/recovery fixes).

   ```bash
   cd /opt/vps-coolify-bootstrap
   sudo git pull --ff-only origin main
   ```

4. Run official Coolify upgrade.

   ```bash
   curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash
   ```

5. Re-apply bootstrap policy immediately after upgrade.

   ```bash
   sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
   ```

6. Validate runtime state.

   ```bash
   sudo bash /opt/vps-coolify-bootstrap/scripts/verify-bootstrap-state.sh /etc/vps-coolify-bootstrap/bootstrap.env
   sudo ss -lntp | grep -E ':(22|80|443|8000|6001|6002)\b' || true
   sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
   ```

7. If realtime is in closed mode, confirm domain-based routing and port guards.

   ```bash
   sudo grep -nE '^PUSHER_HOST=|^PUSHER_PORT=|^PUSHER_SCHEME=' /data/coolify/source/.env
   sudo iptables -S DOCKER-USER | grep -E '6001|6002' || true
   sudo ip6tables -S DOCKER-USER 2>/dev/null | grep -E '6001|6002' || true
   ```

Operational note:

- `COOLIFY_REALTIME_DOMAIN` can be the same as `COOLIFY_PUBLIC_DOMAIN`.
- replay after upgrade is mandatory if you rely on bootstrap hardening
  (`CLOSE_COOLIFY_REALTIME_PORTS=true`, SSH single-port policy, sudo policy).

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

- `COOLIFY_ROOT_USER_PASSWORD`: minimum 16 chars and must include lowercase, uppercase, digit, and symbol
- `bootstrap-artifacts/vps-coolify-init.generated.yml` contains secrets and must not be committed
- bootstrap replay resets UFW baseline each run
- `SSH_KEY_ROTATE=0` appends keys, `SSH_KEY_ROTATE=1` replaces keys

## Input validation rules

See [Getting Started](getting-started.md#1-prepare-env-values) for the
authoritative validation rules and required input format.

Back to [Docs Home](index.md)
