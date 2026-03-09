#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  cat <<'USAGE'
Generate/refresh Docmost env values in a local env file.

Usage:
  scripts/generate-docmost-secrets.sh [--env-file <path>] [--infra-env-file <path>] [--no-infra-sync] [--force-app-secret] [--force-all]

Behavior:
  - If env file is missing, script creates parent directory and copies env/docmost-coolify.env.example.
  - By default, syncs DATABASE_URL and REDIS_URL from bootstrap-artifacts/production-infra.env when available.
  - Generates APP_SECRET when empty/placeholder (or when forced).
USAGE
}

env_file="bootstrap-artifacts/docmost.env"
infra_env_file="bootstrap-artifacts/production-infra.env"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
env_example_file="$repo_root/env/docmost-coolify.env.example"
force_app_secret=0
force_all=0
no_infra_sync=0

require_value_arg() {
  local flag="$1"
  local maybe_value="${2:-}"
  if [[ -z "$maybe_value" || "$maybe_value" == -* ]]; then
    echo "ERROR: $flag requires a value." >&2
    usage >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      require_value_arg "--env-file" "${2:-}"
      env_file="${2:-}"
      shift 2
      ;;
    --infra-env-file)
      require_value_arg "--infra-env-file" "${2:-}"
      infra_env_file="${2:-}"
      shift 2
      ;;
    --no-infra-sync)
      no_infra_sync=1
      shift
      ;;
    --force-app-secret)
      force_app_secret=1
      shift
      ;;
    --force-all)
      force_all=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if (( force_all == 1 )); then
  force_app_secret=1
fi

if [[ "$env_file" != /* ]]; then
  env_file="$repo_root/$env_file"
fi

if [[ "$infra_env_file" != /* ]]; then
  infra_env_file="$repo_root/$infra_env_file"
fi

if [[ -d "$env_file" ]]; then
  echo "ERROR: --env-file points to a directory, expected a file: $env_file" >&2
  exit 1
fi

if [[ -d "$infra_env_file" ]]; then
  echo "ERROR: --infra-env-file points to a directory, expected a file: $infra_env_file" >&2
  exit 1
fi

if [[ ! -f "$env_example_file" ]]; then
  echo "ERROR: missing template env file: $env_example_file" >&2
  exit 1
fi

mkdir -p "$(dirname "$env_file")"

if [[ ! -f "$env_file" ]]; then
  cp "$env_example_file" "$env_file"
  chmod 600 "$env_file"
  echo "Created: $env_file (from $env_example_file)"
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl is required for secret generation." >&2
  exit 1
fi

strip_env_quotes() {
  local value="$1"
  if [[ "$value" =~ ^\'(.*)\'$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$value" =~ ^\"(.*)\"$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$value"
  fi
}

format_env_value() {
  local value="$1"
  if [[ "$value" != *"'"* ]]; then
    printf "'%s'" "$value"
    return 0
  fi
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\\$}"
  printf '"%s"' "$value"
}

is_empty_or_placeholder() {
  local value="$1"
  [[ -z "$value" || "$value" == *"CHANGE_ME"* ]]
}

is_usable_infra_value() {
  local value="$1"
  [[ -n "$value" && "$value" != *"CHANGE_ME"* ]]
}

gen_hex() {
  local bytes="$1"
  openssl rand -hex "$bytes"
}

sync_kv() {
  local key="$1"
  local value="$2"
  printf '%s=%s\n' "$key" "$(format_env_value "$value")"
}

declare -A current=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" != *=* ]] && continue
  k="${line%%=*}"
  v="${line#*=}"
  k="${k#"${k%%[![:space:]]*}"}"
  k="${k%"${k##*[![:space:]]}"}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  current["$k"]="$(strip_env_quotes "$v")"
done < "$env_file"

declare -A infra=()
infra_sync_applied=0
if (( no_infra_sync == 0 )); then
  if [[ -f "$infra_env_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" != *=* ]] && continue
      k="${line%%=*}"
      v="${line#*=}"
      k="${k#"${k%%[![:space:]]*}"}"
      k="${k%"${k##*[![:space:]]}"}"
      v="${v#"${v%%[![:space:]]*}"}"
      v="${v%"${v##*[![:space:]]}"}"
      infra["$k"]="$(strip_env_quotes "$v")"
    done < "$infra_env_file"
  else
    echo "WARNING: infra env file not found, skipping infra sync: $infra_env_file" >&2
  fi
fi

docmost_image="${current[DOCMOST_IMAGE]:-docmost/docmost:latest}"
app_url="${current[APP_URL]:-https://docs.example.com}"
app_secret="${current[APP_SECRET]:-}"
database_url="${current[DATABASE_URL]:-}"
redis_url="${current[REDIS_URL]:-}"
infra_network_name="${current[INFRA_NETWORK_NAME]:-infra}"
port="${current[PORT]:-3000}"
storage_driver="${current[STORAGE_DRIVER]:-local}"

if (( force_app_secret == 1 )) || is_empty_or_placeholder "$app_secret"; then
  app_secret="$(gen_hex 32)"
fi

if (( no_infra_sync == 0 )); then
  postgres_user="${infra[POSTGRES_APPS_USER]:-apps_admin}"
  postgres_pass="${infra[POSTGRES_APPS_PASSWORD]:-}"
  postgres_db="${infra[POSTGRES_DOCMOST_DB]:-docmost}"
  postgres_host="${infra[POSTGRES_APPS_CONTAINER_NAME]:-postgres-apps}"
  valkey_pass="${infra[APPS_VALKEY_PASSWORD]:-}"
  valkey_host="${infra[VALKEY_APPS_CONTAINER_NAME]:-valkey-apps}"

  if is_usable_infra_value "${infra[INFRA_NETWORK_NAME]:-}"; then
    infra_network_name="${infra[INFRA_NETWORK_NAME]}"
    infra_sync_applied=1
  fi

  if is_usable_infra_value "$postgres_pass"; then
    database_url="postgresql://${postgres_user}:${postgres_pass}@${postgres_host}:5432/${postgres_db}?schema=public"
    infra_sync_applied=1
  fi

  if is_usable_infra_value "$valkey_pass"; then
    redis_url="redis://default:${valkey_pass}@${valkey_host}:6379/1"
    infra_sync_applied=1
  fi
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

saw_docmost_image=0
saw_app_url=0
saw_app_secret=0
saw_database_url=0
saw_redis_url=0
saw_infra_network_name=0
saw_port=0
saw_storage_driver=0

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  case "$line" in
    DOCMOST_IMAGE=*) saw_docmost_image=1; sync_kv "DOCMOST_IMAGE" "$docmost_image" >> "$tmp" ;;
    APP_URL=*) saw_app_url=1; sync_kv "APP_URL" "$app_url" >> "$tmp" ;;
    APP_SECRET=*) saw_app_secret=1; sync_kv "APP_SECRET" "$app_secret" >> "$tmp" ;;
    DATABASE_URL=*) saw_database_url=1; sync_kv "DATABASE_URL" "$database_url" >> "$tmp" ;;
    REDIS_URL=*) saw_redis_url=1; sync_kv "REDIS_URL" "$redis_url" >> "$tmp" ;;
    INFRA_NETWORK_NAME=*) saw_infra_network_name=1; sync_kv "INFRA_NETWORK_NAME" "$infra_network_name" >> "$tmp" ;;
    PORT=*) saw_port=1; sync_kv "PORT" "$port" >> "$tmp" ;;
    STORAGE_DRIVER=*) saw_storage_driver=1; sync_kv "STORAGE_DRIVER" "$storage_driver" >> "$tmp" ;;
    *) printf '%s\n' "$line" >> "$tmp" ;;
  esac
done < "$env_file"

(( saw_docmost_image == 1 )) || sync_kv "DOCMOST_IMAGE" "$docmost_image" >> "$tmp"
(( saw_app_url == 1 )) || sync_kv "APP_URL" "$app_url" >> "$tmp"
(( saw_app_secret == 1 )) || sync_kv "APP_SECRET" "$app_secret" >> "$tmp"
(( saw_database_url == 1 )) || sync_kv "DATABASE_URL" "$database_url" >> "$tmp"
(( saw_redis_url == 1 )) || sync_kv "REDIS_URL" "$redis_url" >> "$tmp"
(( saw_infra_network_name == 1 )) || sync_kv "INFRA_NETWORK_NAME" "$infra_network_name" >> "$tmp"
(( saw_port == 1 )) || sync_kv "PORT" "$port" >> "$tmp"
(( saw_storage_driver == 1 )) || sync_kv "STORAGE_DRIVER" "$storage_driver" >> "$tmp"

mv "$tmp" "$env_file"
chmod 600 "$env_file"

echo "Updated: $env_file"
if (( infra_sync_applied == 1 )); then
  echo "Infra-derived Docmost values synchronized from: $infra_env_file"
elif (( no_infra_sync == 0 )); then
  echo "Infra sync not applied (missing or unresolved values in: $infra_env_file)"
else
  echo "Infra sync disabled (--no-infra-sync)."
fi

echo "APP_SECRET generated/refreshed when needed."
