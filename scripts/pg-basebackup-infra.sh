#!/usr/bin/env bash
set -euo pipefail

umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
common_sh=""
for candidate in "$script_dir/common.sh" /usr/local/lib/vps-coolify-bootstrap/common.sh; do
  if [ -f "$candidate" ]; then
    common_sh="$candidate"
    break
  fi
done

if [ -z "$common_sh" ]; then
  echo "ERROR: common.sh helper not found for strict env loading." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$common_sh"

ENV_FILE="${ENV_FILE:-/srv/infra/production-infra.env}"
BASEBACKUP_DIR="${BASEBACKUP_DIR:-/srv/backups/postgres-pitr}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-}"

log_phase() {
  local phase="$1"
  shift
  printf '[%s] [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$phase" "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd docker
require_cmd find
require_cmd gzip

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: Env file not found: $ENV_FILE" >&2
  exit 1
fi

install -d -m 700 "$BASEBACKUP_DIR"

load_env_file_strict "$ENV_FILE"

POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-${POSTGRES_APPS_CONTAINER_NAME:-postgres-apps}}"
POSTGRES_ENABLE_WAL_ARCHIVE="${POSTGRES_ENABLE_WAL_ARCHIVE:-false}"

case "${POSTGRES_ENABLE_WAL_ARCHIVE,,}" in
  true|1|yes|on) ;;
  *)
    echo "ERROR: POSTGRES_ENABLE_WAL_ARCHIVE must be enabled before running pg_basebackup." >&2
    exit 1
    ;;
esac

required_vars=(
  POSTGRES_REPLICATION_USER
  POSTGRES_REPLICATION_PASSWORD
)

for var_name in "${required_vars[@]}"; do
  if [ -z "${!var_name:-}" ]; then
    echo "ERROR: Required variable is missing or empty: $var_name" >&2
    exit 1
  fi
done

if ! docker inspect "$POSTGRES_CONTAINER" >/dev/null 2>&1; then
  echo "ERROR: Postgres container not found: $POSTGRES_CONTAINER" >&2
  exit 1
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
label="postgres-apps-basebackup-${timestamp}"
workdir_in_container="/tmp/pg-basebackup-${timestamp}"
archive_file="${BASEBACKUP_DIR}/postgres-basebackup_${timestamp}.tar.gz"

cleanup() {
  docker exec "$POSTGRES_CONTAINER" rm -rf "$workdir_in_container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log_phase basebackup "Running pg_basebackup inside ${POSTGRES_CONTAINER}."
printf '%s\n' "$POSTGRES_REPLICATION_PASSWORD" | docker exec -i "$POSTGRES_CONTAINER" \
  sh -ec '
    IFS= read -r PGPASSWORD
    export PGPASSWORD
    rm -rf "$1"
    mkdir -p "$1"
    exec pg_basebackup -h 127.0.0.1 -U "$2" -D "$1" -Fp -X stream -c fast -l "$3"
  ' sh "$workdir_in_container" "$POSTGRES_REPLICATION_USER" "$label"

log_phase archive "Exporting base backup archive to ${archive_file}."
if ! docker exec "$POSTGRES_CONTAINER" tar -C /tmp -cpf - "$(basename "$workdir_in_container")" | gzip -1 > "$archive_file"; then
  rm -f "$archive_file"
  echo "ERROR: Failed to archive pg_basebackup output." >&2
  exit 1
fi

if [ ! -s "$archive_file" ]; then
  rm -f "$archive_file"
  echo "ERROR: Empty base backup archive produced." >&2
  exit 1
fi

log_phase prune "Pruning base backups older than ${RETENTION_DAYS} day(s)."
find "$BASEBACKUP_DIR" -type f -name 'postgres-basebackup_*.tar.gz' -mtime +"$RETENTION_DAYS" -delete

log_phase "done" "pg_basebackup archive finished successfully."
