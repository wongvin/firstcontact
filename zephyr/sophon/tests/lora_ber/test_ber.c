/*
 * Host test for src/lora_ber.c (#359). Run with scripts/test-codec.sh.
 *
 * The worked example is the one in LORA-PROTOCOL.md § Bit-error test; its hcrc
 * was computed independently (Python), so this test pins the document and the
 * code to each other.
 */

#include <errno.h>
#include <stdio.h>
#include <string.h>

#include "lora_ber.h"

static int failures;
static int checks;

#define CHECK(cond)                                                                                \
	do {                                                                                       \
		checks++;                                                                          \
		if (!(cond)) {                                                                     \
			failures++;                                                                \
			printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                     \
		}                                                                                  \
	} while (0)

/* A fake image: bytes from a small LCG, so no two stretches look alike. */
#define IMAGE_LEN 1000
static uint8_t image[IMAGE_LEN];
static uint8_t hash[LORA_BER_HASH_SIZE];
static uint8_t other_hash[LORA_BER_HASH_SIZE];

static int read_image(uint32_t off, uint8_t *buf, size_t len, void *ctx)
{
	const uint8_t *src = ctx;

	for (size_t i = 0; i < len; i++) {
		buf[i] = src[(off + i) % IMAGE_LEN];
	}
	return 0;
}

static const struct lora_ber_image img = {
	.hash = hash, .len = IMAGE_LEN, .read = read_image, .ctx = image};

/* The gateway's view of an image whose hash differs: same bytes, other seed. */
static const struct lora_ber_image other_img = {
	.hash = other_hash, .len = IMAGE_LEN, .read = read_image, .ctx = image};

#define PL 60 /* V6's packet length */
#define N  (PL - LORA_BER_HEADER)

static void setup(void)
{
	uint32_t x = 12345;

	for (int i = 0; i < IMAGE_LEN; i++) {
		x = x * 1103515245U + 12345U;
		image[i] = (uint8_t)(x >> 16);
	}
	for (int i = 0; i < LORA_BER_HASH_SIZE; i++) {
		hash[i] = (uint8_t)i;
		other_hash[i] = (uint8_t)i;
	}
	other_hash[0] = 0xFF;
}

static struct lora_ber_anchor anchor_at(uint16_t pseq, uint32_t offset)
{
	struct lora_ber_anchor a = {
		.valid = true, .hdr = {.tx_id = 0x1A2B, .pseq = pseq, .offset = offset}, .len = PL};

	return a;
}

/* The packet sent delta packets after the anchor. */
static void sent_after(const struct lora_ber_anchor *a, uint16_t delta, uint8_t *buf)
{
	struct lora_ber_header h = {
		.tx_id = a->hdr.tx_id,
		.pseq = (uint16_t)(a->hdr.pseq + delta),
		.offset = (a->hdr.offset + (uint32_t)delta * N) % IMAGE_LEN,
	};

	CHECK(lora_ber_encode(&img, &h, buf, PL) == 0);
}

static void test_lost(void)
{
	CHECK(lora_ber_lost(5, 0, 0) == 4);  /* four never arrived */
	CHECK(lora_ber_lost(5, 0, 2) == 2);  /* two of them were heard, unresolved */
	CHECK(lora_ber_lost(5, 0, 4) == 0);  /* all heard */
	CHECK(lora_ber_lost(5, 0, 9) == 0);  /* more unresolved than the gap: none */
	CHECK(lora_ber_lost(1, 0, 0) == 0);  /* the very next packet */
	CHECK(lora_ber_lost(7, 3, 1) == 2);  /* counted from the last accounted */
	CHECK(lora_ber_lost(3, 3, 0) == 0);  /* not past it */
	CHECK(lora_ber_lost(2, 5, 0) == 0);  /* behind it */
}

static void test_worked_example(void)
{
	/* hash = 00 01 .. 1F; tx_id 0x1A2B, pseq 0x0102, offset 0x000345. */
	const uint8_t want[LORA_BER_HEADER] = {0x5C, 0x2B, 0x1A, 0x02, 0x01, 0x45, 0x03, 0x00, 0x50};
	struct lora_ber_header h = {.tx_id = 0x1A2B, .pseq = 0x0102, .offset = 0x000345};
	uint8_t buf[PL];
	struct lora_ber_header back;

	CHECK(lora_ber_encode(&img, &h, buf, PL) == 0);
	CHECK(memcmp(buf, want, sizeof(want)) == 0);
	CHECK(memcmp(buf + LORA_BER_HEADER, image + 0x345, N) == 0);
	CHECK(lora_ber_header_ok(buf, PL, hash, &back));
	CHECK(back.tx_id == 0x1A2B && back.pseq == 0x0102 && back.offset == 0x345);
}

static void test_hcrc_seeded(void)
{
	const uint8_t hdr[8] = {0x5C, 0x2B, 0x1A, 0x02, 0x01, 0x45, 0x03, 0x00};
	struct lora_ber_header h = {.tx_id = 0x1A2B, .pseq = 0x0102, .offset = 0x000345};
	struct lora_ber_header back;
	uint8_t buf[PL];

	CHECK(lora_ber_hcrc(hash, hdr) == 0x50);
	CHECK(lora_ber_hcrc(other_hash, hdr) == 0x35); /* computed independently */
	CHECK(lora_ber_encode(&img, &h, buf, PL) == 0);
	CHECK(!lora_ber_header_ok(buf, PL, other_hash, &back));
}

static void test_encode_limits(void)
{
	struct lora_ber_header h = {0};
	uint8_t buf[LORA_BER_PACKET_MAX + 1];

	CHECK(lora_ber_encode(&img, &h, buf, LORA_BER_HEADER) == -EINVAL);
	CHECK(lora_ber_encode(&img, &h, buf, LORA_BER_PACKET_MAX + 1) == -EINVAL);
	CHECK(lora_ber_encode(&img, &h, buf, LORA_BER_HEADER + 1) == 0);
	CHECK(lora_ber_encode(&img, &h, buf, LORA_BER_PACKET_MAX) == 0);
}

static void test_wrap(void)
{
	/* A packet that starts 10 bytes before the end carries the last 10 and
	 * then the first N - 10. */
	struct lora_ber_header h = {.tx_id = 1, .pseq = 0, .offset = IMAGE_LEN - 10};
	uint8_t buf[PL];

	CHECK(lora_ber_encode(&img, &h, buf, PL) == 0);
	CHECK(memcmp(buf + LORA_BER_HEADER, image + IMAGE_LEN - 10, 10) == 0);
	CHECK(memcmp(buf + LORA_BER_HEADER + 10, image, N - 10) == 0);
}

static void test_bit_errors(void)
{
	uint8_t a[4] = {0x00, 0xFF, 0x0F, 0x80};
	uint8_t b[4] = {0x00, 0x00, 0x0F, 0x81};

	CHECK(lora_ber_bit_errors(a, a, 4) == 0);
	CHECK(lora_ber_bit_errors(a, b, 4) == 9);
}

static void test_clean(void)
{
	struct lora_ber_anchor a = anchor_at(100, 200);
	struct lora_ber_result r;
	uint8_t buf[PL];

	sent_after(&a, 1, buf);
	CHECK(lora_ber_measure(&img, &a, 64, 300, buf, PL, &r) == 0);
	CHECK(r.kind == LORA_BER_GOOD);
	CHECK(r.bit_errors == 0 && r.delta == 1);
	CHECK(r.hdr.pseq == 101 && r.hdr.offset == 200 + N);
}

static void test_no_anchor_good(void)
{
	struct lora_ber_anchor a = anchor_at(100, 200);
	struct lora_ber_result r;
	uint8_t buf[PL];

	sent_after(&a, 7, buf);
	CHECK(lora_ber_measure(&img, NULL, 64, 300, buf, PL, &r) == 0);
	CHECK(r.kind == LORA_BER_GOOD && r.delta == 0); /* nothing to count from */
}

static void test_payload_errors(void)
{
	struct lora_ber_anchor a = anchor_at(100, 200);
	struct lora_ber_result r;
	uint8_t buf[PL];

	/* A single bit, and a burst of 12 bits across two bytes. */
	sent_after(&a, 3, buf);
	buf[20] ^= 0x10;
	buf[40] ^= 0xFF;
	buf[41] ^= 0x0F;
	CHECK(lora_ber_measure(&img, &a, 64, 300, buf, PL, &r) == 0);
	CHECK(r.kind == LORA_BER_GOOD);
	CHECK(r.bit_errors == 13);
	CHECK(r.delta == 3);
}

static void test_header_repaired(void)
{
	struct lora_ber_anchor a = anchor_at(100, 200);
	struct lora_ber_result r;
	uint8_t buf[PL];

	/* Two bits in pseq and one in the payload: hcrc fails, repair finds
	 * delta 5 and counts all three bits. */
	sent_after(&a, 5, buf);
	buf[3] ^= 0x41;
	buf[30] ^= 0x02;
	CHECK(lora_ber_measure(&img, &a, 64, 300, buf, PL, &r) == 0);
	CHECK(r.kind == LORA_BER_REPAIRED);
	CHECK(r.bit_errors == 3);
	CHECK(r.delta == 5);
	CHECK(r.hdr.pseq == 105 && r.hdr.offset == (200 + 5 * N) % IMAGE_LEN);
}

static void test_type_byte_damaged(void)
{
	struct lora_ber_anchor a = anchor_at(100, 200);
	struct lora_ber_result r;
	uint8_t buf[PL];

	sent_after(&a, 2, buf);
	buf[0] ^= 0x01; /* 0x5D: no longer a BER packet's type */
	CHECK(lora_ber_measure(&img, &a, 64, 300, buf, PL, &r) == 0);
	CHECK(r.kind == LORA_BER_REPAIRED);
	CHECK(r.bit_errors == 1 && r.delta == 2);
}

static void test_repair_across_wrap(void)
{
	struct lora_ber_anchor a = anchor_at(0xFFFE, IMAGE_LEN - 20);
	struct lora_ber_result r;
	uint8_t buf[PL];

	/* pseq wraps past 0xFFFF and the offset past the image's end. */
	sent_after(&a, 3, buf);
	buf[8] ^= 0x80; /* hcrc itself */
	CHECK(lora_ber_measure(&img, &a, 64, 300, buf, PL, &r) == 0);
	CHECK(r.kind == LORA_BER_REPAIRED);
	CHECK(r.hdr.pseq == 0x0001);
	CHECK(r.hdr.offset == (IMAGE_LEN - 20 + 3 * N) % IMAGE_LEN);
	CHECK(r.bit_errors == 1 && r.delta == 3);
}

static void test_unresolved(void)
{
	struct lora_ber_anchor a = anchor_at(100, 200);
	struct lora_ber_result r;
	uint8_t buf[PL];

	/* Over a quarter of the bits wrong, with the header hit too. */
	sent_after(&a, 1, buf);
	for (int i = 0; i < PL; i += 2) {
		buf[i] ^= 0xFF;
	}
	CHECK(lora_ber_measure(&img, &a, 64, 300, buf, PL, &r) == 0);
	CHECK(r.kind == LORA_BER_UNRESOLVED);
	CHECK(r.bit_errors == 0 && r.delta == 0);

	/* Header damaged and no anchor: nothing to repair from. */
	sent_after(&a, 1, buf);
	buf[5] ^= 0x01;
	CHECK(lora_ber_measure(&img, NULL, 64, 300, buf, PL, &r) == 0);
	CHECK(r.kind == LORA_BER_UNRESOLVED);

	/* An anchor of another length can't be extrapolated. */
	struct lora_ber_anchor shorter = a;

	shorter.len = PL - 1;
	CHECK(lora_ber_measure(&img, &shorter, 64, 300, buf, PL, &r) == 0);
	CHECK(r.kind == LORA_BER_UNRESOLVED);

	/* Beyond repair_max. */
	sent_after(&a, 10, buf);
	buf[5] ^= 0x01;
	CHECK(lora_ber_measure(&img, &a, 8, 300, buf, PL, &r) == 0);
	CHECK(r.kind == LORA_BER_UNRESOLVED);
}

static void test_image_mismatch(void)
{
	/* The gateway's hash differs from the transporter's, so hcrc fails even
	 * on a clean packet. With no hcrc ever passing, no anchor forms and every
	 * packet stays unresolved: the gateway's mismatch-suspected signal. */
	struct lora_ber_anchor a = anchor_at(100, 200);
	struct lora_ber_result r;
	uint8_t buf[PL];

	sent_after(&a, 1, buf);
	CHECK(lora_ber_measure(&other_img, NULL, 64, 300, buf, PL, &r) == 0);
	CHECK(r.kind == LORA_BER_UNRESOLVED); /* no anchor can ever form */
}

static void test_restart_not_counted(void)
{
	struct lora_ber_anchor a = anchor_at(500, 700);
	struct lora_ber_result r;
	struct lora_ber_header h = {.tx_id = 0x1A2B, .pseq = 0, .offset = 0};
	uint8_t buf[PL];

	/* The transporter restarted: pseq and offset back to 0. Good, re-anchored,
	 * delta not countable. */
	CHECK(lora_ber_encode(&img, &h, buf, PL) == 0);
	CHECK(lora_ber_measure(&img, &a, 64, 300, buf, PL, &r) == 0);
	CHECK(r.kind == LORA_BER_GOOD && r.delta == 0 && r.bit_errors == 0);

	/* A gap longer than count_max isn't counted either. */
	sent_after(&a, 40, buf);
	CHECK(lora_ber_measure(&img, &a, 64, 30, buf, PL, &r) == 0);
	CHECK(r.kind == LORA_BER_GOOD && r.delta == 0);
}

static void test_crc_collision_rejected(void)
{
	/* A header whose hcrc passes but whose offset is wrong -- the 1-in-256
	 * case of damage CRC-8 misses. Its payload doesn't match that offset, so
	 * it isn't trusted; repair recovers the real one. */
	struct lora_ber_anchor a = anchor_at(100, 200);
	struct lora_ber_result r;
	uint8_t buf[PL];
	uint8_t hdr[8];

	sent_after(&a, 2, buf);
	buf[6] ^= 0x01; /* offset + 256 */
	memcpy(hdr, buf, 8);
	buf[8] = lora_ber_hcrc(hash, hdr); /* a matching hcrc, as if by chance */
	CHECK(lora_ber_measure(&img, &a, 64, 300, buf, PL, &r) == 0);
	CHECK(r.kind == LORA_BER_REPAIRED);
	CHECK(r.hdr.offset == 200 + 2 * N);
	CHECK(r.delta == 2);
}

int main(void)
{
	setup();
	test_worked_example();
	test_lost();
	test_hcrc_seeded();
	test_encode_limits();
	test_wrap();
	test_bit_errors();
	test_clean();
	test_no_anchor_good();
	test_payload_errors();
	test_header_repaired();
	test_type_byte_damaged();
	test_repair_across_wrap();
	test_unresolved();
	test_image_mismatch();
	test_restart_not_counted();
	test_crc_collision_rejected();

	printf("%d checks, %d failed\n", checks, failures);
	return failures ? 1 : 0;
}
