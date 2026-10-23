# Gateway noise floor

Design for #336, agreed on 2026-10-22. It fills the `noise_min` and
`noise_median` fields that the LoRa Link record's version 2 (#333,
LORA-LINK-V2-PLAN.md) reserved. PROTOCOL.md § LoRa Link frame is the reference
for the fields; this records how they're measured and why.

## Context

The 2026-10-18 walk suggested the gateway hears about −104 dBm of noise, roughly 5–7 dB above the −111 dBm a 500 kHz channel with a 6 dB noise figure should give. That figure was inferred from packet RSSI and SNR on weak windows. It can't tell apart:
- noise from the receiver's setup (the iPhone and its USB-C cable near the antenna);
- ambient 915 MHz traffic;
- a weak signal.

#333's version 2 record already carries `noise_min` and `noise_median` (bytes 15–16), sent as `0x7F` ("not measured"), and the app and CSV already read and write them. This issue fills them, shows them, and uses them.

## Firmware: sampling the SX1262's instantaneous RSSI

- **The command:** GetRssiInst, opcode `0x15`. Over SPI it's 3 bytes: the opcode, then the status byte, then `RssiInst`. The noise is −RssiInst ÷ 2 dBm. It's allowed in RX mode and doesn't disturb reception.
- **How it's sent:** the same way as `radio_clear_irq()` (`src/lora_link.c:458`), the DIO1 watchdog's precedent:
  - wait for BUSY low, giving up after 10 ms;
  - send with `spi_transceive_dt(&lora_spi, …)`;
  - **only from the system work queue**, where the loramac-node driver does all its radio access, so the two can't interleave.
- **Never sampling during a packet:** packets would read as signal, not noise. The sensor sends a packet every k samples, k × 18.4 ms at 54.3 Hz, and each one is on air for its preset's airtime. The quiet gap between them is what's left of the period, so the sample goes **in the middle of the gap**: half of (k × 18.4 ms − airtime) after each received packet. The gateway computes that from its preset at start, with `lora_airtime()` as the boot log already does (`src/lora_link.c:589`).

  **Timing by preset**, the first 200 ms after a packet starts (1 character = 4 ms; █ on air, · quiet, ▲ the noise sample):

  ```
  V0  │███████████████████·············▲·············████│ SF7 k=10 every 184.0 ms · on air  75.6 · gap 108.4 · sample +54.2
  V1  │███████████████···············▲···············████│ SF7 k=10 every 184.0 ms · on air  56.4 · gap 127.6 · sample +63.8
  V3  │████████·····▲·····███████·····▲·····███████······│ SF7 k=4  every  73.6 ms · on air  28.2 · gap  45.4 · sample +22.7
  V3b │█████··▲··█████·▲··█████·▲··█████··▲·█████··▲·████│ SF7 k=2  every  36.8 ms · on air  19.3 · gap  17.5 · sample + 8.7
  V4  │██████████····▲····█████████····▲····██████████···│ SF7 k=4  every  73.6 ms · on air  37.4 · gap  36.2 · sample +18.1
  V5  │█████████████████████████···········▲·········████│ SF8 k=10 every 184.0 ms · on air 100.0 · gap  84.0 · sample +42.0
  V5b │███████████████····▲···███████████████····▲···████│ SF8 k=5  every  92.0 ms · on air  59.0 · gap  33.0 · sample +16.5
  V6  │████████·····▲·····███████·····▲·····███████······│ SF7 k=4  every  73.6 ms · on air  28.2 · gap  45.4 · sample +22.7
  V6b │█████████████████████████···········▲·········████│ SF8 k=10 every 184.0 ms · on air 100.0 · gap  84.0 · sample +42.0
  ```

  - **Why mid-gap rather than a fixed delay:** the gaps range from 17.5 ms (V3b) to 127.6 ms (V1). A fixed +10 ms would leave only 7.5 ms before V3b's next packet, while wasting most of the long gaps. Mid-gap keeps the most margin on both sides for every preset: at least 8.7 ms (V3b), and 22.7 ms at the default V6.
  - **Latency:** the receive callback (`gateway_rx()`, on the system work queue) runs a millisecond or two after the packet ends, which mid-gap absorbs.
  - **One sample per packet:** about 13 a second at V6, 27 at V3b, 5.4 at the k = 10 presets.
  - **After a lost packet** (or one that fails its CRC, which never reaches `gateway_rx()`), sampling **stays in step** with the sensor's schedule: the next sample goes at the next expected gap centre, `last packet + delay + m × period`, for up to **1 s**. A free-running timer would drift onto packets still being sent, and contaminate the noise exactly on the marginal links this is meant to diagnose (review finding, #336).
  - **After 1 s of silence**, nobody is sending, and a timer samples every 100 ms: everything then is noise or interference.
  - **Walk-test variant rotation** changes k and airtime packet by packet; noise isn't sampled while rotating, and the fields stay `0x7F`.
- **Per window, the figures go into the record:**
  - **`noise_min`:** the clean floor;
  - **`noise_median`:** ongoing interference. A histogram of 1 dB bins over −127…0 dBm, 128 × u16 (256 B RAM), so no sample array is kept and the median is exact to 1 dB.
  - A window with no samples, such as a BUSY timeout every time, stays `0x7F`.
- **Console:** the gateway's stats line adds `noise min/median`.
- **Sensors and direct boards:** unaffected.
- **`VERSION`:** 2.31.1 (2.31.0 had a free-running idle timer; see below).

## App

- **LoRa link section:** a **Noise floor** row after LoRa SNR: "−108 dBm (median −105)". It reads "Not measured" for older firmware (`0x7F`).
- **Margin text:** the RSSI row can also show **signal above noise** = `rssi_avg − noise_median`, an estimate of SNR independent of LoRa's own figure. Only shown when both are present.
- **CSV:** `noise_min` and `noise_median` are already written (empty while `0x7F`). No format change.

## Report

`walktest-report.py`:
- per distance band, the median `noise_median` and the minimum `noise_min`;
- a **signal estimate** column = `rssi_avg − noise_median`, replacing today's inference from SNR;
- both only when the columns are filled.

## Docs

- **PROTOCOL.md § LoRa Link frame:** `noise_min`/`noise_median` are measured from 2.31.1, and how.
- **LORA-PROTOCOL.md:** a short § Noise floor: what's sampled and when, the expected thermal floor (−111 dBm at 500 kHz with a 6 dB NF), and how to read min against median.
- **HARDWARE.md § Wio-SX1262 › a new "Receiver noise floor" subsection:** the bench figures below.
- **TEST-PLAN.md:** a case; ChangeLog.

## Verification

1. **Builds:** firmware MCUboot build, `test-codec.sh`, app Debug and Release, SwiftLint, simulator self-checks (add a vector with noise present).
2. **Reception unaffected:** at the bench, a 2-minute recording with the same sensor and placement before and after the update shows the same LQ (100%) and samples per window.
3. **Noise figures:** with the sensor off, `noise_min` sits near the thermal floor; with it on, `noise_median` stays near the floor, not near the packet RSSI. That shows samples land between packets.
4. **The bench check behind the issue,** recorded in HARDWARE.md:
   1. the gateway on its own LiPo, no USB;
   2. powered from the iPhone over USB-C;
   3. with the phone and cable laid against the antenna, the worst case.

   **Result (2026-10-22, HARDWARE.md § Receiver noise floor):** the same about −105 dBm floor in every setup, so neither the phone nor its cable adds measurable noise.

   The user moves the hardware between three short recordings, and I read the figures from the CSVs.
5. **swift-reviewer** on the app diff.

## Precision and what the figures include

- **Rounding:** `−RssiInst ÷ 2` is truncated towards zero, so an odd raw value reads 0.5 dB louder (raw 221 is −110, not −110.5). The histogram's 1 dB bins match that.
- **Median:** with an even number of samples, the lower (quieter) of the two middle values. Both effects are within 1 dB.
- **Other transmitters are interference, and are counted as such.** A second sensor on the same channel and preset sends its packets out of step with the first, so some land in the first one's gaps. The median then rises towards their RSSI. On the bench, with 4D88 and 86F0 both on air, the median read about −58 dBm against a −106 dBm floor when nothing was heard. That's the noise figure working: the channel genuinely wasn't quiet.
