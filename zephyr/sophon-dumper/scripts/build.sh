#!/usr/bin/env bash
#
# Build the flash dumper (#297).
#
#   scripts/build.sh
#
# Produces build/zephyr/zephyr.uf2. Copy it onto a board's mounted volume, then
# capture the dump with scripts/capture.py.
#
# NO SOPHON_BOOT MODE, deliberately -- same reasoning as the installer. This is
# always a plain UF2 application.
#
# THIS APPLICATION WRITES NOTHING WHEN IT RUNS. See src/main.c, and note that
# CONFIG_FLASH is not enabled, so that is a property of the binary.
#
# Usage: scripts/build.sh [extra west build args...]

set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
sophon_dumper_init
sophon_dumper_activate_west

# -p always, for the same reason as the other two apps: a stale CMake cache is
# behind a large share of confusing Zephyr errors, and this app is tiny.
west build -p always -b "$BOARD" -d "$BUILD_DIR" "$APP_DIR" "$@"

echo
echo "==> $BUILD_DIR/zephyr/zephyr.uf2"
echo "    copy it onto the board's volume, then: scripts/capture.py"
