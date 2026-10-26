/* See lora_lock.h. */

#include "lora_lock.h"

uint32_t lora_lock_seq_bound(int64_t ms)
{
	return (uint32_t)(ms > 0 ? ms : 0) * SAMPLES_PER_S_X10 / 10000U + SEQ_SLACK;
}

bool lora_lock_untagged_ok(int64_t since_ms, uint16_t gap, bool configured)
{
	int64_t hold = configured ? FADE_COUNT_MS : ANCHOR_HOLD_MS;

	return since_ms <= hold && gap <= lora_lock_seq_bound(since_ms);
}
