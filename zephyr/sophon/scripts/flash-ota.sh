#!/usr/bin/env bash
#
# Flash the Sophon MCUboot build over the air, via MCUmgr SMP (#271).
#
#   SOPHON_BOOT=mcuboot scripts/build.sh
#   scripts/flash-ota.sh
#
# For the probe-based path use scripts/flash-swd.sh. The two are not
# interchangeable:
#
#   flash-swd.sh   writes the BOOTLOADER and the application. Erases first, so a
#                  partial completion leaves a board that will not boot.
#   flash-ota.sh   writes the APPLICATION only, into the spare slot. The running
#                  image is untouched until MCUboot swaps on reset, and a bad
#                  image reverts on its own. There is no brick path here.
#
# That asymmetry is why this script is short and flash-swd.sh is careful.
#
# WHAT THIS DELIBERATELY DOES NOT DO: confirm the image. It is marked for TEST,
# so the board boots it once and reverts at the next reset unless something
# confirms it. On this firmware that something is the application itself, and
# only after a frame has actually been delivered to a subscribed central -- see
# maybe_confirm_image() in src/ble.c. So an update becomes permanent when you
# reconnect with the Sophon app and see data, and not before. Automating that
# away here would delete the feature.
#
# BEFORE RUNNING: force-quit the Sophon app, do not merely disconnect in it.
# CONFIG_BT_MAX_CONN=1 means the board serves one central, and this script makes
# several separate connections -- scan, upload, mark, reset, verify. A
# backgrounded app reclaims the board in the gap after the upload and the run
# fails partway, leaving the image uploaded but unmarked. Harmless, but it costs
# you two minutes.
#
# Usage: scripts/flash-ota.sh [name-substring]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
sophon_common_init

BUILD_DIR="$APP_DIR/build-mcuboot"
IMAGE="$BUILD_DIR/sophon/zephyr/zephyr.signed.bin"
FILTER="${1:-${SOPHON_BLE_NAME:-sophon}}"

command -v smpmgr >/dev/null 2>&1 || {
  echo "error: smpmgr not found." >&2
  echo "       uv tool install smpmgr   (see README.md, Getting set up)" >&2
  exit 1
}

[[ -f "$IMAGE" ]] || {
  echo "error: $IMAGE not found" >&2
  echo "       run: SOPHON_BOOT=mcuboot scripts/build.sh" >&2
  exit 1
}

# --- refuse a stale build ------------------------------------------------
#
# Same guard and the same reasoning as flash-swd.sh: an artefact older than any
# input is the one silent failure in this set. Only the application is uploaded,
# so the MCUboot config is not in the list -- a bootloader change cannot be
# delivered this way at all, and needs the probe.
SOURCES=("$APP_DIR/src" "$APP_DIR/prj.conf" "$APP_DIR/CMakeLists.txt"
         "$APP_DIR/app.overlay" "$APP_DIR/VERSION" "$APP_DIR/swd" "$APP_DIR/dts")
NEWER="$(find "${SOURCES[@]}" -newer "$IMAGE" -print -quit 2>/dev/null || true)"
if [[ -n "$NEWER" ]]; then
  echo "error: $IMAGE is older than $NEWER" >&2
  echo "       run: SOPHON_BOOT=mcuboot scripts/build.sh" >&2
  exit 1
fi

# --- resolve the board ----------------------------------------------------
#
# Not cached and not configurable as a literal: on macOS this is a CoreBluetooth
# UUID that identifies the board TO THIS HOST, so it differs per Mac. See
# ble-find.py. SOPHON_BLE_ADDR skips the scan when you already have one.
if [[ -n "${SOPHON_BLE_ADDR:-}" ]]; then
  ADDR="$SOPHON_BLE_ADDR"
  echo "==> using SOPHON_BLE_ADDR=$ADDR"
else
  echo "==> scanning for '$FILTER'"
  if ! ADDR="$(uv run --quiet --with bleak python "$SCRIPT_DIR/ble-find.py" "$FILTER")"; then
    exit 1
  fi
  echo "    $ADDR"
fi

smp() { smpmgr --ble "$ADDR" --timeout "${SOPHON_SMP_TIMEOUT:-30}" "$@"; }

# --- upload ----------------------------------------------------------------
#
# Into the spare slot, so the running image is untouched. ~55 s for a 190 KB
# image at the default 23-byte ATT MTU; see #271 for why the MTU has not been
# raised yet.
# The version being shipped, read from the image itself. Without this the script
# cannot tell a successful update from a REVERTED one -- both end with the board
# running a confirmed image, and only the version number differs.
WANT_VER="$(strings "$IMAGE" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"

echo "==> uploading $(wc -c < "$IMAGE" | tr -d ' ') bytes (about a minute)"
if ! smp image upload "$IMAGE"; then
  echo "error: upload failed." >&2
  echo "       The running image is untouched -- the upload goes to the spare" >&2
  echo "       slot, so a failure here costs nothing. Re-run." >&2
  exit 1
fi

# --- mark for test, and reset ----------------------------------------------
# NOTE THE `|| true`, which is load-bearing. Under `set -euo pipefail` a failing
# smpmgr makes this whole pipeline fail, and the assignment aborts the script
# BEFORE the check below can report anything -- so the useful error never prints
# and the script dies silently having uploaded an image it then abandons. That
# cost two misdiagnosed failures: the trigger was the connection race described
# above, but this is why it was invisible.
HASH="$(smp image state-read 2>/dev/null | grep -oE "[0-9A-F]{64}" | tail -1 || true)"
if [[ -z "$HASH" ]]; then
  echo "error: uploaded, but could not read the staged image's hash back." >&2
  echo "       The image IS in the spare slot and the board still runs the old" >&2
  echo "       one, so nothing is at risk." >&2
  echo "       Most likely something took the board's one connection while the" >&2
  echo "       upload was releasing it -- force-quit the Sophon app and re-run." >&2
  exit 1
fi

# Marking arms the swap, and it is read back rather than assumed -- the #277
# lesson in a new place.
#
# It is worth knowing WHY this step failed twice before the read-back existed,
# because the cause was not flakiness and an earlier version of this comment
# blamed the wrong thing. CONFIG_BT_MAX_CONN=1, and every smpmgr invocation
# connects and disconnects on its own. The upload holds the link for ~55 s and
# then releases it, and an iOS app that has been retrying the whole time takes
# the board in that gap. The next command then cannot connect at all.
#
# So a backgrounded app is not enough: it keeps reconnecting. The app must be
# FORCE-QUIT for the duration. Confirmed by changing nothing else and watching
# the same run go from failing at the mark to completing in 2m03s.
echo "==> marking $HASH for test"
MARKED=0
for attempt in 1 2 3; do
  smp image state-write "$HASH" >/dev/null 2>&1 || true
  if smp image state-read 2>/dev/null | awk '/slot=1/,/^\)/' | grep -q "pending=True"; then
    MARKED=1
    break
  fi
  echo "    attempt $attempt did not take; retrying" >&2
  sleep 3
done

if [[ "$MARKED" -eq 0 ]]; then
  echo "error: could not mark the uploaded image for test." >&2
  echo "       It IS uploaded and sitting in the spare slot -- the board still" >&2
  echo "       runs the old image and nothing is at risk. Mark it by hand with:" >&2
  echo "         smpmgr --ble $ADDR image state-write $HASH" >&2
  exit 1
fi

echo "==> resetting; MCUboot swaps the slots"
smp os reset >/dev/null 2>&1 || true
# Measured at about 20 s for a 190 KB image, not the ~47 s first assumed from
# watching a reflash. 40 s is margin, not an estimate of the swap itself.
sleep "${SOPHON_SWAP_WAIT:-40}"

# --- verify -----------------------------------------------------------------
#
# Read the state back rather than trusting the reset. Note the console is NOT a
# reliable check here: the board's CDC ACM re-enumerates across a swap and a
# capture pinned to the old node returns stale output, which has twice read as a
# failed swap that had in fact succeeded. See BOOTLOADER.md.
echo "==> verifying"
if ! STATE="$(smp image state-read 2>&1)"; then
  echo "error: the board did not answer after the swap." >&2
  echo "       If it is advertising, something else may hold its one connection." >&2
  echo "       If it is not, recover with the probe: scripts/flash-swd.sh" >&2
  exit 1
fi

# `|| true` for the same reason as above: a parse that finds nothing must fall
# through to the reporting below, not kill the script silently.
ACTIVE_VER="$(awk '/slot=0/,/^\)/' <<<"$STATE" | grep -oE "version='[^']+'" | head -1 | cut -d"'" -f2 || true)"
CONFIRMED="$(awk '/slot=0/,/^\)/' <<<"$STATE" | grep -oE "confirmed=(True|False)" | head -1 || true)"

echo
echo "    uploaded: ${WANT_VER:-unknown}"
echo "    running:  $ACTIVE_VER   $CONFIRMED"
echo

# A REVERT and a success both leave the board running a confirmed image. The
# only thing that separates them is whether it is the version we just shipped --
# so check that first, or a failed update reads as a successful one. Observed:
# a deliberately boot-looping image reverted correctly and this script called it
# "running and already confirmed".
if [[ -n "$WANT_VER" && "$ACTIVE_VER" != "$WANT_VER" ]]; then
  echo "==> REVERTED -- the board is NOT running what was just uploaded." >&2
  echo "    $WANT_VER was swapped in, failed to confirm itself, and MCUboot put" >&2
  echo "    $ACTIVE_VER back. That is rollback working, not a flashing error." >&2
  echo >&2
  echo "    The usual cause is that the new image did not reach the point of" >&2
  echo "    delivering a frame -- it crashed, rebooted, or its BLE never came up." >&2
  echo "    It is still in the spare slot; read the console on the next attempt." >&2
  exit 1
fi

if [[ "$CONFIRMED" == "confirmed=False" ]]; then
  echo "==> done -- $ACTIVE_VER is running ON TRIAL."
  echo "    It reverts at the next reset unless it is confirmed, and this"
  echo "    firmware confirms only after delivering a frame to a subscribed"
  echo "    central. Open the Sophon app and watch data arrive; that is what"
  echo "    makes the update permanent."
else
  echo "==> done -- $ACTIVE_VER is running and already confirmed."
  echo "    Something subscribed during the wait above and confirmed it."
fi
