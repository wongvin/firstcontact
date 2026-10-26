/*
 * Host test for src/lora_lock.c (#350, #360). Run with scripts/test-codec.sh.
 *
 * The case #360 fixes: a fade of 5-20 s with no status trailer. With peer
 * "any" the packets that end it are dropped until a trailer re-anchors; with a
 * configured peer they're kept, and the gap before them counts as missing.
 */

#include <stdio.h>

#include "lora_lock.h"

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

/* The samples a stream really advances in ms, at the sensor's rate. */
static uint16_t gap_for(int64_t ms)
{
	return (uint16_t)(ms * SAMPLES_PER_S_X10 / 10000);
}

static void test_bound(void)
{
	CHECK(lora_lock_seq_bound(0) == SEQ_SLACK);
	CHECK(lora_lock_seq_bound(-5) == SEQ_SLACK);
	CHECK(lora_lock_seq_bound(1000) == 54 + SEQ_SLACK);
	CHECK(lora_lock_seq_bound(FADE_COUNT_MS) == 1086 + SEQ_SLACK);
}

static void test_any_peer(void)
{
	/* Within the anchor hold, a stream that continues is kept. */
	CHECK(lora_lock_untagged_ok(100, 4, false));
	CHECK(lora_lock_untagged_ok(ANCHOR_HOLD_MS, gap_for(ANCHOR_HOLD_MS), false));
	/* Past it, even the right stream waits for a trailer (#350). */
	CHECK(!lora_lock_untagged_ok(ANCHOR_HOLD_MS + 1, gap_for(ANCHOR_HOLD_MS + 1), false));
	CHECK(!lora_lock_untagged_ok(10000, gap_for(10000), false));
	/* Another sensor's seq, far off, is refused. */
	CHECK(!lora_lock_untagged_ok(100, 3000, false));
}

static void test_configured_peer(void)
{
	/* A 10 s fade with no trailer: kept (#360). */
	CHECK(lora_lock_untagged_ok(10000, gap_for(10000), true));
	CHECK(lora_lock_untagged_ok(FADE_COUNT_MS, gap_for(FADE_COUNT_MS), true));
	/* Beyond the fade window, a trailer re-anchors, as before. */
	CHECK(!lora_lock_untagged_ok(FADE_COUNT_MS + 1, gap_for(FADE_COUNT_MS + 1), true));
	/* A seq that time can't explain is still refused. */
	CHECK(!lora_lock_untagged_ok(10000, gap_for(10000) + SEQ_SLACK + 1, true));
	CHECK(!lora_lock_untagged_ok(100, 3000, true));
	/* Nothing changes inside the anchor hold. */
	CHECK(lora_lock_untagged_ok(100, 4, true));
}

int main(void)
{
	test_bound();
	test_any_peer();
	test_configured_peer();
	printf("%d checks, %d failed\n", checks, failures);
	return failures ? 1 : 0;
}
