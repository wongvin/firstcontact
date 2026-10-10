#!/usr/bin/env bash
#
# Build the Sophon firmware, for either boot path.
#
#   scripts/build.sh                        # MCUboot via sysbuild (the default)
#   SOPHON_BOOT=uf2 scripts/build.sh        # UF2, for a board not yet migrated
#
# MCUboot is the default because every board runs it (#270). A UF2 build is
# still needed for one job: a board that arrives on the Adafruit bootloader and
# is flashed with scripts/flash-uf2.sh before migrating. Migrating itself, by
# sophon-installer or flash-swd.sh, consumes the MCUboot build.
#
# An MCUboot build needs the signing key (see below). A UF2 build does not.
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
# neither reuses the other's CMake cache. It also lets flash-uf2.sh and
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
# The application's MCUboot-only Kconfig: MCUmgr/SMP and the image manager
# (#271). Kept out of prj.conf so the UF2 build still compiles (#306).
APP_MCUBOOT_CONF="$APP_DIR/swd/app-mcuboot.conf"
# MCUboot only: its console goes to uart0, since it has no USB stack for
# the board's default CDC ACM console.
BOOT_CONSOLE="$APP_DIR/swd/mcuboot-console.overlay"

for f in "$PARTITIONS" "$APP_SLOT0" "$BOOT_CONSOLE" "$APP_MCUBOOT_CONF"; do
  [[ -f "$f" ]] || { echo "error: missing MCUboot build file $f" >&2; exit 1; }
done

# --- signing key (#274) ------------------------------------------------------
#
# MCUboot validates every image on boot against a public key compiled INTO the
# bootloader, and `imgtool` signs the application with the private half of the
# same file. One path, two consumers -- which is why the bootloader and the
# application can never be flashed independently once this changes.
#
# Resolution order, deliberately:
#
#   1. $SOPHON_SIGNING_KEY   -- an absolute path, for CI or a non-macOS host
#   2. ~/.sophon/keys/...    -- where #287 put it on this machine
#
# The default is NOT baked into committed config as an absolute path: that is
# the mistake .vscode/settings.json made (ac6abfd), and it would hardcode one
# developer's $HOME into the build.
#
# Note the doubled quoting where this is passed to west below. It is not a typo:
# BOOT_SIGNATURE_KEY_FILE is a Kconfig *string*, so the quotes have to survive
# into the generated .conf file. Without them the value is written bare and
# Kconfig rejects it -- "malformed string literal in assignment", which aborts
# the build well after the point where the cause is obvious.
SIGNING_KEY="${SOPHON_SIGNING_KEY:-$HOME/.sophon/keys/sophon-fw-rsa-2048.pem}"
if [[ ! -f "$SIGNING_KEY" ]]; then
  echo "error: no signing key at $SIGNING_KEY" >&2
  echo "       set SOPHON_SIGNING_KEY to an absolute path, or see" >&2
  echo "       ~/.sophon/README.md for what belongs there." >&2
  exit 1
fi

# Warn by FINGERPRINT, not by filename -- a filename is a label anyone can
# change, and the thing that actually matters is which key a bootloader will
# trust. This is the same SHA-256 that appears as the KEYHASH TLV in a signed
# image: of the DER PKCS#1 RSAPublicKey, NOT SubjectPublicKeyInfo, which is what
# most tooling emits by default.
DEMO_KEYHASH="fc5701dc6135e1323847bdc40f04d2e5bee5833b23c29f93593d00018cfa9994"
if command -v openssl >/dev/null 2>&1; then
  KEYHASH="$(openssl rsa -in "$SIGNING_KEY" -RSAPublicKey_out -outform DER 2>/dev/null \
             | shasum -a 256 | cut -d" " -f1)"
  if [[ "$KEYHASH" == "$DEMO_KEYHASH" ]]; then
    echo "warning: signing with MCUboot's PUBLIC demo key." >&2
    echo "         Its private half ships in every MCUboot checkout, so images are" >&2
    echo "         integrity-checked but NOT authenticated -- anyone can produce a" >&2
    echo "         signature the bootloader will accept. Tracked in #274." >&2
  fi
fi

exec west build -p always -b "$BOARD" --sysbuild -d "$BUILD_DIR" "$APP_DIR" "$@" \
  -- -DSB_CONFIG_BOOTLOADER_MCUBOOT=y \
     -DSB_CONFIG_BOOT_SIGNATURE_KEY_FILE="\"$SIGNING_KEY\"" \
     -DEXTRA_DTC_OVERLAY_FILE="$PARTITIONS;$APP_SLOT0" \
     -DEXTRA_CONF_FILE="$APP_MCUBOOT_CONF" \
     -Dmcuboot_EXTRA_DTC_OVERLAY_FILE="$PARTITIONS;$BOOT_CONSOLE"
