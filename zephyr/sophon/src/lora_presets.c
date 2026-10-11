/*
 * LoRa air-rate presets (#303). LORA-PROTOCOL.md § Presets is the contract;
 * LORA-UPDATED-PLAN.md § Variants is where each row's airtime, latency and
 * range come from.
 */

#include <zephyr/sys/util.h>

#include "lora_presets.h"

static const struct lora_preset presets[LORA_PRESET_COUNT] = {
	{0, "V0", LORA_FORMAT_V1, 7, 1, 10, 14},  /* the original design */
	{1, "V1", LORA_FORMAT_V2, 7, 1, 10, 14},  /* compact samples */
	{2, "V3", LORA_FORMAT_V2, 7, 1, 4, 14},   /* + k=4: provisional default */
	{3, "V3b", LORA_FORMAT_V2, 7, 1, 2, 14},  /* + k=2 */
	{4, "V4", LORA_FORMAT_V2, 7, 3, 4, 14},   /* V3 + CR 4/7 */
	{5, "V5", LORA_FORMAT_V2, 8, 1, 10, 14},  /* V1 + SF8 */
	{6, "V5b", LORA_FORMAT_V2, 8, 1, 5, 14},  /* V1 + SF8, k=5 */
	{7, "V6", LORA_FORMAT_V2, 7, 1, 4, 22},   /* V3 at +22 dBm */
	{8, "V6b", LORA_FORMAT_V2, 8, 1, 10, 22}, /* V5 at +22 dBm */
};

BUILD_ASSERT(CONFIG_SOPHON_LORA_PRESET < LORA_PRESET_COUNT, "SOPHON_LORA_PRESET out of range");

const struct lora_preset *lora_preset_get(uint8_t id)
{
	return id < LORA_PRESET_COUNT ? &presets[id] : NULL;
}

const struct lora_preset *lora_preset_selected(void)
{
	return &presets[CONFIG_SOPHON_LORA_PRESET];
}

uint16_t lora_preset_full_len(const struct lora_preset *p)
{
	if (p->format == LORA_FORMAT_V1) {
		return LORA_V1_HEADER + p->k * LORA_FRAME_SIZE;
	}
	return LORA_V2_HEADER + p->k * LORA_V2_RECORD;
}
