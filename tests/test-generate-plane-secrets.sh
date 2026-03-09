#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/testlib.sh
source "$repo_root/tests/testlib.sh"

script="$repo_root/scripts/generate-plane-secrets.sh"

test_creates_missing_env_and_generates_secrets_and_urls() {
  local tmpdir env_file secret db_pass redis_pass rabbit_pass db_url redis_url amqp_url
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/plane/plane.env"

  bash "$script" --env-file "$env_file" --no-infra-sync >/dev/null

  assert_file_contains "$env_file" '^SECRET_KEY=' "env should contain SECRET_KEY"
  assert_file_contains "$env_file" '^POSTGRES_PASSWORD=' "env should contain POSTGRES_PASSWORD"
  assert_file_contains "$env_file" '^REDIS_PASSWORD=' "env should contain REDIS_PASSWORD"
  assert_file_contains "$env_file" '^RABBITMQ_DEFAULT_PASS=' "env should contain RABBITMQ_DEFAULT_PASS"
  assert_file_contains "$env_file" '^DATABASE_URL=' "env should contain DATABASE_URL"
  assert_file_contains "$env_file" '^REDIS_URL=' "env should contain REDIS_URL"
  assert_file_contains "$env_file" '^AMQP_URL=' "env should contain AMQP_URL"

  secret="$(strip_env_quotes "$(env_value "$env_file" SECRET_KEY)")"
  db_pass="$(strip_env_quotes "$(env_value "$env_file" POSTGRES_PASSWORD)")"
  redis_pass="$(strip_env_quotes "$(env_value "$env_file" REDIS_PASSWORD)")"
  rabbit_pass="$(strip_env_quotes "$(env_value "$env_file" RABBITMQ_DEFAULT_PASS)")"
  db_url="$(strip_env_quotes "$(env_value "$env_file" DATABASE_URL)")"
  redis_url="$(strip_env_quotes "$(env_value "$env_file" REDIS_URL)")"
  amqp_url="$(strip_env_quotes "$(env_value "$env_file" AMQP_URL)")"

  [[ "$secret" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid SECRET_KEY: $secret" >&2; return 1; }
  [[ "$db_pass" =~ ^[0-9a-f]{32}$ ]] || { echo "Invalid POSTGRES_PASSWORD: $db_pass" >&2; return 1; }
  [[ "$redis_pass" =~ ^[0-9a-f]{32}$ ]] || { echo "Invalid REDIS_PASSWORD: $redis_pass" >&2; return 1; }
  [[ "$rabbit_pass" =~ ^[0-9a-f]{32}$ ]] || { echo "Invalid RABBITMQ_DEFAULT_PASS: $rabbit_pass" >&2; return 1; }

  assert_contains "$db_url" "$db_pass" "DATABASE_URL should include generated POSTGRES_PASSWORD"
  assert_contains "$redis_url" "$redis_pass" "REDIS_URL should include generated REDIS_PASSWORD"
  assert_contains "$amqp_url" "$rabbit_pass" "AMQP_URL should include generated RABBITMQ_DEFAULT_PASS"

  rm -rf "$tmpdir"
}

test_force_passwords_rotates_password_values() {
  local tmpdir env_file first second third
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/plane.env"

  bash "$script" --env-file "$env_file" --no-infra-sync >/dev/null
  first="$(strip_env_quotes "$(env_value "$env_file" POSTGRES_PASSWORD)")"

  bash "$script" --env-file "$env_file" --no-infra-sync >/dev/null
  second="$(strip_env_quotes "$(env_value "$env_file" POSTGRES_PASSWORD)")"
  assert_eq "$first" "$second" "POSTGRES_PASSWORD should remain unchanged without --force-passwords"

  bash "$script" --env-file "$env_file" --no-infra-sync --force-passwords >/dev/null
  third="$(strip_env_quotes "$(env_value "$env_file" POSTGRES_PASSWORD)")"
  [[ "$third" != "$second" ]] || { echo "POSTGRES_PASSWORD did not rotate with --force-passwords" >&2; return 1; }

  rm -rf "$tmpdir"
}

test_force_secrets_rotates_secret_values() {
  local tmpdir env_file first second third
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/plane.env"

  bash "$script" --env-file "$env_file" --no-infra-sync >/dev/null
  first="$(strip_env_quotes "$(env_value "$env_file" SECRET_KEY)")"

  bash "$script" --env-file "$env_file" --no-infra-sync >/dev/null
  second="$(strip_env_quotes "$(env_value "$env_file" SECRET_KEY)")"
  assert_eq "$first" "$second" "SECRET_KEY should remain unchanged without --force-secrets"

  bash "$script" --env-file "$env_file" --no-infra-sync --force-secrets >/dev/null
  third="$(strip_env_quotes "$(env_value "$env_file" SECRET_KEY)")"
  [[ "$third" != "$second" ]] || { echo "SECRET_KEY did not rotate with --force-secrets" >&2; return 1; }

  rm -rf "$tmpdir"
}

test_rejects_directory_env_path() {
  local tmpdir out
  tmpdir="$(mktemp -d)"
  out="$(bash "$script" --env-file "$tmpdir" 2>&1 || true)"
  assert_contains "$out" "expected a file" "script should reject directory passed to --env-file"
  rm -rf "$tmpdir"
}

test_rejects_missing_env_file_value() {
  assert_failure "script should reject missing --env-file value" bash "$script" --env-file
}

test_syncs_plane_values_from_infra_env_file() {
  local tmpdir env_file infra_file pg_pass redis_pass rabbit_pass s3_ak s3_sk db_url redis_url amqp_url
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/plane.env"
  infra_file="$tmpdir/production-infra.env"

  cat >"$infra_file" <<'EOF'
POSTGRES_APPS_USER='apps_admin_custom'
POSTGRES_APPS_PASSWORD='InfraPgPass-42'
POSTGRES_PLANE_DB='plane_main'
POSTGRES_APPS_CONTAINER_NAME='postgres-infra'
APPS_VALKEY_PASSWORD='InfraRedisPass-42'
VALKEY_APPS_CONTAINER_NAME='valkey-infra'
PLANE_RABBITMQ_USER='plane_custom'
PLANE_RABBITMQ_PASSWORD='InfraRabbitPass-42'
PLANE_RABBITMQ_VHOST='plane_vhost'
RABBITMQ_PLANE_CONTAINER_NAME='rabbit-infra'
PLANE_S3_ACCESS_KEY='PLNINFRAKEY123456789'
PLANE_S3_SECRET_KEY='InfraS3SecretValue42'
PLANE_S3_BUCKET='plane-artifacts'
EOF

  bash "$script" --env-file "$env_file" --infra-env-file "$infra_file" >/dev/null

  pg_pass="$(strip_env_quotes "$(env_value "$env_file" POSTGRES_PASSWORD)")"
  redis_pass="$(strip_env_quotes "$(env_value "$env_file" REDIS_PASSWORD)")"
  rabbit_pass="$(strip_env_quotes "$(env_value "$env_file" RABBITMQ_DEFAULT_PASS)")"
  s3_ak="$(strip_env_quotes "$(env_value "$env_file" AWS_ACCESS_KEY_ID)")"
  s3_sk="$(strip_env_quotes "$(env_value "$env_file" AWS_SECRET_ACCESS_KEY)")"
  db_url="$(strip_env_quotes "$(env_value "$env_file" DATABASE_URL)")"
  redis_url="$(strip_env_quotes "$(env_value "$env_file" REDIS_URL)")"
  amqp_url="$(strip_env_quotes "$(env_value "$env_file" AMQP_URL)")"

  assert_eq "apps_admin_custom" "$(strip_env_quotes "$(env_value "$env_file" POSTGRES_USER)")" "POSTGRES_USER should sync from infra"
  assert_eq "postgres-infra" "$(strip_env_quotes "$(env_value "$env_file" POSTGRES_HOST)")" "POSTGRES_HOST should sync from infra"
  assert_eq "plane_main" "$(strip_env_quotes "$(env_value "$env_file" POSTGRES_DB)")" "POSTGRES_DB should sync from infra"
  assert_eq "valkey-infra" "$(strip_env_quotes "$(env_value "$env_file" REDIS_HOST)")" "REDIS_HOST should sync from infra"
  assert_eq "rabbit-infra" "$(strip_env_quotes "$(env_value "$env_file" RABBITMQ_HOST)")" "RABBITMQ_HOST should sync from infra"
  assert_eq "plane_custom" "$(strip_env_quotes "$(env_value "$env_file" RABBITMQ_DEFAULT_USER)")" "RABBITMQ_DEFAULT_USER should sync from infra"
  assert_eq "plane_vhost" "$(strip_env_quotes "$(env_value "$env_file" RABBITMQ_VHOST)")" "RABBITMQ_VHOST should sync from infra"
  assert_eq "plane-artifacts" "$(strip_env_quotes "$(env_value "$env_file" AWS_S3_BUCKET_NAME)")" "AWS_S3_BUCKET_NAME should sync from infra"
  assert_eq "plane-artifacts" "$(strip_env_quotes "$(env_value "$env_file" BUCKET_NAME)")" "BUCKET_NAME should sync from infra"

  assert_eq "InfraPgPass-42" "$pg_pass" "POSTGRES_PASSWORD should sync from infra"
  assert_eq "InfraRedisPass-42" "$redis_pass" "REDIS_PASSWORD should sync from infra"
  assert_eq "InfraRabbitPass-42" "$rabbit_pass" "RABBITMQ_DEFAULT_PASS should sync from infra"
  assert_eq "PLNINFRAKEY123456789" "$s3_ak" "AWS_ACCESS_KEY_ID should sync from infra"
  assert_eq "InfraS3SecretValue42" "$s3_sk" "AWS_SECRET_ACCESS_KEY should sync from infra"

  assert_eq "postgresql://apps_admin_custom:InfraPgPass-42@postgres-infra:5432/plane_main" "$db_url" "DATABASE_URL should be regenerated from infra values"
  assert_eq "redis://default:InfraRedisPass-42@valkey-infra:6379/0" "$redis_url" "REDIS_URL should be regenerated from infra values"
  assert_eq "amqp://plane_custom:InfraRabbitPass-42@rabbit-infra:5672/plane_vhost" "$amqp_url" "AMQP_URL should be regenerated from infra values"

  rm -rf "$tmpdir"
}

test_no_infra_sync_ignores_infra_values() {
  local tmpdir env_file infra_file out pg_pass redis_pass rabbit_pass
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/plane.env"
  infra_file="$tmpdir/production-infra.env"

  cat >"$infra_file" <<'EOF'
POSTGRES_APPS_PASSWORD='InfraPgPass-42'
APPS_VALKEY_PASSWORD='InfraRedisPass-42'
PLANE_RABBITMQ_PASSWORD='InfraRabbitPass-42'
EOF

  out="$(bash "$script" --env-file "$env_file" --infra-env-file "$infra_file" --no-infra-sync 2>&1)"
  assert_contains "$out" "Infra sync disabled (--no-infra-sync)." "script should report disabled infra sync"

  pg_pass="$(strip_env_quotes "$(env_value "$env_file" POSTGRES_PASSWORD)")"
  redis_pass="$(strip_env_quotes "$(env_value "$env_file" REDIS_PASSWORD)")"
  rabbit_pass="$(strip_env_quotes "$(env_value "$env_file" RABBITMQ_DEFAULT_PASS)")"

  [[ "$pg_pass" =~ ^[0-9a-f]{32}$ ]] || { echo "POSTGRES_PASSWORD should be generated when infra sync is disabled" >&2; return 1; }
  [[ "$redis_pass" =~ ^[0-9a-f]{32}$ ]] || { echo "REDIS_PASSWORD should be generated when infra sync is disabled" >&2; return 1; }
  [[ "$rabbit_pass" =~ ^[0-9a-f]{32}$ ]] || { echo "RABBITMQ_DEFAULT_PASS should be generated when infra sync is disabled" >&2; return 1; }

  assert_not_contains "$pg_pass" "InfraPgPass-42" "POSTGRES_PASSWORD should not use infra value when sync is disabled"
  assert_not_contains "$redis_pass" "InfraRedisPass-42" "REDIS_PASSWORD should not use infra value when sync is disabled"
  assert_not_contains "$rabbit_pass" "InfraRabbitPass-42" "RABBITMQ_DEFAULT_PASS should not use infra value when sync is disabled"

  rm -rf "$tmpdir"
}

run_test "generate-plane-secrets creates env + generates secrets/passwords" test_creates_missing_env_and_generates_secrets_and_urls
run_test "generate-plane-secrets rotates passwords only with --force-passwords" test_force_passwords_rotates_password_values
run_test "generate-plane-secrets rotates secrets only with --force-secrets" test_force_secrets_rotates_secret_values
run_test "generate-plane-secrets syncs values from infra env" test_syncs_plane_values_from_infra_env_file
run_test "generate-plane-secrets disables infra sync with --no-infra-sync" test_no_infra_sync_ignores_infra_values
run_test "generate-plane-secrets rejects --env-file directory" test_rejects_directory_env_path
run_test "generate-plane-secrets rejects missing --env-file value" test_rejects_missing_env_file_value

report_and_exit
