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
7. Coolify resource showed `Running (unhealthy)` even though Plane was serving traffic
   - `plane-admin` healthcheck failed with `/bin/sh: node: not found`
8. Coolify resource showed `Running (unknown)` for the Plane stack
   - `plane-minio` had no healthcheck, so Coolify could not confirm readiness

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
- Attaching the public entrypoint and other frontend-only services to the shared
  `infra` network increased multi-network ingress ambiguity.

Applied solution:
- Keep internal Plane `proxy` service in compose.
- Public Coolify domain must target only Plane `proxy` on port `80`.
- Keep other Plane services internal-only.
- Keep `proxy`, `web`, `space`, and `admin` on the stack-local default
  network only.

Why this works:
- Plane's own route map for `/api`, `/auth`, and `/<bucket>` stays authoritative.
- Reduces path-based routing mistakes and avoids ambiguous ingress paths on
  multi-network Coolify installs.

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
- Services that require shared dependencies must reach the external `infra`
  network, but not every Plane service needs that attachment.
- Over-attaching frontend/public services to `infra` widened the network surface
  without providing any dependency benefit.

Applied solution:
- Keep only infra-dependent services attached to:
  - `default`
  - `infra`
- Keep frontend/public services attached to:
  - `default`
- Infra-dependent services in this template:
  - `plane-minio`
  - `api`
  - `worker`
  - `beat-worker`
  - `live`
  - `migrator`
- Default-only services in this template:
  - `proxy`
  - `web`
  - `space`
  - `admin`
- `networks.infra` is declared as external network.

Why this works:
- Guarantees name resolution/reachability for `postgres-apps`, `valkey-apps`,
  `rabbitmq-plane`, and `seaweedfs-plane`.
- Keeps the public ingress path deterministic while still exposing shared
  infra only to the services that need it.

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

### 7) False `unhealthy` state on `plane-admin`
Root cause:
- The original `plane-admin` healthcheck executed `node -e ...`.
- The deployed `makeplane/plane-admin:v1.2.3` image did not include `node`.

Applied solution:
- Replace the healthcheck with an HTTP probe against the local admin UI
  (`/god-mode/`) and a simple process fallback when HTTP tooling is absent.

Why this works:
- Health status now reflects actual admin container readiness instead of a
  missing binary in the image.
- Prevents Coolify from blocking routing or showing a false red state for an
  otherwise functional stack.

### 8) `plane-minio` showed `Running (unknown)` in Coolify
Root cause:
- The TCP forwarder service was running, but it had no explicit healthcheck.
- Coolify could not classify the service as healthy, so the overall resource
  state could remain `unknown`.

Applied solution:
- Add a TCP healthcheck using `nc -z 127.0.0.1 9000`.

Why this works:
- Confirms the local forwarder socket is accepting connections before Coolify
  marks the service healthy.
- Improves deployment visibility without changing Plane's upload topology.

## What Changed for v1.2.3

The new file is a controlled evolution of the known-good incident-prevention
compose topology:

- Version pins moved to `v1.2.3`
- Architecture preserved intentionally:
  - internal Plane proxy retained
  - `plane-minio` forwarder retained
  - shared infra dependencies retained
  - storage-proxy hardening retained
  - selective `infra` attachment retained
  - compatible healthchecks for `plane-admin` and `plane-minio` added

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
   - `plane-admin` and `plane-minio` report healthy state in Coolify/Docker
4. Keep rollback simple:
   - revert only `PLANE_APP_VERSION` / explicit image pins
   - redeploy
