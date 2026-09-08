#!/bin/bash
# ad-fleet-watch-fleet-hermes.sh
# Runs inside main Hermes (8000) cron — watches fleet Hermes (8001)
# On failure: restart → config rollback → alert bus → log
# Part of: AcceleratingDigital Fleet (ad-fleet)
#
# WATCHDOG BLIND-SPOT FIX (2026-09-08): the old version exited silently when
# the fleet gateway LaunchAgent plist was missing, treating it as "fleet not
# installed". laptop-m1's plist was deleted on Aug 28 and the watchdog kept
# reporting ok for 11 days while port 8001 was dead. Now:
#   - plist missing + fleet install dir present  → REINSTALL the plist and alert
#   - plist missing + no fleet install dir       → fleet genuinely not installed, exit silently
#
# Cron config note: this script runs as a no-agent cron (stdout delivered
# directly). Healthy runs MUST print nothing to stdout — only failures log
# via the log() function, which tees to the watchdog log file.

FLEET_DIR="${FLEET_DIR:-$HOME/.ad-fleet}"
FLEET_HERMES_HOME="$FLEET_DIR/hermes"
FLEET_HERMES_PLIST="$HOME/Library/LaunchAgents/com.ad-fleet.hermes-gateway.plist"
LOG="$FLEET_DIR/logs/watchdog-fleet-hermes.log"
MAX_LOG_LINES=500

mkdir -p "$FLEET_DIR/logs" 2>/dev/null || true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

[ ! -f "$FLEET_DIR/config.yaml" ] && exit 0  # Fleet not installed on this machine

# Read fleet DB credentials (for bus alerts)
DB_HOST=$(grep "db_host:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
DB_PORT=$(grep "db_port:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
DB_USER=$(grep "db_user:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
DB_PASS=$(grep "db_pass:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
DB_NAME=$(grep "db_name:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
MACHINE_HOSTNAME=$(grep "hostname:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')

# Find psql
PSQL=""
for p in /opt/homebrew/bin/psql /usr/local/bin/psql $(command -v psql 2>/dev/null); do
  [ -x "$p" ] && PSQL="$p" && break
done

send_alert() {
  local msg="$1"
  log "ALERT: $msg"
  [ -z "$PSQL" ] && return
  [ -z "$DB_HOST" ] && return

  local safe_msg
  safe_msg=$(echo "$msg" | sed "s/'/''/g" | head -c 1000)
  export PGPASSWORD="$DB_PASS"
  "$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c \
    "INSERT INTO hermes_bus (from_host, to_host, kind, body, task_title, task_expires_at)
     VALUES ('$MACHINE_HOSTNAME', 'laptop-m1', 'msg',
       '{\"task\":\"fleet_alert\",\"message\":\"$safe_msg\",\"host\":\"$MACHINE_HOSTNAME\"}',
       'Fleet Alert', NOW() + INTERVAL '6 hours');" 2>/dev/null
}

check_fleet_hermes() {
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    http://127.0.0.1:8001/v1/models 2>/dev/null)
  [ -z "$code" ] && code="000"
  echo "$code"
}

# --- Case 1: plist missing entirely ---
if [ ! -f "$FLEET_HERMES_PLIST" ]; then
  # Fleet Hermes install dir present but plist gone → the gateway has no
  # supervisor. Rebuild the plist from the repo template and reload it.
  if [ -x "$FLEET_HERMES_HOME/hermes-agent/venv/bin/python" ]; then
    log "Fleet Hermes plist missing but install dir exists — rebuilding LaunchAgent..."
    # Hand-rolled plist (matches repo install-script template exactly)
    VENV_DIR="$FLEET_HERMES_HOME/hermes-agent/venv"
    PYTHON_BIN="$VENV_DIR/bin/python"
    LLM_API_KEY=$(grep "llm_api_key:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
    API_SERVER_KEY=$(grep '^API_SERVER_KEY=' "$FLEET_HERMES_HOME/.env" 2>/dev/null | cut -d= -f2-)
    if [ -n "$LLM_API_KEY" ] && [ -n "$API_SERVER_KEY" ]; then
        cat > "$FLEET_HERMES_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ad-fleet.hermes-gateway</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON_BIN}</string>
        <string>-m</string>
        <string>hermes_cli.main</string>
        <string>gateway</string>
        <string>run</string>
        <string>--replace</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${FLEET_HERMES_HOME}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${VENV_DIR}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>VIRTUAL_ENV</key>
        <string>${VENV_DIR}</string>
        <key>HERMES_HOME</key>
        <string>${FLEET_HERMES_HOME}</string>
        <key>INFERENCE_CUSTOM_AD_LITELLM_API_KEY</key>
        <string>${LLM_API_KEY}</string>
        <key>API_SERVER_PORT</key>
        <string>8001</string>
        <key>API_SERVER_KEY</key>
        <string>${API_SERVER_KEY}</string>
        <key>API_SERVER_HOST</key>
        <string>127.0.0.1</string>
        <key>HOME</key>
        <string>${HOME}</string>
    </dict>
    <key>LimitLoadToSessionType</key>
    <array>
        <string>Aqua</string>
        <string>Background</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${FLEET_HERMES_HOME}/logs/gateway.log</string>
    <key>StandardErrorPath</key>
    <string>${FLEET_HERMES_HOME}/logs/gateway.error.log</string>
</dict>
</plist>
PLIST
        chmod 644 "$FLEET_HERMES_PLIST"
    else
      send_alert "UNRECOVERED: Fleet Hermes plist missing on $MACHINE_HOSTNAME and cannot rebuild (missing API keys in .env). Manual intervention required."
      exit 1
    fi
    launchctl unload "$FLEET_HERMES_PLIST" 2>/dev/null || true
    sleep 5
    launchctl load "$FLEET_HERMES_PLIST" 2>/dev/null || true
    sleep 30
    STATUS=$(check_fleet_hermes)
    if echo "$STATUS" | grep -qE "^(200|401)$"; then
      log "SUCCESS: Fleet Hermes plist rebuilt and gateway recovered (status=$STATUS)."
      send_alert "Fleet Hermes LaunchAgent plist was MISSING on $MACHINE_HOSTNAME (gateway down, watchdog previously blind). Rebuilt plist and recovered — port 8001 healthy again. Check what deleted the plist."
      exit 0
    fi
    send_alert "Fleet Hermes plist was MISSING on $MACHINE_HOSTNAME. Rebuilt and reloaded but gateway still not responding (status=$STATUS). Manual intervention required."
    exit 1
  else
    # No install dir → fleet genuinely not installed here
    exit 0
  fi
fi

# --- Case 2: plist exists but gateway not responding — repair ---
STATUS=$(check_fleet_hermes)
if echo "$STATUS" | grep -qE "^(200|401)$"; then
  # Healthy — silent exit
  tail -"$MAX_LOG_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null || true
  exit 0
fi

log "Fleet Hermes (8001) not responding (status=$STATUS) — attempting repair..."

# --- Repair step 1: Restart LaunchAgent ---
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
log "Step 1 FAILED: Still not responding after restart (status=$STATUS)."

# --- Repair step 2: Config rollback ---
BACKUP="$FLEET_HERMES_HOME/config.yaml.backup"
CURRENT="$FLEET_HERMES_HOME/config.yaml"
if [ -f "$BACKUP" ] && [ -f "$CURRENT" ]; then
  log "Step 2: Rolling back fleet Hermes config.yaml from backup..."
  cp "$CURRENT" "$FLEET_HERMES_HOME/config.yaml.bak-watchdog-$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
  cp "$BACKUP" "$CURRENT"
  chmod 600 "$CURRENT"
  launchctl unload "$FLEET_HERMES_PLIST" 2>/dev/null || true
  sleep 5
  launchctl load "$FLEET_HERMES_PLIST" 2>/dev/null || true
  sleep 30
  STATUS=$(check_fleet_hermes)
  if echo "$STATUS" | grep -qE "^(200|401)$"; then
    log "Step 2 SUCCESS: Fleet Hermes recovered after config rollback."
    exit 0
  fi
  log "Step 2 FAILED: Still not responding after config rollback (status=$STATUS)."
else
  log "Step 2 SKIP: No config backup found at $BACKUP"
fi

# --- Both failed — alert the admin via the bus (main gateway is running, so we CAN alert) ---
send_alert "UNRECOVERED: Fleet Hermes (8001) on $MACHINE_HOSTNAME is down. Restart and config rollback both failed. Manual intervention required."

tail -"$MAX_LOG_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null || true
