/*
 * Sophon -- BLE motion peripheral.
 *
 * Advertises, accepts one connection, and notifies an 18-byte frame carrying a
 * 6-axis IMU sample, paced by the sensor's own data-ready interrupt (#209) --
 * 52 Hz nominal, ~54 Hz as measured on hardware.
 *
 * If the IMU is absent or refuses to start, the board falls back to the #208
 * skeleton behaviour -- the same frame at 1 Hz with the six axis fields zero --
 * rather than going quiet. The link stays verifiable end to end, and the iOS app
 * already reads all-zero axes as "the link works but there is no IMU here".
 */

#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <sophon_build_time.h>

#include "ble.h"
#include "frame.h"
#include "imu.h"
#include "version.h"

LOG_MODULE_REGISTER(sophon, LOG_LEVEL_INF);

/*
 * Fallback rate, used only when there is no IMU to pace the stream. Slow enough
 * to watch the link by eye, and slow enough to be obviously not the real thing.
 *
 * It is deliberately unrelated to LED_TICK_MS. The two cadences used to share
 * one loop, which only worked because 250 divided evenly into the notify period
 * -- an undocumented constraint the IMU's ~18 ms period would have broken.
 */
#define FALLBACK_NOTIFY_PERIOD_MS 1000

/* Blink cadence while advertising. Independent of the notify period. */
#define LED_TICK_MS 250

/*
 * How often the transmit counters are summarised to the console.
 *
 * Deliberately a periodic summary rather than a line per failure: the failure
 * worth reporting is TX-buffer exhaustion, and at ~54 Hz a log line per
 * occurrence would flood the console during exactly the congestion it is trying
 * to describe -- and the logging would compete for the resources already under
 * pressure.
 */
#define STATS_PERIOD_MS 30000

/* Green led1 on the XIAO. Active-low, but the gpio_dt_spec flags handle that. */
static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led1), gpios);

/*
 * Advanced by exactly one producer: the IMU trigger thread when a sensor is
 * present, or the system work queue when the fallback timer is driving. The two
 * are mutually exclusive -- main() starts one or the other, never both -- so
 * this needs no lock.
 */
static uint16_t seq;

/*
 * Frames are handed to the system work queue for transmission rather than sent
 * from the thread that built them.
 *
 * This is the whole reason the queue exists, and it is not about throughput.
 * bt_gatt_notify() allocates its PDU with K_FOREVER on any thread that is not
 * the system work queue -- see bt_att_chan_create_pdu() in the host, which
 * special-cases the sysqueue and the ATT response thread to K_NO_WAIT and
 * blocks everywhere else. Called from the IMU's trigger thread, an exhausted
 * ATT pool therefore parks that thread indefinitely, the handler overruns its
 * sample period, and the driver's re-arm race kills the stream for good.
 *
 * Sending from the sysqueue instead means the allocation is K_NO_WAIT, a full
 * pool comes back as -ENOMEM, and ble.c's no_mem counter registers it. That
 * counter was structurally unreachable from the sensor thread, which is why it
 * read zero through a stall.
 *
 * Depth 8 is ~150 ms of slack at 54 Hz. Overflowing it drops the frame, which
 * is correct: seq has already advanced, so the receiver sees the hole rather
 * than a stream that silently skipped an interval.
 */
#define TX_QUEUE_DEPTH 8

K_MSGQ_DEFINE(tx_queue, sizeof(struct sophon_frame), TX_QUEUE_DEPTH, 4);

static void led_set(bool on)
{
	if (led.port) {
		(void)gpio_pin_set_dt(&led, on);
	}
}

static int led_init(void)
{
	if (!gpio_is_ready_dt(&led)) {
		LOG_WRN("led1 not ready; continuing without status LED");
		return -ENODEV;
	}

	return gpio_pin_configure_dt(&led, GPIO_OUTPUT_INACTIVE);
}

/*
 * Builds the next frame. A NULL sample means "no IMU" and leaves the axes zero.
 * Returns false when nobody is subscribed and no frame should exist.
 */
static bool build_frame(struct sophon_frame *out, const struct sophon_imu_sample *sample)
{
	if (!sophon_ble_subscribed()) {
		/*
		 * seq deliberately does not advance while nobody is subscribed:
		 * no data was expected, so the gap it would create on the next
		 * subscribe is not a dropped frame. See PROTOCOL.md.
		 */
		return false;
	}

	out->seq = ++seq;
	out->t_ms = k_uptime_get_32();

	out->ax = sample ? sample->ax : 0;
	out->ay = sample ? sample->ay : 0;
	out->az = sample ? sample->az : 0;
	out->gx = sample ? sample->gx : 0;
	out->gy = sample ? sample->gy : 0;
	out->gz = sample ? sample->gz : 0;

	return true;
}

/*
 * Drains the queue on the system work queue. Every notify from here allocates
 * with K_NO_WAIT, so a full ATT pool returns -ENOMEM and is counted rather than
 * parking the caller.
 */
static void tx_work_handler(struct k_work *work)
{
	struct sophon_frame frame;

	ARG_UNUSED(work);

	while (k_msgq_get(&tx_queue, &frame, K_NO_WAIT) == 0) {
		/*
		 * The outcome is counted in ble.c and summarised by
		 * stats_work_handler. Deliberately NOT logged per failure:
		 * measured on hardware, a flooding link produced 22781
		 * per-failure lines against 11 summaries in 90 s -- two
		 * megabytes of console describing a congestion problem, while
		 * the logging competed for the very resources under pressure.
		 */
		(void)sophon_ble_notify(&frame);
	}
}

static K_WORK_DEFINE(tx_work, tx_work_handler);

/*
 * Data-ready callback, on the LSM6DSL driver's own trigger thread. This is what
 * paces the stream: one frame per sample the sensor actually produced, so seq
 * stays a faithful index of sample periods rather than of timer ticks.
 *
 * It must return promptly -- overrunning a sample period strands the driver's
 * edge interrupt and kills the stream permanently. Building a frame and posting
 * it is bounded work; transmitting it is not, which is why that happens on the
 * system work queue instead. See the tx_queue comment.
 */
static void imu_sample(const struct sophon_imu_sample *sample)
{
	static bool queue_full;

	struct sophon_frame frame;

	if (!build_frame(&frame, sample)) {
		return;
	}

	if (k_msgq_put(&tx_queue, &frame, K_NO_WAIT) != 0) {
		/*
		 * Edge-logged only, for the same reason the transmit failures
		 * are: at 54 Hz a line per drop floods the console during
		 * exactly the congestion it describes. The dropped frame is
		 * already visible to the central as a seq gap.
		 */
		if (!queue_full) {
			LOG_WRN("tx queue full; frames dropped (further drops suppressed)");
			queue_full = true;
		}
		return;
	}

	if (queue_full) {
		LOG_INF("tx queue drained");
		queue_full = false;
	}

	k_work_submit(&tx_work);
}

static void fallback_work_handler(struct k_work *work)
{
	struct sophon_frame frame;

	ARG_UNUSED(work);

	if (build_frame(&frame, NULL)) {
		(void)sophon_ble_notify(&frame);
	}
}

static K_WORK_DEFINE(fallback_work, fallback_work_handler);

static void fallback_timer_expiry(struct k_timer *timer)
{
	ARG_UNUSED(timer);

	/*
	 * Timer callbacks run in ISR context and the Bluetooth API must not be
	 * called from there, so the send is deferred to the system work queue.
	 *
	 * If the previous submission has not run yet, k_work_submit() leaves it
	 * queued once rather than stacking. A missed slot is therefore dropped
	 * rather than burst later, and seq does not advance for a frame that was
	 * never built -- which keeps the receiver's gap count honest.
	 */
	k_work_submit(&fallback_work);
}

/*
 * Both cadences come from periodic k_timers rather than k_msleep() at the bottom
 * of a loop. k_msleep sleeps for *at least* its argument, so the loop body's own
 * duration is added to every iteration and never given back: the period drifts
 * by however long the work took, permanently. A periodic timer re-arms from its
 * own start time, so expiries stay on an absolute grid and jitter does not
 * accumulate.
 */
static K_TIMER_DEFINE(fallback_timer, fallback_timer_expiry, NULL);
static K_TIMER_DEFINE(led_timer, NULL, NULL);

static void stats_work_handler(struct k_work *work)
{
	static struct sophon_tx_stats last;
	struct sophon_tx_stats now;

	ARG_UNUSED(work);

	sophon_ble_tx_stats(&now);

	/*
	 * Silent while healthy. -ENOTCONN is excluded from the test on purpose:
	 * it just means nobody is subscribed, which is the normal state of an
	 * advertising board and not something to report every 30 seconds.
	 */
	if (now.no_mem == last.no_mem && now.other == last.other) {
		last = now;
		return;
	}

	LOG_WRN("tx failures: no-buffer %u (+%u), other %u (+%u); sent %u",
		now.no_mem, now.no_mem - last.no_mem,
		now.other, now.other - last.other,
		now.sent);

	last = now;
}

static K_WORK_DEFINE(stats_work, stats_work_handler);

static void stats_timer_expiry(struct k_timer *timer)
{
	ARG_UNUSED(timer);
	k_work_submit(&stats_work);
}

static K_TIMER_DEFINE(stats_timer, stats_timer_expiry, NULL);

int main(void)
{
	uint32_t tick = 0;
	int err;

	/*
	 * Firmware version is hand-maintained in zephyr/sophon/VERSION, so print
	 * it where it will actually be read. The build time answers the separate
	 * question the version cannot -- is this the build I just flashed -- and
	 * unlike the version it cannot be forgotten.
	 */
	LOG_INF("Sophon starting -- fw %s, hw %u, built %s", APP_VERSION_STRING,
		SOPHON_HW_VERSION, SOPHON_BUILD_TIME);

	(void)led_init();

	err = sophon_ble_init();
	if (err) {
		/*
		 * Nothing useful left to do -- but keep the LED alive so a board
		 * that failed to start is visibly different from a dead one.
		 */
		LOG_ERR("BLE init failed (%d); halting with fast blink", err);
		while (1) {
			led_set(tick++ & 1);
			k_msleep(100);
		}
	}

	/*
	 * A missing IMU is explicitly not fatal. The radio, the GATT table and
	 * the transmit counters are all still worth having on a board whose
	 * sensor did not come up -- and the zero-axis fallback is what makes the
	 * difference visible from the phone rather than looking like a dead link.
	 */
	err = sophon_imu_init(imu_sample);
	if (err) {
		LOG_WRN("no IMU (%d); falling back to %d ms zero-filled frames",
			err, FALLBACK_NOTIFY_PERIOD_MS);
		k_timer_start(&fallback_timer, K_MSEC(FALLBACK_NOTIFY_PERIOD_MS),
			      K_MSEC(FALLBACK_NOTIFY_PERIOD_MS));
	}

	k_timer_start(&led_timer, K_MSEC(LED_TICK_MS), K_MSEC(LED_TICK_MS));
	k_timer_start(&stats_timer, K_MSEC(STATS_PERIOD_MS), K_MSEC(STATS_PERIOD_MS));

	/*
	 * The main thread now only drives the LED: solid while connected, blinking
	 * while advertising. Frames are produced elsewhere -- off the IMU's
	 * data-ready thread, or off the fallback timer -- so no cadence here has
	 * to divide into any other.
	 */
	while (1) {
		/* Blocks until the next expiry on the timer's absolute schedule. */
		(void)k_timer_status_sync(&led_timer);

		led_set(sophon_ble_connected() ? true : (tick & 1));
		tick++;
	}

	return 0;
}
