import CoreLocation
import Foundation
import UIKit

/// The walk-test file format, version 2 (#335; LORA-PROTOCOL.md § Walk-test
/// recording format), kept apart from the recorder's state and I/O.
///
/// A file is a preamble of `# key: value` lines, written once, then a CSV whose
/// rows are typed: `window` rows carry one LoRa Link record each, `event` rows a
/// moment -- the app backgrounded, the link dropped, a marker, a pin. What is
/// fixed for the session lives in the preamble and nowhere else, and a file
/// never changes configuration half-way: see ``SessionKey``.
extension WalkTestRecorder {
    static let formatVersion = 2

    /// What must stay the same for the whole of one file. A record whose key
    /// doesn't match the open file's closes that file and starts the next part.
    ///
    /// Two fields can be not yet known, and an unknown value matches anything:
    /// - `sensorID` is 0 until the gateway locks onto a sensor, and 0 again
    ///   after the gateway restarts (#335 review, finding 1);
    /// - `config` is nil until the gateway's Config read lands, and for a
    ///   gateway without the characteristic.
    ///
    /// The config is what this boot *runs*: active role, preset, TX power and
    /// frequency, which change only at a restart. The peer is left out. Its
    /// stored value can change without a restart and its active value turns
    /// from "any" into the locked sensor (finding 4); the lock itself is
    /// `sensorID`.
    struct SessionKey: Equatable {
        var gateway: UUID
        var sensorID: UInt16
        var rotating: Bool
        /// Preset, SF and RX boost; nil while the variants rotate.
        var radio: [UInt8]?
        var config: [Int64]?

        init(link: LoRaLinkRecord, device: SophonDevice) {
            gateway = device.id
            sensorID = link.sensorID
            rotating = link.isWalkTest
            radio = link.isWalkTest ? nil : [link.preset, link.spreadingFactor, link.rxBoost ? 1 : 0]
            config = device.config.map { state in
                [Int64(state.active.role.rawValue), Int64(state.active.preset), Int64(state.active.txDbm),
                 Int64(state.active.freqHz)]
            }
        }

        func matches(_ other: SessionKey) -> Bool {
            gateway == other.gateway && rotating == other.rotating && radio == other.radio
                && (sensorID == 0 || other.sensorID == 0 || sensorID == other.sensorID)
                && (config == nil || other.config == nil || config == other.config)
        }

        /// This key with whatever `other` knows that it didn't.
        func merged(with other: SessionKey) -> SessionKey {
            var key = self
            if key.sensorID == 0 { key.sensorID = other.sensorID }
            if key.config == nil { key.config = other.config }
            return key
        }
    }

    /// A record or an event waiting to be written, in arrival order.
    enum Queued {
        case record(HeldRecord)
        case event(PendingEvent)

        var isRecord: Bool { heldRecord != nil }
        var heldRecord: HeldRecord? {
            if case .record(let record) = self { return record }
            return nil
        }
    }

    /// An event raised before the preamble exists, held until it is written.
    struct PendingEvent {
        let time: Date
        let text: String
        let fix: CLLocation?
        let pin: CLLocation?
    }

    /// A record captured on arrival -- its row already holds that moment's time
    /// and position -- and written once the gateway's config is known.
    struct HeldRecord {
        let arrived: Date
        let link: LoRaLinkRecord
        let device: SophonDevice
        let sensor: SophonDevice?
        let row: [String: String]
    }

    /// Everything the preamble describes, captured when it is written.
    struct PreambleContext {
        let started: Date
        let note: String
        let part: Int
        let continues: String?
        let gateway: SophonDevice?
        let link: LoRaLinkRecord?
        let sensor: SophonDevice?
        let pin: CLLocation?
        let pinIsAutomatic: Bool
    }

    // MARK: Columns

    static let linkColumns = [
        "heard", "lq_pct", "margin_db", "margin_min_db", "rssi_avg", "rssi_min", "snr_avg", "snr_min",
        "samples", "missing", "bad", "wrong_peer", "last_packet_ms",
    ]
    static let positionColumns = ["lat", "lon", "h_accuracy_m", "distance_m", "fix_age_s"]
    static let batteryColumns = ["sensor_batt_mv", "sensor_usb", "sensor_charging"]

    /// The header. While the variants rotate, preset, SF and RX boost change per
    /// record, so they become columns; otherwise they are in the preamble.
    static func columns(rotating: Bool) -> [String] {
        ["type", "time", "window"] + (rotating ? ["preset", "sf", "rx_boost"] : [])
            + linkColumns + positionColumns + batteryColumns + ["event"]
    }

    // MARK: Rows

    static func windowRow(
        _ link: LoRaLinkRecord, battery: BatteryReading?, fix: CLLocation?, pin: CLLocation?, now: Date
    ) -> [String: String] {
        var row: [String: String] = [
            "type": "window",
            "time": timestamp(now),
            "window": String(link.window),
            "preset": link.presetName,
            "sf": String(link.spreadingFactor),
            "rx_boost": link.rxBoost ? "1" : "0",
            "heard": link.heard ? "1" : "0",
            "lq_pct": link.linkQuality.map { String(format: "%.1f", $0) } ?? "",
            "margin_db": link.marginDB.map { String(format: "%.1f", $0) } ?? "",
            "margin_min_db": link.worstMarginDB.map { String(format: "%.1f", $0) } ?? "",
            "rssi_avg": link.heard ? String(link.rssiAvg) : "",
            "rssi_min": link.heard ? String(link.rssiMin) : "",
            "snr_avg": link.heard ? String(link.snrAvg) : "",
            "snr_min": link.heard ? String(link.snrMin) : "",
            "samples": String(link.samples),
            "missing": String(link.missing),
            "bad": String(link.badPackets),
            "wrong_peer": String(link.wrongPeerPackets),
            "last_packet_ms": String(link.lastPacketMillis),
        ]
        row.merge(positionFields(fix: fix, pin: pin, now: now)) { $1 }
        if let battery {
            row["sensor_batt_mv"] = String(battery.millivolts)
            row["sensor_usb"] = battery.usbPowered.map { $0 ? "1" : "0" } ?? ""
            row["sensor_charging"] = battery.charging.map { $0 ? "1" : "0" } ?? ""
        }
        return row
    }

    /// A moment rather than a window: the type, the time, the latest position and
    /// what happened. Every link column stays empty.
    static func eventRow(_ event: PendingEvent) -> [String: String] {
        var row = ["type": "event", "time": timestamp(event.time), "event": event.text]
        row.merge(positionFields(fix: event.fix, pin: event.pin, now: event.time)) { $1 }
        return row
    }

    private static func positionFields(fix: CLLocation?, pin: CLLocation?, now: Date) -> [String: String] {
        guard let fix else { return [:] }
        var fields = [
            "lat": String(format: "%.6f", fix.coordinate.latitude),
            "lon": String(format: "%.6f", fix.coordinate.longitude),
            "h_accuracy_m": String(format: "%.0f", fix.horizontalAccuracy),
            "fix_age_s": String(format: "%.0f", now.timeIntervalSince(fix.timestamp)),
        ]
        if let pin { fields["distance_m"] = String(format: "%.0f", fix.distance(from: pin)) }
        return fields
    }

    /// One CSV line, in the header's column order; absent columns are empty.
    static func line(_ row: [String: String], columns: [String]) -> String {
        columns.map { csvEscape(row[$0] ?? "") }.joined(separator: ",")
    }

    static func csvEscape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func pinText(_ pin: CLLocation) -> String {
        String(format: "%.6f,%.6f ±%.0f m", pin.coordinate.latitude, pin.coordinate.longitude,
               pin.horizontalAccuracy)
    }

    // MARK: Preamble

    static func preamble(_ context: PreambleContext) -> [String] {
        let local = ISO8601DateFormatter.string(
            from: context.started, timeZone: .current, formatOptions: [.withInternetDateTime])
        var lines = [
            "sophon-walktest: \(formatVersion)",
            "started: \(local) (\(TimeZone.current.identifier))",
        ]
        if context.part > 1, let previous = context.continues {
            lines.append("part: \(context.part)")
            lines.append("continues: \(previous)")
        }
        lines.append("app: \(appDescription)")
        lines.append("gateway: \(deviceDescription(context.gateway))")
        if let gateway = context.gateway {
            let config = configDescription(
                gateway.config, link: context.link, offersConfig: gateway.offersConfig == true)
            lines.append("gateway config: \(config)")
        }
        lines.append("sensor: \(sensorDescription(context.link, sensor: context.sensor))")
        if let sensorConfig = context.sensor?.config {
            lines.append("sensor config: \(configDescription(sensorConfig, link: nil))")
        }
        if let link = context.link {
            lines.append(link.isWalkTest
                         ? "variant rotation: on (preset, SF and RX boost are per-row columns)"
                         : "variant rotation: off (one preset for the whole log)")
        }
        if let pin = context.pin {
            lines.append("pin: \(pinText(pin)) · "
                         + (context.pinIsAutomatic ? "automatic (first fix)" : "dropped by hand"))
        } else {
            lines.append("pin: none yet (an event row records it when set)")
        }
        lines.append("note: \(context.note)")
        if context.link == nil { lines.append("no records") }
        return lines.map { "# " + $0 }
    }

    private static var appDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { raw in
            String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8) ?? "?"
        }
        return "\(version) (build \(build)) · \(model) · iOS \(UIDevice.current.systemVersion)"
    }

    private static func deviceDescription(_ device: SophonDevice?) -> String {
        guard let device else { return "unknown" }
        guard let identity = device.identity else { return "\(device.displayName) · firmware unknown" }
        return "\(device.displayName) · firmware \(identity.firmwareVersion) · hardware \(identity.hardwareVersion)"
    }

    private static func sensorDescription(_ link: LoRaLinkRecord?, sensor: SophonDevice?) -> String {
        guard let name = link?.sensorName else { return "not locked" }
        guard let identity = sensor?.identity else { return "\(name) · firmware unknown" }
        return "\(name) · firmware \(identity.firmwareVersion)"
    }

    /// The active configuration as the board reported it at session start (#329),
    /// plus the SF and RX boost from the record when one is given.
    static func configDescription(_ state: ConfigState?, link: LoRaLinkRecord?, offersConfig: Bool = false) -> String {
        var parts: [String] = []
        if let state {
            let active = state.active
            parts.append("role \(active.role.label.lowercased()) (\(state.roleForced ? "set from the app" : "Auto"))")
            parts.append("preset \(active.presetLabel)")
            if let link, !link.isWalkTest { parts.append("SF\(link.spreadingFactor)") }
            parts.append("TX \(active.txDbm >= 0 ? "+" : "")\(active.txDbm) dBm")
            parts.append(String(format: "%.3f MHz", Double(active.freqHz) / 1e6))
            let peer = state.stored.peerID
            parts.append(peer == 0 ? "peer any" : String(format: "peer Sophon-%04X", peer))
            if state.restartPending { parts.append("stored config differs, applied at the next restart") }
        } else {
            // Not read yet is different from not readable: the read may land
            // later, and an event row then gives the config.
            parts.append(offersConfig ? "not read yet" : "unknown (no Config characteristic)")
            if let link, !link.isWalkTest { parts.append("preset \(link.presetName) · SF\(link.spreadingFactor)") }
        }
        if let link {
            parts.append(link.isWalkTest ? "rotating" : "RX boost \(link.rxBoost ? "on" : "off")")
        }
        return parts.joined(separator: " · ")
    }
}
