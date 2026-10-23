#!/bin/bash
# ad-fleet-specs.sh — Collect machine specs as pipe-delimited fields
# Part of: AcceleratingDigital Fleet (ad-fleet) — v5
# Output (single line): hostname|ram_gb|disk_total|disk_free|cpu|os|arch|hermes_ver|user|member_type
# Never exits non-zero.

FLEET_DIR="$HOME/.ad-fleet"
HOSTNAME=$(grep "hostname:" "$FLEET_DIR/config.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"')
[ -z "$HOSTNAME" ] && HOSTNAME=$(hostname -s | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
USER_NAME=$(grep "^  user:" "$FLEET_DIR/config.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"')
MEMBER_TYPE=$(grep "classification:" "$FLEET_DIR/config.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"')
MACHINE_UUID=$(cat "$FLEET_DIR/machine_id" 2>/dev/null || echo "")

# Strip pipes so fields can't break the delimiter
clean() { echo "$1" | tr -d '|' | head -c 250; }

if [ "$(uname)" = "Darwin" ]; then
  RAM_GB=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1073741824}')
  DISK_TOTAL=$(df -g / 2>/dev/null | tail -1 | awk '{print $2}')
  DISK_FREE=$(df -g / 2>/dev/null | tail -1 | awk '{print $4}')
  OS_VER="macOS $(sw_vers -productVersion 2>/dev/null)"
  ARCH=$(uname -m)
  CPU=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
else
  RAM_GB=$(free -g 2>/dev/null | awk '/Mem/{print $2}')
  DISK_TOTAL=$(df -BG / 2>/dev/null | tail -1 | awk '{print $2}' | tr -d 'G')
  DISK_FREE=$(df -BG / 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
  OS_VER=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)
  ARCH=$(uname -m)
  CPU=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d':' -f2 | sed 's/^ //')
fi

MAIN_BIN=$(command -v hermes 2>/dev/null || echo "$HOME/.hermes/hermes-agent/venv/bin/hermes")
HERMES_VER="not installed"
[ -x "$MAIN_BIN" ] && HERMES_VER=$("$MAIN_BIN" --version 2>/dev/null | head -1)

[ -z "$RAM_GB" ] && RAM_GB=0
[ -z "$DISK_TOTAL" ] && DISK_TOTAL=0
[ -z "$DISK_FREE" ] && DISK_FREE=0
[ -z "$CPU" ] && CPU="unknown"
[ -z "$OS_VER" ] && OS_VER="unknown"
[ -z "$USER_NAME" ] && USER_NAME="unknown"
[ -z "$MEMBER_TYPE" ] && MEMBER_TYPE="unknown"

echo "$(clean "$HOSTNAME")|$RAM_GB|$(clean "$DISK_TOTAL")|$(clean "$DISK_FREE")|$(clean "$CPU")|$(clean "$OS_VER")|$(clean "$ARCH")|$(clean "$HERMES_VER")|$(clean "$USER_NAME")|$(clean "$MEMBER_TYPE")"
