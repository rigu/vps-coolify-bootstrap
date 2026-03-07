#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Render VPS-Coolify init (cloud-init user-data) from template + env file.

Usage:
  scripts/prepare-cloud-init.sh [--env-file <path>] [--overwrite]
USAGE
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
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

env_file="$(resolve_path "$env_file" "$PWD")"
if [[ ! -f "$env_file" ]]; then
  echo "ERROR: Env file not found: $env_file" >&2
  exit 1
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
  IFS=',' read -r -a _items <<< "$csv"
  for item in "${_items[@]}"; do
    item="$(trim "$item")"
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

is_valid_unix_username() {
  local user="$1"
  [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]
}

for k in TIMEZONE SSH_PORT PRIMARY_SUDO_USER SECONDARY_SUDO_USER CREATE_USERS SUDO_USERS DOCKER_USERS COOLIFY_GROUP_USERS COOLIFY_PUBLIC_DOMAIN COOLIFY_ROOT_USERNAME COOLIFY_ROOT_USER_EMAIL COOLIFY_ROOT_USER_PASSWORD USER_PASSWORDS_ENCRYPTION_PASSWORD BOOTSTRAP_REPO_URL BOOTSTRAP_REPO_REF; do
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

if ! is_valid_unix_username "${cfg[PRIMARY_SUDO_USER]}"; then
  echo "ERROR: PRIMARY_SUDO_USER contains invalid UNIX username: ${cfg[PRIMARY_SUDO_USER]}" >&2
  exit 1
fi
if ! is_valid_unix_username "${cfg[SECONDARY_SUDO_USER]}"; then
  echo "ERROR: SECONDARY_SUDO_USER contains invalid UNIX username: ${cfg[SECONDARY_SUDO_USER]}" >&2
  exit 1
fi

if ! csv_contains_value "${cfg[CREATE_USERS]}" "${cfg[PRIMARY_SUDO_USER]}"; then
  echo "ERROR: PRIMARY_SUDO_USER must be present in CREATE_USERS." >&2
  exit 1
fi
if ! csv_contains_value "${cfg[CREATE_USERS]}" "${cfg[SECONDARY_SUDO_USER]}"; then
  echo "ERROR: SECONDARY_SUDO_USER must be present in CREATE_USERS." >&2
  exit 1
fi

for user in $(printf '%s\n' "${cfg[CREATE_USERS]}" | tr ',' '\n'); do
  user="$(trim "$user")"
  [[ -n "$user" ]] || continue
  if [[ "$user" == *:* ]]; then
    echo "ERROR: CREATE_USERS contains invalid username (colon not allowed): $user" >&2
    exit 1
  fi
  if ! is_valid_unix_username "$user"; then
    echo "ERROR: CREATE_USERS contains invalid UNIX username: $user" >&2
    exit 1
  fi
done

validate_user_csv_subset() {
  local list_name="$1"
  local list_value="$2"
  local user=""
  for user in $(printf '%s\n' "$list_value" | tr ',' '\n'); do
    user="$(trim "$user")"
    [[ -n "$user" ]] || continue
    if [[ "$user" == *:* ]]; then
      echo "ERROR: ${list_name} contains invalid username (colon not allowed): $user" >&2
      exit 1
    fi
    if ! is_valid_unix_username "$user"; then
      echo "ERROR: ${list_name} contains invalid UNIX username: $user" >&2
      exit 1
    fi
    if ! csv_contains_value "${cfg[CREATE_USERS]}" "$user"; then
      echo "ERROR: ${list_name} contains user not present in CREATE_USERS: $user" >&2
      exit 1
    fi
  done
}

validate_user_csv_subset "SUDO_USERS" "${cfg[SUDO_USERS]}"
validate_user_csv_subset "DOCKER_USERS" "${cfg[DOCKER_USERS]}"
validate_user_csv_subset "COOLIFY_GROUP_USERS" "${cfg[COOLIFY_GROUP_USERS]}"

allow_public_coolify_realtime_ports="${cfg[ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS]:-0}"
if [[ "$allow_public_coolify_realtime_ports" != "0" && "$allow_public_coolify_realtime_ports" != "1" ]]; then
  echo "ERROR: ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS must be 0 or 1." >&2
  exit 1
fi

env_dir="$(cd "$(dirname "$env_file")" && pwd)"
template_file="${cfg[TEMPLATE_FILE]:-../templates/cloud-init.template.yml}"
output_file="${cfg[OUTPUT_FILE]:-../bootstrap-artifacts/vps-coolify-init.generated.yml}"
template_path="$(resolve_path "$template_file" "$env_dir")"
output_path="$(resolve_path "$output_file" "$env_dir")"

if [[ ! -f "$template_path" ]]; then
  echo "ERROR: Template file not found: $template_path" >&2
  exit 1
fi

ssh_public_key="${cfg[SSH_PUBLIC_KEY]:-}"
if [[ -z "$ssh_public_key" || "$ssh_public_key" == *"CHANGE_ME"* ]]; then
  ssh_key_path="${cfg[SSH_PUBLIC_KEY_PATH]:-}"
  if [[ -z "$ssh_key_path" || "$ssh_key_path" == *"CHANGE_ME"* ]]; then
    echo "ERROR: Set SSH_PUBLIC_KEY or SSH_PUBLIC_KEY_PATH in $env_file" >&2
    exit 1
  fi
  ssh_key_path="$(resolve_path "$ssh_key_path" "$env_dir")"
  if [[ ! -f "$ssh_key_path" ]]; then
    echo "ERROR: SSH public key file not found: $ssh_key_path" >&2
    exit 1
  fi
  ssh_public_key="$(tr -d '\r' < "$ssh_key_path" | head -n1)"
fi

if [[ "$ssh_public_key" == *$'\n'* ]] || [[ ! "$ssh_public_key" =~ ^ssh-(ed25519|rsa|ecdsa-[^[:space:]]+)[[:space:]] ]]; then
  echo "ERROR: Invalid SSH public key format." >&2
  exit 1
fi

for v in "$ssh_public_key" "${cfg[TIMEZONE]}" "${cfg[COOLIFY_PUBLIC_DOMAIN]}" "${cfg[COOLIFY_ROOT_USERNAME]}" "${cfg[COOLIFY_ROOT_USER_EMAIL]}" "${cfg[COOLIFY_ROOT_USER_PASSWORD]}" "${cfg[BOOTSTRAP_REPO_URL]}" "${cfg[BOOTSTRAP_REPO_REF]}"; do
  if [[ "$v" == *"'"* ]]; then
    echo "ERROR: Values used in template must not contain single quotes (')." >&2
    exit 1
  fi
done

coolify_password="${cfg[COOLIFY_ROOT_USER_PASSWORD]}"
if (( ${#coolify_password} < 16 )); then
  echo "ERROR: COOLIFY_ROOT_USER_PASSWORD must be at least 16 characters." >&2
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

for v in "${cfg[COOLIFY_PUBLIC_DOMAIN]}" "${cfg[COOLIFY_ROOT_USERNAME]}" "${cfg[COOLIFY_ROOT_USER_EMAIL]}" "$coolify_password" "$user_passwords_encryption_password" "${cfg[PRIMARY_SUDO_USER]}" "${cfg[SECONDARY_SUDO_USER]}" "${cfg[CREATE_USERS]}" "${cfg[SUDO_USERS]}" "${cfg[DOCKER_USERS]}" "${cfg[COOLIFY_GROUP_USERS]}" "${cfg[BOOTSTRAP_REPO_URL]}" "${cfg[BOOTSTRAP_REPO_REF]}"; do
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
content="${content//PRIMARY_SUDO_USER_HERE/${cfg[PRIMARY_SUDO_USER]}}"
content="${content//SECONDARY_SUDO_USER_HERE/${cfg[SECONDARY_SUDO_USER]}}"
content="${content//SSH_PUBLIC_KEY_HERE/$ssh_public_key}"
content="${content//SSH_KEY_ROTATE_HERE/$ssh_key_rotate}"
content="${content//CREATE_USERS_HERE/${cfg[CREATE_USERS]}}"
content="${content//SUDO_USERS_HERE/${cfg[SUDO_USERS]}}"
content="${content//DOCKER_USERS_HERE/${cfg[DOCKER_USERS]}}"
content="${content//COOLIFY_GROUP_USERS_HERE/${cfg[COOLIFY_GROUP_USERS]}}"
content="${content//ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS_HERE/$allow_public_coolify_realtime_ports}"
content="${content//COOLIFY_PUBLIC_DOMAIN_HERE/${cfg[COOLIFY_PUBLIC_DOMAIN]}}"
content="${content//COOLIFY_ROOT_USERNAME_HERE/${cfg[COOLIFY_ROOT_USERNAME]}}"
content="${content//COOLIFY_ROOT_USER_EMAIL_HERE/${cfg[COOLIFY_ROOT_USER_EMAIL]}}"
content="${content//COOLIFY_ROOT_USER_PASSWORD_HERE/$coolify_password}"
content="${content//USER_PASSWORDS_ENCRYPTION_PASSWORD_HERE/$user_passwords_encryption_password}"
content="${content//BOOTSTRAP_REPO_URL_HERE/${cfg[BOOTSTRAP_REPO_URL]}}"
content="${content//BOOTSTRAP_REPO_REF_HERE/${cfg[BOOTSTRAP_REPO_REF]}}"

for token in TIMEZONE_HERE SSH_PORT_HERE PRIMARY_SUDO_USER_HERE SECONDARY_SUDO_USER_HERE SSH_PUBLIC_KEY_HERE SSH_KEY_ROTATE_HERE CREATE_USERS_HERE SUDO_USERS_HERE DOCKER_USERS_HERE COOLIFY_GROUP_USERS_HERE ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS_HERE COOLIFY_PUBLIC_DOMAIN_HERE COOLIFY_ROOT_USERNAME_HERE COOLIFY_ROOT_USER_EMAIL_HERE COOLIFY_ROOT_USER_PASSWORD_HERE USER_PASSWORDS_ENCRYPTION_PASSWORD_HERE BOOTSTRAP_REPO_URL_HERE BOOTSTRAP_REPO_REF_HERE; do
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
  echo "ERROR: Generated VPS-Coolify init file is ${size} bytes (>32768 Hetzner cloud-init user-data limit)." >&2
  exit 1
fi

echo "Generated: $output_path"
