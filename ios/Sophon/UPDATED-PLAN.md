# Sophon — project skeleton (Zephyr BLE peripheral + iOS central)

> **The current plan.** Supersedes [`ORIGINAL-PLAN.md`](ORIGINAL-PLAN.md), which
> stays frozen as the record of what was approved before implementation began.
>
> Same design, with the API-level details corrected against Zephyr 4.4 and
> Xcode 26 as actually built. The analysis is unchanged: the ATT MTU budget, the
> connection-event capacity model, the batching-vs-DLE arithmetic, and the
> freestanding-app reasoning all stand as written.

## Context

A new sub-project in the `firstcontact` repo: a **Seeed XIAO nRF52840 Sense Plus**
strapped to a moving object, streaming its IMU over BLE to an iPhone that
visualizes the motion in real time.

Named **Sophon** — Cixin Liu's proton-scale probe that sits inside what it
observes and relays continuously to a distant receiver. Same object as the thing
being built, and it lands the `firstcontact` repo theme.

This first issue is **skeleton only**, per the chosen scope. The risky, unfamiliar
parts of a new embedded + mobile pair are the build plumbing, the BLE bring-up,
and the two halves agreeing on a wire format — not the IMU read or the 3D render.
So the deliverable is: **firmware advertises, phone finds it, connects,
subscribes, and counts frames arriving.** Real IMU data and the visualization land
in follow-up issues, against a wire format that is fully specified now.

Four issues, referred to by letter throughout this document (full titles and
filing details under [Issues and branching](#issues-and-branching)):

| | Scope |
|---|---|
| **A** | **this work** — skeleton: build plumbing, BLE bring-up, wire format, connect + subscribe |
| **B** | real 6-axis IMU data at 50 Hz, filling the frame A defines |
| **C** | 3D orientation view + live axis charts on the phone |
| **D** | multi-device scale — batched frames + DLE, and a cross-device time base |

### Hardware / toolchain facts established during planning

| Fact | Value | Source |
|---|---|---|
| Board target | `xiao_ble/nrf52840/sense` | no `plus` variant upstream; Plus adds 9 GPIOs only |
| IMU | LSM6DS3TR-C @ I2C `0x6a`, driver `st,lsm6dsl`, IRQ on `gpio0 11` | [`xiao_ble_nrf52840_sense.dts:40`](file:///Users/vwong/zephyrproject/zephyr/boards/seeed/xiao_ble/xiao_ble_nrf52840_sense.dts) |
| IMU is identical on Sense vs Sense Plus | confirmed | Seeed wiki / product page |
| IMU power rail | `regulator-fixed` on `gpio1 8`, needs `CONFIG_REGULATOR=y` (already in board defconfig) | same dts |
| LEDs | `led0` red / `led1` green / `led2` blue, all **active-low** | `xiao_ble_common.dtsi` |
| Console | USB CDC ACM is the board's `chosen` console — **the XIAO has no UART-to-USB bridge**, so USB is the only console | `boards/common/usb/cdc_acm_serial.dtsi` |
| Flashing | Adafruit UF2 bootloader; `west flash -r uf2` with `--board-id=Seeed_XIAO_nRF52840_Sense` | `boards/seeed/xiao_ble/board.cmake` |
| Zephyr | 4.4.99, SDK 1.0.1 (`arm-zephyr-eabi`), venv at `~/zephyrproject/.venv` | `~/zephyrproject/README.md` |
| `xcode-select` | already `/Applications/Xcode.app/…` — **no `sudo` switch needed** | verified |

### Two gotchas worth knowing before starting

1. **`west` cannot run from inside this repo.** It walks *up* from `cwd` looking
   for `.west/` and fails from `~/repos/firstcontact`. Its own error message names
   the fix: set `ZEPHYR_BASE`. A wrapper script handles this so nobody has to
   remember (see `scripts/build.sh` below).
2. **`west flash -r uf2` may not find the volume.** The runner matches board-id
   `Seeed_XIAO_nRF52840_Sense`; the *Sense Plus* bootloader may report a different
   string. Fallback is a plain `cp build/zephyr/zephyr.uf2 /Volumes/<VOL>/`. The
   README will document both, and the real board-id gets recorded once observed.

---

## Wire format and BLE capacity

*The frame layout is the contract between the two halves; the sections after it
derive why it is shaped that way and where it runs out.*

### The frame

Documented in `zephyr/sophon/PROTOCOL.md`, referenced from both sides. **18 bytes,
little-endian** — deliberately ≤20 so it fits the default 23-byte ATT MTU with no
negotiation required.

| Offset | Size | Type  | Field | Units |
|---|---|---|---|---|
| 0  | 2 | `u16` | `seq`  | frame counter, wraps |
| 2  | 4 | `u32` | `t_ms` | ms since boot |
| 6  | 2 | `i16` | `ax`   | milli-g |
| 8  | 2 | `i16` | `ay`   | milli-g |
| 10 | 2 | `i16` | `az`   | milli-g |
| 12 | 2 | `i16` | `gx`   | centi-deg/s |
| 14 | 2 | `i16` | `gy`   | centi-deg/s |
| 16 | 2 | `i16` | `gz`   | centi-deg/s |

At the eventual 50 Hz this is ~900 B/s — comfortably inside BLE throughput.

### Why 18 bytes — the ATT MTU budget

A notification does not get the full ATT MTU; three layers each take a cut. At
Zephyr's **defaults, unchanged**:

```
Link-layer packet payload        27 bytes    CONFIG_BT_BUF_ACL_TX_SIZE, default 27
  − L2CAP header                  4
  − ATT opcode + handle           3
  ──────────────────────────────────────
  = usable characteristic value  20 bytes
Sophon frame                     18 bytes    (2 spare)
```

So **one IMU sample is exactly one radio packet** — no L2CAP fragmentation and no
reassembly logic on either side.

The MTU is negotiated as `min(central proposal, peripheral maximum)`:

| | Value |
|---|---|
| iOS proposes (iOS 10+; 158 before) | 185 — **stale, see below** |
| Zephyr `CONFIG_BT_L2CAP_TX_MTU` default | **23** ← binding constraint |
| Negotiated result | 23 |

iOS asking for more than 23 buys nothing unless the peripheral's config is raised
too. Staying at 23 is deliberate, and that part is unaffected by what follows.

> **Measured correction, 2026-08-24 (#226).** The 185 above comes from published
> findings that predate current iOS, and it is **wrong for current iOS**. An
> iOS-to-iOS link — the simulator advertising to the viewer — negotiated **~515**.
> The board never reveals iOS's offer, because Zephyr's 23 wins the `min()`, which
> is why this went unnoticed until a second iOS device was on the other end.
>
> **Every figure in this document derived from 185 needs re-deriving before #211
> acts on it** — the ⌊182 / 18⌋ = 10 samples per PDU, the fragmentation counts, and
> the "iOS is the real ceiling" claim in the Kconfig section.
>
> The *conclusion* those figures support is not in doubt: the ATT MTU was never
> the binding constraint. A link-layer payload is at most 251 bytes even with DLE,
> so a large ATT PDU still fragments and raising the MTU without DLE returns a
> fraction of the benefit. That argument survives a bigger MTU intact — it gets
> stronger, since the gap between ATT capacity and link-layer capacity widens.
>
> Left annotated rather than rewritten on purpose. Re-deriving an analysis from a
> single observation, on a document that is the basis for #211, would trade a known
> wrong number for an unverified set of new ones.

#### No pairing — and why the 65-byte footnote exists

`BT_L2CAP_TX_MTU` defaults to **65** instead of 23 the moment `BT_SMP` is enabled.
That is not a round number: LE Secure Connections does an ECDH P-256 exchange, and
the SMP `Pairing Public Key` PDU is `1 opcode + 32 B X + 32 B Y = 65 B`. Enabling
pairing would therefore silently change the MTU analysis above — harmlessly (62-byte
notify budget instead of 20; the 18-byte frame is unaffected), but not obviously.

**Sophon does not pair.** Four reasons, in order of weight:

1. **Development friction, which is decisive.** iOS caches bonds aggressively.
   Reflash the board and its keys are gone while iOS still believes it is bonded —
   reconnection then fails with an encryption error, usually as an immediate silent
   disconnect. The only fix is manual, on the phone: *Settings → Bluetooth → ⓘ →
   Forget This Device*. Without `BT_SETTINGS` that happens on every **reboot**; with
   it, every `-p always` build or chip-erase flash. On a board reflashed several
   times an hour during bring-up, that is a recurring manual step on a *separate
   device*.
2. **Just Works is the only method available.** The association model derives from
   declared IO capabilities, and the XIAO has no display or keyboard →
   `NoInputNoOutput` → Just Works → encryption with **no MITM protection**. The
   real gain is passive-eavesdropper resistance only. (NFC OOB is theoretically
   possible on nRF52840; not a serious option for accelerometer data.)
3. **The threat model does not ask for it.** The data is how an object is moving,
   the attacker must be in radio range, and the service UUID is a random 128-bit
   value nobody else scans for.
4. **Identity does not need it.** The FICR-derived advertised name already
   distinguishes boards, so the multi-device design creates no reason to bond.

The one non-security consideration is a rogue central connecting and occupying the
slot (the peripheral stops advertising once connected), which requires someone to
deliberately target that specific UUID.

If it is ever wanted, the shape is `CONFIG_BT_SMP=y` (the Security Manager
Protocol — the host-side machinery for pairing and link encryption; this is the
master switch the rest depend on) + `BT_SMP_SC_ONLY=y` (reject eavesdroppable LE
Legacy pairing) + `BT_SETTINGS`/`SETTINGS`/`NVS`/`FLASH_MAP` to persist bonds,
plus `BT_GATT_PERM_READ_ENCRYPT` on the characteristic (refuse reads/notifies on
an unencrypted link) and a `bt_conn_auth_cb` (the callback set through which the
association model is driven). **Note `BT_BONDABLE` defaults to `y`** — enabling SMP opts into
bonding unless explicitly disabled.

**Why not raise the MTU and batch samples.** At MTU 185 the characteristic value
capacity is `185 − 3 = 182` B, so `⌊182 / 18⌋ = 10` samples would ride in one
notification — the ceiling iOS permits, worked through on air under *DLE* below.
Rejected because:

- **Latency.** Buffering `k` samples costs `(k−1)/f` on the *first* sample in each
  batch (the last waits zero). 10 samples at 50 Hz is **180 ms** worst case, 90 ms
  average — on a live 3D orientation view that is the difference between the model
  feeling welded to the board and chasing it. Batching suits a *logging* device;
  this is a *visualization* device.
- **It doesn't pay without DLE.** A 185-byte ATT PDU still fragments into 7
  link-layer packets unless Data Length Extension is enabled as well (see below).
  Half-doing it costs the latency and returns little of the efficiency.
- **RAM.** Larger MTU means larger ACL TX/RX buffers, on a part where the BLE
  stack is already the dominant RAM consumer.

### Where the real ceiling is — the connection-event budget

Throughput is bounded by the *connection interval*, not the MTU. The useful unit
is **notifications needed per connection event**, not bytes or packets per second.

**Air time is exact** (LE 1M PHY, 1 bit = 1 µs; packet = 10 bytes of overhead —
preamble 1, access address 4, header 2, CRC 3 — plus payload):

```
Our notification: 18 B frame + 3 ATT + 4 L2CAP  = 25 B LL payload
  on air                       (10 + 25) × 8 µs = 280 µs
Central's empty PDU              (10 + 0) × 8 µs =  80 µs
T_IFS (spec-mandated), ×2                        = 300 µs
                                                 ─────────
one notification + its ack slot                  = 660 µs
```

A 15 ms connection event therefore has room for `15 ms ÷ 660 µs ≈ **22**`
notifications by physics. **Physics is not the constraint — iOS's per-event packet
policy is.** Apple does not document it; the community figure is **~4–6 packets per
connection event**, and Punch Through's finding that iOS delivers a full 185-byte
ATT PDU (7 LL fragments) in one interval is consistent with the upper end. Treat
**4** as the planning number — a ~5.5× discount on what the radio could carry, and
the entire reason this has to be planned against policy rather than air time.

So the argument is **supply vs demand, both in notifications per connection event**:

| | notifications / event |
|---|---|
| Supply — physics ceiling (15 ms ÷ 660 µs) | 22 |
| Supply — iOS policy | **≈ 4** ← binding |
| Demand — 50 Hz at a 15 ms interval | **0.75** |
| **Headroom** | **≈ 5.3×** |

**Reading the demand figure.** It is `rate × interval`, and the units resolve to a
count per event, not a duration — the connection interval is *seconds per
connection event*, so the seconds cancel and the "per event" survives:

```
   samples         seconds           samples
   ───────    ×    ───────      =    ───────
   second           event             event

50 samples/s  ×  0.015 s/event  =  0.75 samples/event
```

Equivalently, as a division: `1 / 0.015 s = 66.7 events/s`, then
`50 samples/s ÷ 66.7 events/s = 0.75 samples/event`. (The familiar form is
*rate × duration = count*, which makes "interval" look like a plain elapsed time.
It isn't — that's the easy misread here.)

Demand across the range iOS might grant:

| Sample rate | 15 ms interval | 30 ms | 45 ms |
|---|---|---|---|
| **50 Hz** (planned) | **0.75** ✓ | **1.5** ✓ | **2.25** ✓ |
| 100 Hz | 1.5 ✓ | 3.0 ✓ | 4.5 ⚠ |
| 200 Hz | 3.0 ✓ | 6.0 ⚠ | 9.0 ✗ |

**You pick the row; iOS picks the column.** Apple's accessory guidance is multiples
of 15 ms with a 15 ms floor, and iOS frequently settles above the floor — the
interval is granted, not requested. So a chosen sample rate has to stay inside
budget across its **entire row**, not merely in the 15 ms column.

**This is why 50 Hz is the right target.** It needs under one notification per
connection event even at 15 ms, and stays inside a budget of 4 across every
plausible interval. It is not close to any edge. 200 Hz, by contrast, is fine only
if iOS grants 15 ms and is at the ceiling by 30 ms — which is exactly the kind of
thing that works on the bench and fails in a room with other Bluetooth traffic.

### What actually degrades with N devices

Aggregate radio duty cycle is **not** the binding constraint, and it is worth being
precise about that rather than hand-waving "bandwidth." One device at 50 Hz costs
`0.75 × 660 µs ≈ 500 µs` per 15 ms event — about **3% of the radio timeline**.
Eight devices is ~27%. On duty cycle alone, eight boards is comfortable.

What breaks is **scheduling**. Each connection has its own anchor point recurring
every interval, and connection events **cannot overlap** — the radio serves one at
a time. With N connections iOS must pack N non-overlapping slots into every
interval window, sized conservatively for the worst case rather than actual usage,
with anchors drifting relative to one another. It is a bin-packing problem, and
iOS's response as it tightens is to **lengthen connection intervals** — which walks
every device rightward across the table above simultaneously.

Two consequences worth designing around:

1. **Don't compute a max-N; measure it.** The falloff depends on iOS version,
   device, and whatever else holds a connection — it is not derivable. The
   skeleton's per-device `framesReceived` and `seqGaps` counters are what turn the
   arrival of boards 3, 4, 5 into an observation instead of a guess. That is a
   second reason they are in the skeleton rather than issue C.
2. **Batching helps for a better reason than byte overhead.** It reduces the number
   of *connection events* a device needs, and event slots — not bytes — are the
   scarce resource under N-device scheduling. This is the mechanism behind the N≥4
   inversion below, and it has a catch worth knowing before issue D is scoped.

### Batching arithmetic — and why it is one decision with DLE, not two

Batching does not change the sample rate, only how many samples ride per
notification:

```
sample rate                    50 samples/s          (unchanged)
batch factor                    4 samples/notification

notification rate  =  50 samples/s ÷ 4 samples/notif  =  12.5 notif/s
demand             =  12.5 notif/s × 0.015 s/event    =  0.1875 notif/event
```

i.e. simply `0.75 ÷ 4`. **But notifications are not packets, and packets are what
the scheduler places.** Four samples fragments into three:

```
Sophon frame  18 B × 4                    =  72 B   ATT characteristic value
  + ATT header   (opcode 1 + handle 2)    +   3
  ────────────────────────────────────────────────
  ATT PDU                                 =  75 B   ← BT_L2CAP_TX_MTU bounds THIS
  + L2CAP header (length 2 + CID 2)       +   4
  ────────────────────────────────────────────────
  L2CAP PDU                               =  79 B   ← this is what fragments
       ↓  ÷ LL payload capacity 27 B,  ⌈79 / 27⌉ = 3
  LL payloads    27 + 27 + 25             =  79 B
```

Two things this diagram is guarding against, both easy to get backwards:

1. **The L2CAP header is outside the ATT MTU.** `BT_L2CAP_TX_MTU` bounds the *ATT
   PDU* (75), not the L2CAP PDU (79). Zephyr's own defaults are the proof:
   `BT_BUF_ACL_TX_SIZE` defaults to **27** and `BT_L2CAP_TX_MTU` to **23** — that
   4-byte gap *is* the L2CAP header. So the requirement is `≥ 75`, never 79.
2. **The L2CAP header is counted once, not per fragment.** The PDU is split with
   the header only on the first packet; continuation fragments are flagged by the
   LLID field. Charging 4 bytes to every packet yields 4 fragments instead of 3.

That 3 is what turns notification rate into packet rate:

```
50 samples/s  ÷  4 samples/notif   =  12.5 notif/s
12.5 notif/s  ×  3 packets/notif   =  37.5 packets/s     ← the no-DLE column
37.5 packets/s × 0.015 s/event     =  0.5625 ≈ 0.56 packets/event
```

Radio time follows the same fragment count, since connection events strictly
alternate central↔peripheral and every fragment needs its own central packet and
both inter-frame spaces:

```
frag 1:  central 80 + peripheral (10+27)×8 = 296 + T_IFS×2 300  =  676 µs
frag 2:  same                                                    =  676 µs
frag 3:  central 80 + peripheral (10+25)×8 = 280 + T_IFS×2 300  =  660 µs
                                       per batched notification    2012 µs
                       × 12.5 notif/s  =  25,150 µs/s  ≈  25 ms/s
```

Each fragment is a full central↔peripheral exchange, so it carries **two** 150 µs
gaps — one on each side of the peripheral's packet — matching the `T_IFS
(spec-mandated), ×2` line in the unbatched calculation above. Frag 3 is identical
to the unbatched notification (660 µs), which is the check that the two
derivations agree.

versus **1092 µs** with DLE (one 79-byte packet: `80 + (10+79)×8 = 712 + T_IFS×2
300`) — which is the entire 25%-vs-59% gap in a single line.

All three configurations side by side:

| per device @ 50 Hz, 15 ms | unbatched | batch 4×, no DLE | batch 4× + DLE |
|---|---|---|---|
| notifications/s | 50 | 12.5 | 12.5 |
| LL packets per notification | 1 | **3** | 1 |
| LL packets/s | 50 | 37.5 | 12.5 |
| notif/event | 0.75 | 0.19 | 0.19 |
| **packets/event** | **0.75** | **0.56** | **0.19** |
| radio time/s | 33 ms | 25 ms | 14 ms |
| required `BT_L2CAP_TX_MTU` | 23 (default) | ≥ 75 | ≥ 75 |
| added latency `(k−1)/f` | 0 | 60 ms | 60 ms |

**The headline 4× only holds in the last column.** Batching alone buys 0.75 → 0.56
(~25%); reaching 0.19 needs DLE alongside the MTU bump. Issue D must therefore
raise **MTU *and* DLE together** — treating them as separate steps would ship the
latency cost while collecting a quarter of the benefit.

**`BT_SMP` is orthogonal to this table — it appears in no column.** It changes the
MTU *default*, not any capability, so it may be `n` or `y` throughout:

- *Unbatched* does not require `BT_SMP=n`. The 18-byte frame is 25 B at L2CAP and
  fits the 27-byte LL payload whether the MTU is 23 or 65. The MTU is permission to
  send bigger, not a change to what is sent.
- *Batched* is not helped by `BT_SMP=y`. Batching needs MTU ≥ 75; SMP's default is
  **65**, short of it, so `BT_L2CAP_TX_MTU` is set explicitly either way.

Its costs are flash/RAM for SMP + ECC, the bring-up friction above, and a small
throughput one that is easy to miss: **encryption appends a 4-byte MIC to every LL
packet**. Capacity is unaffected — the 27/251 payload limits exclude the MIC and the
Length field accommodates it (31 and 255) — but air time is not:

```
unencrypted   (10 + 25)     × 8 = 280 µs   →  660 µs with ack + IFS
encrypted     (10 + 25 + 4) × 8 = 312 µs   →  692 µs        ≈ +5%
```

33 → ~34.6 ms/s of radio time at 50 Hz. Irrelevant at N=1; not nothing when
connection-event occupancy is the scarce resource at N devices.

#### DLE — what it is, and the Zephyr knob that actually controls it

**Data Length Extension** is a Bluetooth 4.2 link-layer feature. Before 4.2 the LL
packet payload was capped at **27 bytes** — the constant behind every `⌈79 / 27⌉`
above. 4.2 added the *LE Data Length Update* procedure: after connecting, the two
sides exchange `LL_LENGTH_REQ`/`LL_LENGTH_RSP` and agree a larger maximum, up to
**251 bytes** (255 from the 8-bit length field, less 4 for the encryption MIC).

It pays because every packet carries fixed overhead regardless of size — 10 bytes
of framing, two 150 µs inter-frame gaps, and the central's reply. At 27-byte
payloads that dominates; at 251 it amortizes away.

**DLE is not the ATT MTU.** Different layers, and conflating them is the usual
error:

| | Layer | Governs | Knob |
|---|---|---|---|
| **ATT MTU** | Host / L2CAP | how big one ATT PDU may be — whether 72 bytes can be *sent* at all | `BT_L2CAP_TX_MTU` |
| **DLE** | Controller / link layer | how big one *radio packet* may be — whether that PDU flies as 1 packet or 3 | ACL buffer sizes |

Raise MTU alone → the batch sends but fragments into 3 packets (the 25% case).
Raise DLE alone → nothing, ATT will not build a PDU that large. Hence one decision.

**In Zephyr you do not set the DLE symbols directly.** `BT_CTLR_DATA_LENGTH` is a
*hidden* option with no prompt, and `BT_CTLR_DATA_LENGTH_MAX` is derived. The
cascade (verified in `subsys/bluetooth/Kconfig:179` and
`subsys/bluetooth/controller/Kconfig:602`):

```
CONFIG_BT_BUF_ACL_TX_SIZE=251     ← the only knobs actually set
CONFIG_BT_BUF_ACL_RX_SIZE=251
      ↓  default y if (either > 27)
BT_DATA_LEN_UPDATE=y              ← automatic
      ↓  hidden, default y, depends on the above
BT_CTLR_DATA_LENGTH=y             ← automatic
      ↓  default BT_BUF_ACL_RX_SIZE if ≤ 251
BT_CTLR_DATA_LENGTH_MAX=251       ← automatic
```

The cost is **RAM** — those buffers go 27 → 251 bytes each and there are several,
which is precisely why the skeleton does not enable it speculatively.

**Set 247, not the exact requirement.** The table's `≥ 75` is the true minimum for
a 4-sample batch, but issue D should not set 75:

```conf
CONFIG_BT_L2CAP_TX_MTU=247      # 251 − 4: one ATT PDU exactly fills one max LL packet
CONFIG_BT_BUF_ACL_TX_SIZE=251
CONFIG_BT_BUF_ACL_RX_SIZE=251
```

75 encodes "exactly 4 samples of exactly 18 bytes" and has to be recomputed the
moment the batch factor moves (5 samples → 93). And **247 is not arbitrary**: it is
`251 − 4`, sized so a full ATT PDU fills a maximally-sized LL packet with no
fragmentation and no waste — which is why it recurs throughout Zephyr BLE configs.

**iOS is the real ceiling, not this config.** It caps negotiation at 185 whatever
the peripheral offers, so the practical outcome is:

```
negotiated ATT MTU              185 B   ← bounds the ATT PDU
  − ATT header (opcode + handle)   3
  = value capacity              182 B   →  ⌊182 / 18⌋ = 10 samples per notification

what 10 samples actually costs on air:
  10 × 18 B                     180 B   value sent (182 − 180 = 2 B unused)
  + ATT header                     3
  = ATT PDU                     183 B
  + L2CAP header                   4
  = L2CAP PDU                   187 B   →  one 251-byte LL packet with DLE;
                                           ⌈187 / 27⌉ = 7 fragments without
```

That 7 is exactly Punch Through's published fragment count for iOS, which is a
useful independent check that this whole model is right. The 10 is the same figure
quoted back in *Why not raise the MTU and batch samples* — **the max batch factor,
set by iOS's 185-byte negotiation cap, not by anything chosen here.**

One nuance that feeds back into multi-device scheduling: large packets are
efficient but **long**, and a packet in flight cannot be preempted. A full 251-byte
packet holds the radio for `(10+251)×8 = 2088 µs ≈ 2.1 ms`. The 79-byte batch is
712 µs, nowhere near that — but it means "max out DLE" is not automatically right
at high N, where short slots pack better.

Whenever batching becomes necessary, the escape hatch is already in the format: the
frame is **fixed-size and carries `seq`**, so batching is "send *k*×18 bytes" and
the decoder splits on 18-byte boundaries. Raising `BT_L2CAP_TX_MTU` and the ACL
buffer sizes is then a **peripheral-side config change only** — iOS
already offers 185 and absorbs the rest at negotiation. No wire-format change, no
version negotiation, no change to the decoder's assumptions.

## Designed for multiple Sophons

The end state is several boards streaming to one iPhone at once. That doesn't
change the wire format, but it does change two things that are cheap now and
expensive after the view layer exists — both are folded into this skeleton.

**Identity.** Every board flashes the same image, so all would advertise
`"Sophon"`. Nothing is lost at the transport layer — `CBPeripheral.identifier` is
distinct per device and `didUpdateValueFor` hands back the peripheral — but the UI
would show *N* identical rows, and that identifier is **generated by iOS, not the
device**, so it differs per iPhone and can't be a label written on a sticker.

Fix: a per-chip ID from the nRF52840's FICR via `hwinfo_get_device_id()`
(`CONFIG_HWINFO=y`; driver confirmed at `drivers/hwinfo/hwinfo_nrf.c`), advertised
as **`"Sophon-A3F2"`**. Same image on every board, unique name automatically, and
they become tellable apart in nRF Connect during bring-up.

The device ID **stays out of the frame**. iOS already knows the source peripheral
on every callback, so putting it in each sample is redundant bytes at 50 Hz × *N*
for zero information. Identity is a connect-time property, not a per-sample one.

**Scheduling caps *N*, not the connection limit** — derived in full under "What
actually degrades with N devices" above. Apple publishes no connection limit and
field reports span 6–20 by device and iOS version, so nothing should be designed
against a number; and the limit that bites first is connection-event scheduling,
not that count. iOS absorbs pressure by lengthening intervals, which degrades every
connected device at once rather than refusing the next one.

This inverts the earlier MTU decision at scale: **batching, correctly rejected for
N=1, becomes correct at N≥4** — because it reduces *connection events*, which is
the scarce resource under multi-device scheduling. Four samples per notify takes a
board from 0.75 packets per event to 0.19 (**with DLE — see the batching arithmetic
above; without it the figure is 0.56**), and the 60 ms of added latency is a fair
trade when watching eight things instead of one. `PROTOCOL.md` documents
this as **the designed scaling path**, not a footnote — it is why the frame is
fixed-size and sequence-numbered.

**Known gap: no common time base.** Each `t_ms` is milliseconds since *that*
board's boot. Fine for fusion, which only needs intra-device `dt`; useless for
aligning two Sophons to the same instant. Solving it needs either iOS arrival
timestamps (BLE *scheduling* jitter dominates, tens of ms) or a real sync — write
`t0` at connect, device reports offsets. Out of scope here, recorded in
`PROTOCOL.md` so it is a known gap rather than a surprise.

**The firmware does not scale-change at all.** Each Sophon is an independent
peripheral holding one connection (`BT_MAX_CONN=1`). Flash the same image *N*
times.

**In this skeleton, `seq` and `t_ms` are live and the six axis fields are zero.**
The frame is the contract; filling it is the next issue. Notify rate is 1 Hz here
(not 50) so the link state is readable by eye during bring-up.

> This 1 Hz zero-filled heartbeat is slightly more than "advertises + connects".
> It is included because it makes the subscribe path verifiable end-to-end for
> ~10 lines of C, and it is the only way the iOS side can prove its notify
> handler works before the IMU exists. **Say so and I'll drop it** — the rest of
> the skeleton stands without it.

**UUIDs** — generated with `uuidgen` at implementation time, then frozen and
recorded in `PROTOCOL.md`. Base UUID `B`, with the first 32-bit group carrying the
role:

```
Sophon Motion Service   C6560001-84D5-4DC2-8C1E-4B4EB2337CE4   in the adv payload
Motion Data (notify)    C6560002-84D5-4DC2-8C1E-4B4EB2337CE4   18-byte frame, + CCC
```

---

## Part 1 — `zephyr/` target

### Where the app lives, and why

Zephyr defines three application types (`doc/develop/application/index.rst:100`):
**repository** (inside `zephyr/` itself — upstream samples only), **workspace**
(inside a west workspace, outside `zephyr/`), and **freestanding** (outside any
workspace). Sophon is **freestanding** — the docs' own diagram for that type is
`<home>/zephyrproject/` next to `<home>/app/`, which is exactly this shape.

This is a deliberate choice forced by the monorepo, not the default. The modern
convention for a standalone Zephyr project is **T2 topology** — the app repo
carries a `west.yml` and `west init -m <repo>` builds a workspace *around* it.
Both ways of doing that here are worse:

| Approach | What actually happens |
|---|---|
| `west init -m <firstcontact> --mf zephyr/sophon/west.yml ~/ws` | west clones **firstcontact a second time** inside the workspace. Two working copies of a repo that also holds `webapp/` and `ios/`, with Vercel and Xcode pointed at the other one. |
| `west init -l ~/repos/firstcontact` | `west init --help`: "`.west` is created next to *directory*". Workspace root becomes **`~/repos/`**, scattering `zephyr/`, `modules/`, `bootloader/`, `tools/` among the seven unrelated projects there. |

So: one clone, app inside it, shared `~/zephyrproject` toolchain, and the
`ZEPHYR_BASE` wrapper — which is the documented cost of the freestanding type
rather than a workaround.

**The one real cost is that the repo does not pin the Zephyr revision** — Sophon
silently follows whatever `~/zephyrproject` is at, so a future `west update` could
break the build with no record of what moved. Mitigated by a version assert in
`CMakeLists.txt` (below) that fails loudly at *configure* time with a readable
message, instead of obscurely at compile time, plus the expectation recorded in
`zephyr/CLAUDE.md`. If this ever needs CI or a second machine, the upgrade path is
to add a `west.yml` and switch to T2 — nothing here blocks that.

### Layout

New top-level target alongside `webapp/`, `ios/`, `api/`.

```
zephyr/
├── CLAUDE.md                  target conventions (mirrors ios/CLAUDE.md in spirit)
├── README.md
└── sophon/
    ├── CMakeLists.txt
    ├── prj.conf
    ├── PROTOCOL.md            wire format + frozen UUIDs — the shared contract
    ├── README.md              build / flash / console, incl. the two gotchas
    ├── src/
    │   ├── main.c             init, LED heartbeat thread, 1 Hz notify timer
    │   ├── ble.c / ble.h      bt_enable, adv set, BT_GATT_SERVICE_DEFINE, notify
    │   ├── ident.c / ident.h  FICR device ID → "Sophon-A3F2" adv name
    │   └── frame.h            packed 18-byte struct + pack helper
    └── scripts/
        ├── build.sh           venv + ZEPHYR_BASE + west build wrapper
        └── flash.sh           west flash -r uf2, with the manual-cp fallback
```

**`CMakeLists.txt`** — standard freestanding app. `find_package(Zephyr)` resolves
through the CMake user package registry (`~/.cmake/packages/Zephyr/`, written by
`west zephyr-export`), so no `ZEPHYR_BASE` is needed *for CMake* — only for `west`
itself.

```cmake
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(sophon)

# Freestanding app: the Zephyr revision comes from whatever ~/zephyrproject is
# at, not from this repo. Fail at configure time with a readable message rather
# than on some unrelated compile error three layers down.
#
# The variable is ZEPHYR_VERSION_CODE, NOT CONFIG_ZEPHYR_VERSION_CODE, and its
# value is a decimal int: (major << 16) | (minor << 8) | patchlevel.
set(SOPHON_MIN_ZEPHYR_CODE 263168) # 4.4.0

if(ZEPHYR_VERSION_CODE LESS SOPHON_MIN_ZEPHYR_CODE)
  message(FATAL_ERROR
    "Sophon requires Zephyr >= 4.4.0; found ${PROJECT_VERSION_STR} at ${ZEPHYR_BASE}. "
    "Run 'west update' in ~/zephyrproject.")
endif()

target_sources(app PRIVATE
  src/main.c
  src/ble.c
  src/ident.c
)
```

Two details in that guard are easy to get wrong, and both fail quietly rather
than loudly:

- **`CONFIG_ZEPHYR_VERSION_CODE` does not exist.** The variable is
  `ZEPHYR_VERSION_CODE`. A guard written against the `CONFIG_` spelling is never
  defined, so the check passes on every version — a dead guard that looks alive.
  Its value is a **decimal** int, `(major << 16) | (minor << 8) | patch`, so 4.4.0
  is `263168`. Writing the threshold in hex additionally relies on CMake parsing
  hex in a numeric comparison, which is not worth depending on.
- **`ZEPHYR_VERSION` is a boolean**, set to `TRUE` to mean "a Zephyr version was
  resolved". Interpolating it into the error message prints `found TRUE`. The
  human-readable string is `PROJECT_VERSION_STR`.

Confirm the guard fires by temporarily raising the threshold above the installed
version. A guard that has never been seen to fail is not a guard.

**`prj.conf`** — the load-bearing lines:

```conf
CONFIG_BT=y
CONFIG_BT_PERIPHERAL=y
CONFIG_BT_DEVICE_NAME="Sophon"              # fallback; overridden at runtime
CONFIG_BT_DEVICE_NAME_DYNAMIC=y             # required to set the FICR-derived name
CONFIG_BT_DEVICE_NAME_MAX=16                # "Sophon-A3F2" is 11 (default 28)

# Per-chip identity from nRF52840 FICR — same image on every board, unique name
CONFIG_HWINFO=y

# The XIAO has no UART-to-USB bridge, so USB CDC ACM is the only console --
# but nothing is set here for it. The board already does the whole job via
# boards/common/usb/Kconfig.cdc_acm_serial.defconfig, which turns on
# USB_DEVICE_STACK_NEXT, CDC_ACM_SERIAL_INITIALIZE_AT_BOOT, and a 4000 ms
# LOG_PROCESS_THREAD_STARTUP_DELAY_MS so the boot banner survives enumeration.
#
# Setting CONFIG_USB_DEVICE_STACK=y here links the LEGACY stack alongside the
# new one and the build fails at link time with a duplicate __device_dts_ord_*
# symbol. If that error appears, something has re-added the old stack.

CONFIG_LOG=y
CONFIG_GPIO=y
```

**The console needs no configuration here — the board supplies it.** The XIAO's
definition sources `boards/common/usb/Kconfig.cdc_acm_serial.defconfig`, which
enables the new USB stack (`USB_DEVICE_STACK_NEXT`), initializes CDC ACM at boot,
and sets `LOG_PROCESS_THREAD_STARTUP_DELAY_MS=4000` so the boot banner survives
USB enumeration.

Two things follow. **Do not add `CONFIG_USB_DEVICE_STACK=y`**: Zephyr carries two
USB device stacks, that symbol selects the legacy one, and having both linked
fails with `multiple definition of __device_dts_ord_*` — a message that points
nowhere near its cause. And **`CONFIG_BOOT_DELAY` is unnecessary**; the board's
log-thread delay already covers banner-versus-enumeration, so setting both just
idles for nine seconds on every boot.

The prj.conf keeps a comment saying what is deliberately absent and what breaks
if it returns, since four missing lines are otherwise indistinguishable from an
oversight.

**`scripts/build.sh`** — the wrapper that makes `west` work from this repo:

```bash
source ~/zephyrproject/.venv/bin/activate
export ZEPHYR_BASE=~/zephyrproject/zephyr
west build -p always -b xiao_ble/nrf52840/sense \
    -d "$APP_DIR/build" "$APP_DIR"
```

**`src/main.c`** behaviour: init BLE → start advertising with the service UUID in
the payload → green LED heartbeat (slow blink while advertising, solid while
connected) → 1 Hz notify of the zero-filled frame when a client is subscribed.

**Advertising must be restarted by the application after a disconnect** — it does
not resume on its own, and Zephyr 4.4 has no `ONE_TIME` option to ask it to. Use
`BT_LE_ADV_CONN_FAST_1` (GAP-recommended intervals, built on
`BT_LE_ADV_OPT_CONN`), and restart from the system work queue rather than inside
the callback, which runs on the Bluetooth RX thread:

```c
static void adv_work_handler(struct k_work *work) { (void)start_advertising(); }
static K_WORK_DEFINE(adv_work, adv_work_handler);

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
        ...
        k_work_submit(&adv_work);
}
```

Upstream's own `peripheral_hr` sample calls `bt_le_adv_start()` twice for this
reason — once at init, once after disconnect. Omitting the second call gives a
board that advertises, accepts one connection, and is then invisible until
rebooted, which presents as a range or pairing fault rather than a missing call.

**The name goes in the scan response, not the advertisement.** Legacy advertising
carries 31 bytes, and the obvious packing overflows it:

```
Flags                                    3 bytes
128-bit service UUID           2 + 16 = 18 bytes
"Sophon-A3F2" complete name    2 + 11 = 13 bytes
                                        ─────────
                                        34 > 31   ✗
```

So the advertisement carries flags + service UUID (21 B) and the **scan response**
carries the name (13 B) — the standard split, and iOS active-scans by default, so
`CBAdvertisementDataLocalNameKey` and `peripheral.name` both populate normally.
Worth knowing up front: this only surfaces at runtime as a `bt_le_adv_start()`
`-EINVAL`, which is an unhelpful way to learn about it.

**Shortening the name to fit was considered and rejected.** `"Sph-A3F2"` is 8
chars → `2 + 8 = 10` B, giving `3 + 18 + 10 = 31` — it fits, but *exactly*, with
zero spare. It buys nothing: the scan response is otherwise empty (13 B of its own
31 B), so the split costs no capacity anywhere, and iOS active-scans by default so
the name arrives regardless. Against that, a padded name is worth having — it is
what identifies a board in nRF Connect and in the app's device list — and 31/31
leaves no room for even one more hex digit of chip ID. The two things that *cannot*
move are the flags (mandatory) and the 128-bit service UUID (iOS's
`scanForPeripherals(withServices:)` matches against the advertisement, and filtered
scanning is required for background operation), so the name is the only field with
anywhere else to go. A 16-bit UUID would free 14 B but requires SIG assignment —
not available for a custom service.

**The scan response's other 18 bytes are spare capacity, deliberately unused for
now.** The packet is already being sent and already being requested (iOS
active-scans), so anything added here is **free in packet count** — it costs only
the bytes and a slightly longer response. That makes it the natural home for
anything worth knowing *before* deciding to connect. What fits:

| Candidate | Cost | Worth it? |
|---|---|---|
| **TX Power Level** (AD type `0x0A`) | 3 B | The cheapest real win — `CBAdvertisementDataTxPowerLevelKey` plus the RSSI already tracked gives a rough path-loss distance estimate. Zephyr fills it in via `BT_LE_ADV_OPT_USE_TX_POWER`. |
| **Protocol version** | 1 B, inside mfr data | Insurance against a future wire-format change being met with a silent misparse. Cheap now, awkward to retrofit. |
| **Battery level** | 1 B | Genuinely useful pre-connect once boards run off battery rather than USB — pick the charged one. Needs an ADC read the skeleton doesn't have. |
| **Full 64-bit FICR ID** | 8 B | The name carries only 4 hex digits (16 bits); the full ID would disambiguate a hash collision. Not a real risk at a handful of boards. |
| **Configured sample rate** | 1 B | Display-only. Marginal. |

Custom fields ride in **Manufacturer Specific Data** (AD type `0xFF`), which costs
`2 B` framing + `2 B` company ID before any payload. Without SIG membership the
company ID is `0xFFFF` — the value reserved for internal/test use. So the full
budget, if all of it were claimed:

```
name "Sophon-A3F2"            2 + 11 = 13 B
TX power                      2 +  1 =  3 B
mfr data  (0xFFFF + 11 B)     2 + 2 + 11 = 15 B
                                       ──────
                                        31 B  exactly
```

**None of this is in issue A.** The skeleton's job is to prove the link works, and
every one of these fields is either speculative (version, before any second version
exists), unavailable (battery, before there is a battery), or cosmetic. Recording
it here so the capacity is a known resource rather than a rediscovery — TX power is
the one to reach for first, and it is a one-flag change whenever distance estimation
becomes interesting.

On every connect, log the **negotiated ATT MTU** via `bt_gatt_get_mtu(conn)`
(`include/zephyr/bluetooth/gatt.h:1663`) rather than assuming it. This is one line
and it turns the whole MTU analysis above from an assumption into an observed fact
at bring-up — expect `23`, and if it ever reads lower, `notify` will start failing
with `-EMSGSIZE` and this log is what explains why.

## Part 2 — `ios/Sophon/` target

A **separate Xcode project**, sibling to `ios/FirstContact/` — not a target inside
it. Bundle `com.vwong.Sophon`, team `9Y8886KJR8`, deployment target 26.0,
Swift 5.0 — matching FirstContact's settings.

```
ios/Sophon/
├── ORIGINAL-PLAN.md               the approved plan, frozen (see below)
├── UPDATED-PLAN.md                ← this document; corrected, current
├── Sophon.xcodeproj/
│   ├── project.pbxproj                            objectVersion 77
│   └── xcshareddata/xcschemes/Sophon.xcscheme      ← see note
├── Sophon/
│   ├── SophonApp.swift
│   ├── ContentView.swift          device list → detail; one row per Sophon
│   ├── Info.plist                 NSBluetoothAlwaysUsageDescription
│   ├── Assets.xcassets/           AccentColor + empty AppIcon (silences warnings)
│   └── BLE/
│       ├── SophonProtocol.swift   frozen UUIDs + MotionFrame decoder (18 bytes)
│       ├── SophonHub.swift        owns the CBCentralManager, [UUID: SophonDevice]
│       └── SophonDevice.swift     per-peripheral identity, state, RSSI, frames
└── scripts/
    └── deploy-device.sh           adapted from ios/FirstContact/scripts/
```

The `project.pbxproj` is hand-written using a **`PBXFileSystemSynchronizedRootGroup`**
(objectVersion 77) — the same mechanism FirstContact already uses, which means no
per-file entries and no pbxproj churn as sources are added.

> **Note on the shared scheme.** `ios/FirstContact` commits *no* scheme —
> `xcodebuild -scheme FirstContact` works there only because Xcode auto-generated
> one into `xcuserdata/` when the project was first opened. A hand-written project
> that has never been opened in Xcode has no such scheme, so `xcodebuild -scheme`
> would fail. Committing a shared scheme fixes this and makes the project build
> from a fresh clone. This is a small, deliberate improvement over FirstContact's
> setup, not an inconsistency.

**The hub/device split is the multi-device fix, applied before any view exists.**
An app gets exactly one `CBCentralManager`, so it cannot live on a per-device
object; and a single `MotionLink` holding *the* peripheral and *the* state would
bake single-device assumptions into the type every view binds to. Same code
volume, one level of indirection, no later refactor.

- **`SophonHub`** — owns the `CBCentralManager`, scans **filtered by service UUID**
  (required: iOS returns no unfiltered scan results while backgrounded), and keys
  discovered peripherals into `[UUID: SophonDevice]` by `CBPeripheral.identifier`.
  Auto-reconnects known devices.
- **`SophonDevice`** — `displayName` (from the scan-response name, e.g.
  `Sophon-A3F2`), `state` (`.discovered / .connecting / .connected /
  .disconnected(Error?)`), `rssi`, `framesReceived`, `seqGaps`, `lastFrame`.

`ContentView` is a list of devices → detail. With one board it is a one-row list;
with five it needs no change. The 3D view and charts (issue C) attach to a
`SophonDevice`, so they are per-device by construction.

**Actor isolation.** The target builds with
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so every declaration is `@MainActor`
unless it says otherwise — while Core Bluetooth's delegate methods are
`nonisolated`. `SophonProtocol` (two immutable `CBUUID` constants) and
`MotionFrame` (a struct of six scalars, also `Sendable`) are therefore declared
**`nonisolated`**: they are pure value-level code that the callbacks must reach,
and the isolation would otherwise be an accident of the project-wide default.
Without it the callbacks cannot read them — warnings today, errors under the
Swift 6 language mode.

`SophonHub` and `SophonDevice` stay `@MainActor` deliberately; they own the
observable state views bind to. The delegate callbacks are `nonisolated` and hop
back via `Task { @MainActor in … }`.

`xcuserdata/` is already gitignored; `build/` at `.gitignore:11` already covers
`zephyr/sophon/build/`. I'll add an explicit, commented Zephyr entry near the
bottom so the coverage isn't accidentally load-bearing on a Python-packaging line.

### The design records

Two documents sit beside each other under `ios/Sophon/`:

- **`ORIGINAL-PLAN.md`** — the plan as approved on 2026-08-09, before any code
  existed. Frozen, and deliberately never updated.
- **`UPDATED-PLAN.md`** — this document. The same design with the API-level detail
  corrected against what the toolchain actually provides. Where the two disagree,
  this one is right.

The value in keeping either is the part that will otherwise be lost: the ATT MTU
budget, the connection-event supply/demand derivation, the batching-vs-DLE
arithmetic, and the reasoning behind the freestanding-app choice. Those explain
*why* the frame is 18 bytes, why the sample rate is 50 Hz, and why the MTU is left
at its default — none of which is recoverable from the source once written. The
frozen copy is worth its disk space because a plan that quietly rewrites itself to
match the code stops being evidence of anything.

Two consequences for the rest of the plan:

- `zephyr/sophon/PROTOCOL.md` **links to these rather than duplicating them**, and
  keeps only the live contract (frame layout, frozen UUIDs, known gaps).
  Duplicating the analysis across documents guarantees they eventually disagree.
- They carry analysis for both halves despite living under `ios/`, so
  `zephyr/CLAUDE.md` and `zephyr/sophon/README.md` point at them explicitly —
  nobody working on the firmware should have to guess that the BLE capacity
  derivation is filed under the iOS target.

## Part 3 — repo conventions

- **`zephyr/CLAUDE.md`** — new target conventions: venv activation, the `west`
  `ZEPHYR_BASE` requirement, hierarchical board naming, UF2 flashing + the
  board-id caveat, USB-CDC-only console, and "a successful build is necessary but
  not sufficient — firmware changes are verified on the physical board." Also
  records that this is a **freestanding** app against a shared `~/zephyrproject`
  at Zephyr **≥ 4.4**, that the workspace is *not* pinned by this repo, and that
  the T2 migration path exists if CI is ever needed.
- **`zephyr/README.md`** and **`ios/Sophon/README.md`**.
- **Root `CLAUDE.md`** — register `zephyr/` in the top-level target list and add
  `sophon:` to the issue title-prefix rule.
- **`ChangeLog.md`** — entry under today's date, staged in the same commit.

## Issues and branching

`sophon:` as the title prefix — one logical project spanning two folders, matching
how CLAUDE.md already handles multi-target names.

| # | Title | Now? |
|---|---|---|
| A | `sophon: Project skeleton — Zephyr BLE peripheral + iOS central` | **this work** |
| B | `sophon: Stream raw 6-axis IMU over BLE GATT notify` | filed → Backlog |
| C | `sophon: 3D orientation view + live axis charts` | filed → Backlog |
| D | `sophon: Multi-device — batched frames + DLE, cross-device time sync` | filed → Backlog |

Issue D captures what this skeleton deliberately does *not* solve: batching past
~5 boards, and a common time base. Identity and the hub/device model are handled
here, so D is purely about scale and sync. Its one non-obvious requirement is that
**`BT_L2CAP_TX_MTU` and DLE must move together** — the batching arithmetic above
shows why splitting them ships the latency cost for a quarter of the benefit — and
that DLE is reached by raising `BT_BUF_ACL_TX_SIZE`/`RX_SIZE`, not by setting
`BT_CTLR_DATA_LENGTH_MAX` (a derived value behind a hidden Kconfig).

All four cross-linked, all added to Project 1. Issue A is implemented on a single
branch `<A>-sophon-skeleton` — the two halves are the **tightly-coupled** case from
CLAUDE.md (one logical change; neither is independently verifiable, since the phone
connecting is what proves the firmware advertises).

---

## Verification

0. The design records exist and their pointers resolve — this document plus the
   frozen `ORIGINAL-PLAN.md`, referenced from `zephyr/CLAUDE.md` and
   `zephyr/sophon/README.md`.

Firmware, on the real board:

1. `zephyr/sophon/scripts/build.sh` → clean build, `build/zephyr/zephyr.uf2` exists.
2. Double-tap reset → volume mounts → `scripts/flash.sh`. If the uf2 runner can't
   match the board-id, fall back to `cp` and **record the real board-id** in
   `zephyr/sophon/README.md`.
3. `minicom -D /dev/tty.usbmodem* -b 115200` → boot banner, `bt_enable` success,
   and the FICR-derived name logged, e.g. `advertising as Sophon-A3F2`.
4. Green LED blinking.
4b. Confirm in **nRF Connect** (or any scanner) that the name appears and the
   service UUID is in the advertisement — this specifically checks the
   advertisement/scan-response split, which `bt_le_adv_start()` would otherwise
   only report as a bare `-EINVAL`.

iOS:

5. `xcodebuild -scheme Sophon -sdk iphonesimulator build` → compiles.
6. Simulator install + `xcrun simctl io … screenshot`, then read the PNG — per
   `ios/CLAUDE.md` this is mandatory for any SwiftUI change. It will show the
   `.poweredOff`/unsupported state, since **the simulator has no Core Bluetooth
   hardware**; that is still a valid layout check and the right way to confirm the
   no-radio state renders sensibly rather than showing a blank screen.
7. `ios/Sophon/scripts/deploy-device.sh` → physical iPhone (the only place BLE can
   actually be tested).

End-to-end, both halves live:

8. Power the XIAO, launch Sophon on the iPhone → state reaches `.connected`,
   RSSI populates, frame counter increments at ~1/s, seq-gap count stays 0.
   Console should log `ATT MTU: 23` on connect, and each received frame should be
   exactly 18 bytes — confirming one sample per radio packet, unfragmented.
9. Walk out of range → state drops to `.disconnected`; walk back → it re-scans and
   reconnects without a relaunch. This is the direct test of the advertising
   restart above: without it the board never re-advertises and step 9 fails while
   looking like a range problem.

Step 8 is the one that matters: it is the single check that proves the build
plumbing, the GATT definition, the advertising payload, the UUID agreement, and
the frame decoder are all correct simultaneously.

Then: implementation-summary comment on issue A, status → **In review**, and pause
for commit consent.
