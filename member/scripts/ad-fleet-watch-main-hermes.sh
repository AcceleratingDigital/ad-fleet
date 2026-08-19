#!/bin/bash
# ad-fleet-watch-main-hermes.sh
# Runs inside fleet Hermes (8001) cron — watches main Hermes (8000)
# On failure: restart → config rollback → alert bus
# Part of: AcceleratingDigital Fleet (ad-fleet)

CONFIG="$HOME/.ad-fleet/config.yaml"
LOG="$HOME/.ad-fleet/logs/watchdog-main-hermes.log"
MAIN_HERMES_PLIST="$HOME/Library/LaunchAgents/ai.hermes.gateway.plist"
HERMES_HOME="$HOME/.hermes"
MAX_LOG_LINES=500

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

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
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    http://127.0.0.1:8000/v1/models 2>/dev/null || echo "000")
  echo "$code"
}

# --- Check health ---
STATUS=$(check_main_hermes)
if echo "$STATUS" | grep -qE "^(200|401)$"; then
  # Healthy — silent exit
  tail -"$MAX_LOG_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null || true
  exit 0
fi

log "Main Hermes (8000) not responding (HTTP $STATUS) — attempting repair..."

# --- Repair step 1: Restart LaunchAgent ---
if [ -f "$MAIN_HERMES_PLIST" ]; then
  log "Step 1: Restarting main Hermes LaunchAgent..."
  launchctl unload "$MAIN_HERMES_PLIST" 2>/dev/null || true
  sleep 5
  launchctl load "$MAIN_HERMES_PLIST" 2>/dev/null || true
  sleep 30
  STATUS=$(check_main_hermes)
  if echo "$STATUS" | grep -qE "^(200|401)$"; then
    log "Step 1 SUCCESS: Main Hermes recovered after restart."
    send_alert "Main Hermes on $HOSTNAME was down — recovered via restart. No action needed."
    exit 0
  fi
  log "Step 1 FAILED: Still not responding after restart (HTTP $STATUS)."
else
  log "Step 1 SKIP: LaunchAgent plist not found at $MAIN_HERMES_PLIST"
fi

# --- Repair step 2: Config rollback ---
BACKUP="$HERMES_HOME/config.yaml.backup"
CURRENT="$HERMES_HOME/config.yaml"
if [ -f "$BACKUP" ]; then
  log "Step 2: Rolling back config.yaml from backup ($(date -r "$BACKUP" '+%Y-%m-%d %H:%M:%S'))..."
  # Save the broken config first
  cp "$CURRENT" "$HERMES_HOME/config.yaml.bak-watchdog-$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
  cp "$BACKUP" "$CURRENT"
  chmod 600 "$CURRENT"
  # Restart again
  if [ -f "$MAIN_HERMES_PLIST" ]; then
    launchctl unload "$MAIN_HERMES_PLIST" 2>/dev/null || true
    sleep 5
    launchctl load "$MAIN_HERMES_PLIST" 2>/dev/null || true
    sleep 30
  fi
  STATUS=$(check_main_hermes)
  if echo "$STATUS" | grep -qE "^(200|401)$"; then
    log "Step 2 SUCCESS: Main Hermes recovered after config rollback."
    send_alert "Main Hermes on $HOSTNAME was down — recovered via config rollback. Please review config."
    exit 0
  fi
  log "Step 2 FAILED: Still not responding after config rollback (HTTP $STATUS)."
else
  log "Step 2 SKIP: No config backup found at $BACKUP"
fi

# --- Both repair steps failed — alert admin ---
send_alert "UNRECOVERED: Main Hermes (8000) on $HOSTNAME is down. Restart and config rollback both failed. Manual intervention required."
log "Alert sent to fleet bus. Human intervention required."

tail -"$MAX_LOG_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null || true
