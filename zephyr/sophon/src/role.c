/*
 * Runtime role selection and the radio presence check (#303).
 *
 * WHY A PRESENCE CHECK AT ALL. The loramac-node SX126x driver waits on BUSY with
 * no timeout (SX126xWaitOnBusy() spins until the line falls). On a board with
 * no Wio-SX1262 fitted, BUSY is an unconnected pin, and a floating input that
 * happens to read high hangs the boot inside the driver's init -- the direct
 * role, which must keep working exactly as before LoRa, would never start.
 *
 * So the lora0 node carries zephyr,deferred-init and the driver does not start
 * on its own. This file asks the chip a question only a real SX1262 answers:
 * the LoRa sync-word register, 0x0740-0x0741, reads 0x14 0x24 out of reset (the
 * private sync word). An absent radio leaves MISO floating, which reads as
 * 0x00 or 0xFF and never as that pair. Only on a match is device_init() called.
 *
 * BUSY is pulled DOWN during the check, the opposite of what an absent radio
 * would need to hang: with no chip the wait below passes at once and the SPI
 * read is what rejects it, and every wait here is bounded.
 */

#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/spi.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "role.h"

LOG_MODULE_REGISTER(sophon_role, LOG_LEVEL_INF);

#define LORA_NODE DT_NODELABEL(lora0)

/* SX126x ReadRegister: opcode, 16-bit address, one status byte, then data. */
#define SX126X_OP_READ_REGISTER 0x1D
#define SX126X_REG_LORA_SYNC    0x0740
#define SYNC_RESET_MSB          0x14
#define SYNC_RESET_LSB          0x24

/* Datasheet: BUSY falls within ~3.5 ms of a reset with the TCXO still off.
 * 20 ms is generous without making a radio-less boot noticeably slower. */
#define BUSY_TIMEOUT_MS 20

static const struct device *const lora_dev = DEVICE_DT_GET(LORA_NODE);
static const struct spi_dt_spec lora_spi =
	SPI_DT_SPEC_GET(LORA_NODE, SPI_WORD_SET(8) | SPI_TRANSFER_MSB);
static const struct gpio_dt_spec lora_busy = GPIO_DT_SPEC_GET(LORA_NODE, busy_gpios);
static const struct gpio_dt_spec lora_reset = GPIO_DT_SPEC_GET(LORA_NODE, reset_gpios);

static enum sophon_role role = SOPHON_ROLE_DIRECT;
static bool role_radio;
static bool role_imu;

/*
 * The boot-time role line is usually lost: logging is deferred, the backlog is
 * flushed in one burst after LOG_PROCESS_THREAD_STARTUP_DELAY_MS, and the CDC
 * ACM console discards what does not fit rather than blocking. So it is said
 * again once things are quiet, where it reliably reaches the console.
 */
#define ROLE_RELOG_DELAY_MS 10000

static void role_relog_handler(struct k_work *work)
{
	ARG_UNUSED(work);
	LOG_INF("role: %s (radio %s, IMU %s)", sophon_role_name(role), role_radio ? "yes" : "no",
		role_imu ? "yes" : "no");
}

static K_WORK_DELAYABLE_DEFINE(role_relog_work, role_relog_handler);

static bool wait_not_busy(void)
{
	int64_t deadline = k_uptime_get() + BUSY_TIMEOUT_MS;

	while (gpio_pin_get_dt(&lora_busy) > 0) {
		if (k_uptime_get() > deadline) {
			return false;
		}
		k_busy_wait(100);
	}
	return true;
}

/* Returns true only if a real SX126x answered with its reset sync word. */
static bool radio_present(void)
{
	uint8_t tx[6] = {SX126X_OP_READ_REGISTER,
			 SX126X_REG_LORA_SYNC >> 8,
			 SX126X_REG_LORA_SYNC & 0xFF,
			 0,
			 0,
			 0};
	uint8_t rx[6] = {0};
	const struct spi_buf tx_buf = {.buf = tx, .len = sizeof(tx)};
	const struct spi_buf rx_buf = {.buf = rx, .len = sizeof(rx)};
	const struct spi_buf_set tx_set = {.buffers = &tx_buf, .count = 1};
	const struct spi_buf_set rx_set = {.buffers = &rx_buf, .count = 1};
	bool present = false;
	int err;

	if (!spi_is_ready_dt(&lora_spi) || !gpio_is_ready_dt(&lora_busy) ||
	    !gpio_is_ready_dt(&lora_reset)) {
		LOG_WRN("radio check: SPI or GPIO not ready");
		return false;
	}

	if (gpio_pin_configure_dt(&lora_busy, GPIO_INPUT | GPIO_PULL_DOWN) ||
	    gpio_pin_configure_dt(&lora_reset, GPIO_OUTPUT_ACTIVE)) {
		LOG_WRN("radio check: pin setup failed");
		goto release;
	}

	/* NRESET is active low; ACTIVE asserts it. >= 100 us per datasheet. */
	k_busy_wait(1000);
	gpio_pin_set_dt(&lora_reset, 0);
	k_busy_wait(1000);

	if (!wait_not_busy()) {
		LOG_INF("radio check: BUSY stayed high");
		goto release;
	}

	err = spi_transceive_dt(&lora_spi, &tx_set, &rx_set);
	if (err) {
		LOG_WRN("radio check: SPI read failed (%d)", err);
		goto release;
	}

	present = (rx[4] == SYNC_RESET_MSB && rx[5] == SYNC_RESET_LSB);
	LOG_INF("radio check: sync word 0x%02x%02x -> %s", rx[4], rx[5],
		present ? "SX126x present" : "no radio");

release:
	/*
	 * Hand the pins back unconfigured either way. With a radio, the driver
	 * reconfigures them in device_init(); without one, nothing should drive a
	 * pin that may be connected to whatever else is on the header.
	 */
	(void)gpio_pin_configure_dt(&lora_busy, GPIO_DISCONNECTED);
	(void)gpio_pin_configure_dt(&lora_reset, GPIO_DISCONNECTED);
	return present;
}

enum sophon_role sophon_role_detect(bool imu_ok)
{
	bool radio = radio_present();

	if (radio) {
		int err = device_init(lora_dev);

		if (err) {
			LOG_ERR("radio answered but its driver failed to start (%d)", err);
			radio = false;
		}
	}

	if (!radio) {
		role = SOPHON_ROLE_DIRECT;
	} else if (imu_ok) {
		role = SOPHON_ROLE_SENSOR;
	} else {
		/*
		 * Also where a sensor whose IMU failed to start ends up -- documented
		 * in LORA-PROTOCOL.md § Roles rather than guessed around here.
		 */
		role = SOPHON_ROLE_GATEWAY;
	}

	role_radio = radio;
	role_imu = imu_ok;
	LOG_INF("role: %s (radio %s, IMU %s)", sophon_role_name(role), radio ? "yes" : "no",
		imu_ok ? "yes" : "no");
	(void)k_work_schedule(&role_relog_work, K_MSEC(ROLE_RELOG_DELAY_MS));
	return role;
}

enum sophon_role sophon_role(void)
{
	return role;
}

const char *sophon_role_name(enum sophon_role r)
{
	switch (r) {
	case SOPHON_ROLE_SENSOR:
		return "sensor";
	case SOPHON_ROLE_GATEWAY:
		return "gateway";
	default:
		return "direct";
	}
}
