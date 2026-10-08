#!/usr/bin/env bash
#
# Shared prologue for the installer scripts. Source it; do not execute it.
# Same shape, and the same reasoning, as ../../sophon/scripts/common.sh -- see
# that file for why the shebang is here despite the file never being run, and
# why exporting ZEPHYR_BASE is what makes a freestanding app buildable from
# inside this repo.
#
# Kept separate from Sophon's for the same reason as the installer's: this app
# has no SOPHON_BOOT mode and must never acquire one. It is a UF2 application,
# always, because a UF2 bootloader is the only thing that will accept it -- and
# because a board that still has one is the only board worth dumping.

sophon_dumper_init() {
  APP_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)"
  WORKSPACE="${SOPHON_ZEPHYR_WORKSPACE:-$HOME/zephyrproject}"
  BOARD="${SOPHON_BOARD:-xiao_ble/nrf52840/sense}"
  BUILD_DIR="$APP_DIR/build"
  export APP_DIR WORKSPACE BOARD BUILD_DIR
}

sophon_dumper_activate_west() {
  if [[ ! -d "$WORKSPACE/.west" ]]; then
    echo "error: no Zephyr workspace at $WORKSPACE (looked for .west/)" >&2
    echo "       set SOPHON_ZEPHYR_WORKSPACE if yours lives elsewhere" >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  source "$WORKSPACE/.venv/bin/activate"
  export ZEPHYR_BASE="$WORKSPACE/zephyr"
}
