import Foundation
import Observation

/// One board's bit-error test state (#359): the latest LoRa BER record, the
/// session's running totals, and the last image check.
///
/// Its own object rather than more properties on ``SophonDevice``, which is at
/// SwiftLint's file-length limit. Held by the device for its lifetime; the
/// session-scoped parts are cleared by ``resetSession()``, called from the
/// device's `resetLinkStats()`.
@MainActor
@Observable
final class LoRaBerState {
    /// Whether the GATT database has the LoRa BER characteristic. Latched across
    /// sessions like the device's other `offers*`: it describes the firmware.
    var offers: Bool?

    /// The latest record, or nil until a gateway sends one. Session-scoped.
    private(set) var record: LoRaBerRecord?
    /// When it arrived. Only a `TimelineView` reads it.
    @ObservationIgnored private(set) var recordAt: Date?

    /// Running totals over this session's records, so the long-run BER can be
    /// read at a finer grain than one window allows.
    private(set) var sessionPackets = 0
    private(set) var sessionDamaged = 0
    private(set) var sessionLost = 0
    private(set) var sessionUnresolved = 0
    private(set) var sessionBitErrors = 0
    private(set) var sessionBits = 0

    /// The last ``SophonDevice/loraLinkHistoryCount`` records, oldest first,
    /// for the LoRa link section's BER chart. Session-scoped.
    private(set) var history: [LoRaBerRecord] = []

    /// What the gateway was last known to hear, and this board's last known
    /// role. Kept across sessions, and changed only when they really change
    /// (#359 review, findings 2-3): a reconnect clears the records and the
    /// config until they are re-read, and reading them live flipped the
    /// layout, and redrew the whole detail view every window.
    private(set) var peer: LoRaPeer = .none
    private(set) var role: SophonConfig.Role?

    func note(peer newPeer: LoRaPeer) {
        if peer != newPeer { peer = newPeer }
    }

    func note(role newRole: SophonConfig.Role) {
        if role != newRole { role = newRole }
    }

    /// BER records arrive in a version this app doesn't read (#346 pattern).
    var mismatch: VersionMismatch?

    /// The last image check, kept across sessions: it describes the two
    /// boards' firmware, and carries the time it was made.
    var imageCheck: ImageCheck.Outcome?

    /// The last record ingested, kept across sessions so the re-read after a
    /// reconnect isn't counted twice (as `loraLastIngested` on the device).
    @ObservationIgnored private var lastIngested: LoRaBerRecord?

    /// Records one window. False for a repeat of the last one.
    @discardableResult
    func ingest(_ newRecord: LoRaBerRecord) -> Bool {
        if mismatch != nil { mismatch = nil }
        if newRecord == lastIngested { return false }
        lastIngested = newRecord
        record = newRecord
        recordAt = Date()
        history.append(newRecord)
        if history.count > SophonDevice.loraLinkHistoryCount {
            history.removeFirst(history.count - SophonDevice.loraLinkHistoryCount)
        }
        sessionPackets += Int(newRecord.packets)
        sessionDamaged += Int(newRecord.damaged)
        sessionLost += Int(newRecord.lost)
        sessionUnresolved += Int(newRecord.unresolved)
        sessionBitErrors += Int(newRecord.bitErrors)
        sessionBits += newRecord.bitsCompared
        return true
    }

    /// The session's bit error rate, or nil before anything was compared.
    var sessionBerPercent: Double? { LoRaBerRecord.percent(sessionBitErrors, of: sessionBits) }

    func recordAge(asOf now: Date) -> TimeInterval? {
        recordAt.map { now.timeIntervalSince($0) }
    }

    /// A transporter was heard in the latest window, and that window is
    /// recent: the gateway is busy with the bit-error test, not silent.
    func isLive(asOf now: Date, staleAfter: TimeInterval) -> Bool {
        guard record?.heard == true, let age = recordAge(asOf: now) else { return false }
        return age <= staleAfter
    }

    func resetSession() {
        record = nil
        recordAt = nil
        history = []
        sessionPackets = 0
        sessionDamaged = 0
        sessionLost = 0
        sessionUnresolved = 0
        sessionBitErrors = 0
        sessionBits = 0
        mismatch = nil
    }
}

/// What a gateway's LoRa link carries (#359): motion from a sensor, the
/// bit-error test from a transporter, both (two boards on one channel, which the
/// one-sensor-per-channel rule forbids), or nothing yet. Decides what the LoRa
/// link section shows and whether the motion sections apply.
enum LoRaPeer: Equatable {
    case none
    case sensor
    case transporter
    case both
}

extension SophonDevice {
    /// What the gateway hears, as stored by ``noteLoRaPeer()``.
    var loraPeer: LoRaPeer { loraBer.peer }

    /// Re-derive the peer from the latest records; called by the hub after it
    /// ingests one. Only while a Link record is held: a reconnect clears it, and
    /// "none" then would just be the gap before the re-read.
    func noteLoRaPeer() {
        guard loraLink != nil else { return }
        loraBer.note(peer: liveLoRaPeer)
    }

    /// From the boards the gateway names, which change slowly, not from one
    /// window's counts, so a fade doesn't flip the layout: the sensor it has
    /// locked onto (released after 5 s of silence), and the transporter it
    /// hears (named until 20 s after it was last heard).
    private var liveLoRaPeer: LoRaPeer {
        guard let link = loraLink else { return .none }
        let sensor = link.sensorID != 0
        let transporter = (loraBer.record?.transporterID ?? 0) != 0
        switch (sensor, transporter) {
        case (true, true): return .both
        case (true, false): return .sensor
        case (false, true): return .transporter
        case (false, false): return .none
        }
    }

    /// A sensor or transporter: it sends over LoRa, and its link is measured by
    /// the gateway that hears it.
    var sendsOverLoRa: Bool {
        switch config?.active.role ?? loraBer.role {
        case .sensor?, .transporter?: return true
        default: return false
        }
    }

    /// Whether this board's motion sections (Frames, Motion, the transmit
    /// counters) mean anything. A sensor or transporter sends over LoRa, not
    /// Bluetooth; a gateway hearing only a transporter has no motion to relay.
    /// An unknown role keeps everything, as before roles were known.
    var streamsMotion: Bool {
        switch config?.active.role ?? loraBer.role {
        case .sensor?, .transporter?: return false
        case .gateway?: return loraPeer != .transporter
        default: return true
        }
    }
}
