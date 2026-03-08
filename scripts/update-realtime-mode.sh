#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/vps-coolify-bootstrap/bootstrap.env"
MODE=""
DOMAIN=""
CLEAR_DOMAIN=0
NO_REPLAY=0

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"
bootstrap_install_error_trap "update-realtime-mode.sh"

usage() {
  cat <<'USAGE'
Update realtime exposure policy in bootstrap env and apply it.

Usage:
  scripts/update-realtime-mode.sh --mode <public|closed> [--domain <hostname>] [--clear-domain] [--env-file <path>] [--no-replay]

Modes:
  public  -> CLOSE_COOLIFY_REALTIME_PORTS=false
  closed  -> CLOSE_COOLIFY_REALTIME_PORTS=true (requires effective realtime domain)

Examples:
  sudo bash scripts/update-realtime-mode.sh --mode public --clear-domain
  sudo bash scripts/update-realtime-mode.sh --mode public --domain realtime.example.com
  sudo bash scripts/update-realtime-mode.sh --mode closed --domain realtime.example.com

Behavior:
  - Updates /etc/vps-coolify-bootstrap/bootstrap.env (or --env-file path).
  - By default runs bootstrap replay to apply changes immediately.
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

set_env_kv() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp_file
  tmp_file="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { found=0 }
    index($0, key "=") == 1 { print key "=" value; found=1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$file" > "$tmp_file"
  cat "$tmp_file" > "$file"
  rm -f "$tmp_file"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      require_value_arg "--env-file" "${2:-}"
      ENV_FILE="${2:-}"
      shift 2
      ;;
    --mode)
      require_value_arg "--mode" "${2:-}"
      MODE="${2:-}"
      shift 2
      ;;
    --domain)
      require_value_arg "--domain" "${2:-}"
      DOMAIN="${2:-}"
      shift 2
      ;;
    --clear-domain)
      CLEAR_DOMAIN=1
      shift
      ;;
    --no-replay)
      NO_REPLAY=1
      shift
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

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  bootstrap_error "run as root (for example: sudo bash scripts/update-realtime-mode.sh ...)."
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  bootstrap_error "bootstrap env file not found: $ENV_FILE"
  exit 1
fi

case "$MODE" in
  public|closed) ;;
  *)
    bootstrap_error "--mode must be public or closed."
    usage >&2
    exit 1
    ;;
esac

load_env_file_strict "$ENV_FILE"

current_domain="${COOLIFY_REALTIME_DOMAIN:-}"

if (( CLEAR_DOMAIN == 1 )) && [[ -n "$DOMAIN" ]]; then
  bootstrap_error "--domain and --clear-domain are mutually exclusive."
  exit 1
fi

effective_domain="$current_domain"
if [[ -n "$DOMAIN" ]]; then
  effective_domain="$DOMAIN"
elif (( CLEAR_DOMAIN == 1 )); then
  effective_domain=""
fi

if [[ -n "$effective_domain" ]]; then
  if [[ "$effective_domain" == *"CHANGE_ME"* ]]; then
    bootstrap_error "COOLIFY_REALTIME_DOMAIN must not contain CHANGE_ME placeholder."
    exit 1
  fi
  if [[ "$effective_domain" == *"'"* ]]; then
    bootstrap_error "COOLIFY_REALTIME_DOMAIN must not contain single quotes."
    exit 1
  fi
  if [[ "$effective_domain" =~ [[:space:]/] ]]; then
    bootstrap_error "COOLIFY_REALTIME_DOMAIN must be a hostname without spaces or /."
    exit 1
  fi
fi

if [[ "$MODE" == "closed" ]] && [[ -z "$effective_domain" ]]; then
  bootstrap_error "closed mode requires realtime domain. Set --domain <hostname> or configure COOLIFY_REALTIME_DOMAIN first."
  exit 1
fi

if [[ "$MODE" == "closed" ]]; then
  set_env_kv "$ENV_FILE" "CLOSE_COOLIFY_REALTIME_PORTS" "true"
else
  set_env_kv "$ENV_FILE" "CLOSE_COOLIFY_REALTIME_PORTS" "false"
fi

# Keep the env format used by template-generated server file (single quotes).
set_env_kv "$ENV_FILE" "COOLIFY_REALTIME_DOMAIN" "'${effective_domain}'"
bootstrap_success "Updated realtime policy in $ENV_FILE (mode=${MODE}, domain=${effective_domain:-<empty>})."

if (( NO_REPLAY == 1 )); then
  bootstrap_warn "Skipping replay (--no-replay). Run bootstrap-host.sh manually to apply changes."
  exit 0
fi

bootstrap_success "Applying realtime policy via bootstrap replay..."
bash "$script_dir/bootstrap-host.sh" "$ENV_FILE"
bootstrap_success "Realtime policy update completed successfully."
