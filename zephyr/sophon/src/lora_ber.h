/*
 * The bit-error test (#359): a transporter sends its own running image over
 * LoRa with the payload CRC off, and a gateway compares every bit it receives
 * with its own copy. TRANSPORTER-PLAN.md is the design; LORA-PROTOCOL.md
 * § Bit-error test is the byte-level contract, and this file and that section
 * must agree.
 *
 * Plain C99 with no Zephyr headers, so it builds and is tested on the host
 * (scripts/test-codec.sh). The image is reached only through a read callback.
 */

#ifndef SOPHON_LORA_BER_H
#define SOPHON_LORA_BER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Format 11 in the type byte (LORA-PROTOCOL.md § Type byte); no flag bits. */
#define LORA_TYPE_BER 0x5C

#define LORA_BER_HEADER     9
#define LORA_BER_HASH_SIZE  32
/* A LoRa payload is at most 255 bytes. */
#define LORA_BER_PACKET_MAX 255

/*
 * A packet whose best match is wrong in more than 1 bit in this many is not a
 * plausible copy of the image: unrelated data is wrong in about half its bits.
 */
#define LORA_BER_PLAUSIBLE_DIV 4

/* Reads len bytes of the image starting at off, wrapping at its end. */
typedef int (*lora_ber_read_fn)(uint32_t off, uint8_t *buf, size_t len, void *ctx);

/* The image a board sends or compares against: its own. */
struct lora_ber_image {
	const uint8_t *hash; /* LORA_BER_HASH_SIZE bytes: seeds hcrc */
	uint32_t len;        /* L = ih_hdr_size + ih_img_size */
	lora_ber_read_fn read;
	void *ctx;
};

struct lora_ber_header {
	uint16_t tx_id;
	uint16_t pseq;
	uint32_t offset; /* u24 on the wire */
};

/* The last packet whose hcrc passed and whose bits were plausible. */
struct lora_ber_anchor {
	bool valid;
	struct lora_ber_header hdr;
	uint8_t len; /* its packet length, PL */
};

enum lora_ber_kind {
	LORA_BER_GOOD,       /* hcrc passed: the header is trusted, and becomes the anchor */
	LORA_BER_REPAIRED,   /* hcrc failed; the header was recovered from the anchor */
	LORA_BER_UNRESOLVED, /* not compared: no anchor, or nothing plausible */
};

struct lora_ber_result {
	enum lora_ber_kind kind;
	struct lora_ber_header hdr; /* the true header: received, or recovered */
	uint32_t bit_errors;        /* over all len * 8 bits; 0 when unresolved */
	/*
	 * Packets the transporter sent since the anchor, this one included: 1 is
	 * the next packet. 0 when it can't be counted (no anchor, a restart, a long
	 * gap). Losses are the caller's to work out from it: a repaired packet
	 * doesn't move the anchor, so the next one's delta includes it.
	 */
	uint16_t delta;
};

/* CRC-8, poly 0x07, init 0, run over the image hash and then header bytes 0-7. */
uint8_t lora_ber_hcrc(const uint8_t hash[LORA_BER_HASH_SIZE], const uint8_t hdr[8]);

/*
 * Build a whole packet of len bytes: the header for h, then the image bytes
 * from h->offset onwards, wrapping at the image's end. Returns 0, -EINVAL for a
 * len that holds no image byte or exceeds LORA_BER_PACKET_MAX, or the read's
 * error.
 */
int lora_ber_encode(const struct lora_ber_image *img, const struct lora_ber_header *h, uint8_t *buf,
		    size_t len);

/* The header, if the type is LORA_TYPE_BER and hcrc matches this image's hash. */
bool lora_ber_header_ok(const uint8_t *buf, size_t len, const uint8_t hash[LORA_BER_HASH_SIZE],
			struct lora_ber_header *out);

/*
 * Packets lost before one accounted at delta, the last accounted being at
 * counted. Of the delta - counted - 1 between them, `between` were heard but
 * couldn't be resolved: counted as unresolved, so not lost too (#359 review,
 * finding 2). Never negative.
 */
uint16_t lora_ber_lost(uint16_t delta, uint16_t counted, uint16_t between);

/* Bits that differ between a and b. */
uint32_t lora_ber_bit_errors(const uint8_t *a, const uint8_t *b, size_t len);

/*
 * Measure one received packet against the image (TRANSPORTER-PLAN.md § Header
 * damage):
 *  - hcrc passes and the bits are plausible: GOOD. delta is set when the
 *    header follows on from the anchor (same transporter, the offset that
 *    pseq implies, at most count_max packets on); otherwise it's a restart or
 *    a long gap, and delta is 0.
 *  - otherwise, with an anchor of the same length: try delta = 1..repair_max,
 *    keep the closest whole packet, and if it's plausible, REPAIRED.
 *  - otherwise UNRESOLVED.
 * anchor may be NULL or invalid. Returns 0, or a read error.
 */
int lora_ber_measure(const struct lora_ber_image *img, const struct lora_ber_anchor *anchor,
		     uint16_t repair_max, uint16_t count_max, const uint8_t *rx, size_t len,
		     struct lora_ber_result *out);

#endif /* SOPHON_LORA_BER_H */
