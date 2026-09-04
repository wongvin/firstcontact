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
    private var linkParamsCharacteristics: [UUID: CBCharacteristic] = [:]

    /// Peripherals that accepted a connection but had no Sophon service behind
    /// it. Tracked so the disconnect they are about to get is not treated as a
    /// dropout worth re-arming against. See `didDiscoverServices`.
    private var withoutService: Set<UUID> = []

    /// Which duplicate-reporting mode the running scan was started with, so
    /// `applyRadioState()` can tell when it needs restarting rather than
    /// assuming the option is fixed.
    private var scanningWithDuplicates = false

    /// The device whose detail view is on screen, if any. Removal is deferred for
    /// it: taking away the screen someone is standing on is the one thing this
    /// feature must not do (#235).
    private var deviceOnScreen: UUID?

    /// Drives ``forgetStaleReleased()``.
    ///
    /// Owned by the hub, NOT by a view. An earlier attempt hung this off the
    /// device list's `.task`, which a NavigationStack cancels the moment a detail
    /// view is pushed -- so staleness stopped being evaluated exactly while
    /// someone was looking at the screen that depends on it, and the control
    /// never changed. Staleness is model state and the model has to maintain it.
    ///
    /// Runs only while something is released, which is the only time the answer
    /// can change.
    private var sweepTask: Task<Void, Never>?
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

        // iOS IGNORES allowDuplicates while backgrounded, so lastSeenAt freezes
        // for the whole suspension no matter how healthily a board is
        // advertising. Returning to the foreground would then look like every
        // released device had gone silent, and the sweep would forget all of them
        // at once (#235).
        //
        // Re-stamping gives them a fresh window to prove themselves in, which is
        // the honest reading: the app has just started listening again and does
        // not yet know anything.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restampReleased()
            }
        }
    }

    /// Give every released device a fresh window to prove itself in.
    ///
    /// Called whenever the app starts listening again after a period of not
    /// listening -- returning to the foreground, or restarting a scan this role
    /// had stopped. In both cases `lastSeenAt` froze for reasons that say nothing
    /// about the board, so judging staleness against it would forget peripherals
    /// for our silence rather than theirs.
    private func restampReleased() {
        let now = Date()
        for device in devices where device.isReleasedByUser {
            device.lastSeenAt = now
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

    /// Let a board go, and mean it (#233).
    ///
    /// A real board is `CONFIG_BT_MAX_CONN=1` and invisible while taken, so this
    /// is what hands it to another tablet, or to nRF Connect, without a power
    /// cycle.
    ///
    /// The flag is set BEFORE the cancel, for the same reason `suspend()` sets
    /// `isSuspended` first: `cancelPeripheralConnection` is asynchronous and the
    /// disconnect callback runs inside a `Task { @MainActor }`, so it lands after
    /// this returns and must already be able to see the intent — otherwise it
    /// re-arms the connection being torn down.
    func release(_ device: SophonDevice) {
        device.isReleasedByUser = true
        // Start the clock now. Nothing has been heard since the release as far as
        // this feature is concerned, and the board is about to stop being ours.
        device.lastSeenAt = Date()
        central.cancelPeripheralConnection(device.peripheral)
        applyRadioState()
    }

    /// Take a released board back, or connect one that was never auto-connected.
    func reclaim(_ device: SophonDevice) {
        device.isReleasedByUser = false
        connect(device)
        // Back to consolidated discovery if nothing else is released.
        applyRadioState()
    }

    /// Drop a board the app can no longer see, so the list stops implying it is
    /// there (#235).
    ///
    /// Every collection keyed by this peripheral goes together — leaving an entry
    /// in any of them would resurrect a half-device on rediscovery. Forgetting
    /// also discards `isReleasedByUser` along with the object, so when the board
    /// advertises again it is discovered fresh and auto-connects with no special
    /// case anywhere.
    func forget(_ device: SophonDevice) {
        byID[device.id] = nil
        devices.removeAll { $0.id == device.id }
        statsCharacteristics[device.id] = nil
        linkParamsCharacteristics[device.id] = nil
        withoutService.remove(device.id)
        log.info("forgot \(device.displayName, privacy: .public)")
        applyRadioState()
    }

    /// Sweep released boards that have gone quiet.
    ///
    /// Skips the one whose detail view is open: a row vanishing from a list is
    /// ordinary, but pulling the screen out from under someone is not.
    /// Starts or stops the sweep to match whether anything is released AND the
    /// scan is running.
    ///
    /// Called only from `applyRadioState()`, on both its paths. Every caller that
    /// changes either input -- `release`, `reclaim`, `forget` -- goes through
    /// there already, so one place decides what should be running rather than
    /// each site remembering to ask twice.
    private func applySweepState() {
        // Both conditions, not just the first. The sweep decides a board is gone
        // from an ABSENCE of advertisements, which is only evidence when we are
        // actually listening -- otherwise it measures our own silence and forgets
        // peripherals for it (#241). radio == .ready is exactly "the scan is
        // running": applyRadioState sets it there and nowhere else.
        let wantSweep = radio == .ready && devices.contains { $0.isReleasedByUser }

        guard wantSweep else {
            sweepTask?.cancel()
            sweepTask = nil
            return
        }
        guard sweepTask == nil else { return }

        sweepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.forgetStaleReleased()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func forgetStaleReleased(asOf now: Date = Date()) {
        // Two passes on purpose. The first updates every device, including the one
        // being looked at -- that is what lets its detail view redraw and swap
        // Connect for an explanation. The second removes only the ones nobody is
        // standing on.
        for device in devices { device.evaluateStaleness(asOf: now) }

        for device in devices where device.id != deviceOnScreen && device.isStaleReleased {
            forget(device)
        }
    }

    /// Called by the detail view so the sweep can leave its device alone.
    func setDeviceOnScreen(_ id: UUID?) { deviceOnScreen = id }

    /// Re-read the board's transmit counters. Cheap and on demand — deliberately
    /// not a subscription, so it costs no connection-event budget.
    func refreshStats(_ device: SophonDevice) {
        // Link params ride the same poll. They change rarely, but "rarely" is not
        // "never" -- iOS stretches the interval to save power -- and a value that
        // is only ever read at connect is one nobody notices going stale (#224).
        if let params = linkParamsCharacteristics[device.id] {
            device.peripheral.readValue(for: params)
        }
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
        let wasScanning = (radio == .ready)

        // Duplicate reporting costs a callback per advertisement -- tens per
        // second per board -- so it is on ONLY while something is released and
        // its liveness actually has to be watched (#235). With it off, iOS
        // consolidates repeat sightings into one discovery event, which is why
        // lastSeenAt cannot be trusted outside this window.
        let wantDuplicates = devices.contains { $0.isReleasedByUser }

        if wantScan {
            if radio != .ready || scanningWithDuplicates != wantDuplicates {
                // Filtered by service UUID, which is REQUIRED: an unfiltered scan
                // returns nothing while the app is backgrounded. It also means the
                // peripheral must keep the service UUID in the advertisement, not
                // the scan response.
                central.stopScan()
                central.scanForPeripherals(
                    withServices: [SophonProtocol.serviceUUID],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: wantDuplicates]
                )
                scanningWithDuplicates = wantDuplicates
                log.info("scanning for Sophon peripherals (duplicates \(wantDuplicates, privacy: .public))")

                // Only when the scan was genuinely off. This branch also runs for
                // a duplicates-mode switch, where nothing was missed and a
                // re-stamp would just extend the window for free.
                if !wasScanning { restampReleased() }
            }
            radio = .ready
            applySweepState()
            return
        }

        // Falling through means the scan is stopping, so the sweep must stop with
        // it -- see applySweepState. Ordered after `radio` is set below.
        defer { applySweepState() }

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
            device.endSession()
        }
        statsCharacteristics.removeAll()
        linkParamsCharacteristics.removeAll()
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
        // Skips boards the user released: resume() connects directly rather than
        // waiting for a fresh advertisement, so it bypasses the guard in
        // didDiscover and would otherwise quietly undo the release (#233).
        for device in devices where !device.isReleasedByUser { connect(device) }
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

        // Read and parse everything out of the dictionary HERE: [String: Any] is
        // not Sendable, so it cannot cross into the Task below.
        //
        // Core Bluetooth hands back the whole manufacturer-data structure,
        // company ID included, which is what SophonIdentity expects.
        let identity = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
            .flatMap(SophonIdentity.init)

        // Signed dBm. Reading this as unsigned would render -8 as 248.
        let txPower = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue

        // Every key iOS surfaced, logged once per peripheral (#246).
        //
        // The app reads three keys and had assumed the rest were absent. That
        // assumption was wrong for TX power -- iOS adds a standard AD type of its
        // own, which `PROTOCOL.md` claimed could not happen -- so the honest move
        // is to look rather than guess again. This is what iOS chose to parse and
        // surface, which is a floor on what is really on the air, not a picture
        // of it: seeing the actual AD structures needs an observer (#252).
        let keys = advertisementData.keys.sorted().joined(separator: ", ")
        let keySet = Set(advertisementData.keys)

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
                self.log.info("advertisement keys: \(keys, privacy: .public)")
            }

            // Latch both, for the same reason the name is latched above: a
            // callback that carried no scan response must not blank a good value.
            // Feeding the update path only would miss the common case, where the
            // create above is the only callback we ever get for a device.
            device.advertisementKeys.formUnion(keySet)

            if let identity { device.identity = identity }
            if let txPower { device.txPower = txPower }

            // Before the released-guard below, deliberately: this is the only
            // evidence that a released board is still on the air and reclaimable.
            device.lastSeenAt = Date()

            device.ingestRSSI(rssi)
            peripheral.delegate = self

            // Auto-connect: with one board there is nothing to choose between,
            // and reconnect-on-return-to-range should not need a tap.
            // A fresh advertisement means it is worth another attempt, including
            // after it was dropped for having no service — advertising our UUID
            // is exactly the evidence that the app is back.
            self.withoutService.remove(peripheral.identifier)

            // ...but not if the user let this one go. A Sophon advertises
            // continuously, so without this check a manual release would be
            // undone by the next advertisement, about a second later (#233).
            // Per-device: releasing one board must not stop another connecting.
            guard !device.isReleasedByUser else { return }

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

            // Deliberately NOT resetLinkStats() here.
            //
            // didConnect means a link exists, not that a Sophon is behind it.
            // Between two iOS devices on one Apple ID the system keeps its own
            // links up, so the re-arm in didDisconnectPeripheral can succeed
            // against a phone whose Sophon app has been swiped away: the central
            // reports connected, service discovery finds nothing, and no frames
            // ever arrive.
            //
            // Resetting here wiped the session record on every one of those
            // phantom connects -- observed as the frame counts dropping to zero
            // and the transmit counters falling back to "Reading..." while the
            // peripheral no longer existed. Destroying the measurement you were
            // studying because the radio twitched is the worst possible moment
            // to do it.
            //
            // The stats are cleared once the motion characteristic is actually
            // subscribed, which is the real start of a session.

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
            device.endSession()
            self.log.info("disconnected \(device.displayName, privacy: .public)")
            self.statsCharacteristics[peripheral.identifier] = nil
            self.linkParamsCharacteristics[peripheral.identifier] = nil

            // Do not re-arm a link that was dropped on purpose. Without this,
            // suspend()'s cancels each bounce straight back into a connect() and
            // the phone reacquires the board's only connection slot while it is
            // supposed to be impersonating one.
            guard !self.isSuspended else { return }

            // Nor one dropped for having no Sophon service. Re-arming there is
            // what produced the endless Connected/Disconnected cycle against a
            // phone whose app had been closed. Rediscovery via the scan brings
            // it back when there is actually something to talk to.
            if self.withoutService.remove(peripheral.identifier) != nil { return }

            // Nor one the user let go of. This is the path that would actually
            // undo a manual release: cancelPeripheralConnection lands here, and
            // this re-arm fires immediately, without waiting on the scan -- so
            // the guard in didDiscover would never even be reached (#233).
            guard !device.isReleasedByUser else {
                self.log.info("released \(device.displayName, privacy: .public), not re-arming")
                return
            }

            // Re-arm. The scan is still running, so walking back into range
            // rediscovers and reconnects without a relaunch.
            self.central.connect(peripheral)
        }
    }
}

extension SophonHub: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // MainActor.assumeIsolated rather than a Task hop, for two reasons.
        //
        // CBService is not Sendable, so it cannot cross an isolation boundary --
        // the same constraint that shapes the peripheral side.
        //
        // And the ordering here is load-bearing: the session must be reset before
        // any characteristic work is issued. Deferring the reset into a Task while
        // issuing discovery synchronously let the first frames, or the stats read
        // response, arrive and then be zeroed by a reset that landed after them.
        MainActor.assumeIsolated {
            let services = peripheral.services ?? []
            let sophon = error == nil
                ? services.first { $0.uuid == SophonProtocol.serviceUUID }
                : nil

            guard let sophon else {
                // Connected to something that is not currently a Sophon.
                //
                // This is a real state, not a theoretical one. Between two iOS
                // devices on one Apple ID the system keeps its own links up, so a
                // connect can succeed against a phone whose Sophon app has been
                // swiped away. The link is genuine; the service is simply not there.
                //
                // Left alone this spun forever: connect succeeds, nothing is ever
                // discovered, no frames arrive, the link eventually times out, the
                // disconnect handler re-arms, and round it goes -- a device row
                // permanently claiming Connected to an app that does not exist.
                //
                // So drop it and do not re-arm. Recovery does not depend on the
                // re-arm anyway: the scan is still running, so the moment the app
                // starts advertising again it is rediscovered and reconnected.
                self.log.info("no Sophon service on this peripheral; dropping")
                self.withoutService.insert(peripheral.identifier)
                self.central.cancelPeripheralConnection(peripheral)
                return
            }

            // The session starts here -- a real Sophon is known to be behind the
            // link -- and everything below is ordered behind it.
            self.byID[peripheral.identifier]?.beginSession()

            // Explicitly filtered rather than passing nil, which is cheaper --
            // but it means a new characteristic must be added HERE as well as to
            // the switch in didDiscoverCharacteristicsFor. Adding only the handler
            // is silent: the characteristic is never discovered, so the handler
            // never runs and the UI simply shows nothing (#224).
            peripheral.discoverCharacteristics(
                [SophonProtocol.motionCharacteristicUUID,
                 SophonProtocol.statsCharacteristicUUID,
                 SophonProtocol.linkParamsCharacteristicUUID],
                for: sophon)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        // assumeIsolated for the same reason as didDiscoverServices: CBCharacteristic
        // is not Sendable, and caching one inside a Task was reaching across an
        // isolation boundary with a reference type that must not cross it.
        MainActor.assumeIsolated {
            guard error == nil, let characteristics = service.characteristics else { return }
            for characteristic in characteristics {
                switch characteristic.uuid {
                case SophonProtocol.motionCharacteristicUUID:
                    peripheral.setNotifyValue(true, for: characteristic)
                case SophonProtocol.statsCharacteristicUUID:
                    // Read once at session start to establish the baseline; after
                    // that it is refreshed on demand from the detail view.
                    self.statsCharacteristics[peripheral.identifier] = characteristic
                    peripheral.readValue(for: characteristic)
                case SophonProtocol.linkParamsCharacteristicUUID:
                    // Read once here, and again whenever stats are refreshed --
                    // iOS revises the interval on its own schedule, so a value
                    // read only at connect goes quietly stale (#224).
                    self.linkParamsCharacteristics[peripheral.identifier] = characteristic
                    peripheral.readValue(for: characteristic)
                default:
                    break
                }
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

        if characteristic.uuid == SophonProtocol.linkParamsCharacteristicUUID {
            let byteCount = data.count
            guard let params = LinkParams(data) else {
                Task { @MainActor in
                    self.log.error("bad link params: \(byteCount) bytes, expected \(LinkParams.wireSize)")
                }
                return
            }
            Task { @MainActor in
                self.byID[peripheral.identifier]?.linkParams = params
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
