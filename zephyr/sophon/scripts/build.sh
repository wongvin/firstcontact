#!/usr/bin/env bash
#
# Build the Sophon firmware.
#
# west walks UP from $PWD looking for a .west/ marker, so it cannot resolve a
# workspace from inside this repo. Exporting ZEPHYR_BASE is what makes a
# freestanding app buildable from here -- that is the documented cost of this
# app layout, not a workaround. See zephyr/CLAUDE.md.
#
# Usage: scripts/build.sh [extra west build args...]

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="${SOPHON_ZEPHYR_WORKSPACE:-$HOME/zephyrproject}"
BOARD="${SOPHON_BOARD:-xiao_ble/nrf52840/sense}"

if [[ ! -d "$WORKSPACE/.west" ]]; then
  echo "error: no Zephyr workspace at $WORKSPACE (looked for .west/)" >&2
  echo "       set SOPHON_ZEPHYR_WORKSPACE if yours lives elsewhere" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$WORKSPACE/.venv/bin/activate"
export ZEPHYR_BASE="$WORKSPACE/zephyr"

# -p always: a stale CMake cache is the cause of a large share of confusing
# Zephyr errors, and this app is small enough that pristine builds are cheap.
exec west build -p always -b "$BOARD" -d "$APP_DIR/build" "$APP_DIR" "$@"
