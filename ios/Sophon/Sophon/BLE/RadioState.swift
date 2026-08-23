import CoreBluetooth

/// The Bluetooth radio's usability, shared by both roles.
///
/// Hoisted out of `SophonHub` when the simulator arrived. The four failure cases
/// are properties of the *radio*, identical whether this device is scanning or
/// advertising, so duplicating them per role would mean two enums drifting apart
/// and two copies of the view that explains them — the exact argument
/// `ContentView` already makes about its own sections.
///
/// What is *not* here is the busy state's name. "Scanning" and "advertising" are
/// properties of the role, not the radio, so each role keeps its own flag and
/// this enum says only `ready`.
///
/// `nonisolated` for the same reason as `SophonProtocol`: Core Bluetooth delegate
/// callbacks are nonisolated and have to be able to construct these.
nonisolated enum RadioState: Equatable {
    case unknown
    case unauthorized
    case unsupported
    case poweredOff
    /// Radio is up and this role is on the air.
    case ready
    /// Radio is fine, but this role has been deliberately taken off the air —
    /// the central while simulating, or the peripheral while viewing. Distinct
    /// from `poweredOff` so the UI can say "not right now" rather than implying
    /// something is broken.
    case idle

    var isUsable: Bool { self == .ready }

    /// Maps a `CBManagerState` to everything except the deliberate cases, which
    /// only the owning role knows about.
    init(_ state: CBManagerState) {
        switch state {
        case .poweredOn:    self = .ready
        case .poweredOff:   self = .poweredOff
        case .unauthorized: self = .unauthorized
        // Also the iOS Simulator, which has no Core Bluetooth hardware.
        case .unsupported:  self = .unsupported
        default:            self = .unknown
        }
    }
}
