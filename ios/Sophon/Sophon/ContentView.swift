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
                    DeviceDetailView(
                        device: device,
                        onRefresh: { hub.refreshStats(device) },
                        onToggleConnection: {
                            if device.isHeld { hub.release(device) } else { hub.reclaim(device) }
                        },
                        onScreen: { hub.setDeviceOnScreen($0 ? device.id : nil) }
                    )
                } label: {
                    DeviceRow(device: device)
                }
                // A swipe rather than a button in the row: the row IS a
                // NavigationLink, and an inline button inside one competes with
                // it for the tap. The detail view carries the visible control;
                // this is the fast path for switching between boards, which is
                // where the choice actually gets made (#233).
                .swipeActions(edge: .trailing) {
                    if device.isHeld {
                        Button("Release") { hub.release(device) }.tint(.orange)
                    } else if !device.isStaleReleased {
                        // Offered only while the board is actually reachable.
                        // connect() on iOS never times out, so on a board that has
                        // gone quiet this would strand the device in .connecting
                        // with nothing to show for it.
                        Button("Connect") { hub.reclaim(device) }.tint(.green)
                    }
                }
            }
            // The sweep that drives this lives in SophonHub, deliberately not in a
            // .task here: a NavigationStack cancels this view's tasks as soon as a
            // detail view is pushed, which is precisely when staleness still needs
            // evaluating.
            .animation(.default, value: hub.devices.count)
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
        // Grey like .discovered, not red: nothing is wrong. The board is simply
        // not ours at the moment, which is a state the user chose.
        case .released: .secondary
        // Amber, not green and not red: the link is genuinely up, so red would
        // be a lie, but nothing is arriving, so green would be a worse one.
        case .stalled: .orange
        }
    }
}

private struct DeviceDetailView: View {
    let device: SophonDevice
    let onRefresh: () -> Void
    let onToggleConnection: () -> Void
    let onScreen: (Bool) -> Void

    /// Pops this view off the NavigationStack. Note this needs no `NavigationPath`
    /// and no selection binding — `DismissAction` works on a plain
    /// `NavigationLink` push, which is what keeps this free of the navigation
    /// refactor #235 was written to avoid.
    @Environment(\.dismiss) private var dismiss

    /// What the app knows it observed — not a claim about the peripheral. Worded
    /// so it does not read as a fault, because for every simulator it is
    /// permanent and correct.
    static let notReported = "Not reported"

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
        // Tell the hub not to sweep this one while it is being looked at. The
        // back chevron is what releases it, so the row disappears on return to
        // the list rather than out from under the reader (#235).
        .onAppear { onScreen(true) }
        .onDisappear { onScreen(false) }
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

            // The interval iOS granted, which Core Bluetooth will not tell this
            // app — it comes back from the peripheral, the only side that can see
            // it (#224). Shown with events/second because that is the form worth
            // comparing against a sample rate: 50 Hz of frames cannot fit through
            // 25 events/s, which is the arithmetic #248 is about.
            if let params = device.linkParams {
                LabeledContent("Interval",
                               value: params.eventsPerSecond.map {
                                   String(format: "%.2f ms · %.0f/s", params.intervalMillis, $0)
                               } ?? String(format: "%.2f ms", params.intervalMillis))
                LabeledContent("Peripheral latency", value: "\(params.latency)")
                LabeledContent("Supervision timeout", value: "\(params.timeoutMillis) ms")
            }

            // Shown unconditionally, unlike RSSI and ATT MTU above: absence is
            // itself the answer here — this peripheral does not advertise who it
            // is — and a row that vanishes cannot say that. Same argument the
            // frames section already makes for showing zero.
            LabeledContent("Hardware", value: device.identity.map { "rev \($0.hardwareVersion)" }
                ?? Self.notReported)
            LabeledContent("Firmware", value: device.identity?.firmwareVersion ?? Self.notReported)
            // A TX power with no identity beside it is the PHONE's radio, not a
            // Sophon's: iOS adds a standard TX Power AD type of its own, while
            // manufacturer data is the part it genuinely cannot advertise. Since
            // #230, a board that reports one always reports the other too, so
            // identity == nil with a TX power present means an iOS peripheral
            // (#246). Worth labelling, because the number is real but is not the
            // board's, and TX power - RSSI means something different for each.
            LabeledContent("TX power", value: device.txPower.map {
                device.identity == nil ? "\($0) dBm · device radio" : "\($0) dBm"
            } ?? Self.notReported)

            // Only when iOS surfaced something nobody here has accounted for.
            // Silent in the normal case, which is the point: #246 happened
            // because an unexpected AD type went unnoticed for a whole issue.
            if !device.advertisementKeys.subtracting(SophonProtocol.expectedAdvertisementKeys).isEmpty {
                let extra = device.advertisementKeys
                    .subtracting(SophonProtocol.expectedAdvertisementKeys)
                    .map { $0.replacingOccurrences(of: "CBAdvertisementData", with: "") }
                    .sorted()
                    .joined(separator: ", ")
                LabeledContent("Other advertising data", value: extra)
                    .foregroundStyle(.orange)
            }

            // Only when unrecognised. Surfacing a version the app already knows
            // would be noise on every screen, every session.
            if let identity = device.identity, !identity.isFullyRecognised {
                LabeledContent("Scan response", value: "v\(identity.scanRspVersion), type \(identity.deviceType)")
                    .foregroundStyle(.orange)
            }

            // The visible control. The swipe action on the list row is the fast
            // path; this is the discoverable one, since a swipe affordance is
            // invisible until you try it.
            //
            // Withdrawn once a released board goes quiet: connect() on iOS never
            // times out, so the button would sit there looking live while doing
            // nothing at all. Saying why beats offering a control that lies.
            if device.isStaleReleased {
                // Takes the place of Connect once the board has gone quiet. The
                // sweep is deferred while this view is on screen, so leaving is
                // what actually retires the entry — this offers that as the
                // action rather than leaving the reader to find the back chevron.
                // The explanation sits in the section footer, where every other
                // explanation in this view lives.
                Button("Back to Devices") { dismiss() }
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Button(role: device.isHeld ? .destructive : nil, action: onToggleConnection) {
                    Text(device.isHeld ? "Release board" : "Connect")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        } header: {
            Text("Link")
        } footer: {
            // Timeline, for the same reason as the State row above: during a stall
            // NOTHING observable on the device changes -- frames stop and the
            // stats read goes unanswered -- so an enclosing body is never
            // re-evaluated, and this text could not appear in the one situation it
            // was written for (#242). A footer is a single block of prose, so
            // wrapping it changes no row layout.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                linkFooter(asOf: context.date)
            }
        }
    }

    @ViewBuilder private func linkFooter(asOf now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .stalled = device.linkStatus(asOf: now) {
                Text("The connection is still open, but no frames are arriving. Core Bluetooth cannot tell that a peripheral has stopped until its supervision timeout expires, which can take minutes between two iOS devices — so this is reported from the data rather than from the link.")
            }
            if case .released = device.linkStatus(asOf: now) {
                if device.isStaleReleased {
                    Text("Not reachable. Another device may have taken this board, or it is off or out of range — it stops advertising either way, so the app cannot tell which. It will be dropped from the list when you go back, and picked up again automatically if it returns.")
                } else {
                    Text("You released this board, so it will not reconnect on its own. A Sophon holds one connection at a time and is invisible to other scanners while taken, so releasing it is what hands it to another device without a power cycle. Restarting the app clears this.")
                }
            }
            if device.identity == nil {
                Text("\(Self.notReported) is normal, not a fault: an iOS peripheral cannot advertise manufacturer data at all, so a simulated Sophon reports no hardware or firmware version — nor does a board running firmware older than #230. TX power is different: it is a standard advertising field that iOS fills in itself, so a value there is the phone's own radio rather than a Sophon's.")
            }
        }
    }

    @ViewBuilder private var framesSection: some View {
        Section("Frames") {
            LabeledContent("Received", value: "\(device.framesReceived)")
            // "Gaps in sequence", not "Lost on link": a hole means a frame is
            // MISSING, and says nothing about where it went. Attribution happens
            // in the transmit counters below, and on an iOS-to-iOS link
            // essentially all of these turn out to be the peripheral refusing to
            // send -- frames that never reached a link to be lost on (#247).
            LabeledContent("Gaps in sequence", value: "\(device.seqGaps)")
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
                // The numbers above are a LAST READ, not a live value, and during
                // a stall they stop moving with nothing to say so -- the same
                // "reads as more than it says" failure the link states exist to
                // avoid. One row either way, so the layout is unchanged (#242).
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if case .stalled = device.linkStatus(asOf: context.date) {
                        Text("Not responding. The Sophon has stopped answering, so these are the last figures it returned, not current ones.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else {
                        Text(attribution(device: device))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if device.state.isConnected {
                // One row either way, so this stays a single List cell and the
                // layout is untouched -- but it now re-evaluates on a timeline.
                // Without that, "Not responding." could never replace "Reading…":
                // an unanswered read changes nothing observable, so the body would
                // never run again (#242).
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if case .stalled = device.linkStatus(asOf: context.date) {
                        // Distinct from "Reading…" on purpose. A read that never
                        // returns is an answer, and presenting it as an ongoing
                        // wait is the same omission as a green dot with no data
                        // behind it.
                        Text("Not responding.").foregroundStyle(.orange)
                    } else {
                        Text("Reading…").foregroundStyle(.secondary)
                    }
                }
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
        // Silence is worth saying out loud: a released board still on the air can
        // be taken back, one that has gone quiet cannot.
        case .released(let silent):
            if silent <= SophonDevice.releasedSilenceThreshold { "Released" }
            else if silent.isFinite { "Released · not seen \(Int(silent))s" }
            else { "Released · not seen" }
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
