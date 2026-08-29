#include <string.h>

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/byteorder.h>

#include <sophon_build_time.h>

#include "ble.h"
#include "ident.h"
#include "version.h"

LOG_MODULE_REGISTER(sophon_ble, LOG_LEVEL_INF);

/*
 * Frozen UUIDs -- see PROTOCOL.md. The iOS side hardcodes the same strings in
 * SophonProtocol.swift; they must not drift.
 *
 *   Service:     C6560001-84D5-4DC2-8C1E-4B4EB2337CE4
 *   Motion Data: C6560002-84D5-4DC2-8C1E-4B4EB2337CE4  (notify)
 *   TX Stats:    C6560003-84D5-4DC2-8C1E-4B4EB2337CE4  (read)
 */
#define SOPHON_UUID_SERVICE \
	BT_UUID_128_ENCODE(0xC6560001, 0x84D5, 0x4DC2, 0x8C1E, 0x4B4EB2337CE4)
#define SOPHON_UUID_MOTION \
	BT_UUID_128_ENCODE(0xC6560002, 0x84D5, 0x4DC2, 0x8C1E, 0x4B4EB2337CE4)
#define SOPHON_UUID_STATS \
	BT_UUID_128_ENCODE(0xC6560003, 0x84D5, 0x4DC2, 0x8C1E, 0x4B4EB2337CE4)

static const struct bt_uuid_128 sophon_service_uuid =
	BT_UUID_INIT_128(SOPHON_UUID_SERVICE);
static const struct bt_uuid_128 sophon_motion_uuid =
	BT_UUID_INIT_128(SOPHON_UUID_MOTION);
static const struct bt_uuid_128 sophon_stats_uuid =
	BT_UUID_INIT_128(SOPHON_UUID_STATS);

static struct bt_conn *current_conn;
static bool motion_subscribed;
static char device_name[SOPHON_NAME_MAX];
static struct sophon_tx_stats tx_stats;

static void motion_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	ARG_UNUSED(attr);

	motion_subscribed = (value == BT_GATT_CCC_NOTIFY);
	LOG_INF("motion notifications %s", motion_subscribed ? "subscribed" : "unsubscribed");
}

/*
 * Read handler for the stats characteristic.
 *
 * Read rather than notify on purpose: these counters move slowly and are
 * diagnostics, and a notification would spend connection-event budget -- the
 * very resource #211 exists to measure. Instrumenting a scarce resource by
 * consuming it defeats the point.
 */
static ssize_t stats_read(struct bt_conn *conn, const struct bt_gatt_attr *attr,
			  void *buf, uint16_t len, uint16_t offset)
{
	struct sophon_tx_stats snapshot;
	uint8_t wire[SOPHON_STATS_SIZE];

	ARG_UNUSED(conn);

	sophon_ble_tx_stats(&snapshot);
	sophon_stats_pack(&snapshot, wire);

	return bt_gatt_attr_read(conn, attr, buf, len, offset, wire, sizeof(wire));
}

BT_GATT_SERVICE_DEFINE(sophon_svc,
	BT_GATT_PRIMARY_SERVICE(&sophon_service_uuid),
	BT_GATT_CHARACTERISTIC(&sophon_motion_uuid.uuid,
			       BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_NONE, /* notify-only: never read directly */
			       NULL, NULL, NULL),
	BT_GATT_CCC(motion_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
	BT_GATT_CHARACTERISTIC(&sophon_stats_uuid.uuid,
			       BT_GATT_CHRC_READ,
			       BT_GATT_PERM_READ,
			       stats_read, NULL, NULL),
);

/*
 * The advertisement and the scan response are SEPARATE 31-byte budgets, not one
 * shared pool. Every field costs 1 length byte + 1 type byte before its payload
 * (Zephyr calls that sum BT_DATA_SERIALIZED_SIZE).
 *
 * Advertisement -- 21 of 31, 10 spare:
 *   flags                 1+1+1  =  3 B
 *   128-bit service UUID  1+1+16 = 18 B
 *
 * The name does not fit alongside the UUID here (3 + 18 + 13 = 34 > 31), which
 * is why it lives in the scan response with everything else. Getting either
 * budget wrong surfaces only as a bare -EINVAL from bt_le_adv_start(), so the
 * scan response is bounded by a BUILD_ASSERT below.
 */
static const struct bt_data adv_data[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
	BT_DATA_BYTES(BT_DATA_UUID128_ALL, SOPHON_UUID_SERVICE),
};

/*
 * Who we are, readable before connecting. One structure rather than two: a
 * second one with the same company ID has undefined merge behaviour on iOS,
 * which exposes a single CBAdvertisementDataManufacturerDataKey.
 */
static const struct sophon_mfg_data mfg_data = {
	.company_id       = SOPHON_COMPANY_ID,
	.scan_rsp_version = SOPHON_SCAN_RSP_VERSION,
	.device_type      = SOPHON_DEVICE_TYPE,
	.hw_version       = SOPHON_HW_VERSION,
	.fw_version_major = SOPHON_FW_VERSION_MAJOR,
	.fw_version_minor = SOPHON_FW_VERSION_MINOR,
};

/*
 * Scan response -- 26 of 31, 5 spare:
 *   complete local name   1+1+11 = 13 B   worst case, "Sophon-4D88"
 *   TX power              1+1+1  =  3 B
 *   manufacturer data     1+1+8  = 10 B
 *
 * Bound the worst case at compile time. The name is the only runtime-sized
 * entry and SOPHON_NAME_MAX - 1 is its longest form, so this is exact rather
 * than approximate. Note sizeof(scan_rsp) would NOT work: struct bt_data holds
 * {type, data_len, *data}, so it measures descriptors, not on-air bytes.
 */
BUILD_ASSERT(BT_DATA_SERIALIZED_SIZE(SOPHON_NAME_MAX - 1) +
		     BT_DATA_SERIALIZED_SIZE(1) +
		     BT_DATA_SERIALIZED_SIZE(sizeof(struct sophon_mfg_data)) <=
	     BT_GAP_ADV_MAX_ADV_DATA_LEN,
	     "Sophon scan response exceeds the legacy 31-byte limit");

static int start_advertising(void)
{
	/*
	 * Function-local rather than static const like adv_data[], because the
	 * name entry's length is only known at runtime.
	 *
	 * Do NOT replace strlen() with 11: the name is 6 bytes on the hwinfo
	 * fallback path (see ident.c), and a hardcoded 11 would broadcast the
	 * terminator plus 4 bytes of uninitialised buffer.
	 *
	 * TX power is the standard AD type rather than a byte of ours, because
	 * iOS then fills CBAdvertisementDataTxPowerLevelKey for free. Zephyr
	 * cannot insert it automatically here -- BT_LE_ADV_OPT_USE_TX_POWER
	 * requires extended advertising, and this is legacy.
	 *
	 * It comes from the same Kconfig that sets the radio, which keeps the two
	 * in step only as long as the configured value is one the radio actually
	 * has. hal_radio_tx_power_value() rounds DOWN to a native step while this
	 * symbol keeps the requested number, so a non-native choice would put a
	 * value on the air that the radio never transmits. prj.conf lists the
	 * native steps and says so.
	 */
	const struct bt_data scan_rsp[] = {
		BT_DATA(BT_DATA_NAME_COMPLETE, device_name, strlen(device_name)),
		BT_DATA_BYTES(BT_DATA_TX_POWER, CONFIG_BT_CTLR_TX_PWR_DBM),
		BT_DATA(BT_DATA_MANUFACTURER_DATA, &mfg_data, sizeof(mfg_data)),
	};
	int err;

	err = bt_le_adv_start(BT_LE_ADV_CONN_FAST_1,
			      adv_data, ARRAY_SIZE(adv_data),
			      scan_rsp, ARRAY_SIZE(scan_rsp));
	if (err) {
		LOG_ERR("bt_le_adv_start failed (%d) -- if -22/-EINVAL, the "
			"advertising payload is over 31 bytes", err);
		return err;
	}

	LOG_INF("advertising as %s (scan rsp %zu B of %d)", device_name,
		bt_data_get_len(scan_rsp, ARRAY_SIZE(scan_rsp)),
		BT_GAP_ADV_MAX_ADV_DATA_LEN);
	return 0;
}

/*
 * Advertising does not resume by itself after a disconnect -- the ONE_TIME
 * option that used to control this no longer exists, and the upstream samples
 * restart explicitly. It is deferred to the system work queue rather than done
 * in the callback, which runs on the Bluetooth RX thread.
 */
static void adv_work_handler(struct k_work *work)
{
	ARG_UNUSED(work);
	(void)start_advertising();
}

static K_WORK_DEFINE(adv_work, adv_work_handler);

static void connected(struct bt_conn *conn, uint8_t err)
{
	if (err) {
		LOG_ERR("connection failed (0x%02x)", err);
		k_work_submit(&adv_work);
		return;
	}

	current_conn = bt_conn_ref(conn);

	/*
	 * Log the negotiated MTU rather than assuming it. Expect 23 -- if it
	 * ever reads lower, notify starts failing with -EMSGSIZE and this line
	 * is what explains why.
	 */
	LOG_INF("connected, ATT MTU %u", bt_gatt_get_mtu(conn));
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
	ARG_UNUSED(conn);

	LOG_INF("disconnected (0x%02x)", reason);

	if (current_conn) {
		bt_conn_unref(current_conn);
		current_conn = NULL;
	}
	motion_subscribed = false;

	k_work_submit(&adv_work);
}

BT_CONN_CB_DEFINE(conn_callbacks) = {
	.connected = connected,
	.disconnected = disconnected,
};

bool sophon_ble_connected(void)
{
	return current_conn != NULL;
}

bool sophon_ble_subscribed(void)
{
	return motion_subscribed;
}

int sophon_ble_notify(const struct sophon_frame *frame)
{
	int err;

	if (!current_conn || !motion_subscribed) {
		tx_stats.no_conn++;
		return -ENOTCONN;
	}

	err = bt_gatt_notify_uuid(current_conn, &sophon_motion_uuid.uuid,
				  sophon_svc.attrs, frame, SOPHON_FRAME_SIZE);

	/*
	 * Note what is NOT done here: seq is not rewound or reused on failure.
	 * A sample that was taken and not delivered is a hole the consumer must
	 * be able to see -- suppressing it would hand the central a stream that
	 * looks continuous while silently missing an interval, and the fusion in
	 * #210 would integrate straight across it. Attribution is what these
	 * counters are for; the sequence stays honest.
	 */
	switch (err) {
	case 0:
		tx_stats.sent++;
		break;
	case -ENOMEM:
		tx_stats.no_mem++;
		break;
	case -ENOTCONN:
		tx_stats.no_conn++;
		break;
	default:
		tx_stats.other++;
		break;
	}

	return err;
}

void sophon_stats_pack(const struct sophon_tx_stats *in, uint8_t out[SOPHON_STATS_SIZE])
{
	sys_put_le32(in->sent,    &out[0]);
	sys_put_le32(in->no_conn, &out[4]);
	sys_put_le32(in->no_mem,  &out[8]);
	sys_put_le32(in->other,   &out[12]);
}

void sophon_ble_tx_stats(struct sophon_tx_stats *out)
{
	/*
	 * Read under the scheduler lock: the counters are written from whichever
	 * thread produces frames -- the IMU's data-ready thread, or the system
	 * work queue in the no-IMU fallback -- and read from the main thread. A
	 * torn read across the struct would report a state that never existed.
	 *
	 * Both writers are threads, never ISRs, so locking out preemption is
	 * enough; no spinlock is needed.
	 */
	k_sched_lock();
	*out = tx_stats;
	k_sched_unlock();
}

int sophon_ble_init(void)
{
	int err;

	err = bt_enable(NULL);
	if (err) {
		LOG_ERR("bt_enable failed (%d)", err);
		return err;
	}

	err = sophon_device_name(device_name, sizeof(device_name));
	if (err) {
		LOG_ERR("device name failed (%d)", err);
		return err;
	}

	err = bt_set_name(device_name);
	if (err) {
		LOG_ERR("bt_set_name failed (%d)", err);
		return err;
	}

	return start_advertising();
}
