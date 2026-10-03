# Development tools for this repo, installed with `brew bundle` from the root.
#
# Only what no language manifest already owns. Deliberately NOT here:
#
#   webapp/      package.json carries eslint and typescript; `npm install`
#   api/server/  requirements.txt carries the Python runtime deps
#   firmware     the Zephyr SDK and workspace are not brew-installable --
#                see "Getting set up" in README.md
#
# Also deliberately absent, because they already exist on a configured Mac:
#
#   clang-format, clangd   ship with Xcode; reach them via `xcrun -f clang-format`.
#                          Installing `llvm` for these costs ~1.5 GB and buys nothing.
#   jq                     macOS ships jq-1.7.1-apple at /usr/bin/jq.
#                          scripts/deploy-device.sh depends on it.
#   arm-zephyr-eabi-gdb    ships with the Zephyr SDK.

# Shell. Four scripts under zephyr/sophon/scripts/ plus the iOS deploy scripts.
# Catches what `bash -n` cannot: an erase guard that could not fail, and a
# sourced file that had never been analysed at all. See #277.
brew "shellcheck"

# Serial console for the XIAO's USB CDC ACM.
#
# Not a matter of taste over minicom: this board suspends and re-enumerates its
# CDC ACM about 100 ms after boot, and a held file descriptor does not error --
# it goes quiet forever. Every capture that appeared to stop at
# "advertising as Sophon-86F0" was that. tio reconnects automatically; minicom
# does not. See zephyr/sophon/BOOTLOADER.md.
brew "tio"

# Python linter and formatter, one binary replacing black + flake8 + isort.
# Repo-wide rather than per-target: it covers zephyr/sophon/scripts/*.py as well
# as api/server/, so it does not belong in either one's manifest.
brew "ruff"

# Swift linter for ios/. Complements the swift-reviewer agent rather than
# overlapping it: that agent catches observability, actor isolation and Core
# Bluetooth semantics; this catches the mechanical layer beneath.
# Configured by ios/Sophon/.swiftlint.yml -- the defaults do not fit this code.
brew "swiftlint"
