#!/usr/bin/env bash
set -uo pipefail

# Public-safe example derived from the production application health check.
# Review all values before deployment.
WORKSPACE_MOUNT="${WORKSPACE_MOUNT:-/srv/audiobooks}"
FILESHARE_HOST="${FILESHARE_HOST:-fileshare.example.internal}"
APP_HOST="${APP_HOST:-127.0.0.1}"
APP_PORT="${APP_PORT:-13378}"
QBITTORRENT_HOST="${QBITTORRENT_HOST:-127.0.0.1}"
QBITTORRENT_PORT="${QBITTORRENT_PORT:-8080}"
VPN_BROWSER_HOST="${VPN_BROWSER_HOST:-127.0.0.1}"
VPN_BROWSER_PORT="${VPN_BROWSER_PORT:-3001}"
SMB_PORT="${SMB_PORT:-445}"
AUTO_M4B_LOG="${AUTO_M4B_LOG:-/opt/auto-m4b/config/auto-m4b-tool.log}"
AUTO_M4B_LOGROTATE="${AUTO_M4B_LOGROTATE:-/etc/logrotate.d/auto-m4b-tool}"

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
ok()   { printf '[OK]   %s\n' "$1"; OK_COUNT=$((OK_COUNT + 1)); }
warn() { printf '[WARN] %s\n' "$1"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info() { printf '[INFO] %s\n' "$1"; }

is_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

check_command() {
  command -v "$1" >/dev/null 2>&1 && ok "Command available: $1" || fail "Required command unavailable: $1"
}

check_container_running() {
  local name="$1" state
  if state="$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null)"; then
    [[ "$state" == "running" ]] && ok "Docker container running: $name" || fail "Docker container state for $name: $state"
  else
    fail "Docker container unavailable: $name"
  fi
}

check_container_env() {
  local container="$1" key="$2" expected="$3" environment actual
  if ! environment="$(docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)"; then
    fail "Could not inspect Docker environment: $container"
    return
  fi
  actual="$(sed -n "s/^${key}=//p" <<<"$environment" | head -n 1)"
  if [[ "$actual" == "$expected" ]]; then
    ok "$container setting correct: $key=$expected"
  elif [[ -z "$actual" ]]; then
    fail "$container setting missing: $key"
  else
    fail "$container setting unexpected: $key=$actual; expected $expected"
  fi
}

check_http() {
  local label="$1" url="$2" insecure="${3:-no}" code
  local -a curl_args=(-sS -o /dev/null -w '%{http_code}' --max-time 6)
  [[ "$insecure" == "yes" ]] && curl_args+=(-k)

  if code="$(curl "${curl_args[@]}" "$url" 2>/dev/null)"; then
    case "$code" in
      200|201|204|301|302|303|307|308|401|403) ok "$label reachable: HTTP $code" ;;
      000) fail "$label not reachable" ;;
      *) warn "$label returned HTTP $code" ;;
    esac
  else
    fail "$label not reachable"
  fi
}

check_port() {
  local label="$1" host="$2" port="$3"
  if ! is_port "$port"; then
    fail "$label has an invalid port value"
    return
  fi
  if timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" >/dev/null 2>&1; then
    ok "$label port open: $host:$port"
  else
    fail "$label port not reachable: $host:$port"
  fi
}

check_disk() {
  local label="$1" path="$2" warn_at="${3:-85}" fail_at="${4:-95}" usage
  if [[ ! -e "$path" ]]; then
    fail "$label path missing: $path"
    return
  fi
  usage="$(df -P "$path" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
  if [[ ! "$usage" =~ ^[0-9]+$ ]]; then
    fail "Could not read disk usage for $label"
  elif (( usage >= fail_at )); then
    fail "$label disk usage critical: ${usage}%"
  elif (( usage >= warn_at )); then
    warn "$label disk usage elevated: ${usage}%"
  else
    ok "$label disk usage healthy: ${usage}%"
  fi
}

check_directory() {
  local label="$1" path="$2"
  [[ -d "$path" ]] && ok "$label directory exists" || fail "$label directory missing: $path"
}

count_items() {
  local label="$1" path="$2" count
  if [[ -d "$path" ]]; then
    count="$(find "$path" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
    info "$label items: $count"
  else
    warn "$label directory missing: $path"
  fi
}

printf '\n=== Application Server Health Check ===\n'
date

info "Required commands"
for command_name in awk bash curl df docker find findmnt head logrotate ls sed stat systemctl tailscale timeout tr wc; do
  check_command "$command_name"
done

info "Mount and storage"
timeout 5 ls "$WORKSPACE_MOUNT" >/dev/null 2>&1 || true
findmnt "$WORKSPACE_MOUNT" >/dev/null 2>&1 && ok "Audiobook workspace is mounted" || fail "Audiobook workspace is not mounted"
check_disk "Application root" / 85 95
check_disk "Audiobook workspace" "$WORKSPACE_MOUNT" 85 95
for directory in Original temp Audiobooks; do
  check_directory "$directory" "$WORKSPACE_MOUNT/$directory"
done

info "Active Docker services"
systemctl is-active --quiet docker && ok "Docker service is active" || fail "Docker service is not active"
for container in audiobookshelf gluetun qbittorrent firefox-vpn auto-m4b; do
  check_container_running "$container"
done

info "Application endpoints"
check_http "Audiobookshelf" "http://$APP_HOST:$APP_PORT"
check_http "qBittorrent" "http://$QBITTORRENT_HOST:$QBITTORRENT_PORT"
check_http "VPN browser" "https://$VPN_BROWSER_HOST:$VPN_BROWSER_PORT" yes
check_port "SMB fileshare" "$FILESHARE_HOST" "$SMB_PORT"

info "Private remote access"
tailscale ip -4 >/dev/null 2>&1 && ok "Private mesh VPN address is available" || fail "Private mesh VPN address is unavailable"

info "VPN-routed download stack"
forwarded_port="$(docker exec gluetun sh -c 'cat /tmp/gluetun/forwarded_port 2>/dev/null' 2>/dev/null | tr -dc '0-9' || true)"
if is_port "$forwarded_port"; then
  ok "VPN forwarded port is available"
else
  fail "VPN forwarded port is unavailable or invalid"
fi
docker exec qbittorrent test -d /downloads >/dev/null 2>&1 && ok "qBittorrent download directory is available" || fail "qBittorrent download directory is unavailable"

info "auto-m4b configuration"
check_container_env auto-m4b SLEEPTIME 10m
check_container_env auto-m4b MAKE_BACKUP N
if [[ -f "$AUTO_M4B_LOG" ]]; then
  log_size="$(stat -c '%s' "$AUTO_M4B_LOG" 2>/dev/null || printf '0')"
  if [[ "$log_size" =~ ^[0-9]+$ ]] && (( log_size < 5242880 )); then
    ok "auto-m4b log size is controlled"
  else
    warn "auto-m4b log is at or above 5 MiB or could not be measured"
  fi
else
  warn "auto-m4b log is missing"
fi
[[ -f "$AUTO_M4B_LOGROTATE" ]] && ok "auto-m4b logrotate policy exists" || warn "auto-m4b logrotate policy missing"

info "Manual workflow directories"
for directory in waiting_room manual_work recentlyadded merge untagged fix delete backup; do
  check_directory "$directory" "$WORKSPACE_MOUNT/temp/$directory"
done
for directory in waiting_room manual_work recentlyadded merge untagged fix; do
  count_items "$directory" "$WORKSPACE_MOUNT/temp/$directory"
done

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
