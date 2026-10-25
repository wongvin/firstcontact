/*
 * The running image for the bit-error test (#359). See lora_image.h.
 *
 * The extent comes from the MCUboot image header at the start of slot 0, and
 * the hash from the SHA-256 TLV after the image, both read here directly:
 * Zephyr's boot_read_bank_header() doesn't expose the header size, and
 * img_mgmt.h needs bootutil's include path, which isn't exported to the app.
 * The layout is bootutil/image.h's, the same the app's FirmwareImage.swift
 * parses. Reads go through the flash map; on the nRF52840 a flash read needs no
 * radio synchronisation, only writes and erases do.
 */

#include <errno.h>

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/byteorder.h>

#include "lora_image.h"

LOG_MODULE_REGISTER(sophon_image, LOG_LEVEL_INF);

static bool ready;

#if defined(CONFIG_MCUBOOT_IMG_MANAGER)

#include <zephyr/storage/flash_map.h>

#define IMAGE_MAGIC          0x96f3b83dU
#define IMAGE_TLV_INFO_MAGIC 0x6907
#define IMAGE_TLV_SHA256     0x0010

static const struct flash_area *slot0;
static uint8_t hash[LORA_BER_HASH_SIZE];
static struct lora_ber_image image;

static int read_wrapped(uint32_t off, uint8_t *buf, size_t len, void *ctx)
{
	ARG_UNUSED(ctx);

	while (len > 0) {
		size_t chunk = MIN(len, image.len - off);
		int err = flash_area_read(slot0, off, buf, chunk);

		if (err) {
			return err;
		}
		buf += chunk;
		len -= chunk;
		off = 0;
	}
	return 0;
}

/*
 * The unprotected TLV area starts after the image and any protected TLVs: a
 * 4-byte info (magic, total length including itself), then entries of
 * type u16, len u16, value.
 */
static int read_hash(uint32_t off)
{
	uint8_t b[4];
	uint32_t end;
	int err;

	err = flash_area_read(slot0, off, b, sizeof(b));
	if (err) {
		return err;
	}
	if (sys_get_le16(&b[0]) != IMAGE_TLV_INFO_MAGIC) {
		return -ENOENT;
	}
	end = off + sys_get_le16(&b[2]);
	for (off += sizeof(b); off + sizeof(b) <= end;) {
		uint16_t type;
		uint16_t len;

		err = flash_area_read(slot0, off, b, sizeof(b));
		if (err) {
			return err;
		}
		type = sys_get_le16(&b[0]);
		len = sys_get_le16(&b[2]);
		off += sizeof(b);
		if (type == IMAGE_TLV_SHA256 && len == LORA_BER_HASH_SIZE) {
			return flash_area_read(slot0, off, hash, sizeof(hash));
		}
		off += len;
	}
	return -ENOENT;
}

int lora_image_init(void)
{
	/* struct image_header: magic, load_addr, hdr_size u16, protect_tlv_size
	 * u16, img_size u32 (bootutil/image.h). */
	uint8_t hdr[16];
	int err;

	err = flash_area_open(PARTITION_ID(slot0_partition), &slot0);
	if (err == 0) {
		err = flash_area_read(slot0, 0, hdr, sizeof(hdr));
	}
	if (err) {
		LOG_ERR("image: slot 0 unreadable (%d)", err);
		return err;
	}
	if (sys_get_le32(&hdr[0]) != IMAGE_MAGIC) {
		LOG_ERR("image: no MCUboot header in slot 0");
		return -ENOENT;
	}
	image.len = (uint32_t)sys_get_le16(&hdr[8]) + sys_get_le32(&hdr[12]);
	if (image.len == 0 || image.len > slot0->fa_size) {
		LOG_ERR("image: implausible length %u", image.len);
		return -EINVAL;
	}

	err = read_hash(image.len + sys_get_le16(&hdr[10]));
	if (err) {
		LOG_ERR("image: hash unreadable (%d)", err);
		return err;
	}

	image.hash = hash;
	image.read = read_wrapped;
	image.ctx = NULL;
	ready = true;
	LOG_INF("image: %u bytes, sha256 %02x%02x%02x%02x...", image.len, hash[0], hash[1], hash[2],
		hash[3]);
	return 0;
}

const struct lora_ber_image *lora_image(void)
{
	return &image;
}

#else /* !CONFIG_MCUBOOT_IMG_MANAGER */

int lora_image_init(void)
{
	return -ENOTSUP;
}

const struct lora_ber_image *lora_image(void)
{
	return NULL;
}

#endif

bool lora_image_ready(void)
{
	return ready;
}
