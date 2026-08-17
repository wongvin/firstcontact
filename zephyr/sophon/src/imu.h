/*
 * LSM6DS3TR-C accelerometer + gyroscope, paced by its own data-ready interrupt.
 *
 * The board carries the IMU on I2C at 0x6a behind a regulator-fixed power rail
 * (gpio1 8, regulator-boot-on), with the data-ready line on gpio0 11. Zephyr
 * drives it with the st,lsm6dsl driver.
 */

#ifndef SOPHON_IMU_H
#define SOPHON_IMU_H

#include <stdint.h>

/*
 * Nominal sample rate, and the notify rate that follows from it.
 *
 * The plan and PROTOCOL.md say "50 Hz". The LSM6DSL cannot produce it: its ODR
 * grid is 12.5 / 26 / 52 / 104 / 208 ... and 50 is not on it. Pacing off the
 * sensor's own data-ready line therefore means taking its nearest step, 52 Hz,
 * rather than resampling a 52 Hz sensor onto a 50 Hz timer -- which would
 * reintroduce exactly the drift between the two clocks that the interrupt is
 * here to remove, and drop or duplicate a sample every half second doing it.
 *
 * The overshoot is free: the connection-event budget in UPDATED-PLAN.md costs
 * 50 Hz at 0.75 notifications per 15 ms event against iOS's ~4. Every column of
 * that table stays comfortable.
 *
 * This is the rate the sensor is *asked* for, not the one it delivers. Measured
 * on hardware the stream runs at 54.2-54.4 Hz -- the ODR comes off an internal RC
 * oscillator that varies part to part and with temperature. Use it for the
 * console banner and for sizing arguments; never as a timebase. t_ms is the
 * authority, and PROTOCOL.md says so to consumers too.
 */
#define SOPHON_IMU_ODR_HZ 52

/*
 * One sample, already in the frame's wire units so the caller does no
 * arithmetic. The sensor API speaks m/s^2 and rad/s; the conversion to these
 * units lives in imu.c, next to the saturation reasoning that justifies them.
 */
struct sophon_imu_sample {
	int16_t ax; /* milli-g */
	int16_t ay;
	int16_t az;
	int16_t gx; /* centi-degrees/second */
	int16_t gy;
	int16_t gz;
};

/*
 * Invoked once per data-ready interrupt, on the driver's own trigger thread --
 * NOT an ISR, so the callee may call into the Bluetooth API directly.
 *
 * It is called on every sample, including while nobody is subscribed. That is
 * deliberate: see the fetch discussion in imu.c. Deciding what to do with a
 * sample is the caller's business, but *taking* it is not optional.
 */
typedef void (*sophon_imu_cb_t)(const struct sophon_imu_sample *sample);

/*
 * Powers up the sensor and arms the data-ready trigger. Returns 0 on success,
 * or a negative errno if the sensor is absent or refused to start -- which the
 * caller is expected to survive rather than treat as fatal, since the BLE link
 * is useful (and debuggable) without an IMU behind it.
 */
int sophon_imu_init(sophon_imu_cb_t cb);

#endif /* SOPHON_IMU_H */
