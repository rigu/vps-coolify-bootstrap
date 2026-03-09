#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$script_dir/common.sh"
bootstrap_install_error_trap "$(basename "$0")"

usage() {
  cat <<'USAGE'
Validate internal service layer state after setup-infra apply.

Usage:
  scripts/verify-infra-state.sh [options]

Options:
  --env-file <path>      Infra env file (default: /srv/infra/production-infra.env)
  --runtime-dir <path>   Runtime directory (default: /srv/infra)
  --network-name <name>  Override network name from env (default: INFRA_NETWORK_NAME from env)
  --wait-seconds <n>     Health wait timeout in seconds (default: 120)
  -h, --help             Show help
USAGE
}

require_value_arg() {
  local flag="$1"
  local maybe_value="${2:-}"
  if [[ -z "$maybe_value" || "$maybe_value" == -* ]]; then
    bootstrap_error "$flag requires a value."
    usage >&2
    exit 1
  fi
}

run_root() {
  if (( EUID == 0 )); then
    "$@"
    return
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    bootstrap_error "sudo is required for docker/network/port validation."
    exit 1
  fi
  sudo "$@"
}

print_container_health_log_tail() {
  local container="$1"
  local health_log
  local line

  health_log="$(run_root docker inspect --format '{{if .State.Health}}{{range .State.Health.Log}}{{println .ExitCode "|" .Output}}{{end}}{{end}}' "$container" 2>/dev/null | tail -n 5 || true)"
  [[ -n "$health_log" ]] || return 0

  bootstrap_warn "Recent healthcheck log for $container:"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    bootstrap_warn "  $line"
  done <<< "$health_log"
}

wait_for_container_health() {
  local container="$1"
  local timeout_seconds="$2"
  local elapsed=0
  local interval=2
  local health=""

  while (( elapsed <= timeout_seconds )); do
    health="$(run_root docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"
    case "$health" in
      healthy|none)
        bootstrap_success "Container health OK: $container ($health)"
        return 0
        ;;
      starting)
        sleep "$interval"
        elapsed=$((elapsed + interval))
        ;;
      *)
        bootstrap_error "Container health failed: $container ($health)"
        print_container_health_log_tail "$container"
        return 1
        ;;
    esac
  done

  bootstrap_error "Timed out waiting for healthy container: $container"
  print_container_health_log_tail "$container"
  return 1
}

validate_localhost_binding() {
  local port="$1"
  local listeners
  listeners="$(run_root ss -lntH 2>/dev/null | awk '{print $4}' | grep -E "(:|\\])${port}$" || true)"

  if [[ -z "$listeners" ]]; then
    bootstrap_error "No listener found for expected infra host port: $port"
    return 1
  fi

  if grep -Eq "^0\\.0\\.0\\.0:${port}$|^\\[::\\]:${port}$" <<<"$listeners"; then
    bootstrap_error "Port $port is publicly bound; expected localhost-only bind."
    return 1
  fi

  if ! grep -Eq "^127\\.0\\.0\\.1:${port}$|^\\[::1\\]:${port}$" <<<"$listeners"; then
    bootstrap_warn "Port $port listener is not classic loopback form; listeners: $listeners"
  else
    bootstrap_success "Localhost-only bind verified for port $port"
  fi
}

assert_file_exists() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    bootstrap_error "required file missing: $file"
    return 1
  fi
  bootstrap_success "File exists: $file"
}

assert_numeric_port_var() {
  local var_name="$1"
  local value="${!var_name:-}"
  if [[ -z "$value" ]]; then
    bootstrap_error "missing required port variable in env: $var_name"
    return 1
  fi
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    bootstrap_error "$var_name must be numeric: $value"
    return 1
  fi
  if (( value < 1 || value > 65535 )); then
    bootstrap_error "$var_name must be in range 1..65535: $value"
    return 1
  fi
}

env_file="/srv/infra/production-infra.env"
runtime_dir="/srv/infra"
network_name_override=""
wait_seconds=120

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      require_value_arg "--env-file" "${2:-}"
      env_file="${2:-}"
      shift 2
      ;;
    --runtime-dir)
      require_value_arg "--runtime-dir" "${2:-}"
      runtime_dir="${2:-}"
      shift 2
      ;;
    --network-name)
      require_value_arg "--network-name" "${2:-}"
      network_name_override="${2:-}"
      shift 2
      ;;
    --wait-seconds)
      require_value_arg "--wait-seconds" "${2:-}"
      wait_seconds="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      bootstrap_error "Unknown argument: $1"
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! "$wait_seconds" =~ ^[0-9]+$ ]] || (( wait_seconds < 0 )); then
  bootstrap_error "--wait-seconds must be a non-negative integer."
  exit 1
fi

if [[ "$env_file" != /* ]]; then
  env_file="$(pwd)/$env_file"
fi
if [[ "$runtime_dir" != /* ]]; then
  runtime_dir="$(pwd)/$runtime_dir"
fi

if [[ ! -f "$env_file" ]]; then
  bootstrap_error "infra env file not found: $env_file"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  bootstrap_error "docker command not found."
  exit 1
fi

bootstrap_info "Loading env from $env_file"
load_env_file_strict "$env_file"

INFRA_NETWORK_NAME="${network_name_override:-${INFRA_NETWORK_NAME:-infra}}"
POSTGRES_APPS_CONTAINER_NAME="${POSTGRES_APPS_CONTAINER_NAME:-postgres-apps}"
VALKEY_APPS_CONTAINER_NAME="${VALKEY_APPS_CONTAINER_NAME:-valkey-apps}"
RABBITMQ_PLANE_CONTAINER_NAME="${RABBITMQ_PLANE_CONTAINER_NAME:-rabbitmq-plane}"
SEAWEEDFS_PLANE_CONTAINER_NAME="${SEAWEEDFS_PLANE_CONTAINER_NAME:-seaweedfs-plane}"

for pvar in POSTGRES_APPS_HOST_PORT VALKEY_HOST_PORT RABBITMQ_AMQP_HOST_PORT RABBITMQ_UI_HOST_PORT SEAWEEDFS_S3_HOST_PORT; do
  assert_numeric_port_var "$pvar"
done

bootstrap_info "Validating runtime file set in $runtime_dir"
assert_file_exists "$runtime_dir/docker-compose.yml"
assert_file_exists "$runtime_dir/production-infra.env"
assert_file_exists "$runtime_dir/valkey.conf"
assert_file_exists "$runtime_dir/seaweedfs-s3-config.json"
assert_file_exists "$runtime_dir/postgres-apps-init.sh"

if ! run_root docker network inspect "$INFRA_NETWORK_NAME" >/dev/null 2>&1; then
  bootstrap_error "infra network missing: $INFRA_NETWORK_NAME"
  exit 1
fi
bootstrap_success "Network exists: $INFRA_NETWORK_NAME"

managed_containers=(
  "$POSTGRES_APPS_CONTAINER_NAME"
  "$VALKEY_APPS_CONTAINER_NAME"
  "$RABBITMQ_PLANE_CONTAINER_NAME"
  "$SEAWEEDFS_PLANE_CONTAINER_NAME"
)

for cn in "${managed_containers[@]}"; do
  if ! run_root docker ps --format '{{.Names}}' | grep -Fxq "$cn"; then
    bootstrap_error "container not running: $cn"
    exit 1
  fi
  wait_for_container_health "$cn" "$wait_seconds"
done

network_members="$(run_root docker network inspect "$INFRA_NETWORK_NAME" --format '{{range .Containers}}{{.Name}} {{end}}')"
for cn in "${managed_containers[@]}"; do
  if ! grep -Eq "(^|[[:space:]])${cn}([[:space:]]|$)" <<<"$network_members"; then
    bootstrap_error "container $cn is not attached to network $INFRA_NETWORK_NAME"
    exit 1
  fi
done
bootstrap_success "Container network attachment validation passed."

validate_localhost_binding "$POSTGRES_APPS_HOST_PORT"
validate_localhost_binding "$VALKEY_HOST_PORT"
validate_localhost_binding "$RABBITMQ_AMQP_HOST_PORT"
validate_localhost_binding "$RABBITMQ_UI_HOST_PORT"
validate_localhost_binding "$SEAWEEDFS_S3_HOST_PORT"
bootstrap_success "Host exposure validation passed (localhost-only infra ports)."

bootstrap_success "verify-infra-state.sh completed successfully."
