/*
 * Sophon motion frame — the wire contract with the iOS central.
 *
 * 18 bytes, little-endian. See PROTOCOL.md; the iOS decoder is
 * ios/Sophon/Sophon/BLE/SophonProtocol.swift and must agree byte for byte.
 */

#ifndef SOPHON_FRAME_H
#define SOPHON_FRAME_H

#include <stdint.h>
#include <zephyr/sys/util.h>

#define SOPHON_FRAME_SIZE 18

struct sophon_frame {
	uint16_t seq;   /* wraps at 65535 */
	uint32_t t_ms;  /* ms since boot, this board only */
	int16_t ax;     /* milli-g */
	int16_t ay;
	int16_t az;
	int16_t gx;     /* centi-deg/s */
	int16_t gy;
	int16_t gz;
} __packed;

BUILD_ASSERT(sizeof(struct sophon_frame) == SOPHON_FRAME_SIZE,
	     "Sophon frame must be exactly 18 bytes on the wire");

/*
 * nRF52840 is little-endian, so the packed struct is already in wire order and
 * the notify path can hand this struct straight to the stack. That is only true
 * on a little-endian target -- assert it rather than assume it, so a future port
 * fails at compile time instead of the phone silently decoding byte-swapped
 * garbage.
 */
BUILD_ASSERT(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__,
	     "Sophon frame is little-endian on the wire; this target is not");

#endif /* SOPHON_FRAME_H */
