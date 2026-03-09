#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/testlib.sh
source "$repo_root/tests/testlib.sh"

gen_script="$repo_root/scripts/generate-plane-secrets.sh"
prep_script="$repo_root/scripts/prepare-plane-compose.sh"
template_file="$repo_root/templates/plane-coolify-compose.community.v1.2.3.full-with-proxy.yml"

test_prepare_plane_compose_renders_from_plane_env() {
  local tmpdir env_file out_file secret
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/plane.env"
  out_file="$tmpdir/plane-compose.yml"

  bash "$gen_script" --env-file "$env_file" --no-infra-sync >/dev/null
  bash "$prep_script" --env-file "$env_file" --template-file "$template_file" --output-file "$out_file" >/dev/null

  [[ -f "$out_file" ]] || { echo "missing rendered compose output" >&2; return 1; }
  if awk '!/^[[:space:]]*#/' "$out_file" | grep -Eq '\$\{'; then
    echo "rendered compose has unresolved \${...} tokens in active YAML lines" >&2
    return 1
  fi
  assert_file_contains "$out_file" 'image: "makeplane/plane-proxy:v1\.2\.3"' "proxy image should resolve default Plane tag" || return 1

  secret="$(strip_env_quotes "$(env_value "$env_file" SECRET_KEY)")"
  assert_file_contains "$out_file" "SECRET_KEY: ${secret}" "SECRET_KEY should be injected from plane env" || return 1

  if command -v python3 >/dev/null 2>&1; then
    python3 - <<PY
import yaml
yaml.safe_load(open('$out_file', encoding='utf-8').read())
PY
  fi

  rm -rf "$tmpdir"
}

test_prepare_plane_compose_fails_for_missing_required_var() {
  local tmpdir env_file out_file out
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/plane.env"
  out_file="$tmpdir/plane-compose.yml"

  bash "$gen_script" --env-file "$env_file" --no-infra-sync >/dev/null
  grep -Ev '^SECRET_KEY=' "$env_file" > "$env_file.tmp"
  mv "$env_file.tmp" "$env_file"

  out="$(bash "$prep_script" --env-file "$env_file" --template-file "$template_file" --output-file "$out_file" 2>&1 || true)"
  assert_contains "$out" "Missing SECRET_KEY" "renderer should fail fast for required missing vars" || return 1

  rm -rf "$tmpdir"
}

test_prepare_plane_compose_creates_env_from_example_when_missing() {
  local tmpdir env_file out_file
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/new/plane.env"
  out_file="$tmpdir/out/plane-compose.yml"

  bash "$prep_script" --env-file "$env_file" --template-file "$template_file" --output-file "$out_file" >/dev/null

  [[ -f "$env_file" ]] || { echo "env file was not created from example" >&2; return 1; }
  [[ -f "$out_file" ]] || { echo "rendered compose output was not created" >&2; return 1; }
  assert_file_contains "$out_file" 'SECRET_KEY: CHANGE_ME_plane_secret_key_min_50_chars' "example env values should be rendered when env is auto-created" || return 1

  rm -rf "$tmpdir"
}

test_prepare_plane_compose_overwrite_behavior() {
  local tmpdir env_file out_file out
  tmpdir="$(mktemp -d)"
  env_file="$tmpdir/plane.env"
  out_file="$tmpdir/plane-compose.yml"

  bash "$gen_script" --env-file "$env_file" --no-infra-sync >/dev/null
  bash "$prep_script" --env-file "$env_file" --template-file "$template_file" --output-file "$out_file" >/dev/null

  out="$(bash "$prep_script" --env-file "$env_file" --template-file "$template_file" --output-file "$out_file" 2>&1 || true)"
  assert_contains "$out" "output already exists" "renderer should refuse overwrite without --overwrite" || return 1

  bash "$prep_script" --env-file "$env_file" --template-file "$template_file" --output-file "$out_file" --overwrite >/dev/null

  rm -rf "$tmpdir"
}

run_test "prepare-plane-compose renders compose from plane env" test_prepare_plane_compose_renders_from_plane_env
run_test "prepare-plane-compose fails when required vars are missing" test_prepare_plane_compose_fails_for_missing_required_var
run_test "prepare-plane-compose creates env from example when missing" test_prepare_plane_compose_creates_env_from_example_when_missing
run_test "prepare-plane-compose overwrite behavior is enforced" test_prepare_plane_compose_overwrite_behavior

report_and_exit
