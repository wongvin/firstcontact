/*
 * Host test for src/lora_codec.c (#303). Run with scripts/test-codec.sh.
 *
 * The worked example is the one in LORA-PROTOCOL.md § Packet formats, so this
 * test pins the document and the code to each other.
 */

#include <errno.h>
#include <stdio.h>
#include <string.h>

#include "lora_codec.h"

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

static void make_frame(uint8_t f[LORA_FRAME_SIZE], uint16_t seq, uint32_t t_ms, int16_t ax,
		       int16_t ay, int16_t az, int16_t gx, int16_t gy, int16_t gz)
{
	int16_t axes[6] = {ax, ay, az, gx, gy, gz};

	f[0] = (uint8_t)seq;
	f[1] = (uint8_t)(seq >> 8);
	f[2] = (uint8_t)t_ms;
	f[3] = (uint8_t)(t_ms >> 8);
	f[4] = (uint8_t)(t_ms >> 16);
	f[5] = (uint8_t)(t_ms >> 24);
	for (int i = 0; i < 6; i++) {
		uint16_t v = (uint16_t)axes[i];

		f[6 + 2 * i] = (uint8_t)v;
		f[7 + 2 * i] = (uint8_t)(v >> 8);
	}
}

/* A v2 run of n frames: consecutive seq from seq0, t from t0 in steps of dt. */
static void make_run(struct lora_packet *p, uint8_t n, uint16_t seq0, uint32_t t0, uint32_t dt)
{
	memset(p, 0, sizeof(*p));
	p->format = LORA_FORMAT_V2;
	p->count = n;
	for (uint8_t i = 0; i < n; i++) {
		make_frame(p->frames[i], (uint16_t)(seq0 + i), t0 + i * dt, (int16_t)(i * 7 - 20),
			   (int16_t)-i, 1000, (int16_t)(150 + i), -30, (int16_t)i);
	}
}

static bool frames_equal(const struct lora_packet *a, const struct lora_packet *b)
{
	return a->count == b->count &&
	       memcmp(a->frames, b->frames, (size_t)a->count * LORA_FRAME_SIZE) == 0;
}

static void test_worked_example(void)
{
	/* LORA-PROTOCOL.md: k=4, seq0 0x1234, t0 100000, dt 0/18/19/18. */
	static const uint8_t header[] = {0x58, 0x34, 0x12, 0xa0, 0x86, 0x01, 0x00, 0x04};
	static const uint8_t rec0[] = {0x00, 0x0c, 0x00, 0xfb, 0xff, 0xea, 0x03,
				       0x96, 0x00, 0xe2, 0xff, 0x00, 0x00};
	static const uint32_t t[] = {100000, 100018, 100037, 100055};
	struct lora_packet p = {.format = LORA_FORMAT_V2, .count = 4};
	struct lora_packet d;
	uint8_t buf[LORA_PACKET_MAX];
	int len;

	make_frame(p.frames[0], 0x1234, t[0], 12, -5, 1002, 150, -30, 0);
	make_frame(p.frames[1], 0x1235, t[1], 14, -3, 1000, 148, -28, 2);
	make_frame(p.frames[2], 0x1236, t[2], 13, -6, 1003, 151, -31, 1);
	make_frame(p.frames[3], 0x1237, t[3], 12, -4, 1001, 149, -29, 0);

	len = lora_codec_encode(&p, buf, sizeof(buf));
	CHECK(len == 60);
	CHECK(memcmp(buf, header, sizeof(header)) == 0);
	CHECK(memcmp(&buf[8], rec0, sizeof(rec0)) == 0);
	CHECK(buf[8 + 13] == 18 && buf[8 + 26] == 19 && buf[8 + 39] == 18);

	CHECK(lora_codec_decode(buf, (size_t)len, 4, &d) == 0);
	CHECK(frames_equal(&p, &d));
	for (int i = 0; i < 4; i++) {
		CHECK(lora_frame_seq(d.frames[i]) == 0x1234 + i);
		CHECK(lora_frame_t_ms(d.frames[i]) == t[i]);
	}
	CHECK(!d.has_status && !d.has_test);
}

static void test_v2_trailers_all_types(void)
{
	static const uint8_t types[] = {0x58, 0x59, 0x5A, 0x5B};
	static const int lens[] = {60, 67, 64, 71}; /* LORA-PROTOCOL.md length table, k=4 */

	for (int i = 0; i < 4; i++) {
		struct lora_packet p, d;
		uint8_t buf[LORA_PACKET_MAX];
		int len;

		make_run(&p, 4, 500, 2000, 18);
		p.has_status = (types[i] & LORA_FLAG_STATUS) != 0;
		p.status = (struct lora_status){0x01A7, 1, 3991, 42};
		p.has_test = (types[i] & LORA_FLAG_TEST) != 0;
		p.test = (struct lora_test){7, 0xBEEF, 29};

		len = lora_codec_encode(&p, buf, sizeof(buf));
		CHECK(len == lens[i]);
		CHECK(buf[0] == types[i]);
		CHECK(lora_codec_decode(buf, (size_t)len, 4, &d) == 0);
		CHECK(frames_equal(&p, &d));
		CHECK(d.has_status == p.has_status && d.has_test == p.has_test);
		if (p.has_status) {
			CHECK(d.status.sensor_id == 0x01A7 && d.status.flags == 1 &&
			      d.status.batt_mv == 3991 && d.status.batt_age_s == 42);
		}
		if (p.has_test) {
			CHECK(d.test.variant == 7 && d.test.vcount == 0xBEEF &&
			      d.test.sf_switch_s == 29);
		}
	}
}

static void test_length_table(void)
{
	/* Every row of LORA-PROTOCOL.md's v2 length table. */
	static const uint8_t ks[] = {2, 4, 5, 10};
	static const int want[4][4] = {
		{34, 41, 38, 45}, {60, 67, 64, 71}, {73, 80, 77, 84}, {138, 145, 142, 149}};

	for (int r = 0; r < 4; r++) {
		for (int c = 0; c < 4; c++) {
			struct lora_packet p;
			uint8_t buf[LORA_PACKET_MAX];

			make_run(&p, ks[r], 1, 1, 18);
			p.has_status = (c & 1) != 0;
			p.has_test = (c & 2) != 0;
			CHECK(lora_codec_encode(&p, buf, sizeof(buf)) == want[r][c]);
		}
	}
}

static void test_v1_round_trip(void)
{
	struct lora_packet p, d;
	uint8_t buf[LORA_PACKET_MAX];
	int len;

	make_run(&p, 10, 65530, 12345, 18); /* also crosses the seq wrap */
	p.format = LORA_FORMAT_V1;
	p.has_status = true;
	p.status = (struct lora_status){0x86F0, 0, 4100, 5};

	len = lora_codec_encode(&p, buf, sizeof(buf));
	CHECK(len == 9 + 18 * 10); /* 189, variant V0 */
	CHECK(buf[0] == LORA_TYPE_V1);
	CHECK(lora_codec_decode(buf, (size_t)len, 10, &d) == 0);
	CHECK(d.format == LORA_FORMAT_V1 && frames_equal(&p, &d));
	CHECK(d.has_status && d.status.sensor_id == 0x86F0 && d.status.batt_mv == 4100);
}

static void test_wraps(void)
{
	struct lora_packet p, d;
	uint8_t buf[LORA_PACKET_MAX];
	int len;

	/* seq 0xFFFE, 0xFFFF, 0x0000, 0x0001 and t_ms crossing 2^32. */
	make_run(&p, 4, 0xFFFE, 0xFFFFFFE0u, 18);
	CHECK(lora_frame_t_ms(p.frames[3]) == 0x16u); /* wrapped */
	len = lora_codec_encode(&p, buf, sizeof(buf));
	CHECK(len == 60);
	CHECK(lora_codec_decode(buf, (size_t)len, 4, &d) == 0);
	CHECK(frames_equal(&p, &d));
	CHECK(lora_frame_seq(d.frames[2]) == 0x0000);
	CHECK(lora_frame_t_ms(d.frames[3]) == 0x16u);
}

static void test_packing_rules(void)
{
	struct lora_packet p;
	uint8_t f[LORA_FRAME_SIZE];

	memset(&p, 0, sizeof(p));
	p.format = LORA_FORMAT_V2;
	make_frame(f, 10, 1000, 0, 0, 0, 0, 0, 0);
	CHECK(lora_codec_v2_can_append(&p, f, 4)); /* empty packet takes anything */

	make_run(&p, 3, 10, 1000, 18);
	make_frame(f, 13, 1054 + 18, 0, 0, 0, 0, 0, 0);
	CHECK(lora_codec_v2_can_append(&p, f, 4)); /* next in line */

	make_run(&p, 4, 10, 1000, 18);
	make_frame(f, 14, 1072 + 18, 0, 0, 0, 0, 0, 0);
	CHECK(!lora_codec_v2_can_append(&p, f, 4)); /* rule 1: k reached */

	make_run(&p, 3, 10, 1000, 18);
	make_frame(f, 14, 1054, 0, 0, 0, 0, 0, 0);
	CHECK(!lora_codec_v2_can_append(&p, f, 4)); /* rule 2: seq skipped (13 dropped) */

	make_frame(f, 13, 1036 + 256, 0, 0, 0, 0, 0, 0);
	CHECK(!lora_codec_v2_can_append(&p, f, 4)); /* rule 3: dt 256 */
	make_frame(f, 13, 1036 + 255, 0, 0, 0, 0, 0, 0);
	CHECK(lora_codec_v2_can_append(&p, f, 4)); /* dt 255 still fits */

	make_run(&p, 1, 0xFFFF, 5, 18);
	make_frame(f, 0x0000, 23, 0, 0, 0, 0, 0, 0);
	CHECK(lora_codec_v2_can_append(&p, f, 4)); /* seq wrap is consecutive */
}

static void test_encode_rejects(void)
{
	struct lora_packet p;
	uint8_t buf[LORA_PACKET_MAX];

	make_run(&p, 4, 1, 1, 18);
	p.count = 0;
	CHECK(lora_codec_encode(&p, buf, sizeof(buf)) == -EINVAL);

	make_run(&p, 4, 1, 1, 18);
	make_frame(p.frames[2], 9, 37, 0, 0, 0, 0, 0, 0); /* seq gap inside a v2 packet */
	CHECK(lora_codec_encode(&p, buf, sizeof(buf)) == -EINVAL);

	make_run(&p, 3, 1, 1, 300); /* dt over 255 */
	CHECK(lora_codec_encode(&p, buf, sizeof(buf)) == -EINVAL);

	make_run(&p, 4, 1, 1, 18);
	p.format = LORA_FORMAT_V1; /* v1 without status */
	CHECK(lora_codec_encode(&p, buf, sizeof(buf)) == -EINVAL);
	p.has_status = true;
	p.has_test = true; /* v1 has no test trailer */
	CHECK(lora_codec_encode(&p, buf, sizeof(buf)) == -EINVAL);

	make_run(&p, 4, 1, 1, 18);
	CHECK(lora_codec_encode(&p, buf, 59) == -ENOSPC);
}

static void test_decode_rejects(void)
{
	struct lora_packet p, d;
	uint8_t buf[LORA_PACKET_MAX];
	int len;

	make_run(&p, 4, 1, 1, 18);
	len = lora_codec_encode(&p, buf, sizeof(buf));
	CHECK(lora_codec_decode(buf, (size_t)len, 4, &d) == 0);

	CHECK(lora_codec_decode(buf, (size_t)len - 1, 4, &d) == -EINVAL); /* short */
	CHECK(lora_codec_decode(buf, (size_t)len + 1, 4, &d) == -EINVAL); /* long */
	CHECK(lora_codec_decode(buf, (size_t)len, 3, &d) == -EINVAL);     /* count > k_max */
	CHECK(lora_codec_decode(buf, 0, 4, &d) == -EINVAL);

	buf[0] = 0x48; /* wrong marker */
	CHECK(lora_codec_decode(buf, (size_t)len, 4, &d) == -EINVAL);
	buf[0] = 0x50; /* format 00, reserved */
	CHECK(lora_codec_decode(buf, (size_t)len, 4, &d) == -EINVAL);
	buf[0] = 0x5C; /* format 11, reserved */
	CHECK(lora_codec_decode(buf, (size_t)len, 4, &d) == -EINVAL);
	buf[0] = 0x59; /* claims a status trailer the length does not have */
	CHECK(lora_codec_decode(buf, (size_t)len, 4, &d) == -EINVAL);
	buf[0] = 0x58;
	buf[7] = 0; /* count 0 */
	CHECK(lora_codec_decode(buf, (size_t)len, 4, &d) == -EINVAL);

	/* v1 with a trailer flag set is not v1. */
	make_run(&p, 2, 1, 1, 18);
	p.format = LORA_FORMAT_V1;
	p.has_status = true;
	len = lora_codec_encode(&p, buf, sizeof(buf));
	CHECK(lora_codec_decode(buf, (size_t)len, 10, &d) == 0);
	buf[0] = 0x55;
	CHECK(lora_codec_decode(buf, (size_t)len, 10, &d) == -EINVAL);
}

int main(void)
{
	test_worked_example();
	test_v2_trailers_all_types();
	test_length_table();
	test_v1_round_trip();
	test_wraps();
	test_packing_rules();
	test_encode_rejects();
	test_decode_rejects();

	printf("%d checks, %d failed\n", checks, failures);
	return failures ? 1 : 0;
}
