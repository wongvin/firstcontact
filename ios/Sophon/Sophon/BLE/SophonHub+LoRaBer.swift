import CoreBluetooth
import Foundation
import os

/// The LoRa BER characteristic (#359), in its own file like LoRa Link's.
/// SophonHub calls these from its discovery and update callbacks, inside the
/// same `MainActor.assumeIsolated` blocks.
extension SophonHub {
    private static let berLog = Logger(subsystem: "com.vwong.Sophon", category: "ble")

    /// Latch whether the GATT database has the characteristic (#261 guard).
    func noteLoRaBerOffered(_ characteristics: [CBCharacteristic], by device: SophonDevice?) {
        let offers = characteristics.contains { $0.uuid == SophonProtocol.loraBerCharacteristicUUID }
        if device?.loraBer.offers != offers { device?.loraBer.offers = offers }
    }

    /// Read the latest window now, then subscribe, as for LoRa Link.
    func subscribeLoRaBer(_ characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        peripheral.readValue(for: characteristic)
        peripheral.setNotifyValue(true, for: characteristic)
    }

    /// LoRa Link and LoRa BER share one case in the delegate's switch, which is
    /// at its complexity limit; this sends each to its own handler.
    func ingestLoRaValue(_ uuid: CBUUID, _ data: Data, from id: UUID) {
        if uuid == SophonProtocol.loraBerCharacteristicUUID {
            ingestLoRaBerValue(data, from: id)
        } else {
            ingestLoRaLinkValue(data, from: id)
        }
    }

    /// One read or notify. Zero bytes is "not a gateway, or no window yet".
    func ingestLoRaBerValue(_ data: Data, from id: UUID) {
        guard !data.isEmpty, let device = devices.first(where: { $0.id == id }) else { return }
        guard let record = LoRaBerRecord(data) else {
            if data.count == LoRaBerRecord.wireSize, let version = data.first,
               let mismatch = VersionMismatch.check(received: version, supported: LoRaBerRecord.supportedVersion) {
                if device.loraBer.mismatch != mismatch { device.loraBer.mismatch = mismatch }
            } else {
                Self.berLog.error("malformed LoRa BER record (\(data.count, privacy: .public) bytes)")
            }
            return
        }
        device.loraBer.ingest(record)
        device.noteLoRaPeer()
    }

    /// Compare the gateway's image with its transporter's (#359). The
    /// transporter is the board the latest record names, found among the boards
    /// the app has seen advertise.
    func checkImages(for gateway: SophonDevice) {
        guard !updater.isBusy, let name = gateway.loraBer.record?.transporterName else { return }
        imageCheck.run(gateway: gateway, transporter: devices.first { $0.displayName == name },
                       transporterName: name)
    }
}
