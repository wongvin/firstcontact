import CoreBluetooth
import Foundation
import UIKit
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
    private(set) var radio: RadioState = .unknown
    private(set) var devices: [SophonDevice] = []

    /// True while this role has been deliberately taken off the air so the
    /// simulator can use the radio instead. See `suspend()`.
    private(set) var isSuspended = false

    /// Last state the manager reported. Kept because whether the scan should be
    /// running depends on this *and* on `isSuspended`, and deciding that in two
    /// places is how the two get out of step.
    private var managerState: CBManagerState = .unknown

    private var central: CBCentralManager!
    private var byID: [UUID: SophonDevice] = [:]
    /// Held per device so stats can be re-read on demand without rediscovering.
    private var statsCharacteristics: [UUID: CBCharacteristic] = [:]
    private let log = Logger(subsystem: "com.vwong.Sophon", category: "ble")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)

        // Frames missed while the app is not running are not link loss. iOS
        // says exactly when that starts, which beats inferring it from how long
        // a gap lasted -- a two-second screen lock and a two-second dropout are
        // identical by duration, and only this tells them apart.
        //
        // BOTH notifications are observed, not just the background one. A quick
        // screen toggle can resign active without ever fully backgrounding, and
        // the app stops being scheduled from the earlier of the two -- so
        // watching only didEnterBackground leaves exactly the short suspensions
        // that happen most often still counted as loss.
        for name in [UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.devices.forEach { $0.noteSuspended() }
                }
            }
        }
    }

    func device(for peripheral: CBPeripheral) -> SophonDevice? {
        byID[peripheral.identifier]
    }

    func connect(_ device: SophonDevice) {
        // isSuspended is checked as well as the radio state: a discovery Task
        // queued just before suspend() can land just after it.
        guard radio.isUsable, !isSuspended else { return }
        device.state = .connecting
        central.connect(device.peripheral)
    }

    func disconnect(_ device: SophonDevice) {
        central.cancelPeripheralConnection(device.peripheral)
    }

    /// Re-read the board's transmit counters. Cheap and on demand — deliberately
    /// not a subscription, so it costs no connection-event budget.
    func refreshStats(_ device: SophonDevice) {
        guard let characteristic = statsCharacteristics[device.id] else { return }
        device.peripheral.readValue(for: characteristic)
    }

    /// The single decision point for whether the scan should be running.
    ///
    /// Two independent inputs govern it -- the radio's own state and whether this
    /// role has been deliberately suspended -- and they change from unrelated
    /// callbacks. Resolving them in one place means the answer cannot depend on
    /// which one happened to fire last, which is exactly the bug that appears
    /// when a second condition is bolted into the state callback.
    private func applyRadioState() {
        let wantScan = (managerState == .poweredOn) && !isSuspended

        if wantScan {
            if radio != .ready {
                // Filtered by service UUID, which is REQUIRED: an unfiltered scan
                // returns nothing while the app is backgrounded. It also means the
                // peripheral must keep the service UUID in the advertisement, not
                // the scan response.
                central.scanForPeripherals(
                    withServices: [SophonProtocol.serviceUUID],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                )
                log.info("scanning for Sophon peripherals")
            }
            radio = .ready
            return
        }

        if radio == .ready {
            central.stopScan()
            log.info("stopped scanning")
        }

        // poweredOn here can only mean deliberately suspended -- the radio is
        // fine, this role is just not using it.
        radio = isSuspended && managerState == .poweredOn ? .idle : RadioState(managerState)
    }

    /// Take the central off the air so this device can advertise as a Sophon
    /// instead.
    ///
    /// Not merely cosmetic: a real board is `CONFIG_BT_MAX_CONN=1`, so a phone
    /// that keeps scanning while pretending to be a board will connect to the
    /// real one and hold its only connection slot.
    func suspend() {
        guard !isSuspended else { return }

        // Set FIRST, before any cancel. cancelPeripheralConnection is
        // asynchronous and didDisconnectPeripheral's body runs inside a
        // Task { @MainActor }, so those bodies land after this function returns
        // and must be able to see the flag -- otherwise each one re-arms the
        // very connection being torn down.
        isSuspended = true
        applyRadioState()

        // Every known peripheral, not just the connected ones. An outstanding
        // connect() on iOS never times out, so a device sitting in .disconnected
        // may still have a live request pending that would grab the board the
        // moment it comes into range. cancelPeripheralConnection cancels pending
        // requests as well as established links.
        for device in devices {
            central.cancelPeripheralConnection(device.peripheral)
            device.state = .disconnected(reason: "simulator mode")
        }
        statsCharacteristics.removeAll()
    }

    /// Put the central back on the air after `suspend()`.
    ///
    /// `devices` is deliberately kept across the suspension: `resetLinkStats()`
    /// already runs on every `didConnect`, so no stale counters survive, and
    /// keeping the objects means a reconnect is immediate rather than waiting on
    /// rediscovery.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        applyRadioState()
        for device in devices { connect(device) }
    }
}

extension SophonHub: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            self.managerState = state
            self.applyRadioState()
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
                // Only overwrite when a name was actually advertised. This
                // matters more since the simulator: iOS strips the local name
                // from advertisements while the app is backgrounded, so a
                // backgrounded Sophon keeps re-advertising with no name, and
                // clobbering the good one would rename it to the phone's own
                // device name mid-session.
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
            self.statsCharacteristics[peripheral.identifier] = nil

            // Do not re-arm a link that was dropped on purpose. Without this,
            // suspend()'s cancels each bounce straight back into a connect() and
            // the phone reacquires the board's only connection slot while it is
            // supposed to be impersonating one.
            guard !self.isSuspended else { return }

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
            peripheral.discoverCharacteristics(
                [SophonProtocol.motionCharacteristicUUID,
                 SophonProtocol.statsCharacteristicUUID],
                for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil, let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case SophonProtocol.motionCharacteristicUUID:
                peripheral.setNotifyValue(true, for: characteristic)
            case SophonProtocol.statsCharacteristicUUID:
                // Read once on connect to establish the session baseline; after
                // that it is refreshed on demand from the detail view.
                peripheral.readValue(for: characteristic)
                Task { @MainActor in
                    self.statsCharacteristics[peripheral.identifier] = characteristic
                }
            default:
                break
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }

        if characteristic.uuid == SophonProtocol.statsCharacteristicUUID {
            let byteCount = data.count
            guard let stats = TxStats(data) else {
                Task { @MainActor in
                    self.log.error("bad stats: \(byteCount) bytes, expected \(TxStats.wireSize)")
                }
                return
            }
            Task { @MainActor in
                self.byID[peripheral.identifier]?.ingest(stats)
            }
            return
        }

        guard characteristic.uuid == SophonProtocol.motionCharacteristicUUID else { return }

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
