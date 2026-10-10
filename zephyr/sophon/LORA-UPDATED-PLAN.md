# sophon: LoRa relay — sensor → gateway → iOS

> **Current design record for #303.** It started as a copy of the frozen
> [LORA-PLAN.md](LORA-PLAN.md), approved 2026-10-09, and changes as
> implementation settles decisions the original couldn't. Where the two
> disagree, this one is right. § Changes from the original plan lists every
> difference. The wire contract is [LORA-PROTOCOL.md](LORA-PROTOCOL.md).

## Changes from the original plan

| Date | Change | Section |
|---|---|---|
| 2026-10-09 | **SX1262 driver: Semtech's loramac-node, chosen over Zephyr's native driver.** The original plan assumed loramac-node without knowing there was a choice. | § Firmware → Driver selection |
| 2026-10-09 | **Gateway board migrated.** `Sophon-01A7` was backed up as shipped and then flashed with MCUboot 2.8.0 by SWD probe, which also verified `flash-swd.sh`'s SoftDevice guard (#301, #305). It runs the Sense image in IMU fallback with no ill effect, so one image for both boards works in practice. The KiCad pin check is still open. | § Gateway board migration |
| 2026-10-10 | **The gateway configures TX before RX.** loramac-node's `lora_airtime()` uses the last TX configuration only. A gateway that never configured TX divided by zero inside `RadioGetLoRaTimeOnAirNumerator()`, a UsageFault at boot, found on hardware. `lora_link_start()` now configures TX, logs the airtime, then switches the gateway to RX. | § Firmware |
| 2026-10-10 | **The walk test is turned around:** the sensor stays at base, and the walker carries the gateway and phone. The app shows live link stats and records them with GPS (#309), replacing the laptop log and the waypoint timing. `walktest-log.sh` is dropped, and `walktest-report.py` reads the app's CSV. The walk test now **depends on #309**. | § Walk-test mode, § Walk-test procedure, § Verification |
| 2026-10-10 | **Antenna gain and the FCC limit.** The levers table now separates the gateway's antenna (receive only, no FCC gain limit, best range per dollar) from the sensor's (≤ 14 dBi at +22 dBm, from EIRP ≤ 36 dBm). The original said only "plenty of margin". New § Antenna gain and the FCC limit. | § Levers for range and latency |
| 2026-10-10 | **Stage 3 verified end to end:** 86F0 (sensor) → 01A7 (gateway) → iPhone at preset V3. LQ 100.0%, 53.6 Hz, RSSI −6 dBm and SNR +12 dB at desk range; iOS granted the gateway's 15 ms interval. | § Verification |
| 2026-10-09 | **Build modes.** `build.sh` builds for MCUboot by default and `flash.sh` is now `flash-uf2.sh` (#270). MCUboot-only Kconfig lives in `swd/app-mcuboot.conf` (#306). The LoRa settings go in `prj.conf`, because both boot paths must compile. | § Firmware → Build changes |

## Context

Today a Sophon board samples its LSM6DS3TR-C at ~54 Hz and sends 18-byte motion frames straight to the iOS app over BLE. The goal is a LoRa hop in the middle, so the sensor can be far from the phone:

```
[Sense Plus + Wio-SX1262]  --LoRa 915 MHz-->  [kit XIAO nRF52840 + Wio-SX1262]  --BLE (unchanged)-->  iOS app
        "sensor"                                         "gateway"
```

**Constraints:**
- The iOS app and the GATT protocol do not change.
- Every node runs MCUboot.
- No rewiring is needed. The Sense IMU is on the internal `i2c0` bus (P0.07/P0.27), not on D4/D5 (`xiao_ble_nrf52840_sense.dts:31-46`).

**Decided:**
- **Hardware:** the sensor is an existing Sense Plus. The gateway is the kit's plain XIAO nRF52840, migrated to MCUboot.
- **Sensor BLE:** the sensor advertises only its name and the MCUmgr SMP service. The app doesn't see it; `flash-ota.sh` still finds it by name (`scripts/ble-find.py:26-57`).
- **Gateway identity:** the gateway advertises its own `Sophon-XXXX` name.
- **Role:** one image for both boards; the role is detected at boot.
- **Method:** each ExpressLRS idea is a variant measured in the walk test against the current design. The default preset is chosen from that data.

## Workflow

1. File the issue `sophon: LoRa relay — sensor→gateway→iOS over SX1262` with a `### Requirements` checklist and add it to Project 1.
2. Create the branch `<N>-lora-relay`.
3. Set Status to In progress and Start date to today.
4. Also file `sophon: LoRa frequency hopping + downlink (ExpressLRS-style)` as a cross-linked follow-up in Backlog.
5. **Save this plan as `zephyr/sophon/LORA-PLAN.md`,** the original LoRa design record, named like `SCAN-RESPONSE-PLAN.md`. Do this on the branch, before any code.
   - Remove the iteration callout and the `` highlights.
   - Keep everything else word for word, under a header line giving the issue number and the date.
   - Link it from the issue body. `LORA-PROTOCOL.md` will cite it as the source of the variant analysis.
   - It ships in the same commit as the code, after consent, like every other doc.

## Hardware / wiring (no rewiring)

| SX1262 | XIAO | nRF |
|---|---|---|
| SCK/MISO/MOSI | D8/D9/D10 (`spi2`) | P1.13/P1.14/P1.15 |
| NSS | D4 | P0.04 |
| DIO1 | D1 | P0.03 |
| RESET | D2 | P0.28 |
| BUSY | D3 | P0.29 |
| RXEN | D5 | P0.05 |
| TX switch | DIO2 (`dio2-tx-enable`) | — |
| TCXO | DIO3, 1.8 V, 5 ms | — |

- The pins come from Meshtastic's `seeed_xiao_nrf52840_kit/variant.h`, checked against `seeed_xiao_connector.dtsi`.
- `i2c1` (D4/D5) is unused by Sophon and is disabled in every image.
- D0 (P0.02) stays free on both boards for the bench latency test.
- Always attach the antenna before transmitting.

## Throughput requirement

The symbols used here (f_ODR, Share, Rb) are defined in the next section, "LoRa variables".

- Motion data: f_ODR × 18 B = **979 B/s = 7.83 kbit/s**. Any variant needs Share < 100%. In practice, keep Share ≤ 60% so there is headroom.
- Rb rules out SF7/125 (5.47 kbit/s) and SF9/500 (7.03 kbit/s). At 500 kHz, only SF7 and SF8 can keep up.
- At boot the firmware logs `lora_airtime()` for each preset, so the hardware's figures can be compared with the tables below.

## LoRa variables

**Radio settings** (both ends must agree unless noted):

| Symbol | Meaning | Range | This design |
|---|---|---|---|
| **SF** | Spreading factor. Each symbol is spread over 2^SF chips and carries SF bits. Higher SF is slower, has longer range and uses more airtime. | 5–12 on SX1262 | 7 (or 8, as a variant) |
| **BW** | Bandwidth of the chirp sweep. Wider is faster and slightly less sensitive. | 7.8–500 kHz | 500 kHz |
| **CR** | Coding-rate **index**. The forward-error-correction ratio is **4/(4+CR)**: CR = 1 → 4/5 … CR = 4 → 4/8. With an explicit header, the receiver reads it from the header. | 1–4 | 1 (3 as a variant) |
| **Npre** | Programmed preamble length, in symbols. The radio adds 4.25 (2 sync-word symbols + 2.25 start-of-frame). | 6–65535 | 8 |
| **Sync word** | Network identifier carried in the preamble. SX126x register 0x0740: 0x1424 is private (reset default), 0x3444 is public/LoRaWAN. | — | private |
| **TX power** | Transmit power at the chip. | −9 to +22 dBm | +14 (+22 as a variant) |

**Packet-shape flags:**

| Symbol | Meaning | This design |
|---|---|---|
| **PL** | Payload length, in bytes | per variant |
| **CRC** | 1 if a 16-bit payload CRC is appended | 1 |
| **IH** | Implicit header. 1 means no header is sent, so length and CR are fixed on both sides. 0 means an explicit header (length, CR, CRC flag). | 0 (Zephyr's driver supports only explicit) |
| **DE** | Low-data-rate optimisation. Required when Tsym > 16 ms. | 0 |

**Derived quantities:**

| Symbol | Formula | SF7 / 500 kHz / CR 1 |
|---|---|---|
| **Rs** symbol rate | BW / 2^SF | 3906 symbols/s |
| **Tsym** symbol time | 2^SF / BW | 0.256 ms |
| **Rb** raw bit rate | SF × Rs × 4/(4+CR) | 21.88 kbit/s |
| **Tpre** preamble time | (Npre + 4.25) × Tsym | 3.14 ms |
| **Npl** payload symbols | 8 + max(ceil((8·PL − 4·SF + 28 + 16·CRC − 20·IH) / (4·(SF − 2·DE))) × (CR + 4), 0) | — |
| **Tpacket** airtime | Tpre + Npl × Tsym | — |

The leading "8 +" in Npl is the header block, which is always sent at 4/8.

**Link quality and sensitivity:**

| Symbol | Meaning |
|---|---|
| **RSSI** | Received signal strength per packet, in dBm |
| **SNR** | Signal-to-noise ratio per packet, in dB. LoRa can demodulate below the noise floor, down to SNRlim. |
| **SNRlim** | The lowest SNR that still demodulates: SF7 −7.5, SF8 −10, SF9 −12.5 … SF12 −20 dB |
| **NF** | Receiver noise figure, about 6 dB |
| **S** sensitivity | −174 + 10·log10(BW) + NF + SNRlim. SF7/500 ≈ −118.5 dBm; ExpressLRS publishes **−117** (SF7/500) and **−120** (SF8/500), which are used below. |
| **Link budget** | TX power − S. Each +6 dB doubles free-space range (×10^(Δ/20)). Near the ground the path-loss exponent is about 3, so the real-world factor is ×10^(Δ/30). |
| **LQ** | Link quality, as ExpressLRS defines it: the percentage of expected packets received over the last 100 packets |

**Application variables:**

| Symbol | Meaning | Value |
|---|---|---|
| **f_ODR** | IMU sample rate (measured upper bound) | 54.4 Hz → 18.4 ms per sample |
| **k** | Samples per LoRa packet | per variant |
| **W** batch window | k / f_ODR | k × 18.4 ms |
| **Share** | Tpacket / W, the fraction of time the radio is transmitting | — |
| **Latency** | sample → BLE notify ≈ W + Tpacket (worst case, for the oldest sample in the batch) | — |

## Ideas from ExpressLRS

ExpressLRS is an open-source radio-control link built for long range and low latency. These are its relevant choices (source: `src/src/common.cpp`, `lib/FHSS/FHSS.cpp`, `lib/OTA/OTA.h`, `lib/SX127xDriver`):

| ExpressLRS technique | What it does | For Sophon |
|---|---|---|
| **Rate table.** 900 MHz modes run 25–200 Hz, all at BW 500, SF6–SF9, CR 4/7–4/8, Npre 8–10. | One named struct per mode holds every radio parameter | **Adopt.** `src/lora_presets.c` |
| **Tiny fixed packets.** OTA4 is 8 B and OTA8 is 13 B, with bit-packed channels. | Short airtime gives low latency | **Adopt** as packet format v2 (13 B per sample, lossless) plus a smaller k. Variants V1 and V3. |
| **CR 4/7 on every 900 MHz mode** | More FEC against interference | **Test** as V4 |
| **Implicit header; LoRa CRC off; own CRC14/16 seeded from a binding UID** | Saves header symbols; rejects foreign packets | **Defer as V2.** Both Zephyr SX1262 drivers send explicit headers only (loramac-node hard-codes `fixLen=false` at `sx12xx_common.c:408-411`), so this needs our own driver. Computed gain: **0 ms at k=10**, because our own 2 B CRC replaces the 16-bit LoRa CRC and the saved header bits disappear inside the same rounding block, and **1.3 ms per packet at k=4**. That isn't worth a new driver on its own. |
| **FHSS.** FCC915: 40 channels, 903.5–926.9 MHz, sequence seeded from the UID, a sync channel every N hops, and the receiver locking onto the transmitter's timing. | Frequency diversity: interference on one channel costs one packet, not the link | **Follow-up issue.** It needs our own driver for fast frequency writes and a fixed packet interval. That's where implicit header pays off too. |
| **Telemetry ratio** (a downlink slot every 1/8–1/64 packets), **dynamic power** | Link stats and acks back to the transmitter; TX power adjusted to the link | **Follow-up issue.** Needs a downlink. |
| **Receiver cycles through rates until it locks** | Recovers automatically after a rate change | **Adopt** in walk-test mode, so the gateway can follow the sensor's SF schedule (below) |
| **LQ %, RSSI, SNR in link stats** | A single honest link-health number | **Adopt.** Printed on the gateway console |

## Levers for range and latency

Every knob that moves range or latency, what it buys, what it costs, and where it is handled. Range effects are in **dB of link budget**: +6 dB doubles free-space range, and is about 1.6× near the ground. Latency figures are for the LoRa leg, W + Tpacket, unless noted. Numbers were checked by script.

### Range levers

| Lever | Range effect | Latency effect | Cost | In this issue? |
|---|---|---|---|---|
| **TX power** 14 → 22 dBm | **+8 dB** | none | Sensor TX current ~45 → ~118 mA (radio-share average 17 → 45 mA at V3). Within FCC §15.247's 30 dBm conducted limit. | ✓ variant **V6 / V6b** |
| **SF** 7 → 8 | **+3 dB** (−117 → −120 dBm) | **+44 ms** at k=10 (airtime 56 → 100 ms) | Radio busy 31% → 54%; about 1.8× the TX energy | ✓ variant **V5 / V5b** |
| **RX boosted mode** on the gateway (`rx-boosted` in DT) | **≈ +2–3 dB** (per the Zephyr binding) | none | About +2 mA in RX, on the USB-powered gateway. The sensor never receives, so it pays nothing. | ✓ **adopt**; A/B tested in the walk test (below) |
| **Antenna height** at the fixed end, 1 m → about 3 m | Often the **largest real-world gain**: it clears the Fresnel zone and gets above people and cars | none | None in firmware; a mast or upstairs window | ✓ walk-test step: one comparison at the farthest passing waypoint |
| **Antenna gain**, **gateway end** (receive only) | **+gain dB**; a 9 dBi gateway antenna ≈ V6's +8 dB of TX power | none | Hardware only, and **no FCC gain limit**: the gateway never transmits. Costs the sensor no battery. See § Antenna gain and the FCC limit below. | ✗ hardware option, **best range per dollar** |
| **Antenna gain**, **sensor end** (transmits) | **+gain dB** | none | Capped by EIRP ≤ 36 dBm: **≤ 14 dBi at +22 dBm**, ≤ 22 dBi at +14 dBm. High-gain omnis have narrow vertical beams, which suit a fixed mast but not a carried or tilted sensor. | ✗ hardware option; 2–5 dBi is usually best on a moving sensor |
| **Antenna orientation** (both vertical, same polarization) | Up to ~20 dB lost if crossed | none | None | ✓ walk-test setup rule |
| **BW** 500 → 250/125 kHz | +3 dB per halving | **Can't carry 54 Hz**: SF7/250 is 82% busy; SF7/125 is 164% | Below 500 kHz, a fixed channel isn't allowed under §15.247, so it needs hopping | ✗ follow-up (needs FHSS and a lower sample rate) |
| **Coding rate** 4/5 → 4/7 | ≈ 0 dB of sensitivity; helps only with **bursty interference** | +9 ms at k=4 | Busy 38% → 51% | ✓ variant **V4** |
| **Frequency hopping** (ExpressLRS FCC915: 40 channels) | Not more sensitivity, but **interference diversity**: a jammed channel costs one packet, not the link | none once locked | Own driver, sync channel, timing lock | ✗ follow-up issue |
| **Retransmission / ARQ** | Recovers lost packets at the edge of range | **+1 round trip per retry** | Needs a downlink | ✗ follow-up issue |
| **Shorter packets** | Lower packet error rate at the same bit error rate (fewer bits to hit) | lower | More packets, so more preamble overhead | ✓ indirectly, via k (V3, V3b) |

### Latency levers

Where latency comes from (worst case, oldest sample in a batch):

`(k − 1) × 18.4 ms` waiting in the batch + `Tpacket` on air + `< 1 ms` decode + `≤ 1 BLE connection interval` + iOS delivery

| Lever | Latency effect | Range effect | Cost | In this issue? |
|---|---|---|---|---|
| **Batch size k** | **Largest lever.** k=10 → 4 → 2: 240 → 102 → 56 ms | none | Smaller k means more preamble overhead per sample: busy 31% → 38% → 52% | ✓ variants **V3 / V3b** |
| **Compact samples (v2)** 18 → 13 B | −19 ms at k=10 (75.6 → 56.4 ms airtime) | none | Codec complexity, lossless | ✓ variant **V1** onward |
| **SF** 7 → 6 | k=2: 56 → **48 ms**; k=4: 102 → **90 ms** | **−2.5 dB** (SNRlim −5 dB) | Less range. The SX1262 supports SF6 with an explicit header. | ✗ not a variant: −8 to −12 ms isn't worth −2.5 dB. Could be added to `lora_presets.c` later. |
| **Implicit header** (V2) | −1.3 ms at k=4; 0 ms at k=10 | none | Our own SX1262 driver | ✗ deferred as V2 |
| **Preamble** 8 → 6 symbols | −0.5 ms | Slightly worse detection at low SNR | — | ✗ negligible |
| **BLE connection interval** (gateway → iPhone) | iOS's default is about 30 ms. Asking the gateway for 15 ms saves up to ~15 ms. The LinkParams characteristic shows the result in the app. | none | Gateway radio duty, on USB power | ✓ **adopt**, gateway role only, at runtime. The image is shared, so a Kconfig default would also change the direct role. On connect, the gateway calls `bt_conn_le_param_update()` with min = max = 12 (15 ms), latency 0, timeout 4 s, which Apple's accessory guidelines allow (min = max = 15 ms). Nothing sets connection parameters today; the only existing setting is MCUmgr's 12/24, which applies during transfers only (`prj.conf:252-254`). |
| **Gateway notify pacing** | A burst of k frames drains across ATT buffers within about 1 connection interval | none | Already planned (`-ENOMEM` → retry in 10 ms) | ✓ |
| **Send as soon as k is reached** (event-driven, not a fixed timer) | Avoids up to 1 slot of extra wait | none | Packet times jitter with the IMU clock, which makes hopping harder later | ✓ phase 1; the follow-up may switch to a fixed interval for FHSS |

### Antenna gain and the FCC limit

FCC §15.247(b), 902–928 MHz with digital modulation (this link at 500 kHz): up
to **30 dBm conducted** with an antenna of up to **6 dBi**. Above 6 dBi, conducted
power drops dB for dB, which together caps **EIRP at 36 dBm**. The 900 MHz band
gets no point-to-point relaxation; that applies to 2.4 GHz only.

| Sensor conducted power | Max sensor antenna gain |
|---|---|
| 30 dBm (the rule's reference point) | 6 dBi |
| **+22 dBm (SX1262 maximum; V6, V6b)** | **14 dBi** |
| +14 dBm (V0–V5) | 22 dBi |

- **Cable loss counts in our favour.** 1 dB of coax between the radio and the
  antenna allows 1 dB more gain.
- **Only the sensor is limited.** The link is one-way, and EIRP rules apply to
  transmitters. A receive antenna's gain adds to the link budget exactly as much
  as the same gain at the transmitter. **The gateway is the cheapest place for
  gain**, and usually the easiest to mount high.
- **Antenna substitution (§15.204).** Under the Wio-SX1262's FCC module grant,
  only antennas of the same type and equal or lower gain than those the grant
  lists are covered. Larger ones fall back on the home-built exemption for a
  few units for personal use (§15.23). Check the grant (its FCC ID) before
  fitting a high-gain antenna.
- **The assumption under all of this:** the 30 dBm allowance assumes the
  transmission's 6 dB bandwidth really is ≥ 500 kHz. LoRa at 500 kHz is designed
  for that.

This is a reading of the rule text, not legal advice.

**Takeaways:**
- **For range**, the order is: antenna height and orientation (free) → RX boost (free) → **gain on the gateway antenna** (hardware only, no FCC limit, no battery cost) → TX power (+8 dB, costs battery) → SF8 (+3 dB, costs latency). Hopping and ARQ come in the follow-up.
- **For latency**, the order is: k → compact samples → BLE interval. SF6 and implicit header save less than 15 ms between them, and each costs range or a new driver.

## Variants vs the current design

Every variant uses BW 500 kHz, Npre 8, explicit header, CRC on and a single channel at 915 MHz. **V0 is the current design.** The Format column refers to "Packet formats" below. PL is the motion-only payload: 9 + 18k for v1, 8 + 13k for v2.

| Variant | Format | Change from previous | PL (B) | Tpacket | Share | Latency | S | Link budget | Range vs V0 (free space / ground) | Avg TX current¹ |
|---|---|---|---|---|---|---|---|---|---|---|
| **V0** current | v1 | 18 B frames, k=10, SF7, CR 4/5, 14 dBm | 189 | 75.6 ms | 41% | 259 ms | −117 | 131 dB | 1.00 / 1.00 | 18.5 mA |
| V1 | v2 | compact 13 B samples | 138 | 56.4 ms | 31% | 240 ms | −117 | 131 dB | 1.00 / 1.00 | 13.8 mA |
| V2 | v2 | V1 with an implicit header | 140 | 56.4 ms (0 saved; 26.9 ms at k=4, 1.3 saved) | 31% | 240 ms | −117 | 131 dB | 1.00 / 1.00 | 13.8 mA |
| **V3** | v2 | V1 with k=4 | 60 | 28.2 ms | 38% | 102 ms | −117 | 131 dB | 1.00 / 1.00 | 17.3 mA |
| V3b | v2 | V1 with k=2 | 34 | 19.3 ms | 52% | 56 ms | −117 | 131 dB | 1.00 / 1.00 | 23.6 mA |
| V4 | v2 | V3 with CR 4/7 | 60 | 37.4 ms | 51% | 111 ms | −117 | 131 dB | ≈1 (interference only) | 22.9 mA |
| V5 | v2 | V1 with SF8 (k=10) | 138 | 100.0 ms | 54% | 284 ms | −120 | 134 dB | 1.41 / 1.26 | 24.5 mA |
| V5b | v2 | V1 with SF8, k=5 | 73 | 59.0 ms | 64% | 151 ms | −120 | 134 dB | 1.41 / 1.26 | 28.9 mA |
| V6 | v2 | V3 at 22 dBm | 60 | 28.2 ms | 38% | 102 ms | −117 | 139 dB | 2.51 / 1.85 | 45.3 mA |
| V6b | v2 | V5 at 22 dBm | 138 | 100.0 ms | 54% | 284 ms | −120 | 142 dB | 3.55 / 2.33 | 64.2 mA |

¹ Share × TX current: ~45 mA at +14 dBm and ~118 mA at +22 dBm, from the SX1262 datasheet's typical figures. This is the radio's share only, not the whole board.

**Notes:**
- **Trailer cost** (v2, SF7, checked by script):
  - The 4 B test trailer, sent on every walk-test packet, adds **1.2–2.5 ms**: k=2 19.3 → 20.5 ms; k=4 28.2 → 29.5 ms; k=10 56.4 → 58.9 ms.
  - The 7 B status trailer, about once per second, adds up to 2.5 ms to that one packet.
  - The test trailer applies to every v2 variant alike, so the comparison stays fair.
- The arithmetic was checked by script. It gets re-checked on hardware against the `lora_airtime()` log line.
- The sensor's 200 mAh pack makes the current column matter. At V0 it lasts roughly 10 h on the radio alone; at V6b roughly 3 h.

**What the table already shows, before any walk test:**
- **V0 is beaten on every column by V1** (less airtime at the same latency) **and by V3** (2.5× lower latency, slightly less current, the same range). v2 is lossless, so the current design has no advantage to keep.
- **Range comes cheaper from TX power than from SF.** V6 gains 8 dB and keeps latency at 102 ms. V5 gains 3 dB and pushes latency to 284 ms. SF8 is only worth having on top of 22 dBm (V6b), when the most range is needed.
- **V4 (CR 4/7)** costs 9 ms per packet and doesn't change sensitivity. It only proves itself if the walk test shows losses at good SNR.

**How to choose** (applied to the walk-test results):
1. Decide the **required distance D**: the farthest waypoint the deployment must work at.
2. Keep the variants with **LQ ≥ 99% at D** on both the line-of-sight and the obstructed route.
3. Of those, take the one with the **lowest latency**. Break ties on **average current**.
4. **Expected outcome:**
   - If D is within V3's range, choose V3.
   - If it's just beyond, choose V6.
   - If it's beyond V6, choose V6b.
   - V3b only if 56 ms latency matters more than battery life.

## Packet formats (specified in new `LORA-PROTOCOL.md`)

Every packet is one LoRa frame: explicit header, LoRa CRC on, little-endian, no padding. **PL** means the LoRa payload length the receiver reports.

### Type byte (offset 0, every format)

| Bits | Field | Values |
|---|---|---|
| 7–4 | `marker` | `0x5`: a Sophon LoRa packet. Anything else is dropped and counted as `rx bad`. |
| 3–2 | `format` | `01` = v1, `10` = v2. `00` and `11` are reserved and dropped. |
| 1 | `TEST` | v2 only: the walk-test trailer is present |
| 0 | `STATUS` | v2 only: the status trailer is present |

So v1 = `0x54`, and v2 = `0x58` (motion only), `0x59` (+ status), `0x5A` (+ test) or `0x5B` (+ status + test).

### v1: the baseline (variant V0)

| Offset | Size | Field | Type | Units / meaning |
|---|---|---|---|---|
| 0 | 1 | `type` | u8 | `0x54` |
| 1 | 2 | `sensor_id` | u16 | Low 16 bits of the sensor's FICR ID (`src/ident.c`) |
| 3 | 1 | `flags` | u8 | bit 0 = USB powered; bits 1–7 are 0 |
| 4 | 2 | `batt_mv` | u16 | Sensor battery in mV; 0 = no reading |
| 6 | 2 | `batt_age_s` | u16 | Seconds since that reading |
| 8 | 1 | `count` | u8 | 1–10 |
| 9 | 18 × count | frames | `struct sophon_frame` | Byte-for-byte as in `src/frame.h` / PROTOCOL.md |

- **Length rule:** PL = 9 + 18·count.

### v2: compact (V1–V6b)

**Header, 8 B:**

| Offset | Size | Field | Type | Units / meaning |
|---|---|---|---|---|
| 0 | 1 | `type` | u8 | `0x58`–`0x5B` |
| 1 | 2 | `seq0` | u16 | `seq` of the first sample; wraps mod 2^16 like PROTOCOL.md's `seq` |
| 3 | 4 | `t0_ms` | u32 | `t_ms` of the first sample (sensor uptime, ms) |
| 7 | 1 | `count` | u8 | Number of sample records, 1–k (k ≤ 15) |

**Sample records**, at offset 8, `count` × 13 B. Record i is at 8 + 13·i:

| Offset in record | Size | Field | Type | Units |
|---|---|---|---|---|
| 0 | 1 | `dt_ms` | u8 | Milliseconds since the previous sample in this packet. Always 0 for record 0. |
| 1 | 2 | `ax` | i16 | milli-g |
| 3 | 2 | `ay` | i16 | milli-g |
| 5 | 2 | `az` | i16 | milli-g |
| 7 | 2 | `gx` | i16 | centi-deg/s |
| 9 | 2 | `gy` | i16 | centi-deg/s |
| 11 | 2 | `gz` | i16 | centi-deg/s |

**Status trailer** (if `STATUS` is set), 7 B, right after the last record:

| Offset in trailer | Size | Field | Type | Meaning |
|---|---|---|---|---|
| 0 | 2 | `sensor_id` | u16 | as in v1 |
| 2 | 1 | `flags` | u8 | bit 0 = USB powered |
| 3 | 2 | `batt_mv` | u16 | mV; 0 = no reading |
| 5 | 2 | `batt_age_s` | u16 | seconds |

**Test trailer** (if `TEST` is set), 4 B, after the status trailer if there is one:

| Offset in trailer | Size | Field | Type | Meaning |
|---|---|---|---|---|
| 0 | 1 | `variant` | u8 | Preset id (V0 = 0 … V6b = 8, the index into `lora_presets.c`) |
| 1 | 2 | `vcount` | u16 | This variant's own packet counter (mod 2^16). The gateway computes LQ for each variant from gaps in it. |
| 3 | 1 | `sf_switch_s` | u8 | Seconds until the next SF7 ↔ SF8 block switch |

**Length rule:**
- PL must equal 8 + 13·count + 7·STATUS + 4·TEST.
- If it doesn't, if `count` is 0, or if `count` is greater than k_max, the packet is dropped and counted as `rx bad`.

| k | Motion only | + status | + test | + both |
|---|---|---|---|---|
| 2 | 34 | 41 | 38 | 45 |
| 4 | 60 | 67 | 64 | 71 |
| 5 | 73 | 80 | 77 | 84 |
| 10 | 138 | 145 | 142 | 149 |

**Sensor packing rules.** The current packet is closed and sent when any of these happens:
1. `count` reaches the preset's k;
2. the next sample's `seq` ≠ `seq0 + count`, which means a frame was dropped (queue overflow), so `seq` stays honest;
3. the next sample's `t_ms` − the previous sample's `t_ms` is more than 255, so `dt_ms` can't overflow;
4. the flush timer fires: W + 20 ms after the first sample, which bounds latency if the IMU stalls.

The `STATUS` trailer goes on the first packet sent at least 1 s after the previous status packet, and also on the first packet after boot. `TEST` is set on every packet when `SOPHON_LORA_WALKTEST=y`.

**Gateway reconstruction**, exact:

```
t = t0_ms
for i in 0 .. count-1:
    t   = t + dt_ms[i]            # u32 arithmetic; dt_ms[0] = 0
    seq = (seq0 + i) mod 65536
    emit sophon_frame{ seq, t, ax[i], ay[i], az[i], gx[i], gy[i], gz[i] }   # 18 B, PROTOCOL.md layout
```

**Why v2 is lossless:**
- `seq` is consecutive within a packet (packing rule 2), so `seq0 + i` is exact.
- `t_ms` is an integer millisecond count from `k_uptime_get_32()`, and every step is ≤ 255 ms (rule 3), so the cumulative `dt` is exact, including across the u32 wrap.
- The six axes are copied without being re-encoded. The app gets exactly the same 18-byte frames as from a direct board.

**Worked example** (the script was run in this planning session): k=4, `seq0` = 0x1234, `t0_ms` = 100000, motion only, PL = 60.

```
header   58 | 34 12 | a0 86 01 00 | 04                       type 0x58, seq0 0x1234, t0 100000, count 4
rec 0    00 | 0c 00 | fb ff | ea 03 | 96 00 | e2 ff | 00 00  dt 0, ax 12, ay -5, az 1002, gx 150, gy -30, gz 0
rec 1-3  12 ... | 13 ... | 12 ...                            dt 18, 19, 18
```

Reconstructed frames: (0x1234, 100000), (0x1235, 100018), (0x1236, 100037), (0x1237, 100055).

**Versioning:**
- A future format takes `format` = `11`.
- Within v2, new trailers may only be added behind a new flag bit. There are no spare type bits left, so a v3 is the route for anything beyond that.
- A receiver drops any type it doesn't know, so old gateways never misread new packets.

**`LORA-PROTOCOL.md` (new)** holds:
- the variables;
- the presets and the variant table;
- the packet-format spec above, word for word;
- the `seq` rule on the sensor (it advances on every sample);
- how the gateway maps onto the unchanged BLE protocol (frames pass through; `no_conn`/`no_mem` count the gateway's own refusals; Battery is the sensor's reading with its age; LinkParams describes the gateway↔phone link);
- role detection;
- the walk-test results and the chosen preset.

`PROTOCOL.md` is not edited.

## Firmware: one image, role chosen at boot

**Why one image works:**
- Both roles use the same pins.
- The gateway runs the image built for `xiao_ble/nrf52840/sense`; on the plain board the IMU just fails to start, which `sophon_imu_init()` already handles.
- **Check first:** confirm from the plain XIAO nRF52840's KiCad source that P1.08, P0.07/P0.27, P0.11 and P1.10 are unconnected or harmless. If any isn't, use two board targets built from the same source.

### Driver selection: Semtech's loramac-node, not Zephyr's native driver

The Zephyr tree has three LoRa backends. For an SX1262 two are usable, and the
original plan assumed the first without knowing the second existed:

| | **loramac-node (chosen)** | Native Zephyr driver |
|---|---|---|
| Origin | Semtech's LoRaMac-node radio layer, a Zephyr module | in-tree `drivers/lora/native/sx126x`, written for Zephyr |
| Maturity | Semtech's reference stack and the long-standing default | Its own Kconfig labels it **experimental** (`CONFIG_LORA_SX126X_NATIVE`) |
| BUSY wait | **No timeout**: `SX126xWaitOnBusy()` spins until BUSY falls | 1 s timeout (`SX126X_BUSY_DEFAULT_TIMEOUT`) |
| Board with no Wio fitted | Can hang the boot inside driver init if the floating BUSY pin reads high | Init fails cleanly, but only if BUSY reads high: it would need a pull-up on BUSY, since it never checks the chip is really there |
| RX boost | Set once from devicetree (`rx-boosted`) at init | Re-applied from devicetree on **every** `lora_config()` |
| Header modes | Explicit only (`fixLen=false` hard-coded) | Explicit only |
| Selected with | `CONFIG_LORA_MODULE_BACKEND_LORAMAC_NODE=y` (named explicitly in `prj.conf`) | `CONFIG_LORA_MODULE_BACKEND_NATIVE=y` |

**Why loramac-node:**
- **The walk test compares variants.** A driver bug would show up as a
  difference between presets and could be mistaken for one. The mature driver
  keeps the comparison about the radio settings.
- **The native driver fights the RX-boost A/B.** The walk test switches RX boost
  on alternate SF pairs by writing the RX-gain register. The native driver
  rewrites that register from devicetree on every `lora_config()`, which the
  sensor and gateway call each time they change preset, so it would silently
  undo the switch.
- **Its one hazard is cheap to guard.** The unbounded BUSY wait is handled by
  `zephyr,deferred-init` plus a raw-SPI presence check in `src/role.c`, about 40
  lines (§ Radio presence check below). A board with no radio never runs the
  driver.

**Revisit if:** the native driver loses its experimental label, or #304's own
driver (for implicit header and frequency hopping) replaces both.

**Choosing the role** (`src/role.c/.h`):

| Radio present | IMU started | Role |
|---|---|---|
| yes | yes | **sensor** |
| yes | no | **gateway** |
| no | either | **direct** (today, unchanged) |

- The role is logged at boot.
- A sensor whose IMU fails to start comes up as a gateway; this is documented.
- **Radio presence check:** the `lora0` node has `zephyr,deferred-init`, because the driver's `SX126xWaitOnBusy()` has no timeout. The check:
  1. Pull BUSY down.
  2. Pulse RESET.
  3. Wait at most 20 ms for BUSY to go low.
  4. Do a raw SPI read of 0x0740–0x0741 (opcode 0x1D) and expect `0x14 0x24`.
  5. If it matches, call `device_init()`.

**Build changes:**
- `app.overlay`: disable `i2c1`; add `lora0` (`semtech,sx1262` on `spi2`, 8 MHz, pins as above, `dio2-tx-enable`, 1.8 V TCXO, `zephyr,deferred-init`, `rx-boosted`).
  - `rx-boosted` only affects receiving, so in practice only the gateway pays for it. For the walk-test A/B, `lora_link.c` writes the SX1262 RX-gain register (0x08AC: 0x96 boosted, 0x94 power-saving) directly at runtime. The driver writes the DT value only at init. Check that register against the SX1262 datasheet during implementation.
- `prj.conf`: `SPI`, `LORA`.
- App `Kconfig`: `SOPHON_LORA_PRESET` (default decided by the walk test; V3 until then), `SOPHON_LORA_WALKTEST` (bool, default n), `SOPHON_LORA_FREQ_HZ`, `SOPHON_LORA_PEER_ID`.
- Scripts and build folders are unchanged.

**`src/lora_presets.c/.h` (new):** a const table, in the style of ExpressLRS's rate table, of `{id, name, sf, bw, cr, k, format, tx_dbm}` for V0–V6b. Normal mode uses one preset. Walk-test mode uses a schedule over the presets.

**`src/lora_link.c/.h` (new):**
- `lora_config()` per preset, and the `lora_airtime()` log line.
- Counters: tx ok/err; rx ok, bad, wrong peer; LQ; last RSSI and SNR.

**`src/lora_codec.c/.h` (new):** v1/v2 pack and unpack exactly as specified, with the length rule. Plain C99 with no Zephyr headers, so it can be tested on the Mac.
- **Host test:** `tests/lora_codec/test_codec.c`, built by `scripts/test-codec.sh` with the Mac's `cc`. (Zephyr's `native_sim` needs a Linux host.)
- **Coverage:** the worked example, the seq wrap, the t_ms u32 wrap, each early-close rule, and length-rule rejects.

**Sensor path (`src/main.c`):**
- `build_frame()` (`main.c:110`) skips the subscribed check when the role is sensor.
- A LoRa thread batches from `tx_queue` using the v2 packing rules and calls the blocking `lora_send()`. This keeps sending off the IMU thread (`main.c:64-84`).
- If the queue overflows, the frame is counted and dropped, so the `seq` gap is honest.

**Gateway path:**
- The `lora_recv_async()` callback validates, decodes v1 or v2, and pushes frames into a 32-deep `tx_queue`. The status fields are stored.
- A dropped frame is counted as `no_conn` when no central is subscribed and as `no_mem` when the queue is full.
- `tx_work_handler` changes to peek → notify. On `-ENOMEM` it keeps the frame and retries in 10 ms.

**`src/ble.c`:**
- **Sensor:** advertises the name and SMP only.
- **Gateway and direct:** advertising, scan response and GATT exactly as today.
- **Gateway connection interval:** on connect, request 15 ms (`bt_conn_le_param_update`, 12/12, latency 0, timeout 400). The existing `le_param_updated` callback (`ble.c:344`) logs what iOS actually grants, and LinkParams reports it.
- **Gateway battery:** the relayed reading, with `age_s = batt_age_s + time since the packet arrived`.
- **Image confirm:** the gateway and direct roles confirm on the first BLE frame (`maybe_confirm_image()`, `ble.c:426`). The sensor confirms on its first successful `lora_send()`.

## Walk-test mode (`SOPHON_LORA_WALKTEST=y`, both boards)

**Interleaving within an SF.** With an explicit header, the gateway decodes any PL, CR or format without being reconfigured. So the sensor rotates **packet by packet** through the SF7 variants **V0 → V1 → V3 → V3b → V4 → V6**. It reconfigures `lora_config()` (CR, TX power) before each send. Every variant then sees the same place, moment and interference.
- One cycle uses 34 samples (625 ms) and 245 ms of airtime, so the radio is busy 39%.
- Over a 4-minute stop (2 minutes of SF7 time), each SF7 variant gets about **190 packets**, about 95 with boost on and 95 with it off. The SF8 cycle (V5 + V5b + V6b = 25 samples, 0.46 s) gives each SF8 variant about **260**. That's enough to resolve LQ to about 1% per boost state.
- V0 (v1) has no test trailer. Its LQ comes from gaps in `seq0`/`seq` among the V0 packets, which works because each cycle has exactly one V0 packet carrying 10 samples.

**Alternating between SFs.** The gateway can only demodulate one SF at a time, so the sensor alternates **30 s SF7 blocks** with **30 s SF8 blocks** (V5 → V5b → V6b interleaved). Every packet carries the seconds left before the next switch (`sf_switch_s`), and both ends switch on that count. If the gateway hears nothing for 1 s, it listens on SF7 and SF8 alternately for 1 s each until it locks again, as an ExpressLRS receiver searches its rates.

**Gateway output.** One record per variant every 10 s, in two places:
- **To the iOS app** over the gateway's **LoRa Link** characteristic (#309). The app logs each record with the phone's GPS position and distance from the base, and exports a CSV. **This is the walk test's primary record.**
- **To the USB console** as a CSV line, the same fields, kept as a bench-side fallback:

```
uptime_s, sf_block, boost, variant, expected, received, LQ%, rssi_avg, rssi_min, snr_avg, snr_min, crc_err
```

Expected packets come from `vcount` gaps. The app keeps receiving motion during the test, so the samples stay real.

**Host script:** `scripts/walktest-report.py` reads the app's CSV (#309). It outputs per distance band and variant: LQ, margin (SNR − SNRlim), RSSI, and pass/fail at LQ ≥ 99%. There is no `walktest-log.sh` and no waypoint timing: GPS distance replaces both.

## Walk-test procedure

**The sensor stays at base, and the walker carries the gateway and the phone.**
BLE ties the phone to the gateway, so this is the only way the walker sees the
link live. A radio link loses the same in both directions, and both ends are the
same Wio-SX1262 hardware, so the measurement is equivalent to carrying the
sensor. **Depends on #309**, which puts the gateway's link stats in the app and
records them with GPS.

1. **Setup:**
   - **Base (sensor, 86F0):** fixed in place, about 1 m high, antenna vertical, by a window or outdoors. Powered from USB or its LiPo, and left still, so the motion stream is a quiet baseline.
   - **Carried (gateway, 01A7):** on a LiPo on its battery pads, held about 1 m high with the antenna vertical, and still at each stop. The gateway only receives, so its draw is the radio in RX plus BLE.
   - **Phone:** connected to the gateway, with the app's walk-test recording started and a **pin dropped at the base**. Distances are measured from that pin.
2. **Routes:**
   - **(a) Line of sight:** stops at 25, 50, 100, 200, 400 and 800 m from the base, then doubling until every variant falls below 50% LQ.
   - **(b) Obstructed:** through or around buildings, a stop every block.
3. **At each stop:** stay **4 minutes** (four SF7 + SF8 pairs). The gateway switches **RX boost on for pairs 1 and 3 and off for pairs 2 and 4** and reports it in each record's `boost` field, so every stop gets an A/B of boost. The app's live margin readout shows when the link is near its edge, which is where the stops matter most.
   - **Antenna height check:** at the farthest stop where V3 still passes, do one extra 4-minute stop with the **base** antenna raised to about 3 m (upstairs window or mast).
   - **Orientation rule:** both antennas vertical at all times.
4. **Walk each route out and back** to check repeatability. Record the weather and any visible interference sources.
5. **Results:** export the app's CSV and run `walktest-report.py` on it. Paste the table into `LORA-PROTOCOL.md` § Walk-test results, apply the "How to choose" rule above, and set the default `SOPHON_LORA_PRESET`.
6. **Sensor-side cost:** the sensor's relayed battery is in the same records. Its drop over the test (mV over time) is a rough check of the current column.

## Bench latency test

Computed latency (W + Tpacket) only bounds the worst case, so it is also measured:
1. Wire a jumper from **D0 on the sensor to D0 on the gateway**, with a common ground.
2. The sensor raises D0 when it samples a frame with `seq % 64 == 0`.
3. The gateway timestamps that edge, then the moment it notifies that `seq` over BLE, and logs the difference.
4. Run each variant for 2 minutes and report min, median and max against the table.

## Gateway board migration (kit XIAO: Meshtastic/UF2 → MCUboot)

**By probe.** The Raspberry Pi Debug Probe goes on the kit's bare XIAO nRF52840, following BOOTLOADER.md § Migrating a board → By probe. Do all of this **with the XIAO unplugged from the Wio-SX1262**: the SWD pads are on the back, which faces the Wio when the boards are stacked.

1. **Copy the UF2 app off the bootloader drive first.** Double-tap reset; note the volume name (Sense boards mount `XIAO-SENSE`). Copy `CURRENT.UF2` and `INFO_UF2.TXT` to `~/.sophon/backups/` using the BOOTLOADER.md naming. Check the copy is non-empty and record its size and hash.
2. **Find the SWD pads on this board.** BOOTLOADER.md's test-point table (TP1 GND, TP3 SWDCLK, TP5 SWDIO) was taken from the **Sense Plus** KiCad netlist. Get the plain XIAO nRF52840's pad positions the same way, from its own KiCad source with `scripts/kicad-netlist.py`, before touching the board. This can be done together with the plain-board pin check in "Firmware". Wire SWCLK, GND and SWDIO; no reset line is needed (BOOTLOADER.md § TP2 is not needed).
3. **Check debug access is open.** Read `UICR APPROTECT` and `CTRL-AP APPROTECTSTATUS`, as for 86F0 (BOOTLOADER.md § APPROTECT).
   - **If they're open:** continue to step 4.
   - **If they're locked:** don't recover yet, because `nrf52_recover` mass-erases. Take the backup over USB with `sophon-dumper` instead (#297). The dumper overwrites only the application, and step 1's `CURRENT.UF2` already holds that, so the two together are a complete backup. Then continue at step 5.
4. **SWD backup:** `dump_image` of the 1 MB of flash and the 4 KB of UICR, with no halt (BOOTLOADER.md § Backup and recovery). **Verify with `cmp` against a second dump** (§ Verify with `cmp`). Store it in `~/.sophon/backups/` under the board's name.
5. **Prove the untested guard while it can be proved.** Run `SOPHON_BOOT=mcuboot scripts/build.sh`, then `scripts/flash-swd.sh` **without `--force`**. It must read SoftDevice magic `0x51b1e5db` at `0x3004` and **refuse**. This is the first UF2 board to meet that guard: BOOTLOADER.md § Guards lists "refuses a board with a SoftDevice" as **not verified**. Record the result there.
6. **Flash:** `scripts/flash-swd.sh --force`. It erases 0–0xFC000, writes MCUboot and the shared image in one session, then reads both back and compares them.
7. **Confirm** it boots, advertises and accepts a connection from the app. With no Wio fitted yet, it should come up as **direct** with zero axes (no IMU). Then plug it into the Wio and power-cycle: it should log **gateway**.
8. **Update BOOTLOADER.md:**
   - add the new board (its `Sophon-XXXX` name) to the board table;
   - list its backups: `CURRENT.UF2`, plus the SWD dump or the dumper pair;
   - mark the SoftDevice guard as verified;
   - fix the stale 4D88 row (`7ea949f`).

**Recovery:** restore the backup over SWD (BOOTLOADER.md § Restoring). If the dumper path was used, copy `CURRENT.UF2` back onto the bootloader drive afterwards to bring back Meshtastic.

## Docs

- **`LORA-PLAN.md` (new):** this plan, the original design record (Workflow step 5). It isn't edited after the fact; outcomes go in `LORA-PROTOCOL.md`.
- **`LORA-UPDATED-PLAN.md` (new):** the current design record. It starts as a copy of `LORA-PLAN.md` and records each change in § Changes from the original plan.
- **`LORA-PROTOCOL.md` (new):** as above.
- **README.md:** the roles and walk-test mode.
- **HARDWARE.md:** the Wio-SX1262 pin map, the antenna warning, the D0 latency jumper, and the plain-board pin check.
- **BOOTLOADER.md:** the gateway board, its backups, the 4D88 fix, the plain XIAO's SWD pad positions, and the SoftDevice guard marked verified.
- **Root `ChangeLog.md`:** a `feat:` entry.

## Verification

1. **Build:** single MCUboot build, both with `SOPHON_LORA_WALKTEST=n` and `=y`. Record flash use against 476K.
2. **Codec test:** `scripts/test-codec.sh`. Pack → unpack round-trips must be byte-identical, covering the worked example, the seq and t_ms wraps, the early-close rules, and length-rule rejects.
3. **Role detection:**
   - Sense board without a Wio → direct, boots with no hang.
   - Sense board with a Wio → sensor.
   - Kit XIAO with a Wio → gateway.
4. **No regression:** the direct role behaves as 2.8.0 does in the app.
5. **Radio bring-up:** each preset's `lora_airtime()` matches the variant table to within a symbol. 0 bad packets at the desk.
6. **Lossless v2 on hardware:** at the desk, run V0 and V1 back to back. The gateway's rebuilt frames must have continuous `seq` and the same `t_ms` cadence as v1.
7. **End to end on the iPhone, normal mode:**
   - The app connects to the gateway and the sensor doesn't appear.
   - About 54 frames per second, motion follows the sensor, uptime equals the sensor's `t_ms`.
   - Gaps ≈ 0 and "TX buffer full" ≈ 0 over 10 minutes.
   - The battery reading is the sensor's.
8. **Fault cases:**
   - Power off the sensor: "Stalled" after 5 s.
   - Power it back on: "Restarts without disconnect" increments.
   - Unsubscribe and subscribe again: no false gaps.
9. **Bench latency test**, then, once #309 has landed, the **walk test (routes a and b)**, with the gateway and phone carried and the sensor at base. Record the chosen preset and the reason in LORA-PROTOCOL.md.
10. **OTA both nodes** with `flash-ota.sh`, back to `WALKTEST=n` with the chosen preset. Each image confirms by its role's rule and survives a reset.
11. **Review:** post the implementation summary on the issue, set Status to In review, and pause for commit consent.
