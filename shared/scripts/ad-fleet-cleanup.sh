#!/bin/bash
# ad-fleet-cleanup.sh — Remove old hermesbus/fleet v1-v3 setup
# Part of: AcceleratingDigital Fleet (ad-fleet)
# SAFE: Does NOT touch user's Hermes (~/.hermes/config.yaml, sessions, skills)
# SAFE: Does NOT modify ~/ADTools/config/secrets.conf

set -euo pipefail

echo "=== AD-FLEET CLEANUP ==="
echo "Removing old fleet setup (hermesbus v1-v3)..."
echo "User's Hermes at ~/.hermes/ will NOT be touched."
echo ""

# --- Remove old LaunchAgents ---
OLD_AGENTS=(
  "com.hermesbus.poll"
  "com.hermesbus.heartbeat"
  "com.hermes.fleet-heartbeat"
  "com.hermes.fleet-poller"
  "com.fleet.heartbeat"
  "com.fleet.poller"
)

echo "--- Removing old LaunchAgents ---"
for agent in "${OLD_AGENTS[@]}"; do
  PLIST="$HOME/Library/LaunchAgents/${agent}.plist"
  if [ -f "$PLIST" ]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "  ✅ Removed: $agent"
  else
    echo "  ⏭️  Not found: $agent"
  fi
done

# Remove old plist backups (*.plist.bak, *.plist.disabled)
for bak in "$HOME/Library/LaunchAgents/com.hermes.fleet-"*.plist.bak \
           "$HOME/Library/LaunchAgents/com.hermesbus."*.plist.bak \
           "$HOME/Library/LaunchAgents/com.fleet."*.plist.bak; do
  [ -f "$bak" ] && rm -f "$bak" && echo "  ✅ Removed backup: $(basename "$bak")" || true
done

# --- Remove old fleet scripts from ~/.hermes/scripts/ ---
echo ""
echo "--- Removing old fleet scripts from ~/.hermes/scripts/ ---"
OLD_SCRIPTS=(
  "hermesbus.sh"
  "hermesbus.sh.new"
  "hermesbus.sh.backup*"
  "hermesbus.sh.bak"
  "hermesbus-poll.sh"
  "hermesbus-cleanup.sh"
  "hermesbus-heartbeat.sh"
  "fleet-heartbeat.sh"
  "fleet-heartbeat-direct.sh"
  "fleet-status-poll.sh"
  "send-file-via-bus.sh"
  "receive-file-from-bus.sh"
  "hermesbus-poll-with-file-transfer.sh"
)

for script in "${OLD_SCRIPTS[@]}"; do
  for f in "$HOME/.hermes/scripts/"$script; do
    if [ -f "$f" ]; then
      rm -f "$f"
      echo "  ✅ Removed: $(basename $f)"
    fi
  done
done

# --- Remove old fleet hermes cron jobs ---
echo ""
echo "--- Checking for old fleet hermes cron jobs ---"
# Extract only valid job IDs (alphanumeric, no colons)
OLD_CRONS=$(hermes cron list 2>/dev/null | grep -i "heartbeat\|hermesbus\|fleet-poll" | grep -oE '[a-f0-9]{8,}' | head -20 || true)
if [ -n "$OLD_CRONS" ]; then
  for cron_id in $OLD_CRONS; do
    hermes cron remove "$cron_id" 2>/dev/null && echo "  ✅ Removed cron: $cron_id" || echo "  ⏭️  Could not remove: $cron_id"
  done
else
  echo "  ⏭️  No old fleet cron jobs found"
fi

# --- Remove old fleet config from ADTools (do NOT delete file, just note) ---
echo ""
echo "--- Old Fleet Config ---"
echo "  ⚠️  ~/ADTools/config/secrets.conf left intact (user's personal config)"
echo "  ⚠️  Old FLEET_DB_USER/FLEET_DB_PASS left in place (may be used by other tools)"
echo "  ✅  New credentials are in ~/.ad-fleet/config.yaml"

echo ""
echo "=== CLEANUP COMPLETE ==="
echo "Old fleet setup removed. User's Hermes (~/.hermes/) is untouched."
echo "Run ad-fleet-doctor.sh to verify new setup is healthy."
