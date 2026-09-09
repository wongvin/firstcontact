#!/usr/bin/env bash
#
# Flash the Sophon MCUboot build over SWD, using a CMSIS-DAP probe.
#
#   SOPHON_BOOT=mcuboot scripts/build.sh
#   scripts/flash-swd.sh
#
# For the UF2 boot path use scripts/flash.sh instead -- and note this script
# REFUSES to run against a board that still has the UF2 bootloader, because
# overwriting it destroys both that bootloader and the S140 SoftDevice, and
# neither is recoverable without a prior full-flash backup. Pass --force only
# with a backup in hand.
#
# Needs no venv and no ZEPHYR_BASE: OpenOCD is driven directly.
#
# Usage: scripts/flash-swd.sh [--force]

set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
sophon_common_init

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

SDK="${ZEPHYR_SDK_INSTALL_DIR:-$HOME/zephyr-sdk-1.0.1}"
OPENOCD="${SOPHON_OPENOCD:-$SDK/hosttools/opt/openocd/bin/openocd}"
SCRIPTS="${SOPHON_OPENOCD_SCRIPTS:-$SDK/hosttools/opt/openocd/share/openocd/scripts}"
BUILD_DIR="$APP_DIR/build-mcuboot"
BOOT_HEX="$BUILD_DIR/mcuboot/zephyr/zephyr.hex"
APP_HEX="$BUILD_DIR/sophon/zephyr/zephyr.signed.hex"

[[ -x "$OPENOCD" ]] || { echo "error: openocd not found at $OPENOCD" >&2
                         echo "       set SOPHON_OPENOCD to override" >&2; exit 1; }

for f in "$BOOT_HEX" "$APP_HEX"; do
  [[ -f "$f" ]] || { echo "error: $f not found" >&2
                     echo "       run: SOPHON_BOOT=mcuboot scripts/build.sh" >&2; exit 1; }
done

oocd() {
  "$OPENOCD" -s "$SCRIPTS" \
    -f interface/cmsis-dap.cfg -c "transport select swd" \
    -c "adapter speed ${SOPHON_SWD_KHZ:-4000}" \
    -f target/nrf52.cfg -c "$1" 2>&1
}

# --- refuse to clobber a UF2 board -------------------------------------------
#
# A Nordic SoftDevice announces itself with magic 0x51B1E5DB in its info struct
# at 0x3004. Its presence means this board still runs the stock UF2 arrangement:
# MBR at 0x0, S140 above it, Adafruit bootloader at 0xF4000. Writing MCUboot
# over that is a one-way door without a backup, so it is not something to do by
# running the wrong script.
echo "==> probing target"
PROBE="$(oocd 'init; echo "MAGIC [nrf52.cpu read_memory 0x3004 32 1]"; exit')" || true
if ! grep -q "Cortex-M4" <<<"$PROBE"; then
  echo "error: no target responding over SWD." >&2
  echo "       check the probe and the SWDIO/SWCLK/GND wiring (TP5/TP3/TP1)." >&2
  echo "$PROBE" | sed 's/^/       /' >&2
  exit 1
fi
# macOS ships bash 3.2, so no ${var,,} -- lowercase with tr.
MAGIC="$(sed -n 's/^MAGIC \(.*\)$/\1/p' <<<"$PROBE" | tr -d ' \r' | tr 'A-Z' 'a-z')"
echo "    SoftDevice magic @0x3004: ${MAGIC:-<unreadable>}  (0x51b1e5db = UF2 board)"
if [[ "$MAGIC" == "1370606555" || "$MAGIC" == "0x51b1e5db" ]]; then
  if [[ "$FORCE" -eq 0 ]]; then
    echo "error: this board still has a Nordic SoftDevice at 0x3000, so it is on" >&2
    echo "       the UF2 boot path. Flashing MCUboot would destroy the SoftDevice" >&2
    echo "       AND the Adafruit bootloader, with no way back without a full" >&2
    echo "       flash + UICR backup." >&2
    echo "       Use scripts/flash.sh, or re-run with --force if that is intended." >&2
    exit 1
  fi
  echo "    warning: SoftDevice present and --force given; proceeding" >&2
fi

# --- erase, then write -------------------------------------------------------
#
# Two OpenOCD invocations, deliberately. Erasing leaves the core executing blank
# flash, which locks up on a double fault; OpenOCD writes flash by running a
# helper routine in target RAM, and a locked-up core cannot run it. Doing both
# in one session fails with "timeout waiting for algorithm". `reset halt` between
# the two is what makes the write succeed.
#
# Storage at 0xFC000 is left alone so settings survive a reflash.
echo "==> erasing 0x000000-0x0FC000"
oocd 'init; halt; flash erase_address 0x00000000 0x000FC000; exit' | grep -iE "error" && exit 1

echo "==> writing mcuboot + signed application"
# ALWAYS end in `reset run`, never a bare `resume`. Resuming after a long halt
# leaves the BLE stack believing a connection that the peer abandoned long ago
# is still live: the board stops advertising, refuses new centrals, and only a
# reset recovers it. That cost an afternoon to diagnose.
OUT="$(oocd "init; reset halt; flash write_image $BOOT_HEX; flash write_image $APP_HEX; reset run; exit")"
if grep -iqE "^Error|failed to write" <<<"$OUT"; then
  echo "$OUT" | sed 's/^/    /' >&2
  echo "error: flash write failed" >&2
  exit 1
fi

echo "==> done -- board reset and running"
echo "    console: /dev/cu.usbmodem* at 115200 (use cu.*, not tty.*)"
