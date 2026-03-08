---
---

# VPS Coolify Deployment Modes

This page describes all deployment modes for Coolify that are supported by this bootstrap repository.

Scope note:
- bootstrap deploys and reconciles the Coolify control-plane on the VPS
- bootstrap does not deploy your application workloads from Git repositories

## Mode 1) First-boot automatic deployment (recommended)

Use when:
- you are creating a new VPS
- your provider supports user-data input (VPS init format)

How it is triggered:
1. Render `bootstrap-artifacts/vps-coolify-init.generated.yml`.
2. Paste it in provider `User data` during VPS creation.
3. On first boot, VPS init runs `scripts/bootstrap-host.sh`.

What bootstrap does:
- installs system baseline (SSH hardening, UFW, fail2ban, unattended upgrades)
- installs Coolify if not running
- configures Coolify bootstrap admin credentials
- syncs local Coolify server connection (id `0`) to:
  - host `host.docker.internal`
  - user `COOLIFY_SUDO_NOPASSWD_USER`
  - port `SSH_PORT`
  - managed localhost private key
- applies realtime policy from env (`CLOSE_COOLIFY_REALTIME_PORTS` + effective realtime domain from `COOLIFY_REALTIME_DOMAIN` or `COOLIFY_PUBLIC_DOMAIN`)

## Mode 2) Manual deployment on existing VPS (no user-data field)

Use when:
- provider UI/API does not support user-data
- you already have VPS console/root access

How it is triggered:
1. Copy local `bootstrap-artifacts/bootstrap.env` to `/etc/vps-coolify-bootstrap/bootstrap.env` on server.
2. Clone repo to `/opt/vps-coolify-bootstrap`.
3. Run:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

Behavior:
- same functional result as first-boot mode
- idempotent and safe to rerun after fixes

## Mode 3) Idempotent replay (reconciliation mode)

Use when:
- policy changed (`SSH_PORT`, users, realtime settings, etc.)
- onboarding/UI drift appeared
- previous run was partial

How it is triggered:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

What replay does:
- re-applies host baseline and security policy
- repairs users/groups/sudo policy
- regenerates passwords only for locked/unset accounts
- resyncs local Coolify server user/key/port
- resyncs realtime env and `DOCKER-USER` guards

What replay does not do:
- does not deploy app workloads
- does not remove Docker volumes/databases
- does not rotate already-set unlocked user passwords

## Mode 4) Recovery deployment after failed first boot

Use when:
- first-boot init/bootstrap failed
- server is in partially configured state

How it is triggered:
- follow [Bootstrap Failure Recovery](bootstrap-failure-recovery.md)
- authoritative recovery step is replay (same command as Mode 3)

Key point:
- recovery mode is not a separate script; it is a guided procedure around replay + diagnostics

## Mode 5) Clean rebuild deployment (reprovision)

Use when:
- host is inconsistent and repair is too risky/time-consuming

How it is triggered:
1. Regenerate env + init file locally.
2. Recreate VPS.
3. Apply generated user-data at VPS creation.

Reference:
- [Bootstrap Failure Recovery](bootstrap-failure-recovery.md#10-clean-rebuild-path-last-resort)

## Realtime/network deployment variants

These are runtime exposure variants controlled by env:

For deep behavior, risks, graphs, and update commands, see:
[VPS Coolify Realtime Modes](vps-coolify-realtime-modes.md).

1. Public realtime ports, no dedicated host (default)
   - `CLOSE_COOLIFY_REALTIME_PORTS=false`
   - `COOLIFY_REALTIME_DOMAIN` empty
   - `6001/6002` can remain externally reachable via Docker publish rules
   - bootstrap removes `PUSHER_HOST`, `PUSHER_PORT`, `PUSHER_SCHEME`

2. Public realtime ports, dedicated realtime domain
   - `CLOSE_COOLIFY_REALTIME_PORTS=false`
   - `COOLIFY_REALTIME_DOMAIN` set
   - bootstrap sets `PUSHER_HOST`, `PUSHER_PORT=443`, `PUSHER_SCHEME=https`
   - app/browser realtime is directed to dedicated domain over `443`
   - direct public `6001/6002` may still be reachable

3. Closed realtime ports (dedicated host optional)
   - `CLOSE_COOLIFY_REALTIME_PORTS=true`
   - bootstrap sets `PUSHER_HOST`, `PUSHER_PORT=443`, `PUSHER_SCHEME=https`
   - realtime host source:
     - `COOLIFY_REALTIME_DOMAIN` when set
     - otherwise `COOLIFY_PUBLIC_DOMAIN` fallback
   - bootstrap enforces `DOCKER-USER` guards:
     - blocks public ingress to `6001/6002` in closed mode
   - routing to `443` is app-level via `PUSHER_*`; direct public `6001/6002` is blocked by guards

## Access result

Bootstrap follows official Coolify access flow:
- initial onboarding on `http://<server-ip>:8000`
- final domain/TLS access on `https://<COOLIFY_PUBLIC_DOMAIN>` after onboarding

## Verify deployment state

Run after any mode:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/verify-bootstrap-state.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

This validates:
- SSH service/socket state and port listeners
- UFW baseline
- user/group/sudo policy
- Coolify localhost server mapping (user/ip/port/key)
- realtime env sync and guard policy

Back to [Docs Home](index.md)
