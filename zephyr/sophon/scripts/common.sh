# Shared prologue for the Sophon scripts. Source it; do not execute it.
#
# west walks UP from $PWD looking for a .west/ marker, so it cannot resolve a
# workspace from inside this repo. Exporting ZEPHYR_BASE is what makes a
# freestanding app buildable from here -- that is the documented cost of this
# app layout, not a workaround. See zephyr/CLAUDE.md.
#
# Extracted because build.sh and flash.sh already carried identical copies of
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

# Which boot path a build targets. See build.sh for the transition plan.
sophon_boot_mode() {
  local mode="${SOPHON_BOOT:-uf2}"
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
