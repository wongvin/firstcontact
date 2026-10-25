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

One image. By default (**Auto**) the role is chosen at boot from what is
attached:

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

### Setting the role from the app (#329)

The app can store a role override on a board (PROTOCOL.md § Config frame); it
applies at the next restart. **Auto**, the default, is the table above, run at
every boot. An override holds only if the hardware supports it:

| Hardware | Roles it accepts |
|---|---|
| Wio + IMU (Sense Plus on a Wio carrier) | auto (sensor), direct, sensor, gateway, transporter |
| Wio, no IMU (base XIAO on a Wio carrier) | auto (gateway), direct, gateway, transporter |
| no Wio | auto (direct), direct |

**Transporter** (#359) is the bit-error test's sender (§ Bit-error test). Auto
never picks it, and it needs an MCUboot build that can read its own image
(Config status bit 6). Like a forced gateway, it leaves an IMU unarmed.

- **A sensor needs an IMU.** A board without one is refused the sensor role,
  rather than sending motion it doesn't have.
- **A Sense Plus forced to gateway leaves its IMU unarmed.** Its Motion stream is
  the sensor's, relayed. Local samples would interleave a second `seq` space
  into it.
- **Forced direct** never starts the radio, even with a Wio fitted.
- **If the hardware changes** after a role was stored (a Wio removed, an IMU
  that no longer starts), the board runs as Auto and says so in the Config
  read's status.

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

**Default:** V6, V3 at +22 dBm (#321), until the walk test picks one (*pending*;
see § Chosen preset). Set by `SOPHON_LORA_PRESET`. Both ends are built from the same
image, so by default they agree on it.

**Set from the app (#329):** the preset, frequency, TX power and peer can each be
overridden per board through the Config characteristic (PROTOCOL.md § Config
frame), applied at the next restart. **Both ends must then agree** on the
spreading factor and the frequency: the gateway decodes any coding rate, packet
format and `k`, but hears nothing on another SF or channel. Change the sensor
and the gateway together. Measured at the desk with only the gateway moved
500 kHz, the link didn't drop cleanly: LQ fell to 8–13% as the off-channel
signal leaked through, which looks like a weak link rather than a
misconfiguration.

**Stats window (#344):** the gateway measures its LoRa Link figures over a
window of 1–10 s, 10 s by default, set from the app like the other parameters
and applied at the next restart. It's the gateway's alone: a sensor sends every
sample whatever it is. Use **1 s** in a vehicle (FIELD-TEST.md scenario 2),
where 10 s smears a record over about 250 m at 90 km/h.
- **Each window is a smaller sample at 1 s:** about 54 samples in about 13
  packets at V6, so LQ moves in steps of about 2% and the worst margin is the
  minimum over 13 packets rather than 134. Don't compare 1 s and 10 s figures
  directly; the walk-test file records the window, and a change of window
  starts a new file.
- **The console thins out:** below 10 s the gateway logs every
  (10 ÷ window)-th window, so about one line per 10 s. Every record still goes
  to the app.

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

Every packet is one LoRa frame: explicit header, LoRa CRC on, little-endian, no padding. The one exception is the bit-error test's format `11` (type `0x5C`), sent with the CRC **off** so damaged packets reach the gateway (§ Bit-error test); with an explicit header the receiver takes CRC on or off from each packet, so motion packets stay CRC-checked. **PL** means the LoRa payload length the receiver reports.

### Type byte (offset 0, every format)

| Bits | Field | Values |
|---|---|---|
| 7–4 | `marker` | `0x5`: a Sophon LoRa packet. Anything else is dropped and counted as `rx bad`. |
| 3–2 | `format` | `01` = v1, `10` = v2, `11` = bit-error test (#359; § Bit-error test). `00` is reserved and dropped. |
| 1 | `TEST` | v2 only: the walk-test trailer is present |
| 0 | `STATUS` | v2 only: the status trailer is present |

So v1 = `0x54`, and v2 = `0x58` (motion only), `0x59` (+ status), `0x5A` (+ test) or `0x5B` (+ status + test). A bit-error test packet is `0x5C`; it has no flag bits.

### v1: the baseline (variant V0)

| Offset | Size | Field | Type | Units / meaning |
|---|---|---|---|---|
| 0 | 1 | `type` | u8 | `0x54` |
| 1 | 2 | `sensor_id` | u16 | Low 16 bits of the sensor's FICR ID (`src/ident.c`) |
| 3 | 1 | `flags` | u8 | the battery flags as on the Battery characteristic (PROTOCOL.md § Battery frame): bit 0 `usb`, bit 1 `charging`, bit 2 `charge_known` (#323); bits 3–7 are 0 |
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
| 2 | 1 | `flags` | u8 | bit 0 `usb`, bit 1 `charging`, bit 2 `charge_known`, as in v1 |
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
- `format` = `11` is the bit-error test's (#359). There are no format values left, so a new format needs a new marker.
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

## Locking onto a sensor

A gateway relays one sensor. With its peer set to **any** (0, the default), it
locks onto the first sensor whose **status trailer** it hears; with a peer
configured (PROTOCOL.md § Config frame), only that sensor. From firmware
2.32.0 (#350):

- **Only the locked sensor's packets are relayed.** A status trailer, about
  once a second, names its sensor; the packets between don't. An untagged
  packet is taken as the locked sensor's only if its `seq` continues that
  sensor's stream: the gap since the last packet accepted is no more than the
  elapsed time allows at 54.3 Hz, plus two packets' slack. Another sensor's
  packets fall outside that and are counted as **wrong peer**.
- **The stream's anchor is trusted for 5 s.** After 5 s with no packet
  accepted, untagged packets wait for a status trailer from the locked sensor
  to re-anchor. That status counts the gap as **missing** if it's within what
  20 s allows (a fade); a bigger jump is the sensor's restart, re-anchored
  without being counted.
- **With no sensor locked**, untagged packets can't be attributed and are
  dropped as wrong peer until a status trailer names a sensor, normally within
  a second.
- **A quiet sensor's lock is released.** With peer **any**, if the locked
  sensor's status trailers stop for **5 s**, the gateway unlocks (`sensor_id`
  reads 0) and locks onto the next sensor heard. If that's the same sensor
  again, its stream continues, so a fade across the release is still counted.
  A configured peer is never released.
- **What this can't do:** two sensors whose `seq` happen to be within that
  bound of each other, for example switched on within about half a second from
  one power source, can still be mixed. That's accepted: two sensors on one
  channel collide on air every few seconds anyway (seen on the bench,
  2026-10-22), so a shared channel doesn't work whatever the gateway does. A
  sensor tag in every packet was considered and rejected (#354).

**One sensor per channel.** To run more than one sensor, give each
sensor–gateway pair its own frequency: **Configuration › Edit… › Set
frequency**, the same value on both boards of a pair (PROTOCOL.md § Config
frame). Keep pairs at least 500 kHz apart, and more where the stepper allows:
on #329's desk test a gateway only 500 kHz off still caught some of the
other channel (LQ 8–13%). On separate channels a gateway never hears the other
sensor, so there's nothing to mix or to collide with. Frequency hopping (#304)
would cut collisions further but is a larger change.

Before 2.32.0 the lock lasted until the gateway restarted, and untagged packets
were accepted from any sensor.

## Sensor BLE presence

The sensor advertises only its `Sophon-XXXX` name and the MCUmgr SMP service —
no Sophon service UUID. A transporter (#359) advertises the same way. The iOS app filters scans on that UUID and never sees the
sensor; `flash-ota.sh` matches by name and still updates it over the air.

**Image confirmation:** the gateway (like a direct board) confirms a new image on
its first BLE frame delivered. The sensor confirms on its first successful LoRa
send. With no acknowledgement on the link, that proves only the sensor's IMU →
radio path. A transporter confirms the same way, on its first send. A gateway
that hears only a transporter relays no motion, so it also confirms on its first
LoRa BER record delivered from a window that heard one (#359).

## Noise floor

From firmware 2.31.1 (#336), a gateway samples its receiver's instantaneous
RSSI between packets: once in the middle of the quiet gap after each packet
it receives, or every 100 ms once nothing has been heard for 200 ms. Each
LoRa Link record carries the window's **minimum** and **median**
(PROTOCOL.md § LoRa Link frame). The timing per preset, and why mid-gap, is in
NOISE-FLOOR-PLAN.md.

- **What to expect:** thermal noise in 500 kHz with a 6 dB noise figure is
  about −111 dBm. A floor several dB above that is noise the receiver's own
  setup picks up, or other traffic on the channel.
- **Minimum against median:** the minimum is the clean floor. A median well
  above it means interference that lasts: another transmitter, or noise from
  something near the antenna.
- **Signal over noise:** packet RSSI minus the median noise estimates the
  signal's margin over the noise the receiver actually hears, independent of
  LoRa's own SNR. The app shows it on the LoRa RSSI row, and
  `walktest-report.py` per distance band.


## Bit-error test

From firmware 2.33.0 (#359). A board in the **transporter** role sends its own
running image over LoRa with the **payload CRC off**, and a gateway compares
every bit it receives with its own copy. The figures go to the gateway's
console and to the app over the LoRa BER characteristic (PROTOCOL.md § LoRa BER
frame). The design and the arithmetic are in
[TRANSPORTER-PLAN.md](TRANSPORTER-PLAN.md).

**What's sent:** slot 0 from the MCUboot header through the body, L =
`ih_hdr_size + ih_img_size` bytes, looped forever. Not the rest of the slot, not
the TLVs, not MCUboot's trailer. A packet that crosses the end wraps to the
start, so every packet is the same length and every payload byte is an image
byte.

**Packet** (`format` = `11`), little-endian:

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 1 | `type` | `0x5C` |
| 1 | 2 | `tx_id` | low 16 bits of the transporter's FICR id, as `sensor_id` |
| 3 | 2 | `pseq` | packet counter, from 0 at boot, mod 2^16. Advances even on a failed send |
| 5 | 3 | `offset` | u24: where in the image the payload starts. Advances by n per packet, mod L |
| 8 | 1 | `hcrc` | CRC-8, poly `0x07`, init 0, over the board's own 32-byte image SHA-256 and then bytes 0–7 |
| 9 | n | image | image bytes `(offset + i) mod L`, i = 0 … n − 1 |

- **Length:** PL = the preset's full motion packet (`lora_preset_full_len`), so
  n = PL − 9. At V6, PL = 60 and n = 51.
- **Schedule:** one packet every k × 18.4 ms, as a sensor sends, so airtime,
  duty and noise-floor gaps match the motion link. A pass over a 220 KB image
  takes 3.7–5.4 minutes depending on the preset; at V6, 4,310 packets, 5.3 min.
- **CRC off** on the transporter only. With an explicit header the receiver
  takes CRC on or off from the packet, so the gateway's configuration is
  unchanged and motion packets stay CRC-checked.
- **Same image on both boards.** Equal SHA-256 means equal bytes on air (the
  hash covers header and body, not the signature, so a reproducible rebuild
  counts as the same). The hash isn't sent: the app's **Check images** compares
  the two boards' slot-0 hashes over SMP, and `hcrc`'s seed makes the gateway
  see a mismatch as headers that never pass. Those headers still name the
  transporter: from 2.37.0 the gateway reports the id two packets in a row
  named, marked unverified (PROTOCOL.md § LoRa BER frame), so the app can find
  the board and run the check that shows the mismatch.
- **A BER walk needs a matching check.** While the gateway hears a
  transporter, the app's **Start walk-test recording** stays disabled until
  Check images reports a match for that pair, on the firmware both run now. A
  mismatch or an unfinished check says why. A walk with no transporter heard
  is unaffected.
- **Not encrypted.** No key or credential is in the image, but anyone receiving
  the channel can rebuild the firmware binary itself.

**Worked example** (the host test pins these bytes): image hash `00 01 … 1F`,
`tx_id` 0x1A2B, `pseq` 0x0102, `offset` 0x000345:

```
5C | 2B 1A | 02 01 | 45 03 00 | 50 | image[0x345] …
```

**What the gateway measures**, per window:
- **Every bit counts, header included.** A packet whose `hcrc` passes is the
  **anchor**. When `hcrc` fails, the gateway rebuilds the header from the
  anchor: `type`, `tx_id` and the hash are known, and Δ packets on, `pseq` is
  `(anchor_pseq + Δ) mod 2^16` and `offset` is `(anchor_offset + Δ·n) mod L`.
  It tries Δ = 1 to what the elapsed time allows plus two (at most 64) and keeps
  the whole packet closest to what arrived: **repaired**.
- **Unresolved:** no anchor in the last 5 s, or the best match over 25% wrong.
  Not compared; counted.
- **Not trusted on hcrc alone:** CRC-8 lets about 1 damaged header in 256
  through, so a passing header whose payload is over 25% wrong goes to repair
  too.
- **A damaged type byte:** a packet that fails to decode, has the anchor's
  length, and arrives within 5 s of the anchor is tried the same way; if it
  can't be resolved it counts as `rx bad`, as before.
- **Lost** packets are the gaps in `pseq`. A gap after more than 20 s, or a
  `pseq` that doesn't match its `offset` (a transporter restart), re-anchors
  without counting.
- **Image mismatch suspected:** at least 10 test packets in the window, at
  least 90% unresolved, at an average SNR ≥ 0 dB.

**What "raw" means:** the bits after the radio's own decoding, with only the
CRC removed. V4 (CR 4/7) is the only preset where the radio corrects errors, so
its figure is the residual after correction. Every other preset is CR 4/5,
parity only, so its figure is the demodulated channel's. Coding can only fix
damaged packets; lost ones (a missed preamble, a failed LoRa header, a
collision) stay lost.

**Console**, one line per window when any test packet was heard:

```
lora ber: tx 1A2B; 135 pkts (1 repaired, 0 unresolved), 2 lost; 3 damaged; 14 / 64800 bits = 0.0216%
```

The transporter logs `lora tx: N image pkts, N send errors; N whole passes so
far` every 10 s.

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

Procedure: LORA-UPDATED-PLAN.md § Walk-test procedure. The sensor stays at base, and the walker carries the gateway and phone. The app's recording format is § Walk-test recording format below.

## Walk-test recording format

The Sophon app writes each walk-test recording as a CSV in Documents (the Files
app's On My iPhone › Sophon). This is **version 3** (#359), which is version 2
(#335) plus the bit-error test's `ber_*` columns and `transporter` preamble line.
What stays fixed for the session is written once, in a preamble, and only what
changes per window is in the rows. Version 1 files, from before #335, have no
preamble and one flat row per record; `scripts/walktest-report.py` reads all
three.

**Preamble:** `# key: value` lines before the header, written when the first
record arrives, so the boards and their configuration are known.

| Key | Value |
|---|---|
| `sophon-walktest` | `3` (`2` before #359), always the first line |
| `started` | local start time with offset, and the time zone |
| `part`, `continues` | only in a continuation file: its part number and the previous file's name |
| `app` | app version and build, phone model, iOS version |
| `gateway` | name, firmware and hardware version |
| `gateway config` | the active Config (PROTOCOL.md § Config frame): role and whether it was set from the app, preset, SF, TX power, frequency, stored peer, RX boost, and the record's window length |
| `sensor` | the sensor the gateway locked onto, with its firmware if the app has seen it advertise; `not locked` otherwise |
| `transporter` | only once the gateway has heard one (#359): its name and the latest image check, e.g. `images match (checked …)`, or `images not checked` |
| `sensor config` | only if the app read the sensor's Config this session |
| `variant rotation` | `off`: one preset for the whole file. `on`: walk-test variant rotation (§ Walk-test mode), so preset, SF and RX boost become row columns |
| `pin` | where distances are measured from: position, accuracy, and `automatic (first fix)` or `dropped by hand` |
| `note` | the walker's description of the setup, typed at Start |
| `no records` | only in a recording stopped before any record arrived |

**Columns:** `type`, `time` (UTC), `window`; with variant rotation on,
`preset`, `sf`, `rx_boost`; then the record's link figures (`heard`, `lq_pct`,
`margin_db`, `margin_min_db`, `rssi_avg`, `rssi_min`, `snr_avg`, `snr_min`,
`samples`, `missing`, `bad`, `wrong_peer`, `last_packet_ms`; § How the gateway
maps onto the BLE protocol). `lq_pct` is computed by the app from `samples`
and `missing` (PROTOCOL.md § LoRa Link frame); `last_packet_ms` is empty for
"25.5 s or more, or none", and `bad` and `wrong_peer` saturate at 15. Then the receiver's noise floor (`noise_min`,
`noise_median`, dBm; empty until #336 measures it); the position (`lat`, `lon`, `h_accuracy_m`,
`distance_m`, `fix_age_s`); the **sensor's** battery as the gateway relays it
(`sensor_batt_mv`, `sensor_usb`, `sensor_charging`); how the window's losses
clustered (`loss_run_1`, `loss_run_2`, `loss_run_3_4`, `loss_run_5_8`,
`loss_run_9_plus`; below); the bit-error test's window (`ber_packets`,
`ber_damaged`, `ber_lost`, `ber_bit_errors`, `ber_bits`, `ber_repaired`,
`ber_unresolved`, `ber_mismatch_suspected`; PROTOCOL.md § LoRa BER frame), filled
only from the BER record with the row's own window number and empty otherwise;
and `event`.

**Loss runs (#337).** The gateway relays every motion sample with the
sensor's `seq`, which advances on every sample whether or not it was heard. A
gap in `seq` on the stream the app receives is therefore a run of lost LoRa
packets: the gap in samples ÷ the preset's `k`, rounded up, since a packet the
sensor closes early carries fewer than `k`. Each `loss_run_*` column is the
number of **samples** the app saw lost in runs of 1, 2, 3–4, 5–8 or 9 or more
packets in that window, so the five add up to the window's loss as the app
saw it:
- **equal to `missing`:** every lost sample was lost on the LoRa link;
- **more than `missing`:** the gateway's own Bluetooth queue overflowed and
  dropped frames, which isn't LoRa loss;
- **less:** a gap that arrived after the record was counted in the next window.

Gaps while the app itself was suspended aren't counted. A `missing` row
carries the runs seen during its 10 s. The columns are **empty** where the app
didn't see the whole of a window's stream: the first record of a recording,
and every row across a dropped link (the `missing` rows and the first record
after it). They are empty too while the variants rotate, since `k` then
changes packet by packet.

**Row types:**

- `window`: one LoRa Link record. `event` is empty.
- `event`: a moment, not a window. Only `type`, `time`, the latest position
  and `event` are filled. The `event` values are:
  - `background`, `foreground`: the app went to the background, e.g. the
    phone was locked, and came back. Control Center or a banner over the app
    isn't logged: the app keeps running;
  - `disconnected`, `connected`: the Bluetooth link to the recording's gateway.
    `disconnected` is logged when iOS gives up on the link, up to the link's
    supervision timeout after it actually failed. `connected` means the link
    is up, not that records are flowing again;
  - `sensor locked: Sophon-XXXX`: the gateway locked onto a sensor after the
    preamble said `not locked`;
  - `transporter heard: Sophon-XXXX` (#359): the gateway first heard a
    transporter after the preamble was written. The preamble's `transporter`
    line states an image check only while it still describes the transporter
    heard and both boards' advertised firmware; otherwise `images not checked`.
    After a reconnect, the first window row can have empty `ber_*` columns: the
    re-read of LoRa Link can land before that window's BER record;
  - `gateway config: …`: the gateway's Config, read after the preamble said
    `not read yet`;
  - `marker: <text>`: added by the walker while recording;
  - `pin: <lat>,<lon> ±<acc> m`: a pin dropped by hand after rows were written. Later distances are from it;
  - `pin automatic: …`: the first fix, when it arrived after the first record;
  - `config changed`: the last row of a file that a configuration change closed.
- `missing`: a window the gateway produced that the app never received
  (#334), written before the next record. It has the window number, the time
  it was due (the previous record's time + one window length per window), and the latest
  fix **as of that time** with its age then, so it falls in the distance band
  where it was missed. The link columns are empty, and `walktest-report.py`
  counts it per band, never in LQ.
  - The window counter is 16-bit (#333), so no realistic gap wraps it.
  - A gateway restart starts the counter again and always drops the link. So
    only across a `disconnected` does the app check the jump against the
    clock: one the clock can't account for is a restart and gets no `missing`
    rows. On a link that stayed up, the jump is trusted, so a record
    delivered late still counts its gap.
  - The one blind spot: a restart within about one window of the previous
    boot falls short by too little to see, giving at most one false row
    (LORA-LINK-V2-PLAN.md § Why no boot ID).
  - Not written while the variants rotate: the gateway then sends several
    records per window.
  - They are written when the next record reveals the gap, so they follow
    any event rows logged during the outage (`disconnected`, `connected`)
    although their times are earlier. Sort by `time` for a strict timeline.

**One configuration per file.** If any of these differ from the open file's
preamble, the app ends that file with a `config changed` event and continues in
`…-part2.csv`, with a fresh preamble saying which file it continues:
- the locked sensor, once both are known. A gateway reports no sensor until it
  locks onto one and again after it restarts, and that matches any sensor;
- the transporter the bit-error test hears (#359), on the same terms: none heard
  yet matches any;
- variant rotation;
- outside rotation, the record's preset, SF and RX boost;
- the gateway's active role, preset, TX power and frequency, once both are
  known. They change only when the gateway restarts. The peer isn't compared:
  a stored peer can change without a restart, and the lock is the sensor above.

A recording follows **one gateway**, the first it hears from. Records from any
other connected gateway are ignored.

A gateway that restarts with the same configuration continues the same file;
the restart shows as `window` starting again. After any reconnect, records wait for the
gateway's Config to be read again before they are written, so the first record
after a real change lands in the new file. They wait at most 15 s, and not
past a disconnect or Stop; a record written while the config is unknown never
splits a file.

## Walk-test results

*Pending.* One table per route (line of sight, obstructed): per waypoint and
variant, LQ, RSSI and SNR, boost on and off, and which variants pass LQ ≥ 99%.
Plus the antenna-height check and the bench latency measurements (min, median,
max per variant).

## Chosen preset

*Pending.* Chosen by the rule in § Variants (How to choose), with the required
distance and the reason recorded here. V6 until then (#321): V3's latency with
8 dB more link budget, for about 2.6× the sensor's radio current.
