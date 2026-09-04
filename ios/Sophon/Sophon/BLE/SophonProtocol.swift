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

    /// Read-only, 8-byte value: the connection parameters iOS granted.
    ///
    /// This exists because **Core Bluetooth exposes no API for them** — an iOS app
    /// cannot ask what interval, latency or supervision timeout it was given. Only
    /// the peripheral can see them, so they have to travel back over GATT (#224).
    ///
    /// Read rather than notify for the same reason as the stats: they change
    /// rarely, and a subscription would spend the connection-event budget these
    /// values exist to explain.
    static let linkParamsCharacteristicUUID = CBUUID(string: "C6560004-84D5-4DC2-8C1E-4B4EB2337CE4")

    /// Manufacturer Specific Data company ID, mirroring `SOPHON_COMPANY_ID` in
    /// `zephyr/sophon/src/version.h`.
    ///
    /// `0xFFFF` is reserved for internal/test use, which is what applies without
    /// SIG membership. It is **not** exclusive, so matching it is a label check,
    /// not proof the peripheral is a Sophon — the service UUID does that, and the
    /// scan is already filtered on it.
    static let companyID: UInt16 = 0xFFFF

    /// The scan-response layout this build knows, mirroring
    /// `SOPHON_SCAN_RSP_VERSION`. An unrecognised value is still parsed: fields
    /// are append-only and never reordered, so the offsets below stay valid.
    static let knownScanRspVersion: UInt8 = 0x01

    /// Mirrors `SOPHON_DEVICE_TYPE`. Display-only — see `SophonIdentity`.
    static let knownDeviceType: UInt16 = 0x0001

    /// Advertisement keys this app reads or knowingly ignores.
    ///
    /// Anything outside this set is something iOS surfaced that nobody here has
    /// looked at. #246 exists because exactly that happened: iOS adds a TX Power
    /// AD type of its own, `PROTOCOL.md` asserted it could not, and no code was
    /// watching for the difference.
    static let expectedAdvertisementKeys: Set<String> = [
        CBAdvertisementDataLocalNameKey,
        CBAdvertisementDataServiceUUIDsKey,
        CBAdvertisementDataManufacturerDataKey,
        CBAdvertisementDataTxPowerLevelKey,
        CBAdvertisementDataIsConnectable,
        CBAdvertisementDataServiceDataKey,
        CBAdvertisementDataOverflowServiceUUIDsKey,
        CBAdvertisementDataSolicitedServiceUUIDsKey,

        // Undocumented, and present on every peripheral — observed on iOS 26
        // alongside the documented keys above. These are **reception metadata**,
        // not AD types: when iOS saw the packet, and which PHY it arrived on.
        // Nothing the peripheral sent.
        //
        // Listed as string literals because there are no public constants for
        // them. Nothing reads their values; they are here so the diagnostic row
        // stays quiet, since a warning that is always lit is one nobody reads —
        // which would defeat the guard #246 added it for.
        //
        // Notably absent: any key indicating whether a callback carried the
        // advertisement or the scan response. Core Bluetooth still merges those,
        // which is what #230's single-structure design depends on.
        "kCBAdvDataTimestamp",
        "kCBAdvDataRxPrimaryPHY",
        "kCBAdvDataRxSecondaryPHY",
    ]
}

/// What a Sophon says about itself before you connect.
///
/// Parsed from `CBAdvertisementDataManufacturerDataKey`. Mirrors
/// `struct sophon_mfg_data` in `zephyr/sophon/src/version.h`; any change there
/// needs the same change here.
///
/// Every field is **display-only**. Nothing branches on them — in particular,
/// connection policy must not, because an iOS peripheral cannot advertise
/// manufacturer data at all, so the simulator never has any of this.
/// The connection parameters the peripheral reports iOS granted.
///
/// Mirrors `struct sophon_link_params` in `zephyr/sophon/src/ble.h`; any change
/// there needs the same change here.
///
/// Governs buffer refusals, frame gaps and stream latency — and iOS revises the
/// interval on its own schedule, notably stretching it to save power, which is
/// what #209's frame loss turned out to be.
nonisolated struct LinkParams: Equatable, Sendable {
    static let wireSize = 8

    /// Microseconds. The peripheral deliberately sends `interval_us` rather than
    /// the deprecated 1.25 ms unit, so no conversion happens on this side.
    let intervalMicros: UInt32

    /// Connection events the peripheral may skip.
    let latency: UInt16

    /// Supervision timeout in **10 ms units**, as carried on the wire.
    let timeoutUnits: UInt16

    var intervalMillis: Double { Double(intervalMicros) / 1000 }
    var timeoutMillis: Int { Int(timeoutUnits) * 10 }

    /// Connection events per second, which is the form worth comparing against a
    /// sample rate: 50 Hz of frames through 33 events/s cannot fit, and that is
    /// the arithmetic #248 is about.
    var eventsPerSecond: Double? {
        guard intervalMicros > 0 else { return nil }
        return 1_000_000 / Double(intervalMicros)
    }

    init?(_ data: Data) {
        guard data.count == Self.wireSize else { return nil }

        var bytes = [UInt8](repeating: 0, count: Self.wireSize)
        data.copyBytes(to: &bytes, count: Self.wireSize)

        func u16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }

        intervalMicros = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        latency = u16(4)
        timeoutUnits = u16(6)
    }

    init(intervalMicros: UInt32, latency: UInt16, timeoutUnits: UInt16) {
        self.intervalMicros = intervalMicros
        self.latency = latency
        self.timeoutUnits = timeoutUnits
    }
}

nonisolated struct SophonIdentity: Equatable, Sendable {
    /// Minimum, not exact. Trailing bytes are ignored so that appending a field
    /// firmware-side does not turn into a parse failure here.
    static let minWireSize = 8

    let scanRspVersion: UInt8
    let deviceType: UInt16
    let hardwareVersion: UInt8
    let firmwareMajor: UInt8
    let firmwareMinor: UInt8

    var firmwareVersion: String { "\(firmwareMajor).\(firmwareMinor)" }

    /// True when both the structure layout and the device type are ones this
    /// build knows. Surfaced to the user only when false.
    var isFullyRecognised: Bool {
        scanRspVersion == SophonProtocol.knownScanRspVersion
            && deviceType == SophonProtocol.knownDeviceType
    }

    /// - Parameter data: the **whole** manufacturer-data structure, company ID
    ///   included. That is what Core Bluetooth hands back; note `bleak` and some
    ///   other stacks strip the company ID into a dictionary key instead, so byte
    ///   offsets quoted elsewhere may be two lower.
    init?(_ data: Data) {
        guard data.count >= Self.minWireSize else { return nil }

        var bytes = [UInt8](repeating: 0, count: Self.minWireSize)
        data.copyBytes(to: &bytes, count: Self.minWireSize)

        func u16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }

        guard u16(0) == SophonProtocol.companyID else { return nil }

        scanRspVersion = bytes[2]
        deviceType = u16(3)
        hardwareVersion = bytes[5]
        firmwareMajor = bytes[6]
        firmwareMinor = bytes[7]
    }

    init(scanRspVersion: UInt8, deviceType: UInt16, hardwareVersion: UInt8,
         firmwareMajor: UInt8, firmwareMinor: UInt8) {
        self.scanRspVersion = scanRspVersion
        self.deviceType = deviceType
        self.hardwareVersion = hardwareVersion
        self.firmwareMajor = firmwareMajor
        self.firmwareMinor = firmwareMinor
    }
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
        checkIdentity()
        checkLinkParams()
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

    private static func checkLinkParams() {
        // Written out from the offset table in PROTOCOL.md, not produced by an
        // encoder: this type is decode-only.
        let wire = Data([
            0x40, 0x9C, 0x00, 0x00, // interval_us @0 = 40000 (40 ms)
            0x04, 0x00,             // latency     @4 = 4
            0x48, 0x00,             // timeout     @6 = 72 units = 720 ms
        ])

        guard let params = LinkParams(wire) else {
            assertionFailure("LinkParams failed to decode its PROTOCOL.md byte vector")
            return
        }

        assert(params.intervalMicros == 40_000,
               "interval decoded byte-swapped or misaligned")
        assert(params.latency == 4)
        assert(params.timeoutUnits == 72)
        assert(params.timeoutMillis == 720, "timeout is 10 ms units on the wire")
        assert(params.intervalMillis == 40)

        // 40 ms -> 25 events/s. The figure #248 needs, so a mistake here would
        // corrupt the capacity arithmetic rather than merely a displayed number.
        assert(params.eventsPerSecond == 25)

        // Exact length, unlike SophonIdentity: this is a fixed GATT value with no
        // append-only rule behind it, so a wrong length means a wrong contract.
        assert(LinkParams(wire.dropLast()) == nil)
        assert(LinkParams(wire + Data([0x00])) == nil)
    }

    private static func checkIdentity() {
        // Written out from the offset table, not produced by an encoder: this
        // type is decode-only, so there is no round trip available even if one
        // were wanted.
        let wire = Data([
            0xFF, 0xFF, // company ID   @0
            0x01,       // scan rsp ver @2
            0x01, 0x00, // device type  @3, little-endian
            0x01,       // hw version   @5
            0x02,       // fw major     @6
            0x00,       // fw minor     @7
        ])

        guard let identity = SophonIdentity(wire) else {
            assertionFailure("SophonIdentity failed to decode its PROTOCOL.md byte vector")
            return
        }

        // The device-type bytes are the only asymmetric field in the structure,
        // so they are the only ones that can catch a byte-order mistake — 0xFFFF
        // reads the same either way round.
        assert(identity.deviceType == SophonProtocol.knownDeviceType,
               "device type decoded byte-swapped: expected 0x0001 from 01 00")
        assert(identity.scanRspVersion == SophonProtocol.knownScanRspVersion)
        assert(identity.hardwareVersion == 1)
        assert(identity.firmwareVersion == "2.0")
        assert(identity.isFullyRecognised)

        // Trailing bytes must be tolerated, or the firmware's append-only rule
        // becomes a parse failure the first time anything is appended.
        assert(SophonIdentity(wire + Data([0xAB, 0xCD])) == identity,
               "SophonIdentity must ignore trailing bytes, not reject them")

        // A short structure and a foreign company ID are both refusals.
        assert(SophonIdentity(wire.prefix(7)) == nil)
        assert(SophonIdentity(Data([0xF1, 0x05]) + wire.dropFirst(2)) == nil,
               "manufacturer data from another company must not be parsed as ours")
    }
}
#endif
