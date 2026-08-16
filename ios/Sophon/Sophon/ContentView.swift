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
                        Text("Power on a board and it will appear here.")
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

    /// How often the board's counters are re-read while this view is on screen.
    ///
    /// Polling rather than subscribing, and only while visible. A notify would
    /// push on every change, and `sent` changes on *every frame* — so the stats
    /// would notify as often as the data itself, which is absurd at #209's
    /// 50 Hz. A read every couple of seconds costs about 0.5 reads per second
    /// whatever the sample rate, and stops entirely when nobody is looking at
    /// it.
    private static let refreshInterval = Duration.seconds(2)

    var body: some View {
        List {
            Section("Link") {
                LabeledContent("State", value: device.state.label)
                if let rssi = device.rssi {
                    LabeledContent("RSSI", value: "\(rssi) dBm")
                }
                if let mtu = device.attMTU {
                    LabeledContent("ATT MTU", value: "~\(mtu)")
                }
            }

            Section("Frames") {
                LabeledContent("Received", value: "\(device.framesReceived)")
                LabeledContent("Sequence gaps", value: "\(device.seqGaps)")
                if let frame = device.lastFrame {
                    LabeledContent("Last seq", value: "\(frame.seq)")
                    LabeledContent("Board uptime", value: "\(frame.tMillis) ms")
                }
            }

            // Deliberately adjacent to the gap count above: a gap says an
            // interval has no data, and only these say whether the frames were
            // lost on the air or never left the board.
            Section {
                if let tx = device.txThisSession {
                    // Every figure here is scoped to this connection, so it is
                    // directly comparable with Received and Sequence gaps above.
                    LabeledContent("Sent by board", value: "\(tx.sent)")
                    if let lost = device.lostInFlight {
                        LabeledContent("Lost in flight", value: "\(lost)")
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
                Text("Board transmit counters")
            } footer: {
                if device.txStatsAt != nil {
                    Text("Scoped to this connection; the board's own totals run since it booted, so they are rebased on connect to stay comparable with the counts above. Re-read every 2s while this screen is open — polled rather than subscribed, and stops when you navigate away.")
                }
            }

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
        .navigationTitle(device.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // .task is cancelled automatically when the view disappears, so the
        // polling stops the moment you navigate away.
        .task {
            while !Task.isCancelled {
                onRefresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }
}

/// Turns the two numbers into the sentence they exist to support. This is the
/// entire value of showing board counters next to app counters — without it the
/// reader has to know what `noBuffer` means to interpret a gap.
private func attribution(device: SophonDevice) -> String {
    guard let tx = device.txThisSession, let lost = device.lostInFlight else { return "" }

    switch (tx.noBuffer, lost) {
    case (0, 0):
        return "Everything the board sent arrived, and nothing was dropped before sending — the link is keeping up."
    case (0, _):
        return "\(lost) frame(s) left the board but never arrived — lost on the link, or while the app was not listening."
    case (_, 0):
        return "\(tx.noBuffer) frame(s) were dropped on the board before sending, but everything that did go out arrived."
    default:
        return "\(tx.noBuffer) frame(s) never left the board, and a further \(lost) went out but did not arrive."
    }
}

private extension SophonDevice.State {
    var label: String {
        switch self {
        case .discovered: "Discovered"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .disconnected(let reason): reason.map { "Disconnected — \($0)" } ?? "Disconnected"
        }
    }
}

#Preview {
    ContentView()
}
