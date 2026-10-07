#!/usr/bin/env bash
#
# Build the UF2 -> MCUboot installer and the migration UF2 (#294).
#
#   scripts/build.sh
#
# Produces build/sophon-migrate.uf2, carrying two disjoint regions: this
# installer at 0x27000 with MCUboot linked inside it, and the signed Sophon
# application at 0x085000. See UF2-MIGRATION.md, "Building the UF2".
#
# NO SOPHON_BOOT MODE, deliberately. The installer is always a plain UF2
# application -- the Adafruit bootloader is the only thing that will accept it,
# and a build at slot0 would be nonsense. Compare ../../sophon/scripts/build.sh,
# which has two modes because the firmware genuinely has two boot paths.
#
# THIS BUILD WRITES NOTHING WHEN IT RUNS. See src/main.c.
#
# Usage: scripts/build.sh [extra west build args...]

set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
sophon_installer_init
sophon_installer_activate_west

# Both payloads come from the Sophon app's MCUboot build, and neither is built
# here. That coupling is deliberate -- #274's signing key means the bootloader
# and the image it validates must be the matched pair that build produced, and
# building a second MCUboot here would invite the two to drift.
MCUBOOT_BIN="$SOPHON_DIR/build-mcuboot/mcuboot/zephyr/zephyr.bin"
SIGNED_IMAGE="$SOPHON_DIR/build-mcuboot/sophon/zephyr/zephyr.signed.bin"

for f in "$MCUBOOT_BIN" "$SIGNED_IMAGE"; do
  [[ -f "$f" ]] || {
    echo "error: $f not found" >&2
    echo "       build it first: SOPHON_BOOT=mcuboot $SOPHON_DIR/scripts/build.sh" >&2
    exit 1
  }
done

# -p always, for the same reason as the Sophon app: a stale CMake cache is
# behind a large share of confusing Zephyr errors, and this app is tiny.
west build -p always -b "$BOARD" -d "$BUILD_DIR" "$APP_DIR" \
  -- -DSOPHON_MCUBOOT_BIN="$MCUBOOT_BIN" "$@"

echo
echo "==> merging the migration UF2"
python3 "$APP_DIR/scripts/mkuf2.py" \
  --installer "$BUILD_DIR/zephyr/zephyr.hex" \
  --image "$SIGNED_IMAGE" \
  -o "$BUILD_DIR/sophon-migrate.uf2"
