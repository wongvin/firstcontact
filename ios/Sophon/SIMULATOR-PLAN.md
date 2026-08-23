<!--
Frozen as approved on 2026-08-22, before any code was written for #226.

The simulator counterpart to ORIGINAL-PLAN.md / UPDATED-PLAN.md, following the
same rule: a record of what was agreed, NOT a live document. Do not edit it to
match what was eventually built. Where the implementation diverged, PROTOCOL.md
and the Sophon README are the current truth; this file records what was intended
and why.

Worth knowing when reading it:

  - The "Background operation" section reached its conclusion by correction. An
    earlier draft said to add no background modes at all and to keep the screen
    awake instead. That was wrong for a push-driven peripheral, and the reasoning
    that replaced it -- that `bluetooth-peripheral` keeps an app *wakeable* but
    cannot keep a *streaming* peripheral scheduled -- is the load-bearing part.

  - The "Housekeeping" section records a real error found while planning: a
    result reported during #209 turned out to be an identity rather than a
    measurement. It is kept here, rather than tidied away, because the mistake
    is more instructive than the plan.
-->
# Sophon iPhone simulator — stream CoreMotion over BLE

## Context

Sophon is one Zephyr board (`zephyr/sophon/`) streaming a 6-axis IMU to an iOS central
(`ios/Sophon/`). Every app change has to be tested against physical hardware, and #211
— multi-device batching and cross-device time sync — needs *several* peripherals. There
is one board.

This adds a **simulator mode** to the existing app: an iPhone acts as a BLE peripheral,
advertising the Sophon Motion Service and streaming its own CoreMotion accelerometer and
gyroscope in the frozen 18-byte frame at ~52 Hz. An iPad runs the same app in viewer mode
and connects to it as though it were a board. **It must keep streaming while the iPhone
sleeps.**

Outcomes:

- App development stops being gated on the one board being flashed and to hand.
- #211 gets a second and third peripheral without buying hardware.
- The app's attribution counters become **testable for the first time**, because we
  control the transmitter and can inject known drops.

Decided with the user: **one app with a mode switch** (not a second target), so the frame
encoder sits beside the decoder and cannot drift; and an **indistinguishable**
`Sophon-XXXX` name, so the viewer needs no special-casing.

## Housekeeping — do this first, it is unrelated

`lostOnAir` is **defined** as `max(0, seqGaps - Int(tx.noBuffer))`
(`SophonDevice.swift:228-231`); its doc comment explicitly rejects `sent - received`.

So the `26 + 136 = 162` reported during #209 was an **identity, not a measurement** — it
could not have come out otherwise. I called it "independent counters complementing
exactly" and offered it as evidence the attribution works. That is wrong, and it is in
the merged **PR #225 body (line 9)** and in issue comments.

Edit the PR body and post a retraction on #209. The engineering conclusions are
unaffected, and the 30/30 figure from the Python soak *was* independent (gaps from
sequence numbers, `no_mem` from the characteristic), so `PROTOCOL.md` stands as written.

## Background operation — required, and why a keep-alive is part of it

Two background modes doing two different jobs. Both are needed; neither substitutes for
the other.

**`bluetooth-peripheral`** keeps the GATT server registered and lets iOS wake the app for
BLE events. Necessary, but **not sufficient** — this peripheral is *push-driven*. It is not
answering the central, it is pushing notifications paced by CoreMotion. Once suspended,
nothing generates an event to wake it, so nothing pushes, so it stays suspended. (The iPad's
2 s stats poll does wake it, which buys a stutter, not 52 Hz.)

**`location`** is therefore the keep-alive, holding the process scheduled so the CoreMotion
subscription and the notify loop both keep running. Chosen over silent audio. The location
is never read, stored, or transmitted — only the session's existence matters.

New `Simulator/BackgroundKeepAlive.swift`:

- `requestWhenInUseAuthorization()` — Always is not required.
- `allowsBackgroundLocationUpdates = true` — **throws at runtime unless `location` is in
  `UIBackgroundModes`**, so plist and code must land in the same change.
- `pausesLocationUpdatesAutomatically = false` — **the line that actually decides whether
  this works.** iOS otherwise pauses updates once it judges the device stationary, which is
  exactly what a phone simulating a sensor on a desk is. The keep-alive would die precisely
  when it is needed, and it would look like a CoreMotion bug.
- `activityType = .other`, `desiredAccuracy = kCLLocationAccuracyThreeKilometers` — the
  cheapest configuration that still counts as an active session.
- Delegate discards every fix. Started on entering simulator mode, stopped on leaving, so
  nothing runs in viewer mode.

Costs a When-In-Use prompt and the blue status indicator while simulating — which doubles as
a visible reminder that the simulator is live.

Keep `isIdleTimerDisabled = true` as well, behind a toggle: the screen-on case then needs no
background path at all, and turning it off is how the background path gets tested on purpose.

Add `CBPeripheralManagerOptionRestoreIdentifierKey` plus
`peripheralManager(_:willRestoreState:)` so an app iOS relaunches resumes serving instead of
going quiet.

**Consequence to accept deliberately**: iOS strips `CBAdvertisementDataLocalNameKey` from
background advertisements and moves the service UUID into the overflow area. Filtered
scanning still finds it (`SophonHub.swift:87-90`), but a peripheral *first discovered* while
backgrounded carries no local name, and `SophonDevice.init` (`:83`) falls back to
`peripheral.name` — the iPhone's device name. Connect while foregrounded and `displayName`
persists across reconnects. Guard `didDiscover` so a nil advertised name never overwrites a
good one.

## Design

### 1. `BLE/SophonProtocol.swift` — the encoder (modify)

Both types have **only** `init?(_ data: Data)`, so Swift suppresses the memberwise init
and a `MotionFrame` cannot currently be constructed at all. Add, all `nonisolated`:

- `MotionFrame.init(seq:tMillis:ax:ay:az:gx:gy:gz:)` + `var encoded: Data` (18 B LE)
- `TxStats.init(sent:noConn:noBuffer:other:)` + `var encoded: Data` (16 B LE)

Place each encoder **directly beneath its decoder**, mirroring the decoder's
byte-at-a-time style — including splitting `tMillis` into the same two `UInt16` writes
the decoder reads at `:106`, so the two can be diffed by eye.

**Saturating conversion — this is a crash, not a nicety.** `Int16(200_000.0)` traps, and
so does `Int16(Double.nan)`. A wrist flick exceeds the frame's 327.67 dps ceiling in
normal use. One helper, clamping in `Double` space *before* the conversion, mirroring
`clamp16()`/`div_round()` in `zephyr/sophon/src/imu.c:69-76`. `Double.rounded()` already
defaults to half-away-from-zero, matching `div_round`.

**Self-check**: a round trip through our own decoder cannot catch a symmetric endianness
or offset bug — the exact failure the file header warns about. So assert against a
**hardcoded golden byte vector transcribed from PROTOCOL.md's offset table**, not from the
Swift. Include `Int16.min`/`.max`, a negative, and a `tMillis` with four distinct bytes.
Run under `#if DEBUG` from `SophonApp.init()`. There is no test target.

### 2. `BLE/RadioState.swift` (new)

Hoist `SophonHub.RadioState` (`:15-23`) to file scope, renaming `.scanning` → `.ready`
and adding `.idle` (radio fine, this role deliberately off air). The four failure cases
are properties of the radio and identical in both roles, so one `RadioUnavailableView`
serves both — which is what `ContentView.swift:166-167` already argues for. Give that view
a `purpose: String` ("to find Sophons" / "to advertise as a Sophon").

### 3. `BLE/SophonHub.swift` — suspend/resume (modify)

In simulator mode the iPhone's central must stop, or it will connect to a real board and
consume its only slot (`CONFIG_BT_MAX_CONN=1`).

Collapse the three inputs that decide "should the scan run?" — `CBManagerState`,
deliberate suspension, launch order — into a single `applyRadioState()`, replacing the
inline handling at `:97-114` and deleting the private `startScan()` (`:82`). Adding a
second condition inline is how ordering bugs get written.

Three correctness points, each a real bug if missed:

- **Set `isSuspended = true` before cancelling.** `cancelPeripheralConnection` is async and
  `didDisconnectPeripheral`'s body runs inside `Task { @MainActor }` (`:183`); the flag must
  be visible to those deferred bodies.
- **Cancel every known peripheral, not just connected ones.** `:192` re-arms with
  `central.connect(peripheral)`, and an outstanding iOS `connect()` **never times out** —
  so a `.disconnected` device can still grab the board later.
- **Guard both paths**: `connect(_:)` at `:66` and the re-arm at `:192`. Together these
  make the launch race benign, since `SophonHub` is constructed at `ContentView.swift:4`
  before the mode is applied.

Do not clear `devices`; `resetLinkStats()` already runs on every `didConnect` (`:156`).

### 4. `Simulator/` — four files mirroring the firmware

The split is deliberate: the same decomposition as `zephyr/sophon/src/`, so "does the
simulator do what the board does?" is answerable one file against one file. Cite the
counterpart in each header.

| File | Firmware analogue | Responsibility |
|---|---|---|
| `SimulatorIdentity.swift` | `ident.c` | `Sophon-XXXX` from the low 16 bits of `identifierForVendor`, persisted in `UserDefaults` (IDFV is nil before first unlock and changes on full uninstall — less stable than FICR) |
| `MotionSource.swift` | `imu.c` | CoreMotion → clamped wire units |
| `SophonPeripheral.swift` | `ble.c` | GATT server, advertising, notify, counters |
| `SophonSimulator.swift` | `main.c` | frame assembly, `seq`, `t_ms`, policy |
| `BackgroundKeepAlive.swift` | — | location session so the stream survives backgrounding |

**Sampling** — raw `startAccelerometerUpdates(to: .main)` at `1.0/52.0` as the pacer, with
handler-less `startGyroUpdates()` polled via `.gyroData`. Raw, **not**
`startDeviceMotionUpdates`: the board sends raw gravity-inclusive accel and uncorrected
gyro, whereas `deviceMotion` returns bias-corrected, fused estimates. The ≤1-sample
pairing skew is *faithful* — the LSM6DSL ORs two independent ODRs onto one DRDY line and
`imu.c:120-170` reads both channels after one fetch with the same caveat.

Use `MainActor.assumeIsolated` (precedent: `SophonHub.swift:53`) rather than a `Task` hop —
the queue is already `.main`, and a Task per sample at 52 Hz defers the frame past the next
runloop turn, manufacturing the jitter this app exists to measure.

Units: accel g × 1000 → milli-g; gyro rad/s × 5729.577951 → centi-deg/s (same constant as
`gyro_to_cdps`). Every axis through the saturating helper.

**If no accelerometer** (the iOS Simulator), fall back to 1 Hz zero-filled frames exactly
as `main.c:288-293` does for a missing IMU.

**`seq` and counters — the fidelity contract:**

- No subscribers → `seq` **does not advance**, nothing sent (matches `build_frame`).
- `updateValue` true → `sent += 1`; false → `noBuffer += 1`, frame dropped, **`seq` never
  rewound**. Structurally unreachable: `seq` lives in `SophonSimulator`.
- **Do not retry** from `peripheralManagerIsReady`. A retry delivers a stale sample with an
  old `t_ms`, which is worse than a hole, and it decouples `noBuffer` from observed gaps —
  destroying the one-to-one attribution. Implement it only to count recoveries.
- `noConn` will read ~0, correctly: `main.c:169-171` never notifies when unsubscribed.

**Two Core Bluetooth traps**: `CBMutableCharacteristic` must be built with `value: nil` —
a cached value is served without calling the read handler, and combining a cached value
with `.notify` raises. And `add(service)` only after `.poweredOn`, `startAdvertising` only
from `peripheralManagerDidAdd`, with `removeAllServices()` on stop or re-entry throws
"service already added".

**`t_ms`** from `CMAccelerometerData.timestamp` (mach-uptime, monotonic) minus a base taken
at the first sample after start — matching `k_uptime_get_32()`. `UInt32(truncatingIfNeeded:)`
so nothing can trap.

**Throttle the UI.** A 52 Hz `@Observable` write drives SwiftUI at 52 Hz on the very thread
pacing the radio. Keep hot state `@ObservationIgnored` and publish one `Display` snapshot at
~10 Hz.

### 5. Bench controls — the reason this is worth building

- **Drop frames, 0–20%** — skip `updateValue`, advance `seq` anyway, bump `noBuffer`. iOS's
  transmit queue is generous, so `updateValue` will essentially never fail on its own and
  `noBuffer` would sit at zero forever. This reproduces the `-ENOMEM` path on demand and
  makes `seqGaps == noBuffer` verifiable for the first time. ~8 lines, highest value in the
  plan. (It cannot fake `lostOnAir` — only "never sent", not "sent and lost". Say so.)
- **Reboot** — resets `seq`, the `t_ms` base and the counters **without dropping the link**.
  This matters: toggling mode drops the connection, and `resetLinkStats()` (`:161-176`) zeroes
  `boardRestarts` before the new `t_ms` is ever compared, so mode-toggling does *not* exercise
  `SophonDevice.swift:107-123`. Only an in-place reboot does.
- **Pretend the IMU is missing** — exercises the viewer's `isAxesZero` path.

Keep these unconditional, not `#if DEBUG`; the whole app is a diagnostic tool.

### 6. UI — `ContentView.swift` (modify) + `SimulatorView.swift` (new)

`@AppStorage("appMode")`, a `Menu`-wrapped `Picker` in the toolbar (no `.toolbar` exists
today), and `.onChange(of: mode, initial: true)` applying **peripheral down before central
up, and vice versa — never both on air**.

Put `.id(mode)` on the `NavigationStack`, never on `ContentView` — on the latter it would
destroy `@State hub` and build a fresh `CBCentralManager` every toggle. It resets the nav
stack so a pushed `DeviceDetailView` cannot survive into simulator mode and keep polling a
peripheral this app just dropped.

Lift the existing viewer body verbatim into `private struct ViewerView` — zero behaviour
change. `SimulatorView` shows identity, link (subscribers, max update length), **nominal vs
sensor vs notify rate** (the split makes dropped frames legible), motion in the *same format*
as `ContentView.swift:250-251` so the screens can be compared literally, frame `seq`/`t_ms`,
counters, and the bench controls.

Drive-by: `ContentView.swift:246` still says "Real IMU data arrives in #209", which shipped.

### 7. Supporting changes

- **`Info.plist`** — `UIBackgroundModes: [bluetooth-peripheral, location]`;
  `NSLocationWhenInUseUsageDescription` stating plainly that location is used only to keep the
  app running while streaming and is never recorded; `NSMotionUsageDescription` (strictly
  required for `CMMotionActivityManager`/`CMPedometer`, not raw `CMMotionManager` — declared
  anyway because the penalty for being wrong is a TCC kill and an unused string costs nothing);
  reword `NSBluetoothAlwaysUsageDescription` to cover the peripheral role.
- **`scripts/deploy-device.sh`** — optional substring filter + `--all`. With ≥2 devices and no
  filter, **fail with a ready-to-paste command per candidate** rather than silently taking the
  first; two attached devices is now the normal case. Behaviour with one device is unchanged, so
  `ios/CLAUDE.md`'s "never hardcode a UDID" still holds — the selector comes from the call site.
  Two constraints: tighten the state test (`tolower($0) ~ /connected/` also matches a device
  *named* "connected"; require the field after the UUID to equal `connected`), and bash here is
  **3.2** — no `mapfile`, no associative arrays, and `while read` in a pipeline subshells.
- **Docs** — `ios/Sophon/README.md` (simulator mode, radio contention and why, sleep behaviour);
  `zephyr/sophon/PROTOCOL.md` gains *A second peripheral implementation* listing the honest
  divergences: MTU ~185 not 23, multiple centrals possible, `no_conn` ~0, Apple's axis frame and
  sign convention, `t_ms` from sim start, artificial drops with no hardware counterpart;
  `ChangeLog.md` under today's date, `feat:`.

### 8. Not in scope

No new target, no second bundle ID. No change to `SophonDevice` or the viewer's attribution UI —
the simulator is meant to be indistinguishable, so needing to change the viewer means something is
wrong. Throttling `SophonDevice.ingest`'s own 52 Hz observation churn is a real follow-up, filed
separately.

## Process

Per `CLAUDE.md`: file a `sophon:` issue **first**, In progress + today's Start date, branch
`<N>-sophon-simulator`, pause for consent before staging.

## Verification

### Go/no-go, before building the UI

1. **Does the advertised name survive?** iOS decides whether the local name lands in the
   advertisement or the scan response, and there is no API to influence it. If the iPad shows the
   iPhone's device name instead of `Sophon-XXXX`, the escape hatch is renaming the iPhone in
   Settings. Find this out on day one.
2. **Does the stream survive backgrounding and lock?** Connect, turn the idle-timer toggle off,
   lock the phone, and watch the iPad for several minutes. Frames must keep arriving at ~52 Hz with
   no growing gap count. Check specifically that it still holds after the phone has been *stationary*
   for a few minutes — that is what `pausesLocationUpdatesAutomatically = false` exists to prevent,
   and a naive implementation looks fine for 60 seconds and then dies.
3. **Does it survive a long run?** Leave it locked for 30+ minutes. Confirm the app was not
   reclaimed, and that `seq` is continuous rather than restarted (a restart means iOS killed and
   relaunched us, which is what the state-restoration path is for).

### Then

4. iOS Simulator screenshots, both modes, iPhone + iPad sims — mandatory per `ios/CLAUDE.md` for any
   SwiftUI change. CB is `.unsupported` and there is no accelerometer, so this exercises the shared
   `RadioUnavailableView` and the no-IMU fallback, and confirms the DEBUG self-check passes at launch.
4. `scripts/deploy-device.sh --all`.
5. iPhone → Simulator: advertising, subscribers 0, sensor ~52 Hz, and **`seq` stays 0** — proving it
   advances only while subscribed.
6. iPad → Viewer: connects; **read Accel/Gyro on both screens at once — they must match.** That is the
   end-to-end encoder/decoder proof and the reason both views use identical formatting.
7. **Physics sanity**: flat on a table, one accel axis ≈ ±1000 mg and the others ≈ 0, gyro ≈ 0. Rotate
   and confirm the expected gyro axis responds. This is what catches a units error; a byte test cannot.
8. **Attribution**: set drop = 10%. `Lost on link` and `TX buffer full` must climb *by the same amount*,
   `Lost on air` stays 0, and the sentence at `ContentView.swift:275` reads "dropped on the Sophon before
   sending". First real verification of #215.
9. **Reboot** with the link up → viewer counts exactly 1 restart.
10. **Radio contention**: real board powered on with the iPhone simulating. The iPad holds both; power-cycle
    the board and confirm it reacquires — proof the suspended central is not stealing the slot. Switch the
    iPhone back to Viewer and confirm it rediscovers the board — proof `resume()` works.
11. A hard wrist flick during step 6 exercises saturation. No crash is the pass.
