# LoRa Link record, version 2

Design for #333 (serving #344 and #336), agreed on 2026-10-21. **Implemented
in firmware 2.29.0**: PROTOCOL.md § LoRa Link frame is the reference for the
layout; this records why each field is where it is.

## Context

The gateway's LoRa Link record (PROTOCOL.md § LoRa Link frame) is exactly **20 bytes**, the most one ATT notify carries at MTU 23 (#271 kept the MTU), and every byte is in use. Three open issues need things it can't hold:

| Issue | Needs in the record |
|---|---|
| #333 | `window` as 16 bits (wraps every 42.7 min today, every 4.3 min at 1 s windows) |
| #344 | the record's **window length** (1–10 s), so no consumer assumes 10 s |
| #336 | the **noise floor** per window: minimum and median, in dBm |

That's 1 + ½ + 2 = 3½ more bytes. Version 2 frees them from fields that are derivable or oversized, and stays at 20 bytes, so it still fits one notify. Defining the noise fields now (as "not measured" until #336) means #336 needs no version 3.

## Side by side

Every u16 stays 2-byte aligned (even offset), and the spare byte is last. The identity fields come first (`version`, `preset`, `sensor_id`); the RSSI and SNR bytes, `samples` and `missing` keep their version 1 offsets; the rarely used counts and `flags` go last. Nothing reads `flags` before decoding the whole record, so its position doesn't matter to either end.

| Field | Version 1: offset, size | Version 2: offset, size | Change |
|---|---|---|---|
| `version` | 0, 1 | 0, 1 | value 1 → **2** |
| `preset` | 1, 1 | 1, bits 0–3 | now 4 bits: ids 0–8, 9–15 spare |
| **`window_s`** | — | 1, bits 4–7 | **new**: 1–10 s (#344) |
| `sensor_id` | 18, 2 | 2, 2 | moved, aligned |
| `window` | 3, 1 (u8) | 4, **2 (u16)** | **widened** (#333), aligned |
| `lq_x10` | 4, 2 | — | **dropped**: `samples ÷ (samples + missing)` |
| `rssi_avg` | 6, 1 | 6, 1 | unchanged |
| `rssi_min` | 7, 1 | 7, 1 | unchanged |
| `snr_avg` | 8, 1 | 8, 1 | unchanged |
| `snr_min` | 9, 1 | 9, 1 | unchanged |
| `samples` | 10, 2 | 10, 2 | unchanged |
| `missing` | 12, 2 | 12, 2 | unchanged |
| `last_packet` | 16, 2 (ms) | 14, 1 (100 ms) | **narrowed**, moved: 0–25.4 s, 255 = 25.5 s or more, or none |
| **`noise_min`** | — | 15, 1 | **new**: dBm, `0x7F` = not measured (#336) |
| **`noise_median`** | — | 16, 1 | **new**: dBm, `0x7F` = not measured (#336) |
| `bad` | 14, 1 | 17, bits 0–3 | **narrowed**, moved: saturates at 15 |
| `wrong_peer` | 15, 1 | 17, bits 4–7 | **narrowed**, moved: saturates at 15 |
| `flags` | 2, 1 | 18, 1 | moved; bits unchanged |
| **`reserved`** | — | 19, 1 | **spare** = 0, last |
| **Total** | **20 B** | **20 B** | the ATT notify limit at MTU 23, so both still fit one notify |

**Version 2 on its own**, in order:

| Offset | Size | Type | Field |
|---|---|---|---|
| 0 | 1 | u8 | `version` = 2 |
| 1 | 1 | u8 | `preset` (bits 0–3) · `window_s` (bits 4–7) |
| 2 | 2 | u16 | `sensor_id` |
| 4 | 2 | u16 | `window` |
| 6 | 1 | i8 | `rssi_avg` |
| 7 | 1 | i8 | `rssi_min` |
| 8 | 1 | i8 | `snr_avg` |
| 9 | 1 | i8 | `snr_min` |
| 10 | 2 | u16 | `samples` |
| 12 | 2 | u16 | `missing` |
| 14 | 1 | u8 | `last_packet`, 100 ms units; 255 = 25.5 s or more, or none |
| 15 | 1 | i8 | `noise_min`, dBm; `0x7F` = not measured |
| 16 | 1 | i8 | `noise_median`, dBm; `0x7F` = not measured |
| 17 | 1 | u8 | `bad` (bits 0–3) · `wrong_peer` (bits 4–7), each saturating at 15 |
| 18 | 1 | u8 | `flags`: bit 0 RX boost · 1 walk-test · 2 heard · 3 spare · 4–7 SF |
| 19 | 1 | u8 | `reserved` = 0 |
| | **20** | | |

**Hex dumps:** the SF and heard bits are near the end, not beside the version; PROTOCOL.md's worked example labels each byte.

**Byte budget:** version 2 frees 4½ bytes (`lq_x10` 2, `last_packet` 1, `bad`/`wrong_peer` 1, half of byte 1) and spends 3½ (`window` +1, `noise_*` 2, `window_s` ½), so it stays at **20 bytes** with one whole byte spare (byte 19, at the end), plus bit 3 of `flags` and preset values 9–15.

## Where the bytes come from

| Freed | Bytes | Why it's safe |
|---|---|---|
| `lq_x10` dropped | 2 | **Derivable:** it is `samples ÷ (samples + missing)`, and "nothing expected" is both zero. Checked against the 2026-10-18 walk: 516 received, 20 missing gives 96.2%, as recorded. Consumers compute it. |
| `last_packet_ms` u16 → u8 in 100 ms | 1 | It's read as "how stale is the link" (orange above 1 s in the app). 100 ms resolution is plenty; saturating at 25.5 s covers any window. |
| `bad` and `wrong_peer` share a byte | 1 | Both are rare: 1 bad packet in the whole hour-long walk, never a wrong peer. They saturate at 15, and a window with 15 of either is already a failure to investigate. |
| `preset` shares its byte with `window_s` | ½ (+ spare preset values 9–15) | Preset ids 0–8 fit in 4 bits; the window length (1–10) fits the other 4. |

| Spent | Bytes |
|---|---|
| `window` u8 → u16 | 1 |
| `window_s` | ½ (in byte 1) |
| `noise_min`, `noise_median` | 2 |

## What each consumer does with version 2

- **App (`LoRaLinkRecord`):**
  - parses version 2;
  - computes link quality from `samples` and `missing`;
  - `windowSeconds` comes from the record;
  - `missingWindows` keeps #334's restart check, the counter against the clock, only across a dropped link. With 16 bits its wrap handling goes, since no realistic gap spans 65,536 windows. #333's added requirement, "use the boot ID", is replaced by this.
  - the walk-test CSV gains `window_s` in the preamble, plus `noise_min` and `noise_median` columns (empty while `0x7F`).
- **Version 1 dropped (decided):** all boards are reflashed together, so the app parses version 2 only. A version 1 record is dropped like any unknown version today ("Parsers drop any other value"), so a gateway still on old firmware shows no LoRa link until it's updated. The version 1 parser and its self-check vectors are removed.
- **`walktest-report.py`:** reads both CSV versions already. The new columns are additive.
- **Self-check:** a worked version 2 byte vector in PROTOCOL.md, mirrored in `SophonProtocolSelfCheck`.

## Why no boot ID

A boot ID was meant to tell a gateway restart from a gap with certainty. It isn't needed, and it wouldn't be certain either:

- **The motion frames can't tell us.** Behind a gateway, `seq` and `t_ms` are the **sensor's**: they show a sensor restart, not a gateway restart. The gateway's TX Stats counters restart at 0 too, so they share the window counter's ambiguity.
- **The window counter plus the clock already does it.** The counter is the gateway's uptime in windows. A restart always drops the link, and across a drop the app compares the jump with the elapsed time. Without a restart, the counter advances by about the elapsed windows. With one, it comes back short by the windows the old boot had counted.
  - **Example:** the gateway restarts at window 5 and the app reconnects 2 minutes (12 windows) later at window 12. That's a jump of 7 against 12 expected, so it's a restart, with no `missing` rows.
- **The only blind spot** is a restart within about one window of the previous boot, where the shortfall is too small to see. The cost is at most one false `missing` row.
- **#332's fetch** loses nothing: a restart clears the gateway's RAM ring, so once the app has detected a restart, there is nothing to fetch from before it.

## Decisions

- **Version 1 dropped (decided):** see above.
- **Noise fields defined now (decided):** `noise_min` and `noise_median` are part of version 2 from the start, sent as `0x7F` ("not measured") until #336 fills them, so #336 needs no version 3.
- **No boot ID (decided):** the spare byte is reserved, last (byte 19); § Why no boot ID gives the reasoning.

## Verification, when #333 is implemented

- PROTOCOL.md worked example for version 2; app self-check vectors for version 2, and a check that a version 1 record is rejected.
- Bench: records arrive with `window` passing 255 without wrapping; a reset gives no `missing` rows; two Save-and-restarts a minute apart give none either; LQ computed by the app matches the gateway console's figure.
- `scripts/test-codec.sh` and the walk-test report on a version 2 recording.
