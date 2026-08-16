# Sophon wire protocol

The contract between the Zephyr peripheral (`zephyr/sophon/`) and the iOS central
(`ios/Sophon/`). Both sides implement this document; changing it means changing
both.

The *reasoning* behind these choices — the ATT MTU budget, the connection-event
capacity analysis, the batching/DLE arithmetic — lives in
[`ios/Sophon/UPDATED-PLAN.md`](../../ios/Sophon/UPDATED-PLAN.md). Its frozen
pre-implementation counterpart, `ORIGINAL-PLAN.md`, sits beside it; where they
disagree the updated one is right. This file is the live contract and is kept
current.

## UUIDs

Frozen at implementation time. Base UUID with the role in the first 32-bit group,
following the Nordic UART convention.

| Role | UUID |
|---|---|
| Sophon Motion Service | `C6560001-84D5-4DC2-8C1E-4B4EB2337CE4` |
| Motion Data characteristic (notify) | `C6560002-84D5-4DC2-8C1E-4B4EB2337CE4` |

The service UUID is carried in the **advertisement**; iOS filtered scanning
(`scanForPeripherals(withServices:)`) matches against it, and filtered scanning is
required for the app to see anything while backgrounded.

The Motion Data characteristic is notify-only and carries a Client Characteristic
Configuration descriptor.

## Frame

**18 bytes, little-endian.** One frame is one IMU sample.

| Offset | Size | Type | Field | Units |
|---|---|---|---|---|
| 0 | 2 | `u16` | `seq` | frame counter, wraps at 65535 |
| 2 | 4 | `u32` | `t_ms` | milliseconds since *this board's* boot |
| 6 | 2 | `i16` | `ax` | milli-g |
| 8 | 2 | `i16` | `ay` | milli-g |
| 10 | 2 | `i16` | `az` | milli-g |
| 12 | 2 | `i16` | `gx` | centi-degrees/second |
| 14 | 2 | `i16` | `gy` | centi-degrees/second |
| 16 | 2 | `i16` | `gz` | centi-degrees/second |

### Why 18 bytes

The ATT MTU is left at Zephyr's default of 23, which leaves 20 bytes of usable
characteristic value once the 4-byte L2CAP header and 3-byte ATT header are
subtracted from the 27-byte link-layer payload. 18 fits with 2 spare, so **one
sample is exactly one radio packet** — no L2CAP fragmentation, no reassembly logic
on either side.

`seq` exists so the receiver can detect dropped frames without a timer. It is
per-device and wraps; the decoder compares against the previous value modulo
65536.

## Rates

| Stage | Notify rate | Axis fields |
|---|---|---|
| #208 (skeleton) | 1 Hz | all zero — `seq` and `t_ms` are live |
| #209 onward | 50 Hz | real IMU data |

The skeleton's 1 Hz zero-filled frame exists so the subscribe path is verifiable
end-to-end before the IMU is wired up, and slow enough to read by eye during
bring-up.

## Identity

Each board advertises a name derived from its nRF52840 FICR device ID:
`Sophon-XXXX`, where `XXXX` is four uppercase hex digits. The same firmware image
flashed to every board therefore produces a distinct, stable name.

The device ID is **not** in the frame. iOS already knows the source peripheral on
every notification callback, so per-sample identity would be redundant bytes at
50 Hz × N devices for zero information. Identity is a connect-time property.

Note the advertised name carries only 16 bits of the 64-bit FICR ID. That is
ample for a handful of boards; it is not a collision-proof identifier.

## Advertising layout

Legacy advertising carries 31 bytes per packet. Flags + the 128-bit service UUID +
the name is 34 bytes, so the name moves to the scan response:

```
Advertisement (21 B of 31)        Scan response (13 B of 31)
  Flags                    3 B      Complete Local Name   2 + 11 B
  128-bit service UUID    18 B
```

iOS active-scans by default, so `CBAdvertisementDataLocalNameKey` and
`peripheral.name` both populate normally. The scan response's remaining 18 bytes
are unused — see UPDATED-PLAN.md for what could go there and why none of it is in
the skeleton.

## Security

**No pairing.** `CONFIG_BT_SMP` is off, the link is unencrypted, and the
characteristic carries no encryption permission. The deciding factor is
development friction: iOS caches bonds aggressively, and a reflashed board loses
its keys while the phone still believes it is bonded, which requires a manual
*Forget This Device* on the phone after each flash.

Full reasoning, and the shape of the change if it is ever wanted, is in
UPDATED-PLAN.md.

## Known gaps

- **No common time base.** `t_ms` is relative to each board's own boot. Adequate
  for sensor fusion, which needs only intra-device `dt`; insufficient for aligning
  two Sophons to the same instant. Tracked in #211.

## Designed scaling path

The frame is fixed-size and sequence-numbered specifically so that batching is
possible without a format change: send *k* × 18 bytes and the decoder splits on
18-byte boundaries. That is a peripheral-side config change only — iOS already
offers a 185-byte MTU at negotiation.

Batching is deliberately **not** done at N=1: it trades latency
(`(k−1)/f`, i.e. 60 ms at k=4 and 50 Hz) for connection-event occupancy, and at one
device there is no occupancy pressure to relieve. It becomes correct around N≥4.

When it happens, the ATT MTU and DLE must be raised **together** — raising the MTU
alone fragments a 4-sample batch into 3 link-layer packets and returns about a
quarter of the benefit. Tracked in #211, which carries the exact Kconfig.
