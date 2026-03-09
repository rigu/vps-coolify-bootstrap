#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  cat <<'USAGE'
Generate/refresh Plane env secrets in a local env file.

Usage:
  scripts/generate-plane-secrets.sh [--env-file <path>] [--infra-env-file <path>] [--no-infra-sync] [--force-passwords] [--force-secrets] [--force-all]

Behavior:
  - If env file is missing, script creates parent directory and copies env/plane-coolify.env.example.
  - By default, syncs infra-dependent Plane values from bootstrap-artifacts/production-infra.env when available.
  - Updates dependent URLs (DATABASE_URL, REDIS_URL, AMQP_URL) when values are generated or placeholders are present.
USAGE
}

env_file="bootstrap-artifacts/plane.env"
infra_env_file="bootstrap-artifacts/production-infra.env"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
env_example_file="$repo_root/env/plane-coolify.env.example"
force_passwords=0
force_secrets=0
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

secret_key="${current[SECRET_KEY]:-}"
postgres_password="${current[POSTGRES_PASSWORD]:-}"
redis_password="${current[REDIS_PASSWORD]:-}"
rabbitmq_password="${current[RABBITMQ_DEFAULT_PASS]:-}"
aws_access_key="${current[AWS_ACCESS_KEY_ID]:-}"
aws_secret_key="${current[AWS_SECRET_ACCESS_KEY]:-}"
silo_secret="${current[SILO_HMAC_SECRET_KEY]:-}"
live_secret="${current[LIVE_SERVER_SECRET_KEY]:-}"
database_url="${current[DATABASE_URL]:-}"
redis_url="${current[REDIS_URL]:-}"
amqp_url="${current[AMQP_URL]:-}"

postgres_user="${current[POSTGRES_USER]:-apps_admin}"
postgres_host="${current[POSTGRES_HOST]:-postgres-apps}"
postgres_db="${current[POSTGRES_DB]:-plane}"
redis_host="${current[REDIS_HOST]:-valkey-apps}"
redis_port="${current[REDIS_PORT]:-6379}"
rabbitmq_user="${current[RABBITMQ_DEFAULT_USER]:-plane}"
rabbitmq_host="${current[RABBITMQ_HOST]:-rabbitmq-plane}"
rabbitmq_port="${current[RABBITMQ_PORT]:-5672}"
rabbitmq_vhost="${current[RABBITMQ_VHOST]:-${current[RABBITMQ_DEFAULT_VHOST]:-plane}}"
aws_s3_bucket_name="${current[AWS_S3_BUCKET_NAME]:-plane-uploads}"
bucket_name="${current[BUCKET_NAME]:-plane-uploads}"

postgres_password_from_infra=0
redis_password_from_infra=0
rabbitmq_password_from_infra=0
aws_access_key_from_infra=0
aws_secret_key_from_infra=0

if is_usable_infra_value "${infra[POSTGRES_APPS_USER]:-}"; then
  postgres_user="${infra[POSTGRES_APPS_USER]}"
  infra_sync_applied=1
fi
if is_usable_infra_value "${infra[POSTGRES_APPS_CONTAINER_NAME]:-}"; then
  postgres_host="${infra[POSTGRES_APPS_CONTAINER_NAME]}"
  infra_sync_applied=1
elif is_usable_infra_value "${infra[POSTGRES_APPS_USER]:-}" || is_usable_infra_value "${infra[POSTGRES_APPS_PASSWORD]:-}"; then
  postgres_host="postgres-apps"
  infra_sync_applied=1
fi
if is_usable_infra_value "${infra[POSTGRES_PLANE_DB]:-}"; then
  postgres_db="${infra[POSTGRES_PLANE_DB]}"
  infra_sync_applied=1
fi
if is_usable_infra_value "${infra[POSTGRES_APPS_PASSWORD]:-}"; then
  postgres_password="${infra[POSTGRES_APPS_PASSWORD]}"
  postgres_password_from_infra=1
  infra_sync_applied=1
fi

if is_usable_infra_value "${infra[VALKEY_APPS_CONTAINER_NAME]:-}"; then
  redis_host="${infra[VALKEY_APPS_CONTAINER_NAME]}"
  infra_sync_applied=1
elif is_usable_infra_value "${infra[APPS_VALKEY_PASSWORD]:-}"; then
  redis_host="valkey-apps"
  infra_sync_applied=1
fi
if is_usable_infra_value "${infra[APPS_VALKEY_PASSWORD]:-}"; then
  redis_password="${infra[APPS_VALKEY_PASSWORD]}"
  redis_password_from_infra=1
  infra_sync_applied=1
fi

if is_usable_infra_value "${infra[RABBITMQ_PLANE_CONTAINER_NAME]:-}"; then
  rabbitmq_host="${infra[RABBITMQ_PLANE_CONTAINER_NAME]}"
  infra_sync_applied=1
elif is_usable_infra_value "${infra[PLANE_RABBITMQ_USER]:-}" || is_usable_infra_value "${infra[PLANE_RABBITMQ_PASSWORD]:-}"; then
  rabbitmq_host="rabbitmq-plane"
  infra_sync_applied=1
fi
if is_usable_infra_value "${infra[PLANE_RABBITMQ_USER]:-}"; then
  rabbitmq_user="${infra[PLANE_RABBITMQ_USER]}"
  infra_sync_applied=1
fi
if is_usable_infra_value "${infra[PLANE_RABBITMQ_VHOST]:-}"; then
  rabbitmq_vhost="${infra[PLANE_RABBITMQ_VHOST]}"
  infra_sync_applied=1
fi
if is_usable_infra_value "${infra[PLANE_RABBITMQ_PASSWORD]:-}"; then
  rabbitmq_password="${infra[PLANE_RABBITMQ_PASSWORD]}"
  rabbitmq_password_from_infra=1
  infra_sync_applied=1
fi

if is_usable_infra_value "${infra[PLANE_S3_ACCESS_KEY]:-}"; then
  aws_access_key="${infra[PLANE_S3_ACCESS_KEY]}"
  aws_access_key_from_infra=1
  infra_sync_applied=1
fi
if is_usable_infra_value "${infra[PLANE_S3_SECRET_KEY]:-}"; then
  aws_secret_key="${infra[PLANE_S3_SECRET_KEY]}"
  aws_secret_key_from_infra=1
  infra_sync_applied=1
fi
if is_usable_infra_value "${infra[PLANE_S3_BUCKET]:-}"; then
  aws_s3_bucket_name="${infra[PLANE_S3_BUCKET]}"
  bucket_name="${infra[PLANE_S3_BUCKET]}"
  infra_sync_applied=1
fi

passwords_changed=0
secrets_changed=0

if (( force_secrets == 1 )) || is_empty_or_placeholder "$secret_key"; then
  secret_key="$(gen_hex 32)"
  secrets_changed=1
fi

if (( postgres_password_from_infra == 0 )) && { (( force_passwords == 1 )) || is_empty_or_placeholder "$postgres_password"; }; then
  postgres_password="$(gen_hex 16)"
  passwords_changed=1
fi

if (( redis_password_from_infra == 0 )) && { (( force_passwords == 1 )) || is_empty_or_placeholder "$redis_password"; }; then
  redis_password="$(gen_hex 16)"
  passwords_changed=1
fi

if (( rabbitmq_password_from_infra == 0 )) && { (( force_passwords == 1 )) || is_empty_or_placeholder "$rabbitmq_password"; }; then
  rabbitmq_password="$(gen_hex 16)"
  passwords_changed=1
fi

if (( aws_access_key_from_infra == 0 )) && { (( force_secrets == 1 )) || is_empty_or_placeholder "$aws_access_key"; }; then
  aws_access_key="PLN$(openssl rand -hex 9 | tr '[:lower:]' '[:upper:]')"
  secrets_changed=1
fi

if (( aws_secret_key_from_infra == 0 )) && { (( force_secrets == 1 )) || is_empty_or_placeholder "$aws_secret_key"; }; then
  aws_secret_key="$(gen_hex 32)"
  secrets_changed=1
fi

if (( force_secrets == 1 )) || is_empty_or_placeholder "$silo_secret"; then
  silo_secret="$(gen_hex 32)"
  secrets_changed=1
fi

if (( force_secrets == 1 )) || is_empty_or_placeholder "$live_secret"; then
  live_secret="$(gen_hex 32)"
  secrets_changed=1
fi

if (( passwords_changed == 1 )) || (( infra_sync_applied == 1 )) || is_empty_or_placeholder "$database_url"; then
  database_url="postgresql://${postgres_user}:${postgres_password}@${postgres_host}:5432/${postgres_db}"
fi

if (( passwords_changed == 1 )) || (( infra_sync_applied == 1 )) || is_empty_or_placeholder "$redis_url"; then
  redis_url="redis://default:${redis_password}@${redis_host}:${redis_port}/0"
fi

if (( passwords_changed == 1 )) || (( infra_sync_applied == 1 )) || is_empty_or_placeholder "$amqp_url"; then
  amqp_url="amqp://${rabbitmq_user}:${rabbitmq_password}@${rabbitmq_host}:${rabbitmq_port}/${rabbitmq_vhost}"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

saw_secret_key=0
saw_postgres_password=0
saw_redis_password=0
saw_rabbitmq_password=0
saw_aws_access_key=0
saw_aws_secret_key=0
saw_silo_secret=0
saw_live_secret=0
saw_database_url=0
saw_redis_url=0
saw_amqp_url=0
saw_postgres_user=0
saw_postgres_db=0
saw_postgres_host=0
saw_redis_host=0
saw_rabbitmq_host=0
saw_rabbitmq_default_user=0
saw_rabbitmq_default_vhost=0
saw_rabbitmq_vhost=0
saw_aws_s3_bucket_name=0
saw_bucket_name=0

while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    SECRET_KEY=*) saw_secret_key=1; sync_kv "SECRET_KEY" "$secret_key" >> "$tmp" ;;
    POSTGRES_PASSWORD=*) saw_postgres_password=1; sync_kv "POSTGRES_PASSWORD" "$postgres_password" >> "$tmp" ;;
    REDIS_PASSWORD=*) saw_redis_password=1; sync_kv "REDIS_PASSWORD" "$redis_password" >> "$tmp" ;;
    RABBITMQ_DEFAULT_PASS=*) saw_rabbitmq_password=1; sync_kv "RABBITMQ_DEFAULT_PASS" "$rabbitmq_password" >> "$tmp" ;;
    AWS_ACCESS_KEY_ID=*) saw_aws_access_key=1; sync_kv "AWS_ACCESS_KEY_ID" "$aws_access_key" >> "$tmp" ;;
    AWS_SECRET_ACCESS_KEY=*) saw_aws_secret_key=1; sync_kv "AWS_SECRET_ACCESS_KEY" "$aws_secret_key" >> "$tmp" ;;
    SILO_HMAC_SECRET_KEY=*) saw_silo_secret=1; sync_kv "SILO_HMAC_SECRET_KEY" "$silo_secret" >> "$tmp" ;;
    LIVE_SERVER_SECRET_KEY=*) saw_live_secret=1; sync_kv "LIVE_SERVER_SECRET_KEY" "$live_secret" >> "$tmp" ;;
    DATABASE_URL=*) saw_database_url=1; sync_kv "DATABASE_URL" "$database_url" >> "$tmp" ;;
    REDIS_URL=*) saw_redis_url=1; sync_kv "REDIS_URL" "$redis_url" >> "$tmp" ;;
    AMQP_URL=*) saw_amqp_url=1; sync_kv "AMQP_URL" "$amqp_url" >> "$tmp" ;;
    POSTGRES_USER=*) saw_postgres_user=1; sync_kv "POSTGRES_USER" "$postgres_user" >> "$tmp" ;;
    POSTGRES_DB=*) saw_postgres_db=1; sync_kv "POSTGRES_DB" "$postgres_db" >> "$tmp" ;;
    POSTGRES_HOST=*) saw_postgres_host=1; sync_kv "POSTGRES_HOST" "$postgres_host" >> "$tmp" ;;
    REDIS_HOST=*) saw_redis_host=1; sync_kv "REDIS_HOST" "$redis_host" >> "$tmp" ;;
    RABBITMQ_HOST=*) saw_rabbitmq_host=1; sync_kv "RABBITMQ_HOST" "$rabbitmq_host" >> "$tmp" ;;
    RABBITMQ_DEFAULT_USER=*) saw_rabbitmq_default_user=1; sync_kv "RABBITMQ_DEFAULT_USER" "$rabbitmq_user" >> "$tmp" ;;
    RABBITMQ_DEFAULT_VHOST=*) saw_rabbitmq_default_vhost=1; sync_kv "RABBITMQ_DEFAULT_VHOST" "$rabbitmq_vhost" >> "$tmp" ;;
    RABBITMQ_VHOST=*) saw_rabbitmq_vhost=1; sync_kv "RABBITMQ_VHOST" "$rabbitmq_vhost" >> "$tmp" ;;
    AWS_S3_BUCKET_NAME=*) saw_aws_s3_bucket_name=1; sync_kv "AWS_S3_BUCKET_NAME" "$aws_s3_bucket_name" >> "$tmp" ;;
    BUCKET_NAME=*) saw_bucket_name=1; sync_kv "BUCKET_NAME" "$bucket_name" >> "$tmp" ;;
    *) printf '%s\n' "$line" >> "$tmp" ;;
  esac
done < "$env_file"

(( saw_secret_key == 1 )) || sync_kv "SECRET_KEY" "$secret_key" >> "$tmp"
(( saw_postgres_password == 1 )) || sync_kv "POSTGRES_PASSWORD" "$postgres_password" >> "$tmp"
(( saw_redis_password == 1 )) || sync_kv "REDIS_PASSWORD" "$redis_password" >> "$tmp"
(( saw_rabbitmq_password == 1 )) || sync_kv "RABBITMQ_DEFAULT_PASS" "$rabbitmq_password" >> "$tmp"
(( saw_aws_access_key == 1 )) || sync_kv "AWS_ACCESS_KEY_ID" "$aws_access_key" >> "$tmp"
(( saw_aws_secret_key == 1 )) || sync_kv "AWS_SECRET_ACCESS_KEY" "$aws_secret_key" >> "$tmp"
(( saw_silo_secret == 1 )) || sync_kv "SILO_HMAC_SECRET_KEY" "$silo_secret" >> "$tmp"
(( saw_live_secret == 1 )) || sync_kv "LIVE_SERVER_SECRET_KEY" "$live_secret" >> "$tmp"
(( saw_database_url == 1 )) || sync_kv "DATABASE_URL" "$database_url" >> "$tmp"
(( saw_redis_url == 1 )) || sync_kv "REDIS_URL" "$redis_url" >> "$tmp"
(( saw_amqp_url == 1 )) || sync_kv "AMQP_URL" "$amqp_url" >> "$tmp"
(( saw_postgres_user == 1 )) || sync_kv "POSTGRES_USER" "$postgres_user" >> "$tmp"
(( saw_postgres_db == 1 )) || sync_kv "POSTGRES_DB" "$postgres_db" >> "$tmp"
(( saw_postgres_host == 1 )) || sync_kv "POSTGRES_HOST" "$postgres_host" >> "$tmp"
(( saw_redis_host == 1 )) || sync_kv "REDIS_HOST" "$redis_host" >> "$tmp"
(( saw_rabbitmq_host == 1 )) || sync_kv "RABBITMQ_HOST" "$rabbitmq_host" >> "$tmp"
(( saw_rabbitmq_default_user == 1 )) || sync_kv "RABBITMQ_DEFAULT_USER" "$rabbitmq_user" >> "$tmp"
(( saw_rabbitmq_default_vhost == 1 )) || sync_kv "RABBITMQ_DEFAULT_VHOST" "$rabbitmq_vhost" >> "$tmp"
(( saw_rabbitmq_vhost == 1 )) || sync_kv "RABBITMQ_VHOST" "$rabbitmq_vhost" >> "$tmp"
(( saw_aws_s3_bucket_name == 1 )) || sync_kv "AWS_S3_BUCKET_NAME" "$aws_s3_bucket_name" >> "$tmp"
(( saw_bucket_name == 1 )) || sync_kv "BUCKET_NAME" "$bucket_name" >> "$tmp"

mv "$tmp" "$env_file"
chmod 600 "$env_file" 2>/dev/null || true

printf 'Updated: %s\n' "$env_file"
if (( passwords_changed == 1 )); then
  echo "Plane passwords generated/refreshed (POSTGRES_PASSWORD, REDIS_PASSWORD, RABBITMQ_DEFAULT_PASS)."
else
  echo "Plane passwords kept (use --force-passwords to rotate)."
fi
if (( secrets_changed == 1 )); then
  echo "Plane secrets generated/refreshed (SECRET_KEY, AWS/SILO/LIVE secrets)."
else
  echo "Plane secrets kept (use --force-secrets to rotate)."
fi

echo "Dependent URLs synchronized when needed: DATABASE_URL, REDIS_URL, AMQP_URL."
if (( infra_sync_applied == 1 )); then
  echo "Infra-derived Plane values synchronized from: $infra_env_file"
elif (( no_infra_sync == 0 )); then
  echo "Infra sync not applied (missing or unresolved values in: $infra_env_file)"
else
  echo "Infra sync disabled (--no-infra-sync)."
fi
