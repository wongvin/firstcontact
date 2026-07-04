//
//  FirstContactApp.swift
//  FirstContact
//
//  Created by Vincent Wong on 4/26/26.
//

import SwiftUI

@main
struct FirstContactApp: App {
    // The keyword store and its Multipeer sync manager are owned here and shared with the view
    // hierarchy via the environment. The manager depends on the store, so both are built in init.
    @StateObject private var store: SyncStore
    @StateObject private var sync: SyncManager
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = SyncStore()
        _store = StateObject(wrappedValue: store)
        _sync = StateObject(wrappedValue: SyncManager(store: store))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(sync)
        }
        // Hold the radios only while the app is active; drop them in the background.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: sync.start()
            case .background, .inactive: sync.stop()
            @unknown default: break
            }
        }
    }
}
