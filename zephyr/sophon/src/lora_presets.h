/*
 * LoRa air-rate presets (#303), in the style of ExpressLRS's rate table: one
 * row holds everything that differs between variants. Ids and values are
 * LORA-PROTOCOL.md § Presets; keep the two in step.
 */

#ifndef SOPHON_LORA_PRESETS_H
#define SOPHON_LORA_PRESETS_H

#include <stdint.h>

#include "lora_codec.h"

struct lora_preset {
	uint8_t id;
	const char *name;
	enum lora_format format;
	uint8_t sf; /* spreading factor, 7 or 8 */
	uint8_t cr; /* coding-rate index: 1 = 4/5 ... 4 = 4/8 */
	uint8_t k;  /* samples per packet */
	int8_t tx_dbm;
};

/* Common to every preset (LORA-PROTOCOL.md § Radio parameters). */
#define LORA_BANDWIDTH_KHZ 500
#define LORA_PREAMBLE_LEN  8

#define LORA_PRESET_COUNT 9

/* The preset for this id, or NULL. */
const struct lora_preset *lora_preset_get(uint8_t id);

/* The one selected by CONFIG_SOPHON_LORA_PRESET. */
const struct lora_preset *lora_preset_selected(void);

/* Payload length of a full motion-only packet for this preset. */
uint16_t lora_preset_full_len(const struct lora_preset *p);

#endif /* SOPHON_LORA_PRESETS_H */
