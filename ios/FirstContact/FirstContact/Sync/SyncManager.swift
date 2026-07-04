//
//  SyncManager.swift
//  FirstContact
//
//  Local device-to-device keyword sync over Apple's Multipeer Connectivity. Each device plays a
//  symmetric role — it both advertises and browses — and auto-connects to the user's other
//  devices with no UI. On connect, and on every local change, it sends the full keyword set;
//  incoming sets are merged by the SyncStore (LWW by updatedAt, tombstones included).
//
//  MPC is a delegate-based Objective-C framework bridged to Swift: no async/await, and every
//  delegate callback arrives on MPC's own background queue. This class is @MainActor, so each
//  callback is nonisolated and hops back to the main actor before touching @Published state or
//  the store (both drive SwiftUI).
//

import Foundation
import Combine
import CryptoKit
import MultipeerConnectivity

@MainActor
final class SyncManager: NSObject, ObservableObject {
    // Bonjour service type: 1–15 chars, lowercase letters/digits/hyphen. Must match Info.plist's
    // NSBonjourServices (_fc-sync._tcp / _fc-sync._udp).
    private static let serviceType = "fc-sync"

    // Shared pairing secret (allowlist gate): the app only connects to peers that present this
    // secret, so it won't sync with a stranger's device on a shared (e.g. workplace) network.
    // Sourced from Secrets.xcconfig via GeneratedSecrets; a built-in default is used when unset
    // so the gate still works out of the box across the user's own builds.
    private static let secret: String = GeneratedSecrets.syncSecret.isEmpty
        ? "fc-default-pairing-v1" : GeneratedSecrets.syncSecret
    private static let secretData = Data(secret.utf8)
    // A short public hash of the secret, advertised in discoveryInfo so peers can pre-filter
    // before inviting — we never send the secret itself to a peer outside our group.
    private static let secretHash: String = SHA256.hash(data: secretData)
        .prefix(8).map { String(format: "%02x", $0) }.joined()

    @Published private(set) var connectedPeers: [MCPeerID] = []
    @Published private(set) var lastSyncedAt: Date?
    /// User-facing kill switch. Flipping it starts/stops the radios.
    @Published var enabled: Bool = true {
        didSet {
            guard oldValue != enabled else { return }
            enabled ? start() : stop()
        }
    }

    private let store: SyncStore
    private let peerID = MCPeerID(displayName: UIDevice.current.name)
    private lazy var session: MCSession = {
        let s = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        return s
    }()
    private lazy var advertiser = MCNearbyServiceAdvertiser(
        peer: peerID, discoveryInfo: ["h": Self.secretHash], serviceType: Self.serviceType)
    private lazy var browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)

    private var running = false

    init(store: SyncStore) {
        self.store = store
        super.init()
        advertiser.delegate = self
        browser.delegate = self
        // Re-broadcast whenever the user edits keywords locally.
        store.onLocalChange = { [weak self] in self?.broadcast() }
    }

    // MARK: - Lifecycle (driven by scenePhase from the App)

    func start() {
        guard enabled, !running else { return }
        running = true
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        guard running else { return }
        running = false
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        connectedPeers = []
    }

    // MARK: - Sending

    private func broadcast() { send(to: session.connectedPeers) }

    private func send(to peers: [MCPeerID]) {
        guard !peers.isEmpty else { return }
        let payload = SyncPayload(keywords: store.snapshot())
        guard let data = try? JSONEncoder().encode(payload) else { return }
        // A peer may drop mid-send; ignore the throw — the next connect resyncs the full set.
        try? session.send(data, toPeers: peers, with: .reliable)
    }
}

// MARK: - MCSessionDelegate

extension SyncManager: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID,
                             didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                if !self.connectedPeers.contains(peerID) { self.connectedPeers.append(peerID) }
                self.send(to: [peerID])   // hand the newcomer our full state
            case .notConnected:
                self.connectedPeers.removeAll { $0 == peerID }
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard let payload = try? JSONDecoder().decode(SyncPayload.self, from: data) else { return }
            let changed = self.store.merge(payload.keywords)
            self.lastSyncedAt = Date()
            // Echo back only if the merge actually changed us — bounds the exchange, no loops.
            if changed { self.send(to: self.session.connectedPeers) }
        }
    }

    // Unused transports — required by the protocol, intentionally empty.
    nonisolated func session(_ s: MCSession, didReceive stream: InputStream,
                             withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ s: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ s: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - Advertiser / Browser delegates (symmetric role with a deterministic invite tiebreak)

extension SyncManager: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            // Accept only peers that present our shared pairing secret AND lose the tiebreak
            // (the lower-sorting displayName invites; we, the higher, accept).
            let secretOK = context == Self.secretData
            let accept = secretOK && peerID.displayName < self.peerID.displayName
            invitationHandler(accept, accept ? self.session : nil)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didNotStartAdvertisingPeer error: Error) {}
}

extension SyncManager: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            // Only invite peers advertising our pairing hash — never even attempt a stranger.
            guard info?["h"] == Self.secretHash else { return }
            // Only the lower-sorting displayName sends the invite — prevents two crossing sessions.
            guard self.peerID.displayName < peerID.displayName else { return }
            guard !self.session.connectedPeers.contains(peerID) else { return }
            self.browser.invitePeer(peerID, to: self.session,
                                    withContext: Self.secretData, timeout: 30)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    nonisolated func browser(_ browser: MCNearbyServiceBrowser,
                             didNotStartBrowsingForPeers error: Error) {}
}
