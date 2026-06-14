#!/bin/bash
#
# deploy-device.sh — build the FirstContact app for the connected physical
# iPhone (Debug) and install + launch it, in one command.
#
# Auto-detects whichever iOS device is currently connected (via
# `xcrun devicectl list devices`) — no hardcoded device name or UDID — and
# fails with a clear message if none is connected. Builds a generic iOS-device
# build (free-signing Apple Development profile), then installs and launches it
# via devicectl.
#
# Usage:
#   ios/FirstContact/scripts/deploy-device.sh
# Run it from anywhere — the script locates the Xcode project relative to itself.
# The device must be connected (USB or network-paired) and unlocked.

set -euo pipefail

SCHEME="FirstContact"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"   # ios/FirstContact (holds FirstContact.xcodeproj)
cd "$PROJECT_DIR"

# --- 1. Find the connected device's devicectl identifier ---------------------
# `devicectl list devices` prints a table; grab the UUID from a row in the
# "connected" state. (A devicectl identifier differs from xcodebuild's device
# id, so it is used only for install/launch — the build uses a generic
# destination, which needs no id.)
DEVICE_ID="$( { xcrun devicectl list devices 2>/dev/null || true; } \
  | awk 'tolower($0) ~ /connected/ {
      for (i = 1; i <= NF; i++)
        if ($i ~ /^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$/) { print $i; exit }
    }' )"

if [ -z "${DEVICE_ID}" ]; then
  echo "error: no connected iOS device found." >&2
  echo "       Connect and unlock an iPhone (USB or network-paired), then retry." >&2
  echo "       Devices currently known to devicectl:" >&2
  xcrun devicectl list devices >&2 || true
  exit 1
fi
echo "==> Connected device: ${DEVICE_ID}"

# --- 2. Build for a generic iOS device (Debug, automatic provisioning) -------
echo "==> Building ${SCHEME} (Debug, iphoneos)…"
xcodebuild -scheme "${SCHEME}" -sdk iphoneos -configuration Debug \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build

# --- 3. Resolve the built .app path and bundle id from build settings --------
SETTINGS="$(xcodebuild -showBuildSettings -scheme "${SCHEME}" -configuration Debug -sdk iphoneos)"
BUILT_DIR="$(printf '%s\n' "${SETTINGS}" | awk '/ BUILT_PRODUCTS_DIR / {print $3; exit}')"
WRAPPER="$(printf '%s\n'  "${SETTINGS}" | awk '/ WRAPPER_NAME / {print $3; exit}')"
BUNDLE_ID="$(printf '%s\n' "${SETTINGS}" | awk '/ PRODUCT_BUNDLE_IDENTIFIER / {print $3; exit}')"
APP="${BUILT_DIR}/${WRAPPER}"

if [ ! -d "${APP}" ]; then
  echo "error: built app not found at ${APP}" >&2
  exit 1
fi

# --- 4. Install + launch -----------------------------------------------------
# devicectl prints a benign "No provider was found." (Code=1002) line to stderr;
# install/launch still succeed.
echo "==> Installing ${WRAPPER} → ${DEVICE_ID}…"
xcrun devicectl device install app --device "${DEVICE_ID}" "${APP}"

echo "==> Launching ${BUNDLE_ID}…"
if xcrun devicectl device process launch --device "${DEVICE_ID}" "${BUNDLE_ID}"; then
  echo "==> Done — launched on device."
else
  echo "warning: launch failed (is the device unlocked?). The app is installed — open it from the home screen." >&2
fi
