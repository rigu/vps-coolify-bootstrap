#!/usr/bin/env bash
set -euo pipefail

: "${POSTGRES_DOCMOST_DB:?POSTGRES_DOCMOST_DB is required}"
: "${POSTGRES_PLANE_DB:?POSTGRES_PLANE_DB is required}"
: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${POSTGRES_REPLICATION_USER:?POSTGRES_REPLICATION_USER is required}"
: "${POSTGRES_REPLICATION_PASSWORD:?POSTGRES_REPLICATION_PASSWORD is required}"

psql \
  -v ON_ERROR_STOP=1 \
  -v docmost_db="$POSTGRES_DOCMOST_DB" \
  -v plane_db="$POSTGRES_PLANE_DB" \
  -v repl_user="$POSTGRES_REPLICATION_USER" \
  -v repl_password="$POSTGRES_REPLICATION_PASSWORD" \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" <<'EOSQL'
SELECT format('CREATE DATABASE %I OWNER %I', :'docmost_db', current_user)
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'docmost_db')\gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'plane_db', current_user)
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'plane_db')\gexec
SELECT format(
  'DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = %L) THEN CREATE ROLE %I WITH LOGIN REPLICATION PASSWORD %L; ELSE ALTER ROLE %I WITH LOGIN REPLICATION PASSWORD %L REPLICATION; END IF; END $$;',
  :'repl_user',
  :'repl_user',
  :'repl_password',
  :'repl_user',
  :'repl_password'
)\gexec
EOSQL
