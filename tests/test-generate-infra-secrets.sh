#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/testlib.sh
source "$repo_root/tests/testlib.sh"

script="$repo_root/scripts/generate-infra-secrets.sh"

test_creates_missing_env_and_generates_secrets() {
  local tmpdir env_file pg valkey rabbit s3ak s3sk
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/infra/production-infra.env"

  bash "$script" --env-file "$env_file" >/dev/null

  assert_file_contains "$env_file" '^POSTGRES_APPS_PASSWORD=' "env should contain POSTGRES_APPS_PASSWORD"
  assert_file_contains "$env_file" '^APPS_VALKEY_PASSWORD=' "env should contain APPS_VALKEY_PASSWORD"
  assert_file_contains "$env_file" '^PLANE_RABBITMQ_PASSWORD=' "env should contain PLANE_RABBITMQ_PASSWORD"
  assert_file_contains "$env_file" '^PLANE_S3_ACCESS_KEY=' "env should contain PLANE_S3_ACCESS_KEY"
  assert_file_contains "$env_file" '^PLANE_S3_SECRET_KEY=' "env should contain PLANE_S3_SECRET_KEY"

  pg="$(strip_env_quotes "$(env_value "$env_file" POSTGRES_APPS_PASSWORD)")"
  valkey="$(strip_env_quotes "$(env_value "$env_file" APPS_VALKEY_PASSWORD)")"
  rabbit="$(strip_env_quotes "$(env_value "$env_file" PLANE_RABBITMQ_PASSWORD)")"
  s3ak="$(strip_env_quotes "$(env_value "$env_file" PLANE_S3_ACCESS_KEY)")"
  s3sk="$(strip_env_quotes "$(env_value "$env_file" PLANE_S3_SECRET_KEY)")"

  [[ "$pg" =~ ^[0-9a-f]{32}$ ]] || { echo "Invalid POSTGRES_APPS_PASSWORD: $pg" >&2; return 1; }
  [[ "$valkey" =~ ^[0-9a-f]{32}$ ]] || { echo "Invalid APPS_VALKEY_PASSWORD: $valkey" >&2; return 1; }
  [[ "$rabbit" =~ ^[0-9a-f]{32}$ ]] || { echo "Invalid PLANE_RABBITMQ_PASSWORD: $rabbit" >&2; return 1; }
  [[ "$s3ak" =~ ^PLN[0-9A-F]{18}$ ]] || { echo "Invalid PLANE_S3_ACCESS_KEY: $s3ak" >&2; return 1; }
  [[ "$s3sk" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid PLANE_S3_SECRET_KEY: $s3sk" >&2; return 1; }

  rm -rf "$tmpdir"
}

test_force_passwords_rotates_only_passwords() {
  local tmpdir env_file pg1 pg2 pg3 s3k1 s3k2
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/production-infra.env"

  bash "$script" --env-file "$env_file" >/dev/null
  pg1="$(strip_env_quotes "$(env_value "$env_file" POSTGRES_APPS_PASSWORD)")"
  s3k1="$(strip_env_quotes "$(env_value "$env_file" PLANE_S3_SECRET_KEY)")"

  bash "$script" --env-file "$env_file" >/dev/null
  pg2="$(strip_env_quotes "$(env_value "$env_file" POSTGRES_APPS_PASSWORD)")"
  s3k2="$(strip_env_quotes "$(env_value "$env_file" PLANE_S3_SECRET_KEY)")"
  assert_eq "$pg1" "$pg2" "POSTGRES_APPS_PASSWORD should remain unchanged without force"
  assert_eq "$s3k1" "$s3k2" "PLANE_S3_SECRET_KEY should remain unchanged without force"

  bash "$script" --env-file "$env_file" --force-passwords >/dev/null
  pg3="$(strip_env_quotes "$(env_value "$env_file" POSTGRES_APPS_PASSWORD)")"
  [[ "$pg3" != "$pg2" ]] || { echo "POSTGRES_APPS_PASSWORD did not rotate with --force-passwords" >&2; return 1; }

  rm -rf "$tmpdir"
}

test_rejects_directory_env_path() {
  local tmpdir out
  tmpdir="$(mktemp -d)"
  out="$(bash "$script" --env-file "$tmpdir" 2>&1 || true)"
  assert_contains "$out" "expected a file" "script should reject directory passed to --env-file"
  rm -rf "$tmpdir"
}

run_test "generate-infra-secrets creates env + generated secrets" test_creates_missing_env_and_generates_secrets
run_test "generate-infra-secrets rotates passwords with --force-passwords" test_force_passwords_rotates_only_passwords
run_test "generate-infra-secrets rejects --env-file directory" test_rejects_directory_env_path

report_and_exit
