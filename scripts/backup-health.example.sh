#!/usr/bin/env bash
set -uo pipefail

# Public-safe example derived from the production backup health check.
SRC="${SRC:-/srv/audiobooks/Audiobooks}"
SOURCE_MOUNT="${SOURCE_MOUNT:-/srv/audiobooks}"
BACKUP_MOUNT="${BACKUP_MOUNT:-/srv/backup}"
BACKUP_ROOT="${BACKUP_ROOT:-$BACKUP_MOUNT/Audiobook-Backups}"
DEST="$BACKUP_ROOT/Audiobooks"
LOGDIR="$BACKUP_ROOT/Logs"
STATE_FILE="$BACKUP_ROOT/last-successful-backup.txt"
BACKUP_COMMAND="${BACKUP_COMMAND:-/usr/local/bin/backup-audiobooks-local}"
MAX_BACKUP_AGE_DAYS="${MAX_BACKUP_AGE_DAYS:-9}"
MAX_FUTURE_SKEW_SECONDS="${MAX_FUTURE_SKEW_SECONDS:-300}"
EXPECTED_CRON_FRAGMENT="${EXPECTED_CRON_FRAGMENT:-backup-audiobooks-local}"

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
ok()   { printf '[OK]   %s\n' "$1"; OK_COUNT=$((OK_COUNT + 1)); }
warn() { printf '[WARN] %s\n' "$1"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info() { printf '[INFO] %s\n' "$1"; }
is_nonnegative_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }

printf '\n=== Audiobook Backup Health Check ===\n'
date

info "Required commands"
required_commands=(awk crontab date df find findmnt grep head mktemp mountpoint rm rsync sed systemctl wc)
commands_ready=1
for command_name in "${required_commands[@]}"; do
  if command -v "$command_name" >/dev/null 2>&1; then
    ok "Command available: $command_name"
  else
    fail "Required command is unavailable: $command_name"
    commands_ready=0
  fi
done

if ! is_nonnegative_integer "$MAX_BACKUP_AGE_DAYS" || (( MAX_BACKUP_AGE_DAYS < 1 )); then
  fail "MAX_BACKUP_AGE_DAYS must be a positive integer"
  time_thresholds_valid=0
elif ! is_nonnegative_integer "$MAX_FUTURE_SKEW_SECONDS"; then
  fail "MAX_FUTURE_SKEW_SECONDS must be a nonnegative integer"
  time_thresholds_valid=0
else
  time_thresholds_valid=1
fi

info "Schedule and command"
cron_text="$(crontab -l 2>/dev/null || true)"
if awk -v fragment="$EXPECTED_CRON_FRAGMENT" '
  /^[[:space:]]*#/ { next }
  index($0, fragment) { found = 1 }
  END { exit(found ? 0 : 1) }
' <<<"$cron_text"; then
  ok "Expected active backup cron entry is present"
else
  fail "Expected active backup cron entry was not found"
fi
[[ -x "$BACKUP_COMMAND" ]] && ok "Backup command is executable" || fail "Backup command is missing or not executable"

info "Mounts and separation"
mounts_ready=1
for mount in "$SOURCE_MOUNT" "$BACKUP_MOUNT"; do
  if mountpoint -q "$mount"; then
    ok "Mount is active: $mount"
  else
    fail "Mount is inactive: $mount"
    mounts_ready=0
  fi
done

if (( mounts_ready == 1 )) && [[ -d "$SRC" && -d "$DEST" ]]; then
  source_device="$(findmnt -n -o SOURCE -T "$SRC" 2>/dev/null || true)"
  destination_device="$(findmnt -n -o SOURCE -T "$DEST" 2>/dev/null || true)"
  if [[ -n "$source_device" && -n "$destination_device" && "$source_device" != "$destination_device" ]]; then
    ok "Source and backup use separate filesystems"
  else
    fail "Filesystem separation could not be verified"
  fi
else
  fail "Filesystem separation could not be checked because a mount or library directory is unavailable"
fi

info "Service and capacity"
systemctl is-active --quiet smbd && ok "Samba is active" || fail "Samba is inactive"
for path in "$SOURCE_MOUNT" "$BACKUP_MOUNT"; do
  usage="$(df -P "$path" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
  if ! is_nonnegative_integer "$usage"; then
    fail "Could not read disk usage: $path"
  elif (( usage >= 95 )); then
    fail "Disk usage critical at $path: ${usage}%"
  elif (( usage >= 85 )); then
    warn "Disk usage elevated at $path: ${usage}%"
  else
    ok "Disk usage healthy at $path: ${usage}%"
  fi
done

info "Mirror comparison"
if [[ -d "$SRC" && -d "$DEST" ]]; then
  source_files="$(find "$SRC" -type f -printf '.' | wc -c)"
  destination_files="$(find "$DEST" -type f -printf '.' | wc -c)"
  source_bytes="$(find "$SRC" -type f -printf '%s\n' | awk '{sum += $1} END {print sum + 0}')"
  destination_bytes="$(find "$DEST" -type f -printf '%s\n' | awk '{sum += $1} END {print sum + 0}')"
  [[ "$source_files" == "$destination_files" ]] && ok "File counts match" || fail "File counts differ"
  [[ "$source_bytes" == "$destination_bytes" ]] && ok "Total bytes match" || fail "Total bytes differ"

  drift_file="$(mktemp)"
  if (( commands_ready == 1 )) && rsync -rni --delete --size-only --out-format='%i %n%L' "$SRC/" "$DEST/" >"$drift_file" 2>/dev/null; then
    if [[ -s "$drift_file" ]]; then
      fail "Mirror has pending additions, changes, or deletions"
      head -n 20 "$drift_file" | sed 's/^/[INFO] Drift: /'
    else
      ok "Mirror structure and file sizes match"
    fi
  else
    fail "Mirror comparison could not be completed"
  fi
  rm -f -- "$drift_file"
else
  fail "Source or backup library directory is missing"
fi

info "Last verified backup"
if [[ -f "$STATE_FILE" ]]; then
  completed_epoch="$(awk -F= '$1=="completed_epoch" {print $2}' "$STATE_FILE")"
  recorded_log="$(awk -F= '$1=="log" {sub(/^[^=]*=/,""); print}' "$STATE_FILE")"
  now_epoch="$(date +%s)"

  if (( time_thresholds_valid == 1 )) && is_nonnegative_integer "$completed_epoch" &&
     (( completed_epoch <= now_epoch + MAX_FUTURE_SKEW_SECONDS )) &&
     (( now_epoch - completed_epoch <= MAX_BACKUP_AGE_DAYS * 86400 )); then
    ok "Last successful backup is recent and has a plausible timestamp"
  else
    fail "Last successful backup is overdue, invalid, or dated in the future"
  fi

  case "$recorded_log" in
    "$LOGDIR"/backup-*.log)
      if [[ -f "$recorded_log" ]] && grep -Fq 'Backup complete and verified.' "$recorded_log"; then
        ok "Completion log exists and contains the verification marker"
      else
        fail "Completion log is missing or incomplete"
      fi
      ;;
    *)
      fail "State file references a log outside the expected log directory"
      ;;
  esac
else
  fail "Successful-backup state file is missing"
fi

if [[ -d "$LOGDIR" ]]; then
  retained_logs="$(find "$LOGDIR" -maxdepth 1 -type f -name 'backup-*.log' | wc -l)"
  if (( retained_logs > 0 )); then
    info "Retained logs: $retained_logs"
  else
    fail "Log directory exists but contains no timestamped backup logs"
  fi
else
  fail "Log directory is missing"
fi

printf '\nOK: %s\nWARN: %s\nFAIL: %s\n' "$OK_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then
  echo "Result: Attention needed."
  exit 2
elif (( WARN_COUNT > 0 )); then
  echo "Result: Working, but review warnings."
  exit 1
else
  echo "Result: All checks passed."
  exit 0
fi
