#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  cat <<'USAGE'
Generate/refresh secret values in bootstrap env file.

Usage:
  scripts/generate-secrets.sh [--env-file <path>] [--force-password] [--force-encryption-password] [--force-ssh-key]
USAGE
}

env_file="env/bootstrap.env"
force_password=0
force_encryption_password=0
force_ssh_key=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env-file)
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

if [ ! -f "$env_file" ]; then
  echo "ERROR: Env file not found: $env_file" >&2
  echo "Create it first from env/bootstrap.env.example" >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl is required for secret generation." >&2
  exit 1
fi

pw_gen() {
  openssl rand -hex 12
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
          printf '%s\n' "$key"
          return 0
        fi
      fi
    done

    for candidate in "$home_dir"/.ssh/*.pub; do
      [ -f "$candidate" ] || continue
      key="$(head -n 1 "$candidate" | tr -d '\r')"
      if is_valid_ssh_pub_key "$key"; then
        printf '%s\n' "$key"
        return 0
      fi
    done
  done

  return 1
}

detected_ssh_key=""
if detected_ssh_key="$(detect_current_user_ssh_pub_key)"; then
  has_detected_ssh_key=1
else
  has_detected_ssh_key=0
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
saw_coolify_password=0
saw_encryption_password=0
saw_ssh_public_key=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    SSH_PUBLIC_KEY=*)
      saw_ssh_public_key=1
      current="${line#*=}"
      if [ "$force_ssh_key" -eq 1 ] || [ -z "$current" ] || [[ "$current" == *CHANGE_ME* ]]; then
        if [ "$has_detected_ssh_key" -eq 1 ]; then
          echo "SSH_PUBLIC_KEY=$detected_ssh_key" >> "$tmp"
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
        echo "COOLIFY_ROOT_USER_PASSWORD=$(pw_gen)" >> "$tmp"
      else
        echo "$line" >> "$tmp"
      fi
      ;;
    USER_PASSWORDS_ENCRYPTION_PASSWORD=*)
      saw_encryption_password=1
      current="${line#*=}"
      if [ "$force_encryption_password" -eq 1 ] || [ -z "$current" ] || [[ "$current" == *CHANGE_ME* ]]; then
        echo "USER_PASSWORDS_ENCRYPTION_PASSWORD=$(pw_gen)" >> "$tmp"
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
  echo "COOLIFY_ROOT_USER_PASSWORD=$(pw_gen)" >> "$tmp"
fi

if [ "$saw_encryption_password" -eq 0 ]; then
  echo "USER_PASSWORDS_ENCRYPTION_PASSWORD=$(pw_gen)" >> "$tmp"
fi

if [ "$saw_ssh_public_key" -eq 0 ] && [ "$has_detected_ssh_key" -eq 1 ]; then
  echo "SSH_PUBLIC_KEY=$detected_ssh_key" >> "$tmp"
fi

mv "$tmp" "$env_file"
chmod 600 "$env_file"
echo "Updated: $env_file"
if [ "$has_detected_ssh_key" -eq 1 ]; then
  echo "SSH public key auto-detected and applied when needed."
else
  echo "No local SSH public key detected; set SSH_PUBLIC_KEY or SSH_PUBLIC_KEY_PATH manually."
fi
