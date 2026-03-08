#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  cat <<'USAGE'
Generate/refresh secret values in bootstrap env file.

Usage:
  scripts/generate-secrets.sh [--env-file <path>] [--force-password] [--force-encryption-password] [--force-ssh-key]

Behavior:
  - If env file is missing, script creates parent directory and copies env/bootstrap.env.example.
USAGE
}

env_file="bootstrap-artifacts/bootstrap.env"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
env_example_file="$repo_root/env/bootstrap.env.example"
force_password=0
force_encryption_password=0
force_ssh_key=0

require_value_arg() {
  local flag="$1"
  local maybe_value="${2:-}"
  if [[ -z "$maybe_value" || "$maybe_value" == -* ]]; then
    echo "ERROR: $flag requires a value." >&2
    usage >&2
    exit 1
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env-file)
      require_value_arg "--env-file" "${2:-}"
      env_file="${2:-}"
      shift 2
      ;;
    --force-password)
      force_password=1
      shift
      ;;
    --force-encryption-password)
      force_encryption_password=1
      shift
      ;;
    --force-ssh-key)
      force_ssh_key=1
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

env_dir="$(dirname "$env_file")"
mkdir -p "$env_dir"

if [[ ! -f "$env_file" ]]; then
  cp "$env_example_file" "$env_file"
  chmod 600 "$env_file"
  echo "Created: $env_file (from $env_example_file)"
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl is required for secret generation." >&2
  exit 1
fi

pw_gen_password() {
  local lower upper digit symbol rest candidate
  local symbol_pool='!@#$%^&*()-_=+'
  local symbol_index

  while true; do
    lower="$(openssl rand -base64 48 | tr -dc '[:lower:]' | head -c 1 || true)"
    upper="$(openssl rand -base64 48 | tr -dc '[:upper:]' | head -c 1 || true)"
    digit="$(openssl rand -base64 48 | tr -dc '0-9' | head -c 1 || true)"
    rest="$(openssl rand -base64 128 | tr -dc 'A-Za-z0-9' | head -c 20 || true)"
    if [[ -z "$lower" || -z "$upper" || -z "$digit" || ${#rest} -lt 20 ]]; then
      continue
    fi
    symbol_index=$(( 0x$(openssl rand -hex 1) % ${#symbol_pool} ))
    symbol="${symbol_pool:$symbol_index:1}"
    candidate="${lower}${upper}${digit}${symbol}${rest}"
    if (( ${#candidate} == 24 )); then
      printf '%s' "$candidate"
      return 0
    fi
  done
}

pw_gen_encryption_password() {
  openssl rand -hex 16
}

format_env_value() {
  local value="$1"
  if [[ "$value" != *"'"* ]]; then
    printf "'%s'" "$value"
    return 0
  fi
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\\$}"
  printf '"%s"' "$value"
}

is_valid_ssh_pub_key() {
  local key="$1"
  [[ "$key" =~ ^ssh-(ed25519|rsa|ecdsa-[^[:space:]]+)[[:space:]] ]]
}

detect_current_user_ssh_pub_key() {
  local users=()
  local user=""
  local home_dir=""
  local candidate=""
  local key=""

  resolve_home_dir() {
    local target_user="$1"
    if [ -n "${HOME:-}" ] && [ "$target_user" = "$(id -un)" ]; then
      printf '%s\n' "$HOME"
      return 0
    fi
    if command -v getent >/dev/null 2>&1; then
      getent passwd "$target_user" | cut -d: -f6
      return 0
    fi
    return 1
  }

  if [ -n "${SUDO_USER:-}" ]; then
    users+=("$SUDO_USER")
  fi
  if [ -n "${USER:-}" ]; then
    users+=("$USER")
  fi
  users+=("$(id -un)")

  for user in "${users[@]}"; do
    [ -n "$user" ] || continue
    home_dir="$(resolve_home_dir "$user" || true)"
    [ -n "$home_dir" ] || continue

    for candidate in \
      "$home_dir/.ssh/id_ed25519.pub" \
      "$home_dir/.ssh/id_ecdsa.pub" \
      "$home_dir/.ssh/id_rsa.pub"; do
      if [ -f "$candidate" ]; then
        key="$(head -n 1 "$candidate" | tr -d '\r')"
        if is_valid_ssh_pub_key "$key"; then
          DETECTED_SSH_KEY="$key"
          DETECTED_SSH_KEY_PATH="$candidate"
          return 0
        fi
      fi
    done

    for candidate in "$home_dir"/.ssh/*.pub; do
      [ -f "$candidate" ] || continue
      key="$(head -n 1 "$candidate" | tr -d '\r')"
      if is_valid_ssh_pub_key "$key"; then
        DETECTED_SSH_KEY="$key"
        DETECTED_SSH_KEY_PATH="$candidate"
        return 0
      fi
    done
  done

  return 1
}

detected_ssh_key=""
detected_ssh_key_path=""
DETECTED_SSH_KEY=""
DETECTED_SSH_KEY_PATH=""
if detect_current_user_ssh_pub_key; then
  detected_ssh_key="$DETECTED_SSH_KEY"
  detected_ssh_key_path="$DETECTED_SSH_KEY_PATH"
  has_detected_ssh_key=1
else
  has_detected_ssh_key=0
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
saw_coolify_password=0
saw_encryption_password=0
saw_ssh_public_key=0
saw_ssh_public_key_path=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    SSH_PUBLIC_KEY_PATH=*)
      saw_ssh_public_key_path=1
      current="${line#*=}"
      if [ "$force_ssh_key" -eq 1 ] || [ -z "$current" ] || [[ "$current" == *CHANGE_ME* ]]; then
        if [ "$has_detected_ssh_key" -eq 1 ]; then
          echo "SSH_PUBLIC_KEY_PATH=$(format_env_value "$detected_ssh_key_path")" >> "$tmp"
        else
          echo "$line" >> "$tmp"
        fi
      else
        echo "$line" >> "$tmp"
      fi
      ;;
    SSH_PUBLIC_KEY=*)
      saw_ssh_public_key=1
      current="${line#*=}"
      if [ "$force_ssh_key" -eq 1 ] || [ -z "$current" ] || [[ "$current" == *CHANGE_ME* ]]; then
        if [ "$has_detected_ssh_key" -eq 1 ]; then
          echo "SSH_PUBLIC_KEY=$(format_env_value "$detected_ssh_key")" >> "$tmp"
        else
          echo "$line" >> "$tmp"
        fi
      else
        echo "$line" >> "$tmp"
      fi
      ;;
    COOLIFY_ROOT_USER_PASSWORD=*)
      saw_coolify_password=1
      current="${line#*=}"
      if [ "$force_password" -eq 1 ] || [ -z "$current" ] || [[ "$current" == *CHANGE_ME* ]]; then
        echo "COOLIFY_ROOT_USER_PASSWORD=$(format_env_value "$(pw_gen_password)")" >> "$tmp"
      else
        echo "$line" >> "$tmp"
      fi
      ;;
    USER_PASSWORDS_ENCRYPTION_PASSWORD=*)
      saw_encryption_password=1
      current="${line#*=}"
      if [ "$force_encryption_password" -eq 1 ] || [ -z "$current" ] || [[ "$current" == *CHANGE_ME* ]]; then
        echo "USER_PASSWORDS_ENCRYPTION_PASSWORD=$(format_env_value "$(pw_gen_encryption_password)")" >> "$tmp"
      else
        echo "$line" >> "$tmp"
      fi
      ;;
    *)
      echo "$line" >> "$tmp"
      ;;
  esac
done < "$env_file"

if [ "$saw_coolify_password" -eq 0 ]; then
  echo "COOLIFY_ROOT_USER_PASSWORD=$(format_env_value "$(pw_gen_password)")" >> "$tmp"
fi

if [ "$saw_encryption_password" -eq 0 ]; then
  echo "USER_PASSWORDS_ENCRYPTION_PASSWORD=$(format_env_value "$(pw_gen_encryption_password)")" >> "$tmp"
fi

if [ "$saw_ssh_public_key" -eq 0 ] && [ "$has_detected_ssh_key" -eq 1 ]; then
  echo "SSH_PUBLIC_KEY=$(format_env_value "$detected_ssh_key")" >> "$tmp"
fi
if [ "$saw_ssh_public_key_path" -eq 0 ] && [ "$has_detected_ssh_key" -eq 1 ]; then
  echo "SSH_PUBLIC_KEY_PATH=$(format_env_value "$detected_ssh_key_path")" >> "$tmp"
fi

mv "$tmp" "$env_file"
chmod 600 "$env_file"
echo "Updated: $env_file"
if [ "$has_detected_ssh_key" -eq 1 ]; then
  echo "SSH_PUBLIC_KEY and SSH_PUBLIC_KEY_PATH auto-detected and applied when needed."
else
  echo "No local SSH public key detected; set SSH_PUBLIC_KEY or SSH_PUBLIC_KEY_PATH manually."
fi
