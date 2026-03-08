#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/testlib.sh
source "$repo_root/tests/testlib.sh"

script="$repo_root/scripts/recover-ssh-access.sh"

test_help_output() {
  local out
  out="$(bash "$script" --help 2>&1)"
  assert_contains "$out" "Emergency SSH recovery helper" "help output should describe recovery workflow"
  assert_contains "$out" "--close-22" "help output should include --close-22"
}

test_unknown_argument_fails() {
  local out
  out="$(bash "$script" --no-such-flag 2>&1 || true)"
  assert_contains "$out" "Unknown argument" "script should reject unknown arguments"
}

test_missing_value_arguments_fail() {
  assert_failure "script should reject missing --env-file value" bash "$script" --env-file
  assert_failure "script should reject missing --unban-ip value" bash "$script" --unban-ip
}

run_test "recover-ssh-access.sh prints help" test_help_output
run_test "recover-ssh-access.sh rejects unknown arguments" test_unknown_argument_fails
run_test "recover-ssh-access.sh enforces values for --env-file/--unban-ip" test_missing_value_arguments_fail

report_and_exit
