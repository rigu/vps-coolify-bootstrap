#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/testlib.sh
source "$repo_root/tests/testlib.sh"

script="$repo_root/scripts/generate-docmost-secrets.sh"

test_generate_docmost_creates_env_and_secret() {
  local tmpdir env_file app_secret
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/docmost.env"

  bash "$script" --env-file "$env_file" --no-infra-sync >/dev/null

  [[ -f "$env_file" ]] || { echo "env file was not created" >&2; return 1; }

  app_secret="$(strip_env_quotes "$(env_value "$env_file" APP_SECRET)")"
  [[ "$app_secret" =~ ^[0-9a-f]{64}$ ]] || { echo "APP_SECRET should be 64 hex chars" >&2; return 1; }

  rm -rf "$tmpdir"
}

test_generate_docmost_syncs_from_infra_env() {
  local tmpdir env_file infra_file db_url redis_url infra_network
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/docmost.env"
  infra_file="$tmpdir/production-infra.env"

  cat > "$infra_file" <<'INFRA'
INFRA_NETWORK_NAME=infra-shared
POSTGRES_APPS_USER=apps_admin
POSTGRES_APPS_PASSWORD=InfraPgPass-42
POSTGRES_DOCMOST_DB=docmost_main
POSTGRES_APPS_CONTAINER_NAME=postgres-infra
APPS_VALKEY_PASSWORD=InfraRedisPass-42
VALKEY_APPS_CONTAINER_NAME=valkey-infra
INFRA

  bash "$script" --env-file "$env_file" --infra-env-file "$infra_file" >/dev/null

  db_url="$(strip_env_quotes "$(env_value "$env_file" DATABASE_URL)")"
  redis_url="$(strip_env_quotes "$(env_value "$env_file" REDIS_URL)")"
  infra_network="$(strip_env_quotes "$(env_value "$env_file" INFRA_NETWORK_NAME)")"

  assert_eq "postgresql://apps_admin:InfraPgPass-42@postgres-infra:5432/docmost_main?schema=public" "$db_url" "DATABASE_URL should be synchronized from infra" || return 1
  assert_eq "redis://default:InfraRedisPass-42@valkey-infra:6379/1" "$redis_url" "REDIS_URL should be synchronized from infra" || return 1
  assert_eq "infra-shared" "$infra_network" "INFRA_NETWORK_NAME should be synchronized from infra" || return 1

  rm -rf "$tmpdir"
}

test_generate_docmost_force_app_secret() {
  local tmpdir env_file first second third
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/docmost.env"

  bash "$script" --env-file "$env_file" --no-infra-sync >/dev/null
  first="$(strip_env_quotes "$(env_value "$env_file" APP_SECRET)")"

  bash "$script" --env-file "$env_file" --no-infra-sync >/dev/null
  second="$(strip_env_quotes "$(env_value "$env_file" APP_SECRET)")"
  assert_eq "$first" "$second" "APP_SECRET should stay unchanged without force" || return 1

  bash "$script" --env-file "$env_file" --no-infra-sync --force-app-secret >/dev/null
  third="$(strip_env_quotes "$(env_value "$env_file" APP_SECRET)")"
  [[ "$third" != "$second" ]] || { echo "APP_SECRET should rotate with --force-app-secret" >&2; return 1; }

  rm -rf "$tmpdir"
}

test_generate_docmost_rejects_env_file_directory() {
  local tmpdir out
  tmpdir="$(mktemp -d)"
  out="$(bash "$script" --env-file "$tmpdir" 2>&1 || true)"
  assert_contains "$out" "--env-file points to a directory" "script should reject --env-file directory" || return 1
  rm -rf "$tmpdir"
}

run_test "generate-docmost-secrets creates env + app secret" test_generate_docmost_creates_env_and_secret
run_test "generate-docmost-secrets syncs DATABASE_URL/REDIS_URL from infra env" test_generate_docmost_syncs_from_infra_env
run_test "generate-docmost-secrets rotates APP_SECRET only when forced" test_generate_docmost_force_app_secret
run_test "generate-docmost-secrets rejects --env-file directory" test_generate_docmost_rejects_env_file_directory

report_and_exit
