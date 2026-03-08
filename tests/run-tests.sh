#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$repo_root/tests/test-common.sh"
bash "$repo_root/tests/test-harden-coolify-compose-ports.sh"
bash "$repo_root/tests/test-recover-ssh-access.sh"
bash "$repo_root/tests/test-update-realtime-mode.sh"
bash "$repo_root/tests/test-generate-secrets.sh"
bash "$repo_root/tests/test-prepare-vps-coolify-init.sh"

if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoLogo -NoProfile -File "$repo_root/tests/test-powershell.ps1"
else
  echo "WARNING: pwsh not found, skipping PowerShell tests."
fi
