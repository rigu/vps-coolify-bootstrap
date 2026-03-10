#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/testlib.sh
source "$repo_root/tests/testlib.sh"

gen_script="$repo_root/scripts/generate-infra-secrets.sh"
prep_script="$repo_root/scripts/prepare-infra-compose.sh"

test_prepare_infra_compose_generates_runtime_files() {
  local tmpdir env_file out_dir
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/production-infra.env"
  out_dir="$tmpdir/out"

  bash "$gen_script" --env-file "$env_file" >/dev/null
  bash "$prep_script" --env-file "$env_file" --output-dir "$out_dir" >/dev/null

  [[ -f "$out_dir/docker-compose.yml" ]] || { echo "missing docker-compose.yml" >&2; return 1; }
  [[ -f "$out_dir/valkey.conf" ]] || { echo "missing valkey.conf" >&2; return 1; }
  [[ -f "$out_dir/seaweedfs-s3-config.json" ]] || { echo "missing seaweedfs-s3-config.json" >&2; return 1; }
  [[ -f "$out_dir/postgres-apps-init.sh" ]] || { echo "missing postgres-apps-init.sh" >&2; return 1; }
  [[ -f "$out_dir/production-infra.env" ]] || { echo "missing production-infra.env" >&2; return 1; }
  [[ -d "$out_dir/postgres-wal-archive" ]] || { echo "missing postgres-wal-archive dir" >&2; return 1; }

  assert_file_not_contains "$out_dir/docker-compose.yml" '_HERE' "compose output should not contain unresolved placeholders"
  assert_file_not_contains "$out_dir/valkey.conf" '_HERE' "valkey output should not contain unresolved placeholders"
  assert_file_not_contains "$out_dir/seaweedfs-s3-config.json" '_HERE' "seaweedfs output should not contain unresolved placeholders"
  assert_file_contains "$out_dir/docker-compose.yml" 'redis-cli .*\\|\\| valkey-cli' "valkey healthcheck should support redis-cli and valkey-cli fallback"
  assert_file_contains "$out_dir/docker-compose.yml" 'archive_mode=' "compose output should configure Postgres archive mode"

  if command -v python3 >/dev/null 2>&1; then
    python3 - <<PY
import yaml, json
yaml.safe_load(open('$out_dir/docker-compose.yml', encoding='utf-8').read())
json.load(open('$out_dir/seaweedfs-s3-config.json', encoding='utf-8'))
PY
  fi

  rm -rf "$tmpdir"
}

test_prepare_infra_compose_rejects_placeholders() {
  local tmpdir env_file out
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/production-infra.env"
  cp "$repo_root/env/infra.env.example" "$env_file"

  out="$(bash "$prep_script" --env-file "$env_file" --output-dir "$tmpdir/out" 2>&1 || true)"
  assert_contains "$out" "CHANGE_ME" "prepare script should reject unresolved CHANGE_ME secrets"

  rm -rf "$tmpdir"
}

run_test "prepare-infra-compose generates runtime files" test_prepare_infra_compose_generates_runtime_files
run_test "prepare-infra-compose rejects unresolved placeholders" test_prepare_infra_compose_rejects_placeholders

report_and_exit
