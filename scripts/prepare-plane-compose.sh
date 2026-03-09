#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Render Plane compose template with values from plane env.

Usage:
  scripts/prepare-plane-compose.sh [--env-file <path>] [--template-file <path>] [--output-file <path>] [--overwrite]

Behavior:
  - If env file is missing, script creates parent directory and copies env/plane-coolify.env.example.
  - Rewrites Docker Compose-style variables to `${VAR:-<value-from-plane.env>}` defaults.
  - Keeps variable expressions in output so Coolify can manage env vars in UI.
  - Writes rendered compose file to bootstrap-artifacts by default.
USAGE
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"
bootstrap_install_error_trap "$(basename "$0")"

env_file="bootstrap-artifacts/plane.env"
template_file="templates/plane-coolify-compose.community.v1.2.3.full-with-proxy.yml"
output_file="bootstrap-artifacts/plane-coolify-compose.community.v1.2.3.full-with-proxy.yml"
overwrite=0

env_example_file="$repo_root/env/plane-coolify.env.example"

require_value_arg() {
  local flag="$1"
  local maybe_value="${2:-}"
  if [[ -z "$maybe_value" || "$maybe_value" == -* ]]; then
    bootstrap_error "$flag requires a value."
    usage >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      require_value_arg "--env-file" "${2:-}"
      env_file="${2:-}"
      shift 2
      ;;
    --template-file)
      require_value_arg "--template-file" "${2:-}"
      template_file="${2:-}"
      shift 2
      ;;
    --output-file)
      require_value_arg "--output-file" "${2:-}"
      output_file="${2:-}"
      shift 2
      ;;
    --overwrite)
      overwrite=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      bootstrap_error "Unknown argument: $1"
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$env_file" != /* ]]; then
  env_file="$repo_root/$env_file"
fi
if [[ "$template_file" != /* ]]; then
  template_file="$repo_root/$template_file"
fi
if [[ "$output_file" != /* ]]; then
  output_file="$repo_root/$output_file"
fi

bootstrap_info "prepare-plane-compose parameters: env_file=${env_file}, template_file=${template_file}, output_file=${output_file}, overwrite=${overwrite}"

if [[ -d "$env_file" ]]; then
  bootstrap_error "--env-file points to a directory, expected a file: $env_file"
  exit 1
fi
if [[ -d "$template_file" ]]; then
  bootstrap_error "--template-file points to a directory, expected a file: $template_file"
  exit 1
fi
if [[ -d "$output_file" ]]; then
  bootstrap_error "--output-file points to a directory, expected a file path: $output_file"
  exit 1
fi

if [[ ! -f "$env_example_file" ]]; then
  bootstrap_error "required env example missing: $env_example_file"
  exit 1
fi
if [[ ! -f "$template_file" ]]; then
  bootstrap_error "required template missing: $template_file"
  exit 1
fi

mkdir -p "$(dirname "$env_file")"
if [[ ! -f "$env_file" ]]; then
  cp "$env_example_file" "$env_file"
  chmod 600 "$env_file"
  bootstrap_success "Created env file from template: $env_file"
fi

if [[ -e "$output_file" && "$overwrite" -ne 1 ]]; then
  bootstrap_error "output already exists: $output_file (use --overwrite to replace)"
  exit 1
fi
mkdir -p "$(dirname "$output_file")"

bootstrap_info "Loading Plane env from: $env_file"
load_env_file_strict "$env_file"
bootstrap_success "Plane env loaded."

if ! command -v python3 >/dev/null 2>&1; then
  bootstrap_error "python3 is required to render compose variables."
  exit 1
fi

bootstrap_info "Rendering template compose interpolation values."
python3 - "$template_file" "$output_file" "$env_file" <<'PY'
import os
import re
import sys

if len(sys.argv) != 4:
    print("ERROR: internal argument mismatch", file=sys.stderr)
    sys.exit(1)

template_path = sys.argv[1]
output_path = sys.argv[2]
env_path = sys.argv[3]

with open(template_path, "r", encoding="utf-8") as fh:
    content = fh.read()

expr_re = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)(?:(:?[-+?])(.*))?$", re.S)


def load_env_map(path: str) -> dict[str, str]:
    env: dict[str, str] = {}
    with open(path, "r", encoding="utf-8") as fh:
        for raw_line in fh:
            line = raw_line.rstrip("\r\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            m = re.match(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$", line)
            if not m:
                continue
            key = m.group(1)
            raw_value = m.group(2).strip()
            if re.match(r"^'(.*)'$", raw_value, re.S):
                value = re.match(r"^'(.*)'$", raw_value, re.S).group(1)
            elif re.match(r'^"(.*)"$', raw_value, re.S):
                value = re.match(r'^"(.*)"$', raw_value, re.S).group(1)
                value = value.replace("\\\\", "\\").replace('\\"', '"').replace("\\$", "$")
            else:
                value = raw_value
            env[key] = value
    return env


env_map = load_env_map(env_path)


def parse_token(text: str, start: int) -> tuple[str, int]:
    if not text.startswith("${", start):
        raise ValueError("internal parse error: token does not start with ${")
    i = start + 2
    depth = 1
    while i < len(text):
        if text.startswith("${", i):
            depth += 1
            i += 2
            continue
        if text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start + 2 : i], i + 1
        i += 1
    raise ValueError("unclosed compose interpolation token")


def resolve_expr(expr: str, preserve_token: bool) -> str:
    match = expr_re.match(expr)
    if not match:
        raise ValueError(f"unsupported compose interpolation expression: ${{{expr}}}")

    name, op, arg = match.group(1), match.group(2), match.group(3)
    is_set = name in env_map
    value = env_map.get(name, "")
    op = op or ""
    arg = arg or ""
    if "${" in arg:
        arg = process_text(arg, preserve_tokens=False)

    def required_error() -> ValueError:
        return ValueError(arg if arg else f"{name} is required")

    if preserve_token:
        if op in (":?", "?"):
            if (op == ":?" and is_set and value != "") or (op == "?" and is_set):
                default_value = value
            else:
                raise required_error()
        elif is_set:
            default_value = value
        elif op in (":-", "-"):
            default_value = arg
        elif op in (":+", "+"):
            default_value = ""
        else:
            default_value = ""

        if "\n" in default_value or "\r" in default_value:
            raise ValueError(f"{name} default value contains a newline and cannot be used in interpolation.")
        if "}" in default_value:
            raise ValueError(f"{name} default value contains '}}' and cannot be used in interpolation.")
        return f"${{{name}:-{default_value}}}"

    if op == "":
        return value if is_set else ""
    if op == ":-":
        return value if (is_set and value != "") else arg
    if op == "-":
        return value if is_set else arg
    if op == ":?":
        if is_set and value != "":
            return value
        raise required_error()
    if op == "?":
        if is_set:
            return value
        raise required_error()
    if op == ":+":  # set and non-empty
        return arg if (is_set and value != "") else ""
    if op == "+":  # set (even if empty)
        return arg if is_set else ""

    raise ValueError(f"unsupported compose interpolation operator in: ${{{expr}}}")


def process_text(text: str, preserve_tokens: bool) -> str:
    result: list[str] = []
    i = 0
    while i < len(text):
        if text.startswith("${", i):
            expr, end = parse_token(text, i)
            result.append(resolve_expr(expr, preserve_tokens))
            i = end
            continue
        result.append(text[i])
        i += 1
    return "".join(result)


try:
    rendered_lines = []
    for line in content.splitlines(keepends=True):
        if line.lstrip().startswith("#"):
            rendered_lines.append(line)
            continue
        rendered_lines.append(process_text(line, preserve_tokens=True))

    content = "".join(rendered_lines)

    with open(output_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)
except ValueError as exc:
    print(f"ERROR: {exc}", file=sys.stderr)
    sys.exit(1)
PY

chmod 644 "$output_file"

bootstrap_success "Rendered Plane compose written to: $output_file"
bootstrap_info "Source template: $template_file"
bootstrap_info "Source env: $env_file"
bootstrap_success "prepare-plane-compose completed successfully."
