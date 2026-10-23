// Opens macOS's AirDrop window for one file (#357). Run by airdrop-fw.sh as
// `swift scripts/airdrop.swift <file>`; exits 0 once the file is sent, 1 if the
// share is cancelled or fails, 2 if AirDrop is unavailable.
//
// NSSharingService needs a running application to put its window on, so this
// starts one as an accessory (no Dock icon) and stops it when the share ends.

import AppKit

final class Sender: NSObject, NSSharingServiceDelegate {
    func sharingService(_ service: NSSharingService, didShareItems items: [Any]) { exit(0) }

    func sharingService(_ service: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        FileHandle.standardError.write("airdrop: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift airdrop.swift <file>\n".data(using: .utf8)!)
    exit(64)
}
let file = URL(fileURLWithPath: arguments[1])

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let sender = Sender()

DispatchQueue.main.async {
    guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [file]) else {
        FileHandle.standardError.write("airdrop: AirDrop is not available\n".data(using: .utf8)!)
        exit(2)
    }
    service.delegate = sender
    app.activate(ignoringOtherApps: true)
    service.perform(withItems: [file])
}
app.run()
