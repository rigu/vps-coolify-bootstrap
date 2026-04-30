#!/usr/bin/env bash
set -euo pipefail

# Example off-site sync script for backup archives.
# Copy to /usr/local/bin/offsite-backup-sync.sh, adjust values, and keep
# credentials outside git.

LOCAL_ROOT="${LOCAL_ROOT:-/srv/backups}"
REMOTE_DEST="${REMOTE_DEST:-CHANGE_ME_remote:vps-backups}"
WAL_ARCHIVE_DIR="${WAL_ARCHIVE_DIR:-/srv/infra/postgres-wal-archive}"
REMOTE_WAL_ARCHIVE_DEST="${REMOTE_WAL_ARCHIVE_DEST:-${REMOTE_DEST}/postgres-wal-archive}"
RCLONE_FLAGS="${RCLONE_FLAGS:---transfers=4 --checkers=8 --fast-list --log-level ERROR}"
STATUS_FILE="${STATUS_FILE:-/var/lib/backup-sync/offsite-last-success.txt}"
MIN_SYNC_INTERVAL_SECONDS="${MIN_SYNC_INTERVAL_SECONDS:-3600}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd rclone
require_cmd date

if [ "$REMOTE_DEST" = "CHANGE_ME_remote:vps-backups" ]; then
  echo "ERROR: REMOTE_DEST is not configured." >&2
  exit 1
fi

if [ -f "$STATUS_FILE" ]; then
  last_success="$(cat "$STATUS_FILE")"
  last_success_epoch="$(date -u -d "$last_success" +%s 2>/dev/null || true)"
  now_epoch="$(date -u +%s)"
  if [ -n "$last_success_epoch" ] && [ $((now_epoch - last_success_epoch)) -lt "$MIN_SYNC_INTERVAL_SECONDS" ]; then
    echo "Skipping off-site sync: last success is newer than ${MIN_SYNC_INTERVAL_SECONDS}s."
    exit 0
  fi
fi

read -r -a rclone_flags <<< "$RCLONE_FLAGS"
rclone copy "$LOCAL_ROOT" "$REMOTE_DEST" "${rclone_flags[@]}"

if [ -d "$WAL_ARCHIVE_DIR" ]; then
  rclone copy "$WAL_ARCHIVE_DIR" "$REMOTE_WAL_ARCHIVE_DEST" "${rclone_flags[@]}"
fi

install -d -m 700 "$(dirname "$STATUS_FILE")"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$STATUS_FILE"
echo "Off-site sync completed at $(cat "$STATUS_FILE")"
