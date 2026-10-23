import CoreBluetooth
import Foundation
import os

/// The LoRa Link characteristic (#309), in its own file so SophonHub.swift stays
/// under its length limit. SophonHub calls these from its discovery and update
/// callbacks, inside the same `MainActor.assumeIsolated` blocks.
extension SophonHub {
    private static let loraLog = Logger(subsystem: "com.vwong.Sophon", category: "ble")

    /// Latch whether the GATT database has the characteristic, guarded like the
    /// other `offers*` latches against re-notifying an identical value (#261).
    func noteLoRaLinkOffered(_ characteristics: [CBCharacteristic], by device: SophonDevice?) {
        let offers = characteristics.contains { $0.uuid == SophonProtocol.loraLinkCharacteristicUUID }
        if device?.offersLoRaLink != offers { device?.offersLoRaLink = offers }
    }

    /// Read for the latest window now, rather than waiting up to 10 s for the
    /// next notify, then subscribe. Off a gateway the read is zero bytes and
    /// nothing ever notifies, so nothing reaches the UI. Not cached and not
    /// polled: the board pushes every window itself.
    func subscribeLoRaLink(_ characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        peripheral.readValue(for: characteristic)
        peripheral.setNotifyValue(true, for: characteristic)
    }

    /// One read or notify. Zero bytes is the defined "not a gateway" answer
    /// (PROTOCOL.md § LoRa Link frame), not an error; anything else that fails
    /// to parse is malformed. A record the device has already seen -- a read
    /// straight after a reconnect -- is not recorded twice.
    func ingestLoRaLinkValue(_ data: Data, from id: UUID) {
        guard !data.isEmpty else { return }
        guard let record = LoRaLinkRecord(data) else {
            // A full-length record in a version this app doesn't read is a
            // firmware/app mismatch, not a fault, and the fix depends on which
            // side is behind: say so on screen, not only in the log (#346).
            if data.count == LoRaLinkRecord.wireSize, let version = data.first,
               let mismatch = VersionMismatch.check(received: version, supported: LoRaLinkRecord.supportedVersion),
               let device = devices.first(where: { $0.id == id }) {
                if device.loraLinkMismatch != mismatch {
                    device.loraLinkMismatch = mismatch
                    Self.loraLog.error("LoRa Link record version \(version, privacy: .public) not read by this app")
                }
                // Every time, not just on the first: a recording started after
                // the message appeared must still log it (#346 review). The
                // recorder logs it once per recording.
                walkTest.noteUnsupportedRecord(version, from: device)
            } else {
                Self.loraLog.error("malformed LoRa Link record (\(data.count, privacy: .public) bytes)")
            }
            return
        }
        guard let device = devices.first(where: { $0.id == id }) else { return }
        if device.ingestLoRaLink(record) {
            // The sensor's own entry, if the app has seen it advertise, gives
            // the recording its firmware and config (#335).
            let sensor = record.sensorName.flatMap { name in devices.first { $0.displayName == name } }
            walkTest.record(record, from: device, sensor: sensor, gaps: device.takeLossGaps())
        }
    }
}
