#!/bin/bash
# ad-fleet-join-member.sh — Member One-Click Installer
# AcceleratingDigital Fleet v4 — MEMBER PACKAGE
# State-machine: re-running resumes from last completed phase
#
# This installer is for MEMBER machines only.
# Admin setup uses a separate package.

set -euo pipefail

FLEET_DIR="$HOME/.ad-fleet"
STATE_FILE="$FLEET_DIR/install_state.json"
LOG="$FLEET_DIR/logs/install.log"
mkdir -p "$FLEET_DIR/logs" 2>/dev/null || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Helpers ─────────────────────────────────────────────────────────────────
log()  { local msg="[$(date '+%H:%M:%S')] $*"; echo "$msg"; echo "$msg" >> "$LOG" 2>/dev/null || true; }
ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; }
fail() { echo "  ❌ $*"; exit 1; }

save_state() { echo "{\"phase\": $1, \"updated\": \"$(date)\"}" > "$STATE_FILE"; }
get_state()  {
  [ -f "$STATE_FILE" ] && \
    python3 -c "import json; print(json.load(open('$STATE_FILE'))['phase'])" 2>/dev/null || \
    echo 0
}

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     AcceleratingDigital Fleet — Member Setup         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

PHASE=$(get_state)
[ "$PHASE" -gt 0 ] && log "Resuming from phase $PHASE..." || log "Starting fresh installation..."

# ─── Phase 0: Cleanup old fleet and stale state ──────────────────────────────
# Always runs — not gated by save_state. Safe to run multiple times.
log "Phase 0: Cleaning up old fleet remnants..."
CLEANUP_SCRIPT="$FLEET_DIR/scripts/ad-fleet-cleanup.sh"

# Run the bundled cleanup script if available
if [ -f "$SCRIPT_DIR/scripts/ad-fleet-cleanup.sh" ]; then
  bash "$SCRIPT_DIR/scripts/ad-fleet-cleanup.sh" 2>&1 | while read -r line; do echo "  $line"; done
elif [ -f "$CLEANUP_SCRIPT" ]; then
  bash "$CLEANUP_SCRIPT" 2>&1 | while read -r line; do echo "  $line"; done
else
  # Inline fallback — unload old LaunchAgents
  for agent in com.hermesbus.poll com.hermesbus.heartbeat com.hermes.fleet-heartbeat com.hermes.fleet-poller com.fleet.heartbeat com.fleet.poller; do
    PLIST="$HOME/Library/LaunchAgents/${agent}.plist"
    if [ -f "$PLIST" ]; then
      launchctl unload "$PLIST" 2>/dev/null || true
      rm -f "$PLIST"
      ok "Removed old agent: $agent"
    fi
  done
  # Remove old scripts
  for s in hermesbus.sh hermesbus-poll.sh hermesbus-cleanup.sh fleet-heartbeat.sh fleet-heartbeat-direct.sh fleet-status-poll.sh; do
    rm -f "$HOME/.hermes/scripts/$s" 2>/dev/null && ok "Removed old script: $s" || true
  done
fi

# If re-running on an existing ad-fleet install, reload daemons to pick up updated scripts
if [ "$PHASE" -gt 0 ] && [ -f "$FLEET_DIR/config.yaml" ]; then
  log "Existing ad-fleet install detected — reloading daemons with updated scripts..."
  # Copy fresh scripts from the ZIP (if available) over the installed ones
  if [ -d "$SCRIPT_DIR/scripts" ]; then
    cp "$SCRIPT_DIR/scripts/"*.sh "$FLEET_DIR/scripts/" 2>/dev/null || true
    chmod +x "$FLEET_DIR/scripts/"*.sh 2>/dev/null || true
    ok "Updated fleet scripts from package"
  fi
  # Reload LaunchAgents so they pick up the new script content
  for agent in com.ad-fleet.heartbeat com.ad-fleet.poller; do
    PLIST="$HOME/Library/LaunchAgents/${agent}.plist"
    if [ -f "$PLIST" ]; then
      launchctl unload "$PLIST" 2>/dev/null || true
      launchctl load "$PLIST" 2>/dev/null || true
      ok "Reloaded: $agent"
    fi
  done
fi
echo ""

# ─── Check psql (required for DB access) ─────────────────────────────────────
# Not a numbered phase — always runs, lightweight check
PSQL_BIN=""
for p in /opt/homebrew/bin/psql /usr/local/bin/psql $(command -v psql 2>/dev/null); do
  [ -x "$p" ] && PSQL_BIN="$p" && break
done
if [ -n "$PSQL_BIN" ]; then
  ok "psql found at $PSQL_BIN"
else
  warn "psql not found — installing via Homebrew..."
  if command -v brew &>/dev/null; then
    brew install libpq 2>&1 | tail -3
    # libpq installs psql but doesn't link it
    BREW_PREFIX=$(brew --prefix libpq 2>/dev/null)
    if [ -x "$BREW_PREFIX/bin/psql" ]; then
      PSQL_BIN="$BREW_PREFIX/bin/psql"
      ok "psql installed at $PSQL_BIN"
    elif [ -x /opt/homebrew/bin/psql ]; then
      PSQL_BIN="/opt/homebrew/bin/psql"
      ok "psql installed at $PSQL_BIN"
    elif [ -x /usr/local/bin/psql ]; then
      PSQL_BIN="/usr/local/bin/psql"
      ok "psql installed at $PSQL_BIN"
    else
      warn "psql installed but location unknown — daemons may fail to reach DB"
    fi
  else
    warn "Homebrew not found — cannot auto-install psql"
    warn "Install manually: brew install libpq, or daemons won't reach DB"
  fi
fi
echo ""

# ─── Phase 1: Create directory structure ─────────────────────────────────────
if [ "$PHASE" -lt 1 ]; then
  log "Phase 1: Creating ~/.ad-fleet/ structure..."
  mkdir -p "$FLEET_DIR"/{scripts,logs,drops,hermes/bin}
  chmod 700 "$FLEET_DIR"
  mkdir -p "$FLEET_DIR/logs"
  touch "$FLEET_DIR/logs/heartbeat.log" "$FLEET_DIR/logs/poller.log" "$FLEET_DIR/logs/install.log"
  save_state 1
  ok "Fleet directories created at ~/.ad-fleet/"
fi

# ─── Phase 2: Check Ollama ────────────────────────────────────────────────────
if [ "$PHASE" -lt 2 ]; then
  log "Phase 2: Checking Ollama..."
  if command -v ollama &>/dev/null; then
    ok "Ollama already installed ($(ollama --version 2>/dev/null || echo 'version unknown'))"
  else
    warn "Ollama not found. Installing..."
    if [ -f "$SCRIPT_DIR/resources/ollama-install.sh" ]; then
      bash "$SCRIPT_DIR/resources/ollama-install.sh" || OLLAMA_FAIL=true
    else
      curl -fsSL https://ollama.ai/install.sh | sh || OLLAMA_FAIL=true
    fi
    if [ "${OLLAMA_FAIL:-false}" = true ]; then
      warn "Ollama install failed — skipping (fleet Hermes uses LiteLLM, Ollama is optional)"
      warn "Intel machines without GPU cannot run Ollama. This is OK."
      save_state 2
    else
      ok "Ollama installed"
    fi
  fi

  # Only pull model if Ollama is actually running
  if command -v ollama >/dev/null 2>&1 && ollama list >/dev/null 2>&1; then
    MODEL_OK=false
    for i in 1 2; do
      if ollama list 2>/dev/null | grep -q "qwen2.5:3b"; then
        MODEL_OK=true
        break
      fi
      sleep 2
    done
    if [ "$MODEL_OK" = true ]; then
      ok "qwen2.5:3b already present"
    else
      log "Pulling qwen2.5:3b (this may take a few minutes on first run)..."
      ollama pull qwen2.5:3b && ok "qwen2.5:3b ready" || warn "Model pull failed — retry with: ollama pull qwen2.5:3b"
    fi
  else
    warn "Ollama not running — skipping model pull (non-critical, LiteLLM is primary)"
  fi
  save_state 2
fi

# ─── Phase 3: Gather machine info ────────────────────────────────────────────
if [ "$PHASE" -lt 3 ]; then
  log "Phase 3: Machine setup..."
  echo ""
  echo "  Just 3 quick questions:"
  echo ""
  read -r -p "  Your Name: " USER_NAME
  SUGGESTED_NAME=$(hostname -s | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  read -r -p "  Machine name [Enter for '$SUGGESTED_NAME']: " MACHINE_NAME
  MACHINE_NAME="${MACHINE_NAME:-$SUGGESTED_NAME}"
  if ! [[ "$MACHINE_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    MACHINE_NAME="$SUGGESTED_NAME"
    warn "Invalid name — using suggested: $MACHINE_NAME"
  fi
  read -r -p "  Machine type [A=always-on / T=travels or sleeps]: " CLASS_INPUT
  TEAM="member"
  echo ""
  CLASS_INPUT_UPPER=$(echo "$CLASS_INPUT" | tr '[:lower:]' '[:upper:]')
  case "$CLASS_INPUT_UPPER" in
    A) CLASS="always-on" ;;
    T) CLASS="transient" ;;
    *) CLASS="transient" ; warn "Defaulting to transient" ;;
  esac

  # Save to temp file for next phase
  echo "$USER_NAME|$CLASS|$TEAM|$MACHINE_NAME" > "$FLEET_DIR/.install_tmp"
  save_state 3
  ok "Machine info saved"
fi

# ─── Phase 4: Generate UUID and write config ──────────────────────────────────
if [ "$PHASE" -lt 4 ]; then
  log "Phase 4: Writing fleet config..."

  # Read saved info
  IFS='|' read -r USER_NAME CLASS TEAM MACHINE_NAME < "$FLEET_DIR/.install_tmp"
  HOSTNAME="$MACHINE_NAME"
  MACHINE_UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
  echo "$MACHINE_UUID" > "$FLEET_DIR/machine_id"

  # Write member config — uses PUBLIC db endpoint
  cat > "$FLEET_DIR/config.yaml" << YAML
# AcceleratingDigital Fleet — Member Config
# Generated: $(date)

fleet:
  db_host: "db.acceleratingdigital.com"
  db_port: 5432
  db_user: "fleet_member"
  db_pass: "nE7gH2jT5wQ8bL1sM4cX6yP3rV9kD0fA2nJ7hZ"
  db_name: "hermes_fleet"
  llm_url: "https://llm.acceleratingdigital.com"
  llm_api_key: "sk-piyush-3d76f8d548c411e2eec59fdb"

machine:
  hostname: "$HOSTNAME"
  uuid: "$MACHINE_UUID"
  role: "member"
  classification: "$CLASS"
  team: "$TEAM"
  user: "$USER_NAME"
  registered_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
YAML

  chmod 600 "$FLEET_DIR/config.yaml"
  rm -f "$FLEET_DIR/.install_tmp"
  save_state 4
  ok "Config written (UUID: $MACHINE_UUID)"
fi

# ─── Phase 5: Install scripts and LaunchAgents ───────────────────────────────
if [ "$PHASE" -lt 5 ]; then
  log "Phase 5: Installing scripts..."
  cp "$SCRIPT_DIR/scripts/"*.sh "$FLEET_DIR/scripts/"
  chmod +x "$FLEET_DIR/scripts/"*.sh

  log "Phase 5: Installing LaunchAgents..."
  LA_DIR="$HOME/Library/LaunchAgents"
  mkdir -p "$LA_DIR"

  for PLIST in "$SCRIPT_DIR/LaunchAgents/"com.ad-fleet.*.plist; do
    PLIST_NAME=$(basename "$PLIST")
    LABEL="${PLIST_NAME%.plist}"
    DEST="$LA_DIR/$PLIST_NAME"

    # Unload if already running
    launchctl unload "$DEST" 2>/dev/null || true

    # Install with HOME path substituted
    sed "s|HOME_PLACEHOLDER|$HOME|g" "$PLIST" > "$DEST"

    # Load
    launchctl load "$DEST" && ok "Loaded: $LABEL" || warn "Failed to load: $LABEL"
  done
  save_state 5
fi

# ─── Phase 6: Run cleanup of old fleet setup ─────────────────────────────────
if [ "$PHASE" -lt 6 ]; then
  log "Phase 6: Cleaning up old fleet setup..."
  if [ -f "$FLEET_DIR/scripts/ad-fleet-cleanup.sh" ]; then
    bash "$FLEET_DIR/scripts/ad-fleet-cleanup.sh" 2>/dev/null || warn "Cleanup had warnings (non-critical)"
  fi
  save_state 6
fi

# ─── Phase 7: Test DB connectivity ───────────────────────────────────────────
if [ "$PHASE" -lt 7 ]; then
  log "Phase 7: Testing database connectivity..."
  DB_HOST=$(grep "db_host:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  DB_PORT=$(grep "db_port:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  DB_USER=$(grep "db_user:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  DB_PASS=$(grep "db_pass:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  DB_NAME=$(grep "db_name:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')

  export PGPASSWORD="$DB_PASS"
  if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" &>/dev/null; then
    ok "Database connection successful"
  else
    warn "Database connection failed — check network. Heartbeat will retry automatically."
  fi
  save_state 7
fi

# ─── Phase 8: Send join request (admin must approve) ─────────────────────────
if [ "$PHASE" -lt 8 ]; then
  log "Phase 8: Sending join request to fleet admins..."

  DB_HOST=$(grep "db_host:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  DB_PORT=$(grep "db_port:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  DB_USER=$(grep "db_user:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  DB_PASS=$(grep "db_pass:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  DB_NAME=$(grep "db_name:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  HOSTNAME=$(grep "hostname:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  MACHINE_UUID=$(cat "$FLEET_DIR/machine_id")
  USER_NAME=$(grep "^  user:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  CLASS=$(grep "classification:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  TEAM=$(grep "team:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')

  export PGPASSWORD="$DB_PASS"
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c \
    "INSERT INTO hermes_bus (from_host, to_host, kind, body, task_title, task_expires_at)
     VALUES (
       '$HOSTNAME',
       'fleet-admin',
       'msg',
       '{\"task\":\"join_request\",\"hostname\":\"$HOSTNAME\",\"uuid\":\"$MACHINE_UUID\",\"classification\":\"$CLASS\",\"team\":\"$TEAM\",\"user\":\"$USER_NAME\"}',
       'JOIN REQUEST: $HOSTNAME ($USER_NAME, $TEAM) wants to join the fleet',
       NOW() + INTERVAL '24 hours'
     );" 2>/dev/null && ok "Join request sent to fleet admins" || warn "Could not send join request — check DB connection"

  save_state 8
fi

# ─── Phase 9: Fire first heartbeat ───────────────────────────────────────────
if [ "$PHASE" -lt 9 ]; then
  log "Phase 9: Sending first heartbeat..."
  bash "$FLEET_DIR/scripts/ad-fleet-heartbeat.sh" && ok "First heartbeat sent" || \
    warn "Heartbeat failed — daemon will retry in 5 min"
  save_state 9
fi

# ─── Phase 10: Run doctor ────────────────────────────────────────────────────
if [ "$PHASE" -lt 10 ]; then
  log "Phase 10: Running diagnostics..."
  echo ""
  bash "$FLEET_DIR/scripts/ad-fleet-doctor.sh"
  save_state 10
fi

# ─── Phase 11: Install fleet Hermes (port 8001) ──────────────────────────────
if [ "$PHASE" -lt 11 ]; then
  log "Phase 11: Installing fleet Hermes gateway (port 8001)..."
  if [ -f "$SCRIPT_DIR/scripts/ad-fleet-install-hermes.sh" ]; then
    bash "$SCRIPT_DIR/scripts/ad-fleet-install-hermes.sh" || warn "Fleet Hermes install had issues — gateway will retry on next boot"
  else
    warn "Fleet Hermes install script not found — skipping (can install later)"
  fi
  save_state 11
fi

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║          ✅ FLEET SETUP COMPLETE                     ║"
echo "╠══════════════════════════════════════════════════════╣"
MACHINE_NAME=$(grep "hostname:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
printf  "║  Machine:  %-40s║\n" "$MACHINE_NAME"
printf  "║  UUID:     %-40s║\n" "$(cat $FLEET_DIR/machine_id)"
printf  "║  Role:     %-40s║\n" "Member"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  ⏳ Waiting for admin approval to fully join fleet   ║"
echo "║  Heartbeat: Every 5 min (automatic)                 ║"
echo "║  Polling:   Every 5 min (automatic)                 ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
