/*
 * Runtime role selection (#303): one image, three roles, chosen at boot from
 * what is attached. See LORA-PROTOCOL.md § Roles.
 *
 *   radio + IMU  -> sensor
 *   radio, no IMU -> gateway
 *   no radio     -> direct (the BLE peripheral as it was before LoRa)
 */

#ifndef SOPHON_ROLE_H
#define SOPHON_ROLE_H

#include <stdbool.h>

enum sophon_role {
	SOPHON_ROLE_DIRECT,
	SOPHON_ROLE_SENSOR,
	SOPHON_ROLE_GATEWAY,
};

/*
 * Probe for the Wio-SX1262, start its driver if present, and fix the role.
 * Call once at boot, after the IMU has been tried. Never fails: a board that
 * cannot use its radio is a direct board.
 */
enum sophon_role sophon_role_detect(bool imu_ok);

/* The role fixed by sophon_role_detect(); SOPHON_ROLE_DIRECT before that. */
enum sophon_role sophon_role(void);

const char *sophon_role_name(enum sophon_role role);

#endif /* SOPHON_ROLE_H */
