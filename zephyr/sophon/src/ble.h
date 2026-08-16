/*
 * BLE peripheral: advertising, the Sophon Motion GATT service, and notify.
 */

#ifndef SOPHON_BLE_H
#define SOPHON_BLE_H

#include <stdbool.h>

#include "frame.h"

/* Enables the stack, sets the FICR-derived name, and starts advertising. */
int sophon_ble_init(void);

/* True once a central has connected. */
bool sophon_ble_connected(void);

/* True once a central has written the CCC to subscribe to Motion Data. */
bool sophon_ble_subscribed(void);

/*
 * Sends one frame as a GATT notification. Returns 0 on success, -ENOTCONN if no
 * one is subscribed, or the stack's error otherwise.
 */
int sophon_ble_notify(const struct sophon_frame *frame);

/*
 * Outcome counts for the transmit path.
 *
 * A gap in the central's sequence numbers says only that an interval has no
 * data; it cannot say whose fault that is. Buffer exhaustion here and loss on
 * the air produce an identical gap, and at N devices they point at completely
 * different culprits. These counters are the second signal that tells them
 * apart -- see PROTOCOL.md.
 *
 * Counters are cumulative since boot and never reset.
 */
struct sophon_tx_stats {
	uint32_t sent;     /* accepted by the stack */
	uint32_t no_conn;  /* -ENOTCONN: nobody subscribed. Expected, not a fault. */
	uint32_t no_mem;   /* -ENOMEM: TX buffers full. The interesting one. */
	uint32_t other;    /* anything else the stack returned */
};

void sophon_ble_tx_stats(struct sophon_tx_stats *out);

/*
 * Wire form of the above, readable over the stats characteristic: four u32s,
 * little-endian, in struct order. 16 bytes fits the 20-byte value budget at the
 * default 23-byte ATT MTU, so this needs no MTU change and never fragments.
 *
 * Packed field by field rather than by copying the struct, so the byte order is
 * stated here rather than inherited from whatever the compiler laid out.
 */
#define SOPHON_STATS_SIZE 16

void sophon_stats_pack(const struct sophon_tx_stats *in, uint8_t out[SOPHON_STATS_SIZE]);

#endif /* SOPHON_BLE_H */
