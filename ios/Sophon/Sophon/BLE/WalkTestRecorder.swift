import CoreLocation
import Foundation
import Observation
import UIKit

/// Records LoRa Link windows against the phone's position, for the walk test
/// (#309, LORA-UPDATED-PLAN.md § Walk-test procedure).
///
/// The walker carries the gateway and this phone while the sensor stays at base.
/// Each record a gateway sends -- one per 10 s window -- becomes one `window` row
/// with the latest location fix and its distance from a pin dropped at the base.
/// What stays fixed for the session -- the boards, their configuration, the pin,
/// the walker's note -- is written once, in a preamble, and the app going to the
/// background, the link dropping, markers and re-dropped pins are `event` rows
/// (#335; the format is in `WalkTestRecorder+CSV.swift` and LORA-PROTOCOL.md
/// § Walk-test recording format). `scripts/walktest-report.py` reads the export.
///
/// Location is used only while a recording runs, and permission is asked for
/// only when the first recording starts. Nothing leaves the phone except by the
/// share sheet, or by the user taking it from the Files app.
///
/// Recordings are saved in **Documents**, which the Files app shows as On My
/// iPhone › Sophon (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`).
/// Not `tmp/`: iOS may purge that at will, and after a force-quit or crash the
/// app no longer knows the file it was writing, so a recording cut short would
/// otherwise be unreachable -- TEST-PLAN 6.13 found exactly that.
@MainActor
@Observable
final class WalkTestRecorder: NSObject {
    private(set) var isRecording = false
    /// Window rows written, across every part of the recording.
    private(set) var rowCount = 0
    /// Which file of the recording is being written. A configuration change
    /// mid-recording closes one file and continues in the next (#335).
    private(set) var part = 1
    /// Where distances are measured from: the sensor's location.
    private(set) var pin: CLLocation?
    /// True while the pin is the recording's first fix rather than one dropped
    /// by hand -- #309's "or use the position at start".
    private(set) var pinIsAutomatic = false
    private(set) var lastFix: CLLocation?
    private(set) var authorization: CLAuthorizationStatus
    /// The files of the latest recording, oldest first: written row by row while
    /// recording, and offered to the share sheet once stopped.
    private(set) var exportURLs: [URL] = []
    /// Set if the file could not be created or written; the UI says so.
    private(set) var writeFailed = false

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var file: FileHandle?
    @ObservationIgnored private var fileURLs: [URL] = []
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private var note = ""
    /// The open file's session, set when its preamble is written. Nil until the
    /// first record: only then are the gateway, the sensor and the config known.
    @ObservationIgnored private var session: SessionKey?
    @ObservationIgnored private var columns: [String] = []
    @ObservationIgnored private var gatewayID: UUID?
    /// Events from before the preamble, written straight after it.
    @ObservationIgnored private var pending: [PendingEvent] = []
    /// Records waiting for the gateway's Config read, with the events that came
    /// after them, in order; see `record(_:from:sensor:)`.
    @ObservationIgnored private var queue: [Queued] = []
    @ObservationIgnored private var inBackground = false
    /// The last record written, to find the windows missed before the next.
    @ObservationIgnored private var lastWindow: WindowMark?
    /// Whether the gateway's link dropped since `lastWindow`: only then can a
    /// restart have reset the counter.
    @ObservationIgnored private var linkDroppedSinceWindow = false
    /// The recording's fixes since the last record, so a `missing` row gets the
    /// position the walker was at when that window was due.
    @ObservationIgnored private var fixHistory: [CLLocation] = []

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        // A walker standing still at a stop produces fixes that differ by
        // jitter alone; 2 m keeps the 1 Hz GPS stream from re-rendering the
        // section for nothing (#309 review, finding 3). The CSV needs only the
        // latest fix once per 10 s window.
        manager.distanceFilter = 2
        manager.pausesLocationUpdatesAutomatically = false

        // Background and foreground are events in the log (#335). Only the
        // app truly leaving the foreground counts: resigning active also fires
        // for Control Center, a banner or a permission prompt, while the app
        // keeps running (review finding 8). SophonHub watches both for another
        // reason -- frame-loss attribution -- which doesn't apply to a log.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteForeground(false) }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteForeground(true) }
        }
    }

    var isLocationDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    /// - Parameter note: the walker's description of the setup -- antennas,
    ///   where the receiver is carried. It goes in the preamble, once.
    func start(note: String) {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        rowCount = 0
        part = 1
        writeFailed = false
        exportURLs = []
        fileURLs = []
        started = Date()
        self.note = note.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        session = nil
        gatewayID = nil
        lastWindow = nil
        linkDroppedSinceWindow = false
        fixHistory = []
        pending = []
        queue = []
        // Each recording measures from its own origin: the first fix after
        // Start, unless a pin is dropped by hand (#309: "or use the position at
        // start"). The first hardware walk had no pin and so no distances.
        pin = nil
        pinIsAutomatic = false
        openFile()
        isRecording = true
        // The walker carries this phone, so it will lock or go in a pocket
        // (#309 review, finding 2). Background location -- the app already
        // declares the `location` background mode for the simulator keep-alive
        // -- keeps the app running so fixes keep arriving. It does NOT keep the
        // gateway's LoRa Link notifies arriving: that takes the
        // `bluetooth-central` background mode. Without it, a locked phone
        // recorded 2 of about 41 windows on the bench (#331). The idle timer is
        // held off so an unlocked screen stays readable at each stop.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        guard isRecording else { return }
        drain()
        // A recording that never got a record still says what it was.
        if session == nil { writePreamble(device: nil, link: nil, sensor: nil, rotating: false) }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        UIApplication.shared.isIdleTimerDisabled = false
        isRecording = false
        closeFile()
        exportURLs = fileURLs
    }

    /// Measure distances from where the phone is now -- drop it standing at the
    /// sensor, before walking away. Before the first record this is the
    /// preamble's pin; after it, an event row says where distances now start.
    func dropPin() {
        pin = lastFix
        pinIsAutomatic = false
        // Before the first record the preamble carries it; only a pin moved
        // after rows exist is an event (review finding 7).
        if let pin, isRecording, session != nil { logEvent("pin: " + Self.pinText(pin)) }
    }

    /// A note from the walker at this moment -- "antenna in hand", "stop 3".
    func addMarker(_ text: String) {
        let text = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard isRecording, !text.isEmpty else { return }
        logEvent("marker: " + text)
    }

    /// The recording's gateway connected or disconnected. Links to any other
    /// board are not this recording's business.
    func noteLink(_ device: SophonDevice, connected: Bool) {
        guard isRecording, device.id == gatewayID else { return }
        // A record held for a Config read the dropped link will never answer
        // is written now, ahead of the event, so the rows stay in order.
        if !connected {
            drain()
            linkDroppedSinceWindow = true
        }
        logEvent(connected ? "connected" : "disconnected")
    }

    /// Distance from the pin to the latest fix, if both exist.
    var distanceFromPin: CLLocationDistance? {
        guard let pin, let lastFix else { return nil }
        return lastFix.distance(from: pin)
    }

    /// One row per LoRa Link record, while recording, appended to the file at
    /// once so a recording survives the app being killed mid-walk.
    ///
    /// - Parameter sensor: the hub's entry for the sensor the gateway locked
    ///   onto, if the app has seen it, for its firmware and config.
    func record(_ link: LoRaLinkRecord, from device: SophonDevice, sensor: SophonDevice?, gaps: [LossGap] = []) {
        guard isRecording else { return }
        // A recording follows one gateway: the first it hears from. Another
        // board still connected would otherwise alternate keys and split the
        // file on every record (review finding 6).
        if gatewayID == nil { gatewayID = device.id }
        guard device.id == gatewayID else { return }
        let now = Date()
        let record = HeldRecord(
            arrived: now, link: link, gaps: gaps, device: device, sensor: sensor,
            row: Self.windowRow(link, battery: device.battery, fix: lastFix, pin: pin, now: now))
        // After a reconnect the session reset clears the config and re-reads
        // it, and the LoRa Link read can land first. The record waits for it,
        // so the first record after a real change lands in the new file. Not
        // for long: a read that never answers releases it after `holdLimit`,
        // at a disconnect, or at Stop, judged with the config unknown
        // (review findings 2 and 3).
        queue.append(.record(record))
        let waiting = device.offersConfig == true && device.config == nil && !device.configReadFailed
        if waiting, let first = queue.first(where: \.isRecord)?.heldRecord,
           now.timeIntervalSince(first.arrived) < Self.holdLimit {
            return
        }
        drain()
    }

    /// How long a record may wait for the gateway's Config read.
    static let holdLimit: TimeInterval = 15

    /// The gateway's Config read landed, or failed: release what waited for it.
    func configSettled(_ device: SophonDevice) {
        guard isRecording, device.id == gatewayID else { return }
        drain()
    }

    /// Writes everything queued, in order.
    private func drain() {
        let items = queue
        queue = []
        for item in items {
            switch item {
            case .record(let record): write(record)
            case .event(let event): writeEvent(event)
            }
        }
    }

    private func write(_ record: HeldRecord) {
        let link = record.link, device = record.device
        let key = SessionKey(link: link, device: device)
        if let session, !session.matches(key) {
            // A log never changes configuration half-way (#335).
            writeEvent(PendingEvent(time: record.arrived, text: "config changed", fix: lastFix, pin: pin))
            closeFile()
            part += 1
            openFile()
            self.session = nil
        }
        if let session {
            // Learnt since the preamble: logged once, not a change.
            func learnt(_ text: String) {
                writeEvent(PendingEvent(time: record.arrived, text: text, fix: lastFix, pin: pin))
            }
            if session.sensorID == 0, key.sensorID != 0, let name = link.sensorName {
                learnt("sensor locked: \(name)")
            }
            if session.config == nil, key.config != nil {
                learnt("gateway config: " + Self.configDescription(device.config, link: link))
            }
            self.session = session.merged(with: key)
        } else {
            writePreamble(device: device, link: link, sensor: record.sensor, rotating: link.isWalkTest)
            session = key
        }
        // The loss runs need the whole of a window's stream. Not known for the
        // first record of a recording (gaps from before Start are mixed in),
        // nor across a dropped link (the session reset discards the gaps
        // before it, and none arrive during it): those rows leave the columns
        // empty rather than claim no loss (#337 review, findings 1, 3 and 4).
        let complete = lastWindow != nil && !linkDroppedSinceWindow
        let ownGaps = writeMissing(before: link, at: record.arrived, gaps: record.gaps, complete: complete)
        var row = record.row
        if complete { row.merge(Self.lossFields(ownGaps, link: link)) { $1 } }
        append(Self.line(row, columns: columns))
        rowCount += 1
    }

    /// One `missing` row for each window between the previous record and this
    /// one (#334), so a gap shows in the file rather than having to be inferred
    /// from the window numbers. A gateway restart isn't a gap: its counter
    /// starts again, which the elapsed time tells apart (`missingWindows`).
    ///
    /// Not while the variants rotate: the gateway then sends several records
    /// per 10 s window, so elapsed time no longer counts windows.
    ///
    /// The motion-stream gaps seen since the previous record are shared out by
    /// time: each `missing` row takes those that arrived in its 10 s, and the
    /// rest -- returned -- belong to the record itself (#337).
    @discardableResult
    private func writeMissing(
        before link: LoRaLinkRecord, at time: Date, gaps: [LossGap], complete: Bool
    ) -> [LossGap] {
        defer {
            lastWindow = WindowMark(number: link.window, time: time, windowSeconds: TimeInterval(link.windowSeconds))
            linkDroppedSinceWindow = false
            // Keep only what a later gap could still need: the fix in force at
            // this record and any after it.
            if let current = fixHistory.lastIndex(where: { $0.timestamp <= time }) {
                fixHistory.removeFirst(current)
            }
        }
        guard let last = lastWindow, !link.isWalkTest else { return gaps }
        let count = Self.missingWindows(
            from: last,
            to: WindowMark(number: link.window, time: time, windowSeconds: TimeInterval(link.windowSeconds)),
            restartPossible: linkDroppedSinceWindow)
        guard count > 0 else { return gaps }
        var start = last.time
        for step in 1...count {
            // The missing windows were the previous record's length (#344).
            let due = last.time.addingTimeInterval(last.windowSeconds * Double(step))
            var row = Self.missingRow(
                window: last.number &+ UInt16(truncatingIfNeeded: step), time: due,
                fix: fixHistory.last { $0.timestamp <= due }, pin: pin)
            let window = gaps.filter { $0.at > start && $0.at <= due }
            if complete { row.merge(Self.lossFields(window, link: link)) { $1 } }
            append(Self.line(row, columns: columns))
            start = due
        }
        return gaps.filter { $0.at > start }
    }

    // MARK: Events and files

    private func noteForeground(_ foreground: Bool) {
        guard isRecording, inBackground == foreground else { return }
        inBackground = !foreground
        logEvent(foreground ? "foreground" : "background")
    }

    /// Writes an event row now; or after the records still waiting, so rows stay
    /// in time order (review finding 5); or after the preamble, before it exists.
    private func logEvent(_ text: String) {
        let event = PendingEvent(time: Date(), text: text, fix: lastFix, pin: pin)
        if !queue.isEmpty {
            queue.append(.event(event))
        } else {
            writeEvent(event)
        }
    }

    private func writeEvent(_ event: PendingEvent) {
        if session == nil {
            pending.append(event)
        } else {
            append(Self.line(Self.eventRow(event), columns: columns))
        }
    }

    private func writePreamble(device: SophonDevice?, link: LoRaLinkRecord?, sensor: SophonDevice?, rotating: Bool) {
        let context = PreambleContext(
            started: started, note: note, part: part,
            continues: fileURLs.dropLast().last?.lastPathComponent,
            gateway: device, link: link, sensor: sensor, pin: pin, pinIsAutomatic: pinIsAutomatic)
        columns = Self.columns(rotating: rotating)
        Self.preamble(context).forEach(append)
        append(columns.joined(separator: ","))
        pending.forEach { append(Self.line(Self.eventRow($0), columns: columns)) }
        pending = []
    }

    private func openFile() {
        let stamp = ISO8601DateFormatter.string(
            from: started, timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let suffix = part > 1 ? "-part\(part)" : ""
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("sophon-walktest-\(stamp)\(suffix).csv")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            writeFailed = true
            return
        }
        file = handle
        fileURLs.append(url)
    }

    private func closeFile() {
        try? file?.close()
        file = nil
    }

    private func append(_ line: String) {
        guard let file else { return }
        do {
            try file.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            if !writeFailed { writeFailed = true }
        }
    }
}

extension WalkTestRecorder: CLLocationManagerDelegate {
    // The manager was created on the main actor, so Core Location delivers its
    // callbacks on the main thread; assumeIsolated states that rather than
    // hopping through a Task, as BackgroundKeepAlive does.
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        MainActor.assumeIsolated {
            // Fixes with no horizontal accuracy are not positions.
            guard fix.horizontalAccuracy >= 0 else { return }
            self.lastFix = fix
            if self.isRecording { self.fixHistory.append(fix) }
            if self.isRecording && self.pin == nil {
                self.pin = fix
                self.pinIsAutomatic = true
                // Usually in the preamble; an event only if the first fix
                // landed after the first record.
                if self.session != nil { self.logEvent("pin automatic: " + Self.pinText(fix)) }
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            if self.authorization != status { self.authorization = status }
        }
    }
}
