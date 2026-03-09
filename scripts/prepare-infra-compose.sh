#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Render internal service layer files (compose + configs) from infra env.

Usage:
  scripts/prepare-infra-compose.sh [--env-file <path>] [--output-dir <dir>] [--overwrite]

Behavior:
  - If env file is missing, script creates parent directory and copies env/infra.env.example.
  - Renders output files: docker-compose.yml, valkey.conf, seaweedfs-s3-config.json, postgres-apps-init.sh
USAGE
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"

env_file="bootstrap-artifacts/production-infra.env"
output_dir="bootstrap-artifacts/infra"
overwrite=0

env_example_file="$repo_root/env/infra.env.example"
compose_template="$repo_root/templates/infra-compose.template.yml"
valkey_template="$repo_root/templates/infra-valkey.conf.template"
seaweedfs_template="$repo_root/templates/infra-seaweedfs-s3-config.template.json"
postgres_init_template="$repo_root/templates/infra-postgres-apps-init.sh"

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
    --output-dir)
      require_value_arg "--output-dir" "${2:-}"
      output_dir="${2:-}"
      shift 2
      ;;
    --overwrite)
      overwrite=1
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

if [[ "$env_file" != /* ]]; then
  env_file="$repo_root/$env_file"
fi
if [[ "$output_dir" != /* ]]; then
  output_dir="$repo_root/$output_dir"
fi

if [[ -d "$env_file" ]]; then
  echo "ERROR: --env-file points to a directory, expected a file: $env_file" >&2
  exit 1
fi

for path in "$env_example_file" "$compose_template" "$valkey_template" "$seaweedfs_template" "$postgres_init_template"; do
  if [[ ! -f "$path" ]]; then
    echo "ERROR: required file missing: $path" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "$env_file")"
if [[ ! -f "$env_file" ]]; then
  cp "$env_example_file" "$env_file"
  chmod 600 "$env_file"
  echo "Created: $env_file (from $env_example_file)"
fi

load_env_file_strict "$env_file"

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: missing required variable: $name" >&2
    exit 1
  fi
}

for v in \
  INFRA_NETWORK_NAME \
  POSTGRES_IMAGE VALKEY_IMAGE RABBITMQ_IMAGE SEAWEEDFS_IMAGE \
  POSTGRES_APPS_USER POSTGRES_APPS_PASSWORD POSTGRES_APPS_DB POSTGRES_PLANE_DB POSTGRES_DOCMOST_DB POSTGRES_APPS_HOST_PORT \
  APPS_VALKEY_PASSWORD VALKEY_HOST_PORT \
  PLANE_RABBITMQ_USER PLANE_RABBITMQ_PASSWORD PLANE_RABBITMQ_VHOST RABBITMQ_AMQP_HOST_PORT RABBITMQ_UI_HOST_PORT \
  PLANE_S3_ACCESS_KEY PLANE_S3_SECRET_KEY PLANE_S3_BUCKET SEAWEEDFS_S3_HOST_PORT; do
  require_var "$v"
done

POSTGRES_APPS_CONTAINER_NAME="${POSTGRES_APPS_CONTAINER_NAME:-postgres-apps}"
VALKEY_APPS_CONTAINER_NAME="${VALKEY_APPS_CONTAINER_NAME:-valkey-apps}"
RABBITMQ_PLANE_CONTAINER_NAME="${RABBITMQ_PLANE_CONTAINER_NAME:-rabbitmq-plane}"
SEAWEEDFS_PLANE_CONTAINER_NAME="${SEAWEEDFS_PLANE_CONTAINER_NAME:-seaweedfs-plane}"

for user_var in POSTGRES_APPS_USER PLANE_RABBITMQ_USER; do
  value="${!user_var}"
  if [[ ! "$value" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
    echo "ERROR: $user_var has invalid format: $value" >&2
    exit 1
  fi
done

for name_var in INFRA_NETWORK_NAME POSTGRES_APPS_DB POSTGRES_PLANE_DB POSTGRES_DOCMOST_DB PLANE_RABBITMQ_VHOST PLANE_S3_BUCKET \
  POSTGRES_APPS_CONTAINER_NAME VALKEY_APPS_CONTAINER_NAME RABBITMQ_PLANE_CONTAINER_NAME SEAWEEDFS_PLANE_CONTAINER_NAME; do
  value="${!name_var}"
  if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "ERROR: $name_var has invalid format: $value" >&2
    exit 1
  fi
done

for secret_var in POSTGRES_APPS_PASSWORD APPS_VALKEY_PASSWORD PLANE_RABBITMQ_PASSWORD PLANE_S3_ACCESS_KEY PLANE_S3_SECRET_KEY; do
  value="${!secret_var}"
  if [[ "$value" == *"CHANGE_ME"* ]]; then
    echo "ERROR: $secret_var still contains CHANGE_ME placeholder." >&2
    exit 1
  fi
done

validate_port() {
  local key="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "ERROR: $key must be numeric (1-65535)." >&2
    exit 1
  fi
  local num
  num=$((10#$value))
  if (( num < 1 || num > 65535 )); then
    echo "ERROR: $key must be between 1 and 65535." >&2
    exit 1
  fi
}

validate_port POSTGRES_APPS_HOST_PORT "$POSTGRES_APPS_HOST_PORT"
validate_port VALKEY_HOST_PORT "$VALKEY_HOST_PORT"
validate_port RABBITMQ_AMQP_HOST_PORT "$RABBITMQ_AMQP_HOST_PORT"
validate_port RABBITMQ_UI_HOST_PORT "$RABBITMQ_UI_HOST_PORT"
validate_port SEAWEEDFS_S3_HOST_PORT "$SEAWEEDFS_S3_HOST_PORT"

compose_output="$output_dir/docker-compose.yml"
valkey_output="$output_dir/valkey.conf"
seaweedfs_output="$output_dir/seaweedfs-s3-config.json"
postgres_init_output="$output_dir/postgres-apps-init.sh"
output_env="$output_dir/production-infra.env"

if (( overwrite == 0 )); then
  for path in "$compose_output" "$valkey_output" "$seaweedfs_output" "$postgres_init_output" "$output_env"; do
    if [[ -e "$path" ]]; then
      echo "ERROR: output already exists: $path (use --overwrite to replace)" >&2
      exit 1
    fi
  done
fi

mkdir -p "$output_dir"

render_template() {
  local src="$1"
  shift
  local content
  content="$(cat "$src")"
  while [[ $# -gt 1 ]]; do
    local token="$1"
    local value="$2"
    content="${content//${token}/${value}}"
    shift 2
  done
  printf '%s' "$content"
}

render_template "$compose_template" \
  INFRA_NETWORK_NAME_HERE "$INFRA_NETWORK_NAME" \
  POSTGRES_IMAGE_HERE "$POSTGRES_IMAGE" \
  VALKEY_IMAGE_HERE "$VALKEY_IMAGE" \
  RABBITMQ_IMAGE_HERE "$RABBITMQ_IMAGE" \
  SEAWEEDFS_IMAGE_HERE "$SEAWEEDFS_IMAGE" \
  POSTGRES_APPS_CONTAINER_NAME_HERE "$POSTGRES_APPS_CONTAINER_NAME" \
  POSTGRES_APPS_USER_HERE "$POSTGRES_APPS_USER" \
  POSTGRES_APPS_PASSWORD_HERE "$POSTGRES_APPS_PASSWORD" \
  POSTGRES_APPS_DB_HERE "$POSTGRES_APPS_DB" \
  POSTGRES_PLANE_DB_HERE "$POSTGRES_PLANE_DB" \
  POSTGRES_DOCMOST_DB_HERE "$POSTGRES_DOCMOST_DB" \
  POSTGRES_APPS_HOST_PORT_HERE "$POSTGRES_APPS_HOST_PORT" \
  VALKEY_APPS_CONTAINER_NAME_HERE "$VALKEY_APPS_CONTAINER_NAME" \
  VALKEY_HOST_PORT_HERE "$VALKEY_HOST_PORT" \
  RABBITMQ_PLANE_CONTAINER_NAME_HERE "$RABBITMQ_PLANE_CONTAINER_NAME" \
  PLANE_RABBITMQ_USER_HERE "$PLANE_RABBITMQ_USER" \
  PLANE_RABBITMQ_PASSWORD_HERE "$PLANE_RABBITMQ_PASSWORD" \
  PLANE_RABBITMQ_VHOST_HERE "$PLANE_RABBITMQ_VHOST" \
  RABBITMQ_AMQP_HOST_PORT_HERE "$RABBITMQ_AMQP_HOST_PORT" \
  RABBITMQ_UI_HOST_PORT_HERE "$RABBITMQ_UI_HOST_PORT" \
  SEAWEEDFS_PLANE_CONTAINER_NAME_HERE "$SEAWEEDFS_PLANE_CONTAINER_NAME" \
  SEAWEEDFS_S3_HOST_PORT_HERE "$SEAWEEDFS_S3_HOST_PORT" \
  > "$compose_output"

render_template "$valkey_template" \
  APPS_VALKEY_PASSWORD_HERE "$APPS_VALKEY_PASSWORD" \
  > "$valkey_output"

render_template "$seaweedfs_template" \
  PLANE_S3_ACCESS_KEY_HERE "$PLANE_S3_ACCESS_KEY" \
  PLANE_S3_SECRET_KEY_HERE "$PLANE_S3_SECRET_KEY" \
  PLANE_S3_BUCKET_HERE "$PLANE_S3_BUCKET" \
  > "$seaweedfs_output"

cp "$postgres_init_template" "$postgres_init_output"
cp "$env_file" "$output_env"

chmod 644 "$compose_output"
chmod 640 "$valkey_output" "$seaweedfs_output"
chmod 644 "$postgres_init_output"
chmod +x "$postgres_init_output"
chmod 600 "$output_env"

if grep -q '_HERE' "$compose_output" "$valkey_output" "$seaweedfs_output"; then
  echo "ERROR: unresolved template placeholders detected in rendered outputs." >&2
  exit 1
fi

cat <<MSG
Generated internal service layer files:
- $compose_output
- $valkey_output
- $seaweedfs_output
- $postgres_init_output
- $output_env

Deploy on server example:
1) sudo install -d -m 750 -o root -g root /srv/infra
2) sudo cp $output_dir/* /srv/infra/
3) cd /srv/infra && sudo docker compose --env-file ./production-infra.env up -d
MSG
