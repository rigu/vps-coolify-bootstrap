---
title: Backup Strategy
nav_order: 7
---

# Backup Strategy

Use this page to design a production backup plan for a VPS that runs:

- Coolify as the control plane
- an internal service layer (`infra`)
- application workloads such as Plane or Docmost

This repository does not ship a one-size-fits-all production backup
implementation, because real retention, destinations, encryption, and
compliance rules are environment-specific. It does define the backup
layers you should cover and the minimum restore capabilities you should
validate.

## 1) Backup layers

Treat production backup as multiple independent layers.

### Layer A: PostgreSQL data

Recommended production baseline:

- daily logical dumps for each application database
- base backup + WAL archiving when low-RPO recovery matters

Why both:

- logical dumps are simple to inspect and restore into another instance
- WAL + base backup supports point-in-time recovery for the whole cluster

For single-VPS stacks, logical dumps are the minimum acceptable baseline.
If the VPS stores active business data, add WAL archiving.

## Layer B: Object and file storage

Back up application file/object data separately from PostgreSQL.

Examples:

- SeaweedFS data directory
- application-local upload directories
- S3-compatible bucket data when the bucket is hosted on the same VPS

Do not assume database backups cover uploads or attachments.

### Layer C: Coolify control plane

Coolify has its own backup/restore flow for the platform state.

Use it for:

- Coolify database and platform state
- control-plane recovery

Do not treat it as a replacement for workload data backups.

### Layer D: Host and config state

Back up the files required to rebuild the machine correctly:

- `/etc/vps-coolify-bootstrap/bootstrap.env`
- `/srv/infra/production-infra.env`
- runtime configs generated from those env files when they contain
  non-regenerable secrets
- backup scripts, restore notes, and service units
- any rclone/restic destination config kept on-host

### Layer E: Provider disaster recovery

Provider backups/snapshots are useful for fast disaster recovery, but
they are not your only backup layer.

Use them for:

- quick full-host rollback
- pre-upgrade safety snapshots

Do not rely on them alone for application-level restore.

## 2) Recommended production pattern

For a typical single-VPS Coolify deployment:

1. run daily logical Postgres dumps
2. run at least daily object/file archive jobs
3. replicate backup artifacts off-site
4. enable provider backups/snapshots
5. test restore paths regularly

If you need low RPO for PostgreSQL, add WAL archiving and periodic base
backups on top of the daily logical dumps.

Repository note:
- this public repo now includes optional PostgreSQL WAL/PITR scaffolding
  in `env/infra.env.example`, `setup-infra.sh`, and
  `verify-infra-state.sh`
- that scaffolding only prepares the infra layer; operators still need a
  private/basebackup job, retention policy, and off-site WAL replication

## 3) Retention

Pick a retention policy intentionally.

Reasonable baseline:

- daily backups: 14-30 days
- weekly backups: 8-12 weeks
- monthly backups: 6-12 months

Keep retention policy documented next to the backup job implementation.

## 4) Off-site replication

Local-only backups are not sufficient for production.

Your off-site target should support:

- encrypted transport
- access control separate from the VPS
- object versioning or immutable retention when available

Common patterns:

- S3-compatible object storage
- `restic` to object storage or SFTP
- `rclone copy` for archive replication

## 5) Restore testing

Backups are not production-ready until restore is tested.

Minimum restore checks:

- restore one recent Postgres dump into a temporary database
- verify at least one object/file archive can be extracted
- verify Coolify control-plane backup is current and documented
- verify config/secrets needed for rebuild are available

Recommended cadence:

- lightweight restore check monthly
- full recovery drill quarterly

## 6) Maintenance baseline

Production maintenance should include:

- daily health checks for containers and public endpoints
- backup freshness checks
- disk-space checks
- controlled update windows for Coolify, host packages, and workloads
- pre-upgrade backup and post-upgrade validation

Recommended operational rule:

- disable or avoid uncontrolled auto-update flows in production
- take a fresh backup before every significant upgrade

## 7) Scope split: public vs private repo

Keep the split clean:

- public repo:
  - generic backup strategy
  - generic maintenance guidance
  - reusable helper scripts or examples
- private repo:
  - real destinations
  - retention values
  - provider choices
  - credentials and restore notes for a specific environment

## Primary sources

- PostgreSQL backup and restore:
  <https://www.postgresql.org/docs/current/backup.html>
- PostgreSQL continuous archiving / PITR:
  <https://www.postgresql.org/docs/current/continuous-archiving.html>
- Coolify backup / restore:
  <https://coolify.io/docs/knowledge-base/how-to/backup-restore-coolify>
- Coolify upgrade guidance:
  <https://coolify.io/docs/get-started/upgrade>
- Coolify firewall guidance:
  <https://coolify.io/docs/knowledge-base/server/firewall>
- Hetzner backups and snapshots:
  <https://docs.hetzner.com/cloud/servers/backups-snapshots/overview/>
- Docmost self-hosting configuration:
  <https://docmost.com/docs/self-hosting/configuration/>

Back to [Docs Home](index.md)
