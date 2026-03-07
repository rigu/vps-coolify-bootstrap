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
