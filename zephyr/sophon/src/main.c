/*
 * Sophon -- BLE motion peripheral, skeleton (#208).
 *
 * Advertises, accepts one connection, and notifies an 18-byte frame at 1 Hz with
 * seq/t_ms live and the six axis fields zero. Real IMU data is #209.
 */

#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "ble.h"
#include "frame.h"

LOG_MODULE_REGISTER(sophon, LOG_LEVEL_INF);

/*
 * Skeleton rate: slow enough to watch the link by eye. #209 raises this to 20
 * (50 Hz).
 *
 * It is deliberately unrelated to LED_TICK_MS. The two cadences used to share
 * one loop, which only worked because 250 divided evenly into the notify period
 * -- an undocumented constraint that 20 ms would have broken.
 */
#define NOTIFY_PERIOD_MS 1000

/* Blink cadence while advertising. Independent of the notify period. */
#define LED_TICK_MS 250

/*
 * How often the transmit counters are summarised to the console.
 *
 * Deliberately a periodic summary rather than a line per failure: the failure
 * worth reporting is TX-buffer exhaustion, and at #209's 50 Hz a log line per
 * occurrence would flood the console during exactly the congestion it is trying
 * to describe -- and the logging would compete for the resources already under
 * pressure.
 */
#define STATS_PERIOD_MS 30000

/* Green led1 on the XIAO. Active-low, but the gpio_dt_spec flags handle that. */
static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led1), gpios);

static struct sophon_frame frame;

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

static void notify_work_handler(struct k_work *work)
{
	ARG_UNUSED(work);

	if (!sophon_ble_subscribed()) {
		/*
		 * seq deliberately does not advance while nobody is subscribed:
		 * no data was expected, so the gap it would create on the next
		 * subscribe is not a dropped frame. See PROTOCOL.md.
		 */
		return;
	}

	frame.seq++;
	frame.t_ms = k_uptime_get_32();
	/* axes stay zero until #209 */

	/*
	 * The outcome is counted in ble.c and summarised by stats_work_handler.
	 * Deliberately NOT logged per failure: measured on hardware, a flooding
	 * link produced 22781 per-failure lines against 11 summaries in 90 s --
	 * two megabytes of console describing a congestion problem, while the
	 * logging competed for the very resources under pressure.
	 */
	(void)sophon_ble_notify(&frame);
}

static K_WORK_DEFINE(notify_work, notify_work_handler);

static void notify_timer_expiry(struct k_timer *timer)
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
	k_work_submit(&notify_work);
}

/*
 * Both cadences come from periodic k_timers rather than k_msleep() at the bottom
 * of a loop. k_msleep sleeps for *at least* its argument, so the loop body's own
 * duration is added to every iteration and never given back: the period drifts
 * by however long the work took, permanently. A periodic timer re-arms from its
 * own start time, so expiries stay on an absolute grid and jitter does not
 * accumulate.
 */
static K_TIMER_DEFINE(notify_timer, notify_timer_expiry, NULL);
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

	LOG_INF("Sophon skeleton starting");

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

	k_timer_start(&notify_timer, K_MSEC(NOTIFY_PERIOD_MS), K_MSEC(NOTIFY_PERIOD_MS));
	k_timer_start(&led_timer, K_MSEC(LED_TICK_MS), K_MSEC(LED_TICK_MS));
	k_timer_start(&stats_timer, K_MSEC(STATS_PERIOD_MS), K_MSEC(STATS_PERIOD_MS));

	/*
	 * The main thread now only drives the LED: solid while connected, blinking
	 * while advertising. Notifies run off their own timer, so the two cadences
	 * are independent and neither has to divide into the other.
	 */
	while (1) {
		/* Blocks until the next expiry on the timer's absolute schedule. */
		(void)k_timer_status_sync(&led_timer);

		led_set(sophon_ble_connected() ? true : (tick & 1));
		tick++;
	}

	return 0;
}
