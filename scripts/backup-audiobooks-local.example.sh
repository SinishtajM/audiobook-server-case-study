#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

# Public-safe example derived from the production backup script.
# Review all paths, thresholds, scheduling, and retention before deployment.
SRC="${SRC:-/srv/audiobooks/Audiobooks}"
SOURCE_MOUNT="${SOURCE_MOUNT:-/srv/audiobooks}"
BACKUP_MOUNT="${BACKUP_MOUNT:-/srv/backup}"
BACKUP_ROOT="${BACKUP_ROOT:-$BACKUP_MOUNT/Audiobook-Backups}"
DEST="$BACKUP_ROOT/Audiobooks"
LOGDIR="$BACKUP_ROOT/Logs"
HISTORY_ROOT="$BACKUP_ROOT/History"
LOCKFILE="${LOCKFILE:-/run/lock/backup-audiobooks-local.lock}"
STATE_FILE="$BACKUP_ROOT/last-successful-backup.txt"
MIN_SOURCE_FILES="${MIN_SOURCE_FILES:-100}"
RETENTION_DAYS="${RETENTION_DAYS:-120}"
DATE="$(date -u +%F_%H-%M-%S)"
LOG=""
RUN_HISTORY="$HISTORY_ROOT/$DATE"
DRY_RUN=0
drift_file=""
state_tmp=""

usage() { echo "Usage: $(basename "$0") [--dry-run]"; }

log() {
  local line
  line="[$(date -u '+%F %T UTC')] $*"
  if [[ -n "$LOG" && -d "$LOGDIR" ]]; then
    printf '%s\n' "$line" | tee -a "$LOG"
  else
    printf '%s\n' "$line" >&2
  fi
}

cleanup() {
  local rc=$?
  trap - EXIT
  [[ -n "$drift_file" ]] && rm -f -- "$drift_file"
  [[ -n "$state_tmp" ]] && rm -f -- "$state_tmp"
  if (( rc != 0 )); then
    log "ERROR: Backup exited with status $rc."
  fi
  exit "$rc"
}
trap cleanup EXIT

case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac

for value_name in MIN_SOURCE_FILES RETENTION_DAYS; do
  value="${!value_name}"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    log "ERROR: $value_name must be a nonnegative integer."
    exit 64
  fi
done
if (( MIN_SOURCE_FILES < 1 )); then
  log "ERROR: MIN_SOURCE_FILES must be at least 1."
  exit 64
fi

required_commands=(awk basename cat chmod date dirname find findmnt flock mkdir mktemp mountpoint mv rm rmdir rsync tee wc)
for command_name in "${required_commands[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    log "ERROR: Required command is unavailable: $command_name"
    exit 69
  fi
done

mkdir -p "$(dirname "$LOCKFILE")"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  log "ERROR: Another audiobook backup is already running."
  exit 75
fi

# Validate physical mounts before creating anything below the backup mount.
for mount in "$SOURCE_MOUNT" "$BACKUP_MOUNT"; do
  if ! mountpoint -q "$mount"; then
    log "ERROR: Required mount is not active: $mount"
    exit 1
  fi
done

if [[ ! -d "$SRC" ]]; then
  log "ERROR: Source library does not exist: $SRC"
  exit 1
fi

mkdir -p "$LOGDIR" "$DEST" "$HISTORY_ROOT"
LOG="$LOGDIR/backup-$DATE.log"

source_files_before="$(find "$SRC" -type f -printf '.' | wc -c)"
if (( source_files_before < MIN_SOURCE_FILES )); then
  log "ERROR: Source contains only $source_files_before files; refusing to synchronize."
  exit 1
fi

source_device="$(findmnt -n -o SOURCE -T "$SRC" 2>/dev/null || true)"
destination_device="$(findmnt -n -o SOURCE -T "$DEST" 2>/dev/null || true)"
if [[ -z "$source_device" || -z "$destination_device" || "$source_device" == "$destination_device" ]]; then
  log "ERROR: Source and destination filesystem separation could not be verified."
  exit 1
fi

rsync_opts=(
  -a
  --delete-delay
  --backup
  --backup-dir="$RUN_HISTORY"
  --human-readable
  --itemize-changes
  --stats
)
if (( DRY_RUN == 1 )); then
  rsync_opts+=(--dry-run)
  log "DRY RUN MODE: no files will be copied, replaced, or deleted."
fi

log "Starting Audiobooks-only local backup."
log "Source file count: $source_files_before"
rsync "${rsync_opts[@]}" "$SRC/" "$DEST/" 2>&1 | tee -a "$LOG"

if (( DRY_RUN == 1 )); then
  log "Dry run complete."
  trap - EXIT
  exit 0
fi

log "Verifying mirror structure and file sizes."
drift_file="$(mktemp)"
if ! rsync -rni --delete --size-only --out-format='%i %n%L' \
  "$SRC/" "$DEST/" >"$drift_file"; then
  log "ERROR: Post-backup rsync verification could not be completed."
  exit 1
fi
if [[ -s "$drift_file" ]]; then
  log "ERROR: Verification found remaining differences:"
  tee -a "$LOG" <"$drift_file"
  exit 1
fi

source_files_after="$(find "$SRC" -type f -printf '.' | wc -c)"
destination_files="$(find "$DEST" -type f -printf '.' | wc -c)"
source_bytes="$(find "$SRC" -type f -printf '%s\n' | awk '{sum += $1} END {print sum + 0}')"
destination_bytes="$(find "$DEST" -type f -printf '%s\n' | awk '{sum += $1} END {print sum + 0}')"

if [[ "$source_files_before" != "$source_files_after" ]]; then
  log "ERROR: Source file count changed during the backup; verification is not stable."
  exit 1
fi
if [[ "$source_files_after" != "$destination_files" || "$source_bytes" != "$destination_bytes" ]]; then
  log "ERROR: Post-backup count or byte comparison failed."
  exit 1
fi

state_tmp="$(mktemp "$BACKUP_ROOT/.last-successful-backup.XXXXXX")"
cat >"$state_tmp" <<STATE
completed_at=$(date -u --iso-8601=seconds)
completed_epoch=$(date +%s)
source_files=$source_files_after
destination_files=$destination_files
source_bytes=$source_bytes
destination_bytes=$destination_bytes
verification=size-path-count-bytes
log=$LOG
STATE
chmod 0640 "$state_tmp"
mv -f "$state_tmp" "$STATE_FILE"
state_tmp=""

rmdir "$RUN_HISTORY" 2>/dev/null || true
find "$LOGDIR" -maxdepth 1 -type f -name 'backup-*.log' \
  -mtime "+$RETENTION_DAYS" -delete
find "$HISTORY_ROOT" -mindepth 1 -maxdepth 1 -type d \
  -name '20??-??-??_*' -mtime "+$RETENTION_DAYS" -exec rm -rf -- {} +

log "Backup complete and verified."
log "Mirrored $source_files_after files totaling $source_bytes bytes."
rm -f -- "$drift_file"
drift_file=""
trap - EXIT
