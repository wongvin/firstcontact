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
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/lora.h>
#include <zephyr/drivers/spi.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/spinlock.h>
#include <zephyr/sys/byteorder.h>

#include "battery.h"
#include "ble.h"
#include "ident.h"
#include "config.h"
#include "lora_codec.h"
#include "lora_link.h"
#include "lora_presets.h"

LOG_MODULE_REGISTER(sophon_lora, LOG_LEVEL_INF);

static const struct device *const lora_dev = DEVICE_DT_GET(DT_NODELABEL(lora0));

static const struct lora_preset *preset;

/* Stats are logged every stats period and reset, like a rate. The sensor's is
 * always 10 s; the gateway's is its window, 1-10 s from the config (#344). */
#define STATS_PERIOD_MS 10000
static uint32_t stats_period_ms = STATS_PERIOD_MS;
/* Under 10 s windows the gateway logs every log_every-th window, so the
 * console stays at one line per ~10 s whatever the window. */
static uint32_t log_every = 1;

/*
 * Nominal sample period, rounded up from the measured 18.4 ms (54.3 Hz). The
 * flush deadline -- packing rule 4 -- is k of these plus slack, so a stalled
 * IMU cannot hold a partly filled packet indefinitely.
 */
#define SAMPLE_PERIOD_MS 19
#define FLUSH_SLACK_MS   20

/* A status trailer at most this often (LORA-PROTOCOL.md). */
#define STATUS_PERIOD_MS 1000

/*
 * Which packets are the locked sensor's (#350). Only a status trailer, about
 * once a second, names its sensor; the packets between carry none. So:
 *  - an untagged packet counts as the locked sensor's only if its seq continues
 *    that sensor's stream: the gap since the last accepted packet can be no more
 *    than the elapsed time allows at 54.3 Hz (SAMPLES_PER_S_X10) plus two
 *    packets' slack. Another sensor's seq lands elsewhere and is a wrong peer;
 *  - the anchor is trusted for ANCHOR_HOLD_MS only. After that much silence an
 *    untagged packet waits for a status trailer from the locked sensor to
 *    re-anchor the stream. That bounds the tolerance (about 300 samples) so a
 *    quiet locked sensor can't hand its stream to another;
 *  - a status trailer from the locked sensor is always accepted. A gap within
 *    what FADE_COUNT_MS allows counts as missing -- a fade -- and a larger jump
 *    is its restart, re-anchored without being counted;
 *  - with no sensor locked, untagged packets can't be attributed and are dropped
 *    until a status trailer names one.
 * Two sensors whose seqs happen to be within the bound of each other can still
 * be mixed: telling them apart for certain needs a sensor tag in every packet
 * (#354).
 */
#define SAMPLES_PER_S_X10 543
#define SEQ_SLACK         (2 * LORA_K_LIMIT)
#define ANCHOR_HOLD_MS    5000
#define FADE_COUNT_MS     20000 /* ~1086 samples, as the old 1024-sample rule */

/* With "any" peer, a lock is released when its sensor's status trailers stop
 * for this long, so the next sensor heard can be locked onto (#350). */
#define PEER_SILENT_MS 5000

/* Samples the elapsed time allows, plus slack; ms is capped by the caller. */
static uint32_t seq_bound(int64_t ms)
{
	return (uint32_t)MAX(ms, 0) * SAMPLES_PER_S_X10 / 10000U + SEQ_SLACK;
}

/* The preset's TX power, unless the stored config overrides it (#329). */
static int8_t tx_dbm(void)
{
	int8_t override = sophon_config_tx_override();

	return override != SOPHON_CONFIG_TX_DEFAULT ? override : preset->tx_dbm;
}

static int configure(bool tx)
{
	struct lora_modem_config cfg = {
		.frequency = sophon_config_freq_hz(),
		.bandwidth = BW_500_KHZ,
		.datarate = (enum lora_datarate)preset->sf,
		.coding_rate = (enum lora_coding_rate)preset->cr,
		.preamble_len = LORA_PREAMBLE_LEN,
		.tx_power = tx_dbm(),
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

/*
 * The receiver's noise floor (#336; NOISE-FLOOR-PLAN.md). The radio's
 * instantaneous RSSI is sampled once in the middle of the quiet gap after each
 * received packet. After a packet is lost -- or fails its CRC, which never
 * reaches gateway_rx -- sampling stays in step with the sensor's schedule, at
 * each expected gap centre, for NOISE_LOCKED_MS; only after that much silence
 * does it run free every NOISE_IDLE_MS. A free-running timer would drift onto
 * packets still being sent (#336 review). Samples are binned in 1 dB steps so
 * each window's minimum and median come out without keeping them. System work
 * queue only, like all other radio access here, so no lock.
 */
#define NOISE_IDLE_MS   100
#define NOISE_LOCKED_MS 1000
#define NOISE_BINS      128 /* bin i holds -i dBm; -127 dBm and below share 127 */
static uint32_t noise_gap_delay_ms;
static uint32_t noise_period_ms; /* the sensor's packet period at this preset */
static uint16_t noise_hist[NOISE_BINS];
static uint16_t noise_count;

static struct k_spinlock relay_lock;
static struct {
	bool valid;
	uint16_t mv;
	uint16_t age_s;
	uint8_t flags;
	int64_t at_ms;
} relay;

static struct k_spinlock record_lock;
static uint8_t record[LORA_LINK_RECORD_SIZE];
static bool record_valid;
/* 16 bits (#333): about 7.6 days of 10 s windows before it wraps. */
static uint16_t record_window;
static int64_t last_rx_ms = -1; /* any packet, good or bad */

/* From the stored config at start (#329); 0 locks onto the first sensor heard. */
static uint16_t peer_id = CONFIG_SOPHON_LORA_PEER_ID;

uint16_t lora_link_peer_id(void)
{
	return peer_id;
}

/*
 * DIO1 WATCHDOG -- recovering a lost radio interrupt.
 *
 * The SX1262 raises DIO1 when a packet is done, and Zephyr's loramac-node glue
 * (drivers/lora/loramac-node/sx126x.c) watches it for a RISING EDGE: one edge,
 * one run of its work item, which reads and clears the radio's IRQ flags and
 * then re-arms the edge with gpio_pin_interrupt_configure_dt(). That re-arm
 * tears the nRF's GPIOTE channel down and back up on every packet, and an edge
 * that lands in that window is lost. DIO1 then stays high -- the radio holds a
 * finished packet with its interrupt raised -- and with no further edge the
 * driver never looks at the radio again. The gateway goes deaf for good while
 * everything else, its 10 s stats included, carries on.
 *
 * Found on hardware (#303): after hours at ~13 packets/s, 01A7 heard nothing
 * while the sensor sent 134 packets per 10 s with no errors. Read live over SWD:
 * DIO1 (P0.03) high and steady, BUSY low, GPIOTE channel 7 armed for a rising
 * edge on P0.03 with no event pending.
 *
 * Recovery here, without touching the driver: if DIO1 has been high for
 * DIO1_STUCK_MS with no packet decoded, send the radio ClearIrqStatus over SPI
 * ourselves. DIO1 drops, the radio stays in continuous receive, and the next
 * packet raises a fresh edge, so the driver resumes its normal path. The cost
 * is the one packet left in the radio's buffer. It is safe because this runs on
 * the system work queue, the same queue as all of the driver's radio access, so
 * the two cannot interleave, and BUSY is checked first.
 *
 * NOT a level-triggered "kick" of the driver's callback: tried, and it is an
 * interrupt storm -- with DIO1 held high a level interrupt re-fires the moment
 * it returns, the thread that would switch back to edge never runs, and the
 * system work queue starves (found on hardware with injected lost edges).
 *
 * The real fix belongs in the driver glue (it should resubmit its work while
 * DIO1 is still high); this stays until it does.
 */
#define WATCHDOG_PERIOD_MS 250
#define DIO1_STUCK_MS      1000

static const struct gpio_dt_spec lora_dio1 = GPIO_DT_SPEC_GET(DT_NODELABEL(lora0), dio1_gpios);
static const struct gpio_dt_spec lora_busy = GPIO_DT_SPEC_GET(DT_NODELABEL(lora0), busy_gpios);
static const struct spi_dt_spec lora_spi =
	SPI_DT_SPEC_GET(DT_NODELABEL(lora0), SPI_WORD_SET(8) | SPI_TRANSFER_MSB);
/* last_rx_ms, the time of the last packet, is defined with the LoRa Link record above. */
static int64_t dio1_high_since = -1;
static uint32_t dio1_kicks;
static bool have_last_seq;
static uint16_t last_seq;
static int64_t last_accept_ms;      /* the last packet accepted as the locked sensor's */
static uint16_t anchor_id;          /* the sensor whose stream last_seq belongs to */
static int64_t peer_status_ms = -1; /* the locked sensor's last status trailer */

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

/* SX126x GetRssiInst: opcode 0x15, then the status byte, then RssiInst; the
 * power is -RssiInst / 2 dBm. Valid in receive mode, and harmless to it. */
static int radio_rssi_inst(int16_t *dbm)
{
	uint8_t tx[3] = {0x15, 0x00, 0x00};
	uint8_t rx[3] = {0};
	const struct spi_buf tx_buf = {.buf = tx, .len = sizeof(tx)};
	const struct spi_buf rx_buf = {.buf = rx, .len = sizeof(rx)};
	const struct spi_buf_set tx_set = {.buffers = &tx_buf, .count = 1};
	const struct spi_buf_set rx_set = {.buffers = &rx_buf, .count = 1};
	int err;

	for (int i = 0; gpio_pin_get_dt(&lora_busy) > 0; i++) {
		if (i >= 100) {
			return -EBUSY;
		}
		k_busy_wait(100);
	}
	err = spi_transceive_dt(&lora_spi, &tx_set, &rx_set);
	if (err == 0) {
		*dbm = -(int16_t)(rx[2] / 2);
	}
	return err;
}

static void noise_handler(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(noise_work, noise_handler);

static void noise_handler(struct k_work *work)
{
	int64_t now = k_uptime_get();
	int64_t quiet_for = last_rx_ms < 0 ? INT64_MAX : now - last_rx_ms;
	int16_t dbm;

	ARG_UNUSED(work);

	if (radio_rssi_inst(&dbm) == 0 && noise_count < UINT16_MAX) {
		noise_hist[MIN(-dbm, NOISE_BINS - 1)]++;
		noise_count++;
	}

	/*
	 * A received packet reschedules this mid-gap (gateway_rx). Until one
	 * does, aim at the next gap the sensor's schedule predicts; after
	 * NOISE_LOCKED_MS of silence nobody is sending, and any time will do.
	 */
	if (quiet_for < NOISE_LOCKED_MS && noise_period_ms > 0) {
		int64_t m = (quiet_for - noise_gap_delay_ms) / noise_period_ms + 1;
		int64_t next = last_rx_ms + noise_gap_delay_ms + m * noise_period_ms;

		(void)k_work_schedule(&noise_work, K_MSEC(MAX(next - now, 1)));
	} else {
		(void)k_work_schedule(&noise_work, K_MSEC(NOISE_IDLE_MS));
	}
}

/* This window's noise minimum and median, in dBm, or 0x7F with no samples. */
static void noise_summary(uint8_t *min_out, uint8_t *median_out)
{
	uint32_t seen = 0;

	*min_out = LORA_LINK_NOISE_UNMEASURED;
	*median_out = LORA_LINK_NOISE_UNMEASURED;
	if (noise_count == 0) {
		return;
	}
	/* Quietest first: the highest bin is the lowest power. */
	for (int i = NOISE_BINS - 1; i >= 0; i--) {
		if (noise_hist[i] == 0) {
			continue;
		}
		if (*min_out == LORA_LINK_NOISE_UNMEASURED) {
			*min_out = (uint8_t)(int8_t)(-i);
		}
		seen += noise_hist[i];
		if (seen * 2 >= noise_count) {
			*median_out = (uint8_t)(int8_t)(-i);
			return;
		}
	}
}

static void gateway_rx(const struct device *dev, uint8_t *data, uint16_t size, int16_t rssi,
		       int8_t snr, void *user_data)
{
	static struct lora_packet pkt; /* system work queue only */
	uint16_t seq0;

	ARG_UNUSED(dev);
	ARG_UNUSED(user_data);

	last_rx_ms = k_uptime_get();
	/* The next noise sample goes mid-gap, before the next packet starts. */
	(void)k_work_reschedule(&noise_work, K_MSEC(noise_gap_delay_ms));
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
	 * peer filter can act directly. With no id configured, lock onto the first
	 * heard. Relocking the same sensor keeps its anchor, so a fade across a
	 * release is still counted.
	 */
	if (pkt.has_status) {
		if (peer_id == 0) {
			peer_id = pkt.status.sensor_id;
			if (peer_id != anchor_id) {
				have_last_seq = false; /* a different stream */
			}
			anchor_id = peer_id;
			LOG_INF("locked onto sensor %04X", peer_id);
		} else if (pkt.status.sensor_id != peer_id) {
			gw_stats.wrong_peer++;
			return;
		}
		peer_status_ms = last_rx_ms;
		store_status(&pkt.status);
	} else if (peer_id == 0) {
		gw_stats.wrong_peer++; /* no sensor named yet: can't be attributed */
		return;
	}

	seq0 = lora_frame_seq(pkt.frames[0]);
	if (have_last_seq) {
		int64_t since = last_rx_ms - last_accept_ms;
		uint16_t gap = (uint16_t)(seq0 - last_seq - 1);

		if (!pkt.has_status) {
			/* The locked sensor's only if it continues its stream, recently. */
			if (since > ANCHOR_HOLD_MS || gap > seq_bound(since)) {
				gw_stats.wrong_peer++;
				return;
			}
			gw_stats.missing += gap;
		} else if (gap <= seq_bound(MIN(since, FADE_COUNT_MS))) {
			gw_stats.missing += gap; /* a fade */
		}
		/* else: the locked sensor's restart -- re-anchored, not counted */
	}
	gw_stats.packets++;
	gw_stats.samples += pkt.count;
	last_seq = lora_frame_seq(pkt.frames[pkt.count - 1]);
	last_accept_ms = last_rx_ms;
	anchor_id = peer_id;
	have_last_seq = true;

	for (uint8_t i = 0; i < pkt.count; i++) {
		struct sophon_frame frame;

		memcpy(&frame, pkt.frames[i], sizeof(frame));
		gateway_on_frame(&frame);
	}
}

static int8_t clamp_i8(int32_t v)
{
	return (int8_t)CLAMP(v, INT8_MIN, INT8_MAX);
}

/* Saturating packers for the narrowed version 2 fields (#333). */
static uint8_t sat_u4(uint32_t v)
{
	return (uint8_t)MIN(v, 15U);
}

static uint8_t last_packet_ds(int64_t age_ms)
{
	/* 100 ms units; 255 = 25.5 s or more, or no packet yet. */
	return age_ms < 0 || age_ms >= 25500 ? 255 : (uint8_t)(age_ms / 100);
}

/*
 * The LoRa Link record, version 2 (#333; LORA-LINK-V2-PLAN.md), laid out as
 * PROTOCOL.md § LoRa Link frame: still 20 bytes, every u16 2-byte aligned, the
 * spare byte last. Link quality is no longer sent: it is samples / (samples +
 * missing), which every consumer computes. Built on the system work queue,
 * read from the Bluetooth RX thread, hence the lock.
 */
static void gateway_build_record(uint32_t rx)
{
	uint8_t r[LORA_LINK_RECORD_SIZE];
	int64_t age = last_rx_ms < 0 ? -1 : k_uptime_get() - last_rx_ms;
	k_spinlock_key_t key;

	r[0] = LORA_LINK_RECORD_VERSION;
	/* preset id bits 0-3; window length in seconds bits 4-7 (#344 makes it
	 * configurable; fixed at the 10 s stats period until then). */
	r[1] = (uint8_t)((preset->id & 0x0F) | ((stats_period_ms / 1000) << 4));
	sys_put_le16(peer_id, &r[2]);
	sys_put_le16(record_window++, &r[4]);
	r[6] = rx ? clamp_i8(gw_stats.rssi_sum / (int32_t)rx) : 0;
	r[7] = rx ? clamp_i8(gw_stats.rssi_min) : 0;
	r[8] = rx ? clamp_i8(gw_stats.snr_sum / (int32_t)rx) : 0;
	r[9] = rx ? clamp_i8(gw_stats.snr_min) : 0;
	sys_put_le16((uint16_t)MIN(gw_stats.samples, UINT16_MAX), &r[10]);
	sys_put_le16((uint16_t)MIN(gw_stats.missing, UINT16_MAX), &r[12]);
	r[14] = last_packet_ds(age);
	noise_summary(&r[15], &r[16]);
	r[17] = (uint8_t)(sat_u4(gw_stats.bad) | (sat_u4(gw_stats.wrong_peer) << 4));
	/* bit 0 RX boost (fixed on here; the walk test A/Bs it), bit 2 heard,
	 * bits 4-7 SF. Bit 1, a walk-test record, is set only by walk-test mode. */
	r[18] = BIT(0) | (rx ? BIT(2) : 0) | (uint8_t)(preset->sf << 4);
	r[19] = 0; /* reserved */

	key = k_spin_lock(&record_lock);
	memcpy(record, r, sizeof(record));
	record_valid = true;
	k_spin_unlock(&record_lock, key);

	sophon_ble_lora_link_notify();
}

bool lora_link_record(uint8_t out[LORA_LINK_RECORD_SIZE])
{
	k_spinlock_key_t key = k_spin_lock(&record_lock);
	bool valid = record_valid;

	if (valid) {
		memcpy(out, record, LORA_LINK_RECORD_SIZE);
	}
	k_spin_unlock(&record_lock, key);
	return valid;
}

static int radio_clear_irq(void)
{
	/* SX126x ClearIrqStatus: opcode 0x02, then a 16-bit mask of all IRQs. */
	uint8_t cmd[3] = {0x02, 0xFF, 0xFF};
	const struct spi_buf buf = {.buf = cmd, .len = sizeof(cmd)};
	const struct spi_buf_set set = {.buffers = &buf, .count = 1};

	for (int i = 0; gpio_pin_get_dt(&lora_busy) > 0; i++) {
		if (i >= 100) {
			return -EBUSY; /* 10 ms: the radio is mid-command, try next tick */
		}
		k_busy_wait(100);
	}
	return spi_write_dt(&lora_spi, &set);
}

static void watchdog_handler(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(watchdog_work, watchdog_handler);

static void watchdog_handler(struct k_work *work)
{
	int64_t now = k_uptime_get();

	ARG_UNUSED(work);

	if (gpio_pin_get_dt(&lora_dio1) <= 0) {
		dio1_high_since = -1;
	} else if (dio1_high_since < 0) {
		dio1_high_since = now;
	} else if (now - dio1_high_since >= DIO1_STUCK_MS &&
		   (last_rx_ms < 0 || now - last_rx_ms >= DIO1_STUCK_MS)) {
		int err = radio_clear_irq();

		if (err == 0) {
			dio1_kicks++;
			LOG_WRN("radio interrupt stuck (DIO1 high %lld ms, no packet) -- "
				"cleared, recovery #%u",
				now - dio1_high_since, dio1_kicks);
			dio1_high_since = -1;
		} else {
			LOG_WRN("radio interrupt stuck, clear failed (%d); retrying", err);
		}
	}

	/*
	 * Release a lock whose sensor has gone quiet, so another sensor can be
	 * locked onto without restarting the gateway (#350). A configured peer is
	 * the user's choice and is never released.
	 */
	if (sophon_config_boot()->peer_id == 0 && peer_id != 0 && peer_status_ms >= 0 &&
	    now - peer_status_ms >= PEER_SILENT_MS) {
		LOG_INF("sensor %04X silent for %d s -- unlocked", peer_id, PEER_SILENT_MS / 1000);
		peer_id = 0; /* the anchor is kept: if it returns, its fade counts */
		peer_status_ms = -1;
	}

	(void)k_work_schedule(&watchdog_work, K_MSEC(WATCHDOG_PERIOD_MS));
}

static void gateway_stats_log(void)
{
	uint32_t rx = gw_stats.packets + gw_stats.bad + gw_stats.wrong_peer;
	uint32_t expected = gw_stats.samples + gw_stats.missing;
	uint32_t lq_x10 = expected ? (gw_stats.samples * 1000U) / expected : 0;
	static uint32_t since_log;

	/* Every window's record goes out; only the console is thinned. */
	gateway_build_record(rx);

	if (++since_log < log_every) {
		goto reset;
	}
	since_log = 0;
	if (log_every > 1) {
		LOG_INF("lora rx (%u s windows, every %uth logged):", stats_period_ms / 1000,
			log_every);
	}
	uint8_t nmin;
	uint8_t nmed;

	noise_summary(&nmin, &nmed);
	if (rx == 0) {
		LOG_INF("lora rx: nothing heard; noise min %d median %d dBm", (int8_t)nmin,
			(int8_t)nmed);
	} else {
		LOG_INF("lora rx: %u pkts, %u bad, %u wrong peer; %u samples, %u missing, "
			"LQ %u.%u%%; RSSI avg %d min %d, SNR avg %d min %d; noise min %d median %d "
			"dBm; %u DIO1 recoveries total",
			gw_stats.packets, gw_stats.bad, gw_stats.wrong_peer, gw_stats.samples,
			gw_stats.missing, lq_x10 / 10, lq_x10 % 10, gw_stats.rssi_sum / (int32_t)rx,
			gw_stats.rssi_min, gw_stats.snr_sum / (int32_t)rx, gw_stats.snr_min,
			(int8_t)nmin, (int8_t)nmed, dio1_kicks);
	}
reset:
	memset(&gw_stats, 0, sizeof(gw_stats));
	memset(noise_hist, 0, sizeof(noise_hist));
	noise_count = 0;
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
	(void)k_work_schedule(&stats_work, K_MSEC(stats_period_ms));
}

int lora_link_start(enum sophon_role role, lora_link_frame_cb on_frame)
{
	int err;

	if (role == SOPHON_ROLE_DIRECT) {
		return 0;
	}

	preset = lora_preset_selected();
	peer_id = sophon_config_boot()->peer_id;
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
		preset->format == LORA_FORMAT_V1 ? "v1" : "v2", tx_dbm(),
		sophon_config_freq_hz() / 1000000, (sophon_config_freq_hz() / 1000) % 1000,
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
		(void)k_work_schedule(&watchdog_work, K_MSEC(WATCHDOG_PERIOD_MS));

		/* The gateway's window, from the config at boot (#344). */
		stats_period_ms = sophon_config_window_s() * 1000U;
		log_every = STATS_PERIOD_MS / stats_period_ms;

		/*
		 * Noise samples go in the middle of the quiet gap between this
		 * preset's packets: the sensor sends one every k samples (k x 18.4
		 * ms at 54.3 Hz), each on air for the airtime (NOISE-FLOOR-PLAN.md).
		 */
		uint32_t period_ms = preset->k * 184U / 10U;
		uint32_t air_ms = lora_airtime(lora_dev, lora_preset_full_len(preset));

		noise_gap_delay_ms = period_ms > air_ms ? (period_ms - air_ms) / 2 : 1;
		noise_period_ms = period_ms;
		LOG_INF("noise floor sampled %u ms after each packet", noise_gap_delay_ms);
		(void)k_work_schedule(&noise_work, K_MSEC(NOISE_IDLE_MS));
	}

	(void)k_work_schedule(&stats_work, K_MSEC(stats_period_ms));
	return 0;
}
