#!/usr/bin/env bash
#
# Flash the Sophon firmware over the XIAO's UF2 bootloader.
#
# Put the board in bootloader mode first: double-tap the reset button. A volume
# mounts under /Volumes/.
#
# The uf2 runner matches on a board-id string. If the Sense Plus reports one the
# runner does not know, it fails to find the volume -- this script then falls
# back to a plain copy, which is all the runner does anyway.
#
# Usage: scripts/flash.sh

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="${SOPHON_ZEPHYR_WORKSPACE:-$HOME/zephyrproject}"
UF2="$APP_DIR/build/zephyr/zephyr.uf2"

if [[ ! -f "$UF2" ]]; then
  echo "error: $UF2 not found -- run scripts/build.sh first" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$WORKSPACE/.venv/bin/activate"
export ZEPHYR_BASE="$WORKSPACE/zephyr"

if west flash -d "$APP_DIR/build" -r uf2; then
  exit 0
fi

echo
echo "uf2 runner failed -- falling back to a manual copy." >&2
echo "If this is the board-id mismatch, record the real id in README.md." >&2
echo >&2

# Any mounted volume with INFO_UF2.TXT is a UF2 bootloader.
# Kept as a newline-separated string rather than an array: macOS ships bash 3.2,
# which has no mapfile and expands empty arrays badly under `set -u`.
volumes="$(find /Volumes -maxdepth 2 -name 'INFO_UF2.TXT' -exec dirname {} \; 2>/dev/null || true)"
count="$(printf '%s' "$volumes" | grep -c . || true)"

if [[ "$count" -eq 0 ]]; then
  echo "error: no UF2 volume mounted. Double-tap reset and retry." >&2
  exit 1
fi

if [[ "$count" -gt 1 ]]; then
  echo "error: multiple UF2 volumes mounted; copy by hand:" >&2
  printf '  %s\n' "$volumes" >&2
  exit 1
fi

echo "found bootloader volume: $volumes"
echo "board-id reported:"
grep -i 'board-id' "$volumes/INFO_UF2.TXT" || true

# -X: do not copy extended attributes. The bootloader reboots the board the
# instant it has a complete UF2, so the volume disappears mid-copy and macOS
# reports "could not copy extended attributes ... Device not configured" -- a
# failure for a write that actually succeeded. Without -X that aborts the script
# under `set -e` and looks like the flash failed.
cp -X "$UF2" "$volumes/" || true

# The volume vanishing IS the success signal.
sleep 2
if [ -d "$volumes" ]; then
  echo "warning: $volumes is still mounted -- the board may not have accepted the image." >&2
  exit 1
fi
echo "copied; bootloader ejected the volume and rebooted into the application."
