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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
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

# --- refuse a stale build (#277) ---------------------------------------------
#
# flash.sh has had this since #253; this script had only an existence check, so
# it would cheerfully write an image built before the edit you are testing. That
# matters more here than on the UF2 path, because this script is what #274 uses
# to change the signing key -- and a stale pair is exactly how a bootloader and
# an application that do not trust each other reach a board by accident.
#
# Both artefacts are checked against every input that can affect EITHER image:
# sysbuild/ configures MCUboot, swd/ carries the partition table both images are
# built against, and the rest is the application.
#
# Deliberately NOT a "same build" check. Two hex files being written by one
# sysbuild run is not something their mtimes can prove -- a long build separates
# them by minutes -- so any threshold would be a guess. Checking both against all
# inputs is the part that is well defined, and it catches the case that matters:
# an input changed and one of them did not keep up.
SOURCES=("$APP_DIR/src" "$APP_DIR/prj.conf" "$APP_DIR/CMakeLists.txt"
         "$APP_DIR/app.overlay" "$APP_DIR/VERSION" "$APP_DIR/sysbuild"
         "$APP_DIR/swd" "$APP_DIR/dts")
for f in "$BOOT_HEX" "$APP_HEX"; do
  NEWER="$(find "${SOURCES[@]}" -newer "$f" -print -quit 2>/dev/null || true)"
  if [[ -n "$NEWER" ]]; then
    echo "error: $f is older than $NEWER" >&2
    echo "       run: SOPHON_BOOT=mcuboot scripts/build.sh" >&2
    exit 1
  fi
done

DUMP="$(mktemp)"
OOCD_LOG="$(mktemp)"
trap 'rm -f "$DUMP" "$OOCD_LOG"' EXIT

# One idiom for every OpenOCD step (#277).
#
# The previous code used two, and neither was sound. The erase step piped to
# `grep -iE error && exit 1`, which cannot fail the script: commands in an `&&`
# list are exempt from errexit and grep finding nothing short-circuits the exit,
# so an OpenOCD that died without printing the word "error" sailed through to
# writing over flash that was never erased. The write step checked captured text
# against a different pattern and no exit status at all.
#
# BOTH signals are needed. OpenOCD has historically exited 0 after printing an
# error, so the status alone is not enough; a crash or a lost probe prints no
# recognisable line, so the text alone is not enough either.
oocd_run() {
  local label="$1" tcl="$2" status=0
  "$OPENOCD" -s "$SCRIPTS" \
    -f interface/cmsis-dap.cfg -c "transport select swd" \
    -c "adapter speed ${SOPHON_SWD_KHZ:-4000}" \
    -f target/nrf52.cfg -c "$tcl" >"$OOCD_LOG" 2>&1 || status=$?
  if [[ "$status" -ne 0 ]] \
     || grep -iqE "^Error|failed to write|timeout waiting for algorithm" "$OOCD_LOG"; then
    sed 's/^/    /' "$OOCD_LOG" >&2
    echo "error: $label failed (openocd exit $status)" >&2
    return 1
  fi
  return 0
}

# --- refuse to clobber a UF2 board -------------------------------------------
#
# A Nordic SoftDevice announces itself with magic 0x51B1E5DB in its info struct
# at 0x3004. Its presence means this board still runs the stock UF2 arrangement:
# MBR at 0x0, S140 above it, Adafruit bootloader at 0xF4000. Writing MCUboot
# over that is a one-way door without a backup, so it is not something to do by
# running the wrong script.
echo "==> probing target"
# Not oocd_run: a target that does not answer is reported with wiring help
# rather than an OpenOCD transcript, so this one reads the log itself. The read
# needs no halt -- see BOOTLOADER.md, "It is the halt, not SWD access" (#275).
oocd_run "probe" 'init; echo "MAGIC [nrf52.cpu read_memory 0x3004 32 1]"; exit' >/dev/null 2>&1 || true
PROBE="$(cat "$OOCD_LOG")"
if ! grep -q "Cortex-M4" <<<"$PROBE"; then
  echo "error: no target responding over SWD." >&2
  echo "       check the probe and the SWDIO/SWCLK/GND wiring (TP5/TP3/TP1)." >&2
  # shellcheck disable=SC2001  # ${v//s/r} cannot prefix EVERY line of a
  # multi-line string; sed is the right tool here, not a fallback.
  echo "$PROBE" | sed 's/^/       /' >&2
  exit 1
fi
# macOS ships bash 3.2, so no ${var,,} -- lowercase with tr.
MAGIC="$(sed -n 's/^MAGIC \(.*\)$/\1/p' <<<"$PROBE" | tr -d ' \r' | tr '[:upper:]' '[:lower:]')"
echo "    SoftDevice magic @0x3004: ${MAGIC:-<unreadable>}  (0x51b1e5db = UF2 board)"

# A GUARD OVER A ONE-WAY DOOR HAS TO FAIL CLOSED.
#
# This used to read the magic, and if it could not, carry on and erase. An
# unreadable value is not evidence of absence -- it is no evidence at all, and
# the next thing the script does is blanket-erase 0x0-0xFC000. On a UF2 board
# that is the SoftDevice AND the Adafruit bootloader, with no way back except a
# full backup.
#
# The same shape as #277's OpenOCD defect: a check whose failure mode was to
# permit the thing it existed to prevent. Here the target answered (the
# Cortex-M4 check above passed), so the probe and wiring are fine and something
# else went wrong with the read -- which is precisely when not to proceed.
if [[ -z "$MAGIC" ]]; then
  if [[ "$FORCE" -eq 0 ]]; then
    echo "error: the target answered but its SoftDevice magic at 0x3004 could" >&2
    echo "       not be read, so this script cannot tell a UF2 board from an" >&2
    echo "       MCUboot one. Refusing: the next step erases 0x0-0xFC000, and on" >&2
    echo "       a UF2 board that destroys the SoftDevice and the Adafruit" >&2
    echo "       bootloader together." >&2
    echo >&2
    echo "       Read it by hand before deciding:" >&2
    echo "         openocd ... -c 'init; mdw 0x3004 1; exit'" >&2
    echo "       0x51b1e5db means UF2 -- use scripts/flash.sh instead." >&2
    echo "       Anything else means MCUboot -- re-run with --force." >&2
    # shellcheck disable=SC2001  # same reason as the probe failure above:
    # ${v//s/r} cannot prefix EVERY line of a multi-line string.
    sed 's/^/       /' <<<"$PROBE" >&2
    exit 1
  fi
  echo "    warning: magic unreadable and --force given; proceeding blind" >&2
fi

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

# --- erase and write, in ONE session -----------------------------------------
#
# This used to be two OpenOCD invocations, on the belief that erase and write
# could not share a session: "erasing leaves the core executing blank flash,
# which locks up on a double fault", and OpenOCD writes flash by running a helper
# routine in target RAM that a locked-up core cannot run. The symptom was real --
# `timeout waiting for algorithm` -- but the rule drawn from it was wrong (#277).
#
# It is ENDING THE SESSION after an erase that does the damage. OpenOCD releases
# the core on exit, and a core released into blank flash double-faults; the next
# session then finds it locked up. Keep the core halted for the whole session and
# the situation never arises.
#
# Measured on Sophon-86F0: blanket erase plus both writes in one session, 27 s,
# no timeout, both images verified, and slot1 confirmed blank afterwards.
#
# Storage at 0xFC000 is left alone so settings survive a reflash. Everything
# below it is erased, slot1 included -- which matters more than it looks: a stale
# image left in slot1 with a valid trailer would be swapped in at the next boot,
# quietly replacing what was just flashed. `flash write_image erase` alone would
# NOT do this, since it only erases the sectors it writes.
#
# ALWAYS end in `reset run`, never a bare `resume`. Resuming after a long halt
# leaves the BLE stack believing a connection that the peer abandoned long ago
# is still live: the board stops advertising, refuses new centrals, and only a
# reset recovers it. That cost an afternoon to diagnose.
#
# None of this is atomic: once the erase has run, any partial completion leaves
# the board unbootable under CONFIG_BOOT_VALIDATE_SLOT0.
#
# It COULD be made recoverable -- dumping 0x0-0xFC000 first and writing it back on
# failure is a rollback, and costs about 25 s. Deliberately not done (#277): it
# would take and reapply a 1 MB snapshot on every flash to cover a case a re-run
# already handles, and a probe failure that broke the write would likely break the
# restore too. What is NOT true is that rollback is impossible, which an earlier
# version of this comment claimed.
#
# So the read-back below is not optional. Reporting precisely what state the board
# is in is the deliverable, and a re-run is the recovery.
echo "==> erasing 0x000000-0x0FC000 and writing mcuboot + signed application"
if ! oocd_run "erase and write" \
     "init; reset halt; \
      flash erase_address 0x00000000 0x000FC000; \
      flash write_image $BOOT_HEX; flash write_image $APP_HEX; \
      reset run; exit"; then
  echo "       the board may now hold a partial pair and refuse to boot." >&2
  echo "       FIRST try running this script again -- the erase is idempotent and" >&2
  echo "       a re-run is the whole recovery in most cases." >&2
  echo "       If the core is wedged: openocd ... -c 'init; nrf52_recover; exit'," >&2
  echo "       then re-run. See BOOTLOADER.md." >&2
  echo "       Backups are in ~/.sophon/backups/, one pair per era. Restore the" >&2
  echo "       _mcuboot_ pair, NOT the _uf2-sdv7_ one -- the latter predates the" >&2
  echo "       migration and returns this board to the Adafruit UF2 bootloader." >&2
  exit 1
fi

# --- read it back (#277) ------------------------------------------------------
#
# `flash write_image` reports what it sent, not what landed, and this script used
# to print "done -- board reset and running" having read nothing at all. The
# re-dump needs NO halt (#275), so verifying costs seconds and does not disturb a
# board that is already up -- which is also why it runs after `reset run` rather
# than before.
#
# Compared against the artefacts that were just WRITTEN, never against a rebuild:
# the image carries a generated build timestamp, so identical source signs
# differently every time and a fresh build would always "fail" this check.
EXTENT="$("$SCRIPT_DIR/ihex-cmp.py" --extent "$BOOT_HEX" "$APP_HEX")"
echo "==> reading back 0x000000-$(printf '0x%06X' "$EXTENT")"
if ! oocd_run "verification read" "init; dump_image $DUMP 0x00000000 $EXTENT; exit"; then
  echo "       the write reported success but could not be read back." >&2
  exit 1
fi

if ! "$SCRIPT_DIR/ihex-cmp.py" "$DUMP" 0x0 "$BOOT_HEX" "$APP_HEX"; then
  echo >&2
  echo "error: what is on the board does not match what was written." >&2
  echo "       the spans above say which image is wrong. Re-run this script; the" >&2
  echo "       erase is idempotent, so a second pass costs 33 s and nothing else." >&2
  echo "       A mismatch that survives a re-run is a flash or probe fault, not a" >&2
  echo "       stale artefact -- the staleness guard already ran." >&2
  exit 1
fi

echo "==> done -- both images verified on the board, which is reset and running"
echo "    console: /dev/cu.usbmodem* at 115200 (use cu.*, not tty.*)"
