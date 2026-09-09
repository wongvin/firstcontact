#!/usr/bin/env bash
#
# Build the Sophon firmware, for either boot path.
#
#   scripts/build.sh                        # UF2 (default during the transition)
#   SOPHON_BOOT=mcuboot scripts/build.sh    # MCUboot via sysbuild
#
# THE TRANSITION. The two boards have diverged: Sophon-86F0 runs MCUboot and is
# flashed over SWD, Sophon-4D88 still runs the Adafruit UF2 bootloader. UF2
# remains the default so existing habits and the un-migrated board keep working,
# and MCUboot is opt-in.
#
# Flip the default when every board has migrated -- that is the condition, not a
# date. Nothing else here needs to change when it happens.
#
# An environment variable rather than a flag because this script forwards "$@"
# to west, where a positional flag of ours would collide with west's own. It
# also matches the existing SOPHON_BOARD / SOPHON_ZEPHYR_WORKSPACE idiom.
#
# Usage: [SOPHON_BOOT=uf2|mcuboot] scripts/build.sh [extra west build args...]

set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
sophon_common_init
sophon_activate_west

MODE="$(sophon_boot_mode)"
BUILD_DIR="$(sophon_build_dir)"

# Separate build directories per mode, so both artefacts can exist at once and
# neither reuses the other's CMake cache. It also lets flash.sh and
# flash-swd.sh each look only at their own output rather than guessing.
#
# -p always: a stale CMake cache causes a large share of confusing Zephyr
# errors, and this app is small enough that pristine builds are cheap.

if [[ "$MODE" == "uf2" ]]; then
  exec west build -p always -b "$BOARD" -d "$BUILD_DIR" "$APP_DIR" "$@"
fi

# --- MCUboot -----------------------------------------------------------------
#
# Two overlays, and they are NOT interchangeable. The partition table is shared
# by both images; the code-partition choice is not -- MCUboot's own app.overlay
# points itself at boot_partition, while the application must be pointed at
# slot0. Applying app-slot0.overlay to the MCUboot image would build a
# bootloader that expects to run from slot 0. See swd/app-slot0.overlay.
PARTITIONS="$APP_DIR/swd/mcuboot-partitions.overlay"
APP_SLOT0="$APP_DIR/swd/app-slot0.overlay"
# MCUboot only: its console goes to uart0, since it has no USB stack for
# the board's default CDC ACM console.
BOOT_CONSOLE="$APP_DIR/swd/mcuboot-console.overlay"

for f in "$PARTITIONS" "$APP_SLOT0" "$BOOT_CONSOLE"; do
  [[ -f "$f" ]] || { echo "error: missing overlay $f" >&2; exit 1; }
done

exec west build -p always -b "$BOARD" --sysbuild -d "$BUILD_DIR" "$APP_DIR" "$@" \
  -- -DSB_CONFIG_BOOTLOADER_MCUBOOT=y \
     -DEXTRA_DTC_OVERLAY_FILE="$PARTITIONS;$APP_SLOT0" \
     -Dmcuboot_EXTRA_DTC_OVERLAY_FILE="$PARTITIONS;$BOOT_CONSOLE"
