#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-/etc/vps-coolify-bootstrap/bootstrap.env}"
ENCRYPTED_PASSWORD_FILE="/etc/vps-coolify-bootstrap/user-passwords.enc"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$script_dir/common.sh"
bootstrap_install_error_trap "ensure-user-passwords.sh"

if [[ ! -f "$ENV_FILE" ]]; then
  bootstrap_error "bootstrap env file not found: $ENV_FILE"
  exit 1
fi

load_env_file_strict "$ENV_FILE"
bootstrap_success "Loaded bootstrap env from $ENV_FILE."
bootstrap_info "Starting managed password/vault workflow."

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    bootstrap_error "missing required variable: $name"
    exit 1
  fi
}

require_var USER_PASSWORDS_ENCRYPTION_PASSWORD

if (( ${#USER_PASSWORDS_ENCRYPTION_PASSWORD} < 16 )); then
  bootstrap_error "USER_PASSWORDS_ENCRYPTION_PASSWORD must be at least 16 chars"
  exit 1
fi

COOLIFY_SUDO_NOPASSWD_USER="${COOLIFY_SUDO_NOPASSWD_USER:-coolify}"
if ! is_valid_unix_username "$COOLIFY_SUDO_NOPASSWD_USER"; then
  bootstrap_error "COOLIFY_SUDO_NOPASSWD_USER contains invalid UNIX username: $COOLIFY_SUDO_NOPASSWD_USER"
  exit 1
fi
if [[ "$COOLIFY_SUDO_NOPASSWD_USER" == "root" ]]; then
  bootstrap_error "COOLIFY_SUDO_NOPASSWD_USER must not be root."
  exit 1
fi
DEVOPS_USER="${DEVOPS_USER:-devops}"
if ! is_valid_unix_username "$DEVOPS_USER"; then
  bootstrap_error "DEVOPS_USER contains invalid UNIX username: $DEVOPS_USER"
  exit 1
fi
if [[ "$DEVOPS_USER" == "root" ]]; then
  bootstrap_error "DEVOPS_USER must not be root."
  exit 1
fi
if [[ "$DEVOPS_USER" == "$COOLIFY_SUDO_NOPASSWD_USER" ]]; then
  bootstrap_error "DEVOPS_USER and COOLIFY_SUDO_NOPASSWD_USER must be different users."
  exit 1
fi
managed_users_csv="$DEVOPS_USER"
managed_users_csv="$(csv_append_unique "$managed_users_csv" "$COOLIFY_SUDO_NOPASSWD_USER")"
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
  managed_users_csv="$(csv_append_unique "$managed_users_csv" "$user")"
done
bootstrap_success "Input validation completed for managed user password workflow."
bootstrap_info "Managed users in scope: $(split_csv_to_lines "$managed_users_csv" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

if ! command -v openssl >/dev/null 2>&1; then
  bootstrap_error "openssl is required to encrypt generated password file"
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
  bootstrap_info "Existing vault found, decrypting: $ENCRYPTED_PASSWORD_FILE"
  if ! USER_PASSWORDS_ENCRYPTION_PASSWORD="$USER_PASSWORDS_ENCRYPTION_PASSWORD" \
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
    -in "$ENCRYPTED_PASSWORD_FILE" \
    -out "$existing_plaintext_file" \
    -pass env:USER_PASSWORDS_ENCRYPTION_PASSWORD; then
    bootstrap_error "could not decrypt existing password file: $ENCRYPTED_PASSWORD_FILE"
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
  bootstrap_success "Existing encrypted password vault decrypted successfully."
fi

{
  echo "# generated_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# host=$(hostname -f 2>/dev/null || hostname)"
  echo "# source_env=$ENV_FILE"
} > "$plaintext_file"

changed_count=0
for user in $(split_csv_to_lines "$managed_users_csv"); do
  if [[ "$user" == *:* ]]; then
    bootstrap_error "managed user list contains invalid username (colon not allowed): $user"
    exit 1
  fi

  if ! is_valid_unix_username "$user"; then
    bootstrap_error "managed user list contains invalid UNIX username: $user"
    exit 1
  fi

  if ! id "$user" >/dev/null 2>&1; then
    bootstrap_error "managed user does not exist: $user"
    exit 1
  fi

  if is_locked_password "$user" || [[ -z "${user_passwords[$user]:-}" ]]; then
    password="$(generate_password)"
    printf '%s:%s\n' "$user" "$password" | chpasswd
    user_passwords["$user"]="$password"
    changed_count=$((changed_count + 1))
    bootstrap_info "Password generated/updated for user: $user"
  else
    bootstrap_info "Existing password kept for user: $user"
  fi
done

for user in $(split_csv_to_lines "$managed_users_csv"); do
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

bootstrap_success "generated/rotated passwords for $changed_count user(s)"
bootstrap_success "encrypted credentials saved to $ENCRYPTED_PASSWORD_FILE"
bootstrap_success "ensure-user-passwords.sh completed successfully."
