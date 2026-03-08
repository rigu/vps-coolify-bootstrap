#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/testlib.sh
source "$repo_root/tests/testlib.sh"

script="$repo_root/scripts/generate-secrets.sh"

make_fake_key() {
  local base="$1"
  mkdir -p "$base/.ssh"
  cat > "$base/.ssh/id_ed25519.pub" <<'KEY'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ7x9T2c5r3V9k3D8rR0p3vWcQx2x2wqP9vYjP6m6tX test@example
KEY
}

test_creates_missing_env_and_generates_passwords_and_ssh_detection() {
  local tmpdir env_file out raw pass enc ssh_key ssh_path
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/bootstrap/bootstrap.env"
  mkdir -p "$tmpdir/home"
  make_fake_key "$tmpdir/home"

  out="$(HOME="$tmpdir/home" USER="$(id -un)" SUDO_USER="" bash "$script" --env-file "$env_file" 2>&1)"
  assert_file_contains "$env_file" '^COOLIFY_ROOT_USER_PASSWORD=' "env should contain COOLIFY_ROOT_USER_PASSWORD"
  assert_file_contains "$env_file" '^USER_PASSWORDS_ENCRYPTION_PASSWORD=' "env should contain USER_PASSWORDS_ENCRYPTION_PASSWORD"
  assert_file_contains "$env_file" '^SSH_PUBLIC_KEY=' "env should contain SSH_PUBLIC_KEY"
  assert_file_contains "$env_file" '^SSH_PUBLIC_KEY_PATH=' "env should contain SSH_PUBLIC_KEY_PATH"

  raw="$(env_value "$env_file" COOLIFY_ROOT_USER_PASSWORD)"
  pass="$(strip_env_quotes "$raw")"
  [[ "$pass" =~ ^[0-9a-f]{24}$ ]] || { echo "Invalid COOLIFY_ROOT_USER_PASSWORD: $pass" >&2; return 1; }

  raw="$(env_value "$env_file" USER_PASSWORDS_ENCRYPTION_PASSWORD)"
  enc="$(strip_env_quotes "$raw")"
  [[ "$enc" =~ ^[0-9a-f]{32}$ ]] || { echo "Invalid USER_PASSWORDS_ENCRYPTION_PASSWORD: $enc" >&2; return 1; }

  ssh_key="$(strip_env_quotes "$(env_value "$env_file" SSH_PUBLIC_KEY)")"
  ssh_path="$(strip_env_quotes "$(env_value "$env_file" SSH_PUBLIC_KEY_PATH)")"
  assert_contains "$ssh_key" "ssh-ed25519" "SSH_PUBLIC_KEY should be auto-detected"
  assert_contains "$ssh_path" "id_ed25519.pub" "SSH_PUBLIC_KEY_PATH should be auto-detected"
  assert_contains "$out" "auto-detected" "script should report SSH key auto-detection"

  rm -rf "$tmpdir"
}

test_no_detected_key_keeps_placeholder_and_warns() {
  local tmpdir env_file out
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/bootstrap.env"
  cp "$repo_root/env/bootstrap.env.example" "$env_file"

  out="$(HOME="$tmpdir/nohome" USER="$(id -un)" SUDO_USER="" bash "$script" --env-file "$env_file" 2>&1)"
  assert_contains "$out" "No local SSH public key detected" "script should warn when no SSH key is available"

  assert_contains "$(env_value "$env_file" SSH_PUBLIC_KEY_PATH)" "CHANGE_ME" "SSH_PUBLIC_KEY_PATH placeholder should remain when key is missing"
  assert_contains "$(env_value "$env_file" SSH_PUBLIC_KEY)" "CHANGE_ME" "SSH_PUBLIC_KEY placeholder should remain when key is missing"

  rm -rf "$tmpdir"
}

test_force_password_rotates_only_when_requested() {
  local tmpdir env_file first second third
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/bootstrap.env"
  cp "$repo_root/env/bootstrap.env.example" "$env_file"

  HOME="$tmpdir/home" USER="$(id -un)" SUDO_USER="" bash "$script" --env-file "$env_file" >/dev/null
  first="$(strip_env_quotes "$(env_value "$env_file" COOLIFY_ROOT_USER_PASSWORD)")"

  HOME="$tmpdir/home" USER="$(id -un)" SUDO_USER="" bash "$script" --env-file "$env_file" >/dev/null
  second="$(strip_env_quotes "$(env_value "$env_file" COOLIFY_ROOT_USER_PASSWORD)")"
  assert_eq "$first" "$second" "password should remain unchanged without --force-password"

  HOME="$tmpdir/home" USER="$(id -un)" SUDO_USER="" bash "$script" --env-file "$env_file" --force-password >/dev/null
  third="$(strip_env_quotes "$(env_value "$env_file" COOLIFY_ROOT_USER_PASSWORD)")"
  [[ "$third" != "$second" ]] || { echo "password did not rotate with --force-password" >&2; return 1; }

  rm -rf "$tmpdir"
}

test_force_encryption_password_rotates_only_when_requested() {
  local tmpdir env_file first second third
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/bootstrap.env"
  cp "$repo_root/env/bootstrap.env.example" "$env_file"

  HOME="$tmpdir/home" USER="$(id -un)" SUDO_USER="" bash "$script" --env-file "$env_file" >/dev/null
  first="$(strip_env_quotes "$(env_value "$env_file" USER_PASSWORDS_ENCRYPTION_PASSWORD)")"

  HOME="$tmpdir/home" USER="$(id -un)" SUDO_USER="" bash "$script" --env-file "$env_file" >/dev/null
  second="$(strip_env_quotes "$(env_value "$env_file" USER_PASSWORDS_ENCRYPTION_PASSWORD)")"
  assert_eq "$first" "$second" "encryption password should remain unchanged without --force-encryption-password"

  HOME="$tmpdir/home" USER="$(id -un)" SUDO_USER="" bash "$script" --env-file "$env_file" --force-encryption-password >/dev/null
  third="$(strip_env_quotes "$(env_value "$env_file" USER_PASSWORDS_ENCRYPTION_PASSWORD)")"
  [[ "$third" != "$second" ]] || { echo "encryption password did not rotate with --force-encryption-password" >&2; return 1; }

  rm -rf "$tmpdir"
}

test_force_ssh_key_replaces_existing_key_and_path() {
  local tmpdir env_file old_key old_path new_home
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/bootstrap.env"
  cp "$repo_root/env/bootstrap.env.example" "$env_file"

  old_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOLDKEY old@test"
  old_path="/old/path/id_old.pub"
  sed -i "s|^SSH_PUBLIC_KEY_PATH=.*|SSH_PUBLIC_KEY_PATH='$old_path'|" "$env_file"
  sed -i "s|^SSH_PUBLIC_KEY=.*|SSH_PUBLIC_KEY='$old_key'|" "$env_file"

  new_home="$tmpdir/home"
  make_fake_key "$new_home"

  # Without force, existing key/path must stay unchanged.
  HOME="$new_home" USER="$(id -un)" SUDO_USER="" bash "$script" --env-file "$env_file" >/dev/null
  assert_eq "$old_key" "$(strip_env_quotes "$(env_value "$env_file" SSH_PUBLIC_KEY)")" "SSH key should not change without --force-ssh-key"
  assert_eq "$old_path" "$(strip_env_quotes "$(env_value "$env_file" SSH_PUBLIC_KEY_PATH)")" "SSH key path should not change without --force-ssh-key"

  # With force, both key and path must be replaced by detected values.
  HOME="$new_home" USER="$(id -un)" SUDO_USER="" bash "$script" --env-file "$env_file" --force-ssh-key >/dev/null
  assert_not_contains "$(strip_env_quotes "$(env_value "$env_file" SSH_PUBLIC_KEY)")" "IOLDKEY" "SSH key should be replaced with detected one when --force-ssh-key is used"
  assert_contains "$(strip_env_quotes "$(env_value "$env_file" SSH_PUBLIC_KEY_PATH)")" "id_ed25519.pub" "SSH key path should be replaced with detected path when --force-ssh-key is used"

  rm -rf "$tmpdir"
}

test_env_file_custom_path_creates_parent_and_file() {
  local tmpdir env_file
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/nested/very/deep/bootstrap.env"

  HOME="$tmpdir/home" USER="$(id -un)" SUDO_USER="" bash "$script" --env-file "$env_file" >/dev/null
  [[ -f "$env_file" ]] || { echo "custom --env-file target should be created" >&2; return 1; }
  assert_file_contains "$env_file" '^DEVOPS_USER=' "newly created custom env file should be copied from example"

  rm -rf "$tmpdir"
}

test_rejects_directory_env_path() {
  local tmpdir out
  tmpdir="$(mktemp -d)"
  out="$(bash "$script" --env-file "$tmpdir" 2>&1 || true)"
  assert_contains "$out" "expected a file" "script should reject directory passed to --env-file"
  rm -rf "$tmpdir"
}

test_rejects_missing_env_file_value() {
  assert_failure "script should reject missing --env-file value" bash "$script" --env-file
}

test_appends_missing_ssh_key_lines_when_detected() {
  local tmpdir env_file
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/bootstrap.env"
  cp "$repo_root/env/bootstrap.env.example" "$env_file"
  sed -i '/^SSH_PUBLIC_KEY_PATH=/d;/^SSH_PUBLIC_KEY=/d' "$env_file"

  mkdir -p "$tmpdir/home"
  make_fake_key "$tmpdir/home"

  HOME="$tmpdir/home" USER="$(id -un)" SUDO_USER="" bash "$script" --env-file "$env_file" >/dev/null
  assert_file_contains "$env_file" '^SSH_PUBLIC_KEY=' "script should append SSH_PUBLIC_KEY when missing"
  assert_file_contains "$env_file" '^SSH_PUBLIC_KEY_PATH=' "script should append SSH_PUBLIC_KEY_PATH when missing"

  rm -rf "$tmpdir"
}

run_test "generate-secrets creates env + detects key + generates secrets" test_creates_missing_env_and_generates_passwords_and_ssh_detection
run_test "generate-secrets warns and keeps placeholders when no key" test_no_detected_key_keeps_placeholder_and_warns
run_test "generate-secrets rotates password only with --force-password" test_force_password_rotates_only_when_requested
run_test "generate-secrets rotates encryption password with --force-encryption-password" test_force_encryption_password_rotates_only_when_requested
run_test "generate-secrets replaces SSH key/key-path only with --force-ssh-key" test_force_ssh_key_replaces_existing_key_and_path
run_test "generate-secrets supports custom --env-file path creation" test_env_file_custom_path_creates_parent_and_file
run_test "generate-secrets rejects --env-file directory" test_rejects_directory_env_path
run_test "generate-secrets rejects missing --env-file value" test_rejects_missing_env_file_value
run_test "generate-secrets appends missing SSH key vars" test_appends_missing_ssh_key_lines_when_detected

report_and_exit
