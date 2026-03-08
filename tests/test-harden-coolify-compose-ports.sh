#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/testlib.sh
source "$repo_root/tests/testlib.sh"

hardener="$repo_root/scripts/harden-coolify-compose-ports.py"

run_hardener() {
  local base="$1"
  local prod="$2"
  set +e
  python3 "$hardener" "$base" "$prod" >/tmp/hardener.out 2>/tmp/hardener.err
  local status=$?
  set -e
  echo "$status"
}

test_applies_expected_transformations() {
  local tmpdir base prod status
  tmpdir="$(mktemp -d)"
  base="$tmpdir/docker-compose.yml"
  prod="$tmpdir/docker-compose.prod.yml"

  cat > "$base" <<'YAML'
services:
  coolify:
    ports:
      - "${APP_PORT:-8000}:8080"
YAML

  cat > "$prod" <<'YAML'
services:
  coolify-realtime:
    ports:
      - "${SOKETI_PORT:-6001}:6001"
      - "6002:6002"
YAML

  status="$(run_hardener "$base" "$prod")"
  assert_eq "10" "$status" "hardener should return 10 when it applies file changes"
  assert_file_not_contains "$base" '\$\{APP_PORT:-8000\}:8080' "APP_PORT publish should be removed"
  assert_file_contains "$prod" '^\s*expose:\s*$' "Soketi ports block should be converted to expose"
  assert_file_contains "$prod" '"6001"' "expose 6001 must exist"
  assert_file_contains "$prod" '"6002"' "expose 6002 must exist"

  rm -rf "$tmpdir"
}

test_returns_zero_when_already_hardened() {
  local tmpdir base prod status
  tmpdir="$(mktemp -d)"
  base="$tmpdir/docker-compose.yml"
  prod="$tmpdir/docker-compose.prod.yml"

  cat > "$base" <<'YAML'
services:
  coolify:
    expose:
      - "8080"
YAML

  cat > "$prod" <<'YAML'
services:
  coolify-realtime:
    expose:
      - "6001"
      - "6002"
YAML

  status="$(run_hardener "$base" "$prod")"
  assert_eq "0" "$status" "hardener should return 0 when compose is already hardened"

  rm -rf "$tmpdir"
}

test_rejects_unrecognized_8080_publish_rule() {
  local tmpdir base prod status
  tmpdir="$(mktemp -d)"
  base="$tmpdir/docker-compose.yml"
  prod="$tmpdir/docker-compose.prod.yml"

  cat > "$base" <<'YAML'
services:
  coolify:
    ports:
      - "127.0.0.1:8000:8080"
YAML

  cat > "$prod" <<'YAML'
services:
  coolify-realtime:
    expose:
      - "6001"
      - "6002"
YAML

  status="$(run_hardener "$base" "$prod")"
  assert_eq "20" "$status" "hardener should return 20 for unsupported 8080 publish formats"

  rm -rf "$tmpdir"
}

test_rejects_unrecognized_soketi_publish_rules() {
  local tmpdir base prod status
  tmpdir="$(mktemp -d)"
  base="$tmpdir/docker-compose.yml"
  prod="$tmpdir/docker-compose.prod.yml"

  cat > "$base" <<'YAML'
services:
  coolify:
    expose:
      - "8080"
YAML

  cat > "$prod" <<'YAML'
services:
  coolify-realtime:
    ports:
      - "6001:6001"
      - "6002:6002"
YAML

  status="$(run_hardener "$base" "$prod")"
  assert_eq "20" "$status" "hardener should return 20 for unsupported Soketi publish formats"

  rm -rf "$tmpdir"
}

run_test "harden-coolify-compose-ports applies expected compose transformations" test_applies_expected_transformations
run_test "harden-coolify-compose-ports returns 0 when already hardened" test_returns_zero_when_already_hardened
run_test "harden-coolify-compose-ports rejects unknown 8080 mapping" test_rejects_unrecognized_8080_publish_rule
run_test "harden-coolify-compose-ports rejects unknown 6001/6002 mapping" test_rejects_unrecognized_soketi_publish_rules

report_and_exit
