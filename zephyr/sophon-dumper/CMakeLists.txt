cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(sophon_dumper)

# Same guard, and the same two traps, as the other two apps here -- see
# ../sophon/CMakeLists.txt for why ZEPHYR_VERSION_CODE and not the CONFIG_
# spelling, and why ZEPHYR_VERSION is a boolean rather than a version string.
set(SOPHON_MIN_ZEPHYR_CODE 263168) # 4.4.0

if(ZEPHYR_VERSION_CODE LESS SOPHON_MIN_ZEPHYR_CODE)
  message(FATAL_ERROR
    "Sophon requires Zephyr >= 4.4.0; found ${PROJECT_VERSION_STR} at ${ZEPHYR_BASE}. "
    "Run 'west update' in ~/zephyrproject.")
endif()

target_sources(app PRIVATE src/main.c)
