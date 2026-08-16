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
                            DeviceDetailView(device: device)
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
