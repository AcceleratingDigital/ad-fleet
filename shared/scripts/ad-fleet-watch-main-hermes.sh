#!/bin/bash
# ad-fleet-watch-main-hermes.sh
# Runs inside fleet Hermes (8001) cron — watches main Hermes (8000)
# On failure: restart → config rollback → alert bus
# Part of: AcceleratingDigital Fleet (ad-fleet)
#
# CRITICAL: This script must NEVER touch a Hermes install that doesn't have
# a gateway LaunchAgent. If no plist exists, main Hermes isn't installed —
# exit silently.

FLEET_DIR="${FLEET_DIR:-$HOME/.ad-fleet}"
CONFIG="$FLEET_DIR/config.yaml"
LOG="$FLEET_DIR/logs/watchdog-main-hermes.log"
MAIN_HERMES_PLIST="$HOME/Library/LaunchAgents/ai.hermes.gateway.plist"
MAIN_HERMES_HOME="$HOME/.hermes"
MAX_LOG_LINES=500

mkdir -p "$FLEET_DIR/logs" 2>/dev/null || true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# --- If main Hermes is not installed on this machine, exit silently ---
if [ ! -f "$MAIN_HERMES_PLIST" ]; then
  # Main Hermes LaunchAgent doesn't exist — not installed on this machine
  # Don't alert, don't attempt repair, just exit
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
  # First try port 8000 (API server, if configured)
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    http://127.0.0.1:8000/v1/models 2>/dev/null)
  [ -z "$code" ] && code="000"
  if echo "$code" | grep -qE "^(200|401)$"; then
    echo "$code"
    return
  fi
  # Fall back: check if the gateway process is running (Telegram-only installs have no HTTP port)
  if pgrep -f "hermes_cli.main gateway" 2>/dev/null | grep -v "ad-fleet" > /dev/null 2>&1; then
    echo "process_ok"
    return
  fi
  # Also check the LaunchAgent — if it's loaded with a PID, it's running
  if launchctl list ai.hermes.gateway 2>/dev/null | grep -q '"PID"'; then
    echo "process_ok"
    return
  fi
  echo "$code"
}

# --- Check health ---
STATUS=$(check_main_hermes)
if echo "$STATUS" | grep -qE "^(200|401|process_ok)$"; then
  # Healthy — silent exit
  tail -"$MAX_LOG_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null || true
  exit 0
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

# --- Repair step 2: Config rollback ---
# Only touch config if the plist exists (verified at top) and backup exists
BACKUP="$MAIN_HERMES_HOME/config.yaml.backup"
CURRENT="$MAIN_HERMES_HOME/config.yaml"
if [ -f "$BACKUP" ] && [ -f "$CURRENT" ]; then
  log "Step 2: Rolling back config.yaml from backup ($(date -r "$BACKUP" '+%Y-%m-%d %H:%M:%S'))..."
  # Save the broken config first
  cp "$CURRENT" "$MAIN_HERMES_HOME/config.yaml.bak-watchdog-$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
  cp "$BACKUP" "$CURRENT"
  chmod 600 "$CURRENT"
  # Restart again
  launchctl unload "$MAIN_HERMES_PLIST" 2>/dev/null || true
  sleep 5
  launchctl load "$MAIN_HERMES_PLIST" 2>/dev/null || true
  sleep 30
  STATUS=$(check_main_hermes)
  if echo "$STATUS" | grep -qE "^(200|401|process_ok)$"; then
    log "Step 2 SUCCESS: Main Hermes recovered after config rollback."
    send_alert "Main Hermes on $HOSTNAME was down — recovered via config rollback. Please review config."
    exit 0
  fi
  log "Step 2 FAILED: Still not responding after config rollback (status=$STATUS)."
else
  log "Step 2 SKIP: No config backup found at $BACKUP"
fi

# --- Both repair steps failed — alert admin ---
send_alert "UNRECOVERED: Main Hermes on $HOSTNAME is down. Restart and config rollback both failed. Manual intervention required."
log "Alert sent to fleet bus. Human intervention required."

tail -"$MAX_LOG_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null || true
