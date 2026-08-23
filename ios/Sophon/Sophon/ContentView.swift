import SwiftUI

/// Which role this device is playing.
///
/// Mutually exclusive on purpose: the two roles contend for one radio, and a
/// phone that keeps scanning while advertising as a Sophon will connect to a real
/// board and hold its only connection slot.
enum AppMode: String, CaseIterable, Identifiable {
    case viewer
    case simulator

    var id: String { rawValue }

    var label: String { self == .viewer ? "Viewer" : "Simulator" }
    var icon: String { self == .viewer ? "dot.radiowaves.left.and.right" : "sensor.tag.radiowaves.forward" }
}

struct ContentView: View {
    @AppStorage("appMode") private var mode: AppMode = .viewer
    @State private var hub = SophonHub()
    @State private var simulator = SophonSimulator()

    var body: some View {
        Group {
            NavigationStack {
                Group {
                    switch mode {
                    case .viewer:
                        ViewerView(hub: hub)
                    case .simulator:
                        SimulatorView(simulator: simulator)
                    }
                }
                .navigationTitle("Sophon")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { modePicker }
                }
            }
            // Rebuilt on a mode change so the navigation stack resets. A
            // DeviceDetailView pushed in viewer mode must not survive into
            // simulator mode, where its 2 s stats poll would keep running
            // against a peripheral this app has deliberately disconnected.
            //
            // On the NavigationStack, never on ContentView: there it would
            // destroy @State hub and build a fresh CBCentralManager on every
            // toggle.
            .id(mode)
        }
        .onChange(of: mode, initial: true) { _, newMode in
            // One role down before the other comes up. Never both on air.
            switch newMode {
            case .viewer:
                simulator.stop()
                hub.resume()
            case .simulator:
                hub.suspend()
                simulator.start()
            }
        }
    }

    private var modePicker: some View {
        // A Menu rather than a segmented control: the toolbar is cramped on an
        // iPhone, and this is a mode you set once rather than flick between.
        Menu {
            Picker("Mode", selection: $mode) {
                ForEach(AppMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(mode.label, systemImage: mode.icon)
        }
    }
}

/// The original central-side UI, lifted out of `ContentView` unchanged when
/// simulator mode arrived.
private struct ViewerView: View {
    let hub: SophonHub

    var body: some View {
        if !hub.radio.isUsable {
            RadioUnavailableView(state: hub.radio, purpose: "to find Sophons")
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
}

/// The iOS Simulator has no Core Bluetooth hardware, so this is what a simulator
/// screenshot shows. Worth rendering properly rather than leaving blank.
///
/// Shared by both roles. The four failure reasons are properties of the radio and
/// read identically whether this device is scanning or advertising; only the
/// sentence explaining what it was *for* differs, which is what `purpose` carries.
struct RadioUnavailableView: View {
    let state: RadioState
    /// Completes "Turn Bluetooth on …" — e.g. "to find Sophons".
    let purpose: String

    private var message: (icon: String, title: String, detail: String) {
        switch state {
        case .poweredOff:
            ("bluetooth.slash", "Bluetooth is off", "Turn Bluetooth on \(purpose).")
        case .unauthorized:
            ("hand.raised", "Bluetooth not permitted", "Allow Bluetooth for Sophon in Settings.")
        case .unsupported:
            ("iphone.slash", "No Bluetooth radio", "This device has no Core Bluetooth support — expected in the Simulator.")
        case .idle:
            ("pause.circle", "Radio not in use", "This role is off the air while the other one has the radio.")
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
        // A timeline, because staleness is a function of elapsed time and nothing
        // else invalidates this row. Without it a peripheral could go silent and
        // the row would keep saying Connected until some unrelated change
        // happened to redraw it. One second is plenty against a 5 s threshold.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            row(asOf: context.date)
        }
    }

    private func row(asOf now: Date) -> some View {
        let status = device.linkStatus(asOf: now)
        return HStack {
            StateDot(status: status)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.body)
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(status.isWarning ? .orange : .secondary)
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
    let status: SophonDevice.LinkStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }

    private var color: Color {
        switch status {
        case .connected: .green
        case .connecting: .orange
        case .discovered: .secondary
        case .disconnected: .red
        // Amber, not green and not red: the link is genuinely up, so red would
        // be a lie, but nothing is arriving, so green would be a worse one.
        case .stalled: .orange
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
        Section {
            // Timeline for the same reason as the list row: staleness changes with
            // elapsed time and nothing else here would redraw it. The 2 s stats
            // poll already re-renders this view, but only while a peripheral is
            // answering -- which is exactly the case this needs to detect.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let status = device.linkStatus(asOf: context.date)
                LabeledContent("State", value: status.label)
                    .foregroundStyle(status.isWarning ? .orange : .primary)
            }
            if let rssi = device.rssi {
                LabeledContent("RSSI", value: "\(rssi) dBm")
            }
            if let mtu = device.attMTU {
                LabeledContent("ATT MTU", value: "~\(mtu)")
            }
        } header: {
            Text("Link")
        } footer: {
            if case .stalled = device.linkStatus() {
                Text("The connection is still open, but no frames are arriving. Core Bluetooth cannot tell that a peripheral has stopped until its supervision timeout expires, which can take minutes between two iOS devices — so this is reported from the data rather than from the link.")
            }
        }
    }

    @ViewBuilder private var framesSection: some View {
        Section("Frames") {
            LabeledContent("Received", value: "\(device.framesReceived)")
            LabeledContent("Lost on link", value: "\(device.seqGaps)")
            // Always shown, including at zero, for the same reason as the
            // interruption count below -- and because its absence was being read
            // as "not measured" rather than as "none". A row that only appears
            // once something has gone wrong cannot be used to confirm that
            // nothing has.
            //
            // Named for what it actually counts. It was "Sophon restarts",
            // which promised to count restarts of the Sophon -- and then read 0
            // however many times the board was reset, because a board reset
            // drops the link and returns as a reconnect. The only thing that
            // reaches this is a peripheral restarting its application state
            // while holding the link open, which today means the simulator's
            // Reboot button.
            //
            // A counter whose name overstates what it measures is the same
            // defect as a green dot with no data behind it.
            LabeledContent("Restarts without disconnect",
                           value: "\(device.restartsWithoutDisconnect)")
            // "Viewer", not "App". This was "App interruptions", which was
            // unambiguous only while every peripheral was a board: there was
            // one app in the system and it was this one. Since the simulator
            // (#226) the thing at the other end can be an app too, so on a
            // screen describing a remote Sophon the old label no longer said
            // whose interruption it was.
            //
            // Always shown, including at zero. A field that only appears once
            // something has gone wrong reads as an error banner; a field
            // permanently at 0 reads as a clean bill of health, and its absence
            // at startup would leave you wondering whether the app was
            // measuring this at all.
            LabeledContent(
                "Viewer not listening",
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
            } else if case .stalled = device.linkStatus() {
                // Distinct from "Reading…" on purpose. A read that never returns
                // is an answer, and presenting it as an ongoing wait is the same
                // omission as a green dot with no data behind it.
                Text("Not responding.").foregroundStyle(.orange)
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
                    // Zeroed axes are a deliberate signal, not a bug: a board
                    // whose IMU failed to start falls back to them rather than
                    // going quiet, and the simulator can emit them on demand.
                    // Saying so beats showing six zeros that look broken.
                    Text("Axes are zero — the Sophon is streaming frames but has no IMU data.")
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

private extension SophonDevice.LinkStatus {
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
        // Says both halves, because both are true and only together are they
        // useful: the link is up, and no data is coming over it.
        case .stalled(let silent): "Connected · no data \(Int(silent))s"
        }
    }

    /// Worth colouring, because it needs explaining rather than merely reporting.
    var isWarning: Bool {
        if case .stalled = self { return true }
        return false
    }
}

#Preview {
    ContentView()
}
