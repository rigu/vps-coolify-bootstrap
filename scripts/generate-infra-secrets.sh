#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  cat <<'USAGE'
Generate/refresh secret values for internal service layer env file.

Usage:
  scripts/generate-infra-secrets.sh [--env-file <path>] [--force-passwords] [--force-secrets] [--force-all]

Behavior:
  - If env file is missing, script creates parent directory and copies env/infra.env.example.
USAGE
}

env_file="bootstrap-artifacts/production-infra.env"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
env_example_file="$repo_root/env/infra.env.example"
force_passwords=0
force_secrets=0
force_all=0

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
    --force-passwords)
      force_passwords=1
      shift
      ;;
    --force-secrets)
      force_secrets=1
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
  force_passwords=1
  force_secrets=1
fi

if [[ "$env_file" != /* ]]; then
  env_file="$repo_root/$env_file"
fi

if [[ -d "$env_file" ]]; then
  echo "ERROR: --env-file points to a directory, expected a file: $env_file" >&2
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

gen_hex() {
  local bytes="$1"
  openssl rand -hex "$bytes"
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

postgres_apps_password="${current[POSTGRES_APPS_PASSWORD]:-}"
apps_valkey_password="${current[APPS_VALKEY_PASSWORD]:-}"
plane_rabbitmq_password="${current[PLANE_RABBITMQ_PASSWORD]:-}"
plane_s3_access_key="${current[PLANE_S3_ACCESS_KEY]:-}"
plane_s3_secret_key="${current[PLANE_S3_SECRET_KEY]:-}"
postgres_replication_password="${current[POSTGRES_REPLICATION_PASSWORD]:-}"

passwords_changed=0
secrets_changed=0

if (( force_passwords == 1 )) || is_empty_or_placeholder "$postgres_apps_password"; then
  postgres_apps_password="$(gen_hex 16)"
  passwords_changed=1
fi

if (( force_passwords == 1 )) || is_empty_or_placeholder "$apps_valkey_password"; then
  apps_valkey_password="$(gen_hex 16)"
  passwords_changed=1
fi

if (( force_passwords == 1 )) || is_empty_or_placeholder "$plane_rabbitmq_password"; then
  plane_rabbitmq_password="$(gen_hex 16)"
  passwords_changed=1
fi

if (( force_passwords == 1 )) || is_empty_or_placeholder "$postgres_replication_password"; then
  postgres_replication_password="$(gen_hex 16)"
  passwords_changed=1
fi

if (( force_secrets == 1 )) || is_empty_or_placeholder "$plane_s3_access_key"; then
  plane_s3_access_key="PLN$(openssl rand -hex 9 | tr '[:lower:]' '[:upper:]')"
  secrets_changed=1
fi

if (( force_secrets == 1 )) || is_empty_or_placeholder "$plane_s3_secret_key"; then
  plane_s3_secret_key="$(gen_hex 32)"
  secrets_changed=1
fi

sync_kv() {
  local key="$1"
  local value="$2"
  printf '%s=%s\n' "$key" "$(format_env_value "$value")"
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

saw_postgres_apps_password=0
saw_apps_valkey_password=0
saw_plane_rabbitmq_password=0
saw_plane_s3_access_key=0
saw_plane_s3_secret_key=0
saw_postgres_replication_password=0

while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    POSTGRES_APPS_PASSWORD=*) saw_postgres_apps_password=1; sync_kv "POSTGRES_APPS_PASSWORD" "$postgres_apps_password" >> "$tmp" ;;
    APPS_VALKEY_PASSWORD=*) saw_apps_valkey_password=1; sync_kv "APPS_VALKEY_PASSWORD" "$apps_valkey_password" >> "$tmp" ;;
    PLANE_RABBITMQ_PASSWORD=*) saw_plane_rabbitmq_password=1; sync_kv "PLANE_RABBITMQ_PASSWORD" "$plane_rabbitmq_password" >> "$tmp" ;;
    POSTGRES_REPLICATION_PASSWORD=*) saw_postgres_replication_password=1; sync_kv "POSTGRES_REPLICATION_PASSWORD" "$postgres_replication_password" >> "$tmp" ;;
    PLANE_S3_ACCESS_KEY=*) saw_plane_s3_access_key=1; sync_kv "PLANE_S3_ACCESS_KEY" "$plane_s3_access_key" >> "$tmp" ;;
    PLANE_S3_SECRET_KEY=*) saw_plane_s3_secret_key=1; sync_kv "PLANE_S3_SECRET_KEY" "$plane_s3_secret_key" >> "$tmp" ;;
    *) printf '%s\n' "$line" >> "$tmp" ;;
  esac
done < "$env_file"

(( saw_postgres_apps_password == 1 )) || sync_kv "POSTGRES_APPS_PASSWORD" "$postgres_apps_password" >> "$tmp"
(( saw_apps_valkey_password == 1 )) || sync_kv "APPS_VALKEY_PASSWORD" "$apps_valkey_password" >> "$tmp"
(( saw_plane_rabbitmq_password == 1 )) || sync_kv "PLANE_RABBITMQ_PASSWORD" "$plane_rabbitmq_password" >> "$tmp"
(( saw_postgres_replication_password == 1 )) || sync_kv "POSTGRES_REPLICATION_PASSWORD" "$postgres_replication_password" >> "$tmp"
(( saw_plane_s3_access_key == 1 )) || sync_kv "PLANE_S3_ACCESS_KEY" "$plane_s3_access_key" >> "$tmp"
(( saw_plane_s3_secret_key == 1 )) || sync_kv "PLANE_S3_SECRET_KEY" "$plane_s3_secret_key" >> "$tmp"

mv "$tmp" "$env_file"
chmod 600 "$env_file" 2>/dev/null || true

printf 'Updated: %s\n' "$env_file"
if (( passwords_changed == 1 )); then
  echo "Infra passwords generated/refreshed (POSTGRES_APPS_PASSWORD, APPS_VALKEY_PASSWORD, PLANE_RABBITMQ_PASSWORD, POSTGRES_REPLICATION_PASSWORD)."
else
  echo "Infra passwords kept (use --force-passwords to rotate)."
fi
if (( secrets_changed == 1 )); then
  echo "Infra secrets generated/refreshed (PLANE_S3_ACCESS_KEY, PLANE_S3_SECRET_KEY)."
else
  echo "Infra secrets kept (use --force-secrets to rotate)."
fi
