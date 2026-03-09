#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/testlib.sh
source "$repo_root/tests/testlib.sh"

script="$repo_root/scripts/verify-infra-state.sh"

test_help() {
  local out
  out="$(bash "$script" --help)"
  assert_contains "$out" "Validate internal service layer state after setup-infra apply." "help should describe verify-infra-state behavior"
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

run_test "verify-infra-state prints help" test_help
run_test "verify-infra-state rejects unknown arguments" test_rejects_unknown_arg
run_test "verify-infra-state enforces required value args" test_requires_value_args

report_and_exit
