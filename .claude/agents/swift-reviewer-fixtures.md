# swift-reviewer regression fixtures

Known-bad code that **actually shipped or nearly shipped** in this repo, kept so
`swift-reviewer` can be re-validated whenever it changes.

Markdown, not Swift, deliberately: these must not compile into any target, and
they are evidence rather than examples to copy.

## How to run the acceptance test

Point the agent at this file and check it names the expected rule for each case.
An agent that misses these is not worth running. One that flags the *fixed*
versions in `ios/Sophon/` is producing false positives and is equally useless —
check both directions.

| # | Defect | Expect rule | Real origin |
|---|---|---|---|
| A | staleness computed in a view body | 1 | #235, shipped to device |
| B | model upkeep on a view's `.task` | 2 | #235, shipped to device |
| C | unconditional `@Observable` write | 3 | #235, caught in review |
| D | sentinel blanks a good value | 5 | #235, user-reported flicker |
| E | advertisement-scoped field in a session reset | 4 | #230, caught in review |
| F | non-`Sendable` CB type across a hop | 6 | #228-era pattern |

---

## A — staleness computed in a view body (rule 1)

```swift
// In DeviceDetailView.linkSection
if device.isStaleReleased() {          // <- calls Date() internally
    Text("Not reachable.")
} else {
    Button("Connect", action: onToggleConnection)
}
```

```swift
func isStaleReleased(asOf now: Date = Date()) -> Bool {
    guard isReleasedByUser, !isHeld else { return false }
    guard let lastSeenAt else { return true }
    return now.timeIntervalSince(lastSeenAt) > Self.releasedSilenceThreshold
}
```

**Why it fails**: nothing observable changes when a board goes quiet, so the body
is never re-evaluated and the branch never flips. The control stayed on `Connect`
indefinitely.

## B — model upkeep owned by a view's `.task` (rule 2)

```swift
List(hub.devices) { device in
    NavigationLink { DeviceDetailView(device: device) } label: { DeviceRow(device: device) }
}
.task {
    while !Task.isCancelled {
        hub.forgetStaleReleased()
        try? await Task.sleep(for: .seconds(1))
    }
}
```

**Why it fails**: `NavigationStack` disappears the source view on push, cancelling
the task — so evaluation stopped exactly while the detail view depending on it
was open.

## C — unconditional `@Observable` write (rule 3)

```swift
func evaluateStaleness(asOf now: Date = Date()) {
    isStaleReleased = now.timeIntervalSince(lastSeenAt) > Self.releasedSilenceThreshold
}
```

**Why it fails**: called once a second for every device. Observation notifies on
every assignment, equal or not, so the whole list redraws every second for nothing.

## D — sentinel blanks a good value (rule 5)

```swift
// 127 is Core Bluetooth's "not available" sentinel, not a real reading.
device.rssi = rssi == 127 ? nil : rssi
```

```swift
if let rssi = device.rssi {
    LabeledContent("RSSI", value: "\(rssi) dBm")
}
```

**Why it fails**: one sentinel among tens of samples a second blanks a good value,
and the `if let` takes the whole row with it. Invisible at one callback per board;
obvious under duplicate scan reporting.

## E — advertisement-scoped field in a session reset (rule 4)

```swift
func resetLinkStats() {
    framesReceived = 0
    attMTU = nil
    identity = nil        // <- lifetime is the advertisement, not the session
    txPower = nil         // <- same
}
```

**Why it fails**: nothing re-delivers an advertisement on demand, so these never
come back for the rest of the session. The `attMTU` line is the same bug, already
documented in `SophonDevice.swift`.

## F — non-`Sendable` Core Bluetooth type across a hop (rule 6)

```swift
nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
    Task { @MainActor in
        for service in p.services ?? [] {       // CBService is not Sendable
            p.discoverCharacteristics(nil, for: service)
        }
    }
}
```

**Why it fails**: `CBService` cannot cross an isolation boundary. Requires
`MainActor.assumeIsolated`, which the managers being created with `queue: .main`
is what makes sound.
