/*
 * Device configuration set from the app (#329). See config.h, CONFIG-PLAN.md
 * and PROTOCOL.md § Config frame.
 *
 * Three copies of the config matter, and keeping them apart is what lets the
 * app show "running now" against "after restart":
 *
 *   stored -- what flash holds now, updated as soon as a write is saved
 *   boot   -- what this boot runs on: the stored config as loaded at boot, or
 *             the defaults if there was none or the boot-loop guard tripped
 *   active -- boot, resolved: the role actually chosen, the preset id rather
 *             than "default", the locked-on peer
 *
 * A write never changes what is running. It takes effect at the next boot,
 * which the write can ask for.
 */

#include <string.h>

#include <zephyr/bluetooth/att.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/byteorder.h>

#if defined(CONFIG_SETTINGS)
#include <zephyr/settings/settings.h>
#endif
#if defined(CONFIG_REBOOT)
#include <zephyr/sys/reboot.h>
#endif

#include <hal/nrf_power.h>

#include "config.h"
#include "lora_link.h"
#include "lora_presets.h"
#include "slow_work.h"

LOG_MODULE_REGISTER(sophon_config, LOG_LEVEL_INF);

#define SETTINGS_KEY "sophon/cfg"

/* The stored record: a version byte, then the config as on the wire. */
#define RECORD_VERSION 1
#define RECORD_SIZE    10

/*
 * BOOT-LOOP GUARD. A config can't stop the app reaching a healthy board (the
 * lockout analysis in CONFIG-PLAN.md), but one that triggers a firmware fault
 * at boot would crash-loop it with Bluetooth never up. So each boot counts
 * itself in GPREGRET2, a register that survives a reset (not power-off), and
 * a boot that comes up clears it. After GUARD_TRIPS boots in a row that never
 * got that far, the stored config is ignored for one boot -- not erased, so
 * the app can still show it before restoring defaults.
 *
 * The high nibble marks the register as ours: it powers up as zero, and MCUboot
 * here uses none of the retention registers.
 */
#define GUARD_REG   1 /* GPREGRET2 */
#define GUARD_MAGIC 0xA0U
#define GUARD_MASK  0xF0U
#define GUARD_TRIPS 3

static const struct sophon_config defaults = {
	.role = SOPHON_CONFIG_ROLE_AUTO,
	.preset = SOPHON_CONFIG_PRESET_DEFAULT,
	.tx_dbm = SOPHON_CONFIG_TX_DEFAULT,
	.freq_hz = SOPHON_CONFIG_FREQ_DEFAULT,
	.peer_id = CONFIG_SOPHON_LORA_PEER_ID,
};

static struct k_spinlock lock;
static struct sophon_config stored; /* guarded by lock */
static struct sophon_config boot;   /* fixed after sophon_config_init() */
static bool boot_from_flash;        /* boot came from a stored record */
static bool guard_tripped;
static bool hw_radio;
static bool hw_imu;
static bool hw_forced;

#if defined(CONFIG_SETTINGS)
/* A write accepted and waiting for the slow work queue to save it. */
static struct sophon_config pending;
static uint8_t pending_flags;
#endif

static bool config_valid(const struct sophon_config *c)
{
	if (c->role > SOPHON_CONFIG_ROLE_GATEWAY) {
		return false;
	}
	if (c->preset != SOPHON_CONFIG_PRESET_DEFAULT && c->preset >= LORA_PRESET_COUNT) {
		return false;
	}
	if (c->tx_dbm != SOPHON_CONFIG_TX_DEFAULT &&
	    (c->tx_dbm < SOPHON_CONFIG_TX_MIN_DBM || c->tx_dbm > SOPHON_CONFIG_TX_MAX_DBM)) {
		return false;
	}
	if (c->freq_hz != SOPHON_CONFIG_FREQ_DEFAULT &&
	    (c->freq_hz < SOPHON_CONFIG_FREQ_MIN_HZ || c->freq_hz > SOPHON_CONFIG_FREQ_MAX_HZ)) {
		return false;
	}
	return true;
}

/* The nine bytes role..peer, shared by the record, the write and the read. */
static void pack_fields(const struct sophon_config *c, uint8_t out[9])
{
	out[0] = c->role;
	out[1] = c->preset;
	out[2] = (uint8_t)c->tx_dbm;
	sys_put_le32(c->freq_hz, &out[3]);
	sys_put_le16(c->peer_id, &out[7]);
}

static void unpack_fields(const uint8_t in[9], struct sophon_config *c)
{
	c->role = in[0];
	c->preset = in[1];
	c->tx_dbm = (int8_t)in[2];
	c->freq_hz = sys_get_le32(&in[3]);
	c->peer_id = sys_get_le16(&in[7]);
}

static bool config_equal(const struct sophon_config *a, const struct sophon_config *b)
{
	return a->role == b->role && a->preset == b->preset && a->tx_dbm == b->tx_dbm &&
	       a->freq_hz == b->freq_hz && a->peer_id == b->peer_id;
}

/* ------------------------------------------------------------- persistence */

#if defined(CONFIG_SETTINGS)
/*
 * Settings are MCUboot-build only (swd/app-mcuboot.conf). Without them a board
 * runs on the build's defaults and refuses config writes.
 */
static int load_cb(const char *key, size_t len, settings_read_cb read_cb, void *cb_arg, void *param)
{
	uint8_t rec[RECORD_SIZE];
	struct sophon_config c;
	bool *found = param;

	if (key != NULL || len != sizeof(rec) || read_cb(cb_arg, rec, sizeof(rec)) != sizeof(rec)) {
		LOG_WRN("stored config unreadable (%u bytes) -- using defaults", (unsigned int)len);
		return 0;
	}
	if (rec[0] != RECORD_VERSION) {
		LOG_WRN("stored config version %u unknown -- using defaults", rec[0]);
		return 0;
	}
	unpack_fields(&rec[1], &c);
	if (!config_valid(&c)) {
		LOG_WRN("stored config out of range -- using defaults");
		return 0;
	}
	stored = c;
	*found = true;
	return 0;
}

static void save_work_handler(struct k_work *work)
{
	struct sophon_config c;
	uint8_t flags;
	int err;

	ARG_UNUSED(work);

	K_SPINLOCK(&lock) {
		c = pending;
		flags = pending_flags;
	}

	if (flags & SOPHON_CONFIG_FLAG_DEFAULTS) {
		err = settings_delete(SETTINGS_KEY);
		c = defaults;
	} else {
		uint8_t rec[RECORD_SIZE] = {RECORD_VERSION};

		pack_fields(&c, &rec[1]);
		err = settings_save_one(SETTINGS_KEY, rec, sizeof(rec));
	}

	if (err) {
		LOG_ERR("config not saved (%d) -- the stored config is unchanged", err);
		return;
	}

	K_SPINLOCK(&lock) {
		stored = c;
	}
	LOG_INF("config %s: role %u preset %u tx %d freq %u peer %04X",
		(flags & SOPHON_CONFIG_FLAG_DEFAULTS) ? "reset to defaults" : "saved", c.role,
		c.preset, c.tx_dbm, c.freq_hz, c.peer_id);

	if (flags & SOPHON_CONFIG_FLAG_RESTART) {
#if defined(CONFIG_REBOOT)
		/*
		 * Long enough for the write response, already sent from the BT RX
		 * thread, to have gone out over the air.
		 */
		LOG_INF("restarting to apply the config");
		k_msleep(500);
		sys_reboot(SYS_REBOOT_WARM);
#else
		LOG_WRN("restart requested, but this build cannot reboot itself");
#endif
	}
}

static K_WORK_DEFINE(save_work, save_work_handler);
#endif /* CONFIG_SETTINGS */

/* ------------------------------------------------------------------- guard */

static bool guard_count_boot(void)
{
	uint32_t reg = nrf_power_gpregret_get(NRF_POWER, GUARD_REG);
	uint32_t failed = ((reg & GUARD_MASK) == GUARD_MAGIC) ? (reg & 0x0FU) : 0;

	/* This boot counts as failed until sophon_config_mark_healthy(). */
	nrf_power_gpregret_set(NRF_POWER, GUARD_REG, GUARD_MAGIC | MIN(failed + 1, 0x0FU));
	return failed >= GUARD_TRIPS;
}

void sophon_config_mark_healthy(void)
{
	nrf_power_gpregret_set(NRF_POWER, GUARD_REG, 0);
}

/* -------------------------------------------------------------------- init */

void sophon_config_init(void)
{
	bool found = false;

	stored = defaults;
	guard_tripped = guard_count_boot();

#if defined(CONFIG_SETTINGS)
	int err = settings_subsys_init();

	if (err) {
		LOG_ERR("settings unavailable (%d) -- running on defaults", err);
	} else {
		(void)settings_load_subtree_direct(SETTINGS_KEY, load_cb, &found);
	}
#endif

	if (guard_tripped) {
		LOG_ERR("%d boots in a row failed to come up -- ignoring the stored config "
			"for this boot (it is kept; restore defaults from the app)",
			GUARD_TRIPS);
		boot = defaults;
	} else {
		boot = stored;
		boot_from_flash = found;
	}

	LOG_INF("config: role %u, preset %u, tx %d, freq %u, peer %04X (%s)", boot.role,
		sophon_config_preset_id(), boot.tx_dbm, sophon_config_freq_hz(), boot.peer_id,
		guard_tripped ? "guard tripped"
		: found       ? "from flash"
			      : "defaults");
}

const struct sophon_config *sophon_config_boot(void)
{
	return &boot;
}

uint8_t sophon_config_preset_id(void)
{
	return boot.preset == SOPHON_CONFIG_PRESET_DEFAULT ? CONFIG_SOPHON_LORA_PRESET
							   : boot.preset;
}

uint32_t sophon_config_freq_hz(void)
{
	return boot.freq_hz == SOPHON_CONFIG_FREQ_DEFAULT ? CONFIG_SOPHON_LORA_FREQ_HZ
							  : boot.freq_hz;
}

int8_t sophon_config_tx_override(void)
{
	return boot.tx_dbm;
}

void sophon_config_set_hardware(bool radio, bool imu, bool forced)
{
	hw_radio = radio;
	hw_imu = imu;
	hw_forced = forced;
}

/* -------------------------------------------------------------- the GATT side */

uint8_t sophon_config_write(const uint8_t *buf, uint16_t len)
{
	struct sophon_config c;
	uint8_t flags;

	if (len != SOPHON_CONFIG_WRITE_SIZE) {
		return BT_ATT_ERR_INVALID_ATTRIBUTE_LEN;
	}
	if (buf[0] != SOPHON_CONFIG_VERSION || buf[11] != 0) {
		return BT_ATT_ERR_VALUE_NOT_ALLOWED;
	}
	unpack_fields(&buf[1], &c);
	flags = buf[10];
	if (flags & ~(SOPHON_CONFIG_FLAG_RESTART | SOPHON_CONFIG_FLAG_DEFAULTS)) {
		return BT_ATT_ERR_VALUE_NOT_ALLOWED;
	}

	/* "Defaults" ignores the fields: it erases the record whatever they say. */
	if (!(flags & SOPHON_CONFIG_FLAG_DEFAULTS)) {
		if (!config_valid(&c)) {
			return BT_ATT_ERR_VALUE_NOT_ALLOWED;
		}
		/*
		 * Only roles this hardware supports, so a stored role is always one
		 * the board could run when it was set.
		 */
		if (c.role == SOPHON_CONFIG_ROLE_SENSOR && !(hw_radio && hw_imu)) {
			return BT_ATT_ERR_VALUE_NOT_ALLOWED;
		}
		if (c.role == SOPHON_CONFIG_ROLE_GATEWAY && !hw_radio) {
			return BT_ATT_ERR_VALUE_NOT_ALLOWED;
		}
	}

#if !defined(CONFIG_SETTINGS)
	return BT_ATT_ERR_WRITE_NOT_PERMITTED;
#else
	/* A save already queued is overwritten: the last write wins. */
	K_SPINLOCK(&lock) {
		pending = c;
		pending_flags = flags;
	}
	(void)sophon_slow_work_submit(&save_work);
	return 0;
#endif
}

void sophon_config_read(uint8_t out[SOPHON_CONFIG_READ_SIZE])
{
	struct sophon_config now;
	struct sophon_config active = boot;
	const struct lora_preset *preset;
	enum sophon_role role = sophon_role();
	uint8_t status = 0;

	K_SPINLOCK(&lock) {
		now = stored;
	}

	active.role = role == SOPHON_ROLE_SENSOR    ? SOPHON_CONFIG_ROLE_SENSOR
		      : role == SOPHON_ROLE_GATEWAY ? SOPHON_CONFIG_ROLE_GATEWAY
						    : SOPHON_CONFIG_ROLE_DIRECT;
	active.preset = sophon_config_preset_id();
	preset = lora_preset_get(active.preset);
	active.tx_dbm = boot.tx_dbm != SOPHON_CONFIG_TX_DEFAULT ? boot.tx_dbm
								: (preset ? preset->tx_dbm : 0);
	active.freq_hz = sophon_config_freq_hz();
	active.peer_id = role == SOPHON_ROLE_GATEWAY ? lora_link_peer_id() : boot.peer_id;

	status |= hw_radio ? SOPHON_CONFIG_STATUS_RADIO : 0;
	status |= hw_imu ? SOPHON_CONFIG_STATUS_IMU : 0;
	status |= !config_equal(&now, &boot) ? SOPHON_CONFIG_STATUS_PENDING : 0;
	status |= hw_forced ? SOPHON_CONFIG_STATUS_FORCED : 0;
	status |= boot_from_flash ? SOPHON_CONFIG_STATUS_STORED : 0;
	status |= guard_tripped ? SOPHON_CONFIG_STATUS_GUARD : 0;

	out[0] = SOPHON_CONFIG_VERSION;
	pack_fields(&now, &out[1]);
	pack_fields(&active, &out[10]);
	out[19] = status;
}
