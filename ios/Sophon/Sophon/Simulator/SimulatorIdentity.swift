import Foundation
import UIKit

/// Per-install identity for the simulated Sophon.
///
/// Counterpart to `zephyr/sophon/src/ident.c`, and derived the same way: take a
/// per-chip (here, per-install) identifier and keep only its low 16 bits, so one
/// build produces a distinct, stable `Sophon-XXXX` on every device.
///
/// `PROTOCOL.md` notes that 16 bits is ample for a handful of boards and is not
/// collision-proof. The same caveat applies here, with one extra wrinkle: the
/// board's FICR id is burned into silicon, whereas `identifierForVendor` is nil
/// before first unlock and is regenerated if every app from this vendor is
/// removed. The derived digits are therefore persisted on first use, so the name
/// stays put for the life of the install even if the underlying id moves.
@MainActor
enum SimulatorIdentity {
    private static let defaultsKey = "simulatorDeviceTag"

    /// `Sophon-A3F2`. Deliberately indistinguishable from a real board's name:
    /// the viewer should need no special case, which is the whole point of a
    /// simulator that stands in for hardware.
    static func advertisedName() -> String {
        "Sophon-\(tag())"
    }

    private static func tag() -> String {
        if let stored = UserDefaults.standard.string(forKey: defaultsKey), stored.count == 4 {
            return stored
        }

        let tag = derivedTag()
        UserDefaults.standard.set(tag, forKey: defaultsKey)
        return tag
    }

    private static func derivedTag() -> String {
        // Low 16 bits of the vendor id, mirroring ident.c's use of the low half
        // of the 64-bit FICR device id.
        if let uuid = UIDevice.current.identifierForVendor {
            let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
            let low = (UInt16(bytes[14]) << 8) | UInt16(bytes[15])
            return String(format: "%04X", low)
        }

        // Nil before first unlock. ident.c falls back to advertising under a
        // plain name rather than refusing to start, and the same judgement
        // applies: a running simulator with an arbitrary tag beats no simulator.
        return String(format: "%04X", UInt16.random(in: 0...UInt16.max))
    }
}
