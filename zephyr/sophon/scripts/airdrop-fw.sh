#!/usr/bin/env bash
#
# AirDrop the latest MCUboot build to an iPhone, for the Sophon app's
# over-the-air update (#357).
#
#   SOPHON_BOOT=mcuboot scripts/build.sh
#   scripts/airdrop-fw.sh
#
# Copies the signed image to build-mcuboot/sophon-<version>.sophonfw -- the
# extension the app registers, so the phone offers "Open in Sophon" -- and opens
# the AirDrop window for it. Pick the iPhone there. The app keeps the image and
# offers it beside the firmware warning of any board running older firmware.
#
# Not part of build.sh on purpose: most builds are not sent anywhere.
#
# The phone does what flash-ota.sh does -- upload, mark for test, reset -- and
# never confirms: the board keeps the image only once it delivers data.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
sophon_common_init

BUILD_DIR="$APP_DIR/build-mcuboot"
IMAGE="$BUILD_DIR/sophon/zephyr/zephyr.signed.bin"

[[ -f "$IMAGE" ]] || {
  echo "error: $IMAGE not found" >&2
  echo "       run: SOPHON_BOOT=mcuboot scripts/build.sh" >&2
  exit 1
}

# --- refuse a stale build ------------------------------------------------
#
# The same guard as flash-ota.sh: an image older than any input is the one
# silent failure, and here it would travel to a phone and on to a board.
SOURCES=("$APP_DIR/src" "$APP_DIR/prj.conf" "$APP_DIR/CMakeLists.txt"
         "$APP_DIR/app.overlay" "$APP_DIR/VERSION" "$APP_DIR/swd" "$APP_DIR/dts")
NEWER="$(find "${SOURCES[@]}" -newer "$IMAGE" -print -quit 2>/dev/null || true)"
if [[ -n "$NEWER" ]]; then
  echo "error: $IMAGE is older than $NEWER" >&2
  echo "       run: SOPHON_BOOT=mcuboot scripts/build.sh" >&2
  exit 1
fi

# --- name it by the version inside it ------------------------------------
#
# From the MCUboot header (ih_ver at offset 20: major, minor, u16 revision),
# not from VERSION, so the name cannot disagree with what the app reads.
read -r MAJOR MINOR REV_LO REV_HI < <(od -An -tu1 -j20 -N4 "$IMAGE")
VERSION="$MAJOR.$MINOR.$((REV_LO + 256 * REV_HI))"
OUT="$BUILD_DIR/sophon-$VERSION.sophonfw"
rm -f "$BUILD_DIR"/sophon-*.sophonfw
cp "$IMAGE" "$OUT"
echo "==> $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"

# --- send ------------------------------------------------------------------
echo "==> opening AirDrop; pick the iPhone"
if swift "$SCRIPT_DIR/airdrop.swift" "$OUT"; then
  echo "==> sent. On the iPhone, open it in Sophon."
else
  echo "warning: AirDrop did not send it. Showing the file in Finder instead;" >&2
  echo "         share it from there (Share > AirDrop)." >&2
  open -R "$OUT"
  exit 1
fi
