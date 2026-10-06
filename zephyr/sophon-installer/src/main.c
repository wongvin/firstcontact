/*
 * Sophon UF2 -> MCUboot installer (#294) -- SURVEY ONLY.
 *
 * THIS BUILD WRITES NOTHING. It is the third item of UF2-MIGRATION.md's
 * "Before any code": confirm the merged UF2 flashes and the installer runs
 * before it is allowed to touch flash. Everything below reads, computes and
 * reports; CONFIG_FLASH is not even enabled, so the absence of writes is a
 * property of the binary rather than a promise in a comment.
 *
 * What it is checking, and why each one can fail silently later:
 *
 *   - that BOTH payloads landed. The UF2 carries two disjoint regions and the
 *     bootloader reports success either way.
 *   - that the staged image is where CONFIG_BOOT_SWAP_USING_OFFSET expects,
 *     which is slot1 + ONE SECTOR, not slot1. Getting this wrong leaves an
 *     image MCUboot will never find.
 *   - that the trailer offsets derive from the PARTITION size and not the
 *     image length -- the mistake UF2-MIGRATION.md spends a section on.
 *   - that the trailer page is what the design claims: live Adafruit
 *     bootloader code, which is why erasing it is destructive and why that
 *     erase has to lead.
 */

#include <string.h>

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/util.h>

LOG_MODULE_REGISTER(installer, LOG_LEVEL_INF);

/* MCUboot, as an ordinary const array. See CMakeLists.txt. */
static const uint8_t mcuboot_blob[] = {
#include "mcuboot_blob.inc"
};

/*
 * Layout, from UF2-MIGRATION.md's column C. Only these are fixed; the top of
 * each payload region floats with whatever was built, which is why no end
 * address appears here.
 */
#define MCUBOOT_DEST   0x000000U /* where the blob goes, on a later milestone */
#define INSTALLER_BASE 0x027000U /* the UF2 application window's base */
#define SLOT0_BASE     0x00C000U
#define SLOT1_BASE     0x084000U
#define SLOT_SIZE      0x078000U /* 480 KB */
#define STAGED_IMAGE   0x085000U /* SLOT1_BASE + one sector */
#define UF2_WINDOW_END 0x0EC000U /* top of what the UF2 bootloader accepts */
#define FLASH_SECTOR   0x001000U

/*
 * MCUboot's trailer geometry. BOOT_MAX_ALIGN is 8 on this SoC, and
 * BOOT_MAGIC_SZ is 16. Reproduced from bootutil_misc.h rather than included,
 * because this application is not built against MCUboot's headers -- the
 * values are asserted against the design document's figures below, so a
 * mismatch fails at compile time rather than on the board.
 */
#define BOOT_MAX_ALIGN 8U
#define BOOT_MAGIC_SZ  16U

#define BOOT_MAGIC_OFF     (SLOT_SIZE - BOOT_MAGIC_SZ)
#define BOOT_IMAGE_OK_OFF  ROUND_DOWN(BOOT_MAGIC_OFF - BOOT_MAX_ALIGN, BOOT_MAX_ALIGN)
#define BOOT_COPY_DONE_OFF (BOOT_IMAGE_OK_OFF - BOOT_MAX_ALIGN)

#define TRAILER_PAGE ROUND_DOWN(SLOT1_BASE + BOOT_MAGIC_OFF, FLASH_SECTOR)

/*
 * The addresses UF2-MIGRATION.md states, checked here rather than trusted. If
 * the derivation above and the document ever disagree, this stops the build.
 */
BUILD_ASSERT(SLOT1_BASE + BOOT_COPY_DONE_OFF == 0x0FBFE0U, "copy_done moved");
BUILD_ASSERT(SLOT1_BASE + BOOT_IMAGE_OK_OFF == 0x0FBFE8U, "image_ok moved");
BUILD_ASSERT(SLOT1_BASE + BOOT_MAGIC_OFF == 0x0FBFF0U, "magic moved");
BUILD_ASSERT(SLOT1_BASE + SLOT_SIZE == 0x0FC000U, "slot1 does not end at 0xFC000");
BUILD_ASSERT(TRAILER_PAGE == 0x0FB000U, "trailer page moved");
BUILD_ASSERT(STAGED_IMAGE == SLOT1_BASE + FLASH_SECTOR,
	     "staged image must be slot1 + one sector, per CONFIG_BOOT_SWAP_USING_OFFSET");

/* MCUboot's image header, from image.h. Only the fields this needs. */
#define IMAGE_MAGIC 0x96f3b83dU

struct image_version {
	uint8_t iv_major;
	uint8_t iv_minor;
	uint16_t iv_revision;
	uint32_t iv_build_num;
};

struct image_header {
	uint32_t ih_magic;
	uint32_t ih_load_addr;
	uint16_t ih_hdr_size;
	uint16_t ih_protect_tlv_size;
	uint32_t ih_img_size;
	uint32_t ih_flags;
	struct image_version ih_ver;
	uint32_t _pad1;
};

/* nRF52840 flash is memory mapped from 0, so a read is a dereference. */
static const void *at(uint32_t addr)
{
	return (const void *)(uintptr_t)addr;
}

static size_t count_written(uint32_t addr, size_t len)
{
	const uint8_t *p = at(addr);
	size_t n = 0;

	for (size_t i = 0; i < len; i++) {
		if (p[i] != 0xFF) {
			n++;
		}
	}
	return n;
}

static bool survey_staged_image(void)
{
	const struct image_header *hdr = at(STAGED_IMAGE);

	if (hdr->ih_magic != IMAGE_MAGIC) {
		LOG_ERR("staged image: NO MCUboot header at 0x%06X (magic 0x%08x)", STAGED_IMAGE,
			hdr->ih_magic);
		LOG_ERR("  the UF2 did not carry the application, or carried it to the");
		LOG_ERR("  wrong address. Nothing can proceed without it.");
		return false;
	}

	LOG_INF("staged image at 0x%06X: v%u.%u.%u+%u", STAGED_IMAGE, hdr->ih_ver.iv_major,
		hdr->ih_ver.iv_minor, hdr->ih_ver.iv_revision, hdr->ih_ver.iv_build_num);
	LOG_INF("  header %u B, body %u B, protected TLVs %u B", hdr->ih_hdr_size, hdr->ih_img_size,
		hdr->ih_protect_tlv_size);

	/*
	 * The one size check that binds. Unprotected TLVs follow the figures
	 * above and are not counted here, so this is a floor on the real extent
	 * -- enough to catch an image that cannot possibly fit, not a precise
	 * measure. The exact check belongs in the merge step, which knows the
	 * file's true length; see scripts/mkuf2.sh.
	 */
	uint32_t body_end = STAGED_IMAGE + hdr->ih_hdr_size + hdr->ih_img_size;

	LOG_INF("  body ends at/after 0x%06X; UF2 window ends 0x%06X (%u KB usable)", body_end,
		UF2_WINDOW_END, (UF2_WINDOW_END - STAGED_IMAGE) / 1024);

	if (body_end >= UF2_WINDOW_END) {
		LOG_ERR("  IMAGE DOES NOT FIT the UF2 application window");
		return false;
	}
	return true;
}

static void survey(void)
{
	LOG_INF("Sophon UF2 -> MCUboot installer (#294)");
	LOG_INF("*** SURVEY BUILD -- WRITES NOTHING ***");
	LOG_INF("");

	LOG_INF("installer running from 0x%06X, inside slot0 0x%06X-0x%06X", INSTALLER_BASE,
		SLOT0_BASE, SLOT1_BASE);
	LOG_INF("  no write targets that range, so no __ramfunc is needed");
	LOG_INF("");

	LOG_INF("MCUboot blob: %u B, destined for 0x%06X", (unsigned int)sizeof(mcuboot_blob),
		MCUBOOT_DEST);

	bool staged_ok = survey_staged_image();

	LOG_INF("");
	LOG_INF("slot1 trailer, derived from the PARTITION size (not the image):");
	LOG_INF("  copy_done  0x%06X", SLOT1_BASE + BOOT_COPY_DONE_OFF);
	LOG_INF("  image_ok   0x%06X", SLOT1_BASE + BOOT_IMAGE_OK_OFF);
	LOG_INF("  magic      0x%06X", SLOT1_BASE + BOOT_MAGIC_OFF);
	LOG_INF("  slot1 ends 0x%06X", SLOT1_BASE + SLOT_SIZE);

	/*
	 * The claim this is checking: that page is live Adafruit bootloader
	 * code, so erasing it is destructive and must therefore lead -- it is
	 * the only step where an ACL refusal is survivable. A page that reads
	 * back erased here would mean the board is NOT on the stock UF2 layout
	 * and the whole premise needs rechecking.
	 */
	size_t written = count_written(TRAILER_PAGE, FLASH_SECTOR);

	LOG_INF("  trailer page 0x%06X-0x%06X holds %u/%u non-erased bytes", TRAILER_PAGE,
		TRAILER_PAGE + FLASH_SECTOR, (unsigned int)written, FLASH_SECTOR);
	if (written == 0) {
		LOG_WRN("  that page is ALREADY ERASED -- this board is not on the stock");
		LOG_WRN("  UF2 layout, and the migration's assumptions do not hold");
	}

	LOG_INF("");
	if (staged_ok) {
		LOG_INF("survey OK -- both payloads present, nothing written");
	} else {
		LOG_ERR("survey FAILED -- see above, nothing written");
	}
}

/*
 * Repeat the survey rather than report it once.
 *
 * The report is longer than this board's CDC ACM buffer, which holds about
 * 1 KB, so a console attached after boot sees it truncated mid-line and then
 * nothing -- the board has already said everything it intends to say.
 * Observed on 86F0 on the first run, and not recoverable by resetting,
 * because a reset re-enumerates USB and drops whatever console was attached.
 *
 * Reprinting makes the result readable whenever a console is attached, which
 * is the entire value of a build whose only output is a report. It costs
 * nothing: this application has nothing else to do, and a later milestone
 * that actually writes flash will not survey in a loop.
 */
#define SURVEY_PERIOD_S 15

int main(void)
{
	for (;;) {
		survey();
		LOG_INF("--- repeating in %d s ---", SURVEY_PERIOD_S);
		LOG_INF("");
		k_sleep(K_SECONDS(SURVEY_PERIOD_S));
	}
	return 0;
}
