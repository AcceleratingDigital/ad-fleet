#!/bin/bash
# ad-fleet-join-admin.sh — Admin One-Click Installer
# AcceleratingDigital Fleet v4 — ADMIN PACKAGE
# State-machine: re-running resumes from last completed phase
#
# This installer is for ADMIN machines only.
# Member setup uses a separate package.
# Admin machines connect directly to internal DB via Tailscale.

set -euo pipefail

FLEET_DIR="${FLEET_DIR:-$HOME/.ad-fleet}"
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
echo "║     AcceleratingDigital Fleet — Admin Setup          ║"
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

# Clean stale hermesbus memory from user's Hermes MEMORY.md
if [ -f "$HOME/.hermes/memories/MEMORY.md" ]; then
  log "Cleaning stale hermesbus memory from user Hermes..."
  python3 << 'PYCLEAN' 2>/dev/null || true
import os
mem_path = os.path.expanduser("~/.hermes/memories/MEMORY.md")
with open(mem_path, 'r') as f:
    content = f.read()
sep = "\n\xa7\n" if "\xa7" in content else "\n\xc2\xa7\n" if "\xc2\xa7" in content else "\n\x00\xa7\n"
sections = content.split(sep) if sep in content else [content]
stale_kw = ['hermesbus','hermes-bus','hermes.bus','fleet-heartbeat.sh','com.hermesbus',
            'hermesbus.sh','hermesbus-poll','FLEET_DB_USER=fleet_member',
            'Cred tiers (2026-08-17)','Heartbeat: MEMBERS use fleet-heartbeat',
            'File transfer (2026-08-17)','hermes-bus+rsync',
            'Fleet discovery: Check skills_list FIRST',
            'Fleet roles: laptop-m1=primary']
clean = [s for s in sections if not any(k.lower() in s.lower() for k in stale_kw)]
content = sep.join(clean)
with open(mem_path, 'w') as f:
    f.write(content)
PYCLEAN
  ok "Memory cleaned"
fi

# Install ad-fleet-manager skill to user's Hermes
if [ -d "$HOME/.hermes/skills" ] && [ -f "$SCRIPT_DIR/scripts/ad-fleet-manager-skill.md" ]; then
  log "Installing ad-fleet-manager skill to user Hermes..."
  mkdir -p "$HOME/.hermes/skills/ad-fleet-manager"
  cp "$SCRIPT_DIR/scripts/ad-fleet-manager-skill.md" "$HOME/.hermes/skills/ad-fleet-manager/SKILL.md"
  ok "ad-fleet-manager skill installed"
elif [ -d "$HOME/.hermes/skills" ]; then
  log "Installing ad-fleet-manager skill from repo..."
  if [ ! -d "$FLEET_DIR/repo" ]; then
    git clone --depth 1 https://github.com/AcceleratingDigital/ad-fleet.git "$FLEET_DIR/repo" 2>/dev/null || true
  fi
  if [ -d "$FLEET_DIR/repo/skills/ad-fleet-manager" ]; then
    mkdir -p "$HOME/.hermes/skills/ad-fleet-manager"
    cp "$FLEET_DIR/repo/skills/ad-fleet-manager/SKILL.md" "$HOME/.hermes/skills/ad-fleet-manager/SKILL.md"
    ok "ad-fleet-manager skill installed from repo"
  fi
fi

# Install watchdog scripts and crons
log "Installing watchdog scripts..."
mkdir -p "$FLEET_DIR/scripts" "$HOME/.ad-fleet/hermes/scripts" "$HOME/.hermes/scripts"
for ws in ad-fleet-watch-main-hermes.sh ad-fleet-watch-fleet-hermes.sh; do
  if [ -f "$SCRIPT_DIR/scripts/$ws" ]; then
    cp "$SCRIPT_DIR/scripts/$ws" "$FLEET_DIR/scripts/"
    cp "$SCRIPT_DIR/scripts/$ws" "$HOME/.ad-fleet/hermes/scripts/" 2>/dev/null || true
    cp "$SCRIPT_DIR/scripts/$ws" "$HOME/.hermes/scripts/" 2>/dev/null || true
    chmod +x "$FLEET_DIR/scripts/$ws" "$HOME/.ad-fleet/hermes/scripts/$ws" "$HOME/.hermes/scripts/$ws" 2>/dev/null || true
  fi
done
ok "Watchdog scripts installed"

# --- Remediate damage from old (buggy) watchdog ---
# The pre-v4.1 watchdog probed :8000, judged healthy gateways dead, restart-bombed
# them every 10m, and could stomp ~/.hermes/config.yaml with a stale backup.
log "Checking for old-watchdog damage..."
# 1. Clear stale cooldown markers so the fixed watchdog starts clean
rm -f "$FLEET_DIR/logs/.watchdog-main-cooldown" 2>/dev/null || true
# 2. Verify all three watchdog copies are byte-identical (executed copy = bundled copy)
WMAIN_REF=$(md5 -q "$SCRIPT_DIR/scripts/ad-fleet-watch-main-hermes.sh" 2>/dev/null || md5sum "$SCRIPT_DIR/scripts/ad-fleet-watch-main-hermes.sh" 2>/dev/null | awk '{print $1}')
for copy in "$FLEET_DIR/scripts" "$FLEET_DIR/hermes/scripts" "$HOME/.hermes/scripts"; do
  f="$copy/ad-fleet-watch-main-hermes.sh"
  if [ -f "$f" ]; then
    WMAIN_CUR=$(md5 -q "$f" 2>/dev/null || md5sum "$f" 2>/dev/null | awk '{print $1}')
    if [ "$WMAIN_CUR" != "$WMAIN_REF" ]; then
      cp "$SCRIPT_DIR/scripts/ad-fleet-watch-main-hermes.sh" "$f" && chmod +x "$f"
      ok "Re-synced stale watchdog copy: $f"
    fi
  fi
done
# 3. Warn if the old watchdog ever stomped the main config (evidence: bak-watchdog files)
STOMPED=$(ls "$HOME/.hermes/config.yaml.bak-watchdog-"* 2>/dev/null | wc -l | tr -d ' ')
if [ "$STOMPED" != "0" ]; then
  warn "Found $STOMPED config.yaml.bak-watchdog-* file(s) in ~/.hermes/"
  warn "The OLD watchdog overwrote ~/.hermes/config.yaml at least once."
  warn "Your current config may be stale — review: ls -la ~/.hermes/config.yaml*"
fi
# 4. If the main gateway LaunchAgent exists but the gateway isn't running
#    (old watchdog likely killed it), start it once
MAIN_GW_PLIST="$HOME/Library/LaunchAgents/ai.hermes.gateway.plist"
if [ -f "$MAIN_GW_PLIST" ]; then
  if ! pgrep -fl "hermes_cli.main gateway" 2>/dev/null | grep -v '\.ad-fleet' | grep -q "hermes_cli.main gateway"; then
    log "Main Hermes gateway is down (likely killed by old watchdog) — starting it..."
    launchctl load "$MAIN_GW_PLIST" 2>/dev/null || true
    sleep 10
    if pgrep -fl "hermes_cli.main gateway" 2>/dev/null | grep -v '\.ad-fleet' | grep -q "hermes_cli.main gateway"; then
      ok "Main Hermes gateway restarted"
    else
      warn "Main Hermes gateway did not start — check manually: launchctl load $MAIN_GW_PLIST"
    fi
  fi
fi
ok "Old-watchdog remediation complete"

# Install watchdog crons (if Hermes is available)
# Only install if INSTALL_WATCHDOGS is true (set by installer, not by fleet_update)
FLEET_HERMES_BIN="$FLEET_DIR/hermes/hermes-agent/venv/bin/hermes"
if [ -x "$FLEET_HERMES_BIN" ]; then
  EXISTING_A=$(HERMES_HOME="$FLEET_DIR/hermes" "$FLEET_HERMES_BIN" cron list 2>/dev/null | grep -c "Watch Main Hermes" || true)
  if [ "$EXISTING_A" = "0" ]; then
    mkdir -p "$FLEET_DIR/hermes/scripts"
    cp "$FLEET_DIR/scripts/ad-fleet-watch-main-hermes.sh" "$FLEET_DIR/hermes/scripts/" 2>/dev/null || true
    HERMES_HOME="$FLEET_DIR/hermes" "$FLEET_HERMES_BIN" cron create "every 10m" \
      --name "Watch Main Hermes" --script "ad-fleet-watch-main-hermes.sh" \
      --no-agent --deliver local 2>/dev/null && ok "Cron A installed (fleet watches main)" || true
  fi
fi
MAIN_HERMES_BIN=$(command -v hermes 2>/dev/null || echo "$HOME/.hermes/hermes-agent/venv/bin/hermes")
if [ -x "$MAIN_HERMES_BIN" ]; then
  EXISTING_B=$(HERMES_HOME="$HOME/.hermes" "$MAIN_HERMES_BIN" cron list 2>/dev/null | grep -c "Watch Fleet Hermes" || true)
  if [ "$EXISTING_B" = "0" ]; then
    mkdir -p "$HOME/.hermes/scripts"
    cp "$FLEET_DIR/scripts/ad-fleet-watch-fleet-hermes.sh" "$HOME/.hermes/scripts/" 2>/dev/null || true
    HERMES_HOME="$HOME/.hermes" "$MAIN_HERMES_BIN" cron create "every 10m" \
      --name "Watch Fleet Hermes" --script "ad-fleet-watch-fleet-hermes.sh" \
      --no-agent --deliver local 2>/dev/null && ok "Cron B installed (main watches fleet)" || true
  fi
fi

# Clone the git repo for future fleet_update pulls
if [ ! -d "$FLEET_DIR/repo" ]; then
  log "Cloning ad-fleet repo for future updates..."
  git clone --depth 1 https://github.com/AcceleratingDigital/ad-fleet.git "$FLEET_DIR/repo" 2>/dev/null && ok "Repo cloned" || warn "Repo clone failed (non-fatal)"
else
  cd "$FLEET_DIR/repo" && git pull --ff-only 2>/dev/null && ok "Repo updated" || true
fi

echo ""
for p in /opt/homebrew/bin/psql /usr/local/bin/psql $(command -v psql 2>/dev/null); do
  [ -x "$p" ] && PSQL_BIN="$p" && break
done
if [ -n "$PSQL_BIN" ]; then
  ok "psql found at $PSQL_BIN"
else
  warn "psql not found — installing via Homebrew..."
  if command -v brew &>/dev/null; then
    brew install libpq 2>&1 | tail -3
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

# ─── Phase 1: Verify network ─────────────────────────────────────────────────
if [ "$PHASE" -lt 1 ]; then
  log "Phase 1: Verifying internal network access..."
  mkdir -p "$FLEET_DIR"/{scripts,logs,drops,hermes/bin}
  chmod 700 "$FLEET_DIR"
  touch "$FLEET_DIR/logs/heartbeat.log" "$FLEET_DIR/logs/poller.log" "$FLEET_DIR/logs/install.log"

  # Admin machines MUST reach the internal DB directly
  if ping -c 1 -W 2 10.1.128.8 &>/dev/null; then
    ok "Internal network reachable (10.1.128.8)"
  else
    warn "Cannot reach 10.1.128.8 — ensure Tailscale/VPN is connected"
    warn "Admin setup requires internal network access. Connect VPN and re-run."
    exit 1
  fi
  save_state 1
fi

# ─── Phase 2: Check Ollama ────────────────────────────────────────────────────
if [ "$PHASE" -lt 2 ]; then
  log "Phase 2: Checking Ollama..."
  if command -v ollama &>/dev/null; then
    ok "Ollama already installed"
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
      log "Pulling qwen2.5:3b..."
      ollama pull qwen2.5:3b && ok "qwen2.5:3b ready" || warn "Model pull failed — retry manually"
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
  echo ""
  CLASS_INPUT_UPPER=$(echo "$CLASS_INPUT" | tr '[:lower:]' '[:upper:]')
  case "$CLASS_INPUT_UPPER" in
    A) CLASS="always-on" ;;
    T) CLASS="transient" ;;
    *) CLASS="always-on" ; warn "Defaulting to always-on" ;;
  esac
  echo "$USER_NAME|$CLASS|$MACHINE_NAME" > "$FLEET_DIR/.install_tmp"
  save_state 3
  ok "Machine info saved"
fi

# ─── Phase 4: Write admin config (internal DB) ────────────────────────────────
if [ "$PHASE" -lt 4 ]; then
  log "Phase 4: Writing fleet config..."
  IFS='|' read -r USER_NAME CLASS MACHINE_NAME < "$FLEET_DIR/.install_tmp"
  HOSTNAME="$MACHINE_NAME"
  MACHINE_UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
  echo "$MACHINE_UUID" > "$FLEET_DIR/machine_id"

  # Admin config — uses INTERNAL db endpoint (Tailscale required)
  cat > "$FLEET_DIR/config.yaml" << YAML
# AcceleratingDigital Fleet — Admin Config
# Generated: $(date)
# ADMIN: Uses internal DB endpoint. Requires Tailscale/VPN.

fleet:
  db_host: "10.1.128.8"
  db_port: 5432
  db_user: "hermes_fleet_admin"
  db_pass: "p7kR9mQ2xL8vN5jH3dY6wE4sB1tC7pZ0aF9jK5lM"
  db_name: "hermes_fleet"
  llm_url: "https://llm.acceleratingdigital.com"
  llm_api_key: "sk-piyush-3d76f8d548c411e2eec59fdb"

machine:
  hostname: "$HOSTNAME"
  uuid: "$MACHINE_UUID"
  role: "admin"
  classification: "$CLASS"
  team: "admin"
  user: "$USER_NAME"
  registered_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
YAML

  chmod 600 "$FLEET_DIR/config.yaml"
  rm -f "$FLEET_DIR/.install_tmp"
  save_state 4
  ok "Admin config written (UUID: $MACHINE_UUID)"
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
    launchctl unload "$DEST" 2>/dev/null || true
    sed "s|HOME_PLACEHOLDER|$HOME|g" "$PLIST" > "$DEST"
    launchctl load "$DEST" && ok "Loaded: $LABEL" || warn "Failed to load: $LABEL"
  done
  save_state 5
fi

# ─── Phase 6: Cleanup old fleet setup ────────────────────────────────────────
if [ "$PHASE" -lt 6 ]; then
  log "Phase 6: Cleaning up old fleet setup..."
  bash "$FLEET_DIR/scripts/ad-fleet-cleanup.sh" 2>/dev/null || warn "Cleanup had warnings (non-critical)"
  save_state 6
fi

# ─── Phase 7: Self-register (admins register directly, no approval needed) ───
if [ "$PHASE" -lt 7 ]; then
  log "Phase 7: Registering in fleet..."
  DB_HOST=$(grep "db_host:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  DB_PORT=$(grep "db_port:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  DB_USER=$(grep "db_user:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  DB_PASS=$(grep "db_pass:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  DB_NAME=$(grep "db_name:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  HOSTNAME=$(grep "hostname:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  MACHINE_UUID=$(cat "$FLEET_DIR/machine_id")
  CLASS=$(grep "classification:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
  USER_NAME=$(grep "^  user:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')

  export PGPASSWORD="$DB_PASS"
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c \
    "INSERT INTO fleet_directives (host, role, classification, team, registered_by, registered_at)
     VALUES ('$HOSTNAME', 'admin', '$CLASS', 'admin', '$USER_NAME', NOW())
     ON CONFLICT (host) DO UPDATE
     SET role='admin', classification='$CLASS', registered_by='$USER_NAME';" \
    && ok "Registered in fleet_directives" || warn "Registration failed — check DB connection"

  save_state 7
fi

# ─── Phase 8: First heartbeat ────────────────────────────────────────────────
if [ "$PHASE" -lt 8 ]; then
  log "Phase 8: Sending first heartbeat..."
  bash "$FLEET_DIR/scripts/ad-fleet-heartbeat.sh" && ok "First heartbeat sent" || \
    warn "Heartbeat failed — daemon will retry in 5 min"
  save_state 8
fi

# ─── Phase 9: Run doctor ─────────────────────────────────────────────────────
if [ "$PHASE" -lt 9 ]; then
  log "Phase 9: Running diagnostics..."
  echo ""
  bash "$FLEET_DIR/scripts/ad-fleet-doctor.sh"
  save_state 9
fi

# ─── Phase 10: Install fleet Hermes (port 8001) ──────────────────────────────
if [ "$PHASE" -lt 10 ]; then
  log "Phase 10: Installing fleet Hermes gateway (port 8001)..."
  if [ -f "$SCRIPT_DIR/scripts/ad-fleet-install-hermes.sh" ]; then
    bash "$SCRIPT_DIR/scripts/ad-fleet-install-hermes.sh" || warn "Fleet Hermes install had issues — gateway will retry on next boot"
  else
    warn "Fleet Hermes install script not found — skipping (can install later)"
  fi
  save_state 10
fi

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║          ✅ ADMIN SETUP COMPLETE                     ║"
echo "╠══════════════════════════════════════════════════════╣"
MACHINE_NAME=$(grep "hostname:" "$FLEET_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
printf  "║  Machine:  %-40s║\n" "$MACHINE_NAME"
printf  "║  UUID:     %-40s║\n" "$(cat $FLEET_DIR/machine_id)"
printf  "║  Role:     %-40s║\n" "Admin (Internal DB Access)"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  ✅ Registered directly (no approval needed)         ║"
echo "║  Heartbeat: Every 5 min (automatic)                 ║"
echo "║  Polling:   Every 5 min (automatic)                 ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
