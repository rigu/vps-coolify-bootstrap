#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/testlib.sh
source "$repo_root/tests/testlib.sh"

script="$repo_root/scripts/prepare-vps-coolify-init.sh"
template="$repo_root/templates/vps-init.template.yml"

make_key_file() {
  local file="$1"
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<'KEY'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBX3iXhWjvR6Z5Tqz6F3QmI3zYIud3q3GQ8Y4uL2xK7n test-prepare
KEY
}

write_valid_env() {
  local file="$1"
  local output_file="$2"
  local ssh_key_path="$3"
  local close_ports="$4"
  local realtime_domain="$5"
  local extra_users="$6"
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<ENV
TIMEZONE=UTC
SSH_PORT=2278
DEVOPS_USER=devops
COOLIFY_SUDO_NOPASSWD_USER=coolify
ADDITIONAL_SUDO_USERS=$extra_users
SSH_PUBLIC_KEY_PATH=$ssh_key_path
SSH_PUBLIC_KEY=CHANGE_ME_ssh_public_key
SSH_KEY_ROTATE=0
CLOSE_COOLIFY_REALTIME_PORTS=$close_ports
COOLIFY_REALTIME_DOMAIN=$realtime_domain
COOLIFY_PUBLIC_DOMAIN=hub.example.com
COOLIFY_ROOT_USERNAME=admin_main
COOLIFY_ROOT_USER_EMAIL=admin@example.com
COOLIFY_ROOT_USER_PASSWORD=Str0ng!Passw0rdAbC1
USER_PASSWORDS_ENCRYPTION_PASSWORD=0123456789abcdef0123456789abcdef
BOOTSTRAP_REPO_URL=https://github.com/rigu/vps-coolify-bootstrap.git
BOOTSTRAP_REPO_REF=main
TEMPLATE_FILE=$template
OUTPUT_FILE=$output_file
ENV
}

assert_yaml_valid() {
  local file="$1"
  python3 - <<PY
import yaml
from pathlib import Path
p = Path(r'''$file''')
yaml.safe_load(p.read_text(encoding='utf-8'))
print('ok')
PY
}

test_generates_valid_output_with_key_and_user_list_delimiters() {
  local tmpdir env_file out_file key_file
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/bootstrap.env"
  out_file="$tmpdir/out.yml"
  key_file="$tmpdir/keys/id_ed25519.pub"
  make_key_file "$key_file"
  write_valid_env "$env_file" "$out_file" "$key_file" "false" "" "ops, qa;sec platform"

  bash "$script" --env-file "$env_file"
  [[ -f "$out_file" ]] || { echo "output not generated" >&2; return 1; }
  assert_yaml_valid "$out_file" >/dev/null

  assert_file_contains "$out_file" '^\s+ssh_authorized_keys:' "generated YML should include ssh_authorized_keys when key is provided"
  assert_file_contains "$out_file" 'CLOSE_COOLIFY_REALTIME_PORTS=false' "generated env should keep close=false"
  assert_file_contains "$out_file" 'DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX=true' "generated env should default ParseAddr workaround toggle to true"
  assert_file_not_contains "$out_file" '_HERE' "no unreplaced placeholders should remain"

  rm -rf "$tmpdir"
}

test_warns_and_generates_without_ssh_key() {
  local tmpdir env_file out_file output
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/bootstrap.env"
  out_file="$tmpdir/out.yml"
  write_valid_env "$env_file" "$out_file" "CHANGE_ME_or_leave_empty" "false" "" ""

  output="$(bash "$script" --env-file "$env_file" 2>&1)"
  [[ -f "$out_file" ]] || { echo "output not generated without ssh key" >&2; return 1; }
  assert_contains "$output" "WARNING: SSH_PUBLIC_KEY and SSH_PUBLIC_KEY_PATH are empty" "script should emit explicit warning when SSH key missing"
  assert_file_not_contains "$out_file" '^\s+ssh_authorized_keys:' "generated YML should not include ssh_authorized_keys when key missing"
  assert_yaml_valid "$out_file" >/dev/null

  rm -rf "$tmpdir"
}

test_close_ports_true_falls_back_to_public_domain() {
  local tmpdir env_file out_file key_file
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/bootstrap.env"
  out_file="$tmpdir/out.yml"
  key_file="$tmpdir/keys/id_ed25519.pub"
  make_key_file "$key_file"
  write_valid_env "$env_file" "$out_file" "$key_file" "true" "" "ops"

  bash "$script" --env-file "$env_file" >/dev/null
  assert_file_contains "$out_file" 'CLOSE_COOLIFY_REALTIME_PORTS=true' "close=true should be preserved"
  assert_file_contains "$out_file" "COOLIFY_REALTIME_DOMAIN=''" "empty realtime domain should remain explicit in rendered env"
  rm -rf "$tmpdir"
}

test_close_ports_true_rejects_placeholder_realtime_domain() {
  local tmpdir env_file out_file key_file
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/bootstrap.env"
  out_file="$tmpdir/out.yml"
  key_file="$tmpdir/keys/id_ed25519.pub"
  make_key_file "$key_file"
  write_valid_env "$env_file" "$out_file" "$key_file" "true" "CHANGE_ME_realtime.example.com" "ops"

  assert_failure "prepare script should fail when CLOSE_COOLIFY_REALTIME_PORTS=true and COOLIFY_REALTIME_DOMAIN is placeholder" bash "$script" --env-file "$env_file"
  rm -rf "$tmpdir"
}

test_legacy_allow_public_mapping() {
  local tmpdir env_file out_file key_file
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/bootstrap.env"
  out_file="$tmpdir/out.yml"
  key_file="$tmpdir/keys/id_ed25519.pub"
  make_key_file "$key_file"
  write_valid_env "$env_file" "$out_file" "$key_file" "" "realtime.example.com" "ops"
  echo "ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS=0" >> "$env_file"

  bash "$script" --env-file "$env_file"
  assert_file_contains "$out_file" 'CLOSE_COOLIFY_REALTIME_PORTS=true' "legacy allow_public=0 should map to close=true"
  rm -rf "$tmpdir"
}

test_requires_overwrite_when_output_exists() {
  local tmpdir env_file out_file key_file
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/bootstrap.env"
  out_file="$tmpdir/out.yml"
  key_file="$tmpdir/keys/id_ed25519.pub"
  make_key_file "$key_file"
  write_valid_env "$env_file" "$out_file" "$key_file" "false" "" "ops"

  bash "$script" --env-file "$env_file"
  assert_failure "prepare script should fail if output exists and --overwrite not set" bash "$script" --env-file "$env_file"
  bash "$script" --env-file "$env_file" --overwrite >/dev/null
  rm -rf "$tmpdir"
}

test_env_file_plus_overwrite_combination_explicit() {
  local tmpdir env_file out_file key_file before after
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/nested/config/bootstrap.env"
  out_file="$tmpdir/nested/output/generated.yml"
  key_file="$tmpdir/keys/id_ed25519.pub"
  make_key_file "$key_file"
  write_valid_env "$env_file" "$out_file" "$key_file" "false" "" "ops"

  bash "$script" --env-file "$env_file" >/dev/null
  before="$(sha256sum "$out_file" | awk '{print $1}')"

  sed -i 's/^COOLIFY_PUBLIC_DOMAIN=.*/COOLIFY_PUBLIC_DOMAIN=hub2.example.com/' "$env_file"
  bash "$script" --env-file "$env_file" --overwrite >/dev/null
  after="$(sha256sum "$out_file" | awk '{print $1}')"

  [[ "$before" != "$after" ]] || { echo "output hash should change when re-rendering with --env-file + --overwrite" >&2; return 1; }
  assert_file_contains "$out_file" 'hub2\.example\.com' "overwritten output should contain updated env value"

  rm -rf "$tmpdir"
}

test_external_env_path_uses_repo_fallback_paths() {
  local tmpdir env_file key_file expected_out
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/bootstrap.env"
  key_file="$tmpdir/keys/id_ed25519.pub"
  make_key_file "$key_file"

  # Keep TEMPLATE_FILE/OUTPUT_FILE defaults from env example to verify fallback behavior.
  cp "$repo_root/env/bootstrap.env.example" "$env_file"
  sed -i "s|^SSH_PUBLIC_KEY_PATH=.*|SSH_PUBLIC_KEY_PATH=$key_file|" "$env_file"
  sed -i "s|^SSH_PUBLIC_KEY=.*|SSH_PUBLIC_KEY=CHANGE_ME_ssh_public_key|" "$env_file"
  sed -i "s|^TIMEZONE=.*|TIMEZONE=UTC|" "$env_file"
  sed -i "s|^SSH_PORT=.*|SSH_PORT=2278|" "$env_file"
  sed -i "s|^DEVOPS_USER=.*|DEVOPS_USER=devops|" "$env_file"
  sed -i "s|^COOLIFY_SUDO_NOPASSWD_USER=.*|COOLIFY_SUDO_NOPASSWD_USER=coolify|" "$env_file"
  sed -i "s|^ADDITIONAL_SUDO_USERS=.*|ADDITIONAL_SUDO_USERS=ops|" "$env_file"
  sed -i "s|^CLOSE_COOLIFY_REALTIME_PORTS=.*|CLOSE_COOLIFY_REALTIME_PORTS=false|" "$env_file"
  sed -i "s|^DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX=.*|DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX=true|" "$env_file"
  sed -i "s|^COOLIFY_REALTIME_DOMAIN=.*|COOLIFY_REALTIME_DOMAIN=|" "$env_file"
  sed -i "s|^COOLIFY_PUBLIC_DOMAIN=.*|COOLIFY_PUBLIC_DOMAIN=hub.example.com|" "$env_file"
  sed -i "s|^COOLIFY_ROOT_USERNAME=.*|COOLIFY_ROOT_USERNAME=admin_main|" "$env_file"
  sed -i "s|^COOLIFY_ROOT_USER_EMAIL=.*|COOLIFY_ROOT_USER_EMAIL=admin@example.com|" "$env_file"
  sed -i "s|^COOLIFY_ROOT_USER_PASSWORD=.*|COOLIFY_ROOT_USER_PASSWORD=Str0ng!Passw0rdAbC1|" "$env_file"
  sed -i "s|^USER_PASSWORDS_ENCRYPTION_PASSWORD=.*|USER_PASSWORDS_ENCRYPTION_PASSWORD=0123456789abcdef0123456789abcdef|" "$env_file"
  sed -i "s|^BOOTSTRAP_REPO_URL=.*|BOOTSTRAP_REPO_URL=https://github.com/rigu/vps-coolify-bootstrap.git|" "$env_file"
  sed -i "s|^BOOTSTRAP_REPO_REF=.*|BOOTSTRAP_REPO_REF=main|" "$env_file"

  bash "$script" --env-file "$env_file" --overwrite >/dev/null
  expected_out="$repo_root/bootstrap-artifacts/vps-coolify-init.generated.yml"
  [[ -f "$expected_out" ]] || { echo "expected fallback output not generated in repo: $expected_out" >&2; return 1; }
  assert_yaml_valid "$expected_out" >/dev/null

  rm -f "$expected_out"
  rm -rf "$tmpdir"
}

test_rejects_invalid_additional_user() {
  local tmpdir env_file out_file key_file
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/bootstrap.env"
  out_file="$tmpdir/out.yml"
  key_file="$tmpdir/keys/id_ed25519.pub"
  make_key_file "$key_file"
  write_valid_env "$env_file" "$out_file" "$key_file" "false" "" "valid,bad:user"

  assert_failure "prepare script should reject ADDITIONAL_SUDO_USERS values containing colon" bash "$script" --env-file "$env_file"
  rm -rf "$tmpdir"
}

test_rejects_invalid_parseaddr_fix_toggle() {
  local tmpdir env_file out_file key_file
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/bootstrap.env"
  out_file="$tmpdir/out.yml"
  key_file="$tmpdir/keys/id_ed25519.pub"
  make_key_file "$key_file"
  write_valid_env "$env_file" "$out_file" "$key_file" "false" "" "ops"

  echo "DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX=yes" >> "$env_file"
  assert_failure "prepare script should reject invalid DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX values" bash "$script" --env-file "$env_file"
  rm -rf "$tmpdir"
}

test_rejects_oversized_generated_file() {
  local tmpdir env_file out_file key_file huge
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/bootstrap.env"
  out_file="$tmpdir/out.yml"
  key_file="$tmpdir/keys/id_ed25519.pub"
  make_key_file "$key_file"
  write_valid_env "$env_file" "$out_file" "$key_file" "false" "" "ops"

  huge="$(head -c 36000 < /dev/zero | tr '\0' 'a')"
  sed -i "s|^COOLIFY_ROOT_USER_PASSWORD=.*|COOLIFY_ROOT_USER_PASSWORD=$huge|" "$env_file"

  assert_failure "prepare script should fail when generated file exceeds size limit" bash "$script" --env-file "$env_file" --overwrite
  rm -rf "$tmpdir"
}

test_missing_each_required_key_fails() {
  local key
  local -a required_keys=(
    TIMEZONE
    SSH_PORT
    COOLIFY_PUBLIC_DOMAIN
    COOLIFY_ROOT_USERNAME
    COOLIFY_ROOT_USER_EMAIL
    COOLIFY_ROOT_USER_PASSWORD
    USER_PASSWORDS_ENCRYPTION_PASSWORD
    BOOTSTRAP_REPO_URL
    BOOTSTRAP_REPO_REF
  )

  for key in "${required_keys[@]}"; do
    local tmpdir env_file out_file key_file
    tmpdir="$(mktemp -d)"
    env_file="$tmpdir/bootstrap.env"
    out_file="$tmpdir/out.yml"
    key_file="$tmpdir/keys/id_ed25519.pub"
    make_key_file "$key_file"
    write_valid_env "$env_file" "$out_file" "$key_file" "false" "" "ops"

    sed -i "/^${key}=/d" "$env_file"
    assert_failure "prepare script should fail when required key is missing: $key" bash "$script" --env-file "$env_file"
    rm -rf "$tmpdir"
  done
}

test_empty_required_value_fails() {
  local tmpdir env_file out_file key_file
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/bootstrap.env"
  out_file="$tmpdir/out.yml"
  key_file="$tmpdir/keys/id_ed25519.pub"
  make_key_file "$key_file"
  write_valid_env "$env_file" "$out_file" "$key_file" "false" "" "ops"

  sed -i 's/^COOLIFY_PUBLIC_DOMAIN=.*/COOLIFY_PUBLIC_DOMAIN=/' "$env_file"
  assert_failure "prepare script should fail when required key has empty value" bash "$script" --env-file "$env_file"
  rm -rf "$tmpdir"
}

test_rejects_missing_env_file_argument_value() {
  assert_failure "prepare script should reject missing --env-file value" bash "$script" --env-file
}

test_missing_devops_user_defaults_to_devops() {
  local tmpdir env_file out_file key_file
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/bootstrap.env"
  out_file="$tmpdir/out.yml"
  key_file="$tmpdir/keys/id_ed25519.pub"
  make_key_file "$key_file"
  write_valid_env "$env_file" "$out_file" "$key_file" "false" "" "ops"

  sed -i '/^DEVOPS_USER=/d' "$env_file"
  bash "$script" --env-file "$env_file"
  assert_file_contains "$out_file" "name: devops" "missing DEVOPS_USER should default to devops"
  rm -rf "$tmpdir"
}

run_test "prepare-vps-coolify-init generates valid YAML with SSH key" test_generates_valid_output_with_key_and_user_list_delimiters
run_test "prepare-vps-coolify-init warns but succeeds without SSH key" test_warns_and_generates_without_ssh_key
run_test "prepare-vps-coolify-init closed mode falls back to COOLIFY_PUBLIC_DOMAIN when realtime domain is empty" test_close_ports_true_falls_back_to_public_domain
run_test "prepare-vps-coolify-init rejects placeholder realtime domain in closed mode" test_close_ports_true_rejects_placeholder_realtime_domain
run_test "prepare-vps-coolify-init maps legacy ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS" test_legacy_allow_public_mapping
run_test "prepare-vps-coolify-init enforces --overwrite" test_requires_overwrite_when_output_exists
run_test "prepare-vps-coolify-init supports --env-file + --overwrite together" test_env_file_plus_overwrite_combination_explicit
run_test "prepare-vps-coolify-init supports external env path with default template/output fallback" test_external_env_path_uses_repo_fallback_paths
run_test "prepare-vps-coolify-init rejects invalid additional users" test_rejects_invalid_additional_user
run_test "prepare-vps-coolify-init rejects invalid ParseAddr workaround toggle" test_rejects_invalid_parseaddr_fix_toggle
run_test "prepare-vps-coolify-init enforces output size limit" test_rejects_oversized_generated_file
run_test "prepare-vps-coolify-init fails when any required env key is missing" test_missing_each_required_key_fails
run_test "prepare-vps-coolify-init fails when required env value is empty" test_empty_required_value_fails
run_test "prepare-vps-coolify-init defaults DEVOPS_USER when key is missing" test_missing_devops_user_defaults_to_devops
run_test "prepare-vps-coolify-init rejects missing --env-file value" test_rejects_missing_env_file_argument_value

report_and_exit
