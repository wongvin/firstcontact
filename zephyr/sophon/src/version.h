/*
 * Sophon identity, advertised in the scan response -- the wire contract for
 * everything a central can learn WITHOUT connecting. See PROTOCOL.md; the iOS
 * parser is ios/Sophon/Sophon/BLE/SophonProtocol.swift and must agree byte for
 * byte.
 *
 * Separate from frame.h on purpose: frame.h is the 18-byte motion frame
 * contract, and putting these here keeps a board revision from implying the
 * frame layout changed.
 */

#ifndef SOPHON_VERSION_H
#define SOPHON_VERSION_H

#include <stdint.h>

#include <zephyr/app_version.h>  /* generated from zephyr/sophon/VERSION */
#include <zephyr/sys/util.h>

/*
 * Company ID 0xFFFF is the value reserved for internal/test use, which is what
 * applies without SIG membership. It is NOT exclusive -- anyone may use it, so
 * a central must not treat it as proof the peripheral is a Sophon. The service
 * UUID is what identifies us; this only labels the payload that follows.
 *
 * Beware when replacing this with a real assigned ID: 0xFFFF reads the same
 * either way round, so it can never catch a byte-order mistake. Only
 * SOPHON_DEVICE_TYPE can -- 0x0001 must appear on air as 01 00.
 */
#define SOPHON_COMPANY_ID 0xFFFFU

/*
 * Versions THIS structure's layout and nothing else -- not the GATT contract,
 * not the 18-byte frame.
 *
 * Fields are APPEND-ONLY and never reordered, so parsers read the offsets they
 * know and ignore trailing bytes. Appending needs no bump; only changing the
 * meaning of an existing field does. That also makes an unrecognised version
 * safe to parse, since the known offsets still hold.
 */
#define SOPHON_SCAN_RSP_VERSION 0x01

/* What kind of peripheral this is. Constant across every Sophon board. */
#define SOPHON_DEVICE_TYPE 0x0001U

/*
 * Board revision. Hand-maintained -- nothing on the board can read its own
 * revision -- so it is the one field here that can go stale. Display-only:
 * nothing branches on it, so a wrong value misinforms rather than misbehaves.
 */
#define SOPHON_HW_VERSION 0x01

/* Firmware version. Bump rule lives in zephyr/sophon/VERSION, beside the numbers. */
#define SOPHON_FW_VERSION_MAJOR APP_VERSION_MAJOR
#define SOPHON_FW_VERSION_MINOR APP_VERSION_MINOR

#define SOPHON_MFG_DATA_SIZE 8

/*
 * Manufacturer Specific Data payload, AD type 0xFF.
 *
 * company_id MUST be first: the Core Spec Supplement defines this AD type as
 * "the first 2 octets contain the Company Identifier, followed by additional
 * manufacturer specific data". Put anything else first and every standard
 * scanner misreads those bytes as the company ID.
 */
struct sophon_mfg_data {
	uint16_t company_id;
	uint8_t  scan_rsp_version;
	uint16_t device_type;
	uint8_t  hw_version;
	uint8_t  fw_version_major;
	uint8_t  fw_version_minor;
} __packed;

BUILD_ASSERT(sizeof(struct sophon_mfg_data) == SOPHON_MFG_DATA_SIZE,
	     "Sophon manufacturer data must be exactly 8 bytes on the wire");

/*
 * Same assumption frame.h makes, asserted here too so this header stands alone:
 * the packed struct is already in wire order only on a little-endian target.
 */
BUILD_ASSERT(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__,
	     "Sophon manufacturer data is little-endian on the wire; this target is not");

BUILD_ASSERT(SOPHON_FW_VERSION_MAJOR <= UINT8_MAX && SOPHON_FW_VERSION_MINOR <= UINT8_MAX,
	     "firmware version does not fit the advertised bytes; see zephyr/sophon/VERSION");

#endif /* SOPHON_VERSION_H */
