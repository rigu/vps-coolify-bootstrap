#!/usr/bin/env bash
# prepare-existing-server.sh — Install prerequisites on an existing server
# that was NOT provisioned via cloud-init/user-data.
#
# This script installs the packages and applies the kernel/fail2ban config
# that cloud-init would normally handle at first boot. Run it ONCE before
# running bootstrap-host.sh on an existing server.
#
# Usage:
#   sudo bash /opt/vps-coolify-bootstrap/scripts/prepare-existing-server.sh [bootstrap.env]
#
# The optional argument is the path to bootstrap.env (default:
# /etc/vps-coolify-bootstrap/bootstrap.env). It is used only to read SSH_PORT
# for the fail2ban jail config.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"
bootstrap_install_error_trap "prepare-existing-server.sh"

ENV_FILE="${1:-/etc/vps-coolify-bootstrap/bootstrap.env}"

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
  bootstrap_error "This script must be run as root (use sudo)."
  exit 1
fi

# ---------------------------------------------------------------------------
# Read SSH_PORT from env (optional, defaults to 2222)
# ---------------------------------------------------------------------------
SSH_PORT="2222"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  _ssh_port_val="$(sed -n "s/^SSH_PORT=\s*['\"]\\{0,1\\}\([^'\"]*\\)['\"]\\{0,1\\}\s*$/\\1/p" "$ENV_FILE" | tail -1)"
  if [[ -n "$_ssh_port_val" ]]; then
    SSH_PORT="$_ssh_port_val"
  fi
  bootstrap_info "Read SSH_PORT=$SSH_PORT from $ENV_FILE"
else
  bootstrap_warn "Env file not found ($ENV_FILE); using default SSH_PORT=$SSH_PORT"
fi

# ---------------------------------------------------------------------------
# Wait for any existing apt lock to release (max 60s)
# ---------------------------------------------------------------------------
bootstrap_info "Waiting for apt lock to be released (if held)..."
wait_count=0
while fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null; do
  if (( wait_count >= 60 )); then
    bootstrap_error "apt lock still held after 60s. Kill the blocking process manually."
    exit 1
  fi
  sleep 2
  wait_count=$((wait_count + 2))
done
bootstrap_success "apt lock is free."

# ---------------------------------------------------------------------------
# Detect Ubuntu codename and validate
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
if CODENAME="$(. /etc/os-release 2>/dev/null && echo "${UBUNTU_CODENAME:-}")"; then
  : # sourced successfully
else
  CODENAME=""
fi
# shellcheck source=/dev/null
if VERSION_ID="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}")"; then
  : # sourced successfully
else
  VERSION_ID=""
fi
bootstrap_info "Detected Ubuntu: codename=$CODENAME version=$VERSION_ID"

if [[ "$CODENAME" != "noble" ]]; then
  bootstrap_warn "This bootstrap is designed for Ubuntu 24.04 LTS (noble)."
  bootstrap_warn "Detected: $CODENAME ($VERSION_ID). Proceed with caution."
fi

# ---------------------------------------------------------------------------
# Install required packages
# ---------------------------------------------------------------------------
bootstrap_info "Installing required packages..."

PACKAGES=(
  ca-certificates
  curl
  git
  openssl
  python3
  ufw
  fail2ban
  unattended-upgrades
)

apt-get update -y
apt-get install -y "${PACKAGES[@]}"
bootstrap_success "All required packages installed."

# ---------------------------------------------------------------------------
# Kernel hardening (sysctl)
# ---------------------------------------------------------------------------
SYSCTL_FILE="/etc/sysctl.d/99-hardening.conf"
bootstrap_info "Writing kernel hardening config: $SYSCTL_FILE"

cat > "$SYSCTL_FILE" <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.tcp_syncookies=1
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
net.ipv6.conf.all.accept_source_route=0
net.ipv6.conf.default.accept_source_route=0
EOF

sysctl --system >/dev/null 2>&1
bootstrap_success "Kernel hardening applied."

# ---------------------------------------------------------------------------
# fail2ban jail config
# ---------------------------------------------------------------------------
JAIL_FILE="/etc/fail2ban/jail.d/10-bootstrap-sshd.local"
bootstrap_info "Writing fail2ban jail config: $JAIL_FILE (port=$SSH_PORT)"

install -d -m 755 /etc/fail2ban/jail.d
cat > "$JAIL_FILE" <<EOF
[DEFAULT]
backend = systemd
banaction = ufw
bantime = 1h
findtime = 10m
maxretry = 5
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 7d

[sshd]
enabled = true
port = ${SSH_PORT}
EOF

# Restart fail2ban if already running
if systemctl is-active --quiet fail2ban 2>/dev/null; then
  systemctl restart fail2ban
  bootstrap_info "fail2ban restarted with new jail config."
fi
bootstrap_success "fail2ban jail config written."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
bootstrap_success "Server preparation complete. You can now run:"
bootstrap_info "  sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh $ENV_FILE"
