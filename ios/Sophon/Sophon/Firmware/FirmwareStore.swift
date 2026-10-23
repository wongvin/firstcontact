import Foundation
import os

/// The firmware image this iPhone holds for updating boards (#357).
///
/// One image, the last one received: AirDropped from the Mac
/// (`zephyr/sophon/scripts/airdrop-fw.sh`) or opened from Files. Kept in
/// Application Support, not Documents, so it stays out of the Files app, where
/// Info.plist promises only walk-test recordings appear.
@MainActor
@Observable
final class FirmwareStore {
    private(set) var held: FirmwareImage?
    /// When `held` arrived, for the row that names it.
    private(set) var receivedAt: Date?
    /// The outcome of the last file opened, for an alert. Cleared by the view.
    var notice: String?

    private let log = Logger(subsystem: "com.vwong.Sophon", category: "firmware")

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Firmware", directoryHint: .isDirectory)
    }

    init() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard let file = files.first(where: { $0.pathExtension == "sophonfw" }),
              let data = try? Data(contentsOf: file) else { return }
        // Re-checked at launch: a file that no longer parses is not offered.
        guard let image = try? FirmwareImage(data) else { return }
        held = image
        receivedAt = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Take a file handed to the app by AirDrop or Files.
    func receive(_ url: URL) {
        // Files opens in place (LSSupportsOpeningDocumentsInPlace), outside the
        // sandbox; AirDrop copies into Documents/Inbox, which is ours to clear.
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            removeIfInbox(url)
        }

        let image: FirmwareImage
        do {
            image = try FirmwareImage(Data(contentsOf: url))
        } catch {
            notice = error.localizedDescription
            log.error("refused \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        do {
            let manager = FileManager.default
            try manager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            // Written before the old one goes, so a failed write leaves the
            // image already held in place, on disk as well as in memory.
            let kept = Self.directory.appending(path: "sophon-\(image.version).sophonfw")
            try image.data.write(to: kept, options: .atomic)
            for old in try manager.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)
            where old.lastPathComponent != kept.lastPathComponent {
                try? manager.removeItem(at: old)
            }
        } catch {
            notice = "Couldn't keep the firmware image: \(error.localizedDescription)"
            return
        }
        held = image
        receivedAt = Date()
        notice = "Firmware \(image.version) is on this iPhone. Boards running older firmware can be updated from their Configuration section."
        log.info("holding firmware \(image.version.description, privacy: .public)")
    }

    private func removeIfInbox(_ url: URL) {
        let inbox = URL.documentsDirectory.appending(path: "Inbox", directoryHint: .isDirectory)
        // Resolved, as /var and /private/var name the same container.
        guard url.resolvingSymlinksInPath().path.hasPrefix(inbox.resolvingSymlinksInPath().path) else { return }
        try? FileManager.default.removeItem(at: url)
        // The folder too, once empty: Documents is visible in Files.
        if (try? FileManager.default.contentsOfDirectory(atPath: inbox.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: inbox)
        }
    }
}
