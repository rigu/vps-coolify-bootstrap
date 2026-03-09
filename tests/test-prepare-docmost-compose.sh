#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/testlib.sh
source "$repo_root/tests/testlib.sh"

gen_script="$repo_root/scripts/generate-docmost-secrets.sh"
prep_script="$repo_root/scripts/prepare-docmost-compose.sh"
template_file="$repo_root/templates/docmost-coolify-compose.community.template.yml"

test_prepare_docmost_compose_renders_from_env() {
  local tmpdir env_file out_file app_secret
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/docmost.env"
  out_file="$tmpdir/docmost-compose.yml"

  bash "$gen_script" --env-file "$env_file" --no-infra-sync >/dev/null
  bash "$prep_script" --env-file "$env_file" --template-file "$template_file" --output-file "$out_file" >/dev/null

  [[ -f "$out_file" ]] || { echo "missing rendered compose output" >&2; return 1; }
  if stat --version >/dev/null 2>&1; then
    assert_eq "600" "$(stat -c '%a' "$out_file")" "rendered compose should be mode 600" || return 1
  fi
  assert_file_contains "$out_file" "APP_SECRET: \\\${APP_SECRET:-" "compose should preserve env variable syntax with defaults" || return 1
  assert_file_contains "$out_file" "image: \"\\\${DOCMOST_IMAGE:-docmost/docmost:latest}\"" "image should keep variable with resolved default" || return 1
  if awk '!/^[[:space:]]*#/' "$out_file" | grep -Eq '\$\{[A-Za-z_][A-Za-z0-9_]*:\?'; then
    echo "required interpolation should be converted to default interpolation on active lines" >&2
    return 1
  fi

  app_secret="$(strip_env_quotes "$(env_value "$env_file" APP_SECRET)")"
  assert_file_contains "$out_file" "APP_SECRET: \\\${APP_SECRET:-${app_secret}}" "APP_SECRET default should come from docmost env" || return 1

  if command -v python3 >/dev/null 2>&1; then
    python3 - <<PY
import yaml
yaml.safe_load(open('$out_file', encoding='utf-8').read())
PY
  fi

  rm -rf "$tmpdir"
}

test_prepare_docmost_compose_fails_for_missing_required_var() {
  local tmpdir env_file out_file out
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/docmost.env"
  out_file="$tmpdir/docmost-compose.yml"

  bash "$gen_script" --env-file "$env_file" --no-infra-sync >/dev/null
  grep -Ev '^APP_SECRET=' "$env_file" > "$env_file.tmp"
  mv "$env_file.tmp" "$env_file"

  out="$(bash "$prep_script" --env-file "$env_file" --template-file "$template_file" --output-file "$out_file" 2>&1 || true)"
  assert_contains "$out" "Missing APP_SECRET" "renderer should fail fast for missing APP_SECRET" || return 1

  rm -rf "$tmpdir"
}

test_prepare_docmost_compose_creates_env_from_example_when_missing() {
  local tmpdir env_file out_file
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/new/docmost.env"
  out_file="$tmpdir/out/docmost-compose.yml"

  bash "$prep_script" --env-file "$env_file" --template-file "$template_file" --output-file "$out_file" >/dev/null

  [[ -f "$env_file" ]] || { echo "env file was not created from example" >&2; return 1; }
  [[ -f "$out_file" ]] || { echo "rendered compose output was not created" >&2; return 1; }
  assert_file_contains "$out_file" "APP_SECRET: \\\${APP_SECRET:-CHANGE_ME_docmost_app_secret_min_64_hex}" "example env values should be used as defaults when env is auto-created" || return 1

  rm -rf "$tmpdir"
}

test_prepare_docmost_compose_overwrite_behavior() {
  local tmpdir env_file out_file out
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/docmost.env"
  out_file="$tmpdir/docmost-compose.yml"

  bash "$gen_script" --env-file "$env_file" --no-infra-sync >/dev/null
  bash "$prep_script" --env-file "$env_file" --template-file "$template_file" --output-file "$out_file" >/dev/null

  out="$(bash "$prep_script" --env-file "$env_file" --template-file "$template_file" --output-file "$out_file" 2>&1 || true)"
  assert_contains "$out" "output already exists" "renderer should refuse overwrite without --overwrite" || return 1

  bash "$prep_script" --env-file "$env_file" --template-file "$template_file" --output-file "$out_file" --overwrite >/dev/null

  rm -rf "$tmpdir"
}

run_test "prepare-docmost-compose renders compose from docmost env" test_prepare_docmost_compose_renders_from_env
run_test "prepare-docmost-compose fails when required vars are missing" test_prepare_docmost_compose_fails_for_missing_required_var
run_test "prepare-docmost-compose creates env from example when missing" test_prepare_docmost_compose_creates_env_from_example_when_missing
run_test "prepare-docmost-compose overwrite behavior is enforced" test_prepare_docmost_compose_overwrite_behavior

report_and_exit
