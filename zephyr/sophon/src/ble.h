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

#endif /* SOPHON_BLE_H */
