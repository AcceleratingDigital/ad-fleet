#!/bin/bash
# ad-fleet-poller.sh — Poll hermes_bus for pending tasks
# Part of: AcceleratingDigital Fleet (ad-fleet)

CONFIG="$HOME/.ad-fleet/config.yaml"
LOG="$HOME/.ad-fleet/logs/poller.log"
[ ! -f "$CONFIG" ] && exit 0

DB_HOST=$(grep "db_host:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_PORT=$(grep "db_port:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_USER=$(grep "db_user:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_PASS=$(grep "db_pass:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_NAME=$(grep "db_name:" "$CONFIG" | awk '{print $2}' | tr -d '"')
HOSTNAME=$(grep "hostname:" "$CONFIG" | awk '{print $2}' | tr -d '"')

export PGPASSWORD="$DB_PASS"

# Fetch one pending non-expired task for this machine
TASK=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
  "SELECT id, task_title, body FROM hermes_bus
   WHERE to_host = '$HOSTNAME'
     AND status = 'pending'
     AND (task_expires_at IS NULL OR task_expires_at > NOW())
   ORDER BY created_at ASC
   LIMIT 1;" 2>/dev/null)

[ -z "$TASK" ] && exit 0

TASK_ID=$(echo "$TASK" | cut -d'|' -f1)
TASK_TITLE=$(echo "$TASK" | cut -d'|' -f2)
TASK_BODY=$(echo "$TASK" | cut -d'|' -f3-)

echo "$(date): Received task $TASK_ID — $TASK_TITLE" >> "$LOG"

# Mark claimed
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c \
  "UPDATE hermes_bus SET status='claimed', claimed_at=NOW() WHERE id=$TASK_ID;" 2>/dev/null

# Parse task type from body
TASK_TYPE=$(echo "$TASK_BODY" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get('task', 'hermes_prompt'))
except:
    print('hermes_prompt')
" 2>/dev/null)

RESULT=""

case "$TASK_TYPE" in
  "doctor")
    RESULT=$(~/.ad-fleet/scripts/ad-fleet-doctor.sh 2>&1)
    ;;

  "update")
    GIT_URL=$(echo "$TASK_BODY" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('git_url',''))" 2>/dev/null)
    VERSION=$(echo "$TASK_BODY" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('version',''))" 2>/dev/null)
    SCRIPT=$(echo "$TASK_BODY" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('script','install.sh'))" 2>/dev/null)
    EXPECTED_SHA=$(echo "$TASK_BODY" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('sha256',''))" 2>/dev/null)
    TMP_DIR=$(mktemp -d)
    git clone --depth 1 "$GIT_URL" "$TMP_DIR" 2>&1
    if [ -n "$EXPECTED_SHA" ]; then
      ACTUAL_SHA=$(shasum -a 256 "$TMP_DIR/$VERSION/$SCRIPT" | awk '{print $1}')
      [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ] && RESULT="SHA256 mismatch — update rejected" && rm -rf "$TMP_DIR" && break
    fi
    RESULT=$(bash "$TMP_DIR/$VERSION/$SCRIPT" 2>&1)
    rm -rf "$TMP_DIR"
    ;;

  "drop")
    GIT_URL=$(echo "$TASK_BODY" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('git_url',''))" 2>/dev/null)
    DROP_PATH=$(echo "$TASK_BODY" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('path',''))" 2>/dev/null)
    EXPECTED_SHA=$(echo "$TASK_BODY" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('sha256',''))" 2>/dev/null)
    TMP_DIR=$(mktemp -d)
    git clone --depth 1 "$GIT_URL" "$TMP_DIR" 2>&1
    if [ -n "$EXPECTED_SHA" ]; then
      ACTUAL_SHA=$(shasum -a 256 "$TMP_DIR/$DROP_PATH" | awk '{print $1}')
      [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ] && RESULT="SHA256 mismatch — drop rejected" && rm -rf "$TMP_DIR" && break
    fi
    mkdir -p "$HOME/.ad-fleet/drops"
    cp "$TMP_DIR/$DROP_PATH" "$HOME/.ad-fleet/drops/"
    RESULT="Drop received: $(basename $DROP_PATH)"
    rm -rf "$TMP_DIR"
    ;;

  "ping")
    RESULT="pong — $HOSTNAME alive at $(date)"
    ;;

  "status_report")
    # Deterministic local status collection — no LLM, pure shell
    MAIN_BIN=$(command -v hermes 2>/dev/null || echo "$HOME/.hermes/hermes-agent/venv/bin/hermes")
    FLEET_BIN="$HOME/.ad-fleet/hermes/hermes-agent/venv/bin/hermes"

    # Main Hermes version
    MAIN_VER="not installed"
    [ -x "$MAIN_BIN" ] && MAIN_VER=$("$MAIN_BIN" --version 2>/dev/null | head -1)

    # Fleet Hermes version
    FLEET_VER="not installed"
    [ -x "$FLEET_BIN" ] && FLEET_VER=$(HERMES_HOME="$HOME/.ad-fleet/hermes" "$FLEET_BIN" --version 2>/dev/null | head -1)

    # Main Hermes model + provider from config.yaml (nested format: model:\n  default: X\n  provider: Y)
    MAIN_MODEL="unknown"
    MAIN_PROVIDER="unknown"
    if [ -f "$HOME/.hermes/config.yaml" ]; then
      MAIN_MODEL=$(grep -A1 "^model:" "$HOME/.hermes/config.yaml" 2>/dev/null | grep "default:" | awk '{print $2}' | tr -d '"' || true)
      MAIN_PROVIDER=$(grep -A5 "^model:" "$HOME/.hermes/config.yaml" 2>/dev/null | grep "provider:" | head -1 | awk '{print $2}' | tr -d '"' || true)
      [ -z "$MAIN_MODEL" ] && MAIN_MODEL="unknown"
      [ -z "$MAIN_PROVIDER" ] && MAIN_PROVIDER="unknown"
    fi

    # Fleet Hermes model + provider from config.yaml
    FLEET_MODEL="unknown"
    FLEET_PROVIDER="unknown"
    if [ -f "$HOME/.ad-fleet/hermes/config.yaml" ]; then
      FLEET_MODEL=$(grep -A1 "^model:" "$HOME/.ad-fleet/hermes/config.yaml" 2>/dev/null | grep "default:" | awk '{print $2}' | tr -d '"' || true)
      FLEET_PROVIDER=$(grep -A5 "^model:" "$HOME/.ad-fleet/hermes/config.yaml" 2>/dev/null | grep "provider:" | head -1 | awk '{print $2}' | tr -d '"' || true)
      [ -z "$FLEET_MODEL" ] && FLEET_MODEL="unknown"
      [ -z "$FLEET_PROVIDER" ] && FLEET_PROVIDER="unknown"
    fi

    # Port checks
    MAIN_PORT=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8000/v1/models 2>/dev/null)
    [ -z "$MAIN_PORT" ] && MAIN_PORT="000"
    FLEET_PORT=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8001/v1/models 2>/dev/null)
    [ -z "$FLEET_PORT" ] && FLEET_PORT="000"

    # LaunchAgent status
    HB_STATUS="not loaded"
    launchctl list com.ad-fleet.heartbeat >/dev/null 2>&1 && HB_STATUS="loaded"
    POLLER_STATUS="not loaded"
    launchctl list com.ad-fleet.poller >/dev/null 2>&1 && POLLER_STATUS="loaded"
    GW_STATUS="not loaded"
    launchctl list com.ad-fleet.hermes-gateway >/dev/null 2>&1 && GW_STATUS="loaded"

    # Build JSON result
    RESULT=$(python3 -c "
import json
print(json.dumps({
    'hostname': '$HOSTNAME',
    'main_hermes': {'version': '$MAIN_VER', 'model': '$MAIN_MODEL', 'provider': '$MAIN_PROVIDER', 'port_8000': '$MAIN_PORT'},
    'fleet_hermes': {'version': '$FLEET_VER', 'model': '$FLEET_MODEL', 'provider': '$FLEET_PROVIDER', 'port_8001': '$FLEET_PORT'},
    'daemons': {'heartbeat': '$HB_STATUS', 'poller': '$POLLER_STATUS', 'gateway': '$GW_STATUS'}
}))
" 2>/dev/null)
    ;;

  "join_approved")
    # Admin approved our join request — update local config role
    APPROVED_ROLE=$(echo "$TASK_BODY" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('role','writer'))" 2>/dev/null)
    # Map DB roles to display roles for local config
    if [ "$APPROVED_ROLE" = "admin" ]; then
      CONFIG_ROLE="admin"
    else
      CONFIG_ROLE="member"
    fi
    # Update role in local config
    if [ -f "$CONFIG" ]; then
      sed -i '' "s/role: \".*\"/role: \"$CONFIG_ROLE\"/" "$CONFIG" 2>/dev/null || \
        sed -i "s/role: \".*\"/role: \"$CONFIG_ROLE\"/" "$CONFIG" 2>/dev/null
    fi
    RESULT="Join approved — local role updated to $CONFIG_ROLE"
    ;;

  "fleet_update")
    # Pull latest scripts from GitHub and reload daemons
    if [ -f "$HOME/.ad-fleet/scripts/ad-fleet-update.sh" ]; then
      RESULT=$(bash "$HOME/.ad-fleet/scripts/ad-fleet-update.sh" 2>&1)
    else
      RESULT="ad-fleet-update.sh not found — cannot update"
    fi
    ;;

  "fleet_alert")
    # A watchdog on another machine is alerting us — forward via Telegram if we have it
    ALERT_MSG=$(echo "$TASK_BODY" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    host = d.get('host', 'unknown')
    msg = d.get('message', 'No details')
    print(f'🚨 AD-Fleet Alert\nMachine: {host}\n{msg}')
except:
    print(sys.stdin.read())
" 2>/dev/null)
    # Send via main Hermes telegram if configured
    HERMES_BIN=$(command -v hermes 2>/dev/null || echo "$HOME/.hermes/hermes-agent/venv/bin/hermes")
    if [ -x "$HERMES_BIN" ]; then
      HERMES_HOME="$HOME/.hermes" "$HERMES_BIN" send "$ALERT_MSG" -t telegram 2>/dev/null || true
    fi
    RESULT="Alert forwarded: $ALERT_MSG"
    ;;

  "hermes_prompt")
    # Send prompt to fleet Hermes API server on port 8001
    FLEET_API_KEY=$(grep "API_SERVER_KEY=" "$HOME/.ad-fleet/hermes/.env" 2>/dev/null | cut -d'=' -f2)
    PROMPT_TEXT=$(echo "$TASK_BODY" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('prompt', d.get('task','')))" 2>/dev/null)
    if [ -z "$PROMPT_TEXT" ]; then
      PROMPT_TEXT="$TASK_BODY"
    fi
    # Escape for JSON
    PROMPT_JSON=$(echo "$PROMPT_TEXT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null)
    RESULT=$(curl -s --max-time 60 \
      http://127.0.0.1:8001/v1/chat/completions \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $FLEET_API_KEY" \
      -d "{\"model\":\"hermes-agent\",\"messages\":[{\"role\":\"user\",\"content\":$PROMPT_JSON}],\"max_tokens\":200,\"stream\":false}" \
      2>&1 | python3 -c "import sys,json; r=json.loads(sys.stdin.read()); print(r.get('choices',[{}])[0].get('message',{}).get('content','ERROR: no response'))" 2>/dev/null)
    if [ -z "$RESULT" ]; then
      RESULT="ERROR: fleet Hermes did not respond (port 8001 may be down)"
    fi
    ;;

  *)
    RESULT="Unknown task type: $TASK_TYPE"
    ;;
esac

# Write result back
SAFE_RESULT=$(echo "$RESULT" | sed "s/'/''/g" | head -c 4000)
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c \
  "UPDATE hermes_bus SET status='done', result='$SAFE_RESULT', done_at=NOW() WHERE id=$TASK_ID;" 2>/dev/null

echo "$(date): Task $TASK_ID done — $TASK_TITLE" >> "$LOG"
tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
