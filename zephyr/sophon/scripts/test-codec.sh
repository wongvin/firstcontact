#!/usr/bin/env bash
#
# Host tests for the LoRa packet codec (#303) and the bit-error test (#359):
# builds src/lora_codec.c and src/lora_ber.c with the Mac's own compiler and runs
# tests/lora_codec/test_codec.c and tests/lora_ber/test_ber.c against them.
#
# A host test rather than twister: Zephyr's native_sim needs a Linux host, and
# the codec is deliberately plain C99 with no Zephyr headers so it does not need
# one. Built with -Werror and the address and undefined-behaviour sanitizers, so
# an out-of-bounds read in a decoder fed a hostile length fails the run rather
# than passing by luck.
#
# Usage: scripts/test-codec.sh

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

CFLAGS=(-std=c99 -Wall -Wextra -Werror -O1 -g
  -fsanitize=address,undefined -fno-sanitize-recover=all
  -I "$APP_DIR/src")

cc "${CFLAGS[@]}" "$APP_DIR/src/lora_codec.c" "$APP_DIR/tests/lora_codec/test_codec.c" \
  -o "$OUT/test_codec"
cc "${CFLAGS[@]}" "$APP_DIR/src/lora_ber.c" "$APP_DIR/tests/lora_ber/test_ber.c" \
  -o "$OUT/test_ber"
cc "${CFLAGS[@]}" "$APP_DIR/src/lora_lock.c" "$APP_DIR/tests/lora_lock/test_lock.c" \
  -o "$OUT/test_lock"

"$OUT/test_codec"
"$OUT/test_ber"
"$OUT/test_lock"
