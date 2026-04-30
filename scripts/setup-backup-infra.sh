#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"

# shellcheck disable=SC1091
source "$script_dir/common.sh"
bootstrap_install_error_trap "$(basename "$0")"

usage() {
  cat <<'USAGE'
Automate shared infra backup setup on a VPS:
- install generic backup scripts and systemd units
- write backup override files under /etc/default
- optionally install the off-site sync example
- enable timers and run the first backup

Usage:
  scripts/setup-backup-infra.sh [options]

Options:
  --env-file <path>               Runtime env file (default: /srv/infra/production-infra.env)
  --backup-dir <path>             Local Postgres dump directory (default: /srv/backups/postgres)
  --object-backup-dir <path>      Local object-storage archive directory (default: /srv/backups/object-storage)
  --basebackup-dir <path>         PITR basebackup directory (default: /srv/backups/postgres-pitr)
  --retention-days <days>         Local dump/object retention (default: 14)
  --basebackup-retention-days <days>
                                  PITR basebackup retention (default: 7)
  --docmost-container <name>      Override Docmost container auto-detection
  --strict-docmost-backup         Fail when Docmost storage cannot be detected
  --include-postgres-apps-db      Also dump POSTGRES_APPS_DB
  --disable-seaweedfs-freeze      Do not pause SeaweedFS during archive
  --disable-docmost-freeze        Do not pause Docmost during archive
  --install-offsite-example       Install offsite-backup-sync.example.sh if no live script exists
  --replace-offsite-script        Replace an existing /usr/local/bin/offsite-backup-sync.sh
  --offsite-remote-dest <dest>    Set REMOTE_DEST in the installed offsite script
  --enable-offsite-timer          Enable offsite-backup-sync.timer when offsite config is ready
  --skip-manual-run               Install/enable only; do not run the first local backup now
  --skip-offsite-run              Do not run offsite-backup-sync.service manually
  -h, --help                      Show help

Notes:
  - This helper installs the generic backup assets from the public bootstrap repo.
  - Off-site sync still requires rclone credentials outside git.
  - Real retention, destinations, encryption, and restore policy remain environment-specific.
USAGE
}

require_value_arg() {
  local flag="$1"
  local maybe_value="${2:-}"
  if [[ -z "$maybe_value" || "$maybe_value" == -* ]]; then
    bootstrap_error "$flag requires a value."
    usage >&2
    exit 1
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    bootstrap_error "Missing required command: $cmd"
    exit 1
  fi
}

run_root() {
  if (( EUID == 0 )); then
    "$@"
    return
  fi
  require_cmd sudo
  sudo "$@"
}

backup_existing_path() {
  local path="$1"
  local backup_path=""

  if ! run_root test -e "$path"; then
    return 0
  fi

  backup_path="${path}.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  run_root cp -a "$path" "$backup_path"
  bootstrap_info "Backed up existing ${path} to ${backup_path}."
}

install_managed_file() {
  local src="$1"
  local dest="$2"
  local mode="$3"

  if [[ ! -f "$src" ]]; then
    bootstrap_error "Required source file is missing: $src"
    exit 1
  fi

  backup_existing_path "$dest"
  run_root install -o root -g root -m "$mode" "$src" "$dest"
  bootstrap_success "Installed ${dest}."
}

install_rendered_file() {
  local dest="$1"
  local mode="$2"
  local tmp_file=""

  tmp_file="$(mktemp)"
  cat >"$tmp_file"
  backup_existing_path "$dest"
  run_root install -o root -g root -m "$mode" "$tmp_file" "$dest"
  rm -f "$tmp_file"
  bootstrap_success "Wrote ${dest}."
}

normalize_bool() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON)
      printf '1\n'
      ;;
    0|false|FALSE|no|NO|off|OFF|'')
      printf '0\n'
      ;;
    *)
      bootstrap_error "Invalid boolean value: ${1:-<empty>}"
      exit 1
      ;;
  esac
}

is_wal_archive_enabled() {
  local value="${POSTGRES_ENABLE_WAL_ARCHIVE:-false}"
  case "${value,,}" in
    true|1|yes|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

offsite_script_ready() {
  local script_path="/usr/local/bin/offsite-backup-sync.sh"

  if ! run_root test -x "$script_path"; then
    return 1
  fi

  if run_root grep -Fq 'CHANGE_ME_remote:vps-backups' "$script_path"; then
    return 1
  fi

  if ! run_root test -f /root/.config/rclone/rclone.conf; then
    return 1
  fi

  if ! command -v rclone >/dev/null 2>&1; then
    return 1
  fi

  return 0
}

show_unit_state() {
  local unit="$1"
  run_root systemctl show "$unit" \
    --property=LoadState,UnitFileState,ActiveState,SubState,Result,ExecMainStatus \
    --no-pager
}

env_file="/srv/infra/production-infra.env"
backup_dir="/srv/backups/postgres"
object_backup_dir="/srv/backups/object-storage"
basebackup_dir="/srv/backups/postgres-pitr"
retention_days="14"
basebackup_retention_days="7"
docmost_container=""
strict_docmost_backup="0"
include_postgres_apps_db="0"
freeze_seaweedfs="1"
freeze_docmost="1"
install_offsite_example="0"
replace_offsite_script="0"
offsite_remote_dest=""
enable_offsite_timer="0"
skip_manual_run="0"
skip_offsite_run="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      require_value_arg "--env-file" "${2:-}"
      env_file="${2:-}"
      shift 2
      ;;
    --backup-dir)
      require_value_arg "--backup-dir" "${2:-}"
      backup_dir="${2:-}"
      shift 2
      ;;
    --object-backup-dir)
      require_value_arg "--object-backup-dir" "${2:-}"
      object_backup_dir="${2:-}"
      shift 2
      ;;
    --basebackup-dir)
      require_value_arg "--basebackup-dir" "${2:-}"
      basebackup_dir="${2:-}"
      shift 2
      ;;
    --retention-days)
      require_value_arg "--retention-days" "${2:-}"
      retention_days="${2:-}"
      shift 2
      ;;
    --basebackup-retention-days)
      require_value_arg "--basebackup-retention-days" "${2:-}"
      basebackup_retention_days="${2:-}"
      shift 2
      ;;
    --docmost-container)
      require_value_arg "--docmost-container" "${2:-}"
      docmost_container="${2:-}"
      shift 2
      ;;
    --strict-docmost-backup)
      strict_docmost_backup="1"
      shift
      ;;
    --include-postgres-apps-db)
      include_postgres_apps_db="1"
      shift
      ;;
    --disable-seaweedfs-freeze)
      freeze_seaweedfs="0"
      shift
      ;;
    --disable-docmost-freeze)
      freeze_docmost="0"
      shift
      ;;
    --install-offsite-example)
      install_offsite_example="1"
      shift
      ;;
    --replace-offsite-script)
      replace_offsite_script="1"
      shift
      ;;
    --offsite-remote-dest)
      require_value_arg "--offsite-remote-dest" "${2:-}"
      offsite_remote_dest="${2:-}"
      shift 2
      ;;
    --enable-offsite-timer)
      enable_offsite_timer="1"
      shift
      ;;
    --skip-manual-run)
      skip_manual_run="1"
      shift
      ;;
    --skip-offsite-run)
      skip_offsite_run="1"
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

require_cmd date
require_cmd install
require_cmd mktemp

if [[ ! -f "$env_file" ]]; then
  bootstrap_error "Runtime env file not found: $env_file"
  exit 1
fi

if [[ ! "$retention_days" =~ ^[0-9]+$ ]]; then
  bootstrap_error "--retention-days must be numeric."
  exit 1
fi

if [[ ! "$basebackup_retention_days" =~ ^[0-9]+$ ]]; then
  bootstrap_error "--basebackup-retention-days must be numeric."
  exit 1
fi

strict_docmost_backup="$(normalize_bool "$strict_docmost_backup")"
include_postgres_apps_db="$(normalize_bool "$include_postgres_apps_db")"
freeze_seaweedfs="$(normalize_bool "$freeze_seaweedfs")"
freeze_docmost="$(normalize_bool "$freeze_docmost")"

load_env_file_strict "$env_file"

bootstrap_info "Installing generic backup assets from ${repo_root}."

run_root install -d -o root -g root -m 755 /usr/local/lib/vps-coolify-bootstrap
install_managed_file "$repo_root/scripts/common.sh" /usr/local/lib/vps-coolify-bootstrap/common.sh 644
install_managed_file "$repo_root/scripts/pg-backup-infra.sh" /usr/local/bin/pg-backup-infra.sh 750
install_managed_file "$repo_root/systemd/pg-backup-infra.service" /etc/systemd/system/pg-backup-infra.service 644
install_managed_file "$repo_root/systemd/pg-backup-infra.timer" /etc/systemd/system/pg-backup-infra.timer 644
install_managed_file "$repo_root/systemd/offsite-backup-sync.service" /etc/systemd/system/offsite-backup-sync.service 644
install_managed_file "$repo_root/systemd/offsite-backup-sync.timer" /etc/systemd/system/offsite-backup-sync.timer 644

install_rendered_file /etc/default/pg-backup-infra 640 <<EOF
ENV_FILE=${env_file}
BACKUP_DIR=${backup_dir}
OBJECT_BACKUP_DIR=${object_backup_dir}
RETENTION_DAYS=${retention_days}
FREEZE_SEAWEEDFS_DURING_BACKUP=${freeze_seaweedfs}
FREEZE_DOCMOST_DURING_BACKUP=${freeze_docmost}
STRICT_DOCMOST_BACKUP=${strict_docmost_backup}
INCLUDE_POSTGRES_APPS_DB_BACKUP=${include_postgres_apps_db}
DOCMOST_CONTAINER=${docmost_container}
EOF

if is_wal_archive_enabled; then
  bootstrap_info "POSTGRES_ENABLE_WAL_ARCHIVE is enabled; installing PITR assets."
  install_managed_file "$repo_root/scripts/pg-basebackup-infra.sh" /usr/local/bin/pg-basebackup-infra.sh 750
  install_managed_file "$repo_root/systemd/pg-basebackup-infra.service" /etc/systemd/system/pg-basebackup-infra.service 644
  install_managed_file "$repo_root/systemd/pg-basebackup-infra.timer" /etc/systemd/system/pg-basebackup-infra.timer 644
  install_rendered_file /etc/default/pg-basebackup-infra 640 <<EOF
ENV_FILE=${env_file}
BASEBACKUP_DIR=${basebackup_dir}
RETENTION_DAYS=${basebackup_retention_days}
EOF
else
  bootstrap_warn "POSTGRES_ENABLE_WAL_ARCHIVE is disabled in ${env_file}; PITR timer will not be installed or enabled."
fi

if [[ -n "$offsite_remote_dest" ]]; then
  install_offsite_example="1"
fi

if [[ "$install_offsite_example" == "1" ]]; then
  if run_root test -e /usr/local/bin/offsite-backup-sync.sh && [[ "$replace_offsite_script" != "1" ]]; then
    bootstrap_warn "/usr/local/bin/offsite-backup-sync.sh already exists; keeping it as-is. Use --replace-offsite-script to overwrite."
  else
    tmp_offsite="$(mktemp)"
    cp "$repo_root/scripts/offsite-backup-sync.example.sh" "$tmp_offsite"
    if [[ -n "$offsite_remote_dest" ]]; then
      sed -i "s#^REMOTE_DEST=.*#REMOTE_DEST=\"${offsite_remote_dest//\"/\\\"}\"#" "$tmp_offsite"
    fi
    backup_existing_path /usr/local/bin/offsite-backup-sync.sh
    run_root install -o root -g root -m 750 "$tmp_offsite" /usr/local/bin/offsite-backup-sync.sh
    rm -f "$tmp_offsite"
    bootstrap_success "Installed /usr/local/bin/offsite-backup-sync.sh."
  fi
fi

run_root systemctl daemon-reload
run_root systemctl enable --now pg-backup-infra.timer
bootstrap_success "Enabled pg-backup-infra.timer."

if is_wal_archive_enabled; then
  run_root systemctl enable --now pg-basebackup-infra.timer
  bootstrap_success "Enabled pg-basebackup-infra.timer."
fi

if [[ "$enable_offsite_timer" == "1" ]]; then
  if offsite_script_ready; then
    run_root systemctl enable --now offsite-backup-sync.timer
    bootstrap_success "Enabled offsite-backup-sync.timer."
  else
    bootstrap_warn "Off-site sync is not ready yet; timer was not enabled. Check REMOTE_DEST, rclone, and /root/.config/rclone/rclone.conf."
  fi
fi

if [[ "$skip_manual_run" != "1" ]]; then
  bootstrap_info "Starting first local backup run."
  run_root systemctl start pg-backup-infra.service
  bootstrap_success "pg-backup-infra.service completed."

  if is_wal_archive_enabled; then
    bootstrap_info "Starting first PostgreSQL basebackup run."
    run_root systemctl start pg-basebackup-infra.service
    bootstrap_success "pg-basebackup-infra.service completed."
  fi
else
  bootstrap_warn "Skipping manual first-run backup by request."
fi

if [[ "$skip_offsite_run" != "1" ]]; then
  if offsite_script_ready; then
    bootstrap_info "Starting first off-site sync run."
    run_root systemctl start offsite-backup-sync.service
    bootstrap_success "offsite-backup-sync.service completed."
  else
    bootstrap_warn "Skipping off-site run because the off-site script is not fully configured."
  fi
else
  bootstrap_warn "Skipping manual off-site run by request."
fi

printf '\n'
bootstrap_info "Unit state summary:"
show_unit_state pg-backup-infra.timer
show_unit_state pg-backup-infra.service

if is_wal_archive_enabled; then
  show_unit_state pg-basebackup-infra.timer
  show_unit_state pg-basebackup-infra.service
fi

if run_root test -e /usr/local/bin/offsite-backup-sync.sh; then
  show_unit_state offsite-backup-sync.service
fi

if [[ "$enable_offsite_timer" == "1" ]] && offsite_script_ready; then
  show_unit_state offsite-backup-sync.timer
fi

printf '\n'
bootstrap_info "Scheduled timers:"
run_root systemctl list-timers --all | grep -E 'pg-backup-infra|pg-basebackup-infra|offsite-backup-sync' || true

printf '\n'
bootstrap_info "Backup artifact directories:"
run_root ls -ld "$backup_dir" "$object_backup_dir" 2>/dev/null || true
run_root find "$backup_dir" "$object_backup_dir" -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TT %p %k KB\n' 2>/dev/null | sort | tail -n 20 || true

if is_wal_archive_enabled; then
  run_root ls -ld "$basebackup_dir" /srv/infra/postgres-wal-archive 2>/dev/null || true
  run_root find "$basebackup_dir" /srv/infra/postgres-wal-archive -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TT %p %k KB\n' 2>/dev/null | sort | tail -n 20 || true
fi

if run_root test -f /var/lib/backup-sync/offsite-last-success.txt; then
  printf '\n'
  bootstrap_info "Latest off-site success marker:"
  run_root cat /var/lib/backup-sync/offsite-last-success.txt
fi

printf '\n'
bootstrap_success "Backup setup workflow finished."
