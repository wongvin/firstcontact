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

/*
 * The connection parameters iOS actually granted -- the one number that governs
 * buffer refusals, frame gaps and stream latency, and which the central cannot
 * see for itself.
 *
 * Core Bluetooth exposes NO API for connection parameters: an iOS app cannot ask
 * what interval, latency or supervision timeout it was given. Only the peripheral
 * can, via bt_conn_get_info(), which is why this has to travel back over GATT
 * rather than simply being read on the phone (#224).
 *
 * The cost of the blind spot is on record: during #209 a board streaming to a
 * sleeping iPhone produced transmit refusals and frame loss, and the diagnosis
 * detoured through buffer sizing before the cause turned out to be iOS stretching
 * the interval to save power. On screen it would have been a glance.
 */
struct sophon_link_params {
	uint32_t interval_us; /* microseconds. NOT the deprecated 1.25 ms unit. */
	uint16_t latency;     /* connection events the peripheral may skip */
	uint16_t timeout;     /* supervision timeout, 10 ms units */
};

/*
 * Wire form: u32 + u16 + u16, little-endian, in struct order. 8 bytes fits the
 * 20-byte value budget at the default 23-byte ATT MTU, so this needs no MTU
 * change and never fragments -- the same constraint that shaped the motion frame
 * and the stats frame.
 *
 * Packed field by field rather than by copying the struct, matching
 * sophon_stats_pack: the byte order is stated here rather than inherited from
 * whatever the compiler laid out.
 */
#define SOPHON_LINK_PARAMS_SIZE 8

void sophon_link_params_pack(const struct sophon_link_params *in,
			     uint8_t out[SOPHON_LINK_PARAMS_SIZE]);

/*
 * Battery: terminal millivolts and the AGE of that reading (#268).
 *
 * Wire form, little-endian, 5 bytes:
 *   0..1  u16  mV
 *   2..3  u16  age of the reading, seconds
 *   4     u8   flags -- bit 0 set when USB was supplying the board
 *
 * The age is on the wire rather than left to the central to guess, because a
 * GATT read proves only that somebody asked. The board samples on its own
 * one-minute timer and this read returns the cache, so the value behind it is
 * up to a minute old in normal operation and older if sampling has since
 * failed. A reading whose timestamp refreshes merely by being read is the
 * defect #237 had to correct in the RSSI row; there is no reason to rebuild it
 * here when four bytes states the truth instead.
 *
 * `mv == 0` means **no reading**, not a reading of zero -- a connected pack
 * cannot sit at 0 mV, so the sentinel is unambiguous. It is what a board whose
 * divider failed to initialise reports, and the app renders it with the #230
 * `Not reported` idiom rather than as a fault.
 *
 * The flags byte is what makes the voltage interpretable. VBAT is the charger's
 * OUT, the BAT pad and the top of the divider shorted together, so the voltage
 * alone cannot say what is driving it. VBUS **absent** proves the pack is, so
 * the reading is the pack; VBUS **present** means the reading is simply what is
 * on VBAT, which may or may not be a pack. Pack ABSENCE stays undetectable.
 *
 * Appended rather than folded into spare bits of `mv`, so the append-only rule
 * that governs the scan response holds here too: the app's parser requires a
 * MINIMUM of 4 bytes and ignores extras, so a central built against the earlier
 * 4-byte form still parses this.
 *
 * Deliberately no percentage and no capacity: see battery.h and PROTOCOL.md.
 */
#define SOPHON_BATTERY_SIZE 5

void sophon_battery_pack(uint16_t mv, uint16_t age_s, uint8_t flags,
			 uint8_t out[SOPHON_BATTERY_SIZE]);

/*
 * Push the current battery reading to a subscribed central.
 *
 * Notify, unusually for this service -- the stats and link-params
 * characteristics are deliberately read-only because they change constantly and
 * a subscription would spend connection events restating them. Battery is the
 * opposite case: it changes rarely, and one of its fields (the USB flag) changes
 * what the reading MEANS. Polling a rare event means either a slow cadence that
 * reports reality late, or a fast one that spends the budget those other
 * characteristics were made reads to protect.
 *
 * Called only on an actual change, so a stationary pack costs nothing.
 * A no-op when nobody has subscribed.
 */
void sophon_ble_battery_notify(void);

#endif /* SOPHON_BLE_H */
