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

/* Skeleton rate: slow enough to watch the link by eye. #209 raises this to 50. */
#define NOTIFY_PERIOD_MS 1000

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

	/*
	 * One loop drives both the LED and the notify timer. The LED ticks at
	 * 250 ms so "connected" (solid) is distinguishable at a glance from
	 * "advertising" (blinking); the notify fires every NOTIFY_PERIOD_MS.
	 */
	while (1) {
		bool connected = sophon_ble_connected();

		led_set(connected ? true : (tick & 1));

		if ((tick % (NOTIFY_PERIOD_MS / 250)) == 0 && sophon_ble_subscribed()) {
			frame.seq++;
			frame.t_ms = k_uptime_get_32();
			/* axes stay zero until #209 */

			err = sophon_ble_notify(&frame);
			if (err && err != -ENOTCONN) {
				LOG_WRN("notify failed (%d)", err);
			}
		}

		tick++;
		k_msleep(250);
	}

	return 0;
}
