---
title: Plane Incident Prevention
nav_order: 17
---

# Plane v1.2.3 for Coolify: Incident Prevention Notes

## Scope
This document explains why the new compose file
`templates/plane-coolify-compose.community.v1.2.3.full-with-proxy.yml`
was designed the way it is for the current deployment architecture:

- Coolify-managed public ingress (Traefik)
- Shared infra services on the external Docker network `infra`
- SeaweedFS (`seaweedfs-plane`) as S3-compatible object storage
- Plane Community deployment behind Plane's internal proxy service

The goal is to prevent the exact failures previously observed in production.

Version policy used here:

- use Plane Community tag track (`v1.2.3`)
- acknowledge that Plane official `setup.sh` output commonly uses
  `artifacts.plane.so/makeplane/*` for Community images
- use Docker Hub `makeplane/*` image defaults in this repository baseline
  for higher pull reliability in mixed environments
- avoid commercial/enterprise-only image defaults in this baseline

## Incidents Observed

1. Browser mixed-content errors during asset upload:
   - HTTPS app requested `http://seaweedfs-plane:8333/plane-uploads`
2. `502 Bad Gateway` on `POST /plane-uploads`
3. `504 Gateway Timeout` on app root or API routes
4. Traefik router parse failures with rule pattern:
   - `Host(\`\`) && PathPrefix(...)`
5. Intermittent `connect: connection refused` from Plane proxy to API
6. Frontend runtime error after redeploy (`Minified React error #418`)

## Root Causes and Applied Solutions

### 1) Mixed Content on upload endpoints
Root cause:
- Storage URLs were generated toward internal HTTP SeaweedFS endpoint.
- Browser blocked HTTP requests from an HTTPS page.

Applied solution:
- Force Plane storage-proxy mode and request-based HTTPS semantics:
  - `USE_STORAGE_PROXY=1`
  - `USE_MINIO=1`
  - `MINIO_ENDPOINT_SSL=1`
  - `AWS_S3_ENDPOINT_URL=http://seaweedfs-plane:8333`
- Keep bucket names aligned:
  - `AWS_S3_BUCKET_NAME=plane-uploads`
  - `BUCKET_NAME=plane-uploads`

Why this works:
- Plane backend uses internal S3 endpoint for bucket checks/startup tasks.
- Browser upload/download URLs stay HTTPS because Plane derives endpoint from
  incoming request host when `USE_MINIO=1` and `MINIO_ENDPOINT_SSL=1`.
- Plane proxy handles storage routing internally.

### 2) 502 on `/plane-uploads`
Root cause:
- Plane proxy expected upstream `plane-minio:9000` while only `seaweedfs-plane:8333` existed.
- DNS resolution for `plane-minio` failed inside proxy container.

Applied solution:
- Keep a lightweight TCP forwarder service named `plane-minio`:
  - `plane-minio:9000 -> seaweedfs-plane:8333`
- Keep Plane proxy service enabled and dependent on `plane-minio`.

Why this works:
- It preserves Plane proxy's expected upstream name without modifying upstream image behavior.
- Upload path remains stable across redeploys.

### 3) 504/route instability from incorrect public routing
Root cause:
- Public domain/routing was not consistently terminated at Plane `proxy` service.
- In some attempts, web/api direct routing caused auth/API/storage path mismatches.

Applied solution:
- Keep internal Plane `proxy` service in compose.
- Public Coolify domain must target only Plane `proxy` on port `80`.
- Keep other Plane services internal-only.

Why this works:
- Plane's own route map for `/api`, `/auth`, and `/<bucket>` stays authoritative.
- Reduces path-based routing mistakes in Coolify.

### 4) Traefik rule `Host(\`\`)` parse errors
Root cause:
- Malformed/auto-generated service URL values produced empty host matcher.

Applied solution:
- Do not manually edit generated `SERVICE_URL_*` variables.
- Use domain/public access UI as source of truth.
- If env fallback is needed, use only valid FQDN variables (`SERVICE_FQDN_*`).

Why this works:
- Prevents invalid Traefik label generation and restores deterministic router rules.

### 5) Service discovery failures to shared dependencies
Root cause:
- Containers not consistently attached to shared external network `infra`.

Applied solution:
- All Plane services in compose are attached to:
  - `default`
  - `infra`
- `networks.infra` is declared as external network.

Why this works:
- Guarantees name resolution/reachability for `postgres-apps`, `valkey-apps`,
  `rabbitmq-plane`, and `seaweedfs-plane`.

### 6) AMQP credential mismatch risk
Root cause:
- Multiple variable conventions across compose variants (default user/pass naming).

Applied solution:
- Keep RabbitMQ variables aligned with known-working deployment model:
  - `RABBITMQ_DEFAULT_USER`
  - `RABBITMQ_DEFAULT_PASS`
  - `RABBITMQ_DEFAULT_VHOST`
  - `RABBITMQ_VHOST`
- Keep a simple, explicit AMQP default URL (no nested interpolation).

Why this works:
- Avoids hidden interpolation failures and queue-connection regressions.

## What Changed for v1.2.3

The new file is a controlled evolution of the known-good incident-prevention
compose topology:

- Version pins moved to `v1.2.3`
- Architecture preserved intentionally:
  - internal Plane proxy retained
  - `plane-minio` forwarder retained
  - shared infra dependencies retained
  - storage-proxy hardening retained

This was chosen over a topology redesign because the redesign paths were the
main source of prior incidents.

## File Produced

- `templates/plane-coolify-compose.community.v1.2.3.full-with-proxy.yml`

## Operational Recommendations

1. Route `projects.example.com` to Plane `proxy` service only.
2. Keep `SERVICE_URL_*` untouched; rely on domain UI / valid `SERVICE_FQDN_*`.
3. After each redeploy, verify:
   - API route health
   - auth preflight
   - one upload test through `/plane-uploads`
4. Keep rollback simple:
   - revert only `PLANE_APP_VERSION` / explicit image pins
   - redeploy
