/*
 * Which untagged packets a gateway attributes to its locked sensor (#350,
 * #360). Pure arithmetic, so scripts/test-codec.sh tests it on the host.
 * LORA-PROTOCOL.md § Locking onto a sensor.
 */

#ifndef SOPHON_LORA_LOCK_H
#define SOPHON_LORA_LOCK_H

#include <stdbool.h>
#include <stdint.h>

#include "lora_codec.h"

/* The sensor's sample rate, x10, and two packets' slack on top of it. */
#define SAMPLES_PER_S_X10 543
#define SEQ_SLACK         (2 * LORA_K_LIMIT)
/* How long an anchor vouches for untagged packets with peer "any". */
#define ANCHOR_HOLD_MS    5000
/* How long a gap may last and still count as a fade, not a restart. */
#define FADE_COUNT_MS     20000 /* ~1086 samples, as the old 1024-sample rule */

/* Samples the elapsed time allows, plus slack; ms is capped by the caller. */
uint32_t lora_lock_seq_bound(int64_t ms);

/*
 * Whether an untagged packet continues the locked sensor's stream: since_ms
 * after the last accepted packet, gap samples on. With peer "any" the anchor
 * vouches for ANCHOR_HOLD_MS, so a quiet sensor can't hand its stream to
 * another. A configured peer is the one sensor on the channel (#360), so it
 * is trusted across a fade as long as a status trailer would be: the packets
 * that end a fade are kept, and the gap before them counts as missing.
 */
bool lora_lock_untagged_ok(int64_t since_ms, uint16_t gap, bool configured);

#endif /* SOPHON_LORA_LOCK_H */
