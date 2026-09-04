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
| TX Stats characteristic (read) | `C6560003-84D5-4DC2-8C1E-4B4EB2337CE4` |
| Link Params characteristic (read) | `C6560004-84D5-4DC2-8C1E-4B4EB2337CE4` |

The service UUID is carried in the **advertisement**; iOS filtered scanning
(`scanForPeripherals(withServices:)`) matches against it, and filtered scanning is
required for the app to see anything while backgrounded.

The Motion Data characteristic is notify-only and carries a Client Characteristic
Configuration descriptor.

The TX Stats characteristic is **read-only, and deliberately not a notify**. The
counters move slowly and are diagnostics; a subscription would spend
connection-event budget, which is the exact resource the counters exist to help
measure. Instrumenting a scarce resource by consuming it defeats the point.

The Link Params characteristic is read-only for the same reason, and exists for a
sharper one: **Core Bluetooth exposes no API for connection parameters.** An iOS
app cannot ask what interval, latency or supervision timeout it was granted. Only
the peripheral can, via `bt_conn_get_info()`, so the values have to travel back
over GATT to reach the side that needs them.

## Link Params frame

8 bytes, little-endian. Read from the live connection each time, never cached — a
stale interval is exactly the kind of number that gets believed, and nobody on the
central side can check it.

| Offset | Size | Type | Field | Units |
|---|---|---|---|---|
| 0 | 4 | `u32` | `interval_us` | microseconds |
| 4 | 2 | `u16` | `latency` | connection events the peripheral may skip |
| 6 | 2 | `u16` | `timeout` | supervision timeout, **10 ms units** |

`interval_us` rather than the 1.25 ms `interval` field: that one is `__deprecated`
in Zephyr 4.4 and builds with a warning. The `le_param_updated` callback still
hands back the old unit, so the firmware ignores its arguments and re-reads
`bt_conn_get_info()` instead — no conversion to get wrong.

8 bytes fits the 20-byte value budget at the default 23-byte ATT MTU, so this
needs no MTU change and never fragments, the same constraint that shaped the
motion and stats frames.

### Why this is the number that matters

Buffer refusals, frame gaps and stream latency are all governed by the interval
iOS grants, and iOS revises it on its own schedule — notably stretching it to save
power. During #209, a board streaming to a sleeping iPhone produced transmit
refusals and frame loss, and the diagnosis detoured through buffer sizing before
the cause turned out to be a stretched interval.

The useful derived form is **events per second** (`1 / interval`), because that is
what a sample rate has to fit through. 50 Hz of frames cannot pass through 25
events/s, which is the arithmetic #248 is about.

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

### Measurement ranges

The units above bound what the frame *can* express; the sensor's configured
full-scale bounds what it *does*. Both are set in `prj.conf` and asserted at
compile time in `src/imu.c`.

| Axis | Full scale | Wire limit | Which one binds |
|---|---|---|---|
| Accel | ±4 g | ±32.767 g | the sensor |
| Gyro | ±250 dps | ±327.67 dps | **the wire** |

The gyro row is a real constraint on this format, not a coincidence. Centi-
degrees/second in an `i16` saturates at 327.67 dps, so ±250 dps is the largest
standard LSM6DSL range that fits — the next step up, ±500 dps, would clip every
fast rotation into a flat top that still decodes as valid data. **Raising the
gyro range therefore requires a frame change, not a config change.**

Accel is the other way round: the wire quantises to 1 mg while the sensor
resolves 0.122 mg/LSB at ±4 g, so the frame is the limiting factor at any
supported range. Moving to ±8 g or ±16 g costs nothing on the wire and needs no
change here.

### Why 18 bytes

The ATT MTU is left at Zephyr's default of 23, which leaves 20 bytes of usable
characteristic value once the 4-byte L2CAP header and 3-byte ATT header are
subtracted from the 27-byte link-layer payload. 18 fits with 2 spare, so **one
sample is exactly one radio packet** — no L2CAP fragmentation, no reassembly logic
on either side.

### What `seq` means

**`seq` is a sample-period index, not a count of successful transmissions.** It
is per-device and wraps at 65535; the decoder compares against the previous value
modulo 65536.

The rules, in full, because the difference between them is load-bearing:

- It advances **once per sample period**, at the moment a frame is built.
- It advances **only while a client is subscribed.** Nothing is expected while
  nobody is listening, so the jump across an unsubscribed stretch is not a gap.
- It is **never rewound or reused**, including when the send fails. A sample that
  was taken and not delivered is a hole, and the receiver has to be able to see
  it.

That last rule is the one worth defending. Now that real IMU data is flowing
(#209), a sample whose notification fails is a physical measurement that no
longer exists anywhere. Reusing its sequence number would hand the central a
stream that *looks* continuous while silently missing an interval — and #210's
fusion would integrate gyro straight across that hole, producing attitude error
that never washes out, from data the app had no way to know was missing.

`t_ms` does not cover for this. It timestamps the frames that arrived; two frames
38 ms apart at 52 Hz are indistinguishable from a hole unless something counts
the missing one.

### What a gap does *not* tell you

A gap means **"there is no data for this interval."** It does not say why. Four
different things produce one:

| Cause | Actually lost? |
|---|---|
| Dropped on the radio link | yes |
| Sample taken, but the notification failed (e.g. TX buffers full) | never sent |
| Central was not listening (app suspended, link still up) | sent fine |
| Frame arrived but the central rejected it | arrived intact |

Attribution therefore needs a **second signal**, not a cleverer sequence number.
The peripheral counts its own transmit outcomes — accepted, no-buffer, no-client,
other — summarises them to the console periodically, and exposes them for reading
over the **TX Stats characteristic** described below.

They are deliberately kept **out of the sample stream**: they answer a debugging
question, and the motion frame should carry motion. A separate read-only
characteristic gets them to a phone in a room full of boards, which is where the
question actually gets asked, without adding a byte to the 52 Hz path.

## TX Stats frame

**16 bytes, little-endian**, read from the TX Stats characteristic. Four
cumulative counters, in this order:

| Offset | Size | Type | Field | Meaning |
|---|---|---|---|---|
| 0 | 4 | `u32` | `sent` | notifications the stack accepted |
| 4 | 4 | `u32` | `no_conn` | rejected, nobody subscribed — expected, not a fault |
| 8 | 4 | `u32` | `no_mem` | rejected, TX buffers full — **the interesting one** |
| 12 | 4 | `u32` | `other` | anything else the stack returned |

Counters are cumulative **since the board booted** and never reset, so they
survive a reconnect while the central's own counters do not. A consumer wanting
per-session figures should snapshot on connect and subtract.

16 bytes fits the 20-byte value budget at the default 23-byte ATT MTU, so this
needs no MTU change and never fragments — the same constraint that shaped the
motion frame.

These counters are what make a gap **explicable**: see *What a gap does not tell
you* above. `no_mem` says the frame never left the board, which distinguishes
board-side congestion from loss on the air. The two produce an identical gap and
point at completely different culprits.

Measured, and the reason to trust the scheme: over a 3-minute soak with
continuous reads of this characteristic running alongside the stream, the central
observed **30 sequence gaps** against a board-side `no_mem` delta of **exactly
30**. Every hole was accounted for board-side; nothing was lost on the air. A gap
count on its own could not have told those apart.

That soak ran against Zephyr's default of three TX buffers. Raising the pools to
8 (see `prj.conf`) removed them on a like-for-like comparison — same device, same
usage, 13 refusals in 56000 frames down to none in 84000. The correspondence
above is therefore a demonstration that the attribution works, not a description
of normal operation.

**Always state which central, and whether it was awake.** The refusal rate is a
property of the radio schedule, not of the peripheral: a central that sleeps
makes iOS stretch the connection interval, several samples pile up between radio
events, and refusals reappear at any pool size. The same firmware that refused
nothing in 84000 frames to a foreground iPad logged 26 in 51000 to a sleeping
iPhone. Comparing those two numbers as though they measured the same thing is
how this document previously got the figure wrong.

It is a reduction, not an elimination. A `no_mem` of zero over any given window
is a sample, not a guarantee — expect an occasional refusal, and expect the
matching single-frame gap to be attributed rather than mysterious. That is the
whole point of carrying the counter.

**`no_mem` is only meaningful if the notify path can actually fail rather than
block.** `bt_gatt_notify()` allocates with `K_FOREVER` on any thread that is not
the system work queue, so a peripheral that transmits from its own sampling
thread will hang there instead of returning `-ENOMEM` — and this counter will
read a reassuring zero while the stream is dead. Sophon transmits from the
sysqueue for exactly this reason; see the queue comment in `src/main.c`.

## Rates

| Stage | Notify rate | Axis fields |
|---|---|---|
| #208 (skeleton) | 1 Hz | all zero — `seq` and `t_ms` are live |
| #209 onward | **52 Hz nominal, ~54.3 Hz measured** | real IMU data |
| #209, no IMU present | 1 Hz | all zero — the fallback below |

The skeleton's 1 Hz zero-filled frame exists so the subscribe path is verifiable
end-to-end before the IMU is wired up, and slow enough to read by eye during
bring-up.

### Why 52 Hz and not 50

The plan derives **50 Hz** from the connection-event budget, and the LSM6DSL
cannot produce it: its output-data-rate grid is 12.5 / 26 / **52** / 104 / 208 …
and 50 is not on it.

The stream is paced by the sensor's data-ready interrupt, so the rate is
whichever grid step is selected — 52 Hz, the nearest. The alternative, running
the sensor at 52 Hz and notifying from a 50 Hz timer, would reintroduce exactly
the drift between two independent clocks that the interrupt exists to remove, and
would drop or duplicate a sample roughly every half second doing it.

The 4% overshoot is free. The capacity analysis in UPDATED-PLAN.md costs 50 Hz at
**0.75** notifications per 15 ms connection event against iOS's ~4-per-event
policy; 52 Hz moves that to **0.78**. Every column of that table stays
comfortable, at 30 ms and 45 ms intervals too.

### The sensor does not deliver its nominal rate either

Measured on hardware, the board streams at **54.2–54.4 Hz**, not 52 — a **+4.6%**
deviation. Two independent clocks agree: the central's wall clock, and the
board's own `t_ms` span (mean period 18.392 ms against the nominal 19.231 ms).
Across a 40 s capture and a 3-minute soak the figure landed at 54.37 and
54.21 Hz — stable, and stably wrong about 52.

The LSM6DSL derives its ODR from an internal RC oscillator, so the delivered rate
varies part to part and with temperature. **The nominal rate is what the sensor
was asked for, not what it produces.**

This is why the pacing decision matters more than the number. A 50 Hz timer would
not have been resampling a 52 Hz sensor, it would have been resampling a 54.4 Hz
one, at a ratio nobody could have predicted from the datasheet. Following the
data-ready line means the drift never has to be discovered.

Budget is unaffected: 54.4 Hz is **0.82** notifications per 15 ms connection event
against iOS's ~4, and 2.45 at a 45 ms interval — still comfortable everywhere.

Consumers should therefore treat the nominal rate as informational and derive
real timing from `t_ms`, which is measured rather than assumed. Anything
integrating gyro (#210) must use `t_ms` deltas; assuming a fixed 52 Hz `dt` would
accumulate a 4.6% attitude error that never washes out.

### No IMU

A board whose sensor is absent or fails to initialise does **not** go quiet. It
falls back to the skeleton's 1 Hz zero-filled frame, so the radio, the GATT
table, and the transmit counters all stay exercisable, and the failure is visible
from the phone as all-zero axes rather than as a dead link. The iOS decoder's
`isAxesZero` already carries precisely this meaning.

## Identity

Each board advertises a name derived from its nRF52840 FICR device ID:
`Sophon-XXXX`, where `XXXX` is four uppercase hex digits. The same firmware image
flashed to every board therefore produces a distinct, stable name.

The device ID is **not** in the frame. iOS already knows the source peripheral on
every notification callback, so per-sample identity would be redundant bytes at
52 Hz × N devices for zero information. Identity is a connect-time property.

Note the advertised name carries only 16 bits of the 64-bit FICR ID. That is
ample for a handful of boards; it is not a collision-proof identifier.

## Advertising layout

The advertisement and the scan response are **separate** 31-byte budgets, not one
shared pool. Every field costs 1 length byte + 1 type byte before its payload.
Flags + the 128-bit service UUID + the name is 34 bytes, so the name moves to the
scan response, which is also where everything a central can learn *without
connecting* now lives:

```
Advertisement (21 B of 31)        Scan response (26 B of 31)
  Flags                    3 B      Complete Local Name    2 + 11 B
  128-bit service UUID    18 B      TX Power               2 +  1 B
                                    Manufacturer Data      2 +  8 B
                                      Company ID       0xFFFF  2 B
                                      Scan rsp version   0x01  1 B
                                      Device type      0x0001  2 B
                                      HW version         0x01  1 B
                                      FW version major   0x02  1 B
                                      FW version minor   0x00  1 B
```

iOS active-scans by default, so `CBAdvertisementDataLocalNameKey`,
`CBAdvertisementDataManufacturerDataKey` and `CBAdvertisementDataTxPowerLevelKey`
all populate before connecting. 5 bytes remain.

The name row is its longest form. On the `hwinfo` fallback path the name is plain
`Sophon`, 5 bytes shorter, putting the scan response at 21 of 31.

### Manufacturer Specific Data

Company ID `0xFFFF` is the value reserved for internal/test use, which is what
applies without SIG membership. It is **not exclusive** — anyone may use it — so
matching it labels the payload, it does not identify the peripheral. The service
UUID does that.

`company_id` is first because the Core Spec Supplement defines AD type `0xFF` that
way: *the first 2 octets contain the Company Identifier, followed by additional
manufacturer specific data*. Note that Core Bluetooth returns the whole structure
including those 2 bytes, while `bleak` and some other stacks strip them into a
dictionary key — so the same wire bytes appear as 8 on iOS and 6 there.

`0xFFFF` reads the same in either byte order, so it can never catch an endianness
mistake. **Device type is the field that can**: `0x0001` must appear on air as
`01 00`.

### The version byte versions this structure only

Not the GATT contract, not the 18-byte frame. A byte claiming to version
everything would have to be bumped for changes it cannot describe.

**Fields are append-only and never reordered.** Parsers read the offsets they know
and ignore trailing bytes, so appending needs no bump — only changing the meaning
of an existing field does. That also makes an unrecognised version safe to parse,
since the known offsets still hold, so the app parses regardless and surfaces the
version rather than refusing.

The frame contract still has no version anywhere on the wire; see #231.

### Versions are display-only, and two of them can go stale

`SOPHON_HW_VERSION` is hand-maintained — nothing on the board can read its own
revision. The firmware version comes from `zephyr/sophon/VERSION` via Zephyr's
`APP_VERSION_MAJOR`/`_MINOR`, which is also a hand edit. Both are therefore
display-only: nothing branches on them, so a stale value misinforms rather than
misbehaves. The boot banner prints the version and a generated build timestamp so
staleness is visible on the console, where it will actually be read.

TX power is built from `CONFIG_BT_CTLR_TX_PWR_DBM`, the same symbol that sets the
radio, and currently reads **−4 dBm**, chosen in `prj.conf` by measurement rather
than by calculation: −16 dBm lost frames beyond ~1 m and −8 dBm still lost them at
desk range in line of sight. A free-space link budget had predicted ~8–10 m at
−16 dBm, wrong by about an order of magnitude. The XIAO's chip antenna,
the board lying on a desk, and 2.4 GHz congestion all cost more than the arithmetic
allows for. It
uses the standard AD type rather than a byte of ours so iOS fills
`CBAdvertisementDataTxPowerLevelKey` for free. Zephyr cannot insert it
automatically here — `BT_LE_ADV_OPT_USE_TX_POWER` requires extended advertising,
and Sophon uses legacy.

That coupling holds **only for TX power levels the radio actually has**. The
nRF52840's steps are +8, +7, +6, +5, +4, +3, +2, 0, −4, −8, −12, −16, −20, −40 dBm;
`hal_radio_tx_power_value()` rounds down to one of those while
`CONFIG_BT_CTLR_TX_PWR_DBM` keeps the number that was asked for. Selecting −1 dBm
therefore transmits at −4 while advertising −1. Since a central estimates distance
as `TX power − RSSI`, that error propagates into every scanner's distance
estimate. `prj.conf` lists the native steps for this reason.

### Connection policy must fail open

An absent or unrecognised device type means **connect anyway**. The decisive case
is the simulator: an iOS peripheral cannot advertise manufacturer data at all
(next section), so a simulated Sophon has no device type, ever, and any policy
requiring one would refuse every simulator. Boards not yet reflashed are the same.

Little is lost, because the scan is already filtered on the Sophon service UUID —
the field's real use is telling *variants* apart once more than one exists. Note
this rule is the **opposite** of #231's, deliberately: showing wrong motion as
good is worse than showing none, while hiding a working board is worse than
showing it unlabelled.

## Security

**No pairing.** `CONFIG_BT_SMP` is off, the link is unencrypted, and the
characteristic carries no encryption permission. The deciding factor is
development friction: iOS caches bonds aggressively, and a reflashed board loses
its keys while the phone still believes it is bonded, which requires a manual
*Forget This Device* on the phone after each flash.

Full reasoning, and the shape of the change if it is ever wanted, is in
UPDATED-PLAN.md.

## A second peripheral implementation

Since #226 this contract has **three** implementers, not two: the firmware, the
iOS decoder, and an iOS *encoder* — a simulator mode in the same app that lets an
iPhone advertise as a Sophon and stream its own CoreMotion data. It exists so app
work is not gated on the one board, and so #211 can be exercised with more than
one peripheral.

Changing the wire format now means changing three places. The encoder is
deliberately written directly beneath the decoder in `SophonProtocol.swift` so two
of the three are always visible at once, and both are checked at launch against
byte vectors transcribed from the table above rather than against each other.

The simulator honours the parts of this document that matter — frame layout, the
`seq` rules, the transmit counters, the read-only stats characteristic — but it is
**not** a substitute for hardware. Where it differs, and why:

| | Board | Simulator |
|---|---|---|
| ATT MTU | 23, negotiated down | **~515 measured** iOS-to-iOS; Core Bluetooth exposes no control |
| Connections | 1 (`CONFIG_BT_MAX_CONN=1`), and **invisible while taken** | several, simultaneously; iOS has no equivalent limit |
| `no_conn` | ~0 | ~0, same reason: nothing is sent unsubscribed |
| `no_mem` | real buffer exhaustion | **real, and frequent — measured at 8.80% of frames before #255 and 5.27% after.** The earlier claim that iOS's queue is generous enough that this "essentially never occurs" was wrong; the bench drop control was built on it and is not needed to exercise this path |
| Axes | the board's frame and sign convention | Apple's device frame — **the two will not agree in sign or axis order** |
| Manufacturer data | device type, hw and fw versions | **absent — an iOS peripheral cannot advertise manufacturer data at all.** `startAdvertising` honours only `CBAdvertisementDataLocalNameKey` and `CBAdvertisementDataServiceUUIDsKey`, and the scan response's extra space "can be used only for the local name". This is why connection policy must fail open |
| TX power | ours, from `CONFIG_BT_CTLR_TX_PWR_DBM` | **present, and iOS's own — measured at 12 dBm.** Not manufacturer data: it is the standard AD type `0x0A`, which iOS emits without being asked. The viewer labels it *device radio*, because the value is real but is the phone's, and `TX power − RSSI` therefore means something different than it does for a board (#246) |
| Link Params | reported from `bt_conn_get_info()` | **absent — the characteristic is not offered.** `CBPeripheralManager` has no API for connection parameters either, so an iOS peripheral cannot see what it was granted any more than an iOS central can. The rows simply do not appear |
| `t_ms` | since board boot | since simulator start |
| Rate, generated | 52 Hz nominal, **~54.3** measured | 52 Hz requested, **50.0** measured — CoreMotion quantises the 19.23 ms interval up to 20 ms |
| Rate, delivered | ~54.3 — refusals are near zero | **~47.4 measured.** Generation and delivery are the same number on the board and are *not* on a simulator, which is why they are now separate rows |
| Sample arrival | hardware DRDY, even | **clumped: 0.2 – 55.3 ms around a 20 ms mean.** The average is exactly right for 50 Hz and says nothing about the distribution |
| Transmit queue | 8-deep `k_msgq`, drained on the system work queue | 8-deep, **paced** at one to two frames per ~20 ms tick (#255). Depth matches deliberately. The pacing does not: the firmware's drain empties the queue in one `while` loop, which is safe only because DRDY is even |

### What a simulator can and cannot put on the air

Worth stating precisely, because conflating two different limits produced a wrong
claim in this document. **What this app can set** and **what reaches the air** are
not the same set.

`CBPeripheralManager.startAdvertising` accepts only `CBAdvertisementDataLocalNameKey`
and `CBAdvertisementDataServiceUUIDsKey`. Everything the Sophon protocol adds — the
company ID, device type, hardware and firmware versions — travels as Manufacturer
Specific Data, which is why none of it can come from a simulator.

**TX power is not in that group.** It is the standard AD type `0x0A`, and iOS emits
one on its own account, measured at 12 dBm. So a simulator does advertise a TX
power; it is simply the phone's radio rather than a Sophon's. The viewer labels it
*device radio*, distinguishing it by the absence of manufacturer data beside it —
since #230, a board reporting one always reports the other.

The earlier version of the table said a simulator advertises "none of it",
including TX power. That was wrong, and it was contradicted by the app's own
screen: the viewer displayed a TX power for a simulator while a footer directly
beneath denied it was possible.

Measured on iOS 26, `advertisementData` also carries three **undocumented** keys —
`kCBAdvDataTimestamp`, `kCBAdvDataRxPrimaryPHY`, `kCBAdvDataRxSecondaryPHY` — on
every peripheral, board included. They are **reception metadata**, not AD types:
when iOS saw the packet and which PHY it arrived on, nothing the peripheral sent.
Mistaking iOS's own additions for the peripheral's output is precisely the error
that produced #246, so they are named here rather than left to be rediscovered.

Notably **absent**: any key saying whether a callback carried the advertisement or
the scan response. Core Bluetooth genuinely does merge those, which is what the
single-structure design above depends on.

**This is still a floor, not a picture.** Everything above comes from the keys iOS
chose to parse and surface through `advertisementData`. The raw AD structures have
never been observed — nRF Connect and `bleak` are both CoreBluetooth-backed and
show the same parsed view. Seeing the bytes needs an observer outside the platform
(#252).

### A simulator is not a stand-in for the board when measuring loss

#226's premise is that app work can proceed without a board. That holds for the
wire format, the UI and the protocol contract. It does **not** hold for anything
measuring loss, gaps or attribution.

The board loses essentially nothing. A simulator lost **8.80%** of generated
frames before #255 and **5.27%** after — not on the air, but refused by iOS before
transmission. The mechanism was measured rather than guessed: CoreMotion delivers
clumped, and until #255 the simulator forwarded those clumps straight to
`updateValue` with no buffer, so bursts overflowed a queue the link could
otherwise have kept up with.

Any figure gathered against a simulator therefore carries an artefact the board
does not have. Two known casualties: the earlier `no_mem` row in the table above,
and the framing of #248, which spent three hypotheses on the wrong mechanism.

**The residual 5.27% is not understood.** It is intermittent — gaps between queue
drains range from 41.8 ms to 8.8 s — and it differs between iOS devices, which
points at scheduling rather than link throughput. It was twice mistaken for a
per-event capacity ceiling by reading an average without checking its
distribution; a ceiling requires a saturated queue, and this queue is idle for
seconds at a time. Do not repeat that inference.

Attributing it needs a view of the link itself, which no endpoint can provide:
Core Bluetooth reports *that* a frame was refused and never *why*. That is what
#251, #252 and #254 exist for.

The connections row has a consequence worth stating outright, because it looks like
a fault the first time it happens. **A connected board stops advertising**, and a
central cannot see a peripheral that is not advertising. So with two viewers and one
board, the first to connect gets it and the second shows *nothing at all* — not a
greyed-out row, not "busy", nothing. There is no BLE signal to distinguish "taken"
from "powered off", and no amount of app-side work can invent one.

Advertising restarts only on disconnect (`adv_work` in `ble.c`), so releasing the
board means disconnecting the holder, or closing the app on it. Note the simulator
behaves the *opposite* way and will happily serve both viewers at once, so a
multi-device test that mixes a board with simulators will not behave uniformly.

The MTU row is the one that matters most for #211: **the "one sample is exactly
one radio packet" property that shaped this format does not hold between two iOS
devices.** The simulator is a way to exercise logic and timing, not to measure
radio capacity.

The axis row matters for #210: fusion developed against the simulator will need
its signs checked against a real board before it can be trusted.

So does the rate row, and in a way that is easy to miss. The board runs about 4%
**fast** and the simulator about 4% **slow**, which puts them roughly **8% apart
from each other** while both claim 52 Hz. Anything that batches, aligns or
integrates across the two must key off `t_ms` rather than a nominal rate — the
same conclusion #209 reached from one device, now with a second data point that
misses in the opposite direction.

## Known gaps

- **No common time base.** `t_ms` is relative to each board's own boot. Adequate
  for sensor fusion, which needs only intra-device `dt`; insufficient for aligning
  two Sophons to the same instant. Tracked in #211.

## Designed scaling path

The frame is fixed-size and sequence-numbered specifically so that batching is
possible without a format change: send *k* × 18 bytes and the decoder splits on
18-byte boundaries. That is a peripheral-side config change only — iOS offers far
more than the frame needs at negotiation.

**Measured correction.** The planning documents put iOS's negotiation ceiling at
**185 bytes**, taken from published findings that predate current iOS. An
iOS-to-iOS link between the simulator and the viewer negotiated **~515**. So iOS
is not the 185-byte ceiling those documents describe, and any figure derived from
that number needs re-deriving rather than trusting.

What does *not* change is the conclusion built on it: the ATT MTU was never the
binding constraint. A link-layer payload is 251 bytes at most even with DLE, so a
large ATT PDU still fragments across link-layer packets, and raising the MTU
without raising DLE returns a fraction of the benefit. The reasoning stands; only
the number was wrong. Read the real value off the app's ATT MTU row rather than
assuming either figure.

Batching is deliberately **not** done at N=1: it trades latency
(`(k−1)/f`, i.e. ~58 ms at k=4 and 52 Hz) for connection-event occupancy, and at one
device there is no occupancy pressure to relieve. It becomes correct around N≥4.

When it happens, the ATT MTU and DLE must be raised **together** — raising the MTU
alone fragments a 4-sample batch into 3 link-layer packets and returns about a
quarter of the benefit. Tracked in #211, which carries the exact Kconfig.
