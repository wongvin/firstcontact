/*
 * Sophon LoRa packet codec (#303). Contract: LORA-PROTOCOL.md § Packet formats.
 *
 * Everything is assembled byte by byte rather than through packed structs, so
 * the code is endian-independent and builds unchanged on the host for the test.
 */

#include <errno.h>
#include <string.h>

#include "lora_codec.h"

/* Offsets inside an 18-byte wire frame (PROTOCOL.md). */
#define FRAME_SEQ  0
#define FRAME_T_MS 2
#define FRAME_AXES 6
#define AXES_LEN   12

static uint16_t get_le16(const uint8_t *p)
{
	return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t get_le32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
	       ((uint32_t)p[3] << 24);
}

static void put_le16(uint8_t *p, uint16_t v)
{
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
}

static void put_le32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
	p[2] = (uint8_t)(v >> 16);
	p[3] = (uint8_t)(v >> 24);
}

uint16_t lora_frame_seq(const uint8_t frame[LORA_FRAME_SIZE])
{
	return get_le16(&frame[FRAME_SEQ]);
}

uint32_t lora_frame_t_ms(const uint8_t frame[LORA_FRAME_SIZE])
{
	return get_le32(&frame[FRAME_T_MS]);
}

static void put_status(uint8_t *p, const struct lora_status *s)
{
	put_le16(&p[0], s->sensor_id);
	p[2] = s->flags;
	put_le16(&p[3], s->batt_mv);
	put_le16(&p[5], s->batt_age_s);
}

static void get_status(const uint8_t *p, struct lora_status *s)
{
	s->sensor_id = get_le16(&p[0]);
	s->flags = p[2];
	s->batt_mv = get_le16(&p[3]);
	s->batt_age_s = get_le16(&p[5]);
}

/*
 * Packing rules 2 and 3: does next follow prev closely enough to share a v2
 * packet? seq must be exactly one on (mod 2^16) and the t_ms step must fit the
 * u8 dt. Unsigned subtraction makes both correct across their wraps.
 */
static bool v2_follows(const uint8_t prev[LORA_FRAME_SIZE], const uint8_t next[LORA_FRAME_SIZE])
{
	uint16_t dseq = (uint16_t)(lora_frame_seq(next) - lora_frame_seq(prev));
	uint32_t dt = lora_frame_t_ms(next) - lora_frame_t_ms(prev);

	return dseq == 1 && dt <= 255;
}

bool lora_codec_v2_can_append(const struct lora_packet *pkt, const uint8_t frame[LORA_FRAME_SIZE],
			      uint8_t k)
{
	if (pkt->count == 0) {
		return k > 0;
	}
	if (pkt->count >= k || pkt->count >= LORA_K_LIMIT) {
		return false; /* rule 1 */
	}
	return v2_follows(pkt->frames[pkt->count - 1], frame);
}

static int encode_v1(const struct lora_packet *pkt, uint8_t *buf, size_t cap)
{
	size_t len = LORA_V1_HEADER + (size_t)pkt->count * LORA_FRAME_SIZE;

	if (!pkt->has_status || pkt->has_test) {
		return -EINVAL;
	}
	if (cap < len) {
		return -ENOSPC;
	}

	buf[0] = LORA_TYPE_V1;
	put_le16(&buf[1], pkt->status.sensor_id);
	buf[3] = pkt->status.flags;
	put_le16(&buf[4], pkt->status.batt_mv);
	put_le16(&buf[6], pkt->status.batt_age_s);
	buf[8] = pkt->count;
	for (uint8_t i = 0; i < pkt->count; i++) {
		memcpy(&buf[LORA_V1_HEADER + i * LORA_FRAME_SIZE], pkt->frames[i], LORA_FRAME_SIZE);
	}
	return (int)len;
}

static int encode_v2(const struct lora_packet *pkt, uint8_t *buf, size_t cap)
{
	size_t len = LORA_V2_HEADER + (size_t)pkt->count * LORA_V2_RECORD +
		     (pkt->has_status ? LORA_STATUS_LEN : 0) + (pkt->has_test ? LORA_TEST_LEN : 0);
	uint8_t *p;

	for (uint8_t i = 1; i < pkt->count; i++) {
		if (!v2_follows(pkt->frames[i - 1], pkt->frames[i])) {
			return -EINVAL;
		}
	}
	if (cap < len) {
		return -ENOSPC;
	}

	buf[0] = LORA_TYPE_V2 | (pkt->has_test ? LORA_FLAG_TEST : 0) |
		 (pkt->has_status ? LORA_FLAG_STATUS : 0);
	put_le16(&buf[1], lora_frame_seq(pkt->frames[0]));
	put_le32(&buf[3], lora_frame_t_ms(pkt->frames[0]));
	buf[7] = pkt->count;

	p = &buf[LORA_V2_HEADER];
	for (uint8_t i = 0; i < pkt->count; i++) {
		p[0] = (i == 0) ? 0
				: (uint8_t)(lora_frame_t_ms(pkt->frames[i]) -
					    lora_frame_t_ms(pkt->frames[i - 1]));
		memcpy(&p[1], &pkt->frames[i][FRAME_AXES], AXES_LEN);
		p += LORA_V2_RECORD;
	}
	if (pkt->has_status) {
		put_status(p, &pkt->status);
		p += LORA_STATUS_LEN;
	}
	if (pkt->has_test) {
		p[0] = pkt->test.variant;
		put_le16(&p[1], pkt->test.vcount);
		p[3] = pkt->test.sf_switch_s;
	}
	return (int)len;
}

int lora_codec_encode(const struct lora_packet *pkt, uint8_t *buf, size_t cap)
{
	if (pkt->count == 0 || pkt->count > LORA_K_LIMIT) {
		return -EINVAL;
	}

	switch (pkt->format) {
	case LORA_FORMAT_V1:
		return encode_v1(pkt, buf, cap);
	case LORA_FORMAT_V2:
		return encode_v2(pkt, buf, cap);
	default:
		return -EINVAL;
	}
}

static int decode_v1(const uint8_t *buf, size_t len, uint8_t k_max, struct lora_packet *out)
{
	uint8_t count;

	if (buf[0] != LORA_TYPE_V1 || len < LORA_V1_HEADER) {
		return -EINVAL; /* v1 carries no trailer flags */
	}
	count = buf[8];
	if (count == 0 || count > k_max ||
	    len != LORA_V1_HEADER + (size_t)count * LORA_FRAME_SIZE) {
		return -EINVAL;
	}

	out->format = LORA_FORMAT_V1;
	out->count = count;
	out->has_status = true;
	out->status.sensor_id = get_le16(&buf[1]);
	out->status.flags = buf[3];
	out->status.batt_mv = get_le16(&buf[4]);
	out->status.batt_age_s = get_le16(&buf[6]);
	out->has_test = false;
	for (uint8_t i = 0; i < count; i++) {
		memcpy(out->frames[i], &buf[LORA_V1_HEADER + i * LORA_FRAME_SIZE], LORA_FRAME_SIZE);
	}
	return 0;
}

static int decode_v2(const uint8_t *buf, size_t len, uint8_t k_max, struct lora_packet *out)
{
	bool has_status = (buf[0] & LORA_FLAG_STATUS) != 0;
	bool has_test = (buf[0] & LORA_FLAG_TEST) != 0;
	const uint8_t *p;
	uint16_t seq0;
	uint32_t t;
	uint8_t count;

	if (len < LORA_V2_HEADER) {
		return -EINVAL;
	}
	count = buf[7];
	if (count == 0 || count > k_max ||
	    len != LORA_V2_HEADER + (size_t)count * LORA_V2_RECORD +
			    (has_status ? LORA_STATUS_LEN : 0) + (has_test ? LORA_TEST_LEN : 0)) {
		return -EINVAL;
	}

	seq0 = get_le16(&buf[1]);
	t = get_le32(&buf[3]);
	p = &buf[LORA_V2_HEADER];

	out->format = LORA_FORMAT_V2;
	out->count = count;
	for (uint8_t i = 0; i < count; i++) {
		uint8_t *f = out->frames[i];

		/* Record 0's dt is 0 by contract; adding it anyway keeps the
		 * reconstruction a single rule, t = t0 + sum(dt). */
		t += p[0];
		put_le16(&f[FRAME_SEQ], (uint16_t)(seq0 + i));
		put_le32(&f[FRAME_T_MS], t);
		memcpy(&f[FRAME_AXES], &p[1], AXES_LEN);
		p += LORA_V2_RECORD;
	}

	out->has_status = has_status;
	if (has_status) {
		get_status(p, &out->status);
		p += LORA_STATUS_LEN;
	}
	out->has_test = has_test;
	if (has_test) {
		out->test.variant = p[0];
		out->test.vcount = get_le16(&p[1]);
		out->test.sf_switch_s = p[3];
	}
	return 0;
}

int lora_codec_decode(const uint8_t *buf, size_t len, uint8_t k_max, struct lora_packet *out)
{
	if (len < 1 || (buf[0] & 0xF0) != LORA_TYPE_MARKER || k_max > LORA_K_LIMIT) {
		return -EINVAL;
	}

	switch (buf[0] & 0x0C) {
	case LORA_TYPE_V1 & 0x0C:
		return decode_v1(buf, len, k_max, out);
	case LORA_TYPE_V2 & 0x0C:
		return decode_v2(buf, len, k_max, out);
	default:
		return -EINVAL; /* 00 and 11 are reserved */
	}
}
