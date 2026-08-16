#include <stdio.h>
#include <string.h>

#include <zephyr/drivers/hwinfo.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "ident.h"

LOG_MODULE_REGISTER(sophon_ident, LOG_LEVEL_INF);

int sophon_device_name(char *buf, size_t len)
{
	uint8_t id[8];
	ssize_t n;
	uint16_t tag;

	if (len < SOPHON_NAME_MAX) {
		return -ENOSPC;
	}

	n = hwinfo_get_device_id(id, sizeof(id));
	if (n <= 0) {
		/*
		 * No FICR id available. Fall back rather than fail: an
		 * unidentifiable board that still advertises is far more useful
		 * during bring-up than one that refuses to start.
		 */
		LOG_WRN("hwinfo unavailable (%d), advertising without chip id", (int)n);
		strcpy(buf, "Sophon");
		return 0;
	}

	/*
	 * Use the LAST two bytes, not the first. hwinfo returns the FICR
	 * DEVICEID big-endian, and the high-order bytes are the least variable
	 * across chips from the same wafer -- taking the low half maximises the
	 * chance that two boards on the bench differ.
	 */
	tag = ((uint16_t)id[n - 2] << 8) | id[n - 1];

	snprintf(buf, len, "Sophon-%04X", tag);
	return 0;
}
