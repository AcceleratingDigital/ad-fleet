#!/bin/bash
# ad-fleet-heartbeat.sh — Send heartbeat to fleet_status
# Part of: AcceleratingDigital Fleet (ad-fleet) — v5 (self-reporting)
# Reads from: ~/.ad-fleet/config.yaml
#
# v5 changes:
#   - Resolves psql robustly (bare `psql` fails on libpq-only installs — this
#     silently killed heartbeats on new member machines)
#   - On failure, reports the issue to fleet admins via hermes_bus
#     (rate-limited to 1 report/hour)

CONFIG="$HOME/.ad-fleet/config.yaml"
LOG="$HOME/.ad-fleet/logs/heartbeat.log"
ISSUE_FLAG="$HOME/.ad-fleet/logs/.hb_issue_last"
[ ! -f "$CONFIG" ] && echo "No ad-fleet config at $CONFIG" && exit 1

DB_HOST=$(grep "db_host:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_PORT=$(grep "db_port:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_USER=$(grep "db_user:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_PASS=$(grep "db_pass:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_NAME=$(grep "db_name:" "$CONFIG" | awk '{print $2}' | tr -d '"')
HOSTNAME=$(grep "hostname:" "$CONFIG" | awk '{print $2}' | tr -d '"')
MACHINE_UUID=$(cat "$HOME/.ad-fleet/machine_id" 2>/dev/null || echo "")

export PGPASSWORD="$DB_PASS"

# ─── Robust psql resolution ──────────────────────────────────────────────────
# Order: our own symlink (installer creates it), common prefixes, libpq's
# unlinked location, then whatever is in PATH.
PSQL=""
for p in "$HOME/.ad-fleet/bin/psql" /opt/homebrew/bin/psql /usr/local/bin/psql /opt/homebrew/opt/libpq/bin/psql $(command -v psql 2>/dev/null); do
  [ -x "$p" ] && PSQL="$p" && break
done

if [ -z "$PSQL" ]; then
  echo "$(date): Heartbeat FAILED — psql not found anywhere" >> "$LOG"
  report_issue "heartbeat: psql binary not found on $HOSTNAME — cannot reach fleet DB. Fix: run ~/.ad-fleet/scripts/ad-fleet-repair.sh or 'brew install libpq'"
  exit 1
fi

# ─── Self-report helper (rate-limited: max 1 per hour) ───────────────────────
report_issue() {
  local msg="$1"
  local now last=0
  now=$(date +%s)
  [ -f "$ISSUE_FLAG" ] && last=$(cat "$ISSUE_FLAG" 2>/dev/null || echo 0)
  [ "$now" -lt "$last" ] 2>/dev/null && last=0
  if [ $((now - last)) -gt 3600 ]; then
    SAFE_MSG=$(echo "$msg" | sed "s/'/''/g" | head -c 500)
    "$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c \
      "INSERT INTO hermes_bus (from_host, to_host, kind, body, task_title, task_expires_at)
       VALUES ('$HOSTNAME', 'fleet-admin', 'msg',
       '{\"task\":\"daemon_issue\",\"source\":\"heartbeat\",\"message\":\"$SAFE_MSG\"}',
       'DAEMON ISSUE: $HOSTNAME — heartbeat failing', NOW() + INTERVAL '48 hours');" >/dev/null 2>&1 \
      && echo "$now" > "$ISSUE_FLAG"
  fi
}

HB_ERR=$( "$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c "
INSERT INTO fleet_status (hostname, last_seen, updated_at, machine_uuid)
 VALUES ('$HOSTNAME', NOW(), NOW(), '$MACHINE_UUID')
 ON CONFLICT (hostname) DO UPDATE
 SET last_seen = EXCLUDED.last_seen, updated_at = NOW(), machine_uuid = EXCLUDED.machine_uuid;" 2>&1 )

if [ $? -eq 0 ]; then
  echo "$(date): Heartbeat OK — $HOSTNAME" >> "$LOG"
  rm -f "$ISSUE_FLAG" 2>/dev/null
else
  echo "$(date): Heartbeat FAILED — $HOSTNAME : $(echo "$HB_ERR" | head -1)" >> "$LOG"
  report_issue "heartbeat: DB insert failed on $HOSTNAME — $(echo "$HB_ERR" | head -2 | tr '\n' ' ' | head -c 300)"
fi

# Keep log to last 500 lines
tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
