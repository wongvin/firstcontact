# Sophon LoRa link protocol

The contract between the two LoRa roles of the Sophon firmware, **sensor** and
**gateway** (#303). Both roles run the same image, so changing this document
means changing one codebase; it still has two ends, and both must follow it.

The *reasoning* behind these choices — the throughput and airtime arithmetic,
the ExpressLRS comparison, the levers for range and latency, the walk-test
method — lives in [LORA-UPDATED-PLAN.md](LORA-UPDATED-PLAN.md), the current
design record. Its frozen pre-implementation counterpart, [LORA-PLAN.md](LORA-PLAN.md),
sits beside it, and where they disagree the updated one is right. This file is
the live contract and is kept current. The BLE side, which the gateway serves to the iOS
app unchanged, stays in [PROTOCOL.md](PROTOCOL.md).

> **Status: specified, not yet implemented.** Written ahead of #303's code.
> Sections marked *pending* are filled in as #303 lands and after the walk test.

## Topology

```
[Sense Plus + Wio-SX1262]  --LoRa 915 MHz-->  [XIAO nRF52840 + Wio-SX1262]  --BLE, PROTOCOL.md-->  iOS app
        sensor                                          gateway
```

The link is **one-way**, sensor → gateway. There is no downlink, no
acknowledgement and no retransmission; a lost packet is a visible gap in `seq`
(see below). A downlink and frequency hopping are #304.

## Roles

One image; the role is chosen at boot from what is attached.

| Radio present | IMU started | Role |
|---|---|---|
| yes | yes | **sensor** |
| yes | no | **gateway** |
| no | either | **direct**: today's BLE peripheral, unchanged |

- **Radio presence** is checked before the SX126x driver initialises, because the
  driver's BUSY wait has no timeout. The `lora0` node carries
  `zephyr,deferred-init`; the check pulls BUSY down, pulses RESET, waits at most
  20 ms for BUSY to fall, then reads registers `0x0740`–`0x0741` over raw SPI
  (opcode `0x1D`). `0x14 0x24`, the private sync word the chip resets to, means a
  radio is present, and only then is the driver initialised.
- **Known edge case:** a sensor whose IMU fails to start comes up as a gateway.
- The role is logged at boot.

## Radio parameters

Common to every preset:

| Parameter | Value |
|---|---|
| Frequency | 915.0 MHz, single channel (`SOPHON_LORA_FREQ_HZ`) |
| Bandwidth | 500 kHz. A fixed channel needs ≥ 500 kHz under FCC §15.247 without hopping. |
| Preamble | 8 symbols |
| Header | explicit. Zephyr's driver supports nothing else; it also lets the gateway decode any length and coding rate without reconfiguring. |
| CRC | on (16-bit LoRa payload CRC) |
| Sync word | private (`0x1424`) |
| IQ | normal |

Per preset: spreading factor, coding rate, samples per packet (k), packet format,
and TX power.

### Presets

Ids are the index into `src/lora_presets.c` and the value of `variant` in the
test trailer. V2 (implicit header) has no id: it needs a driver this link
doesn't have, and is deferred to #304, where it takes the next free id.

| id | Preset | Format | SF | CR | k | TX power |
|---|---|---|---|---|---|---|
| 0 | V0 | v1 | 7 | 4/5 | 10 | +14 dBm |
| 1 | V1 | v2 | 7 | 4/5 | 10 | +14 dBm |
| 2 | V3 | v2 | 7 | 4/5 | 4 | +14 dBm |
| 3 | V3b | v2 | 7 | 4/5 | 2 | +14 dBm |
| 4 | V4 | v2 | 7 | 4/7 | 4 | +14 dBm |
| 5 | V5 | v2 | 8 | 4/5 | 10 | +14 dBm |
| 6 | V5b | v2 | 8 | 4/5 | 5 | +14 dBm |
| 7 | V6 | v2 | 7 | 4/5 | 4 | +22 dBm |
| 8 | V6b | v2 | 8 | 4/5 | 10 | +22 dBm |

**Default:** V3, provisionally, until the walk test picks one (*pending*; see
§ Chosen preset). Set by `SOPHON_LORA_PRESET`. Both ends are built from the same
image, so they always agree on it.

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

## Variants

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

## Packet formats

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

**Worked example** (bytes generated and checked by script): k=4, `seq0` = 0x1234, `t0_ms` = 100000, motion only, PL = 60.

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

## What `seq` means on the LoRa link

On a **direct** board, `seq` advances only while a central is subscribed
(PROTOCOL.md § What `seq` means). On a **sensor** it advances on **every sample**:
the gateway is assumed to be listening at all times, and the sensor has no way
to know otherwise.

A gap the app sees behind a gateway is therefore one of:

| Cause | Attributed by |
|---|---|
| A LoRa packet was lost (k samples at once) | the app's "Lost on air"; the gateway's LQ and `rx bad` counters |
| The sensor's queue overflowed | packing rule 2 closes the packet, so the gap is honest; counted on the sensor's console |
| The gateway refused the frame (queue full) | `no_mem` in TX Stats, which the app subtracts |
| Nobody was subscribed to the gateway | `no_conn` in TX Stats; frames are dropped until a central subscribes |

After a subscribe, the first frame's `seq` is whatever the sensor has reached;
the jump from the previous session is not a loss.

## How the gateway maps onto the BLE protocol

The app connects to the gateway exactly as to a direct board (PROTOCOL.md). What
each item carries behind a gateway:

| PROTOCOL.md item | Behind a gateway |
|---|---|
| Motion Data | The sensor's frames, rebuilt byte for byte (v1 passes them through; v2 reconstructs them exactly). One 18-byte frame per notification, as today. `seq` and `t_ms` are the **sensor's**. |
| TX Stats | The gateway's own BLE delivery: `sent`, `no_conn` (no subscriber), `no_mem` (gateway queue full), `other`. LoRa loss is not counted here, which is why it shows as "Lost on air". |
| Link Params | The gateway ↔ phone BLE link. The gateway requests a 15 ms interval (min = max = 12, latency 0, timeout 4 s) on connect; Link Params shows what iOS granted. |
| Battery | The **sensor's** battery from the latest status trailer (or v1 header): `mv` and the USB flag as sent, `age_s` = `batt_age_s` + seconds since that packet arrived. |
| Advertising, name, manufacturer data | The **gateway's** own: its FICR-derived `Sophon-XXXX` and `device_type` `0x0001`, exactly as a direct board. |

Delivery pacing: a packet's k frames arrive at once; the gateway queues them (32
deep) and notifies one at a time, retrying after 10 ms when the ATT buffers are
full rather than dropping.

## Sensor BLE presence

The sensor advertises only its `Sophon-XXXX` name and the MCUmgr SMP service —
no Sophon service UUID. The iOS app filters scans on that UUID and never sees the
sensor; `flash-ota.sh` matches by name and still updates it over the air.

**Image confirmation:** the gateway (like a direct board) confirms a new image on
its first BLE frame delivered. The sensor confirms on its first successful LoRa
send. With no acknowledgement on the link, that proves only the sensor's IMU →
radio path.

## Walk-test mode

`SOPHON_LORA_WALKTEST=y`, both ends. The sensor sets `TEST` on every v2 packet.

- **Within SF7**, the sensor rotates packet by packet through V0 → V1 → V3 → V3b
  → V4 → V6, reconfiguring coding rate and TX power before each send. With an
  explicit header the gateway decodes all of them without reconfiguring, so
  every variant is measured at the same place and moment.
- **Between SF7 and SF8**, the sensor alternates 30 s blocks (SF8 rotates V5 →
  V5b → V6b). `sf_switch_s` counts down to the switch and both ends switch on it.
  A gateway that hears nothing for 1 s searches, listening on SF7 and SF8 for 1 s
  each, until it locks again.
- **RX boost** on the gateway is on for SF pairs 1 and 3 of each 4-minute stop and
  off for pairs 2 and 4.
- V0 (v1) carries no test trailer; its LQ comes from `seq` gaps among V0 packets.
- **Gateway output**, one record per variant every 10 s: to the iOS app over the gateway's LoRa Link characteristic (#309), which records it with GPS, and as a CSV line on the USB console as a fallback:

```
uptime_s, sf_block, boost, variant, expected, received, LQ%, rssi_avg, rssi_min, snr_avg, snr_min, crc_err
```

Procedure: LORA-UPDATED-PLAN.md § Walk-test procedure. The sensor stays at base, and the walker carries the gateway and phone.

## Walk-test results

*Pending.* One table per route (line of sight, obstructed): per waypoint and
variant, LQ, RSSI and SNR, boost on and off, and which variants pass LQ ≥ 99%.
Plus the antenna-height check and the bench latency measurements (min, median,
max per variant).

## Chosen preset

*Pending.* Chosen by the rule in § Variants (How to choose), with the required
distance and the reason recorded here. V3 until then.
