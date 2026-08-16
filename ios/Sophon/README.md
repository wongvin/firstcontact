# Sophon — iOS app

Central for the Sophon BLE motion peripherals. Companion to the firmware at
[`zephyr/sophon/`](../../zephyr/sophon/).

A **separate Xcode project** from `ios/FirstContact/`, not a target inside it.
Bundle `com.vwong.Sophon`, free Apple ID signing, personal use only — the same
constraints as FirstContact, documented in [`ios/CLAUDE.md`](../CLAUDE.md).

## Status

**Skeleton (#208).** Finds boards, connects, subscribes, decodes the 18-byte
frame, and counts frames and sequence gaps. No visualization yet — the 3D
orientation view and axis charts are #210, and the frames themselves carry zeroed
axes until #209.

## Build and run

```bash
xcodebuild -scheme Sophon -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build

scripts/deploy-device.sh     # physical iPhone, auto-detects the connected device
```

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
├── ContentView.swift        device list -> detail
└── BLE/
    ├── SophonProtocol.swift frozen UUIDs + the 18-byte frame decoder
    ├── SophonHub.swift      owns the single CBCentralManager
    └── SophonDevice.swift   per-peripheral identity, state, link stats
```

**The hub/device split is the multi-device design, applied before any view
exists.** An app gets exactly one `CBCentralManager`, so it cannot live on a
per-device object; and a single type holding *the* peripheral and *the* state
would bake N=1 into everything that binds to it. With one board the UI is a
one-row list; with five it needs no change. Issue #210's views attach to a
`SophonDevice`, so they are per-device by construction.

`SophonHub` scans **filtered by service UUID**, which is required — an unfiltered
scan returns nothing while the app is backgrounded.

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

`zephyr/sophon/PROTOCOL.md` holds the live wire contract and is kept current.
