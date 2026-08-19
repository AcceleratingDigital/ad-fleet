#!/bin/bash
# ad-fleet-watch-fleet-hermes.sh
# Runs inside main Hermes (8000) cron — watches fleet Hermes (8001)
# On failure: restart → config rollback → log (can't bus-alert if fleet is down)
# Part of: AcceleratingDigital Fleet (ad-fleet)

FLEET_DIR="$HOME/.ad-fleet"
FLEET_HERMES_HOME="$FLEET_DIR/hermes"
FLEET_HERMES_PLIST="$HOME/Library/LaunchAgents/com.ad-fleet.hermes-gateway.plist"
LOG="$FLEET_DIR/logs/watchdog-fleet-hermes.log"
MAX_LOG_LINES=500

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

[ ! -f "$FLEET_DIR/config.yaml" ] && exit 0  # Fleet not installed on this machine

check_fleet_hermes() {
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    http://127.0.0.1:8001/v1/models 2>/dev/null || echo "000")
  echo "$code"
}

# --- Check health ---
STATUS=$(check_fleet_hermes)
if echo "$STATUS" | grep -qE "^(200|401)$"; then
  # Healthy — silent exit
  tail -"$MAX_LOG_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null || true
  exit 0
fi

log "Fleet Hermes (8001) not responding (HTTP $STATUS) — attempting repair..."

# --- Repair step 1: Restart LaunchAgent ---
if [ -f "$FLEET_HERMES_PLIST" ]; then
  log "Step 1: Restarting fleet Hermes LaunchAgent..."
  launchctl unload "$FLEET_HERMES_PLIST" 2>/dev/null || true
  sleep 5
  launchctl load "$FLEET_HERMES_PLIST" 2>/dev/null || true
  sleep 30
  STATUS=$(check_fleet_hermes)
  if echo "$STATUS" | grep -qE "^(200|401)$"; then
    log "Step 1 SUCCESS: Fleet Hermes recovered after restart."
    exit 0
  fi
  log "Step 1 FAILED: Still not responding after restart (HTTP $STATUS)."
else
  log "Step 1 SKIP: LaunchAgent plist not found at $FLEET_HERMES_PLIST"
fi

# --- Repair step 2: Config rollback ---
BACKUP="$FLEET_HERMES_HOME/config.yaml.backup"
CURRENT="$FLEET_HERMES_HOME/config.yaml"
if [ -f "$BACKUP" ]; then
  log "Step 2: Rolling back fleet Hermes config.yaml from backup..."
  cp "$CURRENT" "$FLEET_HERMES_HOME/config.yaml.bak-watchdog-$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
  cp "$BACKUP" "$CURRENT"
  chmod 600 "$CURRENT"
  if [ -f "$FLEET_HERMES_PLIST" ]; then
    launchctl unload "$FLEET_HERMES_PLIST" 2>/dev/null || true
    sleep 5
    launchctl load "$FLEET_HERMES_PLIST" 2>/dev/null || true
    sleep 30
  fi
  STATUS=$(check_fleet_hermes)
  if echo "$STATUS" | grep -qE "^(200|401)$"; then
    log "Step 2 SUCCESS: Fleet Hermes recovered after config rollback."
    exit 0
  fi
  log "Step 2 FAILED: Still not responding after config rollback (HTTP $STATUS)."
else
  log "Step 2 SKIP: No config backup found at $BACKUP"
fi

# --- Both failed — log only (fleet bus unavailable if 8001 is down) ---
log "UNRECOVERED: Fleet Hermes (8001) is down. Both repair steps failed. Manual intervention required."
log "Check: launchctl list com.ad-fleet.hermes-gateway"
log "Check: cat $FLEET_HERMES_HOME/config.yaml"
log "Check: $FLEET_HERMES_HOME/hermes-agent/venv/bin/hermes --version"

tail -"$MAX_LOG_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null || true
