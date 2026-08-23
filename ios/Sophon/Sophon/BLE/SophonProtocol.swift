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

    /// Read-only, 16-byte value: the peripheral's own transmit counters.
    ///
    /// Read rather than notify — these move slowly and are diagnostics, and a
    /// notification would spend connection-event budget, which is the resource
    /// #211 is trying to measure.
    static let statsCharacteristicUUID = CBUUID(string: "C6560003-84D5-4DC2-8C1E-4B4EB2337CE4")
}

/// The peripheral's transmit outcome counters, cumulative since its boot.
///
/// These are the other half of the attribution story. `seqGaps` says an interval
/// has no data; only `noBuffer` can say whether those frames were lost on the air
/// or never left the board at all.
nonisolated struct TxStats: Equatable, Sendable {
    static let wireSize = 16

    /// Notifications the stack accepted.
    let sent: UInt32
    /// Rejected because nobody was subscribed. Expected, not a fault.
    let noConn: UInt32
    /// Rejected because the TX buffers were full — the interesting one.
    let noBuffer: UInt32
    /// Anything else the stack returned.
    let other: UInt32

    init?(_ data: Data) {
        guard data.count == Self.wireSize else { return nil }

        var bytes = [UInt8](repeating: 0, count: Self.wireSize)
        data.copyBytes(to: &bytes, count: Self.wireSize)

        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }

        sent = u32(0)
        noConn = u32(4)
        noBuffer = u32(8)
        other = u32(12)
    }

    init(sent: UInt32, noConn: UInt32, noBuffer: UInt32, other: UInt32) {
        self.sent = sent
        self.noConn = noConn
        self.noBuffer = noBuffer
        self.other = other
    }

    /// The inverse of `init?(_:)`, deliberately kept adjacent to it: this type is
    /// now written by the simulator (`Simulator/SophonPeripheral.swift`) and read
    /// from real hardware, so a layout change has to be made here in view of the
    /// decoder rather than in some far-away encoder that quietly disagrees.
    var encoded: Data {
        var bytes = [UInt8](repeating: 0, count: Self.wireSize)

        func put32(_ value: UInt32, _ offset: Int) {
            bytes[offset] = UInt8(truncatingIfNeeded: value)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
            bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
            bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
        }

        put32(sent, 0)
        put32(noConn, 4)
        put32(noBuffer, 8)
        put32(other, 12)

        return Data(bytes)
    }
}

nonisolated extension TxStats {
    /// True when the board reported a transmit failure worth explaining.
    /// `noConn` is excluded: it only means nobody was subscribed.
    var hasFailures: Bool { noBuffer > 0 || other > 0 }
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

    init(seq: UInt16, tMillis: UInt32,
         ax: Int16, ay: Int16, az: Int16,
         gx: Int16, gy: Int16, gz: Int16) {
        self.seq = seq
        self.tMillis = tMillis
        self.ax = ax
        self.ay = ay
        self.az = az
        self.gx = gx
        self.gy = gy
        self.gz = gz
    }

    /// The inverse of `init?(_:)`, kept immediately beneath it on purpose. There
    /// are now three implementations of this layout — the firmware, this decoder
    /// and this encoder — and the only cheap defence against them drifting is
    /// that two of the three are visible on one screen.
    ///
    /// Note `tMillis` is written as two `UInt16`s at 2 and 4, mirroring how the
    /// decoder reads it. That looks redundant next to a single 32-bit write, and
    /// it is deliberate: the frame is `__packed` on the firmware side and the
    /// field is not 4-byte aligned, so the halves are the honest description of
    /// what is on the wire.
    var encoded: Data {
        var bytes = [UInt8](repeating: 0, count: Self.wireSize)

        func put16(_ value: UInt16, _ offset: Int) {
            bytes[offset] = UInt8(truncatingIfNeeded: value)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        func putI16(_ value: Int16, _ offset: Int) {
            put16(UInt16(bitPattern: value), offset)
        }

        put16(seq, 0)
        put16(UInt16(truncatingIfNeeded: tMillis), 2)
        put16(UInt16(truncatingIfNeeded: tMillis >> 16), 4)
        putI16(ax, 6)
        putI16(ay, 8)
        putI16(az, 10)
        putI16(gx, 12)
        putI16(gy, 14)
        putI16(gz, 16)

        return Data(bytes)
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

nonisolated extension MotionFrame {
    /// Rounds and saturates a physical value into the wire's `Int16`, mirroring
    /// `clamp16()` and `div_round()` in `zephyr/sophon/src/imu.c`.
    ///
    /// This is not defensive tidiness — it is the difference between working and
    /// crashing. `Int16(200_000.0)` traps, and so does `Int16(Double.nan)`. The
    /// frame's gyro ceiling is 327.67 deg/s and an iPhone clears that on a flick
    /// of the wrist, so this path runs in ordinary use rather than at some
    /// theoretical extreme.
    ///
    /// The clamp happens in `Double` space *before* the conversion, which is the
    /// whole point: clamping afterwards would mean the trap has already fired.
    ///
    /// `rounded()` defaults to `.toNearestOrAwayFromZero`, which is exactly the
    /// half-away-from-zero behaviour `div_round()` implements by hand.
    static func wireValue(_ value: Double) -> Int16 {
        // NaN has no defensible representation on the wire, so it becomes zero.
        // Infinity does: it is off the top of the scale, which is precisely what
        // saturating means, so it falls through to the clamps below.
        //
        // Testing `isFinite` up front would lump the two together and quietly
        // report a violent, off-scale reading as "stationary" — the self-check
        // in this file caught exactly that mistake here.
        if value.isNaN { return 0 }

        let rounded = value.rounded()
        if rounded <= Double(Int16.min) { return .min }
        if rounded >= Double(Int16.max) { return .max }
        return Int16(rounded)
    }
}

#if DEBUG
/// Checks the wire format against byte vectors transcribed from `PROTOCOL.md`.
///
/// Deliberately **not** a round trip through our own decoder. A round trip is
/// self-consistent by construction: swap the endianness of both halves, or shift
/// every offset by the same amount, and it still passes while the board and the
/// phone disagree completely. That is precisely the failure this file's header
/// warns about, so the expected bytes below are written out from the offset table
/// in `PROTOCOL.md` and must never be regenerated from this code.
nonisolated enum SophonProtocolSelfCheck {
    static func run() {
        checkMotionFrame()
        checkTxStats()
    }

    private static func checkMotionFrame() {
        // seq 0x0201, t_ms 0x06050403, ax 0x0807 ... gz 0x1211 — every byte
        // distinct, so a transposition cannot hide behind a repeated value.
        let frame = MotionFrame(
            seq: 0x0201, tMillis: 0x0605_0403,
            ax: 0x0807, ay: 0x0A09, az: 0x0C0B,
            gx: 0x0E0D, gy: 0x100F, gz: 0x1211
        )
        let expected = Data([
            0x01, 0x02,             // seq        @0
            0x03, 0x04, 0x05, 0x06, // t_ms       @2
            0x07, 0x08,             // ax  milli-g @6
            0x09, 0x0A,             // ay          @8
            0x0B, 0x0C,             // az          @10
            0x0D, 0x0E,             // gx  cdeg/s  @12
            0x0F, 0x10,             // gy          @14
            0x11, 0x12,             // gz          @16
        ])

        assert(frame.encoded.count == MotionFrame.wireSize,
               "MotionFrame must encode to exactly \(MotionFrame.wireSize) bytes")
        assert(frame.encoded == expected,
               "MotionFrame wire layout disagrees with PROTOCOL.md")
        assert(MotionFrame(expected) == frame,
               "MotionFrame does not decode its own PROTOCOL.md byte vector")

        // Signed fields must survive the full Int16 range, negatives included.
        let extremes = MotionFrame(
            seq: .max, tMillis: .max,
            ax: .min, ay: .max, az: -1,
            gx: 1, gy: .min, gz: .max
        )
        assert(MotionFrame(extremes.encoded) == extremes,
               "MotionFrame loses sign or range at the Int16 extremes")

        // Saturation, the path that would otherwise trap.
        assert(MotionFrame.wireValue(200_000) == .max)
        assert(MotionFrame.wireValue(-200_000) == .min)
        assert(MotionFrame.wireValue(.nan) == 0)
        assert(MotionFrame.wireValue(.infinity) == .max)
        assert(MotionFrame.wireValue(0.5) == 1)   // half away from zero
        assert(MotionFrame.wireValue(-0.5) == -1)
    }

    private static func checkTxStats() {
        let stats = TxStats(sent: 0x0403_0201, noConn: 0x0807_0605,
                            noBuffer: 0x0C0B_0A09, other: 0x100F_0E0D)
        let expected = Data([
            0x01, 0x02, 0x03, 0x04, // sent     @0
            0x05, 0x06, 0x07, 0x08, // no_conn  @4
            0x09, 0x0A, 0x0B, 0x0C, // no_mem   @8
            0x0D, 0x0E, 0x0F, 0x10, // other    @12
        ])

        assert(stats.encoded.count == TxStats.wireSize,
               "TxStats must encode to exactly \(TxStats.wireSize) bytes")
        assert(stats.encoded == expected,
               "TxStats wire layout disagrees with PROTOCOL.md")
        assert(TxStats(expected) == stats,
               "TxStats does not decode its own PROTOCOL.md byte vector")
    }
}
#endif
