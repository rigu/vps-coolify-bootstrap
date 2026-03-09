#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"

# shellcheck disable=SC1091
source "$script_dir/common.sh"
bootstrap_install_error_trap "$(basename "$0")"

usage() {
  cat <<'USAGE'
Automate internal service layer setup on a VPS:
- generate infra secrets env
- render infra compose/config files
- ensure Docker network exists
- sync runtime files to /srv/infra
- deploy stack and validate health/exposure

Usage:
  scripts/setup-infra.sh [options]

Options:
  --env-file <path>       Infra env file (default: bootstrap-artifacts/production-infra.env)
  --render-dir <path>     Render output directory (default: bootstrap-artifacts/infra)
  --runtime-dir <path>    Runtime directory on VPS (default: /srv/infra)
  --network-name <name>   Override network name from env (default: INFRA_NETWORK_NAME from env)
  --force-passwords       Force rotate infra passwords in generate step
  --force-secrets         Force rotate infra secrets in generate step
  --skip-generate         Skip generate-infra-secrets step
  --skip-render           Skip prepare-infra-compose step
  --skip-deploy           Skip docker compose up -d
  --skip-validate         Skip post-deploy validation
  --wait-seconds <n>      Health wait timeout in seconds (default: 120)
  -h, --help              Show help
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

to_abs_path() {
  local path="$1"
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$repo_root" "$path"
  fi
}

run_root() {
  if (( EUID == 0 )); then
    "$@"
    return
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    bootstrap_error "sudo is required for privileged operations (docker/network/runtime sync)."
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

env_file="bootstrap-artifacts/production-infra.env"
render_dir="bootstrap-artifacts/infra"
runtime_dir="/srv/infra"
network_name_override=""
force_passwords=0
force_secrets=0
skip_generate=0
skip_render=0
skip_deploy=0
skip_validate=0
wait_seconds=120

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      require_value_arg "--env-file" "${2:-}"
      env_file="${2:-}"
      shift 2
      ;;
    --render-dir)
      require_value_arg "--render-dir" "${2:-}"
      render_dir="${2:-}"
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
    --force-passwords)
      force_passwords=1
      shift
      ;;
    --force-secrets)
      force_secrets=1
      shift
      ;;
    --skip-generate)
      skip_generate=1
      shift
      ;;
    --skip-render)
      skip_render=1
      shift
      ;;
    --skip-deploy)
      skip_deploy=1
      shift
      ;;
    --skip-validate)
      skip_validate=1
      shift
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

if [[ "$env_file" == */ ]]; then
  bootstrap_error "--env-file must be a file path, not a directory path."
  exit 1
fi

if [[ "$render_dir" == */ ]]; then
  render_dir="${render_dir%/}"
fi

env_file="$(to_abs_path "$env_file")"
render_dir="$(to_abs_path "$render_dir")"

if [[ "$runtime_dir" != /* ]]; then
  runtime_dir="$repo_root/$runtime_dir"
fi

bootstrap_info "setup-infra parameters: env_file=${env_file}, render_dir=${render_dir}, runtime_dir=${runtime_dir}, wait_seconds=${wait_seconds}, skip_generate=${skip_generate}, skip_render=${skip_render}, skip_deploy=${skip_deploy}, skip_validate=${skip_validate}"

if ! command -v docker >/dev/null 2>&1; then
  bootstrap_error "docker command not found."
  exit 1
fi

gen_script="$repo_root/scripts/generate-infra-secrets.sh"
prep_script="$repo_root/scripts/prepare-infra-compose.sh"
for required_script in "$gen_script" "$prep_script"; do
  [[ -x "$required_script" ]] || {
    bootstrap_error "required script is missing or not executable: $required_script"
    exit 1
  }
done

if (( skip_generate == 0 )); then
  bootstrap_info "Running infra secret generation."
  gen_args=(--env-file "$env_file")
  (( force_passwords == 1 )) && gen_args+=(--force-passwords)
  (( force_secrets == 1 )) && gen_args+=(--force-secrets)
  bash "$gen_script" "${gen_args[@]}"
  bootstrap_success "Infra secret generation completed."
else
  bootstrap_warn "Skipping infra secret generation (--skip-generate)."
fi

if (( skip_render == 0 )); then
  bootstrap_info "Rendering infra compose/config files."
  bash "$prep_script" --env-file "$env_file" --output-dir "$render_dir" --overwrite
  bootstrap_success "Infra render completed."
else
  bootstrap_warn "Skipping infra render (--skip-render)."
fi

required_render_files=(
  "$render_dir/docker-compose.yml"
  "$render_dir/valkey.conf"
  "$render_dir/seaweedfs-s3-config.json"
  "$render_dir/postgres-apps-init.sh"
)
for file in "${required_render_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    bootstrap_error "missing rendered file: $file"
    exit 1
  fi
done

load_env_file_strict "$env_file"
INFRA_NETWORK_NAME="${network_name_override:-${INFRA_NETWORK_NAME:-infra}}"
POSTGRES_APPS_CONTAINER_NAME="${POSTGRES_APPS_CONTAINER_NAME:-postgres-apps}"
VALKEY_APPS_CONTAINER_NAME="${VALKEY_APPS_CONTAINER_NAME:-valkey-apps}"
RABBITMQ_PLANE_CONTAINER_NAME="${RABBITMQ_PLANE_CONTAINER_NAME:-rabbitmq-plane}"
SEAWEEDFS_PLANE_CONTAINER_NAME="${SEAWEEDFS_PLANE_CONTAINER_NAME:-seaweedfs-plane}"

for pvar in POSTGRES_APPS_HOST_PORT VALKEY_HOST_PORT RABBITMQ_AMQP_HOST_PORT RABBITMQ_UI_HOST_PORT SEAWEEDFS_S3_HOST_PORT; do
  if [[ -z "${!pvar:-}" ]]; then
    bootstrap_error "missing required port variable in env: $pvar"
    exit 1
  fi
done

if run_root docker network inspect "$INFRA_NETWORK_NAME" >/dev/null 2>&1; then
  bootstrap_success "Docker network already exists: $INFRA_NETWORK_NAME"
else
  run_root docker network create "$INFRA_NETWORK_NAME" >/dev/null
  bootstrap_success "Created Docker network: $INFRA_NETWORK_NAME"
fi

bootstrap_info "Synchronizing runtime files to $runtime_dir"
run_root install -d -m 750 -o root -g root "$runtime_dir"
run_root install -m 644 -o root -g root "$render_dir/docker-compose.yml" "$runtime_dir/docker-compose.yml"
# Keep runtime service configs readable by non-root container users.
# Parent directory remains root-owned (750), so host-side exposure stays constrained.
run_root install -m 644 -o root -g root "$render_dir/valkey.conf" "$runtime_dir/valkey.conf"
run_root install -m 644 -o root -g root "$render_dir/seaweedfs-s3-config.json" "$runtime_dir/seaweedfs-s3-config.json"
run_root install -m 755 -o root -g root "$render_dir/postgres-apps-init.sh" "$runtime_dir/postgres-apps-init.sh"
runtime_env_file="$runtime_dir/production-infra.env"
env_source_real="$(readlink -f "$env_file" 2>/dev/null || printf '%s' "$env_file")"
env_target_real="$(readlink -f "$runtime_env_file" 2>/dev/null || printf '%s' "$runtime_env_file")"
if [[ "$env_source_real" == "$env_target_real" ]]; then
  bootstrap_info "Env file already points to runtime target; enforcing owner/mode only."
  run_root chown root:root "$runtime_env_file"
  run_root chmod 600 "$runtime_env_file"
else
  run_root install -m 600 -o root -g root "$env_file" "$runtime_env_file"
fi
bootstrap_success "Runtime files synchronized to $runtime_dir"

if (( skip_deploy == 0 )); then
  bootstrap_info "Deploying internal service layer with docker compose."
  run_root docker compose -f "$runtime_dir/docker-compose.yml" --env-file "$runtime_dir/production-infra.env" up -d
  bootstrap_success "Infra stack deployed."
else
  bootstrap_warn "Skipping deploy (--skip-deploy)."
fi

if (( skip_validate == 0 )); then
  bootstrap_info "Running infra validation checks."

  if ! run_root docker network inspect "$INFRA_NETWORK_NAME" >/dev/null 2>&1; then
    bootstrap_error "infra network missing after setup: $INFRA_NETWORK_NAME"
    exit 1
  fi
  bootstrap_success "Network validation passed: $INFRA_NETWORK_NAME"

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
else
  bootstrap_warn "Skipping validation (--skip-validate)."
fi

bootstrap_success "setup-infra.sh completed successfully."
bootstrap_info "Next: deploy Plane using docs/install-plane-on-coolify.md"
