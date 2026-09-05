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
