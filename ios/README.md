# ios

Two native iOS apps, each its own Xcode project. Personal use, signed with a free
Apple ID — not distributed via TestFlight or the App Store.

Target conventions, including the free-signing bootstrap and the verification
rules, are in [CLAUDE.md](CLAUDE.md).

## The apps

### [`FirstContact/`](FirstContact/)

News reader with keyword filtering, a 30-day work-summary panel, and
device-to-device sync of keywords and messages.

### [`Sophon/`](Sophon/)

Viewer for the Sophon motion sensor, plus a **simulator mode** that turns a spare
iPhone or iPad into a stand-in Sophon so app work does not need the board. Pairs
with the firmware at [`zephyr/sophon/`](../zephyr/sophon/) — one logical project
across two folders, sharing the wire contract in
[`PROTOCOL.md`](../zephyr/sophon/PROTOCOL.md).

## Technologies

Both projects: **Swift 5** with **SwiftUI**, `SWIFT_DEFAULT_ACTOR_ISOLATION =
MainActor`, deployment target iOS 26, and `TARGETED_DEVICE_FAMILY = "1,2"` so a
single binary runs on iPhone and iPad.

| Framework | Where | What for |
|---|---|---|
| **SwiftUI** | both | the entire UI; no UIKit view controllers |
| **Observation** (`@Observable`) | Sophon | models the views bind to, with hot per-frame state marked `@ObservationIgnored` so a 54 Hz stream does not invalidate the UI 54 times a second |
| **Core Bluetooth** | Sophon | `CBCentralManager` for the viewer, `CBPeripheralManager` for the simulator — the same app plays both roles, never at once |
| **Core Motion** | Sophon | raw accelerometer and gyroscope for the simulator, paced by the accelerometer handler rather than a timer |
| **Core Location** | Sophon | *not* for location. A coarse session keeps the process scheduled so the simulator survives backgrounding; the fix is never read. See [`BackgroundKeepAlive.swift`](Sophon/Sophon/Simulator/BackgroundKeepAlive.swift) |
| **Multipeer Connectivity** | FirstContact | symmetric device-to-device sync — each device both advertises and browses, merging by last-writer-wins with tombstones |
| **CryptoKit** | FirstContact | identity/integrity for the sync payloads |
| **Combine** | FirstContact | change publishing in the sync store |
| **WebKit** | FirstContact | in-app article rendering |
| **`os.Logger`** | both | structured logging, with `privacy:` annotations on anything device-identifying |
| **`URLSession` + `async/await`** | FirstContact | all plain HTTP |

### Dependencies

**One**, via Swift Package Manager:
[`google/generative-ai-swift`](https://github.com/google/generative-ai-swift)
(≥ 0.5.6), for the 30-day summary panel in FirstContact. Sophon has none.

Per [CLAUDE.md](CLAUDE.md), packages are allowed when they earn their weight, with
official first-party SDKs preferred. Its API key is a build-time secret — see the
`Secrets.xcconfig` section in CLAUDE.md, which also explains why the
`INFOPLIST_KEY_*` route does not work.

### Concurrency

Both projects build with **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`**, which
shapes more of the code than it sounds like. Core Bluetooth delegate callbacks are
`nonisolated`, so anything they touch must be too — hence the `nonisolated` wire
types in `SophonProtocol.swift`.

Callbacks reach the main actor two ways, and the choice is not stylistic:
`Task { @MainActor in … }` where only `Sendable` scalars cross, and
`MainActor.assumeIsolated` where they cannot — `CBService`, `CBCharacteristic` and
`CBATTRequest` are not `Sendable` and must not cross an isolation boundary at all.
The managers are created with `queue: .main`, which is what makes the assumption
sound; it traps loudly if that ever stops being true.

## Testing

There is no test target in either project. `xcodebuild` succeeding proves syntax
and nothing else, so **any change touching a SwiftUI view needs a simulator
screenshot read before it ships**, and anything touching Bluetooth or motion needs
a physical device — the iOS Simulator has no Core Bluetooth radio and no motion
hardware. Both rules, and the exact commands, are in [CLAUDE.md](CLAUDE.md).

Sophon's wire format is checked at launch under `#if DEBUG` against byte vectors
transcribed from `PROTOCOL.md` — not round-tripped through its own decoder, which
would pass happily while disagreeing with the firmware.

## Deploying to a device

```bash
ios/FirstContact/scripts/deploy-device.sh
ios/Sophon/scripts/deploy-device.sh --all          # every usable device
ios/Sophon/scripts/deploy-device.sh iPad           # pick one by name or UDID
ios/Sophon/scripts/deploy-device.sh --no-launch    # install without restarting
```

Sophon's script takes a selector because simulator mode needs two devices at once.
Free-signing profiles expire after about 7 days; redeploying re-signs.
