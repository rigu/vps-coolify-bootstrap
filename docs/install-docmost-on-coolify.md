---
---

# Install Docmost on Coolify

This guide adds Docmost as a workload on top of a VPS already bootstrapped with this repository.

Expected order before using this page:
1. Bootstrap server baseline
2. Complete Coolify onboarding
3. Create internal service layer (`infra`)
4. Install Docmost

Scope:
- this repository bootstraps server baseline + Coolify
- this guide covers Docmost deployment inside Coolify
- this guide uses shared infra services for Postgres and Valkey (Redis protocol)

## Files provided in this repository

- Compose template:
  - `templates/docmost-coolify-compose.community.template.yml`
- Env template:
  - `env/docmost-coolify.env.example`
- Env generator scripts:
  - `scripts/generate-docmost-secrets.sh`
  - `scripts/generate-docmost-secrets.ps1`
- Compose renderer scripts:
  - `scripts/prepare-docmost-compose.sh`
  - `scripts/prepare-docmost-compose.ps1`

## Prerequisites

- Coolify onboarding is complete and the dashboard is reachable on final HTTPS domain:
  - expected end-state: `https://<coolify-domain>`
  - `http://<server-ip>:8000` is only the temporary onboarding entrypoint
- local server validation passes in Coolify (`Servers -> localhost`)
- internal service layer is running and reachable:
  - `postgres-apps`
  - `valkey-apps`
- external Docker network `infra` exists

If infra is not ready, create it first:
- [Create Infra Network](create-infra-network.md)

## Local ownership: infra secrets vs Docmost secrets

Recommended source of truth:
- infra secrets are generated locally in `bootstrap-artifacts/production-infra.env`
- Docmost env is generated locally in `bootstrap-artifacts/docmost.env`
- Docmost generator syncs infra-dependent values from local infra env

Infra -> Docmost synced keys (automatic in `generate-docmost-secrets.*`):
- `POSTGRES_APPS_USER` -> `DATABASE_URL` user
- `POSTGRES_APPS_PASSWORD` -> `DATABASE_URL` password
- `POSTGRES_DOCMOST_DB` -> `DATABASE_URL` database
- `POSTGRES_APPS_CONTAINER_NAME` -> `DATABASE_URL` host
- `APPS_VALKEY_PASSWORD` -> `REDIS_URL` password
- `VALKEY_APPS_CONTAINER_NAME` -> `REDIS_URL` host
- `INFRA_NETWORK_NAME` -> `INFRA_NETWORK_NAME`
- `MAIL_DRIVER`, `SMTP_*`, `MAIL_FROM_*` -> same keys in Docmost env (when present in infra env)
- `DRAWIO_URL` -> `DRAWIO_URL`
- `PLANE_S3_ACCESS_KEY` -> `AWS_S3_ACCESS_KEY_ID`
- `PLANE_S3_SECRET_KEY` -> `AWS_S3_SECRET_ACCESS_KEY`
- `PLANE_S3_BUCKET` -> `AWS_S3_BUCKET`
- `SEAWEEDFS_PLANE_CONTAINER_NAME` -> `AWS_S3_ENDPOINT` (`http://<container>:8333`)
- `AWS_S3_REGION`, `AWS_S3_ENDPOINT`, `AWS_S3_FORCE_PATH_STYLE` -> same keys in Docmost env (when present in infra env)
- `DISABLE_TELEMETRY` -> `DISABLE_TELEMETRY`
- `FILE_UPLOAD_SIZE_LIMIT`, `FILE_IMPORT_SIZE_LIMIT` -> same keys in Docmost env (when present in infra env)

## 1) Generate Docmost env locally

Bash:

```bash
bash scripts/generate-docmost-secrets.sh
```

PowerShell:

```powershell
pwsh -File scripts/generate-docmost-secrets.ps1
```

Default output:
- `bootstrap-artifacts/docmost.env`

Default infra source:
- `bootstrap-artifacts/production-infra.env`

If infra env does not exist yet:
- `generate-docmost-secrets.*` still succeeds and creates `bootstrap-artifacts/docmost.env`
- script warns that infra sync is skipped
- after infra env is created, rerun the Docmost generator so infra-derived values are synchronized (`DATABASE_URL`, `REDIS_URL`, SMTP/MAIL, DRAWIO, AWS_S3_*, DISABLE_TELEMETRY, FILE_*_SIZE_LIMIT`)

Rerun after infra env is ready:

Linux/macOS (Bash):

```bash
bash scripts/generate-docmost-secrets.sh
```

Windows (PowerShell):

```powershell
pwsh -File scripts/generate-docmost-secrets.ps1
```

Optional flags:
- custom env path:
  - Bash: `--env-file path/to/docmost.env`
  - PowerShell: `-EnvFile path/to/docmost.env`
- custom infra env path:
  - Bash: `--infra-env-file path/to/production-infra.env`
  - PowerShell: `-InfraEnvFile path/to/production-infra.env`
- disable infra sync (advanced/testing):
  - Bash: `--no-infra-sync`
  - PowerShell: `-NoInfraSync`
- rotate app secret:
  - Bash: `--force-app-secret`
  - PowerShell: `-ForceAppSecret`

## 2) Render Docmost compose from env

Bash:

```bash
bash scripts/prepare-docmost-compose.sh
```

PowerShell:

```powershell
pwsh -File scripts/prepare-docmost-compose.ps1
```

Default rendered output:
- `bootstrap-artifacts/docmost-coolify-compose.community.yml`

Rendered behavior:
- output keeps `${VAR}` expressions so Coolify detects environment variables in UI
- defaults are rewritten from `docmost.env` (for example `${APP_SECRET:-<value-from-docmost.env>}`)

## 3) Create Docmost resource in Coolify

1. Open `Projects -> <project> -> <environment>`.
2. Create a new `Docker Compose` resource.
3. Use a clear name (for example `docmost` or `wiki`).
4. Paste the full content of one of:
   - rendered file: `bootstrap-artifacts/docmost-coolify-compose.community.yml` (recommended)
   - raw template: `templates/docmost-coolify-compose.community.template.yml`
5. Save compose.
6. Keep the built-in healthcheck enabled (`/api/health`) for reliable restarts in production.

## 4) Configure Docmost env values in Coolify

1. Open env variables for the Docmost resource.
2. Start from `bootstrap-artifacts/docmost.env`.
3. Replace remaining `CHANGE_ME_*` values if any are still present.
4. Save env values.

Mandatory before first deploy:
- `APP_URL`
- `APP_SECRET`
- `DATABASE_URL`
- `REDIS_URL`
- `FILE_UPLOAD_SIZE_LIMIT` (recommended default: `50mb`)
- `FILE_IMPORT_SIZE_LIMIT` (recommended default: `200mb`)

## 5) Configure public domain routing

Map your Docmost domain to service `docmost`, port `3000`.

Recommended mapping:
- `https://docs.example.com` -> service `docmost` -> port `3000`

## 6) Deploy and verify

Deploy resource in Coolify, then verify:

```bash
curl -sSI https://docs.example.com/
curl -sSI https://docs.example.com/login
```

Container-level checks on VPS:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -i docmost
docker logs --tail 120 <docmost-container-name>
docker inspect --format '{{json .State.Health}}' <docmost-container-name>
```

## 7) Upgrade and rollback

Safe path:
1. Keep compose structure unchanged.
2. Change only `DOCMOST_IMAGE` tag in env values.
3. Redeploy.
4. Roll back by restoring previous tag and redeploy.

Default repository baseline uses:
- `DOCMOST_IMAGE=docmost/docmost:latest`

Pin to a fixed tag in production if you need deterministic upgrades.
