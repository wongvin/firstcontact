/*
 * Battery terminal voltage. See battery.h for what this deliberately does not
 * report, and why.
 */

#include <stdlib.h>

#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <hal/nrf_power.h>

#include "battery.h"
#include "ble.h"

LOG_MODULE_REGISTER(sophon_battery, LOG_LEVEL_INF);

/*
 * The node from app.overlay. DT_NODELABEL rather than a DT_ALIAS: the alias
 * would be one more indirection to keep in step, and this app declares the node
 * itself rather than inheriting it from a board.
 */
#define VBATT_NODE DT_NODELABEL(vbatt)

#if !DT_NODE_EXISTS(VBATT_NODE)
#error "app.overlay is not being applied: no vbatt node. Check the build board."
#endif

static const struct device *const vbatt = DEVICE_DT_GET(VBATT_NODE);

/*
 * Written by the sampler work item, read by the GATT read handler on the
 * Bluetooth RX thread. Both are 16-bit and this is a single-producer,
 * single-consumer pair where a torn read would at worst mix a stale voltage
 * with a fresh timestamp -- but the two are reported together and a caller is
 * entitled to expect them to agree, so they are copied under a spinlock rather
 * than left to luck.
 */
static struct {
	uint16_t mv;
	uint8_t flags;
	int64_t at; /* k_uptime_get() when sampled; negative means never */
} state = {.mv = 0, .flags = 0, .at = -1};

static struct k_spinlock lock;

/*
 * How far a reading has to move before it is logged again. 50 mV is coarse
 * against a LiPo's 3.0-4.2 V span -- about 4% of it -- so the console shows the
 * shape of a charge or a discharge without reporting sampling noise.
 */
#define LOG_DELTA_MV 50

/*
 * One reading: SOPHON_BATTERY_SAMPLES conversions spread over roughly
 * SOPHON_BATTERY_SAMPLES * SOPHON_BATTERY_SAMPLE_GAP_MS, averaged.
 *
 * Each sensor_sample_fetch() switches the divider in, waits the settle delay
 * from the devicetree, converts, and switches it back out -- all inside the
 * driver, which is why nothing here touches P0.14.
 *
 * Returns millivolts, or 0 if every conversion failed.
 */
static uint16_t sample_once(void)
{
	struct sensor_value value;
	int32_t total_mv = 0;
	int taken = 0;

	for (int i = 0; i < SOPHON_BATTERY_SAMPLES; i++) {
		int err;

		if (i) {
			k_msleep(SOPHON_BATTERY_SAMPLE_GAP_MS);
		}

		err = sensor_sample_fetch(vbatt);
		if (err) {
			LOG_WRN("battery fetch failed (%d)", err);
			continue;
		}

		err = sensor_channel_get(vbatt, SENSOR_CHAN_VOLTAGE, &value);
		if (err) {
			LOG_WRN("battery channel read failed (%d)", err);
			continue;
		}

		/*
		 * The driver reports volts as val1 + val2/1e6, already scaled
		 * back up through the divider ratio from the devicetree. So this
		 * is the voltage at the PACK, not at the pin -- the scaling is
		 * not ours to apply and applying it again would double-count.
		 */
		total_mv += value.val1 * 1000 + value.val2 / 1000;
		taken++;
	}

	if (!taken) {
		return 0;
	}

	return (uint16_t)(total_mv / taken);
}

static void sample_work_handler(struct k_work *work)
{
	uint16_t mv;

	ARG_UNUSED(work);

	mv = sample_once();

	/*
	 * A failed reading leaves the previous one in place rather than blanking
	 * it -- the same latching rule the app applies to displayName and
	 * identity. But the timestamp is NOT refreshed, so the value ages
	 * visibly instead of looking freshly measured. Blanking would throw away
	 * a good reading over one bad conversion; refreshing the timestamp would
	 * assert a measurement that did not happen.
	 */
	if (!mv) {
		return;
	}

	/*
	 * Captured WITH the sample, not when a central reads. The flag is what
	 * makes the voltage interpretable, so the two must describe the same
	 * instant -- a reading taken on battery and reported after USB was
	 * plugged in would otherwise be labelled as the charger's.
	 */
	uint8_t flags = nrf_power_usbregstatus_vbusdet_get(NRF_POWER)
		? SOPHON_BATTERY_FLAG_USB : 0;

	bool changed;

	K_SPINLOCK(&lock) {
		changed = (state.mv != mv) || (state.flags != flags);
		state.mv = mv;
		state.flags = flags;
		state.at = k_uptime_get();
	}

	/*
	 * Notified only on a real change, not every sample. The pack moves over
	 * hours, so a periodic notify would spend connection events restating a
	 * number nobody needs told again -- while a USB plug or unplug, which
	 * changes what the reading MEANS, propagates in about a second.
	 */
	if (changed) {
		sophon_ble_battery_notify();
	}

	/*
	 * Silent while healthy, like the transmit-counter summary in main.c: the
	 * first reading is logged because it is the one worth checking against a
	 * multimeter -- a wrong divider ratio or an inverted P0.14 yields a
	 * plausible number, not an error -- and after that only a real move is
	 * worth a line. A pack drifting a few mV between samples is not news, and
	 * a line a minute for eight hours would bury anything that is.
	 */
	static bool logged;
	static uint16_t last_logged;

	if (!logged) {
		LOG_INF("battery %u mV%s (first reading)", mv,
			(flags & SOPHON_BATTERY_FLAG_USB) ? " [USB present -- VBAT net, not necessarily a pack]" : " [on battery]");
		logged = true;
		last_logged = mv;
	} else if (abs((int)mv - (int)last_logged) >= LOG_DELTA_MV) {
		LOG_INF("battery %u mV (was %u)%s", mv, last_logged,
			(flags & SOPHON_BATTERY_FLAG_USB) ? " [USB]" : "");
		last_logged = mv;
	}
}

static K_WORK_DEFINE(sample_work, sample_work_handler);

static void sample_timer_expiry(struct k_timer *timer)
{
	ARG_UNUSED(timer);

	/*
	 * Deferred to the system work queue because sample_once() sleeps between
	 * conversions, and a timer expiry runs in ISR context where it must not.
	 */
	k_work_submit(&sample_work);
}

static K_TIMER_DEFINE(sample_timer, sample_timer_expiry, NULL);

/*
 * Watches VBUS between samples so a plug or unplug is reflected in about a
 * second rather than at the next 60 s sample.
 *
 * Re-samples rather than merely restamping the flag: the cached voltage was
 * measured under the old power source, and relabelling it without re-measuring
 * would assert that the pack reads whatever the charger's rail happened to be.
 */
static void vbus_work_handler(struct k_work *work)
{
	static bool known;
	static bool last;

	bool now = nrf_power_usbregstatus_vbusdet_get(NRF_POWER);

	ARG_UNUSED(work);

	if (known && now == last) {
		return;
	}

	known = true;
	last = now;

	LOG_INF("USB %s -- re-sampling", now ? "connected" : "disconnected");
	k_work_submit(&sample_work);
}

static K_WORK_DEFINE(vbus_work, vbus_work_handler);

static void vbus_timer_expiry(struct k_timer *timer)
{
	ARG_UNUSED(timer);
	k_work_submit(&vbus_work);
}

static K_TIMER_DEFINE(vbus_timer, vbus_timer_expiry, NULL);

void sophon_battery_read(uint16_t *mv, uint16_t *age_s, uint8_t *flags)
{
	uint16_t held_mv;
	uint8_t held_flags;
	int64_t held_at;

	K_SPINLOCK(&lock) {
		held_mv = state.mv;
		held_flags = state.flags;
		held_at = state.at;
	}

	if (!held_mv || held_at < 0) {
		*mv = 0;
		*age_s = 0;
		*flags = 0;
		return;
	}

	*flags = held_flags;

	*mv = held_mv;

	int64_t age_ms = k_uptime_get() - held_at;

	if (age_ms < 0) {
		age_ms = 0;
	}

	*age_s = (uint16_t)MIN(age_ms / 1000, UINT16_MAX);
}

/*
 * P0.14, the divider's low leg. Owned here rather than handed to the driver via
 * power-gpios, because the driver would release it between samples and there is
 * no safe released state on this board -- see app.overlay. Held ACTIVE (low) for
 * the life of the application.
 */
static const struct gpio_dt_spec vbatt_enable =
	GPIO_DT_SPEC_GET(DT_NODELABEL(vbatt_enable), gpios);

int sophon_battery_init(void)
{
	int err;

	if (!gpio_is_ready_dt(&vbatt_enable)) {
		LOG_WRN("battery enable gpio not ready; voltage unavailable");
		return -ENODEV;
	}

	/*
	 * Driven low here and never touched again. Not a power-saving control:
	 * releasing it puts AIN7 at its 3.6 V absolute maximum.
	 */
	err = gpio_pin_configure_dt(&vbatt_enable, GPIO_OUTPUT_ACTIVE);
	if (err) {
		LOG_WRN("battery enable gpio config failed (%d)", err);
		return err;
	}

	if (!device_is_ready(vbatt)) {
		LOG_WRN("battery divider not ready; voltage will read as unavailable");
		return -ENODEV;
	}

	/*
	 * First reading taken immediately rather than one period from now, so a
	 * board that has just booted does not report "no reading" for a whole
	 * minute -- which is indistinguishable, from the app, from a board whose
	 * firmware predates this change.
	 */
	k_work_submit(&sample_work);
	k_timer_start(&sample_timer, K_MSEC(SOPHON_BATTERY_PERIOD_MS),
		      K_MSEC(SOPHON_BATTERY_PERIOD_MS));
	k_timer_start(&vbus_timer, K_MSEC(SOPHON_BATTERY_VBUS_POLL_MS),
		      K_MSEC(SOPHON_BATTERY_VBUS_POLL_MS));

	return 0;
}
