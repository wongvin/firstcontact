#!/usr/bin/env bash
#
# Shared prologue for the Sophon scripts. Source it; do not execute it -- the
# file only defines functions, and it is deliberately left non-executable.
#
# The shebang is for the linter, not for running this. Without a shell
# declaration shellcheck reports SC2148 and then analyses NOTHING, so the one
# file all four scripts depend on was the only one never actually checked, while
# the scripts around it came back clean. A shebang is an ordinary comment when a
# file is sourced, and the mode bit decides executability, so declaring bash here
# costs nothing and matches every other script in this directory.
#
# west walks UP from $PWD looking for a .west/ marker, so it cannot resolve a
# workspace from inside this repo. Exporting ZEPHYR_BASE is what makes a
# freestanding app buildable from here -- that is the documented cost of this
# app layout, not a workaround. See zephyr/CLAUDE.md.
#
# Extracted because build.sh and flash-uf2.sh already carried identical copies of
# this, and flash-swd.sh would have made three. The `.west` error message in
# particular is the kind of text that drifts once it exists twice.

sophon_common_init() {
  APP_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)"
  WORKSPACE="${SOPHON_ZEPHYR_WORKSPACE:-$HOME/zephyrproject}"
  BOARD="${SOPHON_BOARD:-xiao_ble/nrf52840/sense}"
  export APP_DIR WORKSPACE BOARD
}

# Only the west-based paths need this; flash-swd.sh drives OpenOCD directly and
# needs neither the venv nor ZEPHYR_BASE.
sophon_activate_west() {
  if [[ ! -d "$WORKSPACE/.west" ]]; then
    echo "error: no Zephyr workspace at $WORKSPACE (looked for .west/)" >&2
    echo "       set SOPHON_ZEPHYR_WORKSPACE if yours lives elsewhere" >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  source "$WORKSPACE/.venv/bin/activate"
  export ZEPHYR_BASE="$WORKSPACE/zephyr"
}

# Which boot path a build targets. MCUboot by default since every board runs it
# (#270); uf2 is kept for boards that still have the Adafruit bootloader.
sophon_boot_mode() {
  local mode="${SOPHON_BOOT:-mcuboot}"
  case "$mode" in
    uf2|mcuboot) echo "$mode" ;;
    *) echo "error: SOPHON_BOOT must be 'uf2' or 'mcuboot', got '$mode'" >&2; exit 1 ;;
  esac
}

sophon_build_dir() {
  case "$(sophon_boot_mode)" in
    uf2)     echo "$APP_DIR/build" ;;
    mcuboot) echo "$APP_DIR/build-mcuboot" ;;
  esac
}
