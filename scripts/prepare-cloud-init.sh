#!/usr/bin/env bash
set -euo pipefail

echo "WARNING: scripts/prepare-cloud-init.sh is deprecated. Use scripts/prepare-vps-coolify-init.sh instead." >&2
exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/prepare-vps-coolify-init.sh" "$@"
