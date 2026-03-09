#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Render VPS-Coolify init user-data (VPS init format) from template + env file.

Usage:
  scripts/prepare-vps-coolify-init.sh [--env-file <path>] [--overwrite]

Behavior:
  - If env file is missing, script creates parent directory and copies env/bootstrap.env.example.
USAGE
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

split_user_list_to_lines() {
  local raw="$1"
  local item=""
  while IFS= read -r item || [[ -n "$item" ]]; do
    item="$(trim "$item")"
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done < <(printf '%s' "$raw" | tr ',;[:space:]' '\n')
}

resolve_path() {
  local path_value="$1"
  local base_dir="$2"
  if [[ "$path_value" = "~" ]]; then
    path_value="$HOME"
  elif [[ "$path_value" = ~/* ]]; then
    path_value="${HOME}/${path_value#~/}"
  fi
  if [[ "$path_value" = /* ]]; then
    printf '%s\n' "$path_value"
  else
    printf '%s\n' "${base_dir}/${path_value}"
  fi
}

env_file="bootstrap-artifacts/bootstrap.env"
overwrite=0
env_example_file="$repo_root/env/bootstrap.env.example"

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

if [[ -d "$env_file" ]]; then
  echo "ERROR: --env-file points to a directory, expected a file: $env_file" >&2
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

declare -A cfg=()
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  line="${raw_line%$'\r'}"
  line="$(trim "$line")"
  [[ -z "$line" || "${line:0:1}" = "#" ]] && continue
  if [[ "$line" != *"="* ]]; then
    echo "ERROR: Invalid .env line: $raw_line" >&2
    exit 1
  fi
  key="$(trim "${line%%=*}")"
  value="$(trim "${line#*=}")"
  if (( ${#value} >= 2 )); then
    first_char="${value:0:1}"
    last_char="${value: -1}"
    if [[ "$first_char" == "$last_char" && ( "$first_char" == "'" || "$first_char" == '"' ) ]]; then
      value="${value:1:${#value}-2}"
    fi
  fi
  cfg["$key"]="$value"
done < "$env_file"

require_key() {
  local key="$1"
  if [[ -z "${cfg[$key]:-}" ]]; then
    echo "ERROR: Missing required key '$key' in $env_file" >&2
    exit 1
  fi
}

csv_contains_value() {
  local csv="$1"
  local needle="$2"
  local item=""
  for item in $(split_user_list_to_lines "$csv"); do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

csv_append_unique() {
  local csv="$1"
  local value="$2"
  if csv_contains_value "$csv" "$value"; then
    printf '%s\n' "$csv"
  elif [[ -z "$csv" ]]; then
    printf '%s\n' "$value"
  else
    printf '%s,%s\n' "$csv" "$value"
  fi
}

for k in TIMEZONE SSH_PORT COOLIFY_PUBLIC_DOMAIN COOLIFY_ROOT_USERNAME COOLIFY_ROOT_USER_EMAIL COOLIFY_ROOT_USER_PASSWORD USER_PASSWORDS_ENCRYPTION_PASSWORD BOOTSTRAP_REPO_URL BOOTSTRAP_REPO_REF; do
  require_key "$k"
done

ssh_port="${cfg[SSH_PORT]}"
if [[ ! "$ssh_port" =~ ^[0-9]+$ ]]; then
  echo "ERROR: SSH_PORT must be numeric (1-65535)." >&2
  exit 1
fi
ssh_port_num=$((10#$ssh_port))
if (( ssh_port_num < 1 || ssh_port_num > 65535 )); then
  echo "ERROR: SSH_PORT must be between 1 and 65535." >&2
  exit 1
fi

if [[ ! "${cfg[TIMEZONE]}" =~ ^[A-Za-z0-9_+./-]+$ ]]; then
  echo "ERROR: TIMEZONE contains invalid characters." >&2
  exit 1
fi

if [[ "${cfg[COOLIFY_PUBLIC_DOMAIN]}" =~ [[:space:]/] ]]; then
  echo "ERROR: COOLIFY_PUBLIC_DOMAIN must be a hostname without spaces or /." >&2
  exit 1
fi

if [[ ! "${cfg[COOLIFY_ROOT_USER_EMAIL]}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
  echo "ERROR: COOLIFY_ROOT_USER_EMAIL must be a valid email format." >&2
  exit 1
fi

if [[ ! "${cfg[COOLIFY_ROOT_USERNAME]}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: COOLIFY_ROOT_USERNAME must match ^[A-Za-z0-9._-]+$." >&2
  exit 1
fi

devops_user="${cfg[DEVOPS_USER]:-devops}"
if ! is_valid_unix_username "$devops_user"; then
  echo "ERROR: DEVOPS_USER contains invalid UNIX username: $devops_user" >&2
  exit 1
fi
if [[ "$devops_user" == "root" ]]; then
  echo "ERROR: DEVOPS_USER must not be root." >&2
  exit 1
fi
cfg[DEVOPS_USER]="$devops_user"

coolify_sudo_nopasswd_user="${cfg[COOLIFY_SUDO_NOPASSWD_USER]:-coolify}"
if ! is_valid_unix_username "$coolify_sudo_nopasswd_user"; then
  echo "ERROR: COOLIFY_SUDO_NOPASSWD_USER contains invalid UNIX username: $coolify_sudo_nopasswd_user" >&2
  exit 1
fi
if [[ "$coolify_sudo_nopasswd_user" == "root" ]]; then
  echo "ERROR: COOLIFY_SUDO_NOPASSWD_USER must not be root." >&2
  exit 1
fi
if [[ "$devops_user" == "$coolify_sudo_nopasswd_user" ]]; then
  echo "ERROR: DEVOPS_USER and COOLIFY_SUDO_NOPASSWD_USER must be different users." >&2
  exit 1
fi
cfg[COOLIFY_SUDO_NOPASSWD_USER]="$coolify_sudo_nopasswd_user"

cfg[ADDITIONAL_SUDO_USERS]="${cfg[ADDITIONAL_SUDO_USERS]:-}"
managed_users_csv="${cfg[DEVOPS_USER]}"
managed_users_csv="$(csv_append_unique "$managed_users_csv" "${cfg[COOLIFY_SUDO_NOPASSWD_USER]}")"
for user in $(split_user_list_to_lines "${cfg[ADDITIONAL_SUDO_USERS]}"); do
  [[ -n "$user" ]] || continue
  if [[ "$user" == "root" ]]; then
    echo "ERROR: ADDITIONAL_SUDO_USERS must not contain root." >&2
    exit 1
  fi
  if [[ "$user" == *:* ]]; then
    echo "ERROR: ADDITIONAL_SUDO_USERS contains invalid username (colon not allowed): $user" >&2
    exit 1
  fi
  if ! is_valid_unix_username "$user"; then
    echo "ERROR: ADDITIONAL_SUDO_USERS contains invalid UNIX username: $user" >&2
    exit 1
  fi
  if [[ "$user" == "${cfg[COOLIFY_SUDO_NOPASSWD_USER]}" ]]; then
    echo "ERROR: ADDITIONAL_SUDO_USERS must not contain COOLIFY_SUDO_NOPASSWD_USER (${cfg[COOLIFY_SUDO_NOPASSWD_USER]})." >&2
    exit 1
  fi
  managed_users_csv="$(csv_append_unique "$managed_users_csv" "$user")"
done
cfg[MANAGED_USERS]="$managed_users_csv"

close_coolify_realtime_ports="${cfg[CLOSE_COOLIFY_REALTIME_PORTS]:-}"
if [[ -z "$close_coolify_realtime_ports" ]] && [[ -n "${cfg[ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS]:-}" ]]; then
  if [[ "${cfg[ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS]}" == "0" ]]; then
    close_coolify_realtime_ports="true"
  elif [[ "${cfg[ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS]}" == "1" ]]; then
    close_coolify_realtime_ports="false"
  fi
fi
close_coolify_realtime_ports="${close_coolify_realtime_ports:-false}"
case "$close_coolify_realtime_ports" in
  true|false) ;;
  1) close_coolify_realtime_ports="true" ;;
  0) close_coolify_realtime_ports="false" ;;
  *)
    echo "ERROR: CLOSE_COOLIFY_REALTIME_PORTS must be true/false or 1/0." >&2
    exit 1
    ;;
esac
cfg[CLOSE_COOLIFY_REALTIME_PORTS]="$close_coolify_realtime_ports"

docker_disable_ipv6_for_parseaddr_fix="${cfg[DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX]:-true}"
case "$docker_disable_ipv6_for_parseaddr_fix" in
  true|false) ;;
  1) docker_disable_ipv6_for_parseaddr_fix="true" ;;
  0) docker_disable_ipv6_for_parseaddr_fix="false" ;;
  *)
    echo "ERROR: DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX must be true/false or 1/0." >&2
    exit 1
    ;;
esac
cfg[DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX]="$docker_disable_ipv6_for_parseaddr_fix"

coolify_realtime_domain="${cfg[COOLIFY_REALTIME_DOMAIN]:-}"
if [[ -n "$coolify_realtime_domain" ]] && [[ "$coolify_realtime_domain" =~ [[:space:]/] ]]; then
  echo "ERROR: COOLIFY_REALTIME_DOMAIN must be a hostname without spaces or /." >&2
  exit 1
fi
if [[ -n "$coolify_realtime_domain" ]] && [[ "$coolify_realtime_domain" == *"CHANGE_ME"* ]]; then
  echo "ERROR: COOLIFY_REALTIME_DOMAIN must not contain CHANGE_ME placeholder." >&2
  exit 1
fi
cfg[COOLIFY_REALTIME_DOMAIN]="$coolify_realtime_domain"

effective_coolify_realtime_domain="$coolify_realtime_domain"
if [[ "$close_coolify_realtime_ports" == "true" ]] && [[ -z "$effective_coolify_realtime_domain" ]]; then
  effective_coolify_realtime_domain="${cfg[COOLIFY_PUBLIC_DOMAIN]}"
  if [[ -n "$effective_coolify_realtime_domain" ]]; then
    echo "WARNING: COOLIFY_REALTIME_DOMAIN is empty. Closed realtime mode will use COOLIFY_PUBLIC_DOMAIN (${effective_coolify_realtime_domain})." >&2
  fi
fi
if [[ "$close_coolify_realtime_ports" == "true" ]] && [[ -z "$effective_coolify_realtime_domain" ]]; then
  echo "ERROR: Closed realtime mode requires domain via COOLIFY_REALTIME_DOMAIN or COOLIFY_PUBLIC_DOMAIN." >&2
  exit 1
fi

env_dir="$(cd "$(dirname "$env_file")" && pwd)"
template_file="${cfg[TEMPLATE_FILE]:-../templates/vps-init.template.yml}"
output_file="${cfg[OUTPUT_FILE]:-../bootstrap-artifacts/vps-coolify-init.generated.yml}"
template_path="$(resolve_path "$template_file" "$env_dir")"
output_path="$(resolve_path "$output_file" "$env_dir")"

if [[ "$template_file" != /* && ! -f "$template_path" ]]; then
  # If env file is outside the repo, fallback to default env base in repo.
  fallback_template_path="$(resolve_path "$template_file" "$repo_root/bootstrap-artifacts")"
  if [[ -f "$fallback_template_path" ]]; then
    template_path="$fallback_template_path"
  fi
fi

if [[ "$output_file" != /* && "$env_dir" != "$repo_root"* ]]; then
  # For external env paths, keep relative output in repo workspace using default env base.
  output_path="$(resolve_path "$output_file" "$repo_root/bootstrap-artifacts")"
fi

if [[ ! -f "$template_path" ]]; then
  echo "ERROR: Template file not found: $template_path" >&2
  exit 1
fi

ssh_public_key="${cfg[SSH_PUBLIC_KEY]:-}"
if [[ "$ssh_public_key" == *"CHANGE_ME"* ]]; then
  ssh_public_key=""
fi
ssh_key_path="${cfg[SSH_PUBLIC_KEY_PATH]:-}"
if [[ "$ssh_key_path" == *"CHANGE_ME"* ]]; then
  ssh_key_path=""
fi

if [[ -z "$ssh_public_key" && -n "$ssh_key_path" ]]; then
  ssh_key_path="$(resolve_path "$ssh_key_path" "$env_dir")"
  if [[ ! -f "$ssh_key_path" ]]; then
    echo "ERROR: SSH public key file not found: $ssh_key_path" >&2
    exit 1
  fi
  ssh_public_key="$(tr -d '\r' < "$ssh_key_path" | head -n1)"
fi

if [[ -n "$ssh_public_key" ]] && { [[ "$ssh_public_key" == *$'\n'* ]] || [[ ! "$ssh_public_key" =~ ^ssh-(ed25519|rsa|ecdsa-[^[:space:]]+)[[:space:]] ]]; }; then
  echo "ERROR: Invalid SSH public key format." >&2
  exit 1
fi

devops_ssh_authorized_keys_block=""
if [[ -n "$ssh_public_key" ]]; then
  devops_ssh_authorized_keys_block=$'    ssh_authorized_keys:\n      - '"$ssh_public_key"
else
  echo "WARNING: SSH_PUBLIC_KEY and SSH_PUBLIC_KEY_PATH are empty or placeholder values." >&2
  echo "WARNING: Generated VPS init YML will not include ssh_authorized_keys for DEVOPS_USER." >&2
  echo "WARNING: Ensure alternate first-access method (provider console/password/manual key injection)." >&2
fi

for v in "$ssh_public_key" "${cfg[TIMEZONE]}" "${cfg[COOLIFY_PUBLIC_DOMAIN]}" "${cfg[COOLIFY_REALTIME_DOMAIN]}" "${cfg[COOLIFY_ROOT_USERNAME]}" "${cfg[COOLIFY_ROOT_USER_EMAIL]}" "${cfg[COOLIFY_ROOT_USER_PASSWORD]}" "${cfg[BOOTSTRAP_REPO_URL]}" "${cfg[BOOTSTRAP_REPO_REF]}"; do
  if [[ "$v" == *"'"* ]]; then
    echo "ERROR: Values used in template must not contain single quotes (')." >&2
    exit 1
  fi
done

coolify_password="${cfg[COOLIFY_ROOT_USER_PASSWORD]}"
if ! is_valid_coolify_root_password "$coolify_password"; then
  echo "ERROR: COOLIFY_ROOT_USER_PASSWORD must be >=16 chars and include lowercase, uppercase, digit, and symbol." >&2
  exit 1
fi

user_passwords_encryption_password="${cfg[USER_PASSWORDS_ENCRYPTION_PASSWORD]}"
if (( ${#user_passwords_encryption_password} < 16 )); then
  echo "ERROR: USER_PASSWORDS_ENCRYPTION_PASSWORD must be at least 16 characters." >&2
  exit 1
fi
ssh_key_rotate="${cfg[SSH_KEY_ROTATE]:-0}"
if [[ "$ssh_key_rotate" != "0" && "$ssh_key_rotate" != "1" ]]; then
  echo "ERROR: SSH_KEY_ROTATE must be 0 or 1." >&2
  exit 1
fi

for v in "${cfg[COOLIFY_PUBLIC_DOMAIN]}" "${cfg[COOLIFY_ROOT_USERNAME]}" "${cfg[COOLIFY_ROOT_USER_EMAIL]}" "$coolify_password" "$user_passwords_encryption_password" "${cfg[DEVOPS_USER]}" "${cfg[COOLIFY_SUDO_NOPASSWD_USER]}" "${cfg[ADDITIONAL_SUDO_USERS]}" "${cfg[BOOTSTRAP_REPO_URL]}" "${cfg[BOOTSTRAP_REPO_REF]}"; do
  if [[ "$v" == *"CHANGE_ME"* ]]; then
    echo "ERROR: Replace CHANGE_ME values in $env_file" >&2
    exit 1
  fi
done

if [[ "$user_passwords_encryption_password" == *"'"* ]]; then
  echo "ERROR: USER_PASSWORDS_ENCRYPTION_PASSWORD must not contain single quotes (')." >&2
  exit 1
fi

if [[ -f "$output_path" && "$overwrite" -ne 1 ]]; then
  echo "ERROR: Output file exists: $output_path (use --overwrite)" >&2
  exit 1
fi

mkdir -p "$(dirname "$output_path")"

content="$(cat "$template_path")"
content="${content//TIMEZONE_HERE/${cfg[TIMEZONE]}}"
content="${content//SSH_PORT_HERE/${cfg[SSH_PORT]}}"
content="${content//DEVOPS_USER_HERE/${cfg[DEVOPS_USER]}}"
content="${content//COOLIFY_SUDO_NOPASSWD_USER_HERE/${cfg[COOLIFY_SUDO_NOPASSWD_USER]}}"
content="${content//    # DEVOPS_SSH_AUTHORIZED_KEYS_BLOCK_HERE/$devops_ssh_authorized_keys_block}"
content="${content//BOOTSTRAP_SSH_PUBLIC_KEY_HERE/$ssh_public_key}"
content="${content//SSH_KEY_ROTATE_HERE/$ssh_key_rotate}"
content="${content//ADDITIONAL_SUDO_USERS_HERE/${cfg[ADDITIONAL_SUDO_USERS]}}"
content="${content//CLOSE_COOLIFY_REALTIME_PORTS_HERE/${cfg[CLOSE_COOLIFY_REALTIME_PORTS]}}"
content="${content//DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX_HERE/${cfg[DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX]}}"
content="${content//COOLIFY_REALTIME_DOMAIN_HERE/${cfg[COOLIFY_REALTIME_DOMAIN]}}"
content="${content//COOLIFY_PUBLIC_DOMAIN_HERE/${cfg[COOLIFY_PUBLIC_DOMAIN]}}"
content="${content//COOLIFY_ROOT_USERNAME_HERE/${cfg[COOLIFY_ROOT_USERNAME]}}"
content="${content//COOLIFY_ROOT_USER_EMAIL_HERE/${cfg[COOLIFY_ROOT_USER_EMAIL]}}"
content="${content//COOLIFY_ROOT_USER_PASSWORD_HERE/$coolify_password}"
content="${content//USER_PASSWORDS_ENCRYPTION_PASSWORD_HERE/$user_passwords_encryption_password}"
content="${content//BOOTSTRAP_REPO_URL_HERE/${cfg[BOOTSTRAP_REPO_URL]}}"
content="${content//BOOTSTRAP_REPO_REF_HERE/${cfg[BOOTSTRAP_REPO_REF]}}"

for token in TIMEZONE_HERE SSH_PORT_HERE DEVOPS_USER_HERE COOLIFY_SUDO_NOPASSWD_USER_HERE DEVOPS_SSH_AUTHORIZED_KEYS_BLOCK_HERE BOOTSTRAP_SSH_PUBLIC_KEY_HERE SSH_KEY_ROTATE_HERE ADDITIONAL_SUDO_USERS_HERE CLOSE_COOLIFY_REALTIME_PORTS_HERE DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX_HERE COOLIFY_REALTIME_DOMAIN_HERE COOLIFY_PUBLIC_DOMAIN_HERE COOLIFY_ROOT_USERNAME_HERE COOLIFY_ROOT_USER_EMAIL_HERE COOLIFY_ROOT_USER_PASSWORD_HERE USER_PASSWORDS_ENCRYPTION_PASSWORD_HERE BOOTSTRAP_REPO_URL_HERE BOOTSTRAP_REPO_REF_HERE; do
  if grep -Fq "$token" <<< "$content"; then
    echo "ERROR: Unreplaced placeholder: $token" >&2
    exit 1
  fi
done

umask 077
printf '%s\n' "$content" > "$output_path"
chmod 600 "$output_path"

size="$(wc -c < "$output_path" | tr -d '[:space:]')"
if (( size > 32768 )); then
  echo "ERROR: Generated VPS-Coolify init file is ${size} bytes (>32768 Hetzner user-data limit for VPS init format)." >&2
  exit 1
fi

echo "Generated: $output_path"
