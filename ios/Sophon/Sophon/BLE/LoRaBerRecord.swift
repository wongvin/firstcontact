import CoreBluetooth
import Foundation

/// One window of the bit-error test (#359), from the LoRa BER characteristic.
///
/// A board in the transporter role sends its own running image over LoRa with
/// the payload CRC off; the gateway compares every bit with its own copy. Mirrors
/// `gateway_build_ber_record()` in `zephyr/sophon/src/lora_link.c` and
/// PROTOCOL.md § LoRa BER frame: 20 bytes, version 1. The gateway builds it just
/// before the window's LoRa Link record, with the same `window` number.
nonisolated struct LoRaBerRecord: Equatable, Sendable {
    static let wireSize = 20
    static let supportedVersion: UInt8 = 1
    /// Where `unresolved` and `repaired` saturate: a 255 means 255 or more.
    static let countCeiling: UInt8 = 255

    let preset: UInt8
    let windowSeconds: UInt8
    /// The transporter the gateway hears: the XXXX of its Sophon-XXXX; 0 if none.
    /// Confirmed by a packet whose header check passed, or, with
    /// `transporterUnverified`, only named by headers that never passed, as
    /// when the two boards run different images (#359 review, finding 1).
    let transporterID: UInt16
    /// The same counter as the LoRa Link record's.
    let window: UInt16
    /// Packets compared: header good, or repaired.
    let packets: UInt16
    /// Of those, packets with at least one bit wrong.
    let damaged: UInt16
    /// Packets the transporter sent that never arrived.
    let lost: UInt16
    /// Bits wrong, over every bit of every packet compared, header included.
    let bitErrors: UInt32
    /// The packet length, PL: bits compared = packets × 8 × PL.
    let packetLength: UInt8
    /// Heard but not compared: the header couldn't be recovered.
    let unresolved: UInt8
    /// Of `packets`, those whose header failed its check and was recovered.
    let repaired: UInt8
    /// Any transporter packet arrived this window.
    let heard: Bool
    /// Nearly every packet unresolved at a good SNR: the two boards almost
    /// certainly run different images.
    let mismatchSuspected: Bool
    /// The gateway read its own image, so it can compare at all.
    let canCompare: Bool
    /// `transporterID` comes from packet headers that haven't passed their
    /// check: enough to find the board and check its image, not a confirmation.
    let transporterUnverified: Bool

    init?(_ data: Data) {
        guard data.count == Self.wireSize else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == Self.supportedVersion else { return nil }

        func u16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8) }

        guard LoRaLinkRecord.windowRange.contains(bytes[1] >> 4) else { return nil }
        preset = bytes[1] & 0x0F
        windowSeconds = bytes[1] >> 4
        transporterID = u16(2)
        window = u16(4)
        packets = u16(6)
        damaged = u16(8)
        lost = u16(10)
        bitErrors = UInt32(u16(12)) | (UInt32(u16(14)) << 16)
        packetLength = bytes[16]
        unresolved = bytes[17]
        heard = bytes[18] & 0x01 != 0
        mismatchSuspected = bytes[18] & 0x02 != 0
        canCompare = bytes[18] & 0x04 != 0
        transporterUnverified = bytes[18] & 0x08 != 0
        repaired = bytes[19]
    }

    /// Every bit compared this window.
    var bitsCompared: Int { Int(packets) * 8 * Int(packetLength) }

    /// Bit error rate as a percentage, or nil when nothing was compared.
    var berPercent: Double? { Self.percent(Int(bitErrors), of: bitsCompared) }

    /// Packets with at least one bit wrong, as a percentage of those compared.
    var damagedPercent: Double? { Self.percent(Int(damaged), of: Int(packets)) }

    /// Packets that never arrived, as a percentage of all the transporter sent
    /// that the gateway could account for.
    var lostPercent: Double? { Self.percent(Int(lost), of: Int(packets) + Int(lost) + Int(unresolved)) }

    static func percent(_ part: Int, of whole: Int) -> Double? {
        whole > 0 ? Double(part) * 100 / Double(whole) : nil
    }

    var transporterName: String? {
        transporterID == 0 ? nil : String(format: "Sophon-%04X", transporterID)
    }
}

extension SophonProtocol {
    /// The bit-error test's record, served by a LoRa gateway (#359). Present on
    /// every board from 2.33.0; a read off-gateway returns zero bytes.
    nonisolated static let loraBerCharacteristicUUID = CBUUID(string: "C6560008-84D5-4DC2-8C1E-4B4EB2337CE4")
}

#if DEBUG
extension SophonProtocolSelfCheck {
    nonisolated static func checkLoRaBer() {
        // Hand-transcribed from PROTOCOL.md § LoRa BER frame (version 1).
        let wire = Data([
            0x01,                   // version 1                     @0
            0xA7,                   // preset V6 (7), window 10 s    @1
            0x2B, 0x1A,             // transporter 0x1A2B            @2
            0x2A, 0x01,             // window 298                    @4
            0x87, 0x00,             // packets 135                   @6
            0x03, 0x00,             // damaged 3                     @8
            0x02, 0x00,             // lost 2                        @10
            0x0E, 0x00, 0x00, 0x00, // bit errors 14                 @12
            0x3C,                   // packet length 60              @16
            0x00,                   // unresolved 0                  @17
            0x05,                   // heard, can compare            @18
            0x01,                   // repaired 1                    @19
        ])
        guard let record = LoRaBerRecord(wire) else {
            assertionFailure("LoRaBerRecord rejected a valid 20-byte record")
            return
        }
        assert(record.preset == 7 && record.windowSeconds == 10, "byte 1 misread")
        assert(record.transporterID == 0x1A2B && record.transporterName == "Sophon-1A2B", "transporter byte-swapped")
        assert(record.window == 298, "window byte-swapped")
        assert(record.packets == 135 && record.damaged == 3 && record.lost == 2, "packet counts misread")
        assert(record.bitErrors == 14 && record.packetLength == 60, "bit errors or length misread")
        assert(record.unresolved == 0 && record.repaired == 1, "unresolved / repaired swapped")
        assert(record.heard && !record.mismatchSuspected && record.canCompare, "flags misread")
        assert(record.bitsCompared == 64_800, "bits compared is packets × 8 × PL")
        assert(abs((record.berPercent ?? 0) - 0.021_604_9) < 1e-6, "BER is bit errors ÷ bits compared")
        assert(abs((record.damagedPercent ?? 0) - 2.222_2) < 1e-3, "damaged is damaged ÷ packets")
        var big = wire
        big[12] = 0x01; big[13] = 0x02; big[14] = 0x03; big[15] = 0x04
        assert(LoRaBerRecord(big)?.bitErrors == 0x0403_0201, "bit errors is a little-endian u32")
        var mismatch = wire
        mismatch[18] = 0x07
        assert(LoRaBerRecord(mismatch)?.mismatchSuspected == true, "mismatch is bit 1")
        assert(record.transporterUnverified == false, "bit 3 clear: the id is confirmed")
        var claimed = wire
        claimed[18] = 0x0F
        assert(LoRaBerRecord(claimed)?.transporterUnverified == true, "unverified is bit 3")
        assert(LoRaBerRecord(claimed)?.transporterName == "Sophon-1A2B", "an unverified id still names the board")
        var none = wire
        none[6] = 0; none[7] = 0
        assert(LoRaBerRecord(none)?.berPercent == nil, "nothing compared is no figure, not 0 %")
        assert(LoRaBerRecord(wire.dropLast()) == nil, "short record must be rejected")
        assert(LoRaBerRecord(wire + Data([0])) == nil, "long record must be rejected")
        var v2 = wire
        v2[0] = 0x02
        assert(LoRaBerRecord(v2) == nil, "an unknown version must be dropped")
    }
}
#endif
