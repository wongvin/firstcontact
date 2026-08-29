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

# Build timestamp, regenerated on every build.
#
# The second OUTPUT below is a file the command never creates, which is the
# standard way to force a custom command to re-run each time. Without it the
# timestamp would only move when something else triggered a rebuild of this
# rule, which is exactly the staleness the generator exists to avoid.
#
# Own directory rather than Zephyr's generated one: in this file
# PROJECT_BINARY_DIR is the build root, while Zephyr's headers land under
# build/zephyr/include/generated -- a distinction that is easy to get wrong and
# fails only at compile time.
set(SOPHON_GEN_DIR ${PROJECT_BINARY_DIR}/sophon_generated)
set(SOPHON_BUILD_TIME_H ${SOPHON_GEN_DIR}/sophon_build_time.h)

add_custom_command(
  OUTPUT ${SOPHON_BUILD_TIME_H} sophon_build_time_always
  COMMAND ${CMAKE_COMMAND} -DOUT_FILE=${SOPHON_BUILD_TIME_H}
          -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/gen_build_time.cmake
  COMMENT "Generating Sophon build timestamp"
)
add_custom_target(sophon_build_time DEPENDS ${SOPHON_BUILD_TIME_H})
add_dependencies(app sophon_build_time)
target_include_directories(app PRIVATE ${SOPHON_GEN_DIR})
