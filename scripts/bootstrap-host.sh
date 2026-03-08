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

load_env_file_strict "$ENV_FILE"

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

if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: SSH_PORT must be numeric (1-65535)" >&2
  exit 1
fi
ssh_port_num=$((10#$SSH_PORT))
if (( ssh_port_num < 1 || ssh_port_num > 65535 )); then
  echo "ERROR: SSH_PORT must be between 1 and 65535" >&2
  exit 1
fi

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

if [[ ! "$COOLIFY_ROOT_USER_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
  echo "ERROR: COOLIFY_ROOT_USER_EMAIL must be a valid email format" >&2
  exit 1
fi

if [[ ! "$COOLIFY_ROOT_USERNAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: COOLIFY_ROOT_USERNAME must match ^[A-Za-z0-9._-]+$" >&2
  exit 1
fi

for user in $(split_csv_to_lines "$CREATE_USERS"); do
  if [[ "$user" == *:* ]]; then
    echo "ERROR: CREATE_USERS contains invalid username (colon not allowed): $user" >&2
    exit 1
  fi
  if ! is_valid_unix_username "$user"; then
    echo "ERROR: CREATE_USERS contains invalid UNIX username: $user" >&2
    exit 1
  fi
done

COOLIFY_SUDO_NOPASSWD_USER="${COOLIFY_SUDO_NOPASSWD_USER:-coolify}"
if ! is_valid_unix_username "$COOLIFY_SUDO_NOPASSWD_USER"; then
  echo "ERROR: COOLIFY_SUDO_NOPASSWD_USER is not a valid UNIX username: $COOLIFY_SUDO_NOPASSWD_USER" >&2
  exit 1
fi

# Ensure the dedicated Coolify SSH/sudo user is always managed.
CREATE_USERS="$(csv_append_unique "$CREATE_USERS" "$COOLIFY_SUDO_NOPASSWD_USER")"
SUDO_USERS="$(csv_append_unique "$SUDO_USERS" "$COOLIFY_SUDO_NOPASSWD_USER")"
DOCKER_USERS="$(csv_append_unique "$DOCKER_USERS" "$COOLIFY_SUDO_NOPASSWD_USER")"
COOLIFY_GROUP_USERS="$(csv_append_unique "$COOLIFY_GROUP_USERS" "$COOLIFY_SUDO_NOPASSWD_USER")"

validate_user_list_subset() {
  local list_name="$1"
  local list_value="$2"
  local user=""
  for user in $(split_csv_to_lines "$list_value"); do
    if [[ "$user" == *:* ]]; then
      echo "ERROR: ${list_name} contains invalid username (colon not allowed): $user" >&2
      exit 1
    fi
    if ! is_valid_unix_username "$user"; then
      echo "ERROR: ${list_name} contains invalid UNIX username: $user" >&2
      exit 1
    fi
    if ! csv_contains_value "$CREATE_USERS" "$user"; then
      echo "ERROR: ${list_name} contains user not present in CREATE_USERS: $user" >&2
      exit 1
    fi
  done
}

validate_user_list_subset "SUDO_USERS" "$SUDO_USERS"
validate_user_list_subset "DOCKER_USERS" "$DOCKER_USERS"
validate_user_list_subset "COOLIFY_GROUP_USERS" "$COOLIFY_GROUP_USERS"

PRIMARY_SUDO_USER="${PRIMARY_SUDO_USER:-}"
SECONDARY_SUDO_USER="${SECONDARY_SUDO_USER:-}"
if [[ -z "$PRIMARY_SUDO_USER" ]]; then
  PRIMARY_SUDO_USER="$(split_csv_to_lines "$SUDO_USERS" | head -n1 || true)"
fi
PRIMARY_SUDO_USER="${PRIMARY_SUDO_USER:-devops}"

if [[ -z "$PRIMARY_SUDO_USER" ]]; then
  echo "ERROR: PRIMARY_SUDO_USER resolved to empty value" >&2
  exit 1
fi

if ! is_valid_unix_username "$PRIMARY_SUDO_USER"; then
  echo "ERROR: PRIMARY_SUDO_USER is not a valid UNIX username: $PRIMARY_SUDO_USER" >&2
  exit 1
fi

if [[ -n "$SECONDARY_SUDO_USER" ]] && ! is_valid_unix_username "$SECONDARY_SUDO_USER"; then
  echo "ERROR: SECONDARY_SUDO_USER is not a valid UNIX username: $SECONDARY_SUDO_USER" >&2
  exit 1
fi

if ! csv_contains_value "$CREATE_USERS" "$PRIMARY_SUDO_USER"; then
  echo "ERROR: PRIMARY_SUDO_USER must be present in CREATE_USERS: $PRIMARY_SUDO_USER" >&2
  exit 1
fi

if [[ -n "$SECONDARY_SUDO_USER" ]] && ! csv_contains_value "$CREATE_USERS" "$SECONDARY_SUDO_USER"; then
  echo "ERROR: SECONDARY_SUDO_USER must be present in CREATE_USERS: $SECONDARY_SUDO_USER" >&2
  exit 1
fi

SSH_KEY_ROTATE="${SSH_KEY_ROTATE:-0}"

if [[ "$SSH_KEY_ROTATE" != "0" && "$SSH_KEY_ROTATE" != "1" ]]; then
  echo "ERROR: SSH_KEY_ROTATE must be 0 or 1" >&2
  exit 1
fi

CLOSE_COOLIFY_REALTIME_PORTS="${CLOSE_COOLIFY_REALTIME_PORTS:-}"
if [[ -z "$CLOSE_COOLIFY_REALTIME_PORTS" ]] && [[ -n "${ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS:-}" ]]; then
  # Backward compatibility with legacy variable.
  if [[ "$ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS" == "0" ]]; then
    CLOSE_COOLIFY_REALTIME_PORTS="true"
  elif [[ "$ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS" == "1" ]]; then
    CLOSE_COOLIFY_REALTIME_PORTS="false"
  fi
fi
CLOSE_COOLIFY_REALTIME_PORTS="${CLOSE_COOLIFY_REALTIME_PORTS:-false}"
case "$CLOSE_COOLIFY_REALTIME_PORTS" in
  true|false) ;;
  1) CLOSE_COOLIFY_REALTIME_PORTS="true" ;;
  0) CLOSE_COOLIFY_REALTIME_PORTS="false" ;;
  *)
    echo "ERROR: CLOSE_COOLIFY_REALTIME_PORTS must be true/false or 1/0" >&2
    exit 1
    ;;
esac

COOLIFY_REALTIME_DOMAIN="${COOLIFY_REALTIME_DOMAIN:-}"
if [[ -n "$COOLIFY_REALTIME_DOMAIN" ]] && [[ "$COOLIFY_REALTIME_DOMAIN" =~ [[:space:]/] ]]; then
  echo "ERROR: COOLIFY_REALTIME_DOMAIN must be a hostname without spaces or /" >&2
  exit 1
fi
if [[ "$CLOSE_COOLIFY_REALTIME_PORTS" == "true" ]] && [[ -z "$COOLIFY_REALTIME_DOMAIN" ]]; then
  echo "ERROR: COOLIFY_REALTIME_DOMAIN is required when CLOSE_COOLIFY_REALTIME_PORTS=true" >&2
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
  local ssh_key="$2"
  local home_dir
  [[ -n "$ssh_key" ]] || return 0
  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home_dir" ]] || return 0
  install -d -m 700 -o "$user" -g "$user" "$home_dir/.ssh"
  if [[ "$SSH_KEY_ROTATE" == "1" ]]; then
    printf '%s\n' "$ssh_key" > "$home_dir/.ssh/authorized_keys"
    chown "$user:$user" "$home_dir/.ssh/authorized_keys"
    chmod 600 "$home_dir/.ssh/authorized_keys"
  else
    touch "$home_dir/.ssh/authorized_keys"
    chown "$user:$user" "$home_dir/.ssh/authorized_keys"
    chmod 600 "$home_dir/.ssh/authorized_keys"
    if ! grep -Fxq "$ssh_key" "$home_dir/.ssh/authorized_keys"; then
      printf '%s\n' "$ssh_key" >> "$home_dir/.ssh/authorized_keys"
    fi
  fi
}

ensure_ssh_key_present() {
  local user="$1"
  local ssh_key="$2"
  local home_dir
  [[ -n "$ssh_key" ]] || return 0
  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home_dir" ]] || return 0
  install -d -m 700 -o "$user" -g "$user" "$home_dir/.ssh"
  touch "$home_dir/.ssh/authorized_keys"
  chown "$user:$user" "$home_dir/.ssh/authorized_keys"
  chmod 600 "$home_dir/.ssh/authorized_keys"
  if ! grep -Fxq "$ssh_key" "$home_dir/.ssh/authorized_keys"; then
    printf '%s\n' "$ssh_key" >> "$home_dir/.ssh/authorized_keys"
  fi
}

sync_sshd_allowusers() {
  local allow_users
  local sshd_cfg
  local tmp_cfg
  sshd_cfg="/etc/ssh/sshd_config.d/10-bootstrap-hardening.conf"
  allow_users="$(split_csv_to_lines "$CREATE_USERS" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  [[ -n "$allow_users" ]] || return 0

  if [[ ! -f "$sshd_cfg" ]]; then
    echo "ERROR: SSH hardening config not found: $sshd_cfg" >&2
    return 1
  fi

  tmp_cfg="$(mktemp)"
  if ! {
    grep -v '^AllowUsers ' "$sshd_cfg" > "$tmp_cfg" || true
    printf 'AllowUsers %s\n' "$allow_users" >> "$tmp_cfg"
    install -o root -g root -m 644 "$tmp_cfg" "$sshd_cfg"
  }; then
    rm -f "$tmp_cfg"
    return 1
  fi
  rm -f "$tmp_cfg"
}

cleanup_stale_sshd_port22_listeners() {
  local service_main_pid=""
  local pid=""
  local comm=""
  local cgroup_info=""
  local -a listener_pids=()

  if [[ "$SSH_PORT" == "22" ]]; then
    return 0
  fi

  if ! command -v ss >/dev/null 2>&1; then
    return 0
  fi

  service_main_pid="$(systemctl show -p MainPID --value ssh.service 2>/dev/null || true)"
  mapfile -t listener_pids < <(ss -lntp '( sport = :22 )' 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)

  for pid in "${listener_pids[@]}"; do
    [[ -n "$pid" && -d "/proc/$pid" ]] || continue
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    [[ "$comm" == "sshd" ]] || continue

    if [[ "$service_main_pid" =~ ^[0-9]+$ ]] && [[ "$pid" == "$service_main_pid" ]]; then
      continue
    fi

    cgroup_info="$(tr '\n' ' ' < "/proc/$pid/cgroup" 2>/dev/null || true)"
    if [[ "$cgroup_info" == *"ssh.service"* ]]; then
      continue
    fi

    echo "WARNING: terminating stale sshd listener on port 22 (pid=$pid)."
    kill "$pid" 2>/dev/null || true
  done

  sleep 1
  if ss -lnt '( sport = :22 )' 2>/dev/null | grep -q ':22'; then
    echo "WARNING: port 22 is still listening after stale-listener cleanup."
    echo "WARNING: inspect ssh.socket and SSH config fragments for extra listeners."
  fi
}

add_docker_user_rule_if_missing() {
  local table_bin="$1"
  shift
  if ! "$table_bin" -C DOCKER-USER "$@" >/dev/null 2>&1; then
    "$table_bin" -I DOCKER-USER 1 "$@"
  fi
}

remove_docker_user_rule_if_present() {
  local table_bin="$1"
  shift
  while "$table_bin" -C DOCKER-USER "$@" >/dev/null 2>&1; do
    "$table_bin" -D DOCKER-USER "$@" >/dev/null 2>&1 || true
  done
}

sync_coolify_realtime_port_guards() {
  if ! command -v iptables >/dev/null 2>&1; then
    echo "WARNING: iptables is not available; cannot manage DOCKER-USER guards for 6001/6002."
    return 0
  fi

  if ! iptables -nL DOCKER-USER >/dev/null 2>&1; then
    echo "WARNING: DOCKER-USER chain is unavailable; cannot manage guards for 6001/6002."
    return 0
  fi

  if [[ "$CLOSE_COOLIFY_REALTIME_PORTS" == "true" ]]; then
    # Drop public forwarded traffic to Coolify realtime ports by default.
    add_docker_user_rule_if_missing iptables -p tcp -m multiport --dports 6001,6002 -j DROP
    add_docker_user_rule_if_missing iptables -p tcp -m multiport --dports 6001,6002 -s 127.0.0.1/32 -j RETURN
    add_docker_user_rule_if_missing iptables -p tcp -m multiport --dports 6001,6002 -s 10.0.0.0/8 -j RETURN
    add_docker_user_rule_if_missing iptables -p tcp -m multiport --dports 6001,6002 -s 172.16.0.0/12 -j RETURN
    add_docker_user_rule_if_missing iptables -p tcp -m multiport --dports 6001,6002 -s 192.168.0.0/16 -j RETURN
    add_docker_user_rule_if_missing iptables -p tcp -m multiport --dports 6001,6002 -s 100.64.0.0/10 -j RETURN
  else
    remove_docker_user_rule_if_present iptables -p tcp -m multiport --dports 6001,6002 -s 100.64.0.0/10 -j RETURN
    remove_docker_user_rule_if_present iptables -p tcp -m multiport --dports 6001,6002 -s 192.168.0.0/16 -j RETURN
    remove_docker_user_rule_if_present iptables -p tcp -m multiport --dports 6001,6002 -s 172.16.0.0/12 -j RETURN
    remove_docker_user_rule_if_present iptables -p tcp -m multiport --dports 6001,6002 -s 10.0.0.0/8 -j RETURN
    remove_docker_user_rule_if_present iptables -p tcp -m multiport --dports 6001,6002 -s 127.0.0.1/32 -j RETURN
    remove_docker_user_rule_if_present iptables -p tcp -m multiport --dports 6001,6002 -j DROP
  fi

  if command -v ip6tables >/dev/null 2>&1 && ip6tables -nL DOCKER-USER >/dev/null 2>&1; then
    if [[ "$CLOSE_COOLIFY_REALTIME_PORTS" == "true" ]]; then
      add_docker_user_rule_if_missing ip6tables -p tcp -m multiport --dports 6001,6002 -j DROP
      add_docker_user_rule_if_missing ip6tables -p tcp -m multiport --dports 6001,6002 -s ::1/128 -j RETURN
      add_docker_user_rule_if_missing ip6tables -p tcp -m multiport --dports 6001,6002 -s fc00::/7 -j RETURN
      add_docker_user_rule_if_missing ip6tables -p tcp -m multiport --dports 6001,6002 -s fe80::/10 -j RETURN
    else
      remove_docker_user_rule_if_present ip6tables -p tcp -m multiport --dports 6001,6002 -s fe80::/10 -j RETURN
      remove_docker_user_rule_if_present ip6tables -p tcp -m multiport --dports 6001,6002 -s fc00::/7 -j RETURN
      remove_docker_user_rule_if_present ip6tables -p tcp -m multiport --dports 6001,6002 -s ::1/128 -j RETURN
      remove_docker_user_rule_if_present ip6tables -p tcp -m multiport --dports 6001,6002 -j DROP
    fi
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

delete_env_kv() {
  local file="$1"
  local key="$2"
  sed -i "/^${key}=/d" "$file"
}

configure_coolify_realtime_domain() {
  local coolify_env="/data/coolify/source/.env"
  local changed=0
  local current=""
  if [[ ! -f "$coolify_env" ]]; then
    echo "WARNING: $coolify_env not found; cannot manage realtime host env automatically."
    return 0
  fi

  if [[ -n "$COOLIFY_REALTIME_DOMAIN" ]]; then
    current="$(sed -n 's/^PUSHER_HOST=//p' "$coolify_env" | tail -n1 || true)"
    if [[ "$current" != "$COOLIFY_REALTIME_DOMAIN" ]]; then
      set_env_kv "$coolify_env" "PUSHER_HOST" "$COOLIFY_REALTIME_DOMAIN"
      changed=1
    fi

    current="$(sed -n 's/^PUSHER_PORT=//p' "$coolify_env" | tail -n1 || true)"
    if [[ "$current" != "443" ]]; then
      set_env_kv "$coolify_env" "PUSHER_PORT" "443"
      changed=1
    fi

    current="$(sed -n 's/^PUSHER_SCHEME=//p' "$coolify_env" | tail -n1 || true)"
    if [[ "$current" != "https" ]]; then
      set_env_kv "$coolify_env" "PUSHER_SCHEME" "https"
      changed=1
    fi

    echo "INFO: configured Coolify realtime host ${COOLIFY_REALTIME_DOMAIN} (PUSHER_PORT=443, PUSHER_SCHEME=https)."
  else
    if grep -qE '^PUSHER_HOST=' "$coolify_env"; then
      delete_env_kv "$coolify_env" "PUSHER_HOST"
      changed=1
    fi
    if grep -qE '^PUSHER_PORT=' "$coolify_env"; then
      delete_env_kv "$coolify_env" "PUSHER_PORT"
      changed=1
    fi
    if grep -qE '^PUSHER_SCHEME=' "$coolify_env"; then
      delete_env_kv "$coolify_env" "PUSHER_SCHEME"
      changed=1
    fi
  fi

  if (( changed == 1 )) && command -v docker >/dev/null 2>&1; then
    if docker ps --format '{{.Names}}' | grep -qx 'coolify'; then
      docker restart coolify >/dev/null 2>&1 || true
    fi
    if docker ps --format '{{.Names}}' | grep -qx 'coolify-realtime'; then
      docker restart coolify-realtime >/dev/null 2>&1 || true
    fi
  fi
}

apply_sudo_policy() {
  local policy_file
  local tmp_file
  local user
  policy_file="/etc/sudoers.d/99-bootstrap-sudo-policy"
  tmp_file="$(mktemp)"

  if ! {
    : > "$tmp_file"
    for user in $(split_csv_to_lines "$SUDO_USERS"); do
      if [[ "$user" == "$PRIMARY_SUDO_USER" || "$user" == "$COOLIFY_SUDO_NOPASSWD_USER" ]]; then
        printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$user" >> "$tmp_file"
      else
        printf '%s ALL=(ALL:ALL) ALL\n' "$user" >> "$tmp_file"
      fi
    done

    chmod 440 "$tmp_file"
    if command -v visudo >/dev/null 2>&1; then
      visudo -cf "$tmp_file" >/dev/null
    fi
    install -o root -g root -m 440 "$tmp_file" "$policy_file"
  }; then
    rm -f "$tmp_file"
    return 1
  fi
  rm -f "$tmp_file"

  # Prevent VPS init sudoers defaults from overriding long-term policy.
  rm -f /etc/sudoers.d/90-cloud-init-users /etc/sudoers.d/cloud-init-users 2>/dev/null || true
}

# Ensure all declared users exist.
for user in $(split_csv_to_lines "$CREATE_USERS"); do
  ensure_user_exists "$user"
  ensure_ssh_key "$user" "$SSH_PUBLIC_KEY"
done
ensure_ssh_key "$COOLIFY_SUDO_NOPASSWD_USER" "$SSH_PUBLIC_KEY"

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

# Ubuntu 24.04 defaults to ssh.socket (systemd socket activation).
# Socket activation + sshd_config Port directive can conflict, causing sshd
# to not listen on the custom port. Disable socket activation and use the
# classic ssh.service for reliable custom-port operation.
systemctl daemon-reload
systemctl disable --now ssh.socket 2>/dev/null || true
rm -f /etc/systemd/system/ssh.socket.d/override.conf
if [[ -d /etc/systemd/system/ssh.socket.d ]] && \
   [[ -z "$(ls -A /etc/systemd/system/ssh.socket.d 2>/dev/null)" ]]; then
  rmdir /etc/systemd/system/ssh.socket.d 2>/dev/null || true
fi
systemctl daemon-reload
sshd -t
systemctl enable --now ssh.service
systemctl restart ssh.service
cleanup_stale_sshd_port22_listeners

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

sync_coolify_localhost_ssh_user() {
  local key_dir="/data/coolify/ssh/keys"
  local key_path="${key_dir}/id.${COOLIFY_SUDO_NOPASSWD_USER}@host.docker.internal"
  local key_pub_path="${key_path}.pub"
  local key_pub=""
  local attempt=0

  if ! command -v docker >/dev/null 2>&1; then
    echo "WARNING: docker not found; skipping Coolify localhost SSH user sync."
    return 0
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx 'coolify'; then
    echo "WARNING: coolify container is not running; skipping localhost SSH user sync."
    return 0
  fi

  install -d -m 750 "$key_dir"
  chown 9999:root "$key_dir" 2>/dev/null || true
  if [[ ! -s "$key_path" ]] || [[ ! -s "$key_pub_path" ]]; then
    rm -f "$key_path" "$key_pub_path"
    ssh-keygen -t ed25519 -a 100 -f "$key_path" -q -N "" -C "coolify-localhost"
  fi
  chown 9999:root "$key_path" "$key_pub_path" 2>/dev/null || true
  chmod 600 "$key_path" 2>/dev/null || true
  chmod 644 "$key_pub_path" 2>/dev/null || true

  key_pub="$(cat "$key_pub_path" 2>/dev/null || true)"
  if [[ -n "$key_pub" ]]; then
    ensure_ssh_key_present "$COOLIFY_SUDO_NOPASSWD_USER" "$key_pub"
  fi

  while (( attempt < 15 )); do
    if docker exec -i \
      -e BOOTSTRAP_COOLIFY_SSH_USER="$COOLIFY_SUDO_NOPASSWD_USER" \
      -e BOOTSTRAP_COOLIFY_SSH_PORT="$SSH_PORT" \
      coolify php <<'PHP'
<?php
chdir('/var/www/html');
require '/var/www/html/vendor/autoload.php';
$app = require '/var/www/html/bootstrap/app.php';
$kernel = $app->make(\Illuminate\Contracts\Console\Kernel::class);
$kernel->bootstrap();

$targetUser = preg_replace('/[^A-Za-z0-9_-]/', '', (string) getenv('BOOTSTRAP_COOLIFY_SSH_USER'));
$targetPort = (int) getenv('BOOTSTRAP_COOLIFY_SSH_PORT');
if ($targetUser === '' || $targetPort < 1 || $targetPort > 65535) {
    fwrite(STDERR, "invalid bootstrap Coolify SSH user/port\n");
    exit(11);
}

$server = \App\Models\Server::find(0);
if (! $server) {
    fwrite(STDERR, "Coolify localhost server (id=0) not found\n");
    exit(12);
}

$keyPath = '/var/www/html/storage/app/ssh/keys/id.' . $targetUser . '@host.docker.internal';
if (! is_file($keyPath)) {
    fwrite(STDERR, "Coolify key file missing: $keyPath\n");
    exit(13);
}
$keyContent = trim((string) file_get_contents($keyPath));
if ($keyContent === '') {
    fwrite(STDERR, "Coolify key file empty: $keyPath\n");
    exit(14);
}

$teamId = (int) ($server->team_id ?? 0);
$fingerprint = \App\Models\PrivateKey::generateFingerprint($keyContent);
$privateKey = null;

if (! empty($fingerprint)) {
    $privateKey = \App\Models\PrivateKey::query()
        ->where('team_id', $teamId)
        ->where('fingerprint', $fingerprint)
        ->first();
}

if (! $privateKey) {
    $privateKey = \App\Models\PrivateKey::find(0);
}

if (! $privateKey) {
    $privateKey = new \App\Models\PrivateKey();
    $privateKey->id = 0;
    $privateKey->team_id = $teamId;
}

if ((string) $privateKey->private_key !== $keyContent) {
    $privateKey->name = "localhost's key";
    $privateKey->description = 'Managed by VPS bootstrap for localhost SSH.';
    $privateKey->private_key = $keyContent;
    $privateKey->is_git_related = false;
    $privateKey->save();
    $privateKey->storeInFileSystem();
}

$server->user = $targetUser;
$server->ip = 'host.docker.internal';
$server->port = $targetPort;
$server->private_key_id = (int) $privateKey->id;
$server->save();

echo "bootstrap-coolify-localhost-user={$server->user}\n";
echo "bootstrap-coolify-localhost-port={$server->port}\n";
PHP
    then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 2
  done

  echo "WARNING: failed to synchronize Coolify localhost server SSH user automatically after retries."
  return 0
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

sync_coolify_localhost_ssh_user
configure_coolify_realtime_domain
sync_coolify_realtime_port_guards

# Docker published ports bypass UFW because Docker writes iptables rules directly.
if command -v ss >/dev/null 2>&1 && ss -tuln | awk '{print $4}' | grep -Eq '[:.]6001$|[:.]6002$'; then
  echo "WARNING: port 6001 and/or 6002 is listening on host."
  if [[ "$CLOSE_COOLIFY_REALTIME_PORTS" == "true" ]]; then
    echo "WARNING: DOCKER-USER guards were applied to block public ingress to 6001/6002."
    echo "WARNING: verify effective policy with: sudo iptables -S DOCKER-USER"
    echo "WARNING: realtime domain in use: ${COOLIFY_REALTIME_DOMAIN}"
  else
    echo "WARNING: realtime ports are intentionally public by configuration."
  fi
fi

echo "Coolify public URL: https://${COOLIFY_PUBLIC_DOMAIN}"
echo "bootstrap-host.sh completed successfully"
