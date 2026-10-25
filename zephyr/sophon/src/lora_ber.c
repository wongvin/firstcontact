/*
 * The bit-error test's codec and measurement (#359). See lora_ber.h and
 * TRANSPORTER-PLAN.md.
 */

#include <errno.h>
#include <string.h>

#include "lora_ber.h"

static uint8_t crc8_update(uint8_t crc, const uint8_t *p, size_t n)
{
	for (size_t i = 0; i < n; i++) {
		crc ^= p[i];
		for (int b = 0; b < 8; b++) {
			crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0x07) : (uint8_t)(crc << 1);
		}
	}
	return crc;
}

uint8_t lora_ber_hcrc(const uint8_t hash[LORA_BER_HASH_SIZE], const uint8_t hdr[8])
{
	return crc8_update(crc8_update(0, hash, LORA_BER_HASH_SIZE), hdr, 8);
}

static void put_header(const struct lora_ber_image *img, const struct lora_ber_header *h,
		       uint8_t out[LORA_BER_HEADER])
{
	out[0] = LORA_TYPE_BER;
	out[1] = (uint8_t)h->tx_id;
	out[2] = (uint8_t)(h->tx_id >> 8);
	out[3] = (uint8_t)h->pseq;
	out[4] = (uint8_t)(h->pseq >> 8);
	out[5] = (uint8_t)h->offset;
	out[6] = (uint8_t)(h->offset >> 8);
	out[7] = (uint8_t)(h->offset >> 16);
	out[8] = lora_ber_hcrc(img->hash, out);
}

int lora_ber_encode(const struct lora_ber_image *img, const struct lora_ber_header *h, uint8_t *buf,
		    size_t len)
{
	if (len <= LORA_BER_HEADER || len > LORA_BER_PACKET_MAX || img->len == 0) {
		return -EINVAL;
	}
	put_header(img, h, buf);
	return img->read(h->offset % img->len, buf + LORA_BER_HEADER, len - LORA_BER_HEADER,
			 img->ctx);
}

bool lora_ber_header_ok(const uint8_t *buf, size_t len, const uint8_t hash[LORA_BER_HASH_SIZE],
			struct lora_ber_header *out)
{
	if (len <= LORA_BER_HEADER || buf[0] != LORA_TYPE_BER ||
	    lora_ber_hcrc(hash, buf) != buf[8]) {
		return false;
	}
	out->tx_id = (uint16_t)(buf[1] | (buf[2] << 8));
	out->pseq = (uint16_t)(buf[3] | (buf[4] << 8));
	out->offset = (uint32_t)buf[5] | ((uint32_t)buf[6] << 8) | ((uint32_t)buf[7] << 16);
	return true;
}

uint16_t lora_ber_lost(uint16_t delta, uint16_t counted, uint16_t between)
{
	uint16_t gap;

	if (delta <= counted) {
		return 0;
	}
	gap = (uint16_t)(delta - counted - 1U);
	return gap > between ? (uint16_t)(gap - between) : 0U;
}

uint32_t lora_ber_bit_errors(const uint8_t *a, const uint8_t *b, size_t len)
{
	uint32_t n = 0;

	for (size_t i = 0; i < len; i++) {
		uint8_t x = a[i] ^ b[i];

		while (x) {
			x &= (uint8_t)(x - 1);
			n++;
		}
	}
	return n;
}

static bool plausible(uint32_t errors, size_t len)
{
	return errors <= len * 8 / LORA_BER_PLAUSIBLE_DIV;
}

/* The header the transporter sent delta packets after the anchor's. */
static struct lora_ber_header after(const struct lora_ber_image *img,
				    const struct lora_ber_anchor *a, uint16_t delta, size_t len)
{
	uint32_t n = (uint32_t)(len - LORA_BER_HEADER);
	struct lora_ber_header h = {
		.tx_id = a->hdr.tx_id,
		.pseq = (uint16_t)(a->hdr.pseq + delta),
		.offset = (uint32_t)((a->hdr.offset + (uint64_t)delta * n) % img->len),
	};

	return h;
}

int lora_ber_measure(const struct lora_ber_image *img, const struct lora_ber_anchor *anchor,
		     uint16_t repair_max, uint16_t count_max, const uint8_t *rx, size_t len,
		     struct lora_ber_result *out)
{
	uint8_t expect[LORA_BER_PACKET_MAX];
	struct lora_ber_header h;
	bool anchored = anchor != NULL && anchor->valid && anchor->len == len;
	int err;

	memset(out, 0, sizeof(*out));
	out->kind = LORA_BER_UNRESOLVED;
	if (len <= LORA_BER_HEADER || len > LORA_BER_PACKET_MAX || img->len == 0) {
		return 0;
	}

	/*
	 * The fast path. A header that passes hcrc is trusted only if the bits it
	 * implies are plausible: CRC-8 lets about 1 in 256 damaged headers through.
	 */
	if (lora_ber_header_ok(rx, len, img->hash, &h) && h.offset < img->len) {
		err = lora_ber_encode(img, &h, expect, len);
		if (err) {
			return err;
		}
		uint32_t errors = lora_ber_bit_errors(rx, expect, len);

		if (plausible(errors, len)) {
			out->kind = LORA_BER_GOOD;
			out->hdr = h;
			out->bit_errors = errors;
			if (anchored && h.tx_id == anchor->hdr.tx_id) {
				uint16_t delta = (uint16_t)(h.pseq - anchor->hdr.pseq);
				struct lora_ber_header want = after(img, anchor, delta, len);

				if (delta >= 1 && delta <= count_max && want.offset == h.offset) {
					out->delta = delta;
				}
			}
			return 0;
		}
	}

	/* Repair: the closest whole packet the transporter could have sent. */
	if (!anchored) {
		return 0;
	}
	uint32_t best = UINT32_MAX;
	uint16_t best_delta = 0;

	for (uint16_t delta = 1; delta <= repair_max; delta++) {
		struct lora_ber_header cand = after(img, anchor, delta, len);
		uint32_t errors;

		err = lora_ber_encode(img, &cand, expect, len);
		if (err) {
			return err;
		}
		errors = lora_ber_bit_errors(rx, expect, len);
		if (errors < best) {
			best = errors;
			best_delta = delta;
		}
	}
	if (best_delta != 0 && plausible(best, len)) {
		out->kind = LORA_BER_REPAIRED;
		out->hdr = after(img, anchor, best_delta, len);
		out->bit_errors = best;
		out->delta = best_delta;
	}
	return 0;
}
