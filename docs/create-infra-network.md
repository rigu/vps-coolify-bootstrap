---
title: Create Infra Network
nav_order: 4
---

# Create Infra Network

Use this page to prepare the **internal service layer** used by application workloads (for example Plane).

Place in flow:
1. Bootstrap
2. Coolify onboarding
3. Create infra (this page)
4. Install Plane

## What is the internal service layer

The internal service layer is the private dependency layer on the VPS.

It usually contains shared services such as:
- `postgres-apps`
- `valkey-apps`
- `rabbitmq-plane`
- `seaweedfs-plane`

Application workloads (for example Plane) attach to the same Docker network and consume those services by container name.

## Critical separation rule

Keep Coolify internals separate from app shared services:
- Coolify internal DB/cache (`coolify-db`, `coolify-redis`) remain for Coolify itself
- app workloads must use their own shared services on `infra`
- do not point Plane `DATABASE_URL` to Coolify internal Postgres

## Port conflict note (important)

On a fresh VPS created with this bootstrap, infra default host ports are designed to avoid
conflicts with Coolify internal services.

Why this is safe by default:
- Coolify internal containers (`coolify-db`, `coolify-redis`) typically do not publish host ports
- infra services publish explicit host ports (localhost-only binds)

When conflicts can still happen:
- another host service already listens on the same port
- another compose stack already publishes the same host port

Quick check before infra deploy:

```bash
sudo ss -lntp | grep -E ':(5434|6379|5672|15672|8333)\b' || true
```

If any port is already in use, change the corresponding `*_HOST_PORT` value in
`production-infra.env`, then rerun `setup-infra.sh`.

## Precondition

Before preparing internal services:
- Coolify onboarding is finished
- final access works on `https://<coolify-domain>`
- server validation in Coolify is green

## Recommended (automatic) setup: env-only copy, server-side render/deploy

This repository now recommends this flow:
1. Generate only `production-infra.env` locally.
2. Copy only that env file to the VPS.
3. Run `setup-infra.sh` on VPS to generate compose/config files and deploy.

### Local machine (generate infra env only)

Linux/macOS (Bash):

```bash
bash scripts/generate-infra-secrets.sh
```

Windows (PowerShell):

```powershell
pwsh -File scripts/generate-infra-secrets.ps1
```

### Copy env to VPS

Linux/macOS:

```bash
scp -P <SSH_PORT> bootstrap-artifacts/production-infra.env <DEVOPS_USER>@<server-ip>:/tmp/production-infra.env
```

Windows (PowerShell):

```powershell
scp -P <SSH_PORT> .\bootstrap-artifacts\production-infra.env <DEVOPS_USER>@<server-ip>:/tmp/production-infra.env
```

Note:
- `scp` uses `-P` (uppercase) for port
- `ssh` uses `-p` (lowercase) for port
- use your configured admin account for `<DEVOPS_USER>` (default: `devops`)

### VPS apply (generate/render/deploy on server)

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/setup-infra.sh \
  --env-file /tmp/production-infra.env
```

Then run standalone validation:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/verify-infra-state.sh \
  --env-file /srv/infra/production-infra.env
```

Rerun pattern after first successful apply (no re-copy needed):

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/setup-infra.sh \
  --env-file /srv/infra/production-infra.env
```

`setup-infra.sh` now supports using the runtime env path directly and will not fail
when source and target env file are the same file.

What this command does on VPS:
- reads the copied infra env (`production-infra.env`)
- generates/refreshes missing infra secrets only when placeholders are still present
- renders infra compose/config files on VPS
- creates infra Docker network if missing
- syncs runtime files to `/srv/infra` with secure permissions
- runs `docker compose up -d`
- validates container health, network attachment, and localhost-only port exposure

Optional PostgreSQL PITR note:
- `env/infra.env.example` includes optional WAL/PITR toggles for
  `postgres-apps`
- keep `POSTGRES_ENABLE_WAL_ARCHIVE=false` unless you also operate base
  backups and off-site WAL retention
- when WAL archiving is enabled, `setup-infra.sh` also prepares the
  runtime WAL archive directory and `verify-infra-state.sh` validates the
  required PostgreSQL settings

### Automatic setup outputs and runtime state

After a successful `setup-infra.sh` run, this is the expected result.

Files used/generated on VPS repository workspace:
- `<repo>/bootstrap-artifacts/production-infra.env` (when default path is used)
- `<repo>/bootstrap-artifacts/infra/docker-compose.yml`
- `<repo>/bootstrap-artifacts/infra/production-infra.env`
- `<repo>/bootstrap-artifacts/infra/valkey.conf`
- `<repo>/bootstrap-artifacts/infra/seaweedfs-s3-config.json`
- `<repo>/bootstrap-artifacts/infra/postgres-apps-init.sh`

Files created/synced on VPS runtime path:
- `/srv/infra/docker-compose.yml`
- `/srv/infra/production-infra.env`
- `/srv/infra/valkey.conf`
- `/srv/infra/seaweedfs-s3-config.json`
- `/srv/infra/postgres-apps-init.sh`
- `/srv/infra/postgres-wal-archive/` (directory, when WAL archiving is enabled)

Runtime objects created/ensured:
- Docker network: `infra` (or custom value from `INFRA_NETWORK_NAME`)
- Infra containers started by compose:
  - `postgres-apps` (or `POSTGRES_APPS_CONTAINER_NAME`)
  - `valkey-apps` (or `VALKEY_APPS_CONTAINER_NAME`)
  - `rabbitmq-plane` (or `RABBITMQ_PLANE_CONTAINER_NAME`)
  - `seaweedfs-plane` (or `SEAWEEDFS_PLANE_CONTAINER_NAME`)

Host exposure policy applied by compose:
- infra service ports are bound to loopback only (`127.0.0.1:<port>:...`)
- they are not intended for public internet access

Validation executed by `setup-infra.sh`:
- network exists and containers are attached to it
- each infra container is running and reaches healthy/ready state
- expected host ports are listening and not publicly bound
- when WAL archiving is enabled: `archive_mode=on`, `wal_level=replica`,
  and the replication role exists

## Manual mode (advanced/custom)

Use manual steps below only if you need custom flow or troubleshooting details.

### 1) Create Docker network `infra`

Idempotent create command:

```bash
sudo docker network inspect infra >/dev/null 2>&1 || sudo docker network create infra
```

Verify metadata:

```bash
sudo docker network inspect infra --format 'name={{.Name}} driver={{.Driver}} scope={{.Scope}}'
```

Expected:
- `name=infra`
- `driver=bridge`
- `scope=local`

### 2) Prepare host folder for internal stack (recommended)

If you run a dedicated shared-services compose stack, keep it under `/srv/infra`:

```bash
sudo install -d -m 750 -o root -g root /srv/infra
```

Recommended runtime files:
- `/srv/infra/docker-compose.yml`
- `/srv/infra/production-infra.env`
- service-specific config files (for example Valkey/SeaweedFS config)

Recommended permissions:
- env files with secrets: `600`
- service runtime configs mounted read-only into containers: `644`
- compose and non-secret configs: `644`

Example:

```bash
sudo chown root:root /srv/infra/*
sudo chmod 600 /srv/infra/production-infra.env
sudo chmod 644 /srv/infra/valkey.conf /srv/infra/seaweedfs-s3-config.json
```

### 3) Generate infra env locally (only env), then copy to server

Use repository templates and generators:

Linux/macOS (Bash):

```bash
# generate or refresh secrets/passwords
bash scripts/generate-infra-secrets.sh
```

Windows (PowerShell):

```powershell
# generate or refresh secrets/passwords
pwsh -File scripts/generate-infra-secrets.ps1
```

Default local output:
- `bootstrap-artifacts/production-infra.env`

Copy it to VPS:

Linux/macOS:

```bash
scp -P <SSH_PORT> bootstrap-artifacts/production-infra.env <DEVOPS_USER>@<server-ip>:/tmp/production-infra.env
```

Windows (PowerShell):

```powershell
scp -P <SSH_PORT> .\bootstrap-artifacts\production-infra.env <DEVOPS_USER>@<server-ip>:/tmp/production-infra.env
```

Then run server-side generation/render/deploy:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/setup-infra.sh --env-file /tmp/production-infra.env
```

Then validate resulting infra state:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/verify-infra-state.sh --env-file /srv/infra/production-infra.env
```

### 4) Start internal services on `infra`

If your internal stack compose file is ready:

```bash
cd /srv/infra
sudo docker compose --env-file ./production-infra.env up -d
```

### 5) Verify services are attached to `infra`

```bash
sudo docker network inspect infra --format '{{range .Containers}}{{.Name}} {{end}}'
```

You should see shared service containers and application containers that need them.

### 6) Verify internal-only exposure policy

Internal service ports should not be opened publicly in UFW.

Check UFW:

```bash
sudo ufw status numbered
```

Check listening sockets:

```bash
sudo ss -lntp
```

Guideline:
- shared dependency ports must stay internal-only unless there is an explicit operational requirement
- public ingress should go through your reverse-proxy/domain path, not direct DB/queue/cache ports

### 7) Plane-specific connectivity expectations

For Plane profile using this repository:
- Plane compose references shared services by hostnames on `infra`
- Plane resource must be attached to external network `infra`
- public domain should route to Plane `proxy` service (port `80` in compose)

If deployment fails with message that `infra` is missing:
1. create/verify `infra` as above
2. ensure Plane compose has external network block:

```yaml
networks:
  infra:
    external: true
    name: infra
```

3. redeploy resource

## Troubleshooting: `valkey-apps` unhealthy with `valkey.conf` permission denied

Symptom:
- `verify-infra-state.sh` reports `valkey-apps` unhealthy
- container logs show `Fatal error, can't open config file '/etc/valkey/valkey.conf': Permission denied`

Fix on VPS:

```bash
sudo chmod 644 /srv/infra/valkey.conf
sudo docker compose -f /srv/infra/docker-compose.yml --env-file /srv/infra/production-infra.env up -d valkey-apps
sudo bash /opt/vps-coolify-bootstrap/scripts/verify-infra-state.sh --env-file /srv/infra/production-infra.env
```

Permanent fix:
- updated `setup-infra.sh` now installs `valkey.conf` and `seaweedfs-s3-config.json` with `644` so non-root container users can read mounted configs.
- updated `setup-infra.sh` also ensures the SeaweedFS S3 bucket from `PLANE_S3_BUCKET`
  (default `plane-uploads`) exists after deploy.

## Quick checklist

Run these commands and verify all pass:

```bash
sudo docker network inspect infra >/dev/null
sudo docker network inspect infra --format '{{range .Containers}}{{.Name}} {{end}}'
sudo ufw status
```

Back to [Install Plane on Coolify](install-plane-on-coolify.md)
