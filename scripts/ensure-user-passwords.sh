#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-/etc/vps-coolify-bootstrap/bootstrap.env}"
ENCRYPTED_PASSWORD_FILE="/etc/vps-coolify-bootstrap/user-passwords.enc"

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

require_var CREATE_USERS
require_var USER_PASSWORDS_ENCRYPTION_PASSWORD

if (( ${#USER_PASSWORDS_ENCRYPTION_PASSWORD} < 16 )); then
  echo "ERROR: USER_PASSWORDS_ENCRYPTION_PASSWORD must be at least 16 chars" >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl is required to encrypt generated password file" >&2
  exit 1
fi

generate_password() {
  # Use uniform hex output (24 chars) to avoid filtering bias.
  openssl rand -hex 12
}

is_locked_password() {
  local user="$1"
  local shadow_hash
  shadow_hash="$(getent shadow "$user" | cut -d: -f2 || true)"

  if [[ -z "$shadow_hash" || "$shadow_hash" == "!"* || "$shadow_hash" == "*"* ]]; then
    return 0
  fi

  return 1
}

umask 077
plaintext_file="$(mktemp)"
existing_plaintext_file="$(mktemp)"
trap 'rm -f "$plaintext_file" "$existing_plaintext_file"' EXIT

declare -A user_passwords=()

if [[ -f "$ENCRYPTED_PASSWORD_FILE" ]]; then
  if ! USER_PASSWORDS_ENCRYPTION_PASSWORD="$USER_PASSWORDS_ENCRYPTION_PASSWORD" \
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
    -in "$ENCRYPTED_PASSWORD_FILE" \
    -out "$existing_plaintext_file" \
    -pass env:USER_PASSWORDS_ENCRYPTION_PASSWORD; then
    echo "ERROR: could not decrypt existing password file: $ENCRYPTED_PASSWORD_FILE" >&2
    exit 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    if [[ "$line" == *:* ]]; then
      user="${line%%:*}"
      password="${line#*:}"
      if [[ -n "$user" && -n "$password" ]]; then
        user_passwords["$user"]="$password"
      fi
    fi
  done < "$existing_plaintext_file"
fi

{
  echo "# generated_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# host=$(hostname -f 2>/dev/null || hostname)"
  echo "# source_env=$ENV_FILE"
} > "$plaintext_file"

changed_count=0
for user in $(split_csv_to_lines "$CREATE_USERS"); do
  if [[ "$user" == *:* ]]; then
    echo "ERROR: CREATE_USERS contains invalid username (colon not allowed): $user" >&2
    exit 1
  fi

  if ! is_valid_unix_username "$user"; then
    echo "ERROR: CREATE_USERS contains invalid UNIX username: $user" >&2
    exit 1
  fi

  if ! id "$user" >/dev/null 2>&1; then
    echo "ERROR: user declared in CREATE_USERS does not exist: $user" >&2
    exit 1
  fi

  if is_locked_password "$user" || [[ -z "${user_passwords[$user]:-}" ]]; then
    password="$(generate_password)"
    printf '%s:%s\n' "$user" "$password" | chpasswd
    user_passwords["$user"]="$password"
    changed_count=$((changed_count + 1))
  fi
done

for user in $(split_csv_to_lines "$CREATE_USERS"); do
  if [[ -n "${user_passwords[$user]:-}" ]]; then
    printf '%s:%s\n' "$user" "${user_passwords[$user]}" >> "$plaintext_file"
  fi
done

USER_PASSWORDS_ENCRYPTION_PASSWORD="$USER_PASSWORDS_ENCRYPTION_PASSWORD" \
  openssl enc -aes-256-cbc -pbkdf2 -salt -iter 200000 \
  -in "$plaintext_file" \
  -out "$ENCRYPTED_PASSWORD_FILE" \
  -pass env:USER_PASSWORDS_ENCRYPTION_PASSWORD

chmod 600 "$ENCRYPTED_PASSWORD_FILE"
chown root:root "$ENCRYPTED_PASSWORD_FILE"

echo "ensure-user-passwords.sh: generated/rotated passwords for $changed_count user(s)"
echo "ensure-user-passwords.sh: encrypted credentials saved to $ENCRYPTED_PASSWORD_FILE"
