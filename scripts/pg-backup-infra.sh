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
BACKUP_DIR="${BACKUP_DIR:-/srv/backups/postgres}"
OBJECT_BACKUP_DIR="${OBJECT_BACKUP_DIR:-/srv/backups/object-storage}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
DOCMOST_CONTAINER="${DOCMOST_CONTAINER:-}"
STRICT_DOCMOST_BACKUP="${STRICT_DOCMOST_BACKUP:-0}"
SEAWEEDFS_CONTAINER="${SEAWEEDFS_CONTAINER:-}"
FREEZE_SEAWEEDFS_DURING_BACKUP="${FREEZE_SEAWEEDFS_DURING_BACKUP:-1}"
FREEZE_DOCMOST_DURING_BACKUP="${FREEZE_DOCMOST_DURING_BACKUP:-1}"
INCLUDE_POSTGRES_APPS_DB_BACKUP="${INCLUDE_POSTGRES_APPS_DB_BACKUP:-0}"
SEAWEEDFS_CONFIG_FILE="${SEAWEEDFS_CONFIG_FILE:-/srv/infra/seaweedfs-s3-config.json}"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_failures=0

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
require_cmd sort

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: Env file not found: $ENV_FILE" >&2
  exit 1
fi

install -d -m 700 "$BACKUP_DIR" "$OBJECT_BACKUP_DIR"

load_env_file_strict "$ENV_FILE"

POSTGRES_CONTAINER="${POSTGRES_APPS_CONTAINER_NAME:-postgres-apps}"
SEAWEEDFS_CONTAINER="${SEAWEEDFS_CONTAINER:-${SEAWEEDFS_PLANE_CONTAINER_NAME:-seaweedfs-plane}}"

required_vars=(
  POSTGRES_APPS_USER
  POSTGRES_APPS_PASSWORD
  POSTGRES_PLANE_DB
  POSTGRES_DOCMOST_DB
)

for var_name in "${required_vars[@]}"; do
  if [ -z "${!var_name:-}" ]; then
    echo "ERROR: Required variable is missing or empty: $var_name" >&2
    exit 1
  fi
done

container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

sanitize_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

trim() {
  local value="$1"
  echo "$value" | xargs
}

run_with_optional_pause() {
  local container_name="$1"
  local freeze_enabled="$2"
  shift 2

  local paused=0
  local rc=0

  if [ "$freeze_enabled" = "1" ]; then
    log_phase archive "Pausing container ${container_name}."
    docker pause "$container_name" >/dev/null
    paused=1
  fi

  if "$@"; then
    rc=0
  else
    rc=$?
  fi

  if [ "$paused" = "1" ]; then
    log_phase archive "Unpausing container ${container_name}."
    docker unpause "$container_name" >/dev/null || true
  fi

  return "$rc"
}

collect_app_databases() {
  local raw_list="${APP_DATABASES:-}"
  if [ -n "$raw_list" ]; then
    printf '%s' "$raw_list" | tr ',;' '\n' | while IFS= read -r db; do
      db="$(trim "$db")"
      [ -n "$db" ] && printf '%s\n' "$db"
    done
  else
    printf '%s\n' "$POSTGRES_PLANE_DB"
    printf '%s\n' "$POSTGRES_DOCMOST_DB"
  fi

  if [ "$INCLUDE_POSTGRES_APPS_DB_BACKUP" = "1" ] && [ -n "${POSTGRES_APPS_DB:-}" ]; then
    printf '%s\n' "$POSTGRES_APPS_DB"
  fi
}

mapfile -t app_databases < <(collect_app_databases | sort -u)

dump_postgres_db() {
  local db_name="$1"
  local safe_db_name
  local output_file

  safe_db_name="$(sanitize_name "$db_name")"
  output_file="${BACKUP_DIR}/postgres_${safe_db_name}_${timestamp}.dump"

  log_phase dump "Dumping Postgres database ${db_name} from ${POSTGRES_CONTAINER}."
  if ! printf '%s\n' "$POSTGRES_APPS_PASSWORD" | docker exec -i "$POSTGRES_CONTAINER" \
    sh -ec 'IFS= read -r PGPASSWORD; export PGPASSWORD; pg_dump -U "$1" -d "$2" --format=custom --no-owner --no-privileges' \
      sh "$POSTGRES_APPS_USER" "$db_name" \
    > "$output_file"; then
    rm -f "$output_file"
    echo "ERROR: pg_dump failed for ${db_name}" >&2
    return 1
  fi

  if [ ! -s "$output_file" ]; then
    rm -f "$output_file"
    echo "ERROR: Empty dump produced for ${db_name}" >&2
    return 1
  fi

  log_phase dump "Verifying dump integrity for ${db_name}."
  if ! docker exec -i "$POSTGRES_CONTAINER" pg_restore -l < "$output_file" >/dev/null 2>&1; then
    rm -f "$output_file"
    echo "ERROR: Dump integrity check failed for ${db_name}" >&2
    return 1
  fi
}

archive_seaweedfs_data() {
  local output_file="${OBJECT_BACKUP_DIR}/seaweedfs-data_${timestamp}.tar.gz"

  log_phase archive "Archiving SeaweedFS data from ${SEAWEEDFS_CONTAINER}."
  if ! docker cp "${SEAWEEDFS_CONTAINER}:/data" - | gzip -1 > "$output_file"; then
    rm -f "$output_file"
    echo "ERROR: SeaweedFS archive failed." >&2
    return 1
  fi

  if [ ! -s "$output_file" ]; then
    rm -f "$output_file"
    echo "ERROR: Empty SeaweedFS archive produced." >&2
    return 1
  fi
}

backup_seaweedfs_config() {
  local output_file="${OBJECT_BACKUP_DIR}/seaweedfs-s3-config_${timestamp}.json"

  if [ ! -f "$SEAWEEDFS_CONFIG_FILE" ]; then
    echo "ERROR: SeaweedFS config file not found: $SEAWEEDFS_CONFIG_FILE" >&2
    return 1
  fi

  log_phase archive "Copying SeaweedFS config ${SEAWEEDFS_CONFIG_FILE}."
  cp "$SEAWEEDFS_CONFIG_FILE" "$output_file"
  chmod 600 "$output_file"
}

detect_docmost_container() {
  if [ -n "$DOCMOST_CONTAINER" ]; then
    printf '%s\n' "$DOCMOST_CONTAINER"
    return 0
  fi

  local detected
  detected="$(docker ps --filter 'label=coolify.serviceName=docmost' --format '{{.Names}}' | head -n 1)"
  if [ -n "$detected" ]; then
    printf '%s\n' "$detected"
    return 0
  fi

  detected="$(docker ps --filter 'label=coolify.name=docmost' --format '{{.Names}}' | head -n 1)"
  if [ -n "$detected" ]; then
    printf '%s\n' "$detected"
    return 0
  fi

  detected="$(docker ps --format '{{.Names}} {{.Image}}' | awk 'tolower($0) ~ /docmost/ {print $1; exit}')"
  if [ -n "$detected" ]; then
    printf '%s\n' "$detected"
    return 0
  fi

  return 1
}

docmost_storage_driver() {
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$1" \
    | sed -n 's/^STORAGE_DRIVER=//p' \
    | tail -n 1
}

archive_docmost_local_storage() {
  local container_name="$1"
  local output_file="${OBJECT_BACKUP_DIR}/docmost-local-storage_${timestamp}.tar.gz"

  log_phase archive "Archiving Docmost local uploads from ${container_name}."
  if ! docker cp "${container_name}:/app/data/storage" - | gzip -1 > "$output_file"; then
    rm -f "$output_file"
    echo "ERROR: Docmost local storage archive failed." >&2
    return 1
  fi

  if [ ! -s "$output_file" ]; then
    rm -f "$output_file"
    echo "ERROR: Empty Docmost local storage archive produced." >&2
    return 1
  fi
}

prune_old_backups() {
  log_phase prune "Pruning backup artifacts older than ${RETENTION_DAYS} day(s)."
  find "$BACKUP_DIR" -type f -mtime +"$RETENTION_DAYS" -delete
  find "$OBJECT_BACKUP_DIR" -type f -mtime +"$RETENTION_DAYS" -delete
}

if ! container_exists "$POSTGRES_CONTAINER"; then
  echo "ERROR: Postgres container not found: $POSTGRES_CONTAINER" >&2
  exit 1
fi

for app_db in "${app_databases[@]}"; do
  dump_postgres_db "$app_db" || backup_failures=$((backup_failures + 1))
done

if ! container_exists "$SEAWEEDFS_CONTAINER"; then
  echo "ERROR: SeaweedFS container not found: $SEAWEEDFS_CONTAINER" >&2
  backup_failures=$((backup_failures + 1))
else
  run_with_optional_pause "$SEAWEEDFS_CONTAINER" "$FREEZE_SEAWEEDFS_DURING_BACKUP" archive_seaweedfs_data \
    || backup_failures=$((backup_failures + 1))
  backup_seaweedfs_config || backup_failures=$((backup_failures + 1))
fi

if detected_docmost_container="$(detect_docmost_container 2>/dev/null || true)"; then
  if [ -n "$detected_docmost_container" ] && container_exists "$detected_docmost_container"; then
    docmost_driver="$(docmost_storage_driver "$detected_docmost_container" || true)"
    if [ "${docmost_driver:-}" = "local" ]; then
      run_with_optional_pause "$detected_docmost_container" "$FREEZE_DOCMOST_DURING_BACKUP" archive_docmost_local_storage "$detected_docmost_container" \
        || backup_failures=$((backup_failures + 1))
    else
      log_phase archive "Skipping Docmost local upload archive because STORAGE_DRIVER=${docmost_driver:-<unset>}."
    fi
  elif [ "$STRICT_DOCMOST_BACKUP" = "1" ]; then
    echo "ERROR: Docmost container could not be detected." >&2
    backup_failures=$((backup_failures + 1))
  else
    log_phase archive "Skipping Docmost local upload archive because no Docmost container was detected."
  fi
else
  if [ "$STRICT_DOCMOST_BACKUP" = "1" ]; then
    echo "ERROR: Docmost container could not be detected." >&2
    backup_failures=$((backup_failures + 1))
  else
    log_phase archive "Skipping Docmost local upload archive because no Docmost container was detected."
  fi
fi

prune_old_backups

if [ "$backup_failures" -gt 0 ]; then
  echo "ERROR: Backup finished with ${backup_failures} failure(s)." >&2
  exit 1
fi

log_phase "done" "Backup finished successfully."
