#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Emergency SSH recovery helper for provider console sessions.

Usage:
  scripts/recover-ssh-access.sh [--env-file <path>] [--close-22] [--unban-ip <ip>]

Behavior (default mode):
  - Reads SSH_PORT from bootstrap env (fallback: 22)
  - Creates /etc/ssh/sshd_config.d/10-port-recovery.conf with Port 22 + SSH_PORT
  - Disables ssh.socket and enforces ssh.service
  - Validates sshd config, restarts ssh.service
  - Opens UFW allow rules for 22 and SSH_PORT, then reloads UFW
  - Optionally unbans one IP from fail2ban sshd jail

Behavior (--close-22):
  - Removes Port 22 from 10-port-recovery.conf
  - Restarts ssh.service after validation
  - Removes UFW allow 22/tcp rule
USAGE
}

ENV_FILE="/etc/vps-coolify-bootstrap/bootstrap.env"
RECOVERY_CONF="/etc/ssh/sshd_config.d/10-port-recovery.conf"
CLOSE_22=0
UNBAN_IP=""

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"
bootstrap_install_error_trap "recover-ssh-access.sh"

require_value_arg() {
  local flag="$1"
  local maybe_value="${2:-}"
  if [[ -z "$maybe_value" || "$maybe_value" == -* ]]; then
    bootstrap_error "$flag requires a value."
    usage >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      require_value_arg "--env-file" "${2:-}"
      ENV_FILE="${2:-}"
      shift 2
      ;;
    --close-22)
      CLOSE_22=1
      shift
      ;;
    --unban-ip)
      require_value_arg "--unban-ip" "${2:-}"
      UNBAN_IP="${2:-}"
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

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  bootstrap_error "run as root (for example: sudo bash scripts/recover-ssh-access.sh)"
  exit 1
fi

SSH_PORT="22"
if [[ -f "$ENV_FILE" ]]; then
  load_env_file_strict "$ENV_FILE"
  SSH_PORT="${SSH_PORT:-22}"
else
  bootstrap_warn "env file not found: $ENV_FILE (fallback SSH_PORT=22)"
fi

if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || ((10#$SSH_PORT < 1 || 10#$SSH_PORT > 65535)); then
  bootstrap_error "invalid SSH_PORT value: ${SSH_PORT}"
  exit 1
fi

bootstrap_success "Starting SSH recovery workflow (SSH_PORT=${SSH_PORT}, CLOSE_22=${CLOSE_22})."
bootstrap_info "Recovery env file: $ENV_FILE"
if [[ -n "$UNBAN_IP" ]]; then
  bootstrap_info "Fail2ban unban target: $UNBAN_IP"
fi

if (( CLOSE_22 == 0 )); then
  {
    echo "Port 22"
    if [[ "$SSH_PORT" != "22" ]]; then
      echo "Port ${SSH_PORT}"
    fi
    echo "AddressFamily any"
    echo "ListenAddress 0.0.0.0"
    echo "ListenAddress ::"
  } > "$RECOVERY_CONF"
  chmod 644 "$RECOVERY_CONF"
  chown root:root "$RECOVERY_CONF"
  bootstrap_success "Recovery SSH config written: $RECOVERY_CONF"
else
  if [[ -f "$RECOVERY_CONF" ]]; then
    tmp_file="$(mktemp)"
    awk '$1 != "Port" || $2 != "22" { print }' "$RECOVERY_CONF" > "$tmp_file"
    install -o root -g root -m 644 "$tmp_file" "$RECOVERY_CONF"
    rm -f "$tmp_file"
    bootstrap_success "Removed Port 22 from recovery config."
  else
    bootstrap_warn "Recovery config not found; nothing to edit for --close-22."
  fi
fi

mkdir -p /run/sshd
chmod 755 /run/sshd
chown root:root /run/sshd
systemctl daemon-reload
systemctl disable --now ssh.socket 2>/dev/null || true
rm -f /etc/systemd/system/ssh.socket.d/override.conf
systemctl daemon-reload
bootstrap_success "ssh.socket disabled and daemon-reload completed."

sshd -t
bootstrap_success "sshd configuration validation passed."

systemctl enable --now ssh.service
systemctl restart ssh.service
bootstrap_success "ssh.service enabled and restarted."

if command -v ufw >/dev/null 2>&1; then
  bootstrap_info "Applying UFW recovery rules."
  if (( CLOSE_22 == 0 )); then
    ufw allow 22/tcp >/dev/null 2>&1 || true
    if [[ "$SSH_PORT" != "22" ]]; then
      ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || true
    fi
    ufw reload >/dev/null 2>&1 || true
    bootstrap_success "UFW rules opened for recovery SSH ports (22 and ${SSH_PORT})."
  else
    ufw delete allow 22/tcp >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
    bootstrap_success "UFW rule for 22/tcp removed and firewall reloaded."
  fi
else
  bootstrap_warn "ufw command not found; skipped firewall adjustments."
fi

if [[ -n "$UNBAN_IP" ]]; then
  if command -v fail2ban-client >/dev/null 2>&1; then
    fail2ban-client set sshd unbanip "$UNBAN_IP" >/dev/null 2>&1 || true
    bootstrap_success "Fail2ban unban attempted for IP: $UNBAN_IP"
  else
    bootstrap_warn "fail2ban-client not found; skipped unban for $UNBAN_IP"
  fi
fi

if command -v ss >/dev/null 2>&1; then
  ss -lntp | grep -E ":(22|${SSH_PORT})\\b" || true
fi
systemctl status ssh.service --no-pager -n 20 || true
bootstrap_success "SSH recovery workflow completed."
