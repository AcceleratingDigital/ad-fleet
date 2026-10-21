#!/bin/bash
# ad-fleet bootstrap — one-line entry point for fleet members
#
#   curl -fsSL https://raw.githubusercontent.com/AcceleratingDigital/ad-fleet/main/member/bootstrap.sh | bash
#
# Downloads the fleet package, then hands off to the universal installer
# (which auto-detects: fresh install / resume / update+repair).
set -euo pipefail

REPO_URL="https://github.com/AcceleratingDigital/ad-fleet.git"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo ""
echo "  Downloading AcceleratingDigital Fleet package..."
git clone --depth 1 "$REPO_URL" "$TMP/ad-fleet" >/dev/null 2>&1 \
  || { echo "  ❌ Download failed — check your internet connection"; exit 1; }

echo "  Package received. Starting installer..."
echo ""
exec bash "$TMP/ad-fleet/member/ad-fleet-join-member.sh"
