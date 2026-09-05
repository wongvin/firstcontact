# Sophon test plan

Manual test cases for the Sophon iOS app. Sections are added per issue; update
when new behaviour lands.

## Why this is manual

Neither iOS project has a test target, and `ios/CLAUDE.md` is explicit that a
green `xcodebuild` proves syntax and nothing else. For Sophon the gap is wider
still: the iOS Simulator has **no Core Bluetooth radio and no Core Motion
hardware**, so `SimulatorView` renders its no-radio branch and cannot reach the
Transmit counters or Scheduling cadence sections at all. Every case below needs
physical hardware.

## Environments

| Role | Device | Required |
|---|---|---|
| Peripheral | iPhone in **Simulator mode** | yes |
| Central | iPad running the **Viewer** | yes |
| Second central | Second iPad | only for hand-off cases |
| Board | XIAO nRF52840 Sense | only where stated |

Deploy with `ios/Sophon/scripts/deploy-device.sh --all`. Devices must be
unlocked; a locked device refuses launch (see `ios/CLAUDE.md` on the two
`Code=10002` causes).

## 1. Reset paths (issue #259)

Covers three pieces of state that outlive a reset which should clear them.

### 1a. Forcing the precondition — read this first

**The primary defect is not reachable on `main` as it stands.** `localQueueDrops`
increments only when the send queue reaches its depth of 8, and the paced drain
(`drainBudget = 2` every ~18 ms, ≈100 Hz against a ~50 Hz source) keeps it at
0–1. Observed: the "…dropped by send queue" row does not appear at all.

That is precisely why the reset was missed — **nothing exercises this path**, so
nothing caught it. A test plan that cannot reach it repeats the mistake.

Options, best first:

| # | Method | Notes |
|---|---|---|
| A | **Stress build**: set `drainBudget = 1` and `drainInterval` to 25 ms, deploy, then revert | Reproduces the measured first-attempt condition where the queue pinned at 7–8. Repeatable, but not a black-box test and easy to forget to revert |
| B | **Bench control**: add a "stall the drain" toggle beside the existing drop control | Makes this permanently testable. Arguably belongs in #259 itself, since an unexercised path is what broke |
| C | Background the app and return | Unreliable: the drain `Task` and Core Motion may throttle together |
| D | Catch a startup clump | Unreliable: Core Motion arrival ranges 0.2–55.3 ms, so an initial burst of 8 is possible but not dependable |

If none is available, case 1.1 is **inspection-only** and must be recorded as
such rather than marked passed.

### 1b. `localQueueDrops` reset

| ID | Steps | Expected |
|---|---|---|
| 1.1 | With the precondition forced (1a), run until "…dropped by send queue" shows a non-zero value. Note both it and "TX buffer full". Tap **Reboot the simulated board**. | Both read **0**. *Before the fix: TX buffer full resets to 0 while dropped-by-send-queue keeps its value — a subset larger than its superset.* |
| 1.2 | From the same state, switch to **Viewer** mode and back to **Simulator**. | Both read 0. `start()` calls `reboot()`, so a mode round-trip must behave as 1.1 does. |
| 1.3 | After 1.1, with the queue no longer dropping, observe the Transmit counters section for 30 s. | The orange "…dropped by send queue" row is **absent**. *Before the fix it stays lit for the rest of the app's life, since its visibility is gated on the un-reset counter.* |

### 1c. Cadence clock reset

**Presence of values proves nothing.** `Send loop period` and `CoreMotion arrival`
repopulate within about two ticks — roughly 40 ms — so they are back before anyone
can look, whether or not the reset happened. Only the **Drain interval** block
shows "Nothing yet", because it needs two queue-full events and those are rare.

So judge a reset by **range width**: a freshly reset min/max spans a few ms and
widens over the following minute, whereas an un-reset one shows its accumulated
bounds straight away. An earlier draft of case 1.7 expected the whole section to
read "Nothing yet", which is both wrong and untestable — it could not distinguish
"reset and repopulated" from "never reset".

**Judge magnitudes by order, not by a tight bound.** Measured baseline on
iOS: both ranges reach **~55 ms** in normal operation — `Task.sleep` does not
deliver the interval it is asked for, and Core Motion arrives clumped. A 55 ms
upper bound is healthy, not a failure.

The defect's signature is **~60000 ms**, three orders of magnitude away, so it
cannot be confused with ordinary jitter. An earlier draft of this section called
for a "tight range" and a verbal walkthrough put that at 17–25 ms, which would
have failed a perfectly good build.

| ID | Steps | Expected |
|---|---|---|
| 1.4 | Run Simulator mode with an iPad connected until **Send loop period** shows a stable mean near 20 ms. Note it and the range. Switch to Viewer, wait **60 s**, switch back to Simulator. Watch the first few seconds. | Mean stays near 20 ms and the range stays in **tens of ms**. *Before the fix the first tick differences against a 60-second-old instant: the range gains a **~60000 ms** outlier and the mean is permanently poisoned.* |
| 1.5 | Repeat 1.4 watching **CoreMotion arrival** and **Arrival range**. | Mean near 20 ms, range in tens of ms. *Before the fix the range gains the same ~60000 ms outlier on the first sample.* |
| 1.6 | Repeat 1.4 using **Reboot the simulated board** instead of a mode switch. | Same expectations. Reboot and mode-switch must agree. |
| 1.7 | Run until **Arrival range** has widened to roughly `0.2 – 55 ms`. Tap **Reboot**, then read **Loop range** and **Arrival range** within a second or two. | Both ranges are **narrow** — a few ms wide, e.g. `19.8 – 21.2 ms` — and widen again over the next minute. *Before the fix they show the old wide bounds immediately, because min/max were never cleared.* |
| 1.7b | Immediately after the same reboot, look at the **Drain interval** block specifically. | Reads "Nothing yet — the queue has not filled twice", until two queue-full events occur. Unlike the two rows above, this one is gated on `readyGap*` and was already reset correctly; it is here as a control. |

### 1d. Regression — resets that already worked must keep working

The fix touches shared reset paths, so verify it does not disturb what was
already correct.

| ID | Steps | Expected |
|---|---|---|
| 1.8 | Run until Sent, TX buffer full and No subscriber are non-zero. Tap **Reboot**. | All three read 0. |
| 1.9 | After a reboot, check **Drain interval** / **Range** in Scheduling cadence. | Reads "Nothing yet — the queue has not filled twice." `lastReadyAt` was already nil'd correctly and must remain so. |
| 1.10 | On the **iPad**, note Frames received, Gaps in sequence and Restarts without disconnect. Reboot the simulator. | Frames received and Gaps in sequence **reset to 0**, and **Restarts without disconnect increments**. That is `noteBoardRestart()` doing its job: the link never dropped, so the peripheral restarted underneath it and counters spanning two boots would be meaningless. `attMTU` survives, because the *connection* did. Transmit counters read `Reading…` until the next poll rebuilds the baseline. |
| 1.10b | During the same reboot, watch **Gaps in sequence** specifically. | It must **not spike**. `seq` jumping from tens of thousands back to 0 read as loss is the failure this detector exists to prevent — a large gap here means the restart went undetected. |
| 1.11 | With the board (not the simulator), connect, note ATT MTU and Interval, then release and reconnect. | Session-scoped values re-establish; `identity` and `txPower` — advertisement-scoped — are **not** cleared. This is the distinction #230/#235 drew and #259 must not blur. |

### 1e. Dead baseline fields — inspection

| ID | Steps | Expected |
|---|---|---|
| 1.12 | `grep -rn "framesAtStatsBaseline\|interruptedFramesAtStatsBaseline" ios/Sophon/Sophon/` | Either no matches (removed), or matches including a **read** site. Assignment and reset alone means the comment still promises a guarantee nothing implements. |

### 1f. Not covered

- **Whether the paced queue is correctly sized.** #255 measured 8.80% → 5.27%; the residual is unexplained and tracked in #248, not here.
- **The board's equivalent gap.** `k_msgq_put` failing in `main.c` increments no counter, so a board queue-full drop reads as air loss. Latent, and firmware-side.
- **Anything requiring a view of the link itself.** Core Bluetooth reports *that* a frame was refused, never *why* — see #251, #252, #254.

## 2. Observation churn (issue #261)

Unlike § 1, this **does** reach a real board: both hot writes are in
`SophonHub.didDiscover`, ungated by peripheral kind, and `wantDuplicates` keys on
*any* released device — so releasing one peripheral turns duplicate reporting on
for the whole scan and every advertiser delivers callbacks at its advertising
rate. A board at `BT_LE_ADV_CONN_FAST_1` is ~16–33 per second.

### 2a. This section can legitimately conclude "do not fix"

The mechanism is certain; the cost is not. Twenty-odd redraws a second of one row
and one detail view may be entirely invisible on an iPad.

**Measure first. If the rate is imperceptible and no frame drops are observable,
record that and close #261 as won't-fix** rather than restructuring code on
principle. A fix that cannot be shown to change anything is speculative
optimisation wearing a bug fix's clothes.

Measurement options, best first:

| # | Method | Notes |
|---|---|---|
| A | **Instruments → SwiftUI template**, device attached, read "View Body" counts for `DeviceRow` and `DeviceDetailView` | Most faithful, needs no code change. Requires launching from Xcode rather than `deploy-device.sh` |
| B | **Temporary on-screen counter** — bodies-per-second rendered as a row, in the style of every other diagnostic here | Matches how this project asks questions. Note the counter is itself in the body, so it measures with a small observer effect |
| C | `Self._printChanges()` in the two bodies | Names the property that caused each invalidation, which A and B do not. Output only visible when running from Xcode |

C is worth one run regardless: it answers *which* property is driving redraws,
which is the thing the fix targets.

### 2b. Baseline — before any change

Run with a **real board** advertising, plus the Viewer on an iPad.

| ID | Steps | Expected / record |
|---|---|---|
| 2.1 | Nothing released. Sit on the device list for 60 s. Measure `DeviceRow` body rate. | Baseline for the quiet case. Duplicates are off, so `didDiscover` fires roughly once — expect near zero. |
| 2.2 | Release the board (swipe → Release). Leave it advertising, unconnected. Stay on the device list, 60 s. | Record the rate. **This is the case under test.** Expect roughly the board's advertising rate, ~16–33/s. |
| 2.3 | With the board still released, open its detail view. 60 s. | Record `DeviceDetailView` body rate. Expect the same order as 2.2. |
| 2.4 | During 2.2 and 2.3, watch for visible symptoms: scroll stutter, animation hitches, device warmth, battery drain. | Record honestly, including "none observed". This is what decides whether the fix is worth making. |
| 2.5 | Run once with `Self._printChanges()` in both bodies. | Record which properties are named. Expect `advertisementKeys` and `lastSeenAt`. If something else dominates, the issue's diagnosis is wrong. |

### 2c. After the fix

| ID | Steps | Expected |
|---|---|---|
| 2.6 | Repeat 2.2 and 2.3. | Rate falls substantially — ideally to the timeline-driven ~1/s. Record the measured before/after pair in #261; "improved" without numbers is not a result. |
| 2.7 | Repeat 2.5. | Neither `advertisementKeys` nor `lastSeenAt` appears as an invalidation cause. |
| 2.8 | With a **simulator** peripheral, measure `SimulatorView` body rate before and after the `publish()` guard. | Falls from ~10/s toward change-driven. Simulator-side only; a board is unaffected by this one. |

### 2d. Regression — the guards must not break what they touch

The two properties are load-bearing for #235's release behaviour. Each case below
is something a naive guard would break.

| ID | Steps | Expected |
|---|---|---|
| 2.9 | Release a board and keep it advertising, unconnected. Open its detail view and watch the State row for 20 s. | Reads `Released`, and stays there. `lastSeenAt` is still being refreshed, so it must **not** go stale while the board is on the air. *A guard that stops updating `lastSeenAt` breaks exactly this.* |
| 2.10 | Release a board, then power it off. Wait past the 15 s threshold with the detail view open. | Connect is withdrawn, footer explains, **Back to Devices** appears. Staleness detection still works. |
| 2.11 | Repeat 2.10 from the device list rather than the detail view. | Row disappears within ~15 s of the board going quiet. |
| 2.12 | Release a board, power it off, wait for it to be forgotten, power it back on. | Rediscovered and auto-connects, per #235. |
| 2.13 | If `lastSeenAt` becomes `@ObservationIgnored`: watch a released, still-advertising device whose detail view is open, then power it off and read the State row each second. | `Released · not seen Ns` counts up once per second. The `TimelineView` re-evaluates on its own clock and reads the property fresh, so this should hold — but it is the specific thing that breaks if the value stops being observable **and** nothing else drives the redraw. |
| 2.14 | With any peripheral, confirm the orange **Other advertising data** row still behaves: absent normally, present if an unaccounted key appears. | A guard on `advertisementKeys` must not stop the union accumulating — only stop it notifying when unchanged. |

### 2e. Not covered

- **Battery impact.** Plausible but unmeasured, and not separable from the radio's own cost at duplicate-scan rate.
- **Whether duplicate scanning itself is too expensive.** That is #235's design, not this issue; #261 only concerns what the app does per callback.

## 3. RSSI while connected (issue #237)

Before this change `device.rssi` was written in exactly one place — `didDiscover`.
A Sophon board is `CONFIG_BT_MAX_CONN=1` and stops advertising the moment it is
taken, so for the whole of a connected session the row held the last value
captured *before* the link came up. It looked like a rock-steady signal. It was a
number that had stopped being measured.

The fix polls `readRSSI()` on the existing 2 s stats poll, feeds it through the
same `ingestRSSI` smoothing path as advertised samples, bounds that path's window
by **age as well as sample count**, and labels a reading with its age once it
stops being refreshed.

### 3a. Why the window had to become age-bounded

Worth understanding before running anything, because two cases below fail
harmlessly-looking if this is missed.

The two sources arrive three orders of magnitude apart: tens of samples per second
from advertisements with duplicate reporting on (#235), one per second while
connected. A fixed 8-sample window therefore spans **0.3 s** in the first case and
**8 s** in the second. Sixteen seconds cannot follow a tablet being carried away
from a board, which is the one check #237 exists to make possible — so a mean that
looked correct would have failed the acceptance test.

The age bound is `rssiWindowSpan = 4 s`, the count bound `rssiWindow = 8`, and the
display threshold `rssiStaleAfter = 5 s`. The display threshold is deliberately
the larger: at a 1 s poll several consecutive reads must go missing before the
label changes, so one late callback cannot flicker it.

A second rule works with it, and 3.7 is what proves it: a connected reading is
credited to the **last packet the app can prove arrived** (`lastFrameAt`), not to
the moment the reply landed. HCI `Read_RSSI` returns the strength of the
controller's last received packet and cannot say how long ago that was, while
`peripheral.state` stays `.connected` for the whole supervision window after a
board dies. Stamping the reply time would therefore have left this row looking
freshly measured for minutes on a dead link — #237's own defect rebuilt in a new
place, with *frozen and looks live* swapped for *refreshed by asking and looks
live*. Readings that describe a packet older than the window are dropped, which
is what lets the age climb.

**The fix holds either way; 3.7 only says which mechanism held.** If iOS answers
`readRSSI()` on a dead link with an error or the `127` sentinel, the existing
guards drop it and the age climbs regardless of crediting. If it answers from the
controller's cache — the case the crediting rule exists for — the stale timestamp
is what makes the age climb. The row is honest under both, so 3.7 is a diagnostic
rather than a gate.

**That window is only reachable on an iOS-to-iOS link.** A board's supervision
timeout is 420 ms (#224), so a dead board leaves `.connected` before the 5 s
staleness threshold can be crossed — `Disconnected` is the correct answer there,
and the poll stops on its own. iOS chooses a far longer timeout for its own
links, which is where `.stalled` was first reproduced and where 3.7 has to run.

The age bound also settles the disconnect question with no disconnect hook.
Samples describing the old link expire on their own, so a reconnect — possibly
from somewhere else entirely — starts its mean from its own first reading rather
than blending into the previous one. Case 3.9 is what proves that, and it is the
case that silently passes for the wrong reason if you reconnect too slowly to tell
the difference.

### 3b. The value now tracks — the check that was impossible before

| ID | Steps | Expected |
|---|---|---|
| 3.1 | Connect a board, open its detail view, leave it still, and read the RSSI row over 30 s. | A value in dBm, **no age suffix**, moving by a few dB. Before this change it would not have moved at all. |
| 3.2 | With the detail view open, carry the tablet steadily away from the board to the far end of the room, then back. | The value falls as you go and recovers as you return, updating about once a second. This is #237's acceptance test. |
| 3.3 | Note the value at rest, then put a hand or body between tablet and board. | Falls by several dB within a few seconds. A crude but decisive check that the number comes from the radio and not from memory. |
| 3.4 | Compare the reading against `TX power` in the same section, on a board flashed with #230. | `TX power − RSSI` is a plausible path loss for the distance — tens of dB, not near zero and not hundreds. The estimate #230 added TX power *for* is only as good as this row. |

### 3c. A remembered reading must not look like a measured one

Requirement 4 — and the requirement it had to be reconciled with.

The issue asked for polling to stop "when nothing is on screen, as the stats poll
already does". That rule does **not** carry across, and an earlier build that
applied it literally shipped a real defect: RSSI is displayed in the device list
*as well as* the detail view, so a poll living in the detail view's `.task` left a
connected board's list row ageing forever with nothing that could ever clear the
suffix — #237's own complaint moved one screen over. **Found in review on
2026-09-05, after the first build.**

The poll is therefore hub-owned and bounded by the *role* rather than by a view:
it runs between `resume()` and `suspend()`, so simulator mode polls nothing and a
backgrounded app is suspended by iOS. That is defensible only because `readRSSI`
costs no air traffic — see §3e, which measures the claim. The stats poll stays
view-gated because it is a genuine ATT round trip whose results only the detail
view shows.

| ID | Steps | Expected |
|---|---|---|
| 3.5 | Connect a board, open the detail view until RSSI is live, then navigate back to the list and watch its row for 30 s. | Stays **fresh** — value moves, no age suffix, not dimmed. *This is the case that regressed.* An age suffix appearing here means the poll has been re-attached to a view's lifecycle. |
| 3.6 | From 3.5, move the tablet while watching the **list** row only. | The value follows. The list is a first-class consumer of RSSI, not a stale mirror of the detail view. |
| 3.6a | Switch to simulator mode, then back to viewer. | Polling stops and restarts with the role. On return, a reconnected board's reading goes live again within a second or two rather than staying suffixed. |
| 3.7 | **iOS-to-iOS link, and the peer must go silent *without* a clean disconnect.** Connect the viewer to a simulator peripheral, open the detail view, then carry the peripheral device out of range — far enough, or into a lift/fridge/metal enclosure. Watch **both** the State row and the RSSI row. | State reaches `Stalled` at 5 s and RSSI gains its age suffix at the same moment. *If RSSI stays fresh while State says `Stalled`, the evidence-crediting in `ingestConnectedRSSI` is not working.* **Do not background or swipe away the simulator app** — see 3.7b. **Do not turn Bluetooth off on the peer** — that sends a clean teardown, so the viewer goes straight to `Disconnected` and the window never opens. |
| 3.7b | Same as 3.7 but background or swipe away the simulator app. | State stays **`Connected`**, never `Stalled`. *Measured 2026-09-05.* Not a defect and not a usable method: `BackgroundKeepAlive` holds a CoreLocation session precisely so a backgrounded simulator keeps sampling and notifying, because a push-driven peripheral gets no BLE event to wake it. Frames really are still arriving, so a fresh RSSI here is correct. Recorded because this was the first method tried and it looks like it should work. |
| 3.7a | Same as 3.7 but with a **board**: power it off with the detail view open. | State goes to **`Disconnected`**, not `Stalled`, and RSSI gains its age suffix. *Measured 2026-09-05.* This does **not** test the crediting rule: a board's supervision timeout is 420 ms (#224), so `peripheral.state` leaves `.connected` almost immediately, the poll's guard closes, and `rssiAt` freezes regardless of how readings are credited. The result is identical on fixed and unfixed code. Recorded because the case looks decisive and is not — an earlier draft of this plan asked for `Stalled` here, which a board cannot produce. |
| 3.8 | Disconnect a board but leave it advertising and released, so duplicate reporting is on. Watch RSSI in the list. | Stays fresh with no suffix — advertisements are feeding it at tens per second. |

| 3.7c | From 3.7, keep watching for a further 60 s without touching anything. | The age keeps climbing and the value never refreshes itself. A reading that starts ageing and then silently resets to fresh means a stale-crediting sample was accepted rather than dropped. |

### 3d. Across a disconnect

| ID | Steps | Expected |
|---|---|---|
| 3.9 | Note the RSSI at close range. Disconnect, carry the tablet far away, wait **more than 4 s**, then reconnect and read the first value that appears. | The new reading reflects the new distance immediately — it does not start near the old close-range value and drift down. The old samples have aged out of the window. *If it drifts, the age bound is not being applied and only the count bound is in force.* |
| 3.10 | Repeat 3.9 but reconnect in **under 4 s** without moving. | Value is continuous, no visible jump. Ageing out must not mean discarding a still-valid mean. |
| 3.11 | Forget a released board (#235), then let it be rediscovered. | RSSI starts from the new device object's own first sample. Nothing carries over — a forgotten device is a new `SophonDevice`. |

### 3e. Cost — does polling spend connection-event budget?

The code comment justifying the 1 s cadence claims `readRSSI` is **not** an ATT
round trip: the Bluetooth spec's `Read_RSSI` is a local controller command
(Core v6.0 Vol 4 Part E §7.5.4) reporting the strength of packets the peripheral
is already sending. That claim is load-bearing — it is the reason the interval was
chosen for usefulness rather than for thrift — so it should be checked rather than
believed.

**A null result at the shipped 1 s cadence proves nothing.** One read per second
against 20 connection events per second is far below the noise in the refusal
rate. The test needs a stress build.

| ID | Steps | Expected |
|---|---|---|
| 3.12 | Baseline: connected board, detail view open, 60 s. Record frames/s, `noBuffer`, and refusal %. | The figures `PROTOCOL.md` records — ~20 events/s, refusals near 5.27% post-#255. |
| 3.13 | Stress build: change the sleep in `SophonHub.startRSSIPolling()` from 1 s to 100 ms. Repeat 3.12. | **If the claim holds:** frames/s, `noBuffer` and refusal % are unchanged within noise, despite 10 reads/s. **If it does not:** refusals rise measurably and the 1 s cadence needs justifying on cost after all. Record the numbers either way — this is the case that can falsify the comment. |
| 3.14 | On the stress build, confirm the RSSI row still behaves — no flicker, no missing values. | 10 reads/s against a 4 s window is 40 samples capped to 8, i.e. a 0.8 s mean. Should be smooth. |
| 3.14a | On the stress build, open and close the detail view repeatedly while watching the list row. | No stall, no duplicate polling artefacts. One owner drives the poll; the detail view no longer reads RSSI at all. |
| 3.15 | Revert the stress build before shipping. | The RSSI poll back to 1 s. Stated explicitly because a fast poll left in place would quietly change every other measurement in this file. |

### 3f. Regression — the advertised path must be untouched

| ID | Steps | Expected |
|---|---|---|
| 3.16 | Watch a released, advertising board's RSSI in the list for 30 s (duplicate reporting on). | Smooth and readable, as before #237. The 8-sample count bound still governs here; the age bound never binds at tens of samples a second. |
| 3.17 | Confirm the `127` sentinel is still dropped: watch a board at the edge of range in the list. | The row never shows a positive value and never vanishes mid-session. This is #235's latching rule, which `didReadRSSI` also relies on rather than re-implementing. |
| 3.18 | Connect to the **simulator** peripheral and open its detail view. | RSSI populates and tracks — an iOS peripheral cannot advertise manufacturer data, but it is a normal BLE connection, so `readRSSI` works exactly as for a board. |
| 3.19 | Check the detail view's row order and separators: State, RSSI, ATT MTU, Interval… | Each on its own List row with normal separators. RSSI has its **own** `TimelineView`; sharing the State row's would render both inside one cell, which no compile catches. |
| 3.20 | Leave the app in the detail view for several minutes on a healthy link. | No growth in body-evaluation rate versus the #261 baseline. `rssiAt` and `rssiSamples` are `@ObservationIgnored`, so per-sample writes must not drive redraws. |
| 3.21 | Find or force a device whose `rssi` is still nil — a board first seen at the very edge of range, so every sample so far was the `127` sentinel — and open its detail view. | **No blank row** between State and ATT MTU. The nil check sits outside the `TimelineView` for this reason: a `TimelineView` is always one row, so a nil reading inside one renders an `EmptyView` in a real List cell with separators around it. Hard to force; inspect the code path if it cannot be reproduced. |
| 3.22 | Leave a connected board's detail view, then return to the list after a minute, ten minutes, and over an hour. | The age reads `52s ago`, then `10m ago`, then `over an hour ago` — it coarsens rather than printing `3612s ago`. |

### 3g. Not covered

- **Absolute accuracy.** Nothing here calibrates dBm against a reference. The tests check that the number *responds*, not that it is correct — no equipment on hand can establish the latter.
- **Whether 1 s is the right cadence.** 3.13 can show the cost is negligible, which would mean a faster poll is *affordable*; it cannot show it is *useful*. Choosing a different interval would need a reason from the UI side.
- **A disconnected, unreleased board's reading looking stale.** With duplicate reporting off, iOS consolidates repeat sightings, so such a device may legitimately carry a large age. That is honest rather than wrong, but it may read as noisy in a long list. Judgement call deferred until it is seen on real hardware.
- **RSSI as distance.** `TX power − RSSI` is a path-loss estimate, not metres, and #230's range measurements already showed the model off by roughly 10×.

## 4. Saying "not yet known" (issue #263)

The Interval, Peripheral latency and Supervision timeout rows vanished for a
second or two on reconnect, then came back. `resetLinkStats()` clears
`linkParams`, and unlike ATT MTU beside it — restored synchronously in
`beginSession()` from `maximumWriteValueLength` — they can only return once a
GATT read completes. The gap is real and honest. It just said nothing.

They were the only values on that screen whose absence was silent: #230 gave
Hardware / Firmware / TX power a `Not reported` sentinel, and #242 gave the
transmit counters `Reading…` and `Not responding.`

### 4a. The three states, and why there are three

`offersLinkParams` is a **tri-state**, and the reason is the second requirement:
*not yet known* and *never going to answer* must not look alike.

| `offersLinkParams` | Meaning | Rows |
|---|---|---|
| `nil` | characteristic discovery has not returned | **absent** |
| `true` | the peripheral has the characteristic | `Reading…`, then values |
| `false` | it does not, and will not grow one | **absent** |

`false` is every simulator and every board flashed before #224. Absent — not
`Reading…` — because they are not reading; they are never going to answer. The
issue permits absence explicitly here rather than a sentinel.

**`nil` is absent too, and an earlier build got this wrong.** It admitted `nil`
on the reasoning that waiting is what is happening. But `nil` means characteristic
discovery has not returned, so every simulator connect inserted three `Reading…`
rows and removed them one round trip later — #263's own complaint inverted. The
word was not even accurate: no read had been issued yet. Gating on a positive
answer also matches the requirement literally — *while connected with the
characteristic discovered but no value yet*. **Found in review, 2026-09-05.**

`offersLinkParams` is therefore **latched across `resetLinkStats()`**, not cleared
by it. It describes the peripheral's GATT database, which is stable across a
reconnect, and latching is what keeps the rows on screen through the reset instead
of flashing out and back — the same rule that latches `displayName` and `identity`
against a callback carrying nothing. The trade is a stale answer if a board is
reflashed across #224 within one app run; it costs one round trip, and a stale
`false` hides rows rather than showing wrong ones.

### 4a-ii. What `Not responding` is measured from

The first implementation inferred it from `linkStatus` being `.stalled` — which is
a statement about the **motion notify stream**, not about this read. The two are
independent, and the failure modes that stop a read returning leave the frame
stream perfectly healthy:

- an ATT error on the link-params handle (Read Not Permitted, Insufficient
  Authentication) while motion streams at 50 Hz;
- a payload that is not exactly 8 bytes, which `LinkParams.init?` rejects —
  one firmware revision away, since unlike `SophonIdentity` it does *not*
  tolerate trailing bytes.

Both produce a permanent `Reading…` under the old condition — the exact case the
state was added for. It is now measured from `linkParamsRequestedAt`, set once per
session when the read is issued, against the same 5 s threshold. ATT read errors
are also logged rather than silently discarded.

### 4b. The gap is legible

| ID | Steps | Expected |
|---|---|---|
| 4.1 | Connect a board flashed with #224 and open the detail view during the connect. | Interval / latency / timeout appear as `Reading…` and then fill with values. They must **never** be absent while connected, and the rows must not move. |
| 4.2 | Release the board and reconnect with the detail view open — the original repro, `TEST-PLAN` case 1.11. | Same: `Reading…` → values. *Before this change they disappeared for a second or two.* |
| 4.3 | Watch the row heights across 4.2. | Nothing below the link section jumps. Each row is a single List cell in every state, so the section's height is constant. |
| 4.4 | Confirm ATT MTU still behaves through the same reconnect. | Present throughout, never `Reading…` — it is restored synchronously and has no round trip to wait for. Untouched by this change. |
| 4.5 | Confirm `identity` and `TX power` still survive the reconnect. | Unchanged and never cleared. They are advertisement-scoped, not session-scoped. |

### 4c. Never going to answer

| ID | Steps | Expected |
|---|---|---|
| 4.6 | Connect to a **simulator** peripheral and open its detail view. | The three rows are **absent**, and stay absent. They must not sit at `Reading…`: an iOS peripheral has no Link Params characteristic, and Core Bluetooth exposes no API that could give it one. |
| 4.6d | From 4.6, read the **section footer**. | A line explains why the three rows are missing: no link-parameters characteristic to read them from, which is every simulated Sophon and every pre-#224 board, and is normal rather than a fault. The issue permits absence *or* saying so once; with a board on screen showing three rows and a simulator showing none, silence was the wrong half of that choice. *Reported from use 2026-09-05.* |
| 4.6a | Repeat 4.6 watching closely **during the connect**, with the detail view already on screen — reconnect after a dropout, or return from simulator mode. | The rows never appear at all. *This is the case that regressed:* three `Reading…` rows inserting and being removed one round trip later. Watch for a flash, not a steady state. |
| 4.6b | Connect a real board, disconnect it, and watch the section while it is `Disconnected` or `Released`. | The three rows **stay in place** and read `Available while connected` — the same words the transmit counters use for the same state. They must neither vanish (a row that disappears cannot explain itself — this issue's own argument) nor keep asserting the previous connection's interval under a State row saying the link is gone. *An interim build hid them; reported from use 2026-09-05.* |
| 4.6c | From 4.6b, reconnect. | `Available while connected` → `Reading…` → values, with the rows never leaving the screen and nothing below them jumping. |
| 4.7 | If a board running pre-#224 firmware is available, connect and check. | Same as 4.6 — absent. If none is to hand, this is covered by 4.6 sharing the code path. |
| 4.8 | From 4.6, switch to viewer mode with a real board and back. | Rows appear for the board and are absent for the simulator, with no leakage either way. |

### 4d. A read that never returns

| ID | Steps | Expected |
|---|---|---|
| 4.9 | Force a link that comes up, enumerates the characteristic, and then goes quiet before answering — carry the board out of range immediately after connecting. | Rows read **`Not responding`** in orange after 5 s, not `Reading…`. Hard to time; if it cannot be produced, say so rather than recording a pass. |
| 4.9a | The reachable version: build a board whose link-params handle returns an ATT error or a payload that is not 8 bytes, while motion keeps streaming. | Rows reach `Not responding` after 5 s **while the State row still reads `Connected`** and frames keep counting. This is the case the first implementation got wrong — it would have said `Reading…` forever, because it measured the frame stream rather than the read. Needs a modified firmware build; skip and say so if not doing one. |
| 4.10 | From a healthy connected board, watch the three rows for 60 s. | They hold their values and do **not** flicker between values and `Reading…`. The rows re-evaluate on a 1 s timeline, so a state that depends on anything unstable would be visible immediately. |

### 4e. RSSI — the third requirement

| ID | Steps | Expected |
|---|---|---|
| 4.11 | Open the detail view for any device. | The RSSI row is **always present**. Never having had a reading is itself the answer, and it now reads `Not reported` rather than vanishing — matching Hardware / Firmware / TX power below it. |
| 4.12 | Confirm the device **list** row still omits RSSI when there is none. | Still omitted there, deliberately. The list row is an `HStack`, not a List cell, so it carries no blank-row hazard, and a trailing `Not reported` in a compact row is noise rather than information. Only the detail view was in scope. |
| 4.13 | Re-run §3 cases 3.1, 3.5 and 3.9 against this build. | Unchanged. The RSSI row's content is the same; only its presence when nil differs. |

### 4f. Not covered

- **Whether `Reading…` is ever visible at all on a fast link.** The window is one GATT read. It may complete before the first frame is drawn, in which case 4.1 shows values immediately — which is a pass, not a failure. The requirement is that the rows never *vanish*, not that the transient is observed.
- **A peripheral that offers the characteristic and returns a malformed value.** `LinkParams.init?` rejects anything that is not exactly 8 bytes, so the row would stay at `Reading…`. Not reachable without a modified firmware, and #231 is where wire-contract misparsing belongs.
- **Discovery failing outright** (`didDiscoverCharacteristicsFor` with a non-nil error). `offersLinkParams` stays `nil`, and nothing re-issues discovery, so the rows stay **absent** for the life of that connection. That is the safe direction — hiding rows rather than claiming to be reading something nobody asked for — but it is reasoned through, not tested.
