import Foundation
import UIKit
import iOSMcuManagerLibrary
import os

/// Updates one board's firmware over the air from the image this iPhone holds
/// (#357), the way `scripts/flash-ota.sh` does from the Mac: upload into the
/// spare slot, mark it for TEST, reset, and read back what runs.
///
/// THE APP NEVER CONFIRMS. The board confirms the new image itself, by the rule
/// in `maybe_confirm_image()` (ble.c): on its first delivered frame, or first
/// LoRa send as a sensor. Until then a reset reverts it. That is why the mode is
/// `.testOnly`, and why `refusal(for:)` runs before the library is let loose:
/// asked to update a board whose running image is still on trial, the library
/// would confirm that image on its own to free the spare slot, and with an
/// update already pending it would reset the board unasked.
///
/// The library makes its own `CBCentralManager` and retrieves its own
/// `CBPeripheral` by identifier. Not the hub's peripheral object: handed one,
/// the library sets itself as that object's delegate, and the hub would stop
/// hearing its board. iOS keeps one link per board whichever central asks, so
/// the update rides the connection the app already holds and
/// `CONFIG_BT_MAX_CONN=1` is no obstacle.
@MainActor
@Observable
final class FirmwareUpdater {
    enum Phase: Equatable {
        case checking
        case uploading(sent: Int, total: Int)
        case restarting
        case verifying
        case done(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .uploading, .restarting, .verifying: true
            case .done, .failed: false
            }
        }
    }

    /// The board being updated, and how far along. One board at a time.
    private(set) var deviceID: UUID?
    private(set) var phase: Phase?
    /// What the board is being updated to; kept with the result until dismissed.
    private(set) var targetVersion: FirmwareImage.Version?
    /// The first and latest progress callbacks, for the remaining-time
    /// estimate: model state, so the view reads no clock of its own.
    private(set) var uploadStartedAt: Date?
    private(set) var lastProgressAt: Date?

    /// Seconds left in the upload at the rate so far, once there is a rate.
    var uploadSecondsLeft: Int? {
        guard case .uploading(let sent, let total) = phase, sent > 0,
              let start = uploadStartedAt, let latest = lastProgressAt else { return nil }
        let elapsed = latest.timeIntervalSince(start)
        guard elapsed > 1 else { return nil }
        return Int((elapsed / Double(sent) * Double(total - sent)).rounded())
    }

    private var transport: McuMgrBleTransport?
    private var manager: FirmwareUpgradeManager?
    private var controller: FirmwareUpgradeController?
    private var image: FirmwareImage?
    /// The board, for its identity once the read-back says what it runs.
    private weak var device: SophonDevice?
    /// What the board ran before, for saying what a revert went back to.
    private var previousVersion: String?
    /// The screen's auto-lock as it was before the update, put back after.
    /// Safe to restore because nothing else that holds it can start while an
    /// update runs: the walk-test recorder and simulator mode are both
    /// disabled until it ends (#357 review, finding 3).
    private var idleTimerWasDisabled = false
    /// Gives up on a board that doesn't come back from its restart. The library
    /// waits for the disconnect with no limit of its own (#357 review, finding 2).
    private var watchdog: Task<Void, Never>?
    /// Read-backs left after the restart. Each waits up to 20 s for a link.
    private var verifyAttempts = 0

    /// MCUboot's swap, measured at about 20 s for a 190 KB image (flash-ota.sh);
    /// the library waits this long after the reset before reconnecting.
    private static let swapSeconds: TimeInterval = 25
    /// From the reset to giving up: the swap, boot, and four read-backs.
    private static let restartLimit: Duration = .seconds(150)

    private let log = Logger(subsystem: "com.vwong.Sophon", category: "firmware")

    var isBusy: Bool { phase?.isBusy == true }

    func phase(for device: SophonDevice) -> Phase? {
        deviceID == device.id ? phase : nil
    }

    /// Set by the hub: an image check uses SMP too, so neither may start while
    /// the other runs (#359 review, finding 3).
    weak var imageCheck: ImageCheck?

    func start(_ image: FirmwareImage, on device: SophonDevice) {
        guard !isBusy, imageCheck?.isBusy != true else { return }
        idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        deviceID = device.id
        self.device = device
        self.image = image
        targetVersion = image.version
        previousVersion = nil
        phase = .checking
        log.info("updating \(device.displayName, privacy: .public) to \(image.version.description, privacy: .public)")

        let transport = McuMgrBleTransport(device.id)
        self.transport = transport
        ImageManager(transport: transport).list { [weak self] response, error in
            MainActor.assumeIsolated { self?.checked(response, error) }
        }
    }

    /// Stops an upload. Only the upload can be stopped: once the image is
    /// marked, the board swaps at its next reset whatever the app does.
    func cancel() {
        guard case .uploading = phase else { return }
        controller?.cancel()
    }

    /// Clears a finished update's result.
    func dismiss() {
        guard !isBusy else { return }
        phase = nil
        deviceID = nil
        targetVersion = nil
    }

    // MARK: Steps

    private func checked(_ response: McuMgrImageStateResponse?, _ error: Error?) {
        guard phase == .checking, let image, let transport else { return }
        if let error = error ?? response?.getError() {
            finish(.failed("Couldn't read the board's firmware slots: \(error.localizedDescription)"))
            return
        }
        let slots = (response?.images ?? []).map {
            Slot(slot: $0.slot, version: $0.version, hash: Data($0.hash),
                 active: $0.active, confirmed: $0.confirmed, pending: $0.pending)
        }
        previousVersion = slots.first { $0.slot == 0 }?.version
        if let refusal = Self.refusal(for: slots, uploading: image.hash) {
            finish(.failed(refusal))
            return
        }

        let manager = FirmwareUpgradeManager(transport: transport, delegate: self)
        self.manager = manager
        let configuration = FirmwareUpgradeConfiguration(
            estimatedSwapTime: Self.swapSeconds,
            // Never: settings hold the board's configuration (#329).
            eraseAppSettings: false,
            upgradeMode: .testOnly)
        manager.start(images: [ImageManager.Image(image: 0, hash: image.hash, data: image.data)],
                      using: configuration)
    }

    /// Read back what runs after the swap, as flash-ota.sh does: a revert and a
    /// success both end with the board running, and only slot 0 tells them
    /// apart.
    private func verify() {
        guard let transport else { return }
        phase = .verifying
        verifyAttempts -= 1
        ImageManager(transport: transport).list { [weak self] response, error in
            MainActor.assumeIsolated { self?.verified(response, error) }
        }
    }

    private func verified(_ response: McuMgrImageStateResponse?, _ error: Error?) {
        guard phase == .verifying, let image else { return }
        if let error = error ?? response?.getError() {
            // The swap and boot can outlast one read-back's 20 s connect.
            if verifyAttempts > 0 {
                verify()
            } else {
                finish(.failed("""
                    The board restarted, but its firmware couldn't be read back \
                    (\(error.localizedDescription)). Reconnect to see which version it runs.
                    """))
            }
            return
        }
        let running = response?.images?.first { $0.slot == 0 }
        let version = running?.version ?? "unknown"
        noteRunning(version)
        // By hash, not version: a rebuild without a version bump that reverted
        // would otherwise read as updated (#357 review, finding 5).
        guard let running, Data(running.hash) == image.hash else {
            finish(.failed("""
                The board went back to \(version): \(image.version) started but didn't stay. \
                That is rollback working, not a failed upload.
                """))
            return
        }
        if running.confirmed {
            finish(.done("Updated to \(version)."))
        } else {
            finish(.done("""
                Updated to \(version), on trial. It keeps it once it delivers data; \
                a restart before then goes back to \(previousVersion ?? "the old firmware").
                """))
        }
    }

    /// Puts the version slot 0 reports into the board's identity.
    ///
    /// The identity comes from advertisements, and the hub's pending connect
    /// takes the board back as soon as it advertises after the swap, before iOS
    /// reports that advertisement: a scan without duplicates reports a known
    /// peripheral once. So the Link section went on showing the old version,
    /// and the Update button stayed up on a board already updated. The read-back
    /// is the board's own answer, and what its next advertisement will carry.
    private func noteRunning(_ version: String) {
        let parts = version.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count >= 2, let device, let identity = device.identity else {
            log.error("read-back \(version, privacy: .public) not applied: no device or identity")
            return
        }
        let updated = identity.withFirmware(major: parts[0], minor: parts[1])
        log.info("""
            read-back: \(device.displayName, privacy: .public) firmware \
            \(identity.firmwareVersion, privacy: .public) → \(updated.firmwareVersion, privacy: .public)
            """)
        if device.identity != updated { device.identity = updated }
    }

    /// Starts the restart's time limit, once.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        verifyAttempts = 4
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.restartLimit)
            guard !Task.isCancelled, let self, self.phase == .restarting || self.phase == .verifying else { return }
            self.finish(.failed("""
                The board didn't come back after restarting. If the new firmware doesn't run, \
                MCUboot puts the old one back at the next restart. Reconnect to see which version it runs.
                """))
        }
    }

    private func finish(_ result: Phase) {
        phase = result
        UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
        watchdog?.cancel()
        watchdog = nil
        switch result {
        case .done(let message): log.info("\(message, privacy: .public)")
        case .failed(let message): log.error("\(message, privacy: .public)")
        default: break
        }
        transport?.close()
        transport = nil
        manager = nil
        controller = nil
        image = nil
        device = nil
        uploadStartedAt = nil
        lastProgressAt = nil
    }

    // MARK: Refusals

    nonisolated struct Slot: Sendable {
        let slot: UInt64
        let version: String?
        let hash: Data
        let active: Bool
        let confirmed: Bool
        let pending: Bool
    }

    /// Why this board must not be updated now, or nil to go ahead. Each case is
    /// one where the library would otherwise confirm or reset on its own.
    ///
    /// One more such path exists, not covered here because it can't fire today:
    /// a command answered "unsupported" makes the library rename the board
    /// through the settings group and reset it into a firmware loader
    /// (`buttonlessResetIntoFirmwareLoader`). The rename fails, and the update
    /// with it, because the firmware doesn't enable `CONFIG_MCUMGR_GRP_SETTINGS`.
    /// Enabling that group would arm it.
    nonisolated static func refusal(for slots: [Slot], uploading hash: Data) -> String? {
        let running = slots.first { $0.slot == 0 }
        let spare = slots.first { $0.slot == 1 }
        if running?.hash == hash {
            return "This board already runs \(running?.version ?? "this firmware")."
        }
        if running?.confirmed == false || spare?.confirmed == true {
            return """
                This board is running an update on trial. Let it deliver data so it keeps it, \
                or restart it to go back, then try again.
                """
        }
        if spare?.pending == true {
            return "This board has an update waiting for its next restart. Restart it, then try again."
        }
        return nil
    }
}

extension FirmwareUpdater: FirmwareUpgradeDelegate {
    // The library calls these on the main queue.

    nonisolated func upgradeDidStart(controller: FirmwareUpgradeController) {
        MainActor.assumeIsolated { self.controller = controller }
    }

    nonisolated func upgradeStateDidChange(from previousState: FirmwareUpgradeState,
                                           to newState: FirmwareUpgradeState) {
        MainActor.assumeIsolated {
            guard self.isBusy else { return }
            switch newState {
            case .test, .reset:
                self.phase = .restarting
                self.startWatchdog()
            default: break
            }
        }
    }

    nonisolated func upgradeDidComplete() {
        // .testOnly "completes" on a timer, swapSeconds after the reset: the
        // library's reconnect is deferred to the next request, so it proves
        // nothing. The read-back in verify() is the first real contact.
        MainActor.assumeIsolated {
            guard self.isBusy else { return }
            self.verify()
        }
    }

    nonisolated func upgradeDidFail(inState state: FirmwareUpgradeState, with error: Error) {
        let reason = error.localizedDescription
        MainActor.assumeIsolated {
            guard self.isBusy else { return }
            let message = switch state {
            case .test, .reset:
                // The library's reconnect never fails, so a failure here is the
                // test or reset command itself: the board may not have restarted,
                // and the image may already be marked (#357 review, finding 1).
                """
                Couldn't restart the board into the new firmware (\(reason)). It may already be \
                marked to switch at the board's next restart; if so, the board keeps it only once \
                it delivers data. Reconnect to see which version it runs.
                """
            case .upload, .validate, .requestMcuMgrParameters, .bootloaderInfo:
                "Upload failed (\(reason)). The board still runs its old firmware; try again closer to it."
            default:
                "Update failed (\(reason))."
            }
            self.finish(.failed(message))
        }
    }

    nonisolated func upgradeDidCancel(state: FirmwareUpgradeState) {
        MainActor.assumeIsolated {
            guard self.isBusy else { return }
            // The board keeps what arrived, in RAM, until it restarts: an update
            // of the same image resumes there rather than at 0 (zephyr_img_mgmt.c).
            self.finish(.failed("""
                Cancelled. The board still runs \(self.previousVersion ?? "its old firmware"). \
                Updating again picks up where this stopped, unless the board restarts first.
                """))
        }
    }

    nonisolated func uploadProgressDidChange(bytesSent: Int, imageSize: Int, timestamp: Date) {
        MainActor.assumeIsolated {
            guard self.isBusy else { return }
            if self.uploadStartedAt == nil { self.uploadStartedAt = timestamp }
            self.lastProgressAt = timestamp
            self.phase = .uploading(sent: bytesSent, total: imageSize)
        }
    }
}

#if DEBUG
extension SophonProtocolSelfCheck {
    nonisolated static func checkFirmwareRefusals() {
        let new = Data(repeating: 1, count: 32)
        let old = Data(repeating: 2, count: 32)
        let older = Data(repeating: 3, count: 32)
        typealias Slot = FirmwareUpdater.Slot
        func slot(_ n: UInt64, _ hash: Data, confirmed: Bool = false, pending: Bool = false) -> Slot {
            Slot(slot: n, version: n == 0 ? "2.29.0" : "2.28.0", hash: hash,
                 active: n == 0, confirmed: confirmed, pending: pending)
        }
        // Settled after an earlier update: the old image sits unflagged in slot 1.
        assert(FirmwareUpdater.refusal(for: [slot(0, old, confirmed: true), slot(1, older)], uploading: new) == nil,
               "a settled board must be updatable")
        assert(FirmwareUpdater.refusal(for: [slot(0, old, confirmed: true)], uploading: new) == nil,
               "an empty spare slot must be updatable")
        assert(FirmwareUpdater.refusal(for: [slot(0, old), slot(1, older, confirmed: true)], uploading: new) != nil,
               "an image on trial must be refused: the library would confirm it")
        assert(FirmwareUpdater.refusal(for: [slot(0, old, confirmed: true), slot(1, older, pending: true)],
                                       uploading: new) != nil,
               "a pending update must be refused: the library would reset the board")
        assert(FirmwareUpdater.refusal(for: [slot(0, new, confirmed: true)], uploading: new) != nil,
               "the image already running must be refused")
    }
}
#endif
