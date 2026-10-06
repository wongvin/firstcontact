cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(sophon_installer)

# Same guard, and the same two traps, as the Sophon app's CMakeLists -- see
# ../sophon/CMakeLists.txt for why ZEPHYR_VERSION_CODE and not the CONFIG_
# spelling, and why ZEPHYR_VERSION is a boolean rather than a version string.
set(SOPHON_MIN_ZEPHYR_CODE 263168) # 4.4.0

if(ZEPHYR_VERSION_CODE LESS SOPHON_MIN_ZEPHYR_CODE)
  message(FATAL_ERROR
    "Sophon requires Zephyr >= 4.4.0; found ${PROJECT_VERSION_STR} at ${ZEPHYR_BASE}. "
    "Run 'west update' in ~/zephyrproject.")
endif()

#
# MCUboot travels INSIDE this binary; the application does not.
#
# UF2-MIGRATION.md, "Building the UF2", is the argument: 40 KB is small enough
# that the linker does not care, it travels with the code that writes it, and
# there is no second address to keep in step. The 190 KB application is merged
# in as hex records at 0x085000 instead, by scripts/mkuf2.sh, because it is the
# artefact most likely to change and its address is dictated by MCUboot rather
# than chosen.
#
# Built by the Sophon app's own MCUboot build, not by this one. That is a real
# coupling and it is deliberate -- the blob must be the bootloader that signs
# against the project key (#274), so building a second one here would invite
# the two to drift. Fail loudly at configure time rather than embedding a stale
# or absent file.
set(SOPHON_MCUBOOT_BIN
    "${CMAKE_CURRENT_SOURCE_DIR}/../sophon/build-mcuboot/mcuboot/zephyr/zephyr.bin"
    CACHE FILEPATH "MCUboot binary to embed as the installer's payload")

if(NOT EXISTS "${SOPHON_MCUBOOT_BIN}")
  message(FATAL_ERROR
    "MCUboot blob not found at ${SOPHON_MCUBOOT_BIN}\n"
    "  Build it first:  SOPHON_BOOT=mcuboot ../sophon/scripts/build.sh\n"
    "  Or point at one: -DSOPHON_MCUBOOT_BIN=/path/to/zephyr.bin")
endif()

target_sources(app PRIVATE src/main.c)

# Zephyr's own byte-array generator rather than a hand-rolled one. It emits a
# comma-separated list for #include inside an initialiser, and re-runs when the
# input changes.
generate_inc_file_for_target(app
  "${SOPHON_MCUBOOT_BIN}"
  "${ZEPHYR_BINARY_DIR}/include/generated/mcuboot_blob.inc")
