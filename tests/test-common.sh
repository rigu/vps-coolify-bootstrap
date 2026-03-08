#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/testlib.sh
source "$repo_root/tests/testlib.sh"

run_common() {
  local code="$1"
  bash -lc "set -euo pipefail; source '$repo_root/scripts/common.sh'; $code"
}

test_split_csv_to_lines_delimiters() {
  local out
  out="$(run_common "split_csv_to_lines 'devops, ops;qa   platform'")"
  assert_eq $'devops\nops\nqa\nplatform' "$out" "split_csv_to_lines should support comma/semicolon/space"
}

test_csv_contains_value_multi_delim() {
  run_common "csv_contains_value 'devops;ops qa,platform' 'qa'" 2>/dev/null
  assert_failure "csv_contains_value should return non-zero for missing value" run_common "csv_contains_value 'devops;ops qa,platform' 'missing'" 2>/dev/null
}

test_csv_append_unique() {
  local out
  out="$(run_common "csv_append_unique 'devops,ops' 'ops'")"
  assert_eq "devops,ops" "$out" "csv_append_unique should not duplicate existing value"
  out="$(run_common "csv_append_unique 'devops,ops' 'qa'")"
  assert_eq "devops,ops,qa" "$out" "csv_append_unique should append missing value"
}

test_load_env_file_strict_valid() {
  local tmpdir envf out
  tmpdir="$(mktemp -d)"
  envf="$tmpdir/ok.env"
  cat > "$envf" <<'ENV'
export SSH_PORT=2278
DEVOPS_USER='devops'
ADDITIONAL_SUDO_USERS=ops admin;qa
COOLIFY_PUBLIC_DOMAIN=hub.example.com
USER_PASSWORDS_ENCRYPTION_PASSWORD="abc123\\$value"
ENV

  out="$(run_common "load_env_file_strict '$envf'; printf '%s|%s|%s|%s' \"\$SSH_PORT\" \"\$DEVOPS_USER\" \"\$ADDITIONAL_SUDO_USERS\" \"\$COOLIFY_PUBLIC_DOMAIN\"")"
  assert_eq "2278|devops|ops admin;qa|hub.example.com" "$out" "load_env_file_strict should parse valid quoted/unquoted values"
  rm -rf "$tmpdir"
}

test_load_env_rejects_shell_expansion() {
  local tmpdir envf
  tmpdir="$(mktemp -d)"
  envf="$tmpdir/bad.env"
  cat > "$envf" <<'ENV'
COOLIFY_PUBLIC_DOMAIN=$(whoami)
ENV
  assert_failure "load_env_file_strict should reject shell expansion syntax" run_common "load_env_file_strict '$envf'"
  rm -rf "$tmpdir"
}

test_load_env_rejects_unquoted_whitespace_non_additional_users() {
  local tmpdir envf
  tmpdir="$(mktemp -d)"
  envf="$tmpdir/bad-space.env"
  cat > "$envf" <<'ENV'
COOLIFY_PUBLIC_DOMAIN=hub example.com
ENV
  assert_failure "load_env_file_strict should reject unquoted whitespace for non-ADDITIONAL_SUDO_USERS" run_common "load_env_file_strict '$envf'"
  rm -rf "$tmpdir"
}

test_load_env_rejects_invalid_line() {
  local tmpdir envf
  tmpdir="$(mktemp -d)"
  envf="$tmpdir/invalid.env"
  cat > "$envf" <<'ENV'
NOT_AN_ASSIGNMENT
ENV
  assert_failure "load_env_file_strict should reject invalid env lines" run_common "load_env_file_strict '$envf'"
  rm -rf "$tmpdir"
}

run_test "common.sh split_csv_to_lines handles , ; and spaces" test_split_csv_to_lines_delimiters
run_test "common.sh csv_contains_value works with mixed delimiters" test_csv_contains_value_multi_delim
run_test "common.sh csv_append_unique avoids duplicates" test_csv_append_unique
run_test "common.sh load_env_file_strict parses valid env" test_load_env_file_strict_valid
run_test "common.sh load_env_file_strict rejects shell expansion" test_load_env_rejects_shell_expansion
run_test "common.sh load_env_file_strict rejects invalid whitespace" test_load_env_rejects_unquoted_whitespace_non_additional_users
run_test "common.sh load_env_file_strict rejects invalid lines" test_load_env_rejects_invalid_line

report_and_exit
