cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(sophon)

# Freestanding app: the Zephyr revision comes from whatever ~/zephyrproject is
# at, not from this repo (there is no west.yml pinning it here). Fail at
# configure time with a readable message rather than on some unrelated compile
# error three layers down.
#
# Two traps here, both verified against cmake/modules/version.cmake:
#   - the variable is ZEPHYR_VERSION_CODE, NOT CONFIG_ZEPHYR_VERSION_CODE.
#     Guarding on the latter is silently dead -- it is never defined, so the
#     check passes on every version.
#   - ZEPHYR_VERSION is a BOOLEAN (set to TRUE), not a version string. The
#     human-readable one is PROJECT_VERSION_STR.
#
# The code is a decimal int: (major << 16) | (minor << 8) | patchlevel.
set(SOPHON_MIN_ZEPHYR_CODE 263168) # 4.4.0

if(ZEPHYR_VERSION_CODE LESS SOPHON_MIN_ZEPHYR_CODE)
  message(FATAL_ERROR
    "Sophon requires Zephyr >= 4.4.0; found ${PROJECT_VERSION_STR} at ${ZEPHYR_BASE}. "
    "Run 'west update' in ~/zephyrproject.")
endif()

target_sources(app PRIVATE
  src/main.c
  src/ble.c
  src/ident.c
  src/imu.c
)
