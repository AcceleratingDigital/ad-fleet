#!/bin/bash
# ad-fleet-heartbeat.sh — Send heartbeat to fleet_status
# Part of: AcceleratingDigital Fleet (ad-fleet)
# Reads from: ~/.ad-fleet/config.yaml

CONFIG="$HOME/.ad-fleet/config.yaml"
LOG="$HOME/.ad-fleet/logs/heartbeat.log"
[ ! -f "$CONFIG" ] && echo "No ad-fleet config at $CONFIG" && exit 1

DB_HOST=$(grep "db_host:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_PORT=$(grep "db_port:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_USER=$(grep "db_user:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_PASS=$(grep "db_pass:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_NAME=$(grep "db_name:" "$CONFIG" | awk '{print $2}' | tr -d '"')
HOSTNAME=$(grep "hostname:" "$CONFIG" | awk '{print $2}' | tr -d '"')
MACHINE_UUID=$(cat "$HOME/.ad-fleet/machine_id" 2>/dev/null || echo "")

export PGPASSWORD="$DB_PASS"

if [ -n "$MACHINE_UUID" ]; then
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c \
    "INSERT INTO fleet_status (hostname, last_seen, updated_at, machine_uuid)
     VALUES ('$HOSTNAME', NOW(), NOW(), '$MACHINE_UUID')
     ON CONFLICT (hostname) DO UPDATE
     SET last_seen = EXCLUDED.last_seen, updated_at = NOW(), machine_uuid = EXCLUDED.machine_uuid;" 2>&1
else
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c \
    "INSERT INTO fleet_status (hostname, last_seen, updated_at)
     VALUES ('$HOSTNAME', NOW(), NOW())
     ON CONFLICT (hostname) DO UPDATE
     SET last_seen = EXCLUDED.last_seen, updated_at = NOW();" 2>&1
fi

if [ $? -eq 0 ]; then
  echo "$(date): Heartbeat OK — $HOSTNAME" >> "$LOG"
else
  echo "$(date): Heartbeat FAILED — $HOSTNAME" >> "$LOG"
fi

# Keep log to last 500 lines
tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
