import SwiftUI

@main
struct SophonApp: App {
    init() {
        #if DEBUG
        // Checks the 18-byte frame and 16-byte stats layouts against byte
        // vectors written out from PROTOCOL.md.
        //
        // Runs at launch because this project has no test target and the app now
        // contains *both* halves of the wire contract: if the encoder and decoder
        // drift together, every local test still passes while real hardware
        // silently disagrees. A handful of microseconds once per launch is a
        // cheap price for catching that on the first run rather than in a room
        // with a board.
        SophonProtocolSelfCheck.run()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
