import CoreLocation
import Foundation
import Observation
import UIKit

/// Records LoRa Link windows against the phone's position, for the walk test
/// (#309, LORA-UPDATED-PLAN.md § Walk-test procedure).
///
/// The walker carries the gateway and this phone while the sensor stays at base.
/// Each record a gateway sends -- one per 10 s window -- becomes one CSV row with
/// the latest location fix and its distance from a pin dropped at the base.
/// `scripts/walktest-report.py` reads the export.
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
    private(set) var rowCount = 0
    /// Where distances are measured from: the sensor's location.
    private(set) var pin: CLLocation?
    /// True while the pin is the recording's first fix rather than one dropped
    /// by hand -- #309's "or use the position at start".
    private(set) var pinIsAutomatic = false
    private(set) var lastFix: CLLocation?
    private(set) var authorization: CLAuthorizationStatus
    /// The CSV of the latest recording: written row by row while recording, and
    /// offered to the share sheet once stopped.
    private(set) var exportURL: URL?
    /// Set if the file could not be created or written; the UI says so.
    private(set) var writeFailed = false

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var file: FileHandle?
    @ObservationIgnored private var fileURL: URL?

    static let header = [
        "time", "gateway", "sensor", "window", "preset", "sf", "rx_boost", "walk_test", "heard",
        "lq_pct", "margin_db", "rssi_avg", "rssi_min", "snr_avg", "snr_min", "samples", "missing",
        "bad", "wrong_peer", "last_packet_ms", "lat", "lon", "h_accuracy_m", "distance_m", "fix_age_s",
        "pin_lat", "pin_lon", "margin_min_db",
    ].joined(separator: ",")

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
    }

    var isLocationDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    func start() {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        rowCount = 0
        writeFailed = false
        exportURL = nil
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
        // -- keeps the app running, which also keeps the gateway's LoRa Link
        // notifies arriving; the idle timer is held off so an unlocked screen
        // stays readable at each stop.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        UIApplication.shared.isIdleTimerDisabled = false
        isRecording = false
        try? file?.close()
        file = nil
        exportURL = fileURL
    }

    /// Measure distances from where the phone is now -- drop it standing at the
    /// sensor, before walking away. Every row carries the pin it was measured
    /// from, so a re-drop mid-recording is visible in the CSV.
    func dropPin() {
        pin = lastFix
        pinIsAutomatic = false
    }

    /// Distance from the pin to the latest fix, if both exist.
    var distanceFromPin: CLLocationDistance? {
        guard let pin, let lastFix else { return nil }
        return lastFix.distance(from: pin)
    }

    /// One row per LoRa Link record, while recording, appended to the file at
    /// once so a recording survives the app being killed mid-walk.
    func record(_ link: LoRaLinkRecord, from device: SophonDevice) {
        guard isRecording else { return }
        let now = Date()
        var fields: [String] = [
            ISO8601DateFormatter().string(from: now),
            device.displayName,
            link.sensorName ?? "",
            String(link.window),
            link.presetName,
            String(link.spreadingFactor),
            link.rxBoost ? "1" : "0",
            link.isWalkTest ? "1" : "0",
            link.heard ? "1" : "0",
            link.linkQuality.map { String(format: "%.1f", $0) } ?? "",
            link.marginDB.map { String(format: "%.1f", $0) } ?? "",
            link.heard ? String(link.rssiAvg) : "",
            link.heard ? String(link.rssiMin) : "",
            link.heard ? String(link.snrAvg) : "",
            link.heard ? String(link.snrMin) : "",
            String(link.samples),
            String(link.missing),
            String(link.badPackets),
            String(link.wrongPeerPackets),
            String(link.lastPacketMillis),
        ]
        if let fix = lastFix {
            fields += [
                String(format: "%.6f", fix.coordinate.latitude),
                String(format: "%.6f", fix.coordinate.longitude),
                String(format: "%.0f", fix.horizontalAccuracy),
                distanceFromPin.map { String(format: "%.0f", $0) } ?? "",
                String(format: "%.0f", now.timeIntervalSince(fix.timestamp)),
            ]
        } else {
            fields += ["", "", "", "", ""]
        }
        if let pin {
            fields += [String(format: "%.6f", pin.coordinate.latitude),
                       String(format: "%.6f", pin.coordinate.longitude)]
        } else {
            fields += ["", ""]
        }
        fields.append(link.worstMarginDB.map { String(format: "%.1f", $0) } ?? "")
        append(fields.map(Self.csvEscape).joined(separator: ","))
        rowCount += 1
    }

    private static func csvEscape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func openFile() {
        let stamp = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("sophon-walktest-\(stamp).csv")
        guard FileManager.default.createFile(atPath: url.path, contents: Data((Self.header + "\n").utf8)),
              let handle = try? FileHandle(forWritingTo: url) else {
            writeFailed = true
            return
        }
        _ = try? handle.seekToEnd()
        file = handle
        fileURL = url
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
            if self.isRecording && self.pin == nil {
                self.pin = fix
                self.pinIsAutomatic = true
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
