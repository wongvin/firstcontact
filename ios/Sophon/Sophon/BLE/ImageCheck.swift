import Foundation
import iOSMcuManagerLibrary
import os

/// Compares the slot-0 image hash of a gateway and its transporter (#359), so
/// the bit-error test is known to compare like with like.
///
/// The transporter sends its own image and the gateway compares against its
/// own, so the figures mean something only if the two are the same. Equal
/// SHA-256 means equal bytes on air: the hash covers the MCUboot header and
/// body, exactly what is sent (TRANSPORTER-PLAN.md § Image identity).
///
/// The same SMP image-list read as ``FirmwareUpdater``, with the same rule: the
/// library makes its own central and retrieves each board by identifier, so it
/// rides the link the hub already holds to the gateway, and opens one of its
/// own to the transporter, which the hub never holds. One board at a time.
@MainActor
@Observable
final class ImageCheck {
    enum Result: Equatable, Sendable {
        case match
        case mismatch
        /// The transporter wasn't seen advertising, or SMP to it failed.
        case transporterUnreachable(String)
        /// The gateway's own slots couldn't be read.
        case gatewayUnreadable(String)
    }

    struct Outcome: Equatable, Sendable {
        let result: Result
        let transporter: String
        let at: Date
        /// Each board's advertised firmware when checked, so a later update
        /// on either one is seen to void the result (#359 review, finding 2).
        var gatewayFirmware: String?
        var transporterFirmware: String?
    }

    /// The outcome only while it still describes these boards: the transporter
    /// the gateway hears now, each board on the firmware it had when checked.
    /// A board whose firmware isn't known now (out of range, say) isn't held
    /// against it. A rebuild with an unchanged version slips through; the
    /// gateway's mismatch-suspected flag is the backstop for that.
    static func current(
        _ outcome: Outcome?, gateway: SophonDevice, transporterName: String?, transporter: SophonDevice?
    ) -> Outcome? {
        guard let outcome, outcome.transporter == transporterName else { return nil }
        func same(_ then: String?, _ now: String?) -> Bool { then == nil || now == nil || then == now }
        guard same(outcome.gatewayFirmware, gateway.identity?.firmwareVersion),
              same(outcome.transporterFirmware, transporter?.identity?.firmwareVersion) else { return nil }
        return outcome
    }

    /// Why a walk-test recording can't start on this gateway yet, or nil.
    ///
    /// A recording made while the gateway hears a transporter is a BER walk,
    /// and its bit errors mean something only if both boards run the same
    /// image. So it needs a current, matching check first (#359). A gateway
    /// hearing no transporter records an ordinary walk, as before.
    static func walkTestBlock(
        gateway: SophonDevice, findDevice: (String) -> SophonDevice?
    ) -> String? {
        guard let record = gateway.loraBer.record, record.heard else { return nil }
        // A gateway that can't read its own image can't run the check or the
        // test, so there is nothing to gate: blocking would only lock out an
        // ordinary walk with a stray transporter on air (final review, finding 1).
        guard record.canCompare else { return nil }
        guard let name = record.transporterName else {
            return "Waiting for the transporter to be named, then check images."
        }
        let check = current(gateway.loraBer.imageCheck, gateway: gateway, transporterName: name,
                            transporter: findDevice(name))
        switch check?.result {
        case .match: return nil
        case .mismatch: return "The images differ: flash the same image to both boards, then check again."
        case .transporterUnreachable, .gatewayUnreadable:
            return "The image check didn't finish: check images again before a BER walk."
        case nil: return "Check images first: a BER walk needs both boards on the same image."
        }
    }

    /// The gateway being checked, while a check runs.
    private(set) var checkingID: UUID?

    private var transport: McuMgrBleTransport?
    /// Both boards' firmware at the start of the check in flight.
    private var firmware: (gateway: String?, transporter: String?) = (nil, nil)
    private let log = Logger(subsystem: "com.vwong.Sophon", category: "firmware")

    var isBusy: Bool { checkingID != nil }

    /// - Parameter transporter: the hub's entry for the board named in the BER
    ///   record, or nil if the app hasn't seen it advertise.
    func run(gateway: SophonDevice, transporter: SophonDevice?, transporterName: String) {
        guard !isBusy else { return }
        guard let transporter else {
            gateway.loraBer.imageCheck = Outcome(
                result: .transporterUnreachable("not seen advertising"), transporter: transporterName, at: Date())
            return
        }
        checkingID = gateway.id
        firmware = (gateway.identity?.firmwareVersion, transporter.identity?.firmwareVersion)
        log.info(
            "checking images: \(gateway.displayName, privacy: .public) against \(transporterName, privacy: .public)")
        readSlot0(gateway.id) { [weak self] gatewayHash, gatewayError in
            guard let self else { return }
            guard let gatewayHash else {
                self.finish(gateway, .gatewayUnreadable(gatewayError ?? "no image in slot 0"), transporterName)
                return
            }
            self.readSlot0(transporter.id) { transporterHash, transporterError in
                guard let transporterHash else {
                    self.finish(gateway, .transporterUnreachable(transporterError ?? "no image in slot 0"),
                                transporterName)
                    return
                }
                self.finish(gateway, gatewayHash == transporterHash ? .match : .mismatch, transporterName)
            }
        }
    }

    /// One board's slot-0 hash, or an error's description.
    private func readSlot0(_ id: UUID, then done: @escaping (Data?, String?) -> Void) {
        let transport = McuMgrBleTransport(id)
        self.transport = transport
        ImageManager(transport: transport).list { [weak self] response, error in
            MainActor.assumeIsolated {
                transport.close()
                if self?.transport === transport { self?.transport = nil }
                if let error = error ?? response?.getError() {
                    done(nil, error.localizedDescription)
                    return
                }
                let running = response?.images?.first { $0.slot == 0 }
                done(running.map { Data($0.hash) }, nil)
            }
        }
    }

    private func finish(_ gateway: SophonDevice, _ result: Result, _ transporter: String) {
        log.info("image check: \(String(describing: result), privacy: .public)")
        gateway.loraBer.imageCheck = Outcome(
            result: result, transporter: transporter, at: Date(),
            gatewayFirmware: firmware.gateway, transporterFirmware: firmware.transporter)
        checkingID = nil
    }
}
