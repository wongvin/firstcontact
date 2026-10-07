/*
 * Sophon flash dumper (#297) -- READS ONLY.
 *
 * Reads the whole chip out over the CDC ACM console, so a board can be backed
 * up with no probe. That closes the contradiction #294 left behind: a
 * probe-free migration whose first instruction was "attach a probe".
 *
 * WHAT IT CANNOT SAVE. This application is itself delivered as a UF2, so the
 * bootloader writes it to 0x27000 and the ORIGINAL APPLICATION THERE IS GONE
 * before a single byte is read. Everything else survives, which is the whole
 * reason this works:
 *
 *   MBR         0x000000-0x001000   below the dumper
 *   SoftDevice  0x001000-0x027000   below the dumper, ending just under it
 *   application 0x027000-           CLOBBERED -- and the one part rebuildable
 *   storage     0x0EC000-           above
 *   bootloader  0x0F4000-0x100000   above
 *   UICR        0x10001000-         a different region entirely
 *
 * So the dump is a recovery image, not a perfect snapshot. It restores a board
 * to a working bootloader with a broken application, which a UF2 copy then
 * fixes. That is enough, because the application is the only part this repo can
 * regenerate.
 *
 * THIS MAKES PREPARATION PROBE-FREE, NOT RECOVERY. Restoring MBR, SoftDevice or
 * bootloader means writing outside the UF2 application window, and is
 * unreachable once the bootloader is gone -- which is the failure case. SWD
 * remains the restore path. The gain is that the probe is no longer needed to
 * TAKE the safety net, only to use it.
 */

#include <string.h>

#include <zephyr/devicetree.h>
#include <zephyr/drivers/hwinfo.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/crc.h>
#include <zephyr/sys/printk.h>

/*
 * From devicetree, not written down. The chip's size is not this tool's
 * business to know, and hard-coding it is how a dumper silently truncates on a
 * part it was not built for.
 */
#define FLASH_BASE DT_REG_ADDR(DT_CHOSEN(zephyr_flash))
#define FLASH_SIZE DT_REG_SIZE(DT_CHOSEN(zephyr_flash))

/*
 * UICR is the one genuinely SoC-specific thing here, and it has to be dumped:
 * it holds the bootloader address and the reset-pin selection, so a board
 * restored without it has no bootloader pointer and a dead reset button.
 * Guarded so this file still builds on a part that has no such region.
 */
#if defined(CONFIG_SOC_FAMILY_NORDIC_NRF)
#define UICR_BASE 0x10001000U
#define UICR_SIZE 0x00001000U
#endif

/*
 * 192 bytes per line, so a data line is 384 hex characters plus framing. Hex
 * rather than base64 to keep the host side dependency-free and the encoding
 * impossible to get subtly wrong; the size cost is paid back by the run-length
 * skip below, since most of this chip is erased.
 */
#define CHUNK 192

/* 384 hex + offset + crc + framing, with room to spare. */
static char line[512];

/*
 * PACING, AND WHY IT IS NOT OPTIONAL.
 *
 * printk() on CDC ACM goes through uart_poll_out(), which enqueues into a ring
 * the USB stack drains a frame at a time. It does not block when that ring is
 * full -- it DISCARDS. There is no flow control anywhere in this path, so a
 * dumper emitting as fast as it can silently loses lines.
 *
 * Observed on the first run: the stream jumped from offset 0x480 to 0xfc0,
 * fifteen chunks gone, at the same place on every attempt. Deterministic,
 * because the ring fills at a consistent point. The host saw no error from the
 * serial layer; it was only caught because every line carries its offset.
 *
 * One millisecond per line matches the USB frame interval, so the ring gets a
 * chance to drain between lines. It costs a few seconds across a 1 MB dump and
 * buys the difference between a backup and a plausible-looking fiction.
 */
#define LINE_PACE_MS 1

static const uint8_t *at(uint32_t addr)
{
	return (const uint8_t *)(uintptr_t)addr;
}

static bool all_erased(const uint8_t *p, size_t len)
{
	for (size_t i = 0; i < len; i++) {
		if (p[i] != 0xFF) {
			return false;
		}
	}
	return true;
}

static void emit_hex(char *dst, const uint8_t *src, size_t len)
{
	static const char hexdigits[] = "0123456789abcdef";

	for (size_t i = 0; i < len; i++) {
		dst[i * 2] = hexdigits[src[i] >> 4];
		dst[i * 2 + 1] = hexdigits[src[i] & 0xF];
	}
	dst[len * 2] = '\0';
}

/*
 * Runs of erased flash are emitted as a count rather than as 0xFF repeated.
 * Most of a 1 MB part is erased, and without this the dump is ~2 MB of hex
 * down a console that pushes maybe 100 KB/s.
 *
 * The host fills skipped ranges with 0xFF and then checks the whole-region
 * CRC32, so a skip cannot quietly lose data: a wrong skip count fails the
 * region check.
 */
static void dump_region(const char *name, uint32_t base, uint32_t size)
{
	uint32_t crc = 0;
	uint32_t off = 0;

	printk("b %s %08x %08x %u\n", name, base, size, CHUNK);

	while (off < size) {
		uint32_t len = MIN((uint32_t)CHUNK, size - off);
		const uint8_t *p = at(base + off);

		if (len == CHUNK && all_erased(p, len)) {
			uint32_t runs = 0;

			while (off < size && (size - off) >= CHUNK &&
			       all_erased(at(base + off), CHUNK)) {
				crc = crc32_ieee_update(crc, at(base + off), CHUNK);
				off += CHUNK;
				runs++;
			}
			printk("z %08x %u\n", off - runs * CHUNK, runs);
			k_sleep(K_MSEC(LINE_PACE_MS));
			continue;
		}

		emit_hex(line, p, len);
		printk("d %08x %s %08x\n", off, line, crc32_ieee(p, len));
		k_sleep(K_MSEC(LINE_PACE_MS));
		crc = crc32_ieee_update(crc, p, len);
		off += len;
	}

	printk("e %s %08x\n", name, crc);
}

static void dump(void)
{
	uint8_t id[8];
	ssize_t n;

	printk("\n=== SOPHON-DUMP v1 BEGIN\n");

	/*
	 * The WHOLE device id, and no product name. FICR DEVICEID is in neither
	 * flash nor UICR, so it is neither backed up nor restorable -- which is
	 * also why a backup restored onto a different board keeps that board's
	 * identity rather than the donor's.
	 *
	 * What to call the board is the host's business, not this file's: a
	 * dumper that prints a product name is a dumper that belongs to one
	 * project. Emitting all eight bytes also gives the host strictly more
	 * than the two Sophon happens to use (src/ident.c).
	 */
	n = hwinfo_get_device_id(id, sizeof(id));
	printk("id ");
	for (ssize_t i = 0; i < n; i++) {
		printk("%02x", id[i]);
	}
	printk("\n");

	dump_region("flash", FLASH_BASE, FLASH_SIZE);
#if defined(UICR_BASE)
	dump_region("uicr", UICR_BASE, UICR_SIZE);
#endif

	printk("=== SOPHON-DUMP v1 END\n");
}

int main(void)
{
	/*
	 * Repeat rather than dump once, and do not wait for a trigger.
	 *
	 * The console cannot be relied on to be attached when the board boots,
	 * and a dump that has already scrolled past is worse than useless --
	 * the host has no way to ask for another without resetting the board.
	 * Looping means the capture tool can start whenever and wait for the
	 * next BEGIN. A trigger byte or a DTR handshake would both be tidier
	 * and both add a way for this to not start at all.
	 */
	for (;;) {
		dump();
		k_sleep(K_SECONDS(5));
	}
	return 0;
}
