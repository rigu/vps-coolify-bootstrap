#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-/etc/vps-coolify-bootstrap/bootstrap.env}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$script_dir/common.sh"
bootstrap_install_error_trap "bootstrap-host.sh"

if [[ ! -f "$ENV_FILE" ]]; then
  bootstrap_error "bootstrap env file not found: $ENV_FILE"
  exit 1
fi

load_env_file_strict "$ENV_FILE"
bootstrap_success "Loaded bootstrap env from $ENV_FILE."

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    bootstrap_error "missing required variable: $name"
    exit 1
  fi
}

for v in SSH_PORT COOLIFY_PUBLIC_DOMAIN COOLIFY_ROOT_USERNAME COOLIFY_ROOT_USER_EMAIL COOLIFY_ROOT_USER_PASSWORD USER_PASSWORDS_ENCRYPTION_PASSWORD; do
  require_var "$v"
done

if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]]; then
  bootstrap_error "SSH_PORT must be numeric (1-65535)"
  exit 1
fi
ssh_port_num=$((10#$SSH_PORT))
if (( ssh_port_num < 1 || ssh_port_num > 65535 )); then
  bootstrap_error "SSH_PORT must be between 1 and 65535"
  exit 1
fi

if (( ${#COOLIFY_ROOT_USER_PASSWORD} < 16 )); then
  bootstrap_error "COOLIFY_ROOT_USER_PASSWORD must be at least 16 chars"
  exit 1
fi

if (( ${#USER_PASSWORDS_ENCRYPTION_PASSWORD} < 16 )); then
  bootstrap_error "USER_PASSWORDS_ENCRYPTION_PASSWORD must be at least 16 chars"
  exit 1
fi

SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
if [[ "$SSH_PUBLIC_KEY" == *"CHANGE_ME"* ]]; then
  SSH_PUBLIC_KEY=""
fi
if [[ -n "$SSH_PUBLIC_KEY" ]] && [[ ! "$SSH_PUBLIC_KEY" =~ ^ssh-(ed25519|rsa|ecdsa-[^[:space:]]+)[[:space:]] ]]; then
  bootstrap_error "invalid SSH_PUBLIC_KEY format"
  exit 1
fi
if [[ -z "$SSH_PUBLIC_KEY" ]]; then
  bootstrap_warn "SSH_PUBLIC_KEY is empty; bootstrap will not manage operator SSH keys for DEVOPS_USER/ADDITIONAL_SUDO_USERS."
fi

if [[ "$COOLIFY_PUBLIC_DOMAIN" =~ [[:space:]/] ]]; then
  bootstrap_error "COOLIFY_PUBLIC_DOMAIN must be a hostname without spaces or /"
  exit 1
fi

if [[ ! "$COOLIFY_ROOT_USER_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
  bootstrap_error "COOLIFY_ROOT_USER_EMAIL must be a valid email format"
  exit 1
fi

if [[ ! "$COOLIFY_ROOT_USERNAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  bootstrap_error "COOLIFY_ROOT_USERNAME must match ^[A-Za-z0-9._-]+$"
  exit 1
fi

DEVOPS_USER="${DEVOPS_USER:-devops}"
if ! is_valid_unix_username "$DEVOPS_USER"; then
  bootstrap_error "DEVOPS_USER is not a valid UNIX username: $DEVOPS_USER"
  exit 1
fi
if [[ "$DEVOPS_USER" == "root" ]]; then
  bootstrap_error "DEVOPS_USER must not be root."
  exit 1
fi

COOLIFY_SUDO_NOPASSWD_USER="${COOLIFY_SUDO_NOPASSWD_USER:-coolify}"
if ! is_valid_unix_username "$COOLIFY_SUDO_NOPASSWD_USER"; then
  bootstrap_error "COOLIFY_SUDO_NOPASSWD_USER is not a valid UNIX username: $COOLIFY_SUDO_NOPASSWD_USER"
  exit 1
fi
if [[ "$COOLIFY_SUDO_NOPASSWD_USER" == "root" ]]; then
  bootstrap_error "COOLIFY_SUDO_NOPASSWD_USER must not be root."
  exit 1
fi
if [[ "$DEVOPS_USER" == "$COOLIFY_SUDO_NOPASSWD_USER" ]]; then
  bootstrap_error "DEVOPS_USER and COOLIFY_SUDO_NOPASSWD_USER must be different users."
  exit 1
fi

MANAGED_USERS_CSV="$DEVOPS_USER"
MANAGED_USERS_CSV="$(csv_append_unique "$MANAGED_USERS_CSV" "$COOLIFY_SUDO_NOPASSWD_USER")"
for user in $(split_csv_to_lines "${ADDITIONAL_SUDO_USERS:-}"); do
  if [[ "$user" == "root" ]]; then
    bootstrap_error "ADDITIONAL_SUDO_USERS must not contain root."
    exit 1
  fi
  if [[ "$user" == *:* ]]; then
    bootstrap_error "ADDITIONAL_SUDO_USERS contains invalid username (colon not allowed): $user"
    exit 1
  fi
  if ! is_valid_unix_username "$user"; then
    bootstrap_error "ADDITIONAL_SUDO_USERS contains invalid UNIX username: $user"
    exit 1
  fi
  if [[ "$user" == "$COOLIFY_SUDO_NOPASSWD_USER" ]]; then
    bootstrap_error "ADDITIONAL_SUDO_USERS must not contain COOLIFY_SUDO_NOPASSWD_USER ($COOLIFY_SUDO_NOPASSWD_USER)."
    exit 1
  fi
  MANAGED_USERS_CSV="$(csv_append_unique "$MANAGED_USERS_CSV" "$user")"
done

SSH_KEY_ROTATE="${SSH_KEY_ROTATE:-0}"

if [[ "$SSH_KEY_ROTATE" != "0" && "$SSH_KEY_ROTATE" != "1" ]]; then
  bootstrap_error "SSH_KEY_ROTATE must be 0 or 1"
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
    bootstrap_error "CLOSE_COOLIFY_REALTIME_PORTS must be true/false or 1/0"
    exit 1
    ;;
esac

COOLIFY_REALTIME_DOMAIN="${COOLIFY_REALTIME_DOMAIN:-}"
if [[ -n "$COOLIFY_REALTIME_DOMAIN" ]] && [[ "$COOLIFY_REALTIME_DOMAIN" =~ [[:space:]/] ]]; then
  bootstrap_error "COOLIFY_REALTIME_DOMAIN must be a hostname without spaces or /"
  exit 1
fi
if [[ "$COOLIFY_REALTIME_DOMAIN" == *"CHANGE_ME"* ]]; then
  bootstrap_error "COOLIFY_REALTIME_DOMAIN must not contain CHANGE_ME placeholder."
  exit 1
fi
if [[ "$CLOSE_COOLIFY_REALTIME_PORTS" == "true" ]] && [[ -z "$COOLIFY_REALTIME_DOMAIN" ]]; then
  bootstrap_error "COOLIFY_REALTIME_DOMAIN is required when CLOSE_COOLIFY_REALTIME_PORTS=true"
  exit 1
fi
bootstrap_success "Input validation completed (SSH_PORT=${SSH_PORT}, DEVOPS_USER=${DEVOPS_USER}, CLOSE_COOLIFY_REALTIME_PORTS=${CLOSE_COOLIFY_REALTIME_PORTS})."

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

remove_ssh_key_exact_line() {
  local user="$1"
  local ssh_key="$2"
  local home_dir
  local auth_keys
  local tmp_file
  [[ -n "$ssh_key" ]] || return 0

  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home_dir" ]] || return 0
  auth_keys="$home_dir/.ssh/authorized_keys"
  [[ -f "$auth_keys" ]] || return 0

  tmp_file="$(mktemp)"
  grep -Fxv -- "$ssh_key" "$auth_keys" >"$tmp_file" || true
  install -o "$user" -g "$user" -m 600 "$tmp_file" "$auth_keys"
  rm -f "$tmp_file"
}

set_ssh_key_restricted_to_source_ranges() {
  local user="$1"
  local ssh_key="$2"
  local source_ranges="$3"
  local home_dir
  local auth_keys
  local tmp_file
  local entry
  [[ -n "$ssh_key" ]] || return 0
  [[ -n "$source_ranges" ]] || return 0

  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home_dir" ]] || return 0
  install -d -m 700 -o "$user" -g "$user" "$home_dir/.ssh"
  auth_keys="$home_dir/.ssh/authorized_keys"
  touch "$auth_keys"
  chown "$user:$user" "$auth_keys"
  chmod 600 "$auth_keys"

  # Remove previous entries for this key (restricted or unrestricted), then add
  # one canonical localhost/private-only entry for Coolify.
  tmp_file="$(mktemp)"
  grep -Fv -- "$ssh_key" "$auth_keys" >"$tmp_file" || true
  entry="from=\"${source_ranges}\",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc ${ssh_key}"
  printf '%s\n' "$entry" >>"$tmp_file"
  install -o "$user" -g "$user" -m 600 "$tmp_file" "$auth_keys"
  rm -f "$tmp_file"
}

sync_sshd_allowusers() {
  local allow_users
  local sshd_cfg
  local tmp_cfg
  sshd_cfg="/etc/ssh/sshd_config.d/10-bootstrap-hardening.conf"
  allow_users="$(split_csv_to_lines "$MANAGED_USERS_CSV" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  [[ -n "$allow_users" ]] || return 0

  if [[ ! -f "$sshd_cfg" ]]; then
    bootstrap_error "SSH hardening config not found: $sshd_cfg"
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

enforce_sshd_single_port() {
  local sshd_cfg="/etc/ssh/sshd_config.d/10-bootstrap-hardening.conf"
  local recovery_cfg="/etc/ssh/sshd_config.d/10-port-recovery.conf"
  local tmp_cfg=""
  local tmp_new=""
  local file=""
  local -a cfg_files=()

  install -d -m 755 /etc/ssh/sshd_config.d

  if [[ -f "$recovery_cfg" ]]; then
    rm -f "$recovery_cfg"
    bootstrap_warn "Removed recovery SSH config fragment: $recovery_cfg"
  fi

  tmp_cfg="$(mktemp)"
  tmp_new="$(mktemp)"
  if [[ -f "$sshd_cfg" ]]; then
    grep -Ev '^[[:space:]]*Port[[:space:]]+[0-9]+([[:space:]]+.*)?$' "$sshd_cfg" >"$tmp_cfg" || true
  else
    : >"$tmp_cfg"
  fi
  {
    printf 'Port %s\n' "$SSH_PORT"
    cat "$tmp_cfg"
  } >"$tmp_new"
  install -o root -g root -m 644 "$tmp_new" "$sshd_cfg"
  rm -f "$tmp_cfg" "$tmp_new"

  shopt -s nullglob
  cfg_files=(/etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf)
  shopt -u nullglob

  for file in "${cfg_files[@]}"; do
    [[ -f "$file" ]] || continue
    [[ "$file" == "$sshd_cfg" ]] && continue
    if grep -Eq '^[[:space:]]*Port[[:space:]]+[0-9]+([[:space:]]+.*)?$' "$file"; then
      sed -i -E 's/^[[:space:]]*Port[[:space:]]+([0-9]+([[:space:]]+.*)?)$/# bootstrap-disabled Port \1/' "$file"
      bootstrap_warn "Disabled legacy Port directives in $file to enforce SSH_PORT=$SSH_PORT."
    fi
  done

  bootstrap_success "SSH single-port policy prepared (Port $SSH_PORT only)."
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
  # Parse listener PIDs without grep exit-code side effects when no :22
  # listener exists (empty result is expected and should not trigger ERR trap).
  mapfile -t listener_pids < <(
    ss -lntp '( sport = :22 )' 2>/dev/null \
      | awk '{
          while (match($0, /pid=[0-9]+/)) {
            print substr($0, RSTART + 4, RLENGTH - 4)
            $0 = substr($0, RSTART + RLENGTH)
          }
        }' \
      | sort -u
  )

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

    bootstrap_warn "terminating stale sshd listener on port 22 (pid=$pid)."
    kill "$pid" 2>/dev/null || true
  done

  sleep 1
  if ss -lnt '( sport = :22 )' 2>/dev/null | grep -q ':22'; then
    bootstrap_error "port 22 is still listening after stale-listener cleanup."
    bootstrap_error "bootstrap expects only SSH_PORT=$SSH_PORT; inspect ssh.socket and SSH config fragments."
    return 1
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
    bootstrap_warn "iptables is not available; cannot manage DOCKER-USER guards for 6001/6002."
    return 0
  fi

  if ! iptables -nL DOCKER-USER >/dev/null 2>&1; then
    bootstrap_warn "DOCKER-USER chain is unavailable; cannot manage guards for 6001/6002."
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
  bootstrap_success "DOCKER-USER guards synchronized for 6001/6002 (CLOSE_COOLIFY_REALTIME_PORTS=${CLOSE_COOLIFY_REALTIME_PORTS})."
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
    bootstrap_warn "$coolify_env not found; cannot manage realtime host env automatically."
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

    bootstrap_success "Configured Coolify realtime host ${COOLIFY_REALTIME_DOMAIN} (PUSHER_PORT=443, PUSHER_SCHEME=https)."
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
  bootstrap_success "Realtime host env synchronization completed."
}

harden_coolify_compose_ports() {
  local base_compose="/data/coolify/source/docker-compose.yml"
  local prod_compose="/data/coolify/source/docker-compose.prod.yml"
  local hardener_py="${script_dir}/harden-coolify-compose-ports.py"
  local backup_base=""
  local backup_prod=""
  local result=0
  local backup_suffix=""
  local compose_err=""
  local -a compose_cmd=()

  if [[ "$CLOSE_COOLIFY_REALTIME_PORTS" != "true" ]]; then
    bootstrap_success "Compose hardening skipped because CLOSE_COOLIFY_REALTIME_PORTS=${CLOSE_COOLIFY_REALTIME_PORTS}."
    return 0
  fi

  if [[ ! -f "$base_compose" || ! -f "$prod_compose" ]]; then
    bootstrap_error "Coolify compose files not found: $base_compose / $prod_compose"
    return 1
  fi
  if [[ ! -f "$hardener_py" ]]; then
    bootstrap_error "compose hardener script not found: $hardener_py"
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    bootstrap_error "python3 is required for compose hardening with CLOSE_COOLIFY_REALTIME_PORTS=true"
    return 1
  fi

  backup_suffix="$(date +%Y%m%d%H%M%S)"
  backup_base="${base_compose}.bootstrap.bak.${backup_suffix}"
  backup_prod="${prod_compose}.bootstrap.bak.${backup_suffix}"
  cp "$base_compose" "$backup_base"
  cp "$prod_compose" "$backup_prod"

  # hardener returns:
  # - 0: no changes
  # - 10: changes applied
  # - 20: unsupported format
  # Capture non-zero codes without triggering ERR trap.
  if python3 "$hardener_py" "$base_compose" "$prod_compose"; then
    result=0
  else
    result=$?
  fi

  case "$result" in
    0)
      rm -f "$backup_base" "$backup_prod"
      bootstrap_success "Coolify compose already hardened; no changes required."
      ;;
    10)
      if docker compose version >/dev/null 2>&1; then
        compose_cmd=(docker compose)
      elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        compose_cmd=(docker-compose)
      else
        bootstrap_error "Docker Compose is required to apply hardened Coolify compose files."
        mv "$backup_base" "$base_compose"
        mv "$backup_prod" "$prod_compose"
        return 1
      fi

      normalize_coolify_env_ip_values || true
      compose_err="$(mktemp)"
      if ! "${compose_cmd[@]}" -f "$base_compose" -f "$prod_compose" up -d >"$compose_err" 2>&1; then
        cat "$compose_err" >&2 || true
        if sanitize_compose_parseaddr_cidr_and_retry "$compose_err" "$base_compose" "$prod_compose"; then
          bootstrap_warn "retrying Coolify redeploy after CIDR ParseAddr sanitization."
          if ! "${compose_cmd[@]}" -f "$base_compose" -f "$prod_compose" up -d >"$compose_err" 2>&1; then
            cat "$compose_err" >&2 || true
            rm -f "$compose_err"
            bootstrap_error "failed to redeploy Coolify after compose hardening; restoring backups."
            mv "$backup_base" "$base_compose"
            mv "$backup_prod" "$prod_compose"
            return 1
          fi
        else
          rm -f "$compose_err"
          bootstrap_error "failed to redeploy Coolify after compose hardening; restoring backups."
          mv "$backup_base" "$base_compose"
          mv "$backup_prod" "$prod_compose"
          return 1
        fi
      fi
      rm -f "$compose_err"
      rm -f "$backup_base" "$backup_prod"
      bootstrap_success "Coolify compose hardened and redeployed successfully."
      ;;
    20)
      bootstrap_error "unsupported Coolify compose format; refusing partial hardening."
      mv "$backup_base" "$base_compose"
      mv "$backup_prod" "$prod_compose"
      return 1
      ;;
    *)
      bootstrap_error "compose hardening failed with code $result; restoring backups."
      mv "$backup_base" "$base_compose"
      mv "$backup_prod" "$prod_compose"
      return 1
      ;;
  esac
}

replace_literal_in_file() {
  local file="$1"
  local old_value="$2"
  local new_value="$3"
  local status=0
  python3 - "$file" "$old_value" "$new_value" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
old_value = sys.argv[2]
new_value = sys.argv[3]

text = path.read_text(encoding="utf-8")
updated = text.replace(old_value, new_value)
if updated == text:
    raise SystemExit(3)
path.write_text(updated, encoding="utf-8")
raise SystemExit(0)
PY
  status=$?
  if [[ "$status" == "0" ]]; then
    return 0
  fi
  if [[ "$status" == "3" ]]; then
    return 1
  fi
  return "$status"
}

normalize_coolify_env_ip_values() {
  local coolify_env="/data/coolify/source/.env"
  local status=0
  [[ -f "$coolify_env" ]] || return 1

  python3 - "$coolify_env" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)
changed = False
out = []

for line in lines:
    raw = line.rstrip("\r\n")
    eol = line[len(raw):]
    stripped = raw.strip()
    if not stripped or stripped.startswith("#") or "=" not in raw:
        out.append(line)
        continue

    key, value = raw.split("=", 1)
    k = key.strip()
    if "IP" not in k or any(tag in k for tag in ("SUBNET", "POOL", "CIDR")):
        out.append(line)
        continue

    m = re.match(r"^(['\"]?)([0-9A-Fa-f:.]+)/([0-9]{1,3})(['\"]?)$", value.strip())
    if not m:
        out.append(line)
        continue

    q1, ip_addr, _prefix, q2 = m.groups()
    if q1 != q2:
        out.append(line)
        continue

    new_value = f"{q1}{ip_addr}{q2}"
    new_line = f"{key}={new_value}{eol}"
    out.append(new_line)
    changed = True

if changed:
    path.write_text("".join(out), encoding="utf-8")
    raise SystemExit(0)
raise SystemExit(3)
PY
  status=$?
  if [[ "$status" == "0" ]]; then
    bootstrap_warn "normalized CIDR suffixes for IP-like keys in $coolify_env before compose redeploy."
    return 0
  fi
  if [[ "$status" == "3" ]]; then
    return 1
  fi
  return "$status"
}

sanitize_compose_parseaddr_cidr_and_retry() {
  local err_file="$1"
  local base_compose="$2"
  local prod_compose="$3"
  local coolify_env="/data/coolify/source/.env"
  local value=""
  local sanitized=""
  local target=""
  local changed=0
  local daemon_changed=0
  local -a bad_values=()
  local -a targets=("$coolify_env" "$base_compose" "$prod_compose")
  local -a discovered_targets=()
  local -A seen_targets=()
  local -a search_roots=("/data/coolify" "/etc/docker")

  for target in "${targets[@]}"; do
    if [[ -n "$target" ]]; then
      seen_targets["$target"]=1
    fi
  done

  mapfile -t bad_values < <(
    grep -oE 'ParseAddr\("[^"]+/[0-9]{1,3}"\)' "$err_file" 2>/dev/null \
      | sed -E 's/^ParseAddr\("([^"]+)"\)$/\1/' \
      | sort -u
  )

  if [[ "${#bad_values[@]}" -eq 0 ]]; then
    if normalize_coolify_env_ip_values; then
      return 0
    fi
    return 1
  fi

  for value in "${bad_values[@]}"; do
    sanitized="${value%%/*}"
    if [[ -z "$sanitized" || "$sanitized" == "$value" ]]; then
      continue
    fi

    mapfile -t discovered_targets < <(grep -RIl --fixed-strings -- "$value" "${search_roots[@]}" 2>/dev/null || true)
    for target in "${discovered_targets[@]}"; do
      if [[ -n "$target" && -z "${seen_targets["$target"]+x}" ]]; then
        targets+=("$target")
        seen_targets["$target"]=1
      fi
    done

    for target in "${targets[@]}"; do
      [[ -f "$target" ]] || continue
      if replace_literal_in_file "$target" "$value" "$sanitized"; then
        changed=1
        if [[ "$target" == /etc/docker/* ]]; then
          daemon_changed=1
        fi
        bootstrap_warn "sanitized ParseAddr CIDR value in $target: $value -> $sanitized"
      fi
    done
  done

  if (( changed == 0 )); then
    bootstrap_warn "unable to locate ParseAddr CIDR value in /data/coolify or /etc/docker: ${bad_values[*]}"
  fi

  if (( daemon_changed == 1 )); then
    if command -v systemctl >/dev/null 2>&1; then
      if systemctl restart docker >/dev/null 2>&1; then
        bootstrap_warn "docker service restarted after ParseAddr CIDR sanitization in /etc/docker."
      else
        bootstrap_warn "could not restart docker service after /etc/docker sanitization; continuing."
      fi
    fi
  fi

  if (( changed == 1 )); then
    return 0
  fi
  return 1
}

apply_sudo_policy() {
  local policy_file
  local tmp_file
  local user
  policy_file="/etc/sudoers.d/99-bootstrap-sudo-policy"
  tmp_file="$(mktemp)"

  if ! {
    : > "$tmp_file"
    for user in $(split_csv_to_lines "$MANAGED_USERS_CSV"); do
      if [[ "$user" == "$DEVOPS_USER" || "$user" == "$COOLIFY_SUDO_NOPASSWD_USER" ]]; then
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
for user in $(split_csv_to_lines "$MANAGED_USERS_CSV"); do
  ensure_user_exists "$user"
  if [[ "$user" != "$COOLIFY_SUDO_NOPASSWD_USER" ]]; then
    ensure_ssh_key "$user" "$SSH_PUBLIC_KEY"
  fi
done
# The dedicated Coolify localhost user must not inherit the operator's public
# SSH key. Keep access for this user restricted to the dedicated localhost key.
remove_ssh_key_exact_line "$COOLIFY_SUDO_NOPASSWD_USER" "$SSH_PUBLIC_KEY"
bootstrap_success "Managed users ensured and SSH keys synchronized."

bash "$script_dir/ensure-user-passwords.sh" "$ENV_FILE"
bootstrap_success "Managed user password/vault synchronization completed."
sync_sshd_allowusers
bootstrap_success "sshd AllowUsers synchronized from managed users."
enforce_sshd_single_port

# Make sure sshd runtime dir exists before validation/restart.
mkdir -p /run/sshd
chmod 755 /run/sshd
chown root:root /run/sshd
cat >/etc/tmpfiles.d/sshd.conf <<'TMP'
d /run/sshd 0755 root root -
TMP
systemd-tmpfiles --create /etc/tmpfiles.d/sshd.conf
bootstrap_success "sshd runtime directory baseline prepared."

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
bootstrap_success "ssh.socket disabled; ssh.service validated/restarted on configured port."

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
bootstrap_success "UFW baseline rules applied (SSH,80,443)."

systemctl enable --now fail2ban
systemctl enable --now unattended-upgrades
bootstrap_success "fail2ban and unattended-upgrades enabled."

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
  local allowed_from='127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,fc00::/7'
  local key_pub=""
  local attempt=0

  if ! command -v docker >/dev/null 2>&1; then
    bootstrap_warn "docker not found; skipping Coolify localhost SSH user sync."
    return 0
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx 'coolify'; then
    bootstrap_warn "coolify container is not running; skipping localhost SSH user sync."
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
    set_ssh_key_restricted_to_source_ranges "$COOLIFY_SUDO_NOPASSWD_USER" "$key_pub" "$allowed_from"
    remove_ssh_key_exact_line "$COOLIFY_SUDO_NOPASSWD_USER" "$SSH_PUBLIC_KEY"
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

  bootstrap_warn "failed to synchronize Coolify localhost server SSH user automatically after retries."
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
  bootstrap_success "Coolify installed via official installer."
else
  bootstrap_success "Coolify already running; install step skipped."
fi

groupadd -f coolify
if command -v docker >/dev/null 2>&1; then
  groupadd -f docker
fi
bootstrap_success "Required groups ensured (coolify, docker when available)."

for user in $(split_csv_to_lines "$MANAGED_USERS_CSV"); do
  ensure_user_exists "$user"
  usermod -aG sudo "$user"
done
apply_sudo_policy
bootstrap_success "Sudo policy applied for managed users."

for user in $(split_csv_to_lines "$MANAGED_USERS_CSV"); do
  ensure_user_exists "$user"
  usermod -aG coolify "$user"
done

if getent group docker >/dev/null 2>&1; then
  for user in $(split_csv_to_lines "$MANAGED_USERS_CSV"); do
    ensure_user_exists "$user"
    usermod -aG docker "$user"
  done
fi
bootstrap_success "Managed users synchronized to sudo/docker/coolify groups."

sync_coolify_localhost_ssh_user
bootstrap_success "Coolify localhost SSH user synchronization completed."
configure_coolify_realtime_domain
harden_coolify_compose_ports
sync_coolify_realtime_port_guards
bootstrap_success "Realtime security policy synchronization completed."

# Docker published ports bypass UFW because Docker writes iptables rules directly.
if command -v ss >/dev/null 2>&1 && ss -tuln | awk '{print $4}' | grep -Eq '[:.]6001$|[:.]6002$'; then
  bootstrap_warn "port 6001 and/or 6002 is listening on host."
  if [[ "$CLOSE_COOLIFY_REALTIME_PORTS" == "true" ]]; then
    bootstrap_warn "DOCKER-USER guards were applied to block public ingress to 6001/6002."
    bootstrap_warn "verify effective policy with: sudo iptables -S DOCKER-USER"
    bootstrap_warn "realtime domain in use: ${COOLIFY_REALTIME_DOMAIN}"
  else
    bootstrap_warn "realtime ports are intentionally public by configuration."
  fi
fi

bootstrap_success "Coolify public URL: https://${COOLIFY_PUBLIC_DOMAIN}"
bootstrap_success "bootstrap-host.sh completed successfully."
