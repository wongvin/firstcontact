/*
 * The LoRa link (#303). LORA-PROTOCOL.md is the contract; this is one end of
 * it for each role.
 *
 * SENSOR. The IMU's data-ready thread drops each frame into sensor_queue and
 * returns at once -- that thread must never block (see main.c). A dedicated
 * thread gathers frames into a packet under the packing rules and sends it
 * with the blocking lora_send(), so radio time never lands on the IMU thread.
 *
 * GATEWAY. loramac-node's async receive re-arms itself after every packet and
 * runs its callback on the system work queue. The callback decodes, tracks seq
 * continuity, keeps the sensor's latest status, and hands each rebuilt frame to
 * main.c, which owns the BLE delivery queue.
 */

#include <string.h>

#include <zephyr/device.h>
#include <zephyr/drivers/lora.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/spinlock.h>

#include "battery.h"
#include "ble.h"
#include "ident.h"
#include "lora_codec.h"
#include "lora_link.h"
#include "lora_presets.h"

LOG_MODULE_REGISTER(sophon_lora, LOG_LEVEL_INF);

static const struct device *const lora_dev = DEVICE_DT_GET(DT_NODELABEL(lora0));

static const struct lora_preset *preset;

/* Stats are logged every STATS_PERIOD_MS and reset, like a rate. */
#define STATS_PERIOD_MS 10000

/*
 * Nominal sample period, rounded up from the measured 18.4 ms (54.3 Hz). The
 * flush deadline -- packing rule 4 -- is k of these plus slack, so a stalled
 * IMU cannot hold a partly filled packet indefinitely.
 */
#define SAMPLE_PERIOD_MS 19
#define FLUSH_SLACK_MS   20

/* A status trailer at most this often (LORA-PROTOCOL.md). */
#define STATUS_PERIOD_MS 1000

/* A seq jump at least this large is a sensor restart, not loss. */
#define SEQ_RESYNC_GAP 1024

static int configure(bool tx)
{
	struct lora_modem_config cfg = {
		.frequency = CONFIG_SOPHON_LORA_FREQ_HZ,
		.bandwidth = BW_500_KHZ,
		.datarate = (enum lora_datarate)preset->sf,
		.coding_rate = (enum lora_coding_rate)preset->cr,
		.preamble_len = LORA_PREAMBLE_LEN,
		.tx_power = preset->tx_dbm,
		.tx = tx,
		.iq_inverted = false,
		.public_network = false, /* the private sync word */
		.packet_crc_disable = false,
	};

	return lora_config(lora_dev, &cfg);
}

/* ------------------------------------------------------------------ sensor */

#define SENSOR_QUEUE_DEPTH 32
K_MSGQ_DEFINE(sensor_queue, sizeof(struct sophon_frame), SENSOR_QUEUE_DEPTH, 4);

#define SENSOR_STACK_SIZE 1536
#define SENSOR_PRIORITY   K_PRIO_PREEMPT(8)
K_THREAD_STACK_DEFINE(sensor_stack, SENSOR_STACK_SIZE);
static struct k_thread sensor_thread;

static struct {
	uint32_t packets;
	uint32_t send_err;
	uint32_t samples;
	uint32_t dropped; /* sensor_queue full */
} sensor_stats;

void lora_link_submit(const struct sophon_frame *frame)
{
	if (k_msgq_put(&sensor_queue, frame, K_NO_WAIT) != 0) {
		sensor_stats.dropped++;
	}
}

static void fill_status(struct lora_status *s)
{
	uint16_t tag = 0;

	(void)sophon_device_tag(&tag);
	s->sensor_id = tag;
	sophon_battery_read(&s->batt_mv, &s->batt_age_s, &s->flags);
}

static void sensor_main(void *p1, void *p2, void *p3)
{
	/* Static: a v1 packet is 270 B of frames, too much for this stack. */
	static struct lora_packet pkt;
	static uint8_t buf[255];
	struct sophon_frame f;
	bool carry = false;
	int64_t last_status = INT64_MIN / 2;
	bool confirmed = false;

	ARG_UNUSED(p1);
	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	for (;;) {
		int64_t deadline;
		int len;
		int err;

		if (!carry) {
			(void)k_msgq_get(&sensor_queue, &f, K_FOREVER);
		}
		carry = false;

		memset(&pkt, 0, sizeof(pkt));
		pkt.format = preset->format;
		memcpy(pkt.frames[0], &f, LORA_FRAME_SIZE);
		pkt.count = 1;
		deadline = k_uptime_get() + preset->k * SAMPLE_PERIOD_MS + FLUSH_SLACK_MS;

		while (pkt.count < preset->k) {
			int64_t remaining = deadline - k_uptime_get();
			uint8_t fb[LORA_FRAME_SIZE];

			if (remaining <= 0 ||
			    k_msgq_get(&sensor_queue, &f, K_MSEC(remaining)) != 0) {
				break; /* rule 4: the flush deadline */
			}
			memcpy(fb, &f, LORA_FRAME_SIZE);
			if (preset->format == LORA_FORMAT_V2 &&
			    !lora_codec_v2_can_append(&pkt, fb, preset->k)) {
				carry = true; /* rules 2-3: it starts the next packet */
				break;
			}
			memcpy(pkt.frames[pkt.count++], fb, LORA_FRAME_SIZE);
		}

		/* v1 always carries status; v2 about once a second. */
		if (preset->format == LORA_FORMAT_V1 ||
		    k_uptime_get() - last_status >= STATUS_PERIOD_MS) {
			pkt.has_status = true;
			fill_status(&pkt.status);
			last_status = k_uptime_get();
		}

		len = lora_codec_encode(&pkt, buf, sizeof(buf));
		if (len < 0) {
			LOG_ERR("encode failed (%d) -- dropping %u samples", len, pkt.count);
			sensor_stats.send_err++;
			continue;
		}

		err = lora_send(lora_dev, buf, (uint32_t)len);
		if (err) {
			sensor_stats.send_err++;
			continue;
		}
		sensor_stats.packets++;
		sensor_stats.samples += pkt.count;

		/*
		 * The sensor has no BLE subscriber, so the usual "first frame
		 * delivered" confirm never happens. A completed transmission is the
		 * nearest equivalent -- it proves IMU -> radio, though with no
		 * acknowledgement on this link it cannot prove anyone heard it.
		 */
		if (!confirmed) {
			confirmed = true;
			sophon_image_confirm_once();
		}
	}
}

static void sensor_stats_log(void)
{
	LOG_INF("lora tx: %u pkts, %u samples, %u send errors, %u dropped (queue)",
		sensor_stats.packets, sensor_stats.samples, sensor_stats.send_err,
		sensor_stats.dropped);
	memset(&sensor_stats, 0, sizeof(sensor_stats));
}

/* ----------------------------------------------------------------- gateway */

static lora_link_frame_cb gateway_on_frame;

static struct {
	uint32_t packets;
	uint32_t bad;
	uint32_t wrong_peer;
	uint32_t samples;
	uint32_t missing;
	int32_t rssi_sum;
	int16_t rssi_min;
	int32_t snr_sum;
	int8_t snr_min;
} gw_stats;

static struct k_spinlock relay_lock;
static struct {
	bool valid;
	uint16_t mv;
	uint16_t age_s;
	uint8_t flags;
	int64_t at_ms;
} relay;

static uint16_t peer_id = CONFIG_SOPHON_LORA_PEER_ID;
static bool have_last_seq;
static uint16_t last_seq;

bool lora_link_battery(uint16_t *mv, uint16_t *age_s, uint8_t *flags)
{
	k_spinlock_key_t key = k_spin_lock(&relay_lock);
	bool valid = relay.valid;
	uint32_t age = relay.age_s + (uint32_t)((k_uptime_get() - relay.at_ms) / 1000);

	*mv = relay.mv;
	*flags = relay.flags;
	*age_s = age > UINT16_MAX ? UINT16_MAX : (uint16_t)age;
	k_spin_unlock(&relay_lock, key);
	return valid;
}

static void store_status(const struct lora_status *s)
{
	k_spinlock_key_t key = k_spin_lock(&relay_lock);
	bool changed = !relay.valid || relay.mv != s->batt_mv || relay.flags != s->flags;

	relay.valid = true;
	relay.mv = s->batt_mv;
	relay.age_s = s->batt_age_s;
	relay.flags = s->flags;
	relay.at_ms = k_uptime_get();
	k_spin_unlock(&relay_lock, key);

	if (changed) {
		sophon_ble_battery_notify();
	}
}

static void gateway_rx(const struct device *dev, uint8_t *data, uint16_t size, int16_t rssi,
		       int8_t snr, void *user_data)
{
	static struct lora_packet pkt; /* system work queue only */
	uint16_t seq0;

	ARG_UNUSED(dev);
	ARG_UNUSED(user_data);

	gw_stats.rssi_sum += rssi;
	gw_stats.snr_sum += snr;
	gw_stats.rssi_min = MIN(gw_stats.rssi_min, rssi);
	gw_stats.snr_min = MIN(gw_stats.snr_min, snr);

	if (lora_codec_decode(data, size, LORA_K_LIMIT, &pkt) != 0) {
		gw_stats.bad++;
		return;
	}

	/*
	 * The sensor id travels only in status trailers, so that is where the
	 * peer filter can act. With no id configured, lock onto the first heard.
	 */
	if (pkt.has_status) {
		if (peer_id == 0) {
			peer_id = pkt.status.sensor_id;
			LOG_INF("locked onto sensor %04X", peer_id);
		} else if (pkt.status.sensor_id != peer_id) {
			gw_stats.wrong_peer++;
			return;
		}
		store_status(&pkt.status);
	}

	gw_stats.packets++;
	gw_stats.samples += pkt.count;

	seq0 = lora_frame_seq(pkt.frames[0]);
	if (have_last_seq) {
		uint16_t gap = (uint16_t)(seq0 - last_seq - 1);

		if (gap < SEQ_RESYNC_GAP) {
			gw_stats.missing += gap;
		}
	}
	last_seq = lora_frame_seq(pkt.frames[pkt.count - 1]);
	have_last_seq = true;

	for (uint8_t i = 0; i < pkt.count; i++) {
		struct sophon_frame frame;

		memcpy(&frame, pkt.frames[i], sizeof(frame));
		gateway_on_frame(&frame);
	}
}

static void gateway_stats_log(void)
{
	uint32_t rx = gw_stats.packets + gw_stats.bad + gw_stats.wrong_peer;
	uint32_t expected = gw_stats.samples + gw_stats.missing;
	uint32_t lq_x10 = expected ? (gw_stats.samples * 1000U) / expected : 0;

	if (rx == 0) {
		LOG_INF("lora rx: nothing heard");
	} else {
		LOG_INF("lora rx: %u pkts, %u bad, %u wrong peer; %u samples, %u missing, "
			"LQ %u.%u%%; RSSI avg %d min %d, SNR avg %d min %d",
			gw_stats.packets, gw_stats.bad, gw_stats.wrong_peer, gw_stats.samples,
			gw_stats.missing, lq_x10 / 10, lq_x10 % 10, gw_stats.rssi_sum / (int32_t)rx,
			gw_stats.rssi_min, gw_stats.snr_sum / (int32_t)rx, gw_stats.snr_min);
	}
	memset(&gw_stats, 0, sizeof(gw_stats));
	gw_stats.rssi_min = INT16_MAX;
	gw_stats.snr_min = INT8_MAX;
}

/* ------------------------------------------------------------------ common */

static enum sophon_role link_role;

static void stats_handler(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(stats_work, stats_handler);

static void stats_handler(struct k_work *work)
{
	ARG_UNUSED(work);

	if (link_role == SOPHON_ROLE_SENSOR) {
		sensor_stats_log();
	} else {
		gateway_stats_log();
	}
	(void)k_work_schedule(&stats_work, K_MSEC(STATS_PERIOD_MS));
}

int lora_link_start(enum sophon_role role, lora_link_frame_cb on_frame)
{
	int err;

	if (role == SOPHON_ROLE_DIRECT) {
		return 0;
	}

	preset = lora_preset_selected();
	link_role = role;

	/*
	 * Configure for TX first, even on the gateway. loramac-node's airtime
	 * (sx12xx_airtime()) computes from the last TX configuration only; on a
	 * gateway that never configured TX it is all zeros, the spreading factor
	 * is 0, and RadioGetLoRaTimeOnAirNumerator() divides by zero -- a
	 * UsageFault at boot, found on hardware. The gateway switches to RX below,
	 * after the airtime has been logged.
	 */
	err = configure(true);
	if (err) {
		LOG_ERR("lora_config failed (%d)", err);
		return err;
	}

	LOG_INF("preset %s: SF%u BW%u CR4/%u k=%u %s %+d dBm, %u.%03u MHz; "
		"full packet %u B = %u ms on air",
		preset->name, preset->sf, LORA_BANDWIDTH_KHZ, 4 + preset->cr, preset->k,
		preset->format == LORA_FORMAT_V1 ? "v1" : "v2", preset->tx_dbm,
		CONFIG_SOPHON_LORA_FREQ_HZ / 1000000, (CONFIG_SOPHON_LORA_FREQ_HZ / 1000) % 1000,
		lora_preset_full_len(preset), lora_airtime(lora_dev, lora_preset_full_len(preset)));

	if (role == SOPHON_ROLE_SENSOR) {
		k_thread_create(&sensor_thread, sensor_stack, K_THREAD_STACK_SIZEOF(sensor_stack),
				sensor_main, NULL, NULL, NULL, SENSOR_PRIORITY, 0, K_NO_WAIT);
		k_thread_name_set(&sensor_thread, "lora_tx");
	} else {
		gateway_on_frame = on_frame;
		gw_stats.rssi_min = INT16_MAX;
		gw_stats.snr_min = INT8_MAX;
		err = configure(false);
		if (err) {
			LOG_ERR("lora_config (rx) failed (%d)", err);
			return err;
		}
		err = lora_recv_async(lora_dev, gateway_rx, NULL);
		if (err) {
			LOG_ERR("lora_recv_async failed (%d)", err);
			return err;
		}
	}

	(void)k_work_schedule(&stats_work, K_MSEC(STATS_PERIOD_MS));
	return 0;
}
