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
#include <stdint.h>

enum sophon_role {
	SOPHON_ROLE_DIRECT,
	SOPHON_ROLE_SENSOR,
	SOPHON_ROLE_GATEWAY,
};

/*
 * Probe for the Wio-SX1262, start its driver if the role needs it, and fix the
 * role. Call once at boot, after the IMU has been tried. override is the
 * stored role (enum sophon_config_role, #329): AUTO keeps the table above; a
 * forced role applies only if the hardware supports it -- sensor needs the
 * radio and the IMU, gateway the radio -- and otherwise falls back to AUTO.
 * Never fails: a board that cannot use its radio is a direct board.
 */
enum sophon_role sophon_role_resolve(uint8_t override, bool imu_ok);

/* The role fixed by sophon_role_resolve(); SOPHON_ROLE_DIRECT before that. */
enum sophon_role sophon_role(void);

/* Whether the radio answered the presence check. */
bool sophon_role_radio(void);

/* Whether a stored role override is what this boot is running. */
bool sophon_role_forced(void);

const char *sophon_role_name(enum sophon_role role);

#endif /* SOPHON_ROLE_H */
