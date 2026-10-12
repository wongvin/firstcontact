/*
 * A work queue for work that sleeps or blocks (#318).
 *
 * The SX1262 driver handles DIO1 -- TX done, RX done -- as a work item on the
 * SYSTEM work queue, and lora_send() gives up after twice the packet's airtime
 * (58 ms at V3). Anything that holds the system queue longer than that makes a
 * packet that was sent report as failed, and the driver's recovery from that
 * timeout can leave the sensor hung. So work that sleeps (the battery's
 * conversion loop) or blocks on flash (the image confirm) goes here instead,
 * below the system queue and below the LoRa sensor thread.
 */

#ifndef SOPHON_SLOW_WORK_H
#define SOPHON_SLOW_WORK_H

#include <zephyr/kernel.h>

/* Started at boot, before main(), so it is ready for any caller. */
int sophon_slow_work_submit(struct k_work *work);

#endif /* SOPHON_SLOW_WORK_H */
