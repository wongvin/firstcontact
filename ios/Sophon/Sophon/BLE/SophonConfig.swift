import CoreBluetooth
import Foundation

/// A board's configuration (#329): a role override and the LoRa parameters,
/// stored on the board and applied at its next restart.
///
/// Mirrors `struct sophon_config` in `zephyr/sophon/src/config.h` and
/// PROTOCOL.md § Config frame. Any change here needs the same change there.
nonisolated struct SophonConfig: Equatable, Sendable {
    nonisolated enum Role: UInt8, CaseIterable, Sendable {
        /// No override: the board picks its role from its hardware at every boot.
        case auto = 0
        case direct = 1
        case sensor = 2
        case gateway = 3

        var label: String {
            switch self {
            case .auto: "Auto"
            case .direct: "Direct"
            case .sensor: "Sensor"
            case .gateway: "Gateway"
            }
        }
    }

    /// Sentinels meaning "the build's own value".
    static let presetDefault: UInt8 = 0xFF
    static let txDefault: Int8 = 0x7F
    static let freqDefault: UInt32 = 0

    /// A 500 kHz channel centred here stays inside 902–928 MHz.
    static let freqRange: ClosedRange<UInt32> = 902_250_000...927_750_000
    static let txRange: ClosedRange<Int8> = -9...22

    var role: Role
    var preset: UInt8
    var txDbm: Int8
    var freqHz: UInt32
    var peerID: UInt16

    static let defaults = SophonConfig(
        role: .auto, preset: presetDefault, txDbm: txDefault, freqHz: freqDefault, peerID: 0)

    /// The nine bytes role…peer, shared by the read and the write.
    static let fieldsSize = 9

    init(role: Role, preset: UInt8, txDbm: Int8, freqHz: UInt32, peerID: UInt16) {
        self.role = role
        self.preset = preset
        self.txDbm = txDbm
        self.freqHz = freqHz
        self.peerID = peerID
    }

    /// Nil for an unknown role byte.
    init?(fields bytes: ArraySlice<UInt8>) {
        guard bytes.count == Self.fieldsSize else { return nil }
        let raw = Array(bytes)
        guard let role = Role(rawValue: raw[0]) else { return nil }
        self.role = role
        preset = raw[1]
        txDbm = Int8(bitPattern: raw[2])
        freqHz = UInt32(raw[3]) | UInt32(raw[4]) << 8 | UInt32(raw[5]) << 16 | UInt32(raw[6]) << 24
        peerID = UInt16(raw[7]) | UInt16(raw[8]) << 8
    }

    var fields: [UInt8] {
        [role.rawValue, preset, UInt8(bitPattern: txDbm),
         UInt8(freqHz & 0xFF), UInt8(freqHz >> 8 & 0xFF), UInt8(freqHz >> 16 & 0xFF), UInt8(freqHz >> 24),
         UInt8(peerID & 0xFF), UInt8(peerID >> 8)]
    }

    /// Whether every field is in the range the board accepts. The board checks
    /// again, along with the hardware; this only spares a round trip.
    var isValid: Bool {
        (preset == Self.presetDefault || Int(preset) < LoRaLinkRecord.presetNames.count)
            && (txDbm == Self.txDefault || Self.txRange.contains(txDbm))
            && (freqHz == Self.freqDefault || Self.freqRange.contains(freqHz))
    }

    var presetLabel: String {
        preset == Self.presetDefault ? "Build default"
            : Int(preset) < LoRaLinkRecord.presetNames.count ? LoRaLinkRecord.presetNames[Int(preset)]
            : "preset \(preset)"
    }

    var txLabel: String { txDbm == Self.txDefault ? "Preset's own" : "\(txDbm) dBm" }

    var freqLabel: String {
        freqHz == Self.freqDefault ? "Build default" : String(format: "%.3f MHz", Double(freqHz) / 1e6)
    }

    var peerLabel: String { peerID == 0 ? "Any (first heard)" : String(format: "Sophon-%04X", peerID) }
}

/// The Config characteristic's read: what is stored, what is running, and why.
/// PROTOCOL.md § Config frame, 20 bytes.
nonisolated struct ConfigState: Equatable, Sendable {
    static let wireSize = 20
    static let version: UInt8 = 1

    /// What flash holds: the config the next restart will run.
    let stored: SophonConfig
    /// What this boot runs, resolved: the role actually chosen, the preset id
    /// rather than "default", the TX power and frequency in use, the locked peer.
    let active: SophonConfig
    let status: UInt8

    var radioPresent: Bool { status & 0x01 != 0 }
    var imuPresent: Bool { status & 0x02 != 0 }
    /// Stored differs from what is running: a restart would change something.
    var restartPending: Bool { status & 0x04 != 0 }
    /// A stored role override is what this boot runs.
    var roleForced: Bool { status & 0x08 != 0 }
    /// This boot runs a config from flash, not the build's defaults.
    var fromFlash: Bool { status & 0x10 != 0 }
    /// The boot-loop guard tripped: the stored config is being ignored this boot.
    var guardTripped: Bool { status & 0x20 != 0 }

    init?(_ data: Data) {
        guard data.count == Self.wireSize else { return nil }
        let raw = [UInt8](data)
        guard raw[0] == Self.version,
              let stored = SophonConfig(fields: raw[1...9]),
              let active = SophonConfig(fields: raw[10...18]) else { return nil }
        self.stored = stored
        self.active = active
        status = raw[19]
    }

    /// The roles this board's hardware can run, as the firmware validates them:
    /// sensor needs a radio and an IMU, gateway a radio.
    var supportedRoles: [SophonConfig.Role] {
        SophonConfig.Role.allCases.filter {
            switch $0 {
            case .auto, .direct: true
            case .sensor: radioPresent && imuPresent
            case .gateway: radioPresent
            }
        }
    }

    /// What Auto picks on this board: the hardware table in LORA-PROTOCOL.md § Roles.
    var autoRole: SophonConfig.Role {
        !radioPresent ? .direct : imuPresent ? .sensor : .gateway
    }
}

/// The Config characteristic's write. PROTOCOL.md § Config frame, 12 bytes.
nonisolated struct ConfigRequest: Equatable, Sendable {
    static let wireSize = 12

    var config: SophonConfig
    /// Reboot once saved, so the config takes effect now.
    var restart: Bool
    /// Erase the stored config; the fields are ignored.
    var restoreDefaults: Bool

    var encoded: Data {
        let flags: UInt8 = (restart ? 0x01 : 0) | (restoreDefaults ? 0x02 : 0)
        return Data([ConfigState.version] + config.fields + [flags, 0])
    }
}

extension SophonProtocol {
    /// Read and write-with-response, on every board (#329). See ``ConfigState``.
    nonisolated static let configCharacteristicUUID = CBUUID(string: "C6560007-84D5-4DC2-8C1E-4B4EB2337CE4")

    /// The MCUmgr SMP service. A board in the sensor role advertises this and its
    /// name, but not the Sophon service, so the app scans for both (#329).
    nonisolated static let smpServiceUUID = CBUUID(string: "8D53DC1D-1DB7-4CD3-868B-8A527460AA84")
}

extension SophonProtocolSelfCheck {
    nonisolated static func checkConfig() {
        // PROTOCOL.md § Config frame: stored gateway, V3, +14 dBm, 915.5 MHz
        // (0x36916BE0), peer 0x86F0; active gateway, V3, +14 dBm, the same
        // frequency, peer 0x86F0; status radio | forced | from flash (0x19).
        let wire = Data([
            0x01,                                                     // version
            0x03, 0x02, 0x0E, 0xE0, 0x6B, 0x91, 0x36, 0xF0, 0x86,     // stored
            0x03, 0x02, 0x0E, 0xE0, 0x6B, 0x91, 0x36, 0xF0, 0x86,     // active
            0x19,                                                     // status
        ])
        guard let state = ConfigState(wire) else {
            assertionFailure("ConfigState rejected a valid 20-byte frame")
            return
        }
        assert(state.stored.role == .gateway && state.stored.preset == 2, "role or preset misread")
        assert(state.stored.txDbm == 14, "tx power misread")
        assert(state.stored.freqHz == 915_500_000, "frequency byte-swapped")
        assert(state.stored.peerID == 0x86F0, "peer byte-swapped")
        assert(state.radioPresent && !state.imuPresent && state.roleForced && state.fromFlash
               && !state.restartPending && !state.guardTripped, "status bits misread")
        assert(state.supportedRoles == [.auto, .direct, .gateway], "a radio without an IMU cannot be a sensor")
        assert(state.autoRole == .gateway, "Auto on radio-only hardware is a gateway")
        assert(ConfigState(wire.dropLast()) == nil, "short frame must be rejected")
        assert(ConfigState(wire + Data([0])) == nil, "long frame must be rejected")
        var badVersion = wire
        badVersion[0] = 2
        assert(ConfigState(badVersion) == nil, "an unknown version must be dropped")
        var badRole = wire
        badRole[1] = 4
        assert(ConfigState(badRole) == nil, "an unknown role must be dropped")
        var negative = wire
        negative[3] = 0xF7 // -9 dBm
        assert(ConfigState(negative)?.stored.txDbm == -9, "tx power must be signed")

        // The write: the same config, restart requested.
        let request = ConfigRequest(config: state.stored, restart: true, restoreDefaults: false)
        assert(request.encoded == Data([0x01, 0x03, 0x02, 0x0E, 0xE0, 0x6B, 0x91, 0x36, 0xF0, 0x86, 0x01, 0x00]),
               "ConfigRequest does not encode PROTOCOL.md's byte vector")
        let reset = ConfigRequest(config: .defaults, restart: true, restoreDefaults: true)
        assert(reset.encoded == Data([0x01, 0x00, 0xFF, 0x7F, 0, 0, 0, 0, 0, 0, 0x03, 0x00]),
               "restore defaults must encode the sentinels and both flags")

        assert(SophonConfig.defaults.isValid, "defaults must be valid")
        var bad = SophonConfig.defaults
        bad.preset = 9
        assert(!bad.isValid, "preset 9 must be rejected")
        bad = .defaults
        bad.freqHz = 900_000_000
        assert(!bad.isValid, "900 MHz must be rejected")
    }
}
