#!/usr/bin/env bash
set -euo pipefail

split_csv_to_lines() {
  local csv="$1"
  local item=""
  IFS=',' read -r -a items <<< "$csv"
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
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
    echo "ERROR: env file not found: $env_file" >&2
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
      echo "ERROR: invalid env line $line_no in $env_file: $line" >&2
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
      if [[ "$raw_value" =~ [[:space:]] ]]; then
        echo "ERROR: unquoted whitespace for $key at line $line_no in $env_file" >&2
        return 1
      fi
      if [[ "$raw_value" == *\$\(* ]] || [[ "$raw_value" == *\$\{* ]] || [[ "$raw_value" == *\`* ]]; then
        echo "ERROR: potential shell expansion syntax for $key at line $line_no in $env_file; quote the value" >&2
        return 1
      fi
      value="$raw_value"
    fi

    declare -gx "$key=$value"
  done < "$env_file"
}
