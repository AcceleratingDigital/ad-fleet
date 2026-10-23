#!/bin/bash
# ad-fleet-specs-update.sh — Collect machine specs and upsert into fleet_specs
# Part of: AcceleratingDigital Fleet (ad-fleet)
#
# Run paths:
#   1. At registration — the installer calls this right after the first heartbeat
#   2. On demand — fleet admin sends a 'specs_update' task; the poller runs this
#
# Specs are NOT refreshed on every heartbeat (they rarely change).

CONFIG="$HOME/.ad-fleet/config.yaml"
LOG="$HOME/.ad-fleet/logs/specs.log"
SPEC_SCRIPT="$HOME/.ad-fleet/scripts/ad-fleet-specs.sh"
mkdir -p "$HOME/.ad-fleet/logs"

[ ! -f "$CONFIG" ] && echo "No ad-fleet config at $CONFIG" && exit 1
[ ! -x "$SPEC_SCRIPT" ] && echo "Specs collector missing at $SPEC_SCRIPT" && exit 1

DB_HOST=$(grep "db_host:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_PORT=$(grep "db_port:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_USER=$(grep "db_user:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_PASS=$(grep "db_pass:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_NAME=$(grep "db_name:" "$CONFIG" | awk '{print $2}' | tr -d '"')
MACHINE_UUID=$(cat "$HOME/.ad-fleet/machine_id" 2>/dev/null || echo "")

# Resolve psql (same order as the daemons)
PSQL=""
for p in "$HOME/.ad-fleet/bin/psql" /opt/homebrew/bin/psql /usr/local/bin/psql /opt/homebrew/opt/libpq/bin/psql $(command -v psql 2>/dev/null); do
  [ -x "$p" ] && PSQL="$p" && break
done
[ -z "$PSQL" ] && echo "$(date): Specs FAILED — psql not found" >> "$LOG" && exit 1

SPECS=$(bash "$SPEC_SCRIPT" 2>/dev/null)
if ! echo "$SPECS" | grep -qE '^[^|]+\|[^|]*\|[^|]*\|[^|]*\|'; then
  echo "$(date): Specs FAILED — collector produced no usable output" >> "$LOG"
  exit 1
fi

IFS='|' read -r S_HOST S_RAM S_DTOT S_DFREE S_CPU S_OS S_ARCH S_HERMES S_USER S_MTYPE <<< "$SPECS"
export PGPASSWORD="$DB_PASS"
if "$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c "
INSERT INTO fleet_specs (hostname, ram_gb, disk_total_gb, disk_free_gb, cpu_type, os_version, arch, hermes_version, user_name, member_type, machine_uuid, collected_at)
VALUES ('$S_HOST', NULLIF('$S_RAM','')::int, NULLIF('$S_DTOT','')::int, NULLIF('$S_DFREE','')::int,
        '$S_CPU', '$S_OS', '$S_ARCH', '$S_HERMES', '$S_USER', '$S_MTYPE', NULLIF('$MACHINE_UUID','')::uuid, NOW())
ON CONFLICT (hostname) DO UPDATE SET
  ram_gb=EXCLUDED.ram_gb, disk_total_gb=EXCLUDED.disk_total_gb, disk_free_gb=EXCLUDED.disk_free_gb,
  cpu_type=EXCLUDED.cpu_type, os_version=EXCLUDED.os_version, arch=EXCLUDED.arch,
  hermes_version=EXCLUDED.hermes_version, user_name=EXCLUDED.user_name, member_type=EXCLUDED.member_type,
  machine_uuid=EXCLUDED.machine_uuid, collected_at=NOW();" 2>>"$LOG"; then
  echo "$(date): Specs updated — $S_HOST" >> "$LOG"
  exit 0
else
  echo "$(date): Specs update FAILED — $S_HOST (DB error logged above)" >> "$LOG"
  exit 1
fi
