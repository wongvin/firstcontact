/*
 * Battery terminal voltage, from the XIAO nRF52840's on-module divider (#268).
 *
 * 1 MOhm / 510 kOhm on AIN7 (P0.31), switched in by P0.14 sinking. The divider
 * node and the SAADC channel are declared in `app.overlay`, because the board
 * files declare neither; Zephyr's `voltage-divider` driver owns the enable, the
 * settle delay and the scaling.
 *
 * **Voltage only, deliberately.** There is no fuel gauge on this board -- the
 * BQ25101 is a charger, so nothing counts charge in or out of the pack -- and a
 * LiPo's discharge curve is nearly flat across 3.7-3.9 V, most of its usable
 * range. Under a 52 Hz IMU and an active radio the terminal voltage also sags in
 * bursts. A percentage or an mAh figure derived from this would be modelled, not
 * measured, which is the failure #228, #230, #237 and #263 each exist to
 * correct. PROTOCOL.md records the reasoning so it is not "improved" later.
 */

#ifndef SOPHON_BATTERY_H
#define SOPHON_BATTERY_H

#include <stdint.h>

#include <zephyr/sys/util.h>

/*
 * How often the pack is sampled.
 *
 * Matched to the app's read cadence, which is also one minute. Equal rather
 * than faster: a central's read returns this cache, so sampling more often than
 * it is read would only shrink the number in the age field without putting any
 * more truth behind the voltage.
 *
 * Both terms of the age can therefore reach a minute, putting the worst case a
 * central sees at ~120 s. The cost is ~71 ms of ADC per minute, about 0.12% duty
 * on the divider.
 */
#define SOPHON_BATTERY_PERIOD_MS 60000

/*
 * Samples per reading, and their spacing.
 *
 * Spread rather than taken back to back. Averaging a burst removes ADC noise
 * but not the load sag that matters here: at a 50 ms connection interval, eight
 * conversions in a few milliseconds all land inside one radio window and
 * inherit whatever that window was doing. Spacing them 10 ms apart spans at
 * least one full interval, so the mean straddles both the transmit bursts and
 * the quiet between them.
 */
#define SOPHON_BATTERY_SAMPLES 8
#define SOPHON_BATTERY_SAMPLE_GAP_MS 10

/*
 * Starts the sampler. Returns 0, or a negative errno if the divider is absent
 * or not ready.
 *
 * A failure here is not fatal and the caller is expected to carry on, the same
 * as for a missing IMU. `sophon_battery_read()` then reports no reading, and the
 * app renders that as `Not reported` -- the #230 idiom for "this peripheral does
 * not report it", which is also every board flashed before this change.
 */
/*
 * How often VBUS is checked for a change, independent of the sampling timer.
 *
 * The USB flag is what decides whether the app may call the reading a battery
 * voltage, so it has to track reality quickly -- waiting for the next 60 s
 * sample meant unplugging USB left the app saying `VBAT net` for up to a minute,
 * and up to two once the central's own poll is added. A register read costs
 * nothing, so this is checked every second and a change triggers an immediate
 * re-sample: the voltage AND its flag both move at once, which matters because
 * a sample taken on USB really was the charger's rail.
 */
#define SOPHON_BATTERY_VBUS_POLL_MS 1000

int sophon_battery_init(void);

/*
 * Most recent reading.
 *
 * @param mv     terminal millivolts, or 0 meaning **no reading** -- not a
 *               reading of zero. A connected pack cannot be at 0 mV, so the
 *               sentinel is unambiguous.
 * @param age_s  seconds since that reading was taken, saturating at UINT16_MAX.
 *
 * The age is on the wire, not just in the log, for the reason #237 had to be
 * corrected: a GATT read proves only that a central asked, and the cached value
 * behind it may be a minute old or -- if sampling has failed since -- much
 * older. A voltage that refreshes its own timestamp merely by being read is the
 * same defect as an RSSI that did.
 */
/*
 * Set when USB was supplying the board at the moment of the reading.
 *
 * This is the whole of what can be known about the source. VBAT is the charger's
 * OUT, the BAT pad and the top of the divider shorted together, so no
 * measurement at that node can say what is driving it. VBUS can:
 *
 *   absent  -> the board is running off the pack, so the reading IS the pack
 *   present -> the charger is holding the node; the reading is simply the
 *              voltage on VBAT, which may or may not be a pack
 *
 * Note what this deliberately does NOT claim: pack ABSENCE is not detectable.
 * `/CHG` would have been the extra evidence, but P0.17 does not carry it -- the
 * net name says `~{CHG}` while the pin lands on the BQ25101's PRETERM input,
 * with its programming resistor R8 marked DNP.
 */
#define SOPHON_BATTERY_FLAG_USB BIT(0)

void sophon_battery_read(uint16_t *mv, uint16_t *age_s, uint8_t *flags);

#endif /* SOPHON_BATTERY_H */
