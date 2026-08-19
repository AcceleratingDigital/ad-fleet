#!/bin/bash
# ad-fleet-doctor.sh — Deterministic health diagnostics (no LLM required)
# Part of: AcceleratingDigital Fleet (ad-fleet)

CONFIG="$HOME/.ad-fleet/config.yaml"

# Find psql — not always in PATH on machines without Postgres app
PSQL=""
for p in /opt/homebrew/bin/psql /usr/local/bin/psql $(command -v psql 2>/dev/null); do
  [ -x "$p" ] && PSQL="$p" && break
done

echo "=== AD-FLEET DOCTOR ==="
echo "Time:     $(date)"
MACHINE_NAME=$(grep "hostname:" "$CONFIG" | awk '{print $2}' | tr -d '"')
echo "Hostname: $MACHINE_NAME"
echo "OS:       $(uname -rs)"
echo "Arch:     $(uname -m)"
echo "UUID:     $(cat $HOME/.ad-fleet/machine_id 2>/dev/null || echo 'NOT SET')"
echo ""

# --- Fleet Hermes Gateway (port 8001) ---
echo "--- Fleet Hermes (port 8001) ---"
HERMES_BIN="$HOME/.ad-fleet/hermes/hermes-agent/venv/bin/hermes"
echo -n "Binary:   "
if [ -f "$HERMES_BIN" ]; then
  VERSION=$(HERMES_HOME="$HOME/.ad-fleet/hermes" "$HERMES_BIN" --version 2>/dev/null | head -1 || echo "found")
  echo "OK $VERSION"
else
  echo "NOT FOUND"
fi

echo -n "Gateway:  "
if launchctl list com.ad-fleet.hermes-gateway 2>/dev/null | grep -q "PID"; then
  echo "OK Running (LaunchAgent loaded)"
else
  echo "WARN LaunchAgent not loaded"
fi

echo -n "Port 8001: "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8001/v1/models 2>/dev/null || echo "000")
if echo "$HTTP_CODE" | grep -q "200\|401"; then
  echo "OK Responding (HTTP $HTTP_CODE)"
else
  echo "WARN Not responding (HTTP $HTTP_CODE)"
fi

# --- User Hermes (port 8000) ---
echo ""
echo "--- User Hermes (port 8000) ---"
echo -n "Gateway:  "
curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8000/v1/models 2>/dev/null | grep -q "200\|401" && echo "OK Running (port 8000)" || echo "WARN Not responding (may be normal)"

# --- Ollama ---
echo ""
echo "--- Ollama ---"
echo -n "Binary:   "
command -v ollama >/dev/null 2>&1 && echo "OK Installed" || echo "NOT FOUND"
echo -n "Service:  "
curl -s http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && echo "OK Running" || echo "NOT RUNNING"
echo -n "Model:    "
ollama list 2>/dev/null | grep -q "qwen2.5:3b" && echo "OK qwen2.5:3b loaded" || echo "WARN qwen2.5:3b not pulled"

# --- Fleet Config ---
echo ""
echo "--- Fleet Config ---"
echo -n "Config:   "
[ -f "$CONFIG" ] && echo "OK $CONFIG" || echo "MISSING"
echo -n "Machine ID: "
[ -f "$HOME/.ad-fleet/machine_id" ] && echo "OK $(cat $HOME/.ad-fleet/machine_id)" || echo "MISSING"
echo -n "Role:     "
grep "role:" "$CONFIG" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "UNKNOWN"

# --- LaunchAgents ---
echo ""
echo "--- Daemons ---"
echo -n "Heartbeat: "
launchctl list 2>/dev/null | grep -q "com.ad-fleet.heartbeat" && echo "OK Loaded" || echo "NOT LOADED"
echo -n "Poller:    "
launchctl list 2>/dev/null | grep -q "com.ad-fleet.poller" && echo "OK Loaded" || echo "NOT LOADED"
echo -n "Fleet Hermes: "
launchctl list 2>/dev/null | grep -q "com.ad-fleet.hermes-gateway" && echo "OK Loaded" || echo "NOT LOADED"
echo -n "Last HB:   "
tail -1 "$HOME/.ad-fleet/logs/heartbeat.log" 2>/dev/null || echo "No heartbeat log yet"

# --- Database ---
echo ""
echo "--- Database ---"
if [ -f "$CONFIG" ]; then
  DB_HOST=$(grep "db_host:" "$CONFIG" | awk '{print $2}' | tr -d '"')
  DB_PORT=$(grep "db_port:" "$CONFIG" | awk '{print $2}' | tr -d '"')
  DB_USER=$(grep "db_user:" "$CONFIG" | awk '{print $2}' | tr -d '"')
  DB_PASS=$(grep "db_pass:" "$CONFIG" | awk '{print $2}' | tr -d '"')
  DB_NAME=$(grep "db_name:" "$CONFIG" | awk '{print $2}' | tr -d '"')
  export PGPASSWORD="$DB_PASS"
  echo -n "DB:       "
  if [ -n "$PSQL" ]; then
    "$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c "SELECT 1;" >/dev/null 2>&1 \
      && echo "OK Connected to $DB_HOST:$DB_PORT" \
      || echo "CANNOT connect to $DB_HOST:$DB_PORT"
  else
    echo "WARN psql not installed (DB uncheckable — daemons have their own PATH)"
  fi
fi

echo -n "LiteLLM:  "
curl -s -o /dev/null -w "%{http_code}" \
  --max-time 5 https://llm.acceleratingdigital.com/health/liveness 2>/dev/null | \
  grep -q "200" && echo "OK Reachable" || echo "WARN Not reachable (non-critical)"

# --- Resources ---
echo ""
echo "--- Resources ---"
if [ "$(uname)" = "Darwin" ]; then
  TOTAL_MEM=$(sysctl -n hw.memsize | awk '{printf "%.0f", $1/1024/1024/1024}')
  echo "RAM:      ${TOTAL_MEM}GB total"
  df -h / | tail -1 | awk '{print "Disk (/):  " $3 " used / " $2 " total (" $5 " full)"}'
else
  free -h | grep Mem | awk '{print "RAM:  " $3 " used / " $2 " total"}'
  df -h / | tail -1 | awk '{print "Disk: " $3 " / " $2 " (" $5 " used)"}'
fi

# --- Old Fleet Cleanup Check ---
echo ""
echo "--- Old Fleet Status ---"
echo -n "Old hermesbus scripts: "
ls ~/.hermes/scripts/hermesbus*.sh 2>/dev/null | wc -l | xargs -I{} echo "{} found (run ad-fleet-cleanup.sh to remove)"
echo -n "Old launchd agents:    "
ls ~/Library/LaunchAgents/com.hermesbus.*.plist 2>/dev/null | wc -l | xargs -I{} echo "{} found"

echo ""
echo "=== END DOCTOR ==="
