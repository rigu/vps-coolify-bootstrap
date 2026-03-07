#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-/etc/vps-coolify-bootstrap/bootstrap.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: bootstrap env file not found: $ENV_FILE" >&2
  exit 1
fi
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"

# shellcheck disable=SC1090
source "$ENV_FILE"

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: missing required variable: $name" >&2
    exit 1
  fi
}

for v in SSH_PORT SSH_PUBLIC_KEY CREATE_USERS SUDO_USERS DOCKER_USERS COOLIFY_GROUP_USERS COOLIFY_PUBLIC_DOMAIN COOLIFY_ROOT_USERNAME COOLIFY_ROOT_USER_EMAIL COOLIFY_ROOT_USER_PASSWORD USER_PASSWORDS_ENCRYPTION_PASSWORD; do
  require_var "$v"
done

if (( ${#COOLIFY_ROOT_USER_PASSWORD} < 16 )); then
  echo "ERROR: COOLIFY_ROOT_USER_PASSWORD must be at least 16 chars" >&2
  exit 1
fi

if (( ${#USER_PASSWORDS_ENCRYPTION_PASSWORD} < 16 )); then
  echo "ERROR: USER_PASSWORDS_ENCRYPTION_PASSWORD must be at least 16 chars" >&2
  exit 1
fi

if [[ ! "$SSH_PUBLIC_KEY" =~ ^ssh-(ed25519|rsa|ecdsa-[^[:space:]]+)[[:space:]] ]]; then
  echo "ERROR: invalid SSH_PUBLIC_KEY format" >&2
  exit 1
fi

if [[ "$COOLIFY_PUBLIC_DOMAIN" =~ [[:space:]/] ]]; then
  echo "ERROR: COOLIFY_PUBLIC_DOMAIN must be a hostname without spaces or /" >&2
  exit 1
fi

PRIMARY_SUDO_USER="${PRIMARY_SUDO_USER:-}"
if [[ -z "$PRIMARY_SUDO_USER" ]]; then
  PRIMARY_SUDO_USER="$(split_csv_to_lines "$SUDO_USERS" | head -n1 || true)"
fi
PRIMARY_SUDO_USER="${PRIMARY_SUDO_USER:-deploy}"
SSH_KEY_ROTATE="${SSH_KEY_ROTATE:-0}"

if [[ "$SSH_KEY_ROTATE" != "0" && "$SSH_KEY_ROTATE" != "1" ]]; then
  echo "ERROR: SSH_KEY_ROTATE must be 0 or 1" >&2
  exit 1
fi

ensure_user_exists() {
  local user="$1"
  if ! id "$user" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$user"
  fi
}

ensure_ssh_key() {
  local user="$1"
  local home_dir
  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home_dir" ]] || return 0
  install -d -m 700 -o "$user" -g "$user" "$home_dir/.ssh"
  if [[ "$SSH_KEY_ROTATE" == "1" ]]; then
    printf '%s\n' "$SSH_PUBLIC_KEY" > "$home_dir/.ssh/authorized_keys"
    chown "$user:$user" "$home_dir/.ssh/authorized_keys"
    chmod 600 "$home_dir/.ssh/authorized_keys"
  else
    touch "$home_dir/.ssh/authorized_keys"
    chown "$user:$user" "$home_dir/.ssh/authorized_keys"
    chmod 600 "$home_dir/.ssh/authorized_keys"
    if ! grep -Fxq "$SSH_PUBLIC_KEY" "$home_dir/.ssh/authorized_keys"; then
      printf '%s\n' "$SSH_PUBLIC_KEY" >> "$home_dir/.ssh/authorized_keys"
    fi
  fi
}

sync_sshd_allowusers() {
  local allow_users
  local sshd_cfg
  sshd_cfg="/etc/ssh/sshd_config.d/10-bootstrap-hardening.conf"
  allow_users="$(split_csv_to_lines "$CREATE_USERS" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  [[ -n "$allow_users" ]] || return 0

  if [[ -f "$sshd_cfg" ]]; then
    if grep -q '^AllowUsers ' "$sshd_cfg"; then
      sed -i "s/^AllowUsers .*/AllowUsers ${allow_users}/" "$sshd_cfg"
    else
      printf 'AllowUsers %s\n' "$allow_users" >> "$sshd_cfg"
    fi
  fi
}

apply_sudo_policy() {
  local policy_file
  local tmp_file
  policy_file="/etc/sudoers.d/99-bootstrap-sudo-policy"
  tmp_file="$(mktemp)"

  printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$PRIMARY_SUDO_USER" > "$tmp_file"
  for user in $(split_csv_to_lines "$SUDO_USERS"); do
    if [[ "$user" != "$PRIMARY_SUDO_USER" ]]; then
      printf '%s ALL=(ALL:ALL) ALL\n' "$user" >> "$tmp_file"
    fi
  done

  chmod 440 "$tmp_file"
  if command -v visudo >/dev/null 2>&1; then
    visudo -cf "$tmp_file" >/dev/null
  fi
  install -o root -g root -m 440 "$tmp_file" "$policy_file"
  rm -f "$tmp_file"

  # Prevent cloud-init sudoers defaults from overriding long-term policy.
  rm -f /etc/sudoers.d/90-cloud-init-users /etc/sudoers.d/cloud-init-users 2>/dev/null || true
}

# Ensure all declared users exist.
for user in $(split_csv_to_lines "$CREATE_USERS"); do
  ensure_user_exists "$user"
  ensure_ssh_key "$user"
done

bash "$script_dir/ensure-user-passwords.sh" "$ENV_FILE"
sync_sshd_allowusers

# Make sure sshd runtime dir exists before validation/restart.
mkdir -p /run/sshd
chmod 755 /run/sshd
chown root:root /run/sshd
cat >/etc/tmpfiles.d/sshd.conf <<'TMP'
d /run/sshd 0755 root root -
TMP
systemd-tmpfiles --create /etc/tmpfiles.d/sshd.conf

sshd -t
systemctl restart ssh.socket
systemctl restart ssh

# Firewall hardening.
# This intentionally resets UFW to the bootstrap baseline.
ufw --force reset
ufw default deny incoming
ufw default deny routed
ufw default allow outgoing
ufw limit "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw delete allow 22/tcp || true
ufw delete allow OpenSSH || true
ufw logging low
ufw --force enable

systemctl enable --now fail2ban
systemctl enable --now unattended-upgrades

is_coolify_running() {
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi

  docker ps --format '{{.Names}} {{.Label "com.docker.compose.project"}}' 2>/dev/null | \
    awk '$1=="coolify" || $2=="coolify"{found=1} END{exit(found?0:1)}'
}

if ! is_coolify_running; then
  export DEBIAN_FRONTEND=noninteractive
  # Official Coolify installer path. Trade-off: remote script execution via curl|bash.
  # Detection assumes container name `coolify` or compose project label `coolify`.
  env \
    ROOT_USERNAME="$COOLIFY_ROOT_USERNAME" \
    ROOT_USER_EMAIL="$COOLIFY_ROOT_USER_EMAIL" \
    ROOT_USER_PASSWORD="$COOLIFY_ROOT_USER_PASSWORD" \
    bash -c 'curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash'
fi

groupadd -f coolify
if command -v docker >/dev/null 2>&1; then
  groupadd -f docker
fi

for user in $(split_csv_to_lines "$SUDO_USERS"); do
  ensure_user_exists "$user"
  usermod -aG sudo "$user"
done
apply_sudo_policy

for user in $(split_csv_to_lines "$COOLIFY_GROUP_USERS"); do
  ensure_user_exists "$user"
  usermod -aG coolify "$user"
done

if getent group docker >/dev/null 2>&1; then
  for user in $(split_csv_to_lines "$DOCKER_USERS"); do
    ensure_user_exists "$user"
    usermod -aG docker "$user"
  done
fi

# Docker published ports bypass UFW because Docker writes iptables rules directly.
if command -v ss >/dev/null 2>&1 && ss -tuln | awk '{print $4}' | grep -Eq '[:.]6001$|[:.]6002$'; then
  echo "WARNING: port 6001 and/or 6002 is listening on host."
  echo "WARNING: verify Docker/Coolify exposure and restrict unintended public access."
fi

echo "Coolify public URL: https://${COOLIFY_PUBLIC_DOMAIN}"
echo "bootstrap-host.sh completed successfully"
