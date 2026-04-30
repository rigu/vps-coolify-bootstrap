#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/testlib.sh
source "$repo_root/tests/testlib.sh"

script="$repo_root/scripts/setup-backup-infra.sh"

test_help() {
  local out
  out="$(bash "$script" --help)"
  assert_contains "$out" "Automate shared infra backup setup on a VPS" "help should describe setup-backup-infra behavior"
}

test_rejects_unknown_arg() {
  local out
  out="$(bash "$script" --unknown 2>&1 || true)"
  assert_contains "$out" "Unknown argument" "script should reject unknown args"
}

test_requires_value_args() {
  local out
  out="$(bash "$script" --env-file 2>&1 || true)"
  assert_contains "$out" "--env-file requires a value." "script should enforce --env-file value"
}

make_temp_env_file() {
  local envf="$1"
  cat >"$envf" <<'EOF'
POSTGRES_ENABLE_WAL_ARCHIVE=false
EOF
}

test_rejects_non_numeric_retention_days() {
  local tmpdir
  local envf
  local out
  tmpdir="$(mktemp -d)"
  envf="$tmpdir/production-infra.env"
  make_temp_env_file "$envf"
  out="$(bash "$script" --env-file "$envf" --retention-days nope 2>&1 || true)"
  rm -rf "$tmpdir"
  assert_contains "$out" "--retention-days must be numeric." "script should reject non-numeric retention days"
}

test_rejects_non_numeric_basebackup_retention_days() {
  local tmpdir
  local envf
  local out
  tmpdir="$(mktemp -d)"
  envf="$tmpdir/production-infra.env"
  make_temp_env_file "$envf"
  out="$(bash "$script" --env-file "$envf" --basebackup-retention-days nope 2>&1 || true)"
  rm -rf "$tmpdir"
  assert_contains "$out" "--basebackup-retention-days must be numeric." "script should reject non-numeric basebackup retention days"
}

test_rejects_unsafe_env_shell_expansion() {
  local tmpdir
  local envf
  local out
  tmpdir="$(mktemp -d)"
  envf="$tmpdir/production-infra.env"
  cat >"$envf" <<'EOF'
POSTGRES_ENABLE_WAL_ARCHIVE=$(id)
EOF
  out="$(bash "$script" --env-file "$envf" --skip-manual-run 2>&1 || true)"
  rm -rf "$tmpdir"
  assert_contains "$out" "potential shell expansion syntax" "script should reject unsafe env shell expansion"
}

test_backup_scripts_parse() {
  bash -n "$repo_root/scripts/setup-backup-infra.sh"
  bash -n "$repo_root/scripts/pg-backup-infra.sh"
  bash -n "$repo_root/scripts/pg-basebackup-infra.sh"
  bash -n "$repo_root/scripts/offsite-backup-sync.example.sh"
}

test_backup_service_does_not_trigger_offsite_implicitly() {
  assert_file_not_contains \
    "$repo_root/systemd/pg-backup-infra.service" \
    '^OnSuccess=offsite-backup-sync\.service$' \
    "local backup service should not implicitly trigger off-site sync"
}

test_backup_scripts_pass_shellcheck_when_available() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    return 0
  fi

  shellcheck \
    "$repo_root/scripts/setup-backup-infra.sh" \
    "$repo_root/scripts/pg-backup-infra.sh" \
    "$repo_root/scripts/pg-basebackup-infra.sh" \
    "$repo_root/scripts/offsite-backup-sync.example.sh"
}

run_test "setup-backup-infra prints help" test_help
run_test "setup-backup-infra rejects unknown arguments" test_rejects_unknown_arg
run_test "setup-backup-infra enforces required value args" test_requires_value_args
run_test "setup-backup-infra rejects non-numeric retention days" test_rejects_non_numeric_retention_days
run_test "setup-backup-infra rejects non-numeric basebackup retention days" test_rejects_non_numeric_basebackup_retention_days
run_test "setup-backup-infra rejects unsafe env shell expansion" test_rejects_unsafe_env_shell_expansion
run_test "backup scripts pass bash -n" test_backup_scripts_parse
run_test "pg-backup-infra.service does not chain off-site sync implicitly" test_backup_service_does_not_trigger_offsite_implicitly
run_test "backup scripts pass shellcheck when available" test_backup_scripts_pass_shellcheck_when_available

report_and_exit
