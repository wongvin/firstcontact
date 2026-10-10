/*
 * The LoRa link (#303): the sensor batches IMU samples into packets and sends
 * them; the gateway receives, rebuilds the 18-byte frames, and hands them to
 * the BLE side. Packet formats are lora_codec.h; air rates are lora_presets.h.
 */

#ifndef SOPHON_LORA_LINK_H
#define SOPHON_LORA_LINK_H

#include <stdbool.h>
#include <stdint.h>

#include "frame.h"
#include "role.h"

/* Called by the gateway for each rebuilt frame, on the system work queue. */
typedef void (*lora_link_frame_cb)(const struct sophon_frame *frame);

/*
 * Configure the radio for the selected preset and start the role's side of
 * the link. A no-op returning 0 for SOPHON_ROLE_DIRECT. on_frame is used by
 * the gateway only.
 */
int lora_link_start(enum sophon_role role, lora_link_frame_cb on_frame);

/*
 * Sensor: queue one sample for sending. Never blocks -- it is called from the
 * IMU's data-ready thread. A full queue drops the sample and counts it, which
 * leaves an honest seq gap.
 */
void lora_link_submit(const struct sophon_frame *frame);

/*
 * Gateway: the sensor's battery as last relayed, with age_s grown by the time
 * since that packet arrived. False until a status has been received.
 */
bool lora_link_battery(uint16_t *mv, uint16_t *age_s, uint8_t *flags);

#endif /* SOPHON_LORA_LINK_H */
