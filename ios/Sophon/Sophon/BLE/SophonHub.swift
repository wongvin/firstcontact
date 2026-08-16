import CoreBluetooth
import Foundation
import os

/// Owns the app's single `CBCentralManager` and the set of known Sophons.
///
/// The hub/device split exists so that multi-device support is structural rather
/// than retrofitted: there is exactly one central manager per app, so it cannot
/// live on a per-device object, and a single "the peripheral / the state" type
/// would bake N=1 into everything that binds to it.
@MainActor
@Observable
final class SophonHub: NSObject {
    enum RadioState: Equatable {
        case unknown
        case unauthorized
        case unsupported
        case poweredOff
        case scanning

        var isUsable: Bool { self == .scanning }
    }

    private(set) var radio: RadioState = .unknown
    private(set) var devices: [SophonDevice] = []

    private var central: CBCentralManager!
    private var byID: [UUID: SophonDevice] = [:]
    private let log = Logger(subsystem: "com.vwong.Sophon", category: "ble")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func device(for peripheral: CBPeripheral) -> SophonDevice? {
        byID[peripheral.identifier]
    }

    func connect(_ device: SophonDevice) {
        guard radio.isUsable else { return }
        device.state = .connecting
        central.connect(device.peripheral)
    }

    func disconnect(_ device: SophonDevice) {
        central.cancelPeripheralConnection(device.peripheral)
    }

    private func startScan() {
        // Filtered by service UUID, which is REQUIRED: an unfiltered scan
        // returns nothing while the app is backgrounded. It also means the
        // firmware must keep the service UUID in the advertisement, not the
        // scan response.
        central.scanForPeripherals(
            withServices: [SophonProtocol.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        radio = .scanning
        log.info("scanning for Sophon peripherals")
    }
}

extension SophonHub: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            switch state {
            case .poweredOn:
                self.startScan()
            case .poweredOff:
                self.radio = .poweredOff
            case .unauthorized:
                self.radio = .unauthorized
            case .unsupported:
                // Also the simulator, which has no Core Bluetooth hardware.
                self.radio = .unsupported
            default:
                self.radio = .unknown
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // iOS active-scans by default, so the scan-response name is already here.
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssi = RSSI.intValue

        Task { @MainActor in
            let device: SophonDevice
            if let known = self.byID[peripheral.identifier] {
                device = known
                if let advertisedName { device.displayName = advertisedName }
            } else {
                device = SophonDevice(peripheral: peripheral, advertisedName: advertisedName)
                self.byID[peripheral.identifier] = device
                self.devices.append(device)
                self.log.info("discovered \(device.displayName, privacy: .public)")
            }

            // 127 is Core Bluetooth's "not available" sentinel, not a real reading.
            device.rssi = rssi == 127 ? nil : rssi
            peripheral.delegate = self

            // Auto-connect: with one board there is nothing to choose between,
            // and reconnect-on-return-to-range should not need a tap.
            if case .discovered = device.state {
                self.connect(device)
            } else if case .disconnected = device.state {
                self.connect(device)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard let device = self.byID[peripheral.identifier] else { return }
            device.state = .connected
            device.resetLinkStats()

            // maximumWriteValueLength(.withoutResponse) is the negotiated ATT
            // MTU minus the 3-byte ATT header — the closest iOS exposes.
            device.attMTU = peripheral.maximumWriteValueLength(for: .withoutResponse) + 3

            self.log.info("connected \(device.displayName, privacy: .public), ATT MTU ~\(device.attMTU ?? -1)")
            peripheral.discoverServices([SophonProtocol.serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let reason = error?.localizedDescription
        Task { @MainActor in
            self.byID[peripheral.identifier]?.state = .disconnected(reason: reason)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let reason = error?.localizedDescription
        Task { @MainActor in
            guard let device = self.byID[peripheral.identifier] else { return }
            device.state = .disconnected(reason: reason)
            self.log.info("disconnected \(device.displayName, privacy: .public)")

            // Re-arm. The scan is still running, so walking back into range
            // rediscovers and reconnects without a relaunch.
            self.central.connect(peripheral)
        }
    }
}

extension SophonHub: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services where service.uuid == SophonProtocol.serviceUUID {
            peripheral.discoverCharacteristics([SophonProtocol.motionCharacteristicUUID], for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil, let characteristics = service.characteristics else { return }
        for characteristic in characteristics
        where characteristic.uuid == SophonProtocol.motionCharacteristicUUID {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil,
              characteristic.uuid == SophonProtocol.motionCharacteristicUUID,
              let data = characteristic.value
        else { return }

        let byteCount = data.count
        guard let frame = MotionFrame(data) else {
            Task { @MainActor in
                // Worth shouting about: an unexpected length means the two sides
                // disagree about the wire format, which nothing downstream can
                // recover from.
                self.log.error("bad frame: \(byteCount) bytes, expected \(MotionFrame.wireSize)")
            }
            return
        }

        Task { @MainActor in
            self.byID[peripheral.identifier]?.ingest(frame)
        }
    }
}
