import SwiftUI

/// The over-the-air update rows in a board's Configuration section (#357): the
/// Update button, on any board advertising firmware older than the image this
/// iPhone holds, and beside #346's version warning; then the update's progress
/// and result.
///
/// Progress is shown whatever the section shows otherwise: once the board is
/// back on new firmware its Config frame reads, the warning goes, and the
/// result still has to be seen.
struct FirmwareUpdateRows: View {
    let device: SophonDevice
    let firmware: FirmwareStore
    let updater: FirmwareUpdater
    /// The board's Config frame is older than this app reads (#346). Under that
    /// warning the rows also say why no update is offered; elsewhere they
    /// appear only when one is.
    let warned: Bool
    /// A walk-test recording is running; an update would cut it off.
    let recording: Bool
    /// Asks for confirmation. Held by the detail view, outside its List (see
    /// ``View/firmwareUpdateConfirmation(isPresented:device:firmware:updater:)``).
    let onUpdate: () -> Void

    var body: some View {
        if let phase = updater.phase(for: device) {
            progress(phase)
        } else if warned || heldIsNewer {
            offerRow
        }
    }

    /// The held image is newer than the firmware the board advertises.
    private var heldIsNewer: Bool {
        guard let held = firmware.held, let identity = device.identity else { return false }
        return held.version.isNewer(thanMajor: identity.firmwareMajor, minor: identity.firmwareMinor)
    }

    @ViewBuilder private var offerRow: some View {
        if let held = firmware.held {
            if let identity = device.identity,
               !held.version.isNewer(thanMajor: identity.firmwareMajor, minor: identity.firmwareMinor) {
                note("This iPhone holds firmware \(held.version), not newer than the board's \(identity.firmwareVersion).")
            } else if device.identity == nil {
                // No version to compare with, so no downgrade check (#357 review, finding 5).
                note("This board's firmware version isn't known yet.")
            } else if updater.isBusy {
                note("Another board is updating.")
            } else if recording {
                note("Stop the walk-test recording to update.")
            } else if !device.state.isConnected {
                note("Connect to update.")
            } else {
                Button("Update to \(held.version)", action: onUpdate)
            }
        } else {
            note("To update from here, AirDrop a firmware image from the Mac.")
        }
    }

    @ViewBuilder private func progress(_ phase: FirmwareUpdater.Phase) -> some View {
        let target = updater.targetVersion.map { "\($0)" } ?? "new firmware"
        switch phase {
        case .checking:
            LabeledContent("Updating to \(target)") { ProgressView() }
        case .uploading(let sent, let total):
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Updating to \(target)") {
                    Text(total > 0 ? "\(sent * 100 / total) %" : "")
                }
                ProgressView(value: Double(sent), total: Double(max(total, 1)))
                Text(uploadDetail(sent: sent, total: total))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("Cancel update", role: .destructive) { updater.cancel() }
        case .restarting:
            LabeledContent("Restarting into \(target)") { ProgressView() }
            note("The board swaps its firmware, which takes about 25 s. Keep this iPhone near it.")
        case .verifying:
            LabeledContent("Checking what runs") { ProgressView() }
        case .done(let message):
            Text(message).foregroundStyle(.green)
            Button("OK") { updater.dismiss() }
        case .failed(let message):
            Text(message).foregroundStyle(.red)
            Button("OK") { updater.dismiss() }
        }
    }

    private func uploadDetail(sent: Int, total: Int) -> String {
        let kb = "\(sent / 1024) of \(total / 1024) KB"
        guard let left = updater.uploadSecondsLeft else { return kb + ". Keep this iPhone near the board." }
        return kb + ", about \(left) s left. Keep this iPhone near the board."
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
    }
}

extension View {
    /// The confirmation before an update. Attach it outside any List, for the
    /// reason given at ``View/configEditor(item:device:onWrite:)``: the List
    /// rebuilds its sections every second and would dismiss it.
    func firmwareUpdateConfirmation(
        isPresented: Binding<Bool>,
        device: SophonDevice,
        firmware: FirmwareStore,
        updater: FirmwareUpdater,
        recording: Bool
    ) -> some View {
        confirmationDialog("Update \(device.displayName)?", isPresented: isPresented, titleVisibility: .visible) {
            if let held = firmware.held {
                Button("Update to \(held.version)") {
                    // Checked again on the tap: the board may have dropped, or a
                    // recording started, while the dialog was up.
                    guard device.state.isConnected, !recording else { return }
                    updater.start(held, on: device)
                }
            }
        } message: {
            if let held = firmware.held {
                let from = device.identity.map { " from \($0.firmwareVersion)" } ?? ""
                Text("""
                    Sends firmware \(held.version) (\(held.data.count / 1024) KB) to \(device.displayName)\(from), \
                    then restarts it. About two minutes; keep this iPhone near the board. The board keeps the \
                    new firmware once it delivers data, and goes back to the old one if it restarts before then.
                    """)
            }
        }
    }
}
