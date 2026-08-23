# Sophon — iOS app

Central for the Sophon BLE motion peripherals. Companion to the firmware at
[`zephyr/sophon/`](../../zephyr/sophon/).

A **separate Xcode project** from `ios/FirstContact/`, not a target inside it.
Bundle `com.vwong.Sophon`, free Apple ID signing, personal use only — the same
constraints as FirstContact, documented in [`ios/CLAUDE.md`](../CLAUDE.md).

## Status

**Viewer and simulator.** Finds boards, connects, subscribes, decodes the 18-byte
frame, and counts frames, sequence gaps and transmit outcomes (#208, #215, #219,
#214). The boards now stream real 6-axis IMU data at ~54 Hz (#209).

Since #226 the app also runs the *other* side: a **simulator mode** that makes an
iPhone advertise as a Sophon and stream its own CoreMotion data, so no board is
needed to work on the app. See [Simulator mode](#simulator-mode).

No visualization yet — the 3D orientation view and axis charts are #210.

## Build and run

```bash
xcodebuild -scheme Sophon -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build

scripts/deploy-device.sh              # one connected device, auto-detected
scripts/deploy-device.sh iPad         # pick one by name, model or UDID
scripts/deploy-device.sh --all        # one build, installed on every connected device
```

The selector exists because **simulator mode needs two devices at once**. With two
or more usable devices and no selector the script fails rather than guessing, and
prints a ready-to-paste command per candidate.

Device discovery reads `devicectl`'s JSON rather than scraping its table, and
reports each device's **tunnel state** before installing:

```
==> Deploying to 3 device(s):
    iPad mini        tunnel disconnected — devicectl will try to establish one
    iPad mini 5      tunnel disconnected — devicectl will try to establish one
    violav17         tunnel disconnected — devicectl will try to establish one
```

The state is **reported, not obeyed**. `disconnected` means the tunnel is down
right now, not that the device is unusable — devicectl usually brings one up on
demand, and all three devices above installed cleanly from that state. It is not
reliable either, so a failed install is retried once; the first attempt is often
what wakes the tunnel. Only `unavailable` devices are skipped outright.

Locked devices install fine but refuse to *launch*, so the app lands and has to be
opened from the home screen.

**BLE only works on a real device.** The Simulator has no Core Bluetooth radio, so
it reports `.unsupported` and the app renders a "No Bluetooth radio" state. That
is still a useful layout check — and it is deliberately a rendered state rather
than a blank screen.

Unlike FirstContact, this project **commits a shared scheme**
(`Sophon.xcodeproj/xcshareddata/xcschemes/`). FirstContact's scheme was
auto-generated into `xcuserdata/` on first open, so `xcodebuild -scheme` works
there by luck; a hand-written project that has never been opened in Xcode has no
scheme at all. Committing it makes this build from a fresh clone.

## Structure

```
Sophon/
├── SophonApp.swift
├── ContentView.swift        mode picker; viewer's device list -> detail
├── SimulatorView.swift      the peripheral-side screen
├── BLE/
│   ├── SophonProtocol.swift frozen UUIDs, the 18-byte frame, encode + decode
│   ├── RadioState.swift     radio usability, shared by both roles
│   ├── SophonHub.swift      owns the single CBCentralManager
│   └── SophonDevice.swift   per-peripheral identity, state, link stats
└── Simulator/               mirrors zephyr/sophon/src/ file for file
    ├── SimulatorIdentity.swift   <- ident.c
    ├── MotionSource.swift        <- imu.c
    ├── SophonPeripheral.swift    <- ble.c
    ├── SophonSimulator.swift     <- main.c
    └── BackgroundKeepAlive.swift  (no firmware counterpart)
```

**The hub/device split is the multi-device design, applied before any view
exists.** An app gets exactly one `CBCentralManager`, so it cannot live on a
per-device object; and a single type holding *the* peripheral and *the* state
would bake N=1 into everything that binds to it. With one board the UI is a
one-row list; with five it needs no change. Issue #210's views attach to a
`SophonDevice`, so they are per-device by construction.

`SophonHub` scans **filtered by service UUID**, which is required — an unfiltered
scan returns nothing while the app is backgrounded.

## Simulator mode

The app has two modes, chosen from the picker in the navigation bar.

**Viewer** is the original central: scan, connect, decode, show counters.

**Simulator** turns the device into a Sophon. It advertises the Motion Service
under an ordinary `Sophon-XXXX` name and streams its own CoreMotion accelerometer
and gyroscope in the same 18-byte frame at ~52 Hz. The viewer needs no special
case — that is the point. Run the simulator on an iPhone and the viewer on an
iPad and you have a working pair with no board.

`Simulator/` mirrors `zephyr/sophon/src/` file for file, so "does the simulator
behave like the board?" is answerable by reading one file against one file.

### The two modes never share the radio

Entering simulator mode **suspends the central**: it stops scanning and cancels
every connection, including pending ones. This is not tidiness. A real board
accepts exactly one connection, so a phone that kept scanning while pretending to
be a board would connect to the real one and hold its only slot.

### Streaming while backgrounded

`bluetooth-peripheral` alone is not enough. It keeps a peripheral *wakeable* for
incoming events, but this one is push-driven — nothing asks it for a frame, it
produces them from CoreMotion — so once suspended nothing arrives to wake it and
the stream stops. A **location session** is used as a keep-alive to hold the
process scheduled. No location is read, stored or sent; only the session matters.
Expect a When-In-Use prompt and the blue status indicator while simulating.

**Killing the app stops it, and stays stopped.** Core Bluetooth state restoration
is deliberately not enabled: it got the app relaunched in the background with the
link restored but sampling never restarted, so the viewer saw a peripheral that
was connected and permanently silent. A dead simulator behaving like a
powered-off board is the honest outcome. See the comment in
`Simulator/SophonPeripheral.swift`.

"Keep the screen awake" is on by default, so the common case never needs any of
that. Turn it off to test the background path deliberately.

### Bench controls

The reason this is worth having beyond convenience:

- **Drop frames (0–20%)** — iOS's transmit queue is generous enough that
  `updateValue` essentially never fails, so `no_mem` would read zero forever. This
  reproduces the firmware's out-of-buffers path on demand, making the viewer's
  attribution checkable against a known truth for the first time. It can only fake
  "taken but never sent"; genuine loss on the air cannot be synthesised from here.
- **Reboot** — resets `seq`, uptime and counters *without* dropping the link. The
  only way to exercise the viewer's board-restart detection, since switching modes
  disconnects and clears it first.
- **Pretend the IMU is missing** — zeroed axes, exercising the viewer's no-IMU copy.

### What it is not

Not a substitute for hardware. The negotiated MTU is far larger iOS-to-iOS than
the board's 23, it will serve several centrals, and its axes are in Apple's frame
rather than the board's — **so signs and axis order will not match a real board**.
See *A second peripheral implementation* in
[`PROTOCOL.md`](../../zephyr/sophon/PROTOCOL.md) for the full list.

## Design records

**Read [`UPDATED-PLAN.md`](UPDATED-PLAN.md)** — the current plan, and the one to
trust. It is the approved design with the API-level detail corrected against what
Zephyr 4.4 and Xcode 26 actually provide.

[`ORIGINAL-PLAN.md`](ORIGINAL-PLAN.md) is the frozen snapshot of that design as
approved *before* #208 was implemented, kept deliberately un-updated. Where the
two disagree, `UPDATED-PLAN.md` is right. Consult the original only when you want
to know what was originally intended — a plan that quietly rewrites itself to
match the code stops being evidence of anything.

Either is worth reading because the reasoning is not recoverable from the source:
the ATT MTU budget, the connection-event supply/demand derivation, the
batching-vs-DLE arithmetic, and why the Zephyr app is freestanding. Read before
changing the frame size, the sample rate, or the MTU. They cover **both** halves
despite living here.

[`SIMULATOR-PLAN.md`](SIMULATOR-PLAN.md) is the same kind of frozen record for
#226's simulator mode, approved before that work started. Its header notes the two
places the plan was wrong on the way to being approved, which are left visible
rather than tidied away.

`zephyr/sophon/PROTOCOL.md` holds the live wire contract and is kept current. Note
it now has **three** implementers rather than two — the firmware, the app's
decoder, and the simulator's encoder.
