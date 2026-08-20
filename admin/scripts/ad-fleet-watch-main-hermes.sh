#!/bin/bash
# ad-fleet-watch-main-hermes.sh
# Runs inside fleet Hermes (8001) cron — watches main Hermes gateway
# On failure: restart → cooldown → alert bus
# Part of: AcceleratingDigital Fleet (ad-fleet)
#
# CRITICAL: This script must NEVER touch a Hermes install that doesn't have
# a gateway LaunchAgent. If no plist exists, main Hermes isn't installed —
# exit silently.
#
# CRITICAL: This script must NEVER modify ~/.hermes/config.yaml. The old
# config-rollback repair step stomped live configs with stale backups and
# caused lost-configuration incidents. Removed permanently.

FLEET_DIR="${FLEET_DIR:-$HOME/.ad-fleet}"
CONFIG="$FLEET_DIR/config.yaml"
LOG="$FLEET_DIR/logs/watchdog-main-hermes.log"
MAIN_HERMES_PLIST="$HOME/Library/LaunchAgents/ai.hermes.gateway.plist"
MAIN_HERMES_HOME="$HOME/.hermes"
MAX_LOG_LINES=500
COOLDOWN_MARKER="$FLEET_DIR/logs/.watchdog-main-cooldown"
COOLDOWN_SECS=3600   # after a failed repair, wait 1h before trying again

mkdir -p "$FLEET_DIR/logs" 2>/dev/null || true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# --- If main Hermes is not installed on this machine, exit silently ---
if [ ! -f "$MAIN_HERMES_PLIST" ]; then
  tail -"$MAX_LOG_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null || true
  exit 0
fi

# Read fleet DB credentials
DB_HOST=$(grep "db_host:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_PORT=$(grep "db_port:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_USER=$(grep "db_user:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_PASS=$(grep "db_pass:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_NAME=$(grep "db_name:" "$CONFIG" | awk '{print $2}' | tr -d '"')
HOSTNAME=$(grep "hostname:" "$CONFIG" | awk '{print $2}' | tr -d '"')

# Find psql
PSQL=""
for p in /opt/homebrew/bin/psql /usr/local/bin/psql $(command -v psql 2>/dev/null); do
  [ -x "$p" ] && PSQL="$p" && break
done

send_alert() {
  local msg="$1"
  log "ALERT: $msg"
  [ -z "$PSQL" ] && return

  # Escape single quotes
  local safe_msg
  safe_msg=$(echo "$msg" | sed "s/'/''/g" | head -c 1000)
  export PGPASSWORD="$DB_PASS"
  "$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c \
    "INSERT INTO hermes_bus (from_host, to_host, kind, body, task_title, task_expires_at)
     VALUES ('$HOSTNAME', 'laptop-m1', 'msg',
       '{\"task\":\"fleet_alert\",\"message\":\"$safe_msg\",\"host\":\"$HOSTNAME\"}',
       'Fleet Alert', NOW() + INTERVAL '6 hours');" 2>/dev/null
}

check_main_hermes() {
  # Primary check: is the MAIN gateway process running?
  # pgrep -fl lists full command lines so we can exclude the fleet gateway.
  # (Bare `pgrep -f | grep -v ad-fleet` was a bug: pgrep outputs bare PIDs,
  #  so the filter never matched anything and the fleet's own gateway PID
  #  made a dead main gateway look healthy — and vice versa.)
  if pgrep -fl "hermes_cli.main gateway" 2>/dev/null | grep -v '\.ad-fleet' | grep -q "hermes_cli.main gateway"; then
    echo "process_ok"
    return
  fi
  # LaunchAgent check — loaded with a live PID means running
  if launchctl list ai.hermes.gateway 2>/dev/null | grep -q '"PID"'; then
    echo "process_ok"
    return
  fi
  # Last resort: port 8000 API server (only on installs that expose it)
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    http://127.0.0.1:8000/v1/models 2>/dev/null)
  [ -z "$code" ] && code="000"
  echo "$code"
}

# --- Check health ---
STATUS=$(check_main_hermes)
if echo "$STATUS" | grep -qE "^(200|401|process_ok)$"; then
  # Healthy — clear any cooldown marker and exit silently
  rm -f "$COOLDOWN_MARKER" 2>/dev/null || true
  tail -"$MAX_LOG_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null || true
  exit 0
fi

# --- Cooldown: if a repair already failed recently, don't restart-bomb the gateway ---
if [ -f "$COOLDOWN_MARKER" ]; then
  MARKER_AGE=$(( $(date +%s) - $(stat -f %m "$COOLDOWN_MARKER" 2>/dev/null || stat -c %Y "$COOLDOWN_MARKER" 2>/dev/null || echo 0) ))
  if [ "$MARKER_AGE" -lt "$COOLDOWN_SECS" ]; then
    log "Main Hermes still down; in cooldown ($((MARKER_AGE/60))m of $((COOLDOWN_SECS/60))m) — skipping repair."
    exit 0
  fi
  rm -f "$COOLDOWN_MARKER" 2>/dev/null || true
fi

log "Main Hermes not responding (status=$STATUS) — attempting repair..."

# --- Repair step 1: Restart LaunchAgent ---
# (We already verified plist exists above)
log "Step 1: Restarting main Hermes LaunchAgent..."
launchctl unload "$MAIN_HERMES_PLIST" 2>/dev/null || true
sleep 5
launchctl load "$MAIN_HERMES_PLIST" 2>/dev/null || true
sleep 30
STATUS=$(check_main_hermes)
if echo "$STATUS" | grep -qE "^(200|401|process_ok)$"; then
  log "Step 1 SUCCESS: Main Hermes recovered after restart."
  send_alert "Main Hermes on $HOSTNAME was down — recovered via restart. No action needed."
  exit 0
fi
log "Step 1 FAILED: Still not responding after restart (status=$STATUS)."

# --- Repair step 2 (config rollback) REMOVED ---
# A fleet watchdog must NEVER overwrite the main install's ~/.hermes/config.yaml.
# If the gateway won't start after a restart, a human needs to look at it.

# --- Repair failed — set cooldown and alert admin ---
touch "$COOLDOWN_MARKER" 2>/dev/null || true
send_alert "UNRECOVERED: Main Hermes gateway on $HOSTNAME is down. Restart failed. Watchdog entering 1h cooldown. Manual intervention required."
log "Alert sent to fleet bus. Human intervention required."

tail -"$MAX_LOG_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null || true
