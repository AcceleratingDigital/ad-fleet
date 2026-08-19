#!/bin/bash
# ad-fleet-update.sh — Pull latest fleet scripts from GitHub and reload daemons
# Part of: AcceleratingDigital Fleet (ad-fleet)
# Triggered by poller when it receives a "fleet_update" task
#
# This script:
# 1. Clones/pulls the ad-fleet repo to ~/.ad-fleet/repo
# 2. Copies updated scripts to ~/.ad-fleet/scripts/
# 3. Reloads heartbeat + poller LaunchAgents
# 4. Optionally deploys skills to user's Hermes

set -euo pipefail

FLEET_DIR="$HOME/.ad-fleet"
REPO_DIR="$FLEET_DIR/repo"
REPO_URL="https://github.com/AcceleratingDigital/ad-fleet.git"
LOG="$FLEET_DIR/logs/update.log"
mkdir -p "$FLEET_DIR/logs" 2>/dev/null || true

log()  { echo "[$(date '+%H:%M:%S')] $*"; }

# --- Clone or pull ---
if [ -d "$REPO_DIR/.git" ]; then
  log "Pulling latest from GitHub..."
  cd "$REPO_DIR"
  git pull origin main 2>&1 | tail -5
else
  log "Cloning ad-fleet repo..."
  git clone --depth 1 "$REPO_URL" "$REPO_DIR" 2>&1 | tail -5
  cd "$REPO_DIR"
fi

# --- Determine role ---
ROLE=$(grep "role:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
log "Machine role: $ROLE"

# --- Copy updated shared scripts ---
log "Updating shared scripts..."
cp "$REPO_DIR/shared/scripts/"*.sh "$FLEET_DIR/scripts/" 2>/dev/null || true
chmod +x "$FLEET_DIR/scripts/"*.sh 2>/dev/null || true

# --- Copy role-specific scripts ---
if [ "$ROLE" = "admin" ]; then
  log "Updating admin scripts..."
  cp "$REPO_DIR/admin/scripts/"*.sh "$FLEET_DIR/scripts/" 2>/dev/null || true
elif [ "$ROLE" = "member" ]; then
  log "Updating member scripts..."
  cp "$REPO_DIR/member/scripts/"*.sh "$FLEET_DIR/scripts/" 2>/dev/null || true
fi
chmod +x "$FLEET_DIR/scripts/"*.sh 2>/dev/null || true

# --- Reload LaunchAgents so they pick up new scripts ---
log "Reloading daemons..."
for agent in com.ad-fleet.heartbeat com.ad-fleet.poller; do
  PLIST="$HOME/Library/LaunchAgents/${agent}.plist"
  if [ -f "$PLIST" ]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST" 2>/dev/null || true
    log "  Reloaded: $agent"
  fi
done

# --- Deploy skills to user's Hermes (admin only) ---
if [ "$ROLE" = "admin" ] && [ -d "$REPO_DIR/skills" ]; then
  USER_HERMES_SKILLS="$HOME/.hermes/skills"
  if [ -d "$USER_HERMES_SKILLS" ]; then
    log "Deploying fleet skills to user Hermes..."
    for skill_dir in "$REPO_DIR/skills/"*/; do
      skill_name=$(basename "$skill_dir")
      target="$USER_HERMES_SKILLS/$skill_name"
      mkdir -p "$target"
      cp -r "$skill_dir"* "$target/" 2>/dev/null || true
      log "  Deployed skill: $skill_name"
    done
  fi
fi

# --- Run doctor to verify ---
log "Running doctor..."
bash "$FLEET_DIR/scripts/ad-fleet-doctor.sh" 2>&1 | grep -E "OK|WARN|FAIL|NOT" || true

log "Update complete."
echo "$(date): Update complete" >> "$LOG"
