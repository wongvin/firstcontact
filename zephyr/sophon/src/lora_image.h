/*
 * The running image, as the bit-error test sends and compares it (#359;
 * TRANSPORTER-PLAN.md § Image identity and extent): slot 0 from the MCUboot
 * header through the body, and its SHA-256.
 *
 * MCUboot builds only. In a UF2 build lora_image_init() fails and nothing else
 * may be called.
 */

#ifndef SOPHON_LORA_IMAGE_H
#define SOPHON_LORA_IMAGE_H

#include <stdbool.h>

#include "lora_ber.h"

/*
 * Read slot 0's image header and hash. Call once at boot. Returns 0, -ENOTSUP
 * in a UF2 build, or an error if the image can't be read. Logs the result.
 */
int lora_image_init(void);

/* Whether lora_image_init() succeeded: the board can transport and compare. */
bool lora_image_ready(void);

/* The image to hand to lora_ber_*: valid once lora_image_ready(). */
const struct lora_ber_image *lora_image(void);

#endif /* SOPHON_LORA_IMAGE_H */
