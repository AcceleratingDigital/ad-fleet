#!/bin/bash
# ad-fleet-repair.sh — Repair / reinstall a broken member install
# Part of: AcceleratingDigital Fleet (ad-fleet) — v5
#
# Use when a machine is registered but never heartbeats, or daemons are dead.
# Safe to run any time: idempotent, keeps config, fixes the common failure
# modes (psql PATH, LaunchAgents not loaded, stale state), and reports its
# findings directly to fleet admins via the fleet DB.
#
# Run:  bash ~/.ad-fleet/scripts/ad-fleet-repair.sh
#   or from the installer package:  bash member/scripts/ad-fleet-repair.sh

FLEET_DIR="$HOME/.ad-fleet"
CONFIG="$FLEET_DIR/config.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$FLEET_DIR/logs/repair.log"

log()  { local m="[$(date '+%H:%M:%S')] $*"; echo "$m"; echo "$m" >> "$LOG" 2>/dev/null; }
ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; }
fail() { echo "  ❌ $*"; }

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║      AD-Fleet Repair — diagnose & fix member node    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
log "Repair started"

ISSUES=()

# ─── Step 1: config present? ─────────────────────────────────────────────────
if [ ! -f "$CONFIG" ]; then
  fail "No config at $CONFIG — this machine was never installed (or FLEET_DIR moved)."
  fail "Run the full installer: bash ad-fleet-join-member.sh  (not this repair script)"
  exit 1
fi
ok "Config found"

DB_HOST=$(grep "db_host:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_PORT=$(grep "db_port:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_USER=$(grep "db_user:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_PASS=$(grep "db_pass:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_NAME=$(grep "db_name:" "$CONFIG" | awk '{print $2}' | tr -d '"')
HOSTNAME=$(grep "hostname:" "$CONFIG" | awk '{print $2}' | tr -d '"')
export PGPASSWORD="$DB_PASS"

# ─── Step 2: psql — the #1 silent killer ─────────────────────────────────────
PSQL=""
for p in /opt/homebrew/bin/psql /usr/local/bin/psql /opt/homebrew/opt/libpq/bin/psql $(command -v psql 2>/dev/null); do
  [ -x "$p" ] && PSQL="$p" && break
done

mkdir -p "$FLEET_DIR/bin"
if [ -n "$PSQL" ]; then
  # Pin it so daemons never depend on PATH again
  if [ ! -e "$FLEET_DIR/bin/psql" ] || [ "$(readlink "$FLEET_DIR/bin/psql" 2>/dev/null)" != "$PSQL" ]; then
    ln -sf "$PSQL" "$FLEET_DIR/bin/psql"
    ok "psql pinned: $FLEET_DIR/bin/psql -> $PSQL"
  else
    ok "psql pinned already: $PSQL"
  fi
else
  # Try installing via brew
  if command -v brew >/dev/null 2>&1; then
    warn "psql not found — installing libpq..."
    brew install libpq >/dev/null 2>&1
    BREW_PSQL="$(brew --prefix libpq 2>/dev/null)/bin/psql"
    if [ -x "$BREW_PSQL" ]; then
      ln -sf "$BREW_PSQL" "$FLEET_DIR/bin/psql"
      PSQL="$FLEET_DIR/bin/psql"
      ok "psql installed via libpq and pinned: $PSQL"
    else
      ISSUES+=("psql missing: brew install libpq ran but no binary found")
    fi
  else
    ISSUES+=("psql missing and Homebrew not installed — run the full installer")
  fi
fi

# ─── Step 3: DB connectivity ─────────────────────────────────────────────────
DB_OK=false
if [ -n "$PSQL" ]; then
  if "$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c "SELECT 1;" >/dev/null 2>&1; then
    ok "DB reachable: $DB_HOST:$DB_PORT"
    DB_OK=true
  else
    DB_ERR=$("$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" 2>&1 | head -3)
    ISSUES+=("DB unreachable: $(echo "$DB_ERR" | tr '\n' ' ' | head -c 250)")
    warn "DB connect failed:"
    echo "$DB_ERR" | sed 's/^/      /'
  fi
else
  ISSUES+=("DB uncheckable: no psql")
fi

# ─── Step 4: scripts current + executable ────────────────────────────────────
# IMPORTANT: the package (bootstrap clone) is the source of truth — it's the
# freshest code. A stale repo clone on disk must NEVER overwrite it.
if [ -f "$SCRIPT_DIR/ad-fleet-heartbeat.sh" ] && [ -f "$SCRIPT_DIR/ad-fleet-poller.sh" ]; then
  cp "$SCRIPT_DIR"/*.sh "$FLEET_DIR/scripts/" && chmod +x "$FLEET_DIR/scripts/"*.sh || {
    ISSUES+=("script copy from package FAILED — installed daemons may be stale")
    warn "Could not refresh scripts from package"
  }
  # Verify the installed heartbeat actually has the v5 psql resolution
  if grep -q 'ad-fleet/bin/psql' "$FLEET_DIR/scripts/ad-fleet-heartbeat.sh" 2>/dev/null; then
    ok "Scripts refreshed from package (v5 verified)"
  else
    ISSUES+=("installed heartbeat script is STALE (no v5 psql resolution) — copy failed silently")
    warn "Installed heartbeat is OLD — daemons will keep failing"
  fi
elif [ -d "$FLEET_DIR/repo/member/scripts" ]; then
  # No package scripts beside us — fall back to repo clone, but pull first
  (cd "$FLEET_DIR/repo" && git pull --ff-only >/dev/null 2>&1)
  cp "$FLEET_DIR/repo/member/scripts/"*.sh "$FLEET_DIR/scripts/" 2>/dev/null && chmod +x "$FLEET_DIR/scripts/"*.sh
  ok "Scripts refreshed from repo clone"
fi

# ─── Step 5: LaunchAgents — reinstall + load ─────────────────────────────────
LA_DIR="$HOME/Library/LaunchAgents"
PLIST_SRC_DIR="$SCRIPT_DIR/../LaunchAgents"
[ -d "$PLIST_SRC_DIR" ] || PLIST_SRC_DIR="$FLEET_DIR/repo/member/LaunchAgents"
mkdir -p "$LA_DIR"

for LABEL in com.ad-fleet.heartbeat com.ad-fleet.poller; do
  PLIST_NAME="$LABEL.plist"
  DEST="$LA_DIR/$PLIST_NAME"
  SRC_PLIST=""
  [ -f "$PLIST_SRC_DIR/$PLIST_NAME" ] && SRC_PLIST="$PLIST_SRC_DIR/$PLIST_NAME"
  # Repo fallback
  [ -z "$SRC_PLIST" ] && [ -f "$FLEET_DIR/repo/member/LaunchAgents/$PLIST_NAME" ] && SRC_PLIST="$FLEET_DIR/repo/member/LaunchAgents/$PLIST_NAME"

  if [ -n "$SRC_PLIST" ]; then
    launchctl unload "$DEST" 2>/dev/null || true
    sed "s|HOME_PLACEHOLDER|$HOME|g" "$SRC_PLIST" > "$DEST"
    if launchctl load "$DEST" 2>/dev/null; then
      ok "Loaded: $LABEL"
    else
      ISSUES+=("launchctl load failed: $LABEL (may need logout/login)")
      warn "Could not load $LABEL — try: launchctl load $DEST"
    fi
  else
    ISSUES+=("plist source missing for $LABEL")
  fi
done

# Give heartbeat a moment, then fire one manually as a smoke test
sleep 2
if [ -x "$FLEET_DIR/scripts/ad-fleet-heartbeat.sh" ]; then
  HB_OUT=$(bash "$FLEET_DIR/scripts/ad-fleet-heartbeat.sh" 2>&1)
  if echo "$HB_OUT" | grep -q "FAILED"; then
    ISSUES+=("manual heartbeat run FAILED: $(echo "$HB_OUT" | head -2 | tr '\n' ' ' | head -c 300)")
    warn "Heartbeat fired but FAILED: $HB_OUT"
  else
    ok "Heartbeat fired"
  fi
fi

# ─── Step 6: verify heartbeat actually landed in the DB ──────────────────────
if [ "$DB_OK" = true ]; then
  SEEN=$("$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT ROUND(EXTRACT(EPOCH FROM (NOW() - last_seen))/60) FROM fleet_status WHERE hostname='$HOSTNAME';" 2>/dev/null | head -1)
  if [ -n "$SEEN" ] && [ "$SEEN" -lt 5 ] 2>/dev/null; then
    ok "Heartbeat VERIFIED in fleet DB (${SEEN}m ago)"
  else
    HB_LOG_ERR=$(tail -3 "$FLEET_DIR/logs/heartbeat-error.log" 2>/dev/null | tr '\n' ' ' | head -c 250)
    ISSUES+=("heartbeat not landing in fleet_status (last_seen: ${SEEN:-never}); daemon stderr: ${HB_LOG_ERR:-none}")
    warn "Heartbeat did NOT land in DB — check $FLEET_DIR/logs/heartbeat-error.log"
  fi
fi

# ─── Step 7: daemon issue reports pending? Show them ─────────────────────────
echo ""
echo "--- Doctor summary ---"
[ -x "$FLEET_DIR/scripts/ad-fleet-doctor.sh" ] && bash "$FLEET_DIR/scripts/ad-fleet-doctor.sh" 2>&1 | tail -30

# ─── Step 8: report issues to fleet admins ───────────────────────────────────
if [ ${#ISSUES[@]} -gt 0 ] && [ "$DB_OK" = true ]; then
  ISSUE_JSON=$(printf '%s; ' "${ISSUES[@]}" | sed "s/'/''/g" | head -c 800)
  "$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c \
    "INSERT INTO hermes_bus (from_host, to_host, kind, body, task_title, task_expires_at)
     VALUES ('$HOSTNAME', 'fleet-admin', 'msg',
     '{\"task\":\"daemon_issue\",\"source\":\"repair\",\"message\":\"$ISSUE_JSON\"}',
     'REPAIR REPORT: $HOSTNAME — ${#ISSUES[@]} issue(s) found', NOW() + INTERVAL '48 hours');" >/dev/null 2>&1 \
    && ok "Issues reported to fleet admins" \
    || warn "Could not report issues (DB write failed)"
  echo ""
  warn "Issues found:"
  for i in "${ISSUES[@]}"; do echo "      • $i"; done
elif [ ${#ISSUES[@]} -eq 0 ]; then
  echo ""
  ok "All checks passed — machine is healthy and reporting."
  if [ "$DB_OK" = true ]; then
    "$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c \
      "INSERT INTO hermes_bus (from_host, to_host, kind, body, task_title, task_expires_at)
       VALUES ('$HOSTNAME', 'fleet-admin', 'msg',
       '{\"task\":\"daemon_issue\",\"source\":\"repair\",\"message\":\"repair OK — all checks passed, heartbeat verified\"}',
       'REPAIR REPORT: $HOSTNAME — healthy', NOW() + INTERVAL '48 hours');" >/dev/null 2>&1 || true
  fi
else
  warn "Issues found but DB unreachable — could not report to fleet:"
  for i in "${ISSUES[@]}"; do echo "      • $i"; done
fi

log "Repair finished (${#ISSUES[@]} issue(s))"
echo ""
echo "Done. If issues remain, send the output above to a fleet admin."
