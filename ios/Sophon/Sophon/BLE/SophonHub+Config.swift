import CoreBluetooth
import Foundation
import os

/// The Config characteristic and sensor handling (#329), in their own file so
/// SophonHub.swift stays readable. SophonHub calls these from its discovery,
/// update and write callbacks, inside `MainActor.assumeIsolated` blocks.
extension SophonHub {
    private static let configLog = Logger(subsystem: "com.vwong.Sophon", category: "config")

    /// Latch whether the GATT database has the characteristic, guarded like the
    /// other `offers*` latches against re-notifying an identical value (#261).
    func noteConfigOffered(_ characteristics: [CBCharacteristic], by device: SophonDevice?) {
        let offers = characteristics.contains { $0.uuid == SophonProtocol.configCharacteristicUUID }
        if device?.offersConfig != offers { device?.offersConfig = offers }
    }

    /// Read once at session start. Not polled: it changes only when this app
    /// writes it, and a write is followed by its own re-read or by a restart,
    /// whose reconnect reads it again.
    func readConfig(_ characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        configCharacteristics[peripheral.identifier] = characteristic
        peripheral.readValue(for: characteristic)
    }

    func ingestConfigValue(_ data: Data, from id: UUID) {
        guard let state = ConfigState(data) else {
            Self.configLog.error("malformed config (\(data.count, privacy: .public) bytes)")
            // A version this app doesn't read is a mismatch to explain (#346).
            if data.count == ConfigState.wireSize, let version = data.first,
               let mismatch = VersionMismatch.check(received: version, supported: ConfigState.version),
               let device = devices.first(where: { $0.id == id }), device.configMismatch != mismatch {
                device.configMismatch = mismatch
            }
            // An answer all the same: nothing better is coming this session
            // (#335 review, finding 3).
            configReadFailed(id)
            return
        }
        guard let device = devices.first(where: { $0.id == id }) else { return }
        if device.config != state { device.config = state }
        if device.configMismatch != nil { device.configMismatch = nil }
        if device.configReadFailed { device.configReadFailed = false }

        // The authoritative check that this link isn't one the app took by
        // accident (#329 review). A board restarted into the sensor role can be
        // reconnected before its SMP-only advertisement is ever seen: the
        // disconnect re-arms a connect, which completes on the first
        // connectable advertisement, after which the board stops advertising.
        // The config read on every connect says what the board really is.
        if state.active.role == .sensor {
            if !device.advertisesAsSensor { device.advertisesAsSensor = true }
            if !device.sensorSessionRequested {
                Self.configLog.info("\(device.displayName, privacy: .public) is a sensor; not holding it")
                dropConnection(device)
            }
        }

        // A write acknowledged before its flash save: check it landed.
        if let expected = device.configAwaitingStore, state.stored == expected {
            device.configAwaitingStore = nil
        }
        walkTest.configSettled(device)
    }

    /// A config read that failed is an answer, not "still reading" (#263).
    func configReadFailed(_ id: UUID) {
        guard let device = devices.first(where: { $0.id == id }) else { return }
        device.configReadFailed = true
        walkTest.configSettled(device)
    }

    /// Send a config. It is stored by the board and applied at its next restart,
    /// which the request can ask for. A board takes the write only if every
    /// field is in range and its hardware supports the role.
    func writeConfig(_ request: ConfigRequest, to device: SophonDevice) {
        guard let characteristic = configCharacteristics[device.id], device.state.isConnected else {
            device.configWriteError = "Not connected"
            return
        }
        device.configWriteError = nil
        device.configWritePending = true
        device.configWriteRestarts = request.restart
        device.configAwaitingStore = request.restart || request.restoreDefaults ? nil : request.config
        // Will it come back as a sensor? Then its disconnect must not be
        // re-armed -- unless the user is deliberately configuring a sensor.
        if request.restart, let state = device.config {
            let role = request.restoreDefaults ? SophonConfig.Role.auto : request.config.role
            let resolved = role == .auto ? state.autoRole : role
            device.expectingSensorRestart = resolved == .sensor && !device.sensorSessionRequested
        }
        device.peripheral.writeValue(request.encoded, for: characteristic, type: .withResponse)
        Self.configLog.info("config write to \(device.displayName, privacy: .public)")
    }

    func configWriteFinished(_ id: UUID, error: String?) {
        guard let device = devices.first(where: { $0.id == id }) else { return }
        device.configWritePending = false
        if let error {
            // Core Bluetooth doesn't name every ATT error -- the board's
            // "value not allowed" (0x13) arrives as a generic one -- so the
            // message says what a refusal means rather than quoting the code.
            device.configWriteError = "The board refused this setting (\(error))."
            device.expectingSensorRestart = false
            device.configAwaitingStore = nil
            Self.configLog.error("config write refused: \(error, privacy: .public)")
            return
        }
        // With a restart, the board disconnects about half a second from now and
        // the reconnect reads it afresh. Without one, re-read -- but not at once:
        // the board acknowledges before its flash save, which can take tens of
        // milliseconds longer, and a read too soon shows the old config.
        guard !device.configWriteRestarts else { return }
        Task { [weak self] in
            for delay in [300, 1500] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, device.state.isConnected, let characteristic = self.configCharacteristics[id]
                else { return }
                if device.configAwaitingStore == nil { return }
                device.peripheral.readValue(for: characteristic)
            }
            try? await Task.sleep(for: .milliseconds(500))
            if device.configAwaitingStore != nil, device.state.isConnected {
                device.configAwaitingStore = nil
                device.configWriteError = "The board accepted the setting but did not store it."
            }
        }
    }

    /// Track which role a board advertises (#329).
    ///
    /// A board in the LoRa sensor role advertises SMP and its name, not the
    /// Sophon service. It is listed under Sensors and connected only when the
    /// user taps Connect. Advertising the Sophon service again -- reconfigured
    /// as a gateway or direct -- returns it to the main list, to auto-connect as
    /// usual unless the user has released it.
    func noteRoleAdvertised(_ device: SophonDevice, sensor: Bool, sophon: Bool) {
        if sensor, !device.advertisesAsSensor {
            device.advertisesAsSensor = true
        } else if sophon, device.advertisesAsSensor {
            device.advertisesAsSensor = false
            device.sensorSessionRequested = false
        }
    }
}
