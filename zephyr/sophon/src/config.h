/*
 * Device configuration set from the app (#329): a role override and the LoRa
 * parameters, stored in flash and applied at the next boot. The design is
 * CONFIG-PLAN.md; the wire layouts are PROTOCOL.md § Config frame.
 */

#ifndef SOPHON_CONFIG_H
#define SOPHON_CONFIG_H

#include <stdbool.h>
#include <stdint.h>

#include <zephyr/sys/util.h>

#include "role.h"

/* The stored role. AUTO is no override: detect from the hardware at boot. */
enum sophon_config_role {
	SOPHON_CONFIG_ROLE_AUTO = 0,
	SOPHON_CONFIG_ROLE_DIRECT = 1,
	SOPHON_CONFIG_ROLE_SENSOR = 2,
	SOPHON_CONFIG_ROLE_GATEWAY = 3,
};

/* Sentinels meaning "use the build's own value". */
#define SOPHON_CONFIG_PRESET_DEFAULT 0xFF
#define SOPHON_CONFIG_TX_DEFAULT     0x7F
#define SOPHON_CONFIG_FREQ_DEFAULT   0

/* A 500 kHz channel centred here stays inside 902-928 MHz. */
#define SOPHON_CONFIG_FREQ_MIN_HZ 902250000U
#define SOPHON_CONFIG_FREQ_MAX_HZ 927750000U
#define SOPHON_CONFIG_TX_MIN_DBM  (-9)
#define SOPHON_CONFIG_TX_MAX_DBM  22

struct sophon_config {
	uint8_t role;     /* enum sophon_config_role */
	uint8_t preset;   /* 0..LORA_PRESET_COUNT-1, or SOPHON_CONFIG_PRESET_DEFAULT */
	int8_t tx_dbm;    /* SOPHON_CONFIG_TX_MIN..MAX_DBM, or SOPHON_CONFIG_TX_DEFAULT */
	uint32_t freq_hz; /* SOPHON_CONFIG_FREQ_MIN..MAX_HZ, or SOPHON_CONFIG_FREQ_DEFAULT */
	uint16_t peer_id; /* 0 = lock onto the first sensor heard */
	/* Gateway stats window, seconds (#344): 1..SOPHON_CONFIG_WINDOW_MAX_S, or
	 * SOPHON_CONFIG_WINDOW_DEFAULT. On the wire it is the role byte's high
	 * nibble (PROTOCOL.md § Config frame), so no frame grows. */
	uint8_t window_s;
};

#define SOPHON_CONFIG_WINDOW_DEFAULT 0
#define SOPHON_CONFIG_WINDOW_MAX_S   10
/* What "default" means: the 10 s window every board used before #344. */
#define SOPHON_CONFIG_WINDOW_BUILD_S 10

/* Wire sizes and bits: PROTOCOL.md § Config frame. */
#define SOPHON_CONFIG_WRITE_SIZE 12
#define SOPHON_CONFIG_READ_SIZE  20
/* Version 2 (#344): the role byte's high nibble carries window_s. A version 1
 * write has 0 there, which is "default", so it is still accepted. */
#define SOPHON_CONFIG_VERSION    2

#define SOPHON_CONFIG_FLAG_RESTART  BIT(0)
#define SOPHON_CONFIG_FLAG_DEFAULTS BIT(1)

#define SOPHON_CONFIG_STATUS_RADIO   BIT(0)
#define SOPHON_CONFIG_STATUS_IMU     BIT(1)
#define SOPHON_CONFIG_STATUS_PENDING BIT(2)
#define SOPHON_CONFIG_STATUS_FORCED  BIT(3)
#define SOPHON_CONFIG_STATUS_STORED  BIT(4)
#define SOPHON_CONFIG_STATUS_GUARD   BIT(5)

/*
 * Load the stored config and run the boot-loop guard. Call first thing at boot,
 * before the IMU and the role: both depend on it. Never fails; a board with no
 * usable config runs on the build's defaults.
 */
void sophon_config_init(void);

/* The config this boot runs on: the stored one, or defaults. */
const struct sophon_config *sophon_config_boot(void);

/* Values this boot uses, with the build defaults resolved. */
uint8_t sophon_config_preset_id(void);
uint32_t sophon_config_freq_hz(void);
/* The TX power override, or SOPHON_CONFIG_TX_DEFAULT for the preset's own. */
int8_t sophon_config_tx_override(void);
/* The gateway's stats window this boot, in seconds: 1..10, the default resolved. */
uint8_t sophon_config_window_s(void);

/*
 * Record what the hardware turned out to be, once the role is fixed. Writes are
 * validated against it, and the read reports it.
 */
void sophon_config_set_hardware(bool radio, bool imu, bool forced);

/*
 * Clear the boot-loop guard's counter: this boot came up. Called once
 * advertising has run for a while.
 */
void sophon_config_mark_healthy(void);

/*
 * The Config characteristic. write returns 0 on success, or a BT_ATT_ERR_* code
 * with nothing stored. The save, and any restart, run later on the slow work
 * queue. read fills SOPHON_CONFIG_READ_SIZE bytes.
 */
uint8_t sophon_config_write(const uint8_t *buf, uint16_t len);
void sophon_config_read(uint8_t out[SOPHON_CONFIG_READ_SIZE]);

#endif /* SOPHON_CONFIG_H */
