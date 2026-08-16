import CoreBluetooth
import Foundation

/// The wire contract with the Zephyr peripheral.
///
/// Mirrors `zephyr/sophon/PROTOCOL.md` and `zephyr/sophon/src/frame.h`. Any
/// change here needs the same change on the firmware side.
/// `nonisolated` because the target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and Core Bluetooth's delegate
/// callbacks are nonisolated — without this they cannot read these constants.
nonisolated enum SophonProtocol {
    /// Carried in the advertisement, so it can be used as a scan filter.
    /// Filtered scanning is required for iOS to report anything while backgrounded.
    static let serviceUUID = CBUUID(string: "C6560001-84D5-4DC2-8C1E-4B4EB2337CE4")

    /// Notify-only, 18-byte value.
    static let motionCharacteristicUUID = CBUUID(string: "C6560002-84D5-4DC2-8C1E-4B4EB2337CE4")
}

/// One IMU sample. 18 bytes on the wire, little-endian.
///
/// Sized to fit the default 23-byte ATT MTU so a sample is exactly one radio
/// packet — which is why `init?(_:)` can insist on an exact length rather than
/// reassembling across notifications.
nonisolated struct MotionFrame: Equatable, Sendable {
    static let wireSize = 18

    /// Wraps at 65535. Used to detect drops without a timer.
    let seq: UInt16
    /// Milliseconds since *the source board's* boot — not a shared clock.
    /// Aligning two devices to the same instant is a known gap (#211).
    let tMillis: UInt32

    /// Accelerometer, milli-g.
    let ax: Int16, ay: Int16, az: Int16
    /// Gyroscope, centi-degrees/second.
    let gx: Int16, gy: Int16, gz: Int16

    init?(_ data: Data) {
        guard data.count == Self.wireSize else { return nil }

        // Copy into a contiguous buffer first. A Data sliced out of another Data
        // keeps the parent's indices, so data[0] can trap — and loadUnaligned
        // needs a known-aligned base anyway.
        var bytes = [UInt8](repeating: 0, count: Self.wireSize)
        data.copyBytes(to: &bytes, count: Self.wireSize)

        func u16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        func i16(_ offset: Int) -> Int16 {
            Int16(bitPattern: u16(offset))
        }

        seq = u16(0)
        tMillis = UInt32(u16(2)) | (UInt32(u16(4)) << 16)
        ax = i16(6)
        ay = i16(8)
        az = i16(10)
        gx = i16(12)
        gy = i16(14)
        gz = i16(16)
    }
}

nonisolated extension MotionFrame {
    /// Frames skipped between `previous` and `self`, accounting for the `seq`
    /// wrap. Returns 0 for the expected next frame.
    ///
    /// A duplicate or reordered frame reads as a very large gap rather than a
    /// negative one, which is the honest answer — the sequence really did not
    /// advance by one, and pretending otherwise would hide a real problem.
    func gap(since previous: MotionFrame) -> Int {
        Int(seq &- previous.seq &- 1)
    }

    /// Skeleton frames (#208) carry live `seq`/`t_ms` and zeroed axes. Useful
    /// for telling "the link works but there is no IMU yet" apart from "the
    /// board is streaming real data".
    var isAxesZero: Bool {
        ax == 0 && ay == 0 && az == 0 && gx == 0 && gy == 0 && gz == 0
    }
}
