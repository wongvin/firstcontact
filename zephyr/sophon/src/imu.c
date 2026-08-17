#include <zephyr/device.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/util.h>

#include "imu.h"

LOG_MODULE_REGISTER(sophon_imu, LOG_LEVEL_INF);

/*
 * DEVICE_DT_GET_ONE rather than a node label: the label (lsm6ds3tr_c) is
 * board-specific, and this asserts at compile time that the board has exactly
 * one st,lsm6dsl -- a clearer failure than a runtime NULL if the board file
 * ever renames the node.
 */
static const struct device *const imu = DEVICE_DT_GET_ONE(st_lsm6dsl);

static sophon_imu_cb_t sample_cb;
static bool armed;

/* Uptime of the most recent successful fetch; the watchdog's only input. */
static uint32_t last_sample_ms;

/*
 * Full-scale ranges are set at build time in prj.conf; both choices are pinned
 * to the *frozen wire format*, not to taste, so assert them here rather than
 * leaving a comment nobody reads.
 *
 * The gyro one is load-bearing. Centi-degrees/second in an int16 tops out at
 * 327.67 deg/s, so +/-250 dps is the largest standard range the frame can
 * represent. Selecting 500 dps would silently saturate every fast rotation into
 * a flat-topped plateau -- data that looks plausible and is wrong, which is the
 * worst failure mode available. Changing this needs a frame change (#211
 * territory), not a Kconfig edit.
 */
BUILD_ASSERT(CONFIG_LSM6DSL_GYRO_FS != 0,
	     "Sophon pins the gyro full-scale at build time; 0 means runtime-selected");
BUILD_ASSERT(CONFIG_LSM6DSL_GYRO_FS <= 250,
	     "gyro full-scale above 250 dps overflows centi-deg/s in an int16");
BUILD_ASSERT(CONFIG_LSM6DSL_ACCEL_FS != 0,
	     "Sophon pins the accel full-scale at build time; 0 means runtime-selected");
BUILD_ASSERT(CONFIG_LSM6DSL_ACCEL_FS <= 32,
	     "accel full-scale above 32 g overflows milli-g in an int16");

/*
 * ODR 0 means "selected at runtime", and the driver writes that straight into
 * CTRL1_XL / CTRL2_G -- where 0 is the *power-down* code. Nothing is set at
 * runtime here, so a 0 here would leave the sensor silently asleep and the
 * data-ready line permanently low: no error anywhere, just no samples ever.
 */
BUILD_ASSERT(CONFIG_LSM6DSL_ACCEL_ODR != 0, "accel ODR 0 powers the sensor down");
BUILD_ASSERT(CONFIG_LSM6DSL_GYRO_ODR != 0, "gyro ODR 0 powers the sensor down");

/*
 * ODR code 3 is 52 Hz in the driver's table. Asserted so SOPHON_IMU_ODR_HZ --
 * which the console line and the docs both quote -- cannot drift away from what
 * the hardware was actually told to do.
 *
 * Both must match: the accelerometer and gyroscope have independent ODRs, and
 * the data-ready line is the OR of the two. Setting them differently makes the
 * interrupt fire at the faster rate with the slower channel repeating stale
 * values -- a stream that looks like it is sampling faster than it is.
 */
BUILD_ASSERT(CONFIG_LSM6DSL_ACCEL_ODR == 3 && CONFIG_LSM6DSL_GYRO_ODR == 3,
	     "SOPHON_IMU_ODR_HZ assumes ODR code 3 (52 Hz) on both channels");

static int64_t div_round(int64_t num, int64_t den)
{
	return num >= 0 ? (num + den / 2) / den : (num - den / 2) / den;
}

static int16_t clamp16(int64_t v)
{
	return (int16_t)CLAMP(v, INT16_MIN, INT16_MAX);
}

/*
 * The Zephyr sensor API hands back m/s^2 as val1 + val2/1e6. Milli-g is
 * micro-m/s^2 / 9806.65, done as *100/980665 to stay in integers -- an int64 is
 * needed because 4 g is already ~3.9e9 after the multiply.
 *
 * Integer rather than float throughout: this runs ~54 times a second on a
 * Cortex-M4F alongside the radio, and the wire quantum is 1 mg, so the
 * fractional precision a float would buy is discarded two lines later anyway.
 */
static int16_t accel_to_mg(const struct sensor_value *val)
{
	int64_t micro_ms2 = (int64_t)val->val1 * 1000000 + val->val2;

	return clamp16(div_round(micro_ms2 * 100, 980665));
}

/*
 * rad/s to centi-degrees/second: multiply by 100 * 180/pi = 5729.578, applied
 * as 5729578/1e9 against the micro-rad/s value.
 */
static int16_t gyro_to_cdps(const struct sensor_value *val)
{
	int64_t micro_rads = (int64_t)val->val1 * 1000000 + val->val2;

	return clamp16(div_round(micro_rads * 5729578, 1000000000));
}

/*
 * Runs on the driver's own trigger thread.
 *
 * EVERYTHING HERE MUST BE BOUNDED, and by a margin well inside one sample
 * period. This is not a style preference -- overrunning a period kills the
 * stream permanently. See the re-arm race described above sophon_imu_init().
 *
 * So: fetch, convert, hand off. The callback is expected to do the same and
 * return; in particular it must not transmit from this thread, because
 * bt_gatt_notify() allocates with K_FOREVER on any thread that is not the
 * system work queue and will block here indefinitely when ATT buffers run dry.
 */
static void data_ready(const struct device *dev, const struct sensor_trigger *trig)
{
	static bool fetch_failing;

	struct sensor_value accel[3], gyro[3];
	struct sophon_imu_sample sample;
	int err;

	ARG_UNUSED(trig);

	/*
	 * The fetch is unconditional -- it happens even when nobody is
	 * subscribed and the sample is about to be thrown away.
	 *
	 * This is not defensive tidiness, it is required for the stream to keep
	 * running. The driver arms the line as GPIO_INT_EDGE_TO_ACTIVE, disables
	 * it while this handler runs, and re-enables it on return without
	 * re-checking the level. DRDY stays asserted until the output registers
	 * are read, so skipping the fetch leaves the line already high when the
	 * edge interrupt is re-armed -- no further edge ever arrives and the IMU
	 * goes permanently silent, with no error reported anywhere.
	 *
	 * Whether the sample is *used* is the caller's decision. Whether it is
	 * *taken* is not.
	 */
	err = sensor_sample_fetch(dev);
	if (err) {
		/*
		 * Logged on the healthy -> failing edge only. At ~54 Hz a line
		 * per failure is over 3000 a minute, and the same reasoning
		 * applies as to the transmit counters in main.c: the flood
		 * describes the problem while competing with it.
		 */
		if (!fetch_failing) {
			LOG_ERR("IMU sample fetch failed (%d); further errors suppressed", err);
			fetch_failing = true;
		}
		return;
	}

	if (fetch_failing) {
		LOG_INF("IMU sample fetch recovered");
		fetch_failing = false;
	}

	/*
	 * Stamped after a successful fetch, because that is the event the
	 * watchdog cares about: the line was serviced and DRDY was cleared.
	 */
	last_sample_ms = k_uptime_get_32();

	if (sensor_channel_get(dev, SENSOR_CHAN_ACCEL_XYZ, accel) != 0 ||
	    sensor_channel_get(dev, SENSOR_CHAN_GYRO_XYZ, gyro) != 0) {
		return;
	}

	sample.ax = accel_to_mg(&accel[0]);
	sample.ay = accel_to_mg(&accel[1]);
	sample.az = accel_to_mg(&accel[2]);
	sample.gx = gyro_to_cdps(&gyro[0]);
	sample.gy = gyro_to_cdps(&gyro[1]);
	sample.gz = gyro_to_cdps(&gyro[2]);

	sample_cb(&sample);
}

/*
 * Static, not a stack local: lsm6dsl_trigger_set() stores this pointer in its
 * driver data and dereferences it on every interrupt thereafter. A local would
 * dangle the moment sophon_imu_init() returned.
 */
static const struct sensor_trigger drdy_trigger = {
	.type = SENSOR_TRIG_DATA_READY,
	.chan = SENSOR_CHAN_ALL,
};

/*
 * Liveness watchdog.
 *
 * The driver has a race this app cannot fix from the outside: lsm6dsl_thread_cb()
 * re-enables the edge interrupt after the handler returns but never re-checks
 * the level, so if DRDY went high again while the handler was running, no
 * further edge arrives and the stream is dead for good. lsm6dsl_trigger_set()
 * *does* handle the already-high case, with an explicit gpio_pin_get_dt() and a
 * manual kick -- so re-arming through it is exactly the recovery path.
 *
 * This converts a permanent, silent death into a logged hiccup. It is
 * deliberately not the primary defence: the real fix is keeping the handler
 * short (see data_ready), and if this ever fires it means something overran a
 * sample period and is worth investigating rather than shrugging at.
 */
#define STALL_TIMEOUT_MS 250 /* ~13 sample periods at 54 Hz */
#define WATCHDOG_PERIOD_MS 200

static void watchdog_work_handler(struct k_work *work)
{
	uint32_t idle;
	int err;

	ARG_UNUSED(work);

	if (!armed) {
		return;
	}

	idle = k_uptime_get_32() - last_sample_ms;
	if (idle < STALL_TIMEOUT_MS) {
		return;
	}

	LOG_WRN("no IMU sample for %u ms -- re-arming the data-ready trigger", idle);

	err = sensor_trigger_set(imu, &drdy_trigger, data_ready);
	if (err) {
		LOG_ERR("re-arm failed (%d)", err);
		return;
	}

	/*
	 * Re-stamped so a re-arm that does not take effect reports the next
	 * stall against this attempt rather than firing again immediately.
	 */
	last_sample_ms = k_uptime_get_32();
}

static K_WORK_DEFINE(watchdog_work, watchdog_work_handler);

static void watchdog_timer_expiry(struct k_timer *timer)
{
	ARG_UNUSED(timer);

	/* Timer callbacks are ISR context; sensor_trigger_set() is not safe there. */
	k_work_submit(&watchdog_work);
}

static K_TIMER_DEFINE(watchdog_timer, watchdog_timer_expiry, NULL);

int sophon_imu_init(sophon_imu_cb_t cb)
{
	int err;

	if (cb == NULL) {
		return -EINVAL;
	}

	/*
	 * The power rail is a regulator-fixed with regulator-boot-on and a
	 * 3000 us startup-delay-us, so it is already up and settled by the time
	 * the driver's init runs -- device_is_ready() covers both. Nothing here
	 * needs to sequence the regulator by hand.
	 */
	if (!device_is_ready(imu)) {
		LOG_ERR("LSM6DS3TR-C not ready -- check the sensor power rail");
		return -ENODEV;
	}

	sample_cb = cb;
	last_sample_ms = k_uptime_get_32();

	err = sensor_trigger_set(imu, &drdy_trigger, data_ready);
	if (err) {
		LOG_ERR("data-ready trigger not armed (%d)", err);
		sample_cb = NULL;
		return err;
	}

	armed = true;
	k_timer_start(&watchdog_timer, K_MSEC(WATCHDOG_PERIOD_MS), K_MSEC(WATCHDOG_PERIOD_MS));

	LOG_INF("IMU streaming: accel +/-%d g, gyro +/-%d dps, ODR %d Hz nominal",
		CONFIG_LSM6DSL_ACCEL_FS, CONFIG_LSM6DSL_GYRO_FS, SOPHON_IMU_ODR_HZ);

	return 0;
}
