#!/bin/bash
#
# deploy-device.sh — build the Sophon app for the connected physical
# iPhone (Debug) and install + launch it, in one command.
#
# Auto-detects whichever iOS device is currently connected (via
# `xcrun devicectl list devices`) — no hardcoded device name or UDID — and
# fails with a clear message if none is connected. Builds a generic iOS-device
# build (free-signing Apple Development profile), then installs and launches it
# via devicectl.
#
# Usage:
#   ios/Sophon/scripts/deploy-device.sh              # one device connected
#   ios/Sophon/scripts/deploy-device.sh iPad         # pick by substring
#   ios/Sophon/scripts/deploy-device.sh --all        # every usable device
#   ios/Sophon/scripts/deploy-device.sh --no-launch  # install only, do not restart
#   SOPHON_DEVICE=iPhone ios/Sophon/scripts/deploy-device.sh
#
# --no-launch installs and stops there. Install IS the deployment; launching is
# only how the new code gets to run, because installing over a running app
# replaces the bundle while leaving the old process executing. Two reasons to
# want it:
#
#   - it does not kill a session in progress, so a device mid-measurement keeps
#     running the old build until you restart it yourself;
#   - install works on a LOCKED device, whereas launch is refused. Most of the
#     "launch failed" noise on a locked device is this, and with --no-launch it
#     stops being a warning about something you did not ask for.
#
# The cost is that nothing tells you the app is stale. Restart it by hand, or
# re-run without the flag, before believing you are testing the new build.
#
# The selector exists because simulator mode needs two devices at once — an
# iPhone advertising as a Sophon and an iPad viewing it — so "the connected
# device" stopped being unambiguous. It is matched case-insensitively against
# the whole devicectl row, so a name, a model or a full UDID all work. Nothing
# is hardcoded here; the choice is supplied at the call site.
#
# With two or more connected and no selector this FAILS rather than guessing.
# Silently deploying to whichever device enumerated first is the kind of wrong
# that costs twenty minutes of debugging the wrong build. Behaviour with exactly
# one device connected is unchanged.
#
# Run it from anywhere — the script locates the Xcode project relative to itself.
# The device must be connected (USB or network-paired) and unlocked.

set -euo pipefail

SCHEME="Sophon"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"   # ios/Sophon (holds Sophon.xcodeproj)
cd "$PROJECT_DIR"

# --- 0. Parse the optional selector ------------------------------------------
DEPLOY_ALL=0
NO_LAUNCH=0
FILTER="${SOPHON_DEVICE:-}"
for arg in "$@"; do
  case "${arg}" in
    --all) DEPLOY_ALL=1 ;;
    --no-launch) NO_LAUNCH=1 ;;
    -h|--help)
      # Two things that were wrong here, both only visible once the header grew:
      #
      #   - the range was hardcoded to lines 2-32, so extending the usage block
      #     silently truncated the help rather than failing;
      #   - BASH_SOURCE[0] is relative when invoked as ./deploy-device.sh, and
      #     this script has already cd'd to PROJECT_DIR by now, so sed could not
      #     find its own file.
      #
      # Printing the leading comment block dynamically, from an absolute path,
      # cannot drift out of sync with the header.
      awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' \
        "${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
      exit 0 ;;
    -*)
      echo "error: unknown option ${arg}" >&2
      exit 1 ;;
    *) FILTER="${arg}" ;;
  esac
done

# --- 1. Enumerate devices and check their tunnel state ---------------------
# Read devicectl's JSON rather than scraping the text table. devicectl's own help
# says JSON output is "the ONLY supported interface for scripts", and the table's
# State column is genuinely awkward to parse: device names contain spaces, so
# column positions shift, and "available (paired)" is two tokens while
# "connected" is one. jq ships with macOS, so this costs nothing.
#
# The field that matters is connectionProperties.tunnelState:
#
#   connected     an active tunnel exists right now
#   disconnected  paired, tunnel currently down
#   unavailable   not reachable at all
#
# A "disconnected" tunnel is NOT a reason to skip the device. devicectl will
# usually bring one up on demand: measured on this project's iPad mini 5, which
# sat in disconnected for several minutes and then installed cleanly ("Acquired
# tunnel connection to device" -> "App installed"). It is also not reliable --
# the same device minutes earlier failed with `Connection reset by peer`
# (CoreDeviceError 4000) -- which is why install is retried once below.
#
# So tunnel state is reported, not obeyed. Predicting failure from a state that
# describes only this instant would silently skip devices that would have worked,
# and with --all the entire point is not to have to think about it.
DEVICE_JSON="$(mktemp)"
DEVICE_TABLE="$(mktemp)"
LAUNCH_LOG="$(mktemp)"
trap 'rm -f "${DEVICE_JSON}" "${DEVICE_TABLE}" "${LAUNCH_LOG}"' EXIT

if ! xcrun devicectl list devices --json-output "${DEVICE_JSON}" >/dev/null 2>&1; then
  echo "error: could not enumerate devices (xcrun devicectl list devices failed)." >&2
  exit 1
fi

# identifier <TAB> name <TAB> tunnelState, for anything paired and not unavailable.
jq -r --arg filter "$(printf '%s' "${FILTER}" | tr '[:upper:]' '[:lower:]')" '
  .result.devices[]
  | select(.connectionProperties.pairingState == "paired")
  | select(.connectionProperties.tunnelState != "unavailable")
  | [.identifier, .deviceProperties.name, .connectionProperties.tunnelState]
  | select(
      $filter == ""
      or (map(tostring) | join(" ") | ascii_downcase | contains($filter))
    )
  | @tsv
' "${DEVICE_JSON}" > "${DEVICE_TABLE}"

MATCH_COUNT="$(wc -l < "${DEVICE_TABLE}" | tr -d ' ')"

if [ "${MATCH_COUNT}" -eq 0 ]; then
  if [ -n "${FILTER}" ]; then
    echo "error: no usable iOS device matches '${FILTER}'." >&2
  else
    echo "error: no usable iOS device found." >&2
  fi
  echo "       Unlock the device and confirm it is on the same Wi-Fi as this Mac," >&2
  echo "       or attach it by USB. Only 'unavailable' devices are skipped outright." >&2
  echo "       Tunnel state per known device:" >&2
  jq -r '.result.devices[]
         | "         \(.deviceProperties.name)  tunnel=\(.connectionProperties.tunnelState)  paired=\(.connectionProperties.pairingState)"' \
    "${DEVICE_JSON}" >&2 || true
  exit 1
fi

if [ "${MATCH_COUNT}" -gt 1 ] && [ "${DEPLOY_ALL}" -eq 0 ]; then
  echo "error: ${MATCH_COUNT} usable devices — choose one, or use --all:" >&2
  while IFS="$(printf '\t')" read -r id name tunnel; do
    printf "  %s '%s'   (tunnel %s)\n" "$(basename "${BASH_SOURCE[0]}")" "${name}" "${tunnel}" >&2
  done < "${DEVICE_TABLE}"
  echo "  $(basename "${BASH_SOURCE[0]}") --all" >&2
  exit 1
fi

echo "==> Deploying to ${MATCH_COUNT} device(s):"
while IFS="$(printf '\t')" read -r id name tunnel; do
  if [ "${tunnel}" = "connected" ]; then
    printf '    %-16s tunnel up\n' "${name}"
  else
    printf '    %-16s tunnel %s — devicectl will try to establish one\n' "${name}" "${tunnel}"
  fi
done < "${DEVICE_TABLE}"

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

# --- 4. Install + launch on each selected device -----------------------------
# devicectl prints a benign "No provider was found." (Code=1002) line to stderr;
# install/launch still succeed.
#
# One build, N installs: with --all both devices get the same binary, which is
# the point — the iPhone runs it in simulator mode and the iPad in viewer mode.
FAILED=0
while IFS="$(printf '\t')" read -r DEVICE_ID NAME TUNNEL; do
  echo "==> Installing ${WRAPPER} → ${NAME}…"

  # Retried once, deliberately. A device whose tunnel is down often fails the
  # first attempt with `Connection reset by peer` and succeeds on the second,
  # because the first attempt is what wakes the tunnel up. Retrying beyond twice
  # just prolongs a genuine failure.
  if ! xcrun devicectl device install app --device "${DEVICE_ID}" "${APP}"; then
    echo "    first attempt failed; retrying once (tunnel was ${TUNNEL})…" >&2
    sleep 3
    if ! xcrun devicectl device install app --device "${DEVICE_ID}" "${APP}"; then
      echo "warning: install failed on ${NAME} — unlock it and confirm it is on this Wi-Fi." >&2
      FAILED=1
      continue
    fi
  fi

  if [ "${NO_LAUNCH}" -eq 1 ]; then
    echo "    installed, not launched — restart the app to pick it up"
    continue
  fi

  echo "==> Launching ${BUNDLE_ID} on ${NAME}…"
  # --terminate-existing is not optional here. Installing over a RUNNING app
  # replaces the bundle on disk but leaves the old process executing, and a
  # plain launch then just foregrounds that stale process -- so the build you
  # just deployed never actually runs. Silently testing the previous build is a
  # far worse failure than a launch error, because nothing looks wrong.
  # tee rather than redirect: the output still streams as it did, and pipefail
  # (set at the top) makes the pipeline carry devicectl's status rather than
  # tee's, so a failure is still detected.
  if ! xcrun devicectl device process launch --terminate-existing \
       --device "${DEVICE_ID}" "${BUNDLE_ID}" 2>&1 | tee "${LAUNCH_LOG}"; then
    # devicectl reports several distinct causes through the same non-zero exit,
    # and the wrong guess sends you to the wrong fix -- this used to blame a
    # locked device for what was almost always an untrusted certificate (#239).
    if grep -qE "not been explicitly trusted|invalid code signature|inadequate entitlements" "${LAUNCH_LOG}"; then
      echo "warning: ${NAME} has not trusted this developer certificate, so the app cannot launch." >&2
      echo "         Settings > General > VPN & Device Management > Developer App > Trust." >&2
      echo "         Free-signing certificates are reissued about weekly, so expect this again." >&2
    elif grep -qE "could not be, unlocked|FBSOpenApplicationErrorDomain error 7" "${LAUNCH_LOG}"; then
      echo "warning: ${NAME} is locked, so launch was refused. Unlock and re-run, or open the app from the home screen." >&2
    else
      echo "warning: launch failed on ${NAME}. The app is installed -- open it from the home screen." >&2
      echo "         devicectl's own output above says why." >&2
    fi
  fi
done < "${DEVICE_TABLE}"

if [ "${FAILED}" -eq 0 ]; then
  if [ "${NO_LAUNCH}" -eq 1 ]; then
    echo "==> Done — installed only. The devices are still running the previous"
    echo "    build until each app is restarted."
  else
    echo "==> Done."
  fi
else
  echo "==> Finished with warnings." >&2
  exit 1
fi
