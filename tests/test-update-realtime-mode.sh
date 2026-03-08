#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/testlib.sh
source "$repo_root/tests/testlib.sh"

script="$repo_root/scripts/update-realtime-mode.sh"

test_help() {
  local output
  output="$(bash "$script" --help 2>&1)"
  assert_contains "$output" "Usage:" "help should print usage"
}

test_rejects_unknown_arg() {
  assert_failure "script should fail on unknown args" bash "$script" --unknown-arg
}

test_requires_mode_value() {
  assert_failure "script should fail when --mode value is missing" bash "$script" --mode
}

run_test "update-realtime-mode prints help" test_help
run_test "update-realtime-mode rejects unknown arguments" test_rejects_unknown_arg
run_test "update-realtime-mode enforces required --mode value" test_requires_mode_value

report_and_exit
