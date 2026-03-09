---
---

# Install Plane on Coolify

This guide adds Plane as a workload on top of a VPS already bootstrapped with this repository.

Expected order before using this page:
1. Bootstrap server baseline
2. Complete Coolify onboarding
3. Create internal service layer (`infra`)
4. Install Plane

Scope:
- this repository bootstraps server baseline + Coolify
- this guide covers Plane deployment inside Coolify
- this guide uses a **Community-only baseline** (`v1.2.3 full-with-proxy`)

Version baseline used here:
- **Plane Community v1.2.3** (repository baseline)
- verify upstream before changing versions:
  - <https://github.com/makeplane/plane/releases/latest>
  - <https://developers.plane.so/self-hosting/editions-and-versions>
  - <https://developers.plane.so/self-hosting/methods/coolify>

Important:
- this repository intentionally keeps a **Community-only external-infra compose baseline**
- the provided compose profile is adapted from official Plane `v1.2.3` and
  intentionally disables bundled stateful services (`plane-db`, `plane-redis`,
  `plane-mq`, built-in `plane-minio`) to use shared infra services instead
- official Plane `setup.sh` installer currently uses `artifacts.plane.so/makeplane/*` image references
- this repository intentionally defaults to Docker Hub (`makeplane/*`) for better
  cross-environment pull reliability and simpler fallback behavior
- if your environment requires another registry mirror, set explicit
  `PLANE_*_IMAGE` overrides in Plane env values

## Files provided in this repository

- Compose template:
  - `templates/plane-coolify-compose.community.v1.2.3.full-with-proxy.yml`
- Env template:
  - `env/plane-coolify.env.example`
- Env secret generator scripts:
  - `scripts/generate-plane-secrets.sh`
  - `scripts/generate-plane-secrets.ps1`
- Compose renderer script:
  - `scripts/prepare-plane-compose.sh`
  - `scripts/prepare-plane-compose.ps1`
- Incident-prevention notes:
  - [Plane Incident Prevention Notes](plane-community-v1.2.3-incident-prevention.md)

## Prerequisites

- Coolify onboarding is complete and the dashboard is reachable on final HTTPS domain:
  - expected end-state: `https://<coolify-domain>`
  - `http://<server-ip>:8000` is only the temporary onboarding entrypoint
- local server validation passes in Coolify:
  - in `Servers -> localhost`, `Validate Server` / `Check Connection` returns success
  - this specifically means Coolify can SSH from container context to the host with the configured localhost server settings (`host`, `port`, `user`, private key)
  - no SSH/sudo errors (`Server is not reachable`, `Connection refused`, `sudo password is required`)
- shared services required by this Plane profile are running and reachable from the same Docker network:
  - `postgres-apps`
  - `valkey-apps`
  - `rabbitmq-plane`
  - `seaweedfs-plane`
  - if you changed infra container-name overrides, use your custom names instead
- ensure infra setup was executed from this repo scripts so SeaweedFS S3 bucket
  (`PLANE_S3_BUCKET`, default `plane-uploads`) is created before Plane deploy
- external Docker network `infra` exists, and shared services are attached to it
  (Plane services are attached during Step 5)

Before proceeding, if `infra` is missing, create it using:
- [Create Infra Network](create-infra-network.md)
- recommended path: generate infra env locally, copy it to VPS, then run server-side `setup-infra.sh --env-file ...`

## Local ownership: infra secrets vs Plane secrets

Recommended source of truth:
- infra secrets are generated locally in `bootstrap-artifacts/production-infra.env`
- Plane env is generated locally in `bootstrap-artifacts/plane.env`
- Plane env imports infra-dependent values from local infra env during generation

Infra -> Plane synced keys (automatic in `generate-plane-secrets.*`):
- `POSTGRES_APPS_USER` -> `POSTGRES_USER`
- `POSTGRES_APPS_PASSWORD` -> `POSTGRES_PASSWORD`
- `POSTGRES_PLANE_DB` -> `POSTGRES_DB`
- `POSTGRES_APPS_CONTAINER_NAME` -> `POSTGRES_HOST`
- `APPS_VALKEY_PASSWORD` -> `REDIS_PASSWORD`
- `VALKEY_APPS_CONTAINER_NAME` -> `REDIS_HOST`
- `PLANE_RABBITMQ_USER` -> `RABBITMQ_DEFAULT_USER`
- `PLANE_RABBITMQ_PASSWORD` -> `RABBITMQ_DEFAULT_PASS`
- `PLANE_RABBITMQ_VHOST` -> `RABBITMQ_VHOST` and `RABBITMQ_DEFAULT_VHOST`
- `RABBITMQ_PLANE_CONTAINER_NAME` -> `RABBITMQ_HOST`
- `PLANE_S3_ACCESS_KEY` -> `AWS_ACCESS_KEY_ID`
- `PLANE_S3_SECRET_KEY` -> `AWS_SECRET_ACCESS_KEY`
- `PLANE_S3_BUCKET` -> `AWS_S3_BUCKET_NAME` and `BUCKET_NAME`
- `SEAWEEDFS_PLANE_CONTAINER_NAME` -> `AWS_S3_ENDPOINT_URL` (`http://<container>:8333`)

Dependent URLs are regenerated when needed:
- `DATABASE_URL`
- `REDIS_URL`
- `AMQP_URL`

## 1) Generate Plane env secrets and passwords locally

Bash:

```bash
bash scripts/generate-plane-secrets.sh
```

PowerShell:

```powershell
pwsh -File scripts/generate-plane-secrets.ps1
```

Default output:
- `bootstrap-artifacts/plane.env`

Default infra source:
- `bootstrap-artifacts/production-infra.env`

If infra env does not exist yet:
- `generate-plane-secrets.*` still succeeds and creates/updates `bootstrap-artifacts/plane.env`
- script warns that infra sync is skipped (missing infra env file)
- local Plane secrets/passwords are generated, and dependent URLs are built from current Plane values
- after infra env is created, rerun `generate-plane-secrets.*` so infra-derived values are synchronized

Rerun commands after infra env is ready:

Linux/macOS (Bash):

```bash
bash scripts/generate-plane-secrets.sh
```

Windows (PowerShell):

```powershell
pwsh -File scripts/generate-plane-secrets.ps1
```

Optional explicit infra source path:
- Bash: `--infra-env-file path/to/production-infra.env`
- PowerShell: `-InfraEnvFile path/to/production-infra.env`

Disable infra sync only for special cases:
- Bash: `--no-infra-sync`
- PowerShell: `-NoInfraSync`

Optional force rotation:
- passwords only: `--force-passwords` / `-ForcePasswords`
- secrets only: `--force-secrets` / `-ForceSecrets`
- all generated values: `--force-all` / `-ForceAll`

Optional custom path:
- Bash: `--env-file path/to/plane.env`
- PowerShell: `-EnvFile path/to/plane.env`

Notes:
- generated values are non-destructive by default
- infra-sourced Plane credentials are kept as infra values (they are not rotated by Plane generator force flags)
- dependent URLs are synchronized when needed:
  - `DATABASE_URL`
  - `REDIS_URL`
  - `AMQP_URL`

## 2) Create Plane resource in Coolify

Optional: render compose with values from `bootstrap-artifacts/plane.env` first:

```bash
bash scripts/prepare-plane-compose.sh
```

```powershell
pwsh -File scripts/prepare-plane-compose.ps1
```

Default rendered output:
- `bootstrap-artifacts/plane-coolify-compose.community.v1.2.3.full-with-proxy.yml`

Rendered behavior:
- output keeps `${VAR}` expressions so Coolify detects environment variables in UI
- defaults are rewritten from `plane.env` (for example `${SECRET_KEY:-<value-from-plane.env>}`)

1. Open `Projects -> <project> -> <environment>`.
2. Create a new `Docker Compose` resource.
3. Use a clear name (for example `plane` or `projects`).
4. Paste the full content of one of:
   - rendered file: `bootstrap-artifacts/plane-coolify-compose.community.v1.2.3.full-with-proxy.yml` (recommended after running renderer)
   - raw template: `templates/plane-coolify-compose.community.v1.2.3.full-with-proxy.yml`
5. Save compose.

## 3) Configure Plane environment values

1. Open env variables for the Plane resource.
2. Start from `bootstrap-artifacts/plane.env` (generated in Step 1), or from `env/plane-coolify.env.example`.
3. Replace all remaining `CHANGE_ME_*` values before first deploy.
4. Save env values.

Critical required values before deploy:
- `SECRET_KEY`
- `DATABASE_URL`
- `REDIS_URL`
- `RABBITMQ_DEFAULT_PASS`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_S3_ENDPOINT_URL` (internal SeaweedFS endpoint, e.g. `http://seaweedfs-plane:8333`)
- `SILO_HMAC_SECRET_KEY`
- `LIVE_SERVER_SECRET_KEY`

## 4) Configure public domain routing

Use Plane `proxy` service as public entrypoint.

Recommended mapping:
- `https://projects.example.com` -> service `proxy` -> port `80`

Keep these services internal-only (no direct public domain):
- `web`, `api`, `space`, `admin`, `live`, `worker`, `beat-worker`, `migrator`

## 5) Attach Plane services to `infra` network

If UI exposes predefined network setting:
- enable predefined network
- set network name to `infra`
- redeploy

If UI does not expose it, keep compose network block as provided:

```yaml
networks:
  infra:
    external: true
    name: infra
```

## 6) Deploy and verify

Deploy resource in Coolify, then verify:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'proxy|web|api|worker|plane-minio'
```

Health checks to run:

```bash
curl -sSI https://projects.example.com/
curl -sSI https://projects.example.com/api/instances/
curl -i -X OPTIONS https://projects.example.com/auth/email-check/
```

## 7) Upgrade and rollback (safe path)

Recommended approach:
1. Keep compose unchanged.
2. Change only version env values.
3. Redeploy.
4. Rollback by restoring previous version values and redeploy.

Primary switch:
- `PLANE_APP_VERSION`

Optional explicit image pins (set all together when used):
- `PLANE_PROXY_IMAGE`
- `PLANE_WEB_IMAGE`
- `PLANE_BACKEND_IMAGE`
- `PLANE_SPACE_IMAGE`
- `PLANE_ADMIN_IMAGE`
- `PLANE_LIVE_IMAGE`

Before upgrade:
- take verified DB backup
- keep previous env snapshot and image tag snapshot

Community upgrade policy:
1. Keep the compose file unchanged.
2. Change only `PLANE_APP_VERSION` (and optional explicit `PLANE_*_IMAGE` pins).
3. Redeploy once.
4. If anything fails, rollback by restoring previous version variables and redeploy.

## 8) Common failure signals

- `Mixed Content` on uploads
- `502` on `/plane-uploads`
- `504` on root/API paths
- public routing to wrong service (not `proxy`)

Use:
- [Plane Incident Prevention Notes](plane-community-v1.2.3-incident-prevention.md)
- [Onboarding Troubleshooting](onboarding-troubleshooting.md)

Back to [Docs Home](index.md)
