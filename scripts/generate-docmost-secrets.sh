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
  - By default, syncs infra-derived Docmost values from bootstrap-artifacts/production-infra.env when available.
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
storage_driver="${current[STORAGE_DRIVER]:-s3}"
mail_driver="${current[MAIL_DRIVER]:-smtp}"
smtp_host="${current[SMTP_HOST]:-CHANGE_ME_smtp_host}"
smtp_port="${current[SMTP_PORT]:-587}"
smtp_username="${current[SMTP_USERNAME]:-CHANGE_ME_smtp_username}"
smtp_password="${current[SMTP_PASSWORD]:-CHANGE_ME_smtp_password}"
smtp_secure="${current[SMTP_SECURE]:-false}"
mail_from_address="${current[MAIL_FROM_ADDRESS]:-CHANGE_ME_mail_from_address}"
mail_from_name="${current[MAIL_FROM_NAME]:-Docmost}"
drawio_url="${current[DRAWIO_URL]:-https://embed.diagrams.net/?spin=1&proto=json&configure=1}"
aws_s3_access_key_id="${current[AWS_S3_ACCESS_KEY_ID]:-CHANGE_ME_plane_s3_access_key}"
aws_s3_secret_access_key="${current[AWS_S3_SECRET_ACCESS_KEY]:-CHANGE_ME_plane_s3_secret_key}"
aws_s3_region="${current[AWS_S3_REGION]:-eu-central-1}"
aws_s3_bucket="${current[AWS_S3_BUCKET]:-plane-uploads}"
aws_s3_endpoint="${current[AWS_S3_ENDPOINT]:-http://seaweedfs-plane:8333}"
aws_s3_force_path_style="${current[AWS_S3_FORCE_PATH_STYLE]:-true}"
disable_telemetry="${current[DISABLE_TELEMETRY]:-true}"
search_driver="${current[SEARCH_DRIVER]:-typesense}"
typesense_url="${current[TYPESENSE_URL]:-http://typesense:8108}"
typesense_api_key="${current[TYPESENSE_API_KEY]:-CHANGE_ME_typesense_api_key}"
typesense_locale="${current[TYPESENSE_LOCALE]:-en}"

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
  seaweedfs_host="${infra[SEAWEEDFS_PLANE_CONTAINER_NAME]:-seaweedfs-plane}"

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

  if is_usable_infra_value "${infra[MAIL_DRIVER]:-}"; then
    mail_driver="${infra[MAIL_DRIVER]}"
    infra_sync_applied=1
  fi
  if is_usable_infra_value "${infra[SMTP_HOST]:-}"; then
    smtp_host="${infra[SMTP_HOST]}"
    infra_sync_applied=1
  fi
  if is_usable_infra_value "${infra[SMTP_PORT]:-}"; then
    smtp_port="${infra[SMTP_PORT]}"
    infra_sync_applied=1
  fi
  if is_usable_infra_value "${infra[SMTP_USERNAME]:-}"; then
    smtp_username="${infra[SMTP_USERNAME]}"
    infra_sync_applied=1
  fi
  if is_usable_infra_value "${infra[SMTP_PASSWORD]:-}"; then
    smtp_password="${infra[SMTP_PASSWORD]}"
    infra_sync_applied=1
  fi
  if is_usable_infra_value "${infra[SMTP_SECURE]:-}"; then
    smtp_secure="${infra[SMTP_SECURE]}"
    infra_sync_applied=1
  fi
  if is_usable_infra_value "${infra[MAIL_FROM_ADDRESS]:-}"; then
    mail_from_address="${infra[MAIL_FROM_ADDRESS]}"
    infra_sync_applied=1
  fi
  if is_usable_infra_value "${infra[MAIL_FROM_NAME]:-}"; then
    mail_from_name="${infra[MAIL_FROM_NAME]}"
    infra_sync_applied=1
  fi
  if is_usable_infra_value "${infra[DRAWIO_URL]:-}"; then
    drawio_url="${infra[DRAWIO_URL]}"
    infra_sync_applied=1
  fi

  if is_usable_infra_value "${infra[PLANE_S3_ACCESS_KEY]:-}"; then
    aws_s3_access_key_id="${infra[PLANE_S3_ACCESS_KEY]}"
    infra_sync_applied=1
  fi
  if is_usable_infra_value "${infra[PLANE_S3_SECRET_KEY]:-}"; then
    aws_s3_secret_access_key="${infra[PLANE_S3_SECRET_KEY]}"
    infra_sync_applied=1
  fi
  if is_usable_infra_value "${infra[PLANE_S3_BUCKET]:-}"; then
    aws_s3_bucket="${infra[PLANE_S3_BUCKET]}"
    infra_sync_applied=1
  fi
  if is_usable_infra_value "${infra[AWS_S3_REGION]:-}"; then
    aws_s3_region="${infra[AWS_S3_REGION]}"
    infra_sync_applied=1
  fi
  if is_usable_infra_value "${infra[AWS_S3_ENDPOINT]:-}"; then
    aws_s3_endpoint="${infra[AWS_S3_ENDPOINT]}"
    infra_sync_applied=1
  elif is_usable_infra_value "$seaweedfs_host"; then
    aws_s3_endpoint="http://${seaweedfs_host}:8333"
    infra_sync_applied=1
  fi
  if is_usable_infra_value "${infra[AWS_S3_FORCE_PATH_STYLE]:-}"; then
    aws_s3_force_path_style="${infra[AWS_S3_FORCE_PATH_STYLE]}"
    infra_sync_applied=1
  fi
  if is_usable_infra_value "${infra[DISABLE_TELEMETRY]:-}"; then
    disable_telemetry="${infra[DISABLE_TELEMETRY]}"
    infra_sync_applied=1
  fi
  if is_usable_infra_value "${infra[SEARCH_DRIVER]:-}"; then
    search_driver="${infra[SEARCH_DRIVER]}"
    infra_sync_applied=1
  fi
  if is_usable_infra_value "${infra[TYPESENSE_URL]:-}"; then
    typesense_url="${infra[TYPESENSE_URL]}"
    infra_sync_applied=1
  fi
  if is_usable_infra_value "${infra[TYPESENSE_API_KEY]:-}"; then
    typesense_api_key="${infra[TYPESENSE_API_KEY]}"
    infra_sync_applied=1
  fi
  if is_usable_infra_value "${infra[TYPESENSE_LOCALE]:-}"; then
    typesense_locale="${infra[TYPESENSE_LOCALE]}"
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
saw_mail_driver=0
saw_smtp_host=0
saw_smtp_port=0
saw_smtp_username=0
saw_smtp_password=0
saw_smtp_secure=0
saw_mail_from_address=0
saw_mail_from_name=0
saw_drawio_url=0
saw_aws_s3_access_key_id=0
saw_aws_s3_secret_access_key=0
saw_aws_s3_region=0
saw_aws_s3_bucket=0
saw_aws_s3_endpoint=0
saw_aws_s3_force_path_style=0
saw_disable_telemetry=0
saw_search_driver=0
saw_typesense_url=0
saw_typesense_api_key=0
saw_typesense_locale=0

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
    MAIL_DRIVER=*) saw_mail_driver=1; sync_kv "MAIL_DRIVER" "$mail_driver" >> "$tmp" ;;
    SMTP_HOST=*) saw_smtp_host=1; sync_kv "SMTP_HOST" "$smtp_host" >> "$tmp" ;;
    SMTP_PORT=*) saw_smtp_port=1; sync_kv "SMTP_PORT" "$smtp_port" >> "$tmp" ;;
    SMTP_USERNAME=*) saw_smtp_username=1; sync_kv "SMTP_USERNAME" "$smtp_username" >> "$tmp" ;;
    SMTP_PASSWORD=*) saw_smtp_password=1; sync_kv "SMTP_PASSWORD" "$smtp_password" >> "$tmp" ;;
    SMTP_SECURE=*) saw_smtp_secure=1; sync_kv "SMTP_SECURE" "$smtp_secure" >> "$tmp" ;;
    MAIL_FROM_ADDRESS=*) saw_mail_from_address=1; sync_kv "MAIL_FROM_ADDRESS" "$mail_from_address" >> "$tmp" ;;
    MAIL_FROM_NAME=*) saw_mail_from_name=1; sync_kv "MAIL_FROM_NAME" "$mail_from_name" >> "$tmp" ;;
    POSTMARK_TOKEN=*) ;;
    DRAWIO_URL=*) saw_drawio_url=1; sync_kv "DRAWIO_URL" "$drawio_url" >> "$tmp" ;;
    AWS_S3_ACCESS_KEY_ID=*) saw_aws_s3_access_key_id=1; sync_kv "AWS_S3_ACCESS_KEY_ID" "$aws_s3_access_key_id" >> "$tmp" ;;
    AWS_S3_SECRET_ACCESS_KEY=*) saw_aws_s3_secret_access_key=1; sync_kv "AWS_S3_SECRET_ACCESS_KEY" "$aws_s3_secret_access_key" >> "$tmp" ;;
    AWS_S3_REGION=*) saw_aws_s3_region=1; sync_kv "AWS_S3_REGION" "$aws_s3_region" >> "$tmp" ;;
    AWS_S3_BUCKET=*) saw_aws_s3_bucket=1; sync_kv "AWS_S3_BUCKET" "$aws_s3_bucket" >> "$tmp" ;;
    AWS_S3_ENDPOINT=*) saw_aws_s3_endpoint=1; sync_kv "AWS_S3_ENDPOINT" "$aws_s3_endpoint" >> "$tmp" ;;
    AWS_S3_FORCE_PATH_STYLE=*) saw_aws_s3_force_path_style=1; sync_kv "AWS_S3_FORCE_PATH_STYLE" "$aws_s3_force_path_style" >> "$tmp" ;;
    DISABLE_TELEMETRY=*) saw_disable_telemetry=1; sync_kv "DISABLE_TELEMETRY" "$disable_telemetry" >> "$tmp" ;;
    SEARCH_DRIVER=*) saw_search_driver=1; sync_kv "SEARCH_DRIVER" "$search_driver" >> "$tmp" ;;
    TYPESENSE_URL=*) saw_typesense_url=1; sync_kv "TYPESENSE_URL" "$typesense_url" >> "$tmp" ;;
    TYPESENSE_API_KEY=*) saw_typesense_api_key=1; sync_kv "TYPESENSE_API_KEY" "$typesense_api_key" >> "$tmp" ;;
    TYPESENSE_LOCALE=*) saw_typesense_locale=1; sync_kv "TYPESENSE_LOCALE" "$typesense_locale" >> "$tmp" ;;
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
(( saw_mail_driver == 1 )) || sync_kv "MAIL_DRIVER" "$mail_driver" >> "$tmp"
(( saw_smtp_host == 1 )) || sync_kv "SMTP_HOST" "$smtp_host" >> "$tmp"
(( saw_smtp_port == 1 )) || sync_kv "SMTP_PORT" "$smtp_port" >> "$tmp"
(( saw_smtp_username == 1 )) || sync_kv "SMTP_USERNAME" "$smtp_username" >> "$tmp"
(( saw_smtp_password == 1 )) || sync_kv "SMTP_PASSWORD" "$smtp_password" >> "$tmp"
(( saw_smtp_secure == 1 )) || sync_kv "SMTP_SECURE" "$smtp_secure" >> "$tmp"
(( saw_mail_from_address == 1 )) || sync_kv "MAIL_FROM_ADDRESS" "$mail_from_address" >> "$tmp"
(( saw_mail_from_name == 1 )) || sync_kv "MAIL_FROM_NAME" "$mail_from_name" >> "$tmp"
(( saw_drawio_url == 1 )) || sync_kv "DRAWIO_URL" "$drawio_url" >> "$tmp"
(( saw_aws_s3_access_key_id == 1 )) || sync_kv "AWS_S3_ACCESS_KEY_ID" "$aws_s3_access_key_id" >> "$tmp"
(( saw_aws_s3_secret_access_key == 1 )) || sync_kv "AWS_S3_SECRET_ACCESS_KEY" "$aws_s3_secret_access_key" >> "$tmp"
(( saw_aws_s3_region == 1 )) || sync_kv "AWS_S3_REGION" "$aws_s3_region" >> "$tmp"
(( saw_aws_s3_bucket == 1 )) || sync_kv "AWS_S3_BUCKET" "$aws_s3_bucket" >> "$tmp"
(( saw_aws_s3_endpoint == 1 )) || sync_kv "AWS_S3_ENDPOINT" "$aws_s3_endpoint" >> "$tmp"
(( saw_aws_s3_force_path_style == 1 )) || sync_kv "AWS_S3_FORCE_PATH_STYLE" "$aws_s3_force_path_style" >> "$tmp"
(( saw_disable_telemetry == 1 )) || sync_kv "DISABLE_TELEMETRY" "$disable_telemetry" >> "$tmp"
(( saw_search_driver == 1 )) || sync_kv "SEARCH_DRIVER" "$search_driver" >> "$tmp"
(( saw_typesense_url == 1 )) || sync_kv "TYPESENSE_URL" "$typesense_url" >> "$tmp"
(( saw_typesense_api_key == 1 )) || sync_kv "TYPESENSE_API_KEY" "$typesense_api_key" >> "$tmp"
(( saw_typesense_locale == 1 )) || sync_kv "TYPESENSE_LOCALE" "$typesense_locale" >> "$tmp"

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
