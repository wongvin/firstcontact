import Foundation
import os

/// The gateway peer a walk-test recording holds (#360).
///
/// With peer "any", a gateway drops the packets that end a fade longer than 5 s
/// until its sensor's next status trailer, and lets go of the sensor if the
/// trailers stop for 5 s: 171 of the sensor's own packets on the 2026-10-24
/// walk. A walk test runs one sensor per channel, so for its length the app
/// configures that sensor as the gateway's peer, with the existing Config write.
/// A configured peer is never released, and its stream is kept across a fade
/// of up to 20 s (firmware 2.38.0, `lora_lock.c`). Stop writes the gateway's
/// previous config back.
///
/// A Config write takes effect at a restart, so the gateway restarts once when
/// the hold is set and once when it's released; the recording rides through
/// both. If the app is gone at Stop, the peer stays configured until changed in
/// Configuration, where it shows.
struct PeerHold: Equatable {
    let gateway: UUID
    /// The stored config before the hold, written back at Stop.
    let original: SophonConfig
    let sensor: UInt16
    /// Stop came while the gateway was out of reach: restore on its next read.
    var restorePending = false
}

extension SophonHub {
    private static let holdLog = Logger(subsystem: "com.vwong.Sophon", category: "walktest")

    /// Hold the recording's gateway to the sensor it has locked onto, once:
    /// only while recording, only that recording's gateway, only with peer
    /// "any" configured, and only once a sensor is locked.
    ///
    /// "Any" is judged from the stored config with no restart pending, so the
    /// running config is the stored one. Not from the config's *active* peer:
    /// a gateway reports the sensor it has locked onto there (`config.c`), so
    /// that is never 0 at the moment this is meant to run.
    func holdWalkTestPeer(_ gateway: SophonDevice) {
        guard walkTest.isRecording, walkTest.gatewayID == gateway.id, peerHold == nil,
              gateway.state.isConnected, !gateway.configWritePending,
              let state = gateway.config, state.active.role == .gateway, !state.restartPending,
              state.stored.peerID == 0,
              let sensor = gateway.loraLink?.sensorID, sensor != 0 else { return }
        var held = state.stored
        held.peerID = sensor
        peerHold = PeerHold(gateway: gateway.id, original: state.stored, sensor: sensor)
        let name = String(format: "Sophon-%04X", sensor)
        walkTest.noteEvent("peer held: \(name) (gateway restarting)")
        Self.holdLog.info("holding \(gateway.displayName, privacy: .public) to \(name, privacy: .public)")
        writeConfig(ConfigRequest(config: held, restart: true, restoreDefaults: false), to: gateway)
    }

    /// At Stop: write the gateway's config from before the hold, or, if it's
    /// out of reach, as soon as it's read again.
    func releaseWalkTestPeer() {
        guard var hold = peerHold else { return }
        walkTest.noteEvent("peer released (gateway restarting)")
        if let gateway = devices.first(where: { $0.id == hold.gateway }),
           gateway.state.isConnected, !gateway.configWritePending, gateway.config != nil {
            restore(hold, on: gateway)
        } else {
            hold.restorePending = true
            peerHold = hold
            Self.holdLog.info("peer restore deferred until the gateway is back")
        }
    }

    /// A deferred restore, on the gateway's next config read. Only while the
    /// held peer is still stored: someone may have changed it since.
    func finishPeerRestore(_ gateway: SophonDevice, state: ConfigState) {
        guard let hold = peerHold, hold.restorePending, hold.gateway == gateway.id,
              !walkTest.isRecording else { return }
        if state.stored.peerID == hold.sensor, gateway.state.isConnected {
            restore(hold, on: gateway)
        } else {
            peerHold = nil
        }
    }

    private func restore(_ hold: PeerHold, on gateway: SophonDevice) {
        peerHold = nil
        Self.holdLog.info("restoring \(gateway.displayName, privacy: .public)'s peer")
        writeConfig(ConfigRequest(config: hold.original, restart: true, restoreDefaults: false), to: gateway)
    }
}
