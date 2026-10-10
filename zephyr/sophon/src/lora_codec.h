/*
 * Sophon LoRa packet codec (#303) -- v1 and the compact v2.
 *
 * The byte-level contract is LORA-PROTOCOL.md § Packet formats; this file and
 * that section must agree. Plain C99 with no Zephyr headers, so it builds and is
 * tested on the host (scripts/test-codec.sh).
 *
 * Frames are handled as their 18-byte little-endian wire form -- exactly the
 * bytes of a struct sophon_frame on this target, and exactly what the gateway
 * notifies to the app. The codec never interprets the axes; it copies them.
 */

#ifndef SOPHON_LORA_CODEC_H
#define SOPHON_LORA_CODEC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define LORA_FRAME_SIZE 18

/* Upper bound on samples per packet the codec will ever hold. A preset's k is
 * at most this; the decoder is also given the k_max it should enforce. */
#define LORA_K_LIMIT 15

/* Type byte: marker in bits 7-4, format in bits 3-2, trailer flags in 1-0. */
#define LORA_TYPE_MARKER 0x50
#define LORA_TYPE_V1     0x54
#define LORA_TYPE_V2     0x58
#define LORA_FLAG_TEST   0x02
#define LORA_FLAG_STATUS 0x01

#define LORA_V1_HEADER  9
#define LORA_V2_HEADER  8
#define LORA_V2_RECORD  13
#define LORA_STATUS_LEN 7
#define LORA_TEST_LEN   4

/* Largest packet the codec can produce: v1 at LORA_K_LIMIT. */
#define LORA_PACKET_MAX (LORA_V1_HEADER + LORA_FRAME_SIZE * LORA_K_LIMIT)

enum lora_format {
	LORA_FORMAT_V1 = 1,
	LORA_FORMAT_V2 = 2,
};

struct lora_status {
	uint16_t sensor_id;  /* low 16 bits of the sensor's FICR id */
	uint8_t flags;       /* bit 0 = USB powered */
	uint16_t batt_mv;    /* 0 = no reading */
	uint16_t batt_age_s; /* seconds since that reading */
};

struct lora_test {
	uint8_t variant;     /* preset id */
	uint16_t vcount;     /* this variant's own packet counter */
	uint8_t sf_switch_s; /* seconds to the next SF block switch */
};

struct lora_packet {
	enum lora_format format;
	uint8_t count;
	uint8_t frames[LORA_K_LIMIT][LORA_FRAME_SIZE];
	/* v1 always carries status in its header; v2 only when has_status. */
	bool has_status;
	struct lora_status status;
	bool has_test; /* v2 only */
	struct lora_test test;
};

/*
 * Encode into buf. Returns the payload length, or a negative errno:
 *   -EINVAL  count outside 1..LORA_K_LIMIT, v1 without status, v1 with a test
 *            trailer, or a v2 run that breaks the packing rules (seq not
 *            consecutive, or a t_ms step over 255 ms)
 *   -ENOSPC  cap too small
 */
int lora_codec_encode(const struct lora_packet *pkt, uint8_t *buf, size_t cap);

/*
 * Decode len bytes. Returns 0, or -EINVAL for anything the spec says to drop:
 * wrong marker, reserved format, v1 with trailer flags set, count of 0 or above
 * k_max, or a length that does not match the length rule. On success the
 * frames are rebuilt exactly -- v2's seq0 + i and t0 + sum(dt).
 */
int lora_codec_decode(const uint8_t *buf, size_t len, uint8_t k_max, struct lora_packet *out);

/*
 * Packing rules 1-3 (LORA-PROTOCOL.md): may frame join a v2 packet that
 * currently holds pkt->count frames, for a preset with k samples? False means
 * close the current packet first. Rule 4, the flush timer, is the caller's.
 */
bool lora_codec_v2_can_append(const struct lora_packet *pkt, const uint8_t frame[LORA_FRAME_SIZE],
			      uint8_t k);

/* Wire-frame field accessors, for callers and tests. */
uint16_t lora_frame_seq(const uint8_t frame[LORA_FRAME_SIZE]);
uint32_t lora_frame_t_ms(const uint8_t frame[LORA_FRAME_SIZE]);

#endif /* SOPHON_LORA_CODEC_H */
