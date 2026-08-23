import CoreBluetooth
import Foundation
import os

/// The GATT server side of the simulator: advertising, the Sophon Motion
/// service, notify, and the transmit counters.
///
/// Counterpart to `zephyr/sophon/src/ble.c`, and reuses the frozen UUIDs from
/// `SophonProtocol` so the two cannot describe different services.
///
/// Delegate callbacks use `MainActor.assumeIsolated` rather than `Task { @MainActor }`,
/// which is the opposite of `SophonHub`'s style. That is forced, not preferred:
/// `CBATTRequest` is not `Sendable`, so a read request cannot cross an isolation
/// boundary without an unsafe escape. The manager is created with `queue: .main`,
/// so the assumption holds — and `assumeIsolated` traps loudly if that ever
/// changes, which is the right failure.
@MainActor
@Observable
final class SophonPeripheral: NSObject {
    private(set) var radio: RadioState = .unknown
    private(set) var isAdvertising = false
    private(set) var subscribers: Set<UUID> = []
    /// The largest value a notification can carry, as the central negotiated it.
    /// The board's analogue is the ATT MTU logged on connect.
    private(set) var maximumUpdateLength: Int?
    /// How many times the transmit queue filled and then drained. Counted for
    /// visibility only — see `notify(_:)` for why nothing is retried.
    private(set) var queueFullRecoveries = 0

    /// Cumulative since this simulator started, never reset except by `reboot()`.
    /// Kept out of observation because they move at the sample rate.
    @ObservationIgnored private var sent: UInt32 = 0
    @ObservationIgnored private var noConn: UInt32 = 0
    @ObservationIgnored private var noBuffer: UInt32 = 0
    @ObservationIgnored private var other: UInt32 = 0

    var counters: TxStats {
        TxStats(sent: sent, noConn: noConn, noBuffer: noBuffer, other: other)
    }

    var subscriberCount: Int { subscribers.count }

    private var manager: CBPeripheralManager?
    private var motionCharacteristic: CBMutableCharacteristic?
    private var advertisedName = ""
    private let log = Logger(subsystem: "com.vwong.Sophon", category: "peripheral")

    // MARK: - Lifecycle

    func start(localName: String) {
        advertisedName = localName
        guard manager == nil else { return }

        // Created lazily so viewer mode holds no peripheral-role radio, and
        // released in stop() so the counters get clean "board boot" semantics.
        //
        // The restore identifier lets iOS hand the session back if it relaunches
        // us in the background rather than leaving the viewer staring at a
        // peripheral that silently stopped existing.
        manager = CBPeripheralManager(
            delegate: self,
            queue: .main,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: "com.vwong.Sophon.peripheral"]
        )
    }

    func stop() {
        guard let manager else { return }

        // Explicit teardown in this order. Dropping the reference alone is not
        // documented to stop advertising promptly, and leaving the service
        // registered makes the next start() fail with "service already added".
        manager.stopAdvertising()
        manager.removeAllServices()
        manager.delegate = nil
        self.manager = nil

        motionCharacteristic = nil
        subscribers.removeAll()
        maximumUpdateLength = nil
        isAdvertising = false
        radio = .idle
        log.info("peripheral stopped")
    }

    /// Zeroes the counters without touching the link, standing in for a board
    /// power-cycle that stays inside the supervision timeout.
    func resetCounters() {
        sent = 0
        noConn = 0
        noBuffer = 0
        other = 0
        queueFullRecoveries = 0
    }

    // MARK: - Transmit

    /// Sends one frame, and records the outcome exactly as `sophon_ble_notify()`
    /// does.
    ///
    /// Returns false when the frame did not go out.
    @discardableResult
    func notify(_ frame: MotionFrame) -> Bool {
        guard let manager, let motionCharacteristic else { return false }

        guard !subscribers.isEmpty else {
            noConn &+= 1
            return false
        }

        let accepted = manager.updateValue(
            frame.encoded, for: motionCharacteristic, onSubscribedCentrals: nil
        )

        // false means the transmit queue is full, which is the natural analogue
        // of the firmware's -ENOMEM, so it lands in the same counter.
        //
        // Note what is NOT done: the frame is not retried and `seq` is not
        // rewound. `seq` is not even reachable from here — it lives in
        // SophonSimulator and has already advanced — and that is deliberate
        // structure rather than an accident of layering.
        if accepted { sent &+= 1 } else { noBuffer &+= 1 }
        return accepted
    }

    /// Counts an artificially dropped frame.
    ///
    /// The bench control that produces these exists because iOS's transmit queue
    /// is generous enough that `updateValue` essentially never fails at 18 bytes
    /// and 52 Hz. Left alone, `noBuffer` would read zero forever and the viewer's
    /// attribution logic would stay as untested as it has always been.
    func noteArtificialDrop() {
        noBuffer &+= 1
    }
}

// MARK: - CBPeripheralManagerDelegate

extension SophonPeripheral: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let state = peripheral.state
        MainActor.assumeIsolated {
            radio = RadioState(state)
            guard state == .poweredOn else {
                isAdvertising = false
                return
            }
            publishService(on: peripheral)
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        willRestoreState dict: [String: Any]
    ) {
        MainActor.assumeIsolated {
            log.info("restored by the system")
            // Recover the characteristic we must notify on. Rebuilding the
            // service instead would register a second copy of it.
            let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService]
            motionCharacteristic = services?
                .compactMap(\.characteristics)
                .flatMap { $0 }
                .compactMap { $0 as? CBMutableCharacteristic }
                .first { $0.uuid == SophonProtocol.motionCharacteristicUUID }
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(
        _ peripheral: CBPeripheralManager, error: Error?
    ) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            if let message {
                log.error("advertising failed: \(message, privacy: .public)")
                isAdvertising = false
                return
            }
            isAdvertising = true
            log.info("advertising as \(self.advertisedName, privacy: .public)")
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        // Sendable scalars extracted before touching the actor.
        let id = central.identifier
        let maxLength = central.maximumUpdateValueLength
        MainActor.assumeIsolated {
            subscribers.insert(id)
            maximumUpdateLength = maxLength
            log.info("central subscribed; max update \(maxLength)")
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        let id = central.identifier
        MainActor.assumeIsolated {
            subscribers.remove(id)
            if subscribers.isEmpty { maximumUpdateLength = nil }
            log.info("central unsubscribed")
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            // Core Bluetooth's documented pattern is to resend the failed value
            // here. This deliberately does not, for two reasons.
            //
            // A retry would deliver a sample whose t_ms is already stale, so the
            // central sees a continuous stream carrying a wrong timebase — worse
            // than the hole it replaced, and precisely what PROTOCOL.md argues
            // against under "What seq means".
            //
            // It would also decouple noBuffer from observed gaps, destroying the
            // one-to-one attribution that makes a gap explicable at all.
            //
            // Nothing is lost by waiting: the next sample is under 20 ms away,
            // and the board behaves identically — it keeps calling
            // bt_gatt_notify() every sample and lets the failures fall where
            // they may.
            queueFullRecoveries += 1
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest
    ) {
        // CBATTRequest is not Sendable, hence assumeIsolated rather than a hop.
        MainActor.assumeIsolated {
            guard request.characteristic.uuid == SophonProtocol.statsCharacteristicUUID else {
                peripheral.respond(to: request, withResult: .readNotPermitted)
                return
            }

            let data = counters.encoded
            // Offset handling mirrors bt_gatt_attr_read(). The viewer polls this
            // every 2 s, so it is a live path rather than protocol paperwork.
            guard request.offset <= data.count else {
                peripheral.respond(to: request, withResult: .invalidOffset)
                return
            }

            request.value = data.subdata(in: request.offset ..< data.count)
            peripheral.respond(to: request, withResult: .success)
        }
    }
}

// MARK: - Service construction

private extension SophonPeripheral {
    func publishService(on peripheral: CBPeripheralManager) {
        guard motionCharacteristic == nil else {
            startAdvertising(on: peripheral)
            return
        }

        // value: nil on BOTH characteristics, and this is not optional.
        //
        // A CBMutableCharacteristic built with a non-nil value is cached by Core
        // Bluetooth and served without the read handler ever running — which
        // would freeze the stats at whatever they were at startup. Worse,
        // combining a cached value with .notify raises an exception outright.
        let motion = CBMutableCharacteristic(
            type: SophonProtocol.motionCharacteristicUUID,
            properties: [.notify],
            value: nil,
            // Notify-only, so no read permission: the analogue of
            // BT_GATT_PERM_NONE on the board. Core Bluetooth adds the CCCD
            // itself; declaring one by hand is an error.
            permissions: []
        )
        let stats = CBMutableCharacteristic(
            type: SophonProtocol.statsCharacteristicUUID,
            properties: [.read],
            value: nil,
            permissions: [.readable]
        )

        let service = CBMutableService(type: SophonProtocol.serviceUUID, primary: true)
        service.characteristics = [motion, stats]

        motionCharacteristic = motion
        // Advertising waits for peripheralManagerDidAdd, below.
        peripheral.add(service)
    }

    func startAdvertising(on peripheral: CBPeripheralManager) {
        guard !peripheral.isAdvertising else { return }

        // iOS honours only these two keys. The service UUID must be in the
        // advertisement because the viewer's scan is filtered on it; iOS decides
        // for itself whether the name travels in the advertisement or the scan
        // response, and there is no API to influence that.
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: advertisedName,
            CBAdvertisementDataServiceUUIDsKey: [SophonProtocol.serviceUUID],
        ])
    }
}

extension SophonPeripheral {
    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: Error?
    ) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            if let message {
                log.error("adding service failed: \(message, privacy: .public)")
                return
            }
            startAdvertising(on: peripheral)
        }
    }
}
