#!/usr/bin/env bash
set -euo pipefail

bootstrap_log_ts() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

bootstrap_log() {
  local level="$1"
  shift
  local context="${BOOTSTRAP_LOG_CONTEXT:-$(basename "${0:-script}")}"
  printf '[%s] [%s] [%s] %s\n' "$level" "$(bootstrap_log_ts)" "$context" "$*" >&2
}

bootstrap_info() {
  bootstrap_log "INFO" "$*"
}

bootstrap_success() {
  bootstrap_log "SUCCESS" "$*"
}

bootstrap_warn() {
  bootstrap_log "WARNING" "$*"
}

bootstrap_error() {
  bootstrap_log "ERROR" "$*"
}

bootstrap_install_error_trap() {
  local context="${1:-$(basename "${0:-script}")}"
  BOOTSTRAP_LOG_CONTEXT="$context"
  set -o errtrace
  trap 'bootstrap_err_trap "$?" "$LINENO" "$BASH_COMMAND"' ERR
}

bootstrap_err_trap() {
  local exit_code="$1"
  local line_no="$2"
  local command="$3"
  bootstrap_error "Unhandled failure (exit=${exit_code}) at line ${line_no}: ${command}"
  exit "$exit_code"
}

split_csv_to_lines() {
  local csv="$1"
  local item=""
  while IFS= read -r item || [[ -n "$item" ]]; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done < <(printf '%s' "$csv" | tr ',;[:space:]' '\n')
}

is_valid_unix_username() {
  local user="$1"
  [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]
}

csv_contains_value() {
  local csv="$1"
  local needle="$2"
  local item=""
  while IFS= read -r item; do
    [[ "$item" == "$needle" ]] && return 0
  done < <(split_csv_to_lines "$csv")
  return 1
}

csv_append_unique() {
  local csv="$1"
  local value="$2"
  if csv_contains_value "$csv" "$value"; then
    printf '%s\n' "$csv"
  elif [[ -z "$csv" ]]; then
    printf '%s\n' "$value"
  else
    printf '%s,%s\n' "$csv" "$value"
  fi
}

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

load_env_file_strict() {
  local env_file="$1"
  local line=""
  local key=""
  local raw_value=""
  local value=""
  local line_no=0

  if [[ ! -f "$env_file" ]]; then
    bootstrap_error "env file not found: $env_file"
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    line="${line%$'\r'}"

    if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi

    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      key="${BASH_REMATCH[2]}"
      raw_value="$(trim_whitespace "${BASH_REMATCH[3]}")"
    else
      bootstrap_error "invalid env line $line_no in $env_file: $line"
      return 1
    fi

    if [[ -z "$raw_value" ]]; then
      value=""
    elif [[ "$raw_value" =~ ^\'([^\']*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "$raw_value" =~ ^\"(.*)\"$ ]]; then
      value="${BASH_REMATCH[1]}"
      value="${value//\\\\/\\}"
      value="${value//\\\"/\"}"
      value="${value//\\\$/\$}"
    else
      if [[ "$raw_value" == *\$\(* ]] || [[ "$raw_value" == *\$\{* ]] || [[ "$raw_value" == *\`* ]]; then
        bootstrap_error "potential shell expansion syntax for $key at line $line_no in $env_file; quote the value"
        return 1
      fi
      # Allow unquoted spaces only for ADDITIONAL_SUDO_USERS so operators can
      # write simple user lists (for example: "ops admin;dev").
      if [[ "$raw_value" =~ [[:space:]] ]] && [[ "$key" != "ADDITIONAL_SUDO_USERS" ]]; then
        bootstrap_error "unquoted whitespace for $key at line $line_no in $env_file"
        return 1
      fi
      value="$raw_value"
    fi

    declare -gx "$key=$value"
  done < "$env_file"
}
