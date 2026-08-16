import SwiftUI

struct ContentView: View {
    @State private var hub = SophonHub()

    var body: some View {
        NavigationStack {
            Group {
                if !hub.radio.isUsable {
                    RadioUnavailableView(state: hub.radio)
                } else if hub.devices.isEmpty {
                    ContentUnavailableView {
                        Label("Looking for Sophons", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text("Power on a Sophon and it will appear here.")
                    }
                } else {
                    List(hub.devices) { device in
                        NavigationLink {
                            DeviceDetailView(device: device) { hub.refreshStats(device) }
                        } label: {
                            DeviceRow(device: device)
                        }
                    }
                }
            }
            .navigationTitle("Sophon")
        }
    }
}

/// The simulator has no Core Bluetooth hardware, so this is what a simulator
/// screenshot shows. Worth rendering properly rather than leaving blank.
private struct RadioUnavailableView: View {
    let state: SophonHub.RadioState

    private var message: (icon: String, title: String, detail: String) {
        switch state {
        case .poweredOff:
            ("bluetooth.slash", "Bluetooth is off", "Turn Bluetooth on to find Sophons.")
        case .unauthorized:
            ("hand.raised", "Bluetooth not permitted", "Allow Bluetooth for Sophon in Settings.")
        case .unsupported:
            ("iphone.slash", "No Bluetooth radio", "This device has no Core Bluetooth support — expected in the Simulator.")
        default:
            ("hourglass", "Starting up", "Waiting for the Bluetooth radio.")
        }
    }

    var body: some View {
        ContentUnavailableView {
            Label(message.title, systemImage: message.icon)
        } description: {
            Text(message.detail)
        }
    }
}

private struct DeviceRow: View {
    let device: SophonDevice

    var body: some View {
        HStack {
            StateDot(state: device.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.body)
                Text(device.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let rssi = device.rssi {
                Text("\(rssi) dBm")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct StateDot: View {
    let state: SophonDevice.State

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }

    private var color: Color {
        switch state {
        case .connected: .green
        case .connecting: .orange
        case .discovered: .secondary
        case .disconnected: .red
        }
    }
}

private struct DeviceDetailView: View {
    let device: SophonDevice
    let onRefresh: () -> Void

    /// Regular width gets two columns; compact keeps the single list.
    ///
    /// Keyed off the size class rather than the device model, so an iPad in a
    /// narrow split-screen slot correctly gets the phone layout instead of two
    /// columns squeezed into half a screen.
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// How often the Sophon's counters are re-read while this view is on screen.
    ///
    /// Polling rather than subscribing, and only while visible. A notify would
    /// push on every change, and `sent` changes on *every frame* — so the stats
    /// would notify as often as the data itself, which is absurd at #209's
    /// 50 Hz. A read every couple of seconds costs about 0.5 reads per second
    /// whatever the sample rate, and stops entirely when nobody is looking at
    /// it.
    private static let refreshInterval = Duration.seconds(2)

    var body: some View {
        Group {
            if sizeClass == .regular {
                // Left holds the two counts you scan at a glance; right holds
                // the live values and the transmit detail.
                //
                // This does separate Frames from the transmit counters, which
                // #219 had placed adjacent because they answer one question
                // between them — how much arrived, and whose fault the rest
                // was. On a desk console at large type that pairing loses to
                // the practical constraint: only so much fits in a column, and
                // Motion is about to grow six live values (#209).
                HStack(alignment: .top, spacing: 0) {
                    List {
                        linkSection
                        framesSection
                    }
                    Divider()
                    List {
                        motionSection
                        countersSection
                    }
                }
            } else {
                List {
                    linkSection
                    framesSection
                    countersSection
                    motionSection
                }
            }
        }
        .navigationTitle(device.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // .task sits on the Group, not inside a branch, so the polling behaves
        // identically in both layouts — and is still cancelled automatically
        // when the view disappears.
        .task {
            while !Task.isCancelled {
                onRefresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    // Sections are defined once and composed by both layouts. Two divergent
    // copies of the same content would drift the moment one was edited.

    @ViewBuilder private var linkSection: some View {
        Section("Link") {
            LabeledContent("State", value: device.state.label)
            if let rssi = device.rssi {
                LabeledContent("RSSI", value: "\(rssi) dBm")
            }
            if let mtu = device.attMTU {
                LabeledContent("ATT MTU", value: "~\(mtu)")
            }
        }
    }

    @ViewBuilder private var framesSection: some View {
        Section("Frames") {
            LabeledContent("Received", value: "\(device.framesReceived)")
            LabeledContent("Lost on link", value: "\(device.seqGaps)")
            if device.boardRestarts > 0 {
                // Detected exactly, via Sophon uptime running backwards.
                LabeledContent("Sophon restarts", value: "\(device.boardRestarts)")
            }
            // Always shown, including at zero. A field that only appears once
            // something has gone wrong reads as an error banner; a field
            // permanently at 0 reads as a clean bill of health, and its absence
            // at startup would leave you wondering whether the app was
            // measuring this at all.
            LabeledContent(
                "App interruptions",
                value: device.interruptions == 0
                    ? "0"
                    : "\(device.interruptions) · \(device.framesDuringInterruptions) frames")
            if let frame = device.lastFrame {
                LabeledContent("Last seq", value: "\(frame.seq)")
                LabeledContent("Sophon uptime", value: "\(frame.tMillis) ms")
            }
        }
    }

    /// A gap says an interval has no data; only these say whether the frames
    /// were lost on the air or never left the Sophon. The two sit together in
    /// the compact layout. In the wide layout they are in separate columns but
    /// both on screen at once, which serves the same comparison.
    @ViewBuilder private var countersSection: some View {
        Section {
            if let tx = device.txThisSession {
                // Every figure here is scoped to this connection, so it is
                // directly comparable with the frame counts.
                LabeledContent("Sent by Sophon", value: "\(tx.sent)")
                if let lost = device.lostOnAir {
                    LabeledContent("Lost on air", value: "\(lost)")
                }
                LabeledContent("TX buffer full", value: "\(tx.noBuffer)")
                if tx.other > 0 {
                    LabeledContent("Other TX errors", value: "\(tx.other)")
                }
                Text(attribution(device: device))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if device.state.isConnected {
                Text("Reading…").foregroundStyle(.secondary)
            } else {
                Text("Available while connected.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Sophon transmit counters")
        } footer: {
            if device.txStatsAt != nil {
                Text("Scoped to this connection; the Sophon's own totals run since it booted, so they are rebased on connect to stay comparable with the counts above. Re-read every 2s while this screen is open — polled rather than subscribed, and stops when you navigate away.")
            }
        }
    }

    @ViewBuilder private var motionSection: some View {
        if let frame = device.lastFrame {
            Section("Motion") {
                if frame.isAxesZero {
                    // The skeleton (#208) sends zeroed axes on purpose. Saying
                    // so beats showing six zeros that look like a bug.
                    Text("Axes are zero — firmware is streaming the skeleton frame. Real IMU data arrives in #209.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Accel", value: "\(frame.ax), \(frame.ay), \(frame.az) mg")
                LabeledContent("Gyro", value: "\(frame.gx), \(frame.gy), \(frame.gz) cdps")
            }
        }
    }
}

/// Turns the two numbers into the sentence they exist to support. This is the
/// entire value of showing board counters next to app counters — without it the
/// reader has to know what `noBuffer` means to interpret a gap.
private func attribution(device: SophonDevice) -> String {
    guard let tx = device.txThisSession else { return "" }
    guard let lost = device.lostOnAir else { return "" }

    let interrupted = device.framesDuringInterruptions
    let aside = interrupted > 0
        ? " Separately, \(interrupted) frame(s) were sent while this app was not listening — not lost, just unobserved."
        : ""

    switch (tx.noBuffer, lost) {
    case (0, 0):
        return "Everything the Sophon sent arrived, and nothing was dropped before sending — the link is keeping up." + aside
    case (0, _):
        return "\(lost) frame(s) left the Sophon but never arrived — lost on the link." + aside
    case (_, 0):
        return "\(tx.noBuffer) frame(s) were dropped on the Sophon before sending, but everything that did go out arrived." + aside
    default:
        return "\(tx.noBuffer) frame(s) never left the Sophon, and a further \(lost) went out but did not arrive." + aside
    }
}

private extension SophonDevice.State {
    /// The disconnect reason is deliberately not appended. Core Bluetooth's
    /// `localizedDescription` is long and rarely informative — "The connection
    /// has timed out unexpectedly." — and it pushed the State row to two lines
    /// while saying little the state itself did not. The reason is still
    /// carried on the case and written to the log, so nothing is lost.
    var label: String {
        switch self {
        case .discovered: "Discovered"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        }
    }
}

#Preview {
    ContentView()
}
