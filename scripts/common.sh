#!/usr/bin/env bash
set -euo pipefail

split_csv_to_lines() {
  local csv="$1"
  csv="${csv// /}"
  IFS=',' read -r -a items <<< "$csv"
  for item in "${items[@]}"; do
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
}
