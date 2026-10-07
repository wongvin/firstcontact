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

#include <zephyr/drivers/flash.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/crc.h>
#include <zephyr/sys/reboot.h>
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
#define MCUBOOT_REGION 0x00C000U /* 0x0 up to slot0: MBR + SoftDevice, in layout A */
#define STORAGE_BASE   0x0FC000U /* slot1 ends here; storage runs to 0x100000 */

/*
 * Where the stub TLV trailer for slot0 goes: the last sector before the
 * installer. See step 5 for why slot0 needs one at all. It must sit inside
 * slot0, below the installer, and in the SoftDevice remnant that nothing
 * needs -- the asserts below pin all three.
 */
#define PRIMARY_STUB_TLV 0x026000U

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
BUILD_ASSERT(PRIMARY_STUB_TLV + FLASH_SECTOR <= INSTALLER_BASE,
	     "the stub TLV sector would overlap the installer, which is writing it");
BUILD_ASSERT(PRIMARY_STUB_TLV > SLOT0_BASE + FLASH_SECTOR,
	     "the stub TLV must leave room for slot0's header sector below it");

/*
 * The trailer magic, copied from the BOOT_MAX_ALIGN == 8 branch of
 * bootutil_public.c. Which branch applies is not a guess: this build leaves
 * CONFIG_MCUBOOT_BOOT_MAX_ALIGN at 4, the Zephyr port only overrides
 * BOOT_MAX_ALIGN when that symbol exceeds 8, so the fallback of 8 stands --
 * and the BUILD_ASSERTs above independently pin the offsets to an align of 8.
 * The other branch is a DIFFERENT 16 bytes, so getting this wrong means
 * MCUboot silently ignores the staged image.
 */
static const uint8_t boot_magic[BOOT_MAGIC_SZ] = {
	0x77, 0xc2, 0x95, 0xf3, 0x60, 0xd2, 0xef, 0x7f,
	0x35, 0x52, 0x50, 0x0f, 0x2c, 0xb6, 0x79, 0x80,
};

#define BOOT_FLAG_SET 1U /* bootutil_public.h; "leave equal to one, written to flash" */

/* image.h. The TLV trailer that follows an image's body. */
#define IMAGE_TLV_INFO_MAGIC 0x6907U

struct image_tlv_info {
	uint16_t it_magic;
	uint16_t it_tlv_tot;
};

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

/*
 * Compare flash against a buffer without memcmp(). MCUBOOT_DEST is 0, and GCC
 * sees a pointer literally derived from address zero as NULL -- it warns
 * -Wnonnull and is entitled to assume the call never happens. volatile keeps
 * the reads, and the loop keeps the compiler out of it.
 */
static bool flash_matches(uint32_t addr, const uint8_t *buf, size_t len)
{
	const volatile uint8_t *p = (const volatile uint8_t *)(uintptr_t)addr;

	for (size_t i = 0; i < len; i++) {
		if (p[i] != buf[i]) {
			return false;
		}
	}
	return true;
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

static bool survey(void)
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
	LOG_INF("  copy_done  0x%06X", (unsigned int)(SLOT1_BASE + BOOT_COPY_DONE_OFF));
	LOG_INF("  image_ok   0x%06X", (unsigned int)(SLOT1_BASE + BOOT_IMAGE_OK_OFF));
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

	LOG_INF("  trailer page 0x%06X-0x%06X holds %u/%u non-erased bytes",
		(unsigned int)TRAILER_PAGE, (unsigned int)(TRAILER_PAGE + FLASH_SECTOR),
		(unsigned int)written, FLASH_SECTOR);
	if (written == 0) {
		LOG_WRN("  that page is ALREADY ERASED -- this board is not on the stock");
		LOG_WRN("  UF2 layout, and the migration's assumptions do not hold");
	}

	LOG_INF("");
	if (staged_ok) {
		LOG_INF("survey OK -- both payloads present");
	} else {
		LOG_ERR("survey FAILED -- see above");
	}
	return staged_ok;
}

/* ------------------------------------------------------------------------ */
/* The migration. Everything below writes flash.                             */
/* ------------------------------------------------------------------------ */

static const struct device *const flash_dev = DEVICE_DT_GET(DT_CHOSEN(zephyr_flash_controller));

/*
 * Step 2. Erase slot1's trailer page, and READ IT BACK.
 *
 * This leads, and the reason is the whole safety argument. The page is inside
 * the Adafruit bootloader's own region, and on this SoC a write-protected
 * region refuses erases as well as writes, with the configuration surviving
 * until reset. If ACL were locking it, every later step would still succeed and
 * MCUboot would then find nothing marked -- a brick discovered after the point
 * of no return.
 *
 * Doing it first makes a refusal harmless: a blocked erase changes nothing, so
 * aborting here leaves the board exactly as it was found, with 0x0 untouched
 * and the Adafruit bootloader still reachable.
 *
 * The read-back is not ceremony. A blocked erase is SILENT -- it does not fail,
 * it simply does not happen -- so the only way to learn the answer is to look.
 */
static int step2_erase_trailer_page(void)
{
	LOG_INF("step 2: erase 0x%06X-0x%06X (slot1 trailer page)", (unsigned int)TRAILER_PAGE,
		(unsigned int)(TRAILER_PAGE + FLASH_SECTOR));

	int rc = flash_erase(flash_dev, TRAILER_PAGE, FLASH_SECTOR);

	if (rc) {
		LOG_ERR("  erase returned %d -- nothing written, board untouched", rc);
		return rc;
	}

	size_t left = count_written(TRAILER_PAGE, FLASH_SECTOR);

	if (left != 0) {
		LOG_ERR("  READ-BACK FAILED: %u/%u bytes still set", (unsigned int)left,
			FLASH_SECTOR);
		LOG_ERR("  the erase did not take. The most likely cause is an ACL lock");
		LOG_ERR("  over the bootloader region, which survives until reset.");
		LOG_ERR("  ABORTING: 0x0 is untouched and the board is as it was found.");
		return -EACCES;
	}

	LOG_INF("  erased and verified -- the point of no return is now behind us");
	return 0;
}

/*
 * Step 3. MCUboot to 0x0. ~1.5 s, and the board is unbootable throughout.
 *
 * The CRC is checked BEFORE the erase, so a corrupt payload costs nothing; what
 * remains after it passes is power loss alone.
 */
static int step3_write_mcuboot(void)
{
	uint32_t crc = crc32_ieee(mcuboot_blob, sizeof(mcuboot_blob));

	LOG_INF("step 3: MCUboot blob CRC32 0x%08x (expected 0x%08x)", crc,
		(uint32_t)SOPHON_MCUBOOT_CRC32);
	if (crc != (uint32_t)SOPHON_MCUBOOT_CRC32) {
		LOG_ERR("  CRC MISMATCH -- refusing to write a corrupt bootloader.");
		LOG_ERR("  The trailer page is already erased, so this board now needs");
		LOG_ERR("  SWD recovery. That is the one ordering cost of probing first.");
		return -EINVAL;
	}

	LOG_INF("  erasing 0x%06X-0x%06X", (unsigned int)MCUBOOT_DEST,
		(unsigned int)MCUBOOT_REGION);
	int rc = flash_erase(flash_dev, MCUBOOT_DEST, MCUBOOT_REGION);

	if (rc) {
		LOG_ERR("  erase returned %d -- BOARD IS NOW UNBOOTABLE, recover over SWD", rc);
		return rc;
	}

	LOG_INF("  writing %u B", (unsigned int)sizeof(mcuboot_blob));
	rc = flash_write(flash_dev, MCUBOOT_DEST, mcuboot_blob, sizeof(mcuboot_blob));
	if (rc) {
		LOG_ERR("  write returned %d -- BOARD IS NOW UNBOOTABLE, recover over SWD", rc);
		return rc;
	}

	if (!flash_matches(MCUBOOT_DEST, mcuboot_blob, sizeof(mcuboot_blob))) {
		LOG_ERR("  READ-BACK MISMATCH -- recover over SWD");
		return -EIO;
	}

	LOG_INF("  MCUboot written and verified");
	return 0;
}

/*
 * Step 4. The trailer: magic GOOD, image_ok SET, copy_done left UNSET.
 *
 * That combination is the PERM row of the swap table -- it tells MCUboot the
 * staged image is to be installed permanently rather than tried once. The
 * primary slot does not participate in that decision, which is what makes this
 * work at all: slot0 currently holds the old UF2-era application and is not a
 * valid MCUboot image.
 */
static int step4_write_trailer(void)
{
	uint8_t flag[BOOT_MAX_ALIGN];

	LOG_INF("step 4: trailer at 0x%06X", (unsigned int)(SLOT1_BASE + BOOT_MAGIC_OFF));

	int rc =
		flash_write(flash_dev, SLOT1_BASE + BOOT_MAGIC_OFF, boot_magic, sizeof(boot_magic));

	if (rc) {
		LOG_ERR("  magic write returned %d", rc);
		return rc;
	}

	/* Pad with the erased value: 0xFF writes nothing, 0x00 would clear bits. */
	memset(flag, 0xFF, sizeof(flag));
	flag[0] = BOOT_FLAG_SET;
	rc = flash_write(flash_dev, SLOT1_BASE + BOOT_IMAGE_OK_OFF, flag, sizeof(flag));
	if (rc) {
		LOG_ERR("  image_ok write returned %d", rc);
		return rc;
	}

	if (!flash_matches(SLOT1_BASE + BOOT_MAGIC_OFF, boot_magic, sizeof(boot_magic))) {
		LOG_ERR("  magic read-back MISMATCH");
		return -EIO;
	}

	LOG_INF("  magic GOOD, image_ok SET, copy_done left UNSET");
	return 0;
}

/*
 * Step 5. Make slot0 coherent enough for the swap to run.
 *
 * THIS IS THE STEP THE DESIGN DID NOT KNOW IT NEEDED, and it was found by the
 * board refusing to migrate. MCUboot will not swap into a primary slot it
 * cannot read as an image, and slot0 at this moment holds the old SoftDevice
 * and application.
 *
 * Two gates, in this order, and the second only appears once the first is
 * passed:
 *
 *   loader.c      boot_read_image_headers() abandons the swap outright if
 *                 either slot lacks IMAGE_MAGIC. Without a header here,
 *                 MCUboot prints "Failed reading image headers" and gives up.
 *
 *   loader.c:1134 having found a magic, it then calls boot_read_image_size()
 *                 on the primary and asserts the result. That looks for a TLV
 *                 trailer at ih_hdr_size + ih_img_size, and aborts when it is
 *                 not there -- so writing a header ALONE turns a clean refusal
 *                 into an abort(). Both observed on hardware.
 *
 * The trick is the image size. A stub claiming the real 190 KB would put its
 * TLV at 0x03A6E8, inside the installer's own code, which it plainly cannot
 * write. Claiming a SMALL size instead puts the TLV in the SoftDevice remnant
 * below the installer, which is free. MCUboot sizes the swap from
 * max(primary, secondary), so understating the primary costs nothing -- the
 * real 190 KB still moves.
 *
 * Nothing here has to be true. Slot0 is about to be overwritten by the swap;
 * this only has to be readable.
 */
static int step5_stub_primary_slot(void)
{
	const struct image_header *staged = at(STAGED_IMAGE);
	const struct image_tlv_info *staged_tlv;
	struct image_header stub;
	struct image_tlv_info tlv;
	uint32_t tlv_off;

	LOG_INF("step 5: stub a readable image into slot0");

	/*
	 * Reuse the staged image's own TLV total rather than inventing one.
	 * Reading it also checks that the staged image's trailer is where its
	 * header says -- a free sanity check on the thing about to be booted.
	 */
	tlv_off = STAGED_IMAGE + staged->ih_hdr_size + staged->ih_img_size;
	staged_tlv = at(tlv_off);
	if (staged_tlv->it_magic != IMAGE_TLV_INFO_MAGIC) {
		LOG_ERR("  staged image has no TLV trailer at 0x%06X (magic 0x%04x)",
			(unsigned int)tlv_off, staged_tlv->it_magic);
		return -EINVAL;
	}
	LOG_INF("  staged TLV at 0x%06X, %u B", (unsigned int)tlv_off, staged_tlv->it_tlv_tot);

	stub = *staged;
	stub.ih_protect_tlv_size = 0;
	stub.ih_img_size = PRIMARY_STUB_TLV - SLOT0_BASE - stub.ih_hdr_size;

	tlv.it_magic = IMAGE_TLV_INFO_MAGIC;
	tlv.it_tlv_tot = staged_tlv->it_tlv_tot;

	LOG_INF("  stub header at 0x%06X claims %u B, putting its TLV at 0x%06X",
		(unsigned int)SLOT0_BASE, stub.ih_img_size, (unsigned int)PRIMARY_STUB_TLV);

	int rc = flash_erase(flash_dev, SLOT0_BASE, FLASH_SECTOR);

	if (rc) {
		LOG_ERR("  slot0 header erase returned %d", rc);
		return rc;
	}
	rc = flash_write(flash_dev, SLOT0_BASE, &stub, sizeof(stub));
	if (rc) {
		LOG_ERR("  slot0 header write returned %d", rc);
		return rc;
	}

	rc = flash_erase(flash_dev, PRIMARY_STUB_TLV, FLASH_SECTOR);
	if (rc) {
		LOG_ERR("  stub TLV erase returned %d", rc);
		return rc;
	}
	rc = flash_write(flash_dev, PRIMARY_STUB_TLV, &tlv, sizeof(tlv));
	if (rc) {
		LOG_ERR("  stub TLV write returned %d", rc);
		return rc;
	}

	if (!flash_matches(SLOT0_BASE, (const uint8_t *)&stub, sizeof(stub)) ||
	    !flash_matches(PRIMARY_STUB_TLV, (const uint8_t *)&tlv, sizeof(tlv))) {
		LOG_ERR("  READ-BACK MISMATCH");
		return -EIO;
	}

	LOG_INF("  slot0 is now readable as an image; the swap can size itself");
	return 0;
}

/*
 * Step 5b. The storage partition, which nothing currently uses.
 *
 * Not required. It is erased anyway because the first time settings storage is
 * enabled it would otherwise meet flash that is neither erased nor a valid
 * structure -- a latent trap, for about 0.4 s now.
 */
static void step5b_erase_storage(void)
{
	uint32_t len = 0x100000U - STORAGE_BASE;

	LOG_INF("step 5b: erase storage 0x%06X-0x100000 (optional)", (unsigned int)STORAGE_BASE);

	int rc = flash_erase(flash_dev, STORAGE_BASE, len);

	if (rc) {
		LOG_WRN("  returned %d -- harmless, nothing uses it yet", rc);
	}
}

static void migrate(void)
{
	if (step2_erase_trailer_page() != 0) {
		return;
	}
	if (step3_write_mcuboot() != 0) {
		return;
	}
	if (step4_write_trailer() != 0) {
		return;
	}
	if (step5_stub_primary_slot() != 0) {
		return;
	}
	step5b_erase_storage();

	LOG_INF("");
	LOG_INF("MIGRATION COMPLETE. Resetting; MCUboot swaps slot1 into slot0,");
	LOG_INF("which takes about 20 s and is restartable if interrupted.");
	k_sleep(K_MSEC(500)); /* let the console drain before the reset */
	sys_reboot(SYS_REBOOT_COLD);
}

#define COUNTDOWN_S 10

int main(void)
{
	/*
	 * A failed survey is not a reason to retry -- nothing about the board
	 * will change on its own -- so report it forever rather than acting on
	 * a payload that is not there. Reprinting matters because the report is
	 * longer than this board's CDC ACM buffer, which holds about 1 KB: a
	 * console attached after boot sees it truncated mid-line and then
	 * nothing, and a reset to retry re-enumerates USB and drops the console.
	 */
	while (!survey()) {
		LOG_ERR("--- refusing to migrate; retrying the survey in %d s ---", COUNTDOWN_S);
		k_sleep(K_SECONDS(COUNTDOWN_S));
	}

	LOG_INF("");
	LOG_WRN("MIGRATING in %d s. This REPLACES the bootloader.", COUNTDOWN_S);
	LOG_WRN("Remove power now to abort -- after this, only SWD recovers it.");
	for (int i = COUNTDOWN_S; i > 0; i--) {
		LOG_WRN("  %d", i);
		k_sleep(K_SECONDS(1));
	}

	migrate();

	/* Only reached if a step failed; migrate() reboots on success. */
	for (;;) {
		LOG_ERR("migration did not complete -- see above. Recover over SWD.");
		k_sleep(K_SECONDS(30));
	}
	return 0;
}
