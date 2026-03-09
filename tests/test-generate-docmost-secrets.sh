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
  local tmpdir env_file infra_file db_url redis_url infra_network \
    smtp_host mail_from_address drawio_url s3_key s3_secret s3_bucket s3_endpoint \
    disable_telemetry search_driver typesense_url typesense_api_key typesense_locale
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
SMTP_HOST=smtp.infra.internal
SMTP_PORT=465
SMTP_USERNAME=infra-mail-user
SMTP_PASSWORD=InfraMailPass-42
SMTP_SECURE=true
MAIL_FROM_ADDRESS=noreply@infra.example
MAIL_FROM_NAME=Infra Docmost
DRAWIO_URL=https://drawio.infra.example
PLANE_S3_ACCESS_KEY=PLNINFRAKEY123456789
PLANE_S3_SECRET_KEY=InfraS3SecretValue42
PLANE_S3_BUCKET=docmost-assets
SEAWEEDFS_PLANE_CONTAINER_NAME=seaweedfs-infra
DISABLE_TELEMETRY=false
SEARCH_DRIVER=typesense
TYPESENSE_URL=http://typesense-infra:8108
TYPESENSE_API_KEY=InfraTypesenseApiKey42
TYPESENSE_LOCALE=ro
INFRA

  bash "$script" --env-file "$env_file" --infra-env-file "$infra_file" >/dev/null

  db_url="$(strip_env_quotes "$(env_value "$env_file" DATABASE_URL)")"
  redis_url="$(strip_env_quotes "$(env_value "$env_file" REDIS_URL)")"
  infra_network="$(strip_env_quotes "$(env_value "$env_file" INFRA_NETWORK_NAME)")"
  smtp_host="$(strip_env_quotes "$(env_value "$env_file" SMTP_HOST)")"
  mail_from_address="$(strip_env_quotes "$(env_value "$env_file" MAIL_FROM_ADDRESS)")"
  drawio_url="$(strip_env_quotes "$(env_value "$env_file" DRAWIO_URL)")"
  s3_key="$(strip_env_quotes "$(env_value "$env_file" AWS_S3_ACCESS_KEY_ID)")"
  s3_secret="$(strip_env_quotes "$(env_value "$env_file" AWS_S3_SECRET_ACCESS_KEY)")"
  s3_bucket="$(strip_env_quotes "$(env_value "$env_file" AWS_S3_BUCKET)")"
  s3_endpoint="$(strip_env_quotes "$(env_value "$env_file" AWS_S3_ENDPOINT)")"
  disable_telemetry="$(strip_env_quotes "$(env_value "$env_file" DISABLE_TELEMETRY)")"
  search_driver="$(strip_env_quotes "$(env_value "$env_file" SEARCH_DRIVER)")"
  typesense_url="$(strip_env_quotes "$(env_value "$env_file" TYPESENSE_URL)")"
  typesense_api_key="$(strip_env_quotes "$(env_value "$env_file" TYPESENSE_API_KEY)")"
  typesense_locale="$(strip_env_quotes "$(env_value "$env_file" TYPESENSE_LOCALE)")"

  assert_eq "postgresql://apps_admin:InfraPgPass-42@postgres-infra:5432/docmost_main?schema=public" "$db_url" "DATABASE_URL should be synchronized from infra" || return 1
  assert_eq "redis://default:InfraRedisPass-42@valkey-infra:6379/1" "$redis_url" "REDIS_URL should be synchronized from infra" || return 1
  assert_eq "infra-shared" "$infra_network" "INFRA_NETWORK_NAME should be synchronized from infra" || return 1
  assert_eq "smtp.infra.internal" "$smtp_host" "SMTP_HOST should be synchronized from infra" || return 1
  assert_eq "noreply@infra.example" "$mail_from_address" "MAIL_FROM_ADDRESS should be synchronized from infra" || return 1
  assert_eq "https://drawio.infra.example" "$drawio_url" "DRAWIO_URL should be synchronized from infra" || return 1
  assert_eq "PLNINFRAKEY123456789" "$s3_key" "AWS_S3_ACCESS_KEY_ID should be synchronized from infra" || return 1
  assert_eq "InfraS3SecretValue42" "$s3_secret" "AWS_S3_SECRET_ACCESS_KEY should be synchronized from infra" || return 1
  assert_eq "docmost-assets" "$s3_bucket" "AWS_S3_BUCKET should be synchronized from infra" || return 1
  assert_eq "http://seaweedfs-infra:8333" "$s3_endpoint" "AWS_S3_ENDPOINT should be synchronized from infra" || return 1
  assert_eq "false" "$disable_telemetry" "DISABLE_TELEMETRY should be synchronized from infra" || return 1
  assert_eq "typesense" "$search_driver" "SEARCH_DRIVER should be synchronized from infra" || return 1
  assert_eq "http://typesense-infra:8108" "$typesense_url" "TYPESENSE_URL should be synchronized from infra" || return 1
  assert_eq "InfraTypesenseApiKey42" "$typesense_api_key" "TYPESENSE_API_KEY should be synchronized from infra" || return 1
  assert_eq "ro" "$typesense_locale" "TYPESENSE_LOCALE should be synchronized from infra" || return 1

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
run_test "generate-docmost-secrets syncs infra-derived Docmost values from infra env" test_generate_docmost_syncs_from_infra_env
run_test "generate-docmost-secrets rotates APP_SECRET only when forced" test_generate_docmost_force_app_secret
run_test "generate-docmost-secrets rejects --env-file directory" test_generate_docmost_rejects_env_file_directory

report_and_exit
