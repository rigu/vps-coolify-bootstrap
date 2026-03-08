#!/usr/bin/env bash
set -euo pipefail

TESTS_TOTAL=0
TESTS_FAILED=0

fail() {
  local message="$1"
  echo "[FAIL] $message" >&2
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

pass() {
  local message="$1"
  echo "[PASS] $message"
}

run_test() {
  local name="$1"
  shift
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "$expected" != "$actual" ]]; then
    echo "Expected: [$expected]" >&2
    echo "Actual:   [$actual]" >&2
    echo "$message" >&2
    return 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "Missing substring: $needle" >&2
    echo "$message" >&2
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "Unexpected substring: $needle" >&2
    echo "$message" >&2
    return 1
  fi
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Eq "$pattern" "$file"; then
    echo "Pattern not found in $file: $pattern" >&2
    echo "$message" >&2
    return 1
  fi
}

assert_file_not_contains() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if grep -Eq "$pattern" "$file"; then
    echo "Unexpected pattern in $file: $pattern" >&2
    echo "$message" >&2
    return 1
  fi
}

assert_success() {
  local message="$1"
  shift
  if ! "$@"; then
    echo "$message" >&2
    return 1
  fi
}

assert_failure() {
  local message="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "$message" >&2
    return 1
  fi
}

strip_env_quotes() {
  local value="$1"
  if [[ "$value" =~ ^\'(.*)\'$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$value" =~ ^\"(.*)\"$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$value"
  fi
}

env_value() {
  local file="$1"
  local key="$2"
  sed -n "s/^${key}=//p" "$file" | tail -n1
}

report_and_exit() {
  echo
  echo "Tests total: $TESTS_TOTAL"
  echo "Tests failed: $TESTS_FAILED"
  if (( TESTS_FAILED > 0 )); then
    exit 1
  fi
}
