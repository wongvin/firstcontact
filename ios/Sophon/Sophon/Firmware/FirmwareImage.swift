import CryptoKit
import Foundation

/// A signed MCUboot application image, as `scripts/airdrop-fw.sh` sends it (#357).
///
/// Parsed here, bounds-checked, rather than with the SMP library's own
/// `McuMgrImage`: that one reads the header without checking the length, so a
/// short or foreign file AirDropped to the phone would trap the app instead of
/// being refused.
///
/// The SHA-256 TLV is also checked against the bytes, which MCUboot would do
/// only after the whole upload: a file damaged on the way is refused before a
/// minute is spent sending it.
nonisolated struct FirmwareImage: Sendable {
    /// `ih_ver` without the build number, which Sophon leaves at 0.
    struct Version: Comparable, Hashable, Sendable, CustomStringConvertible {
        let major: UInt8
        let minor: UInt8
        let revision: UInt16

        var description: String { "\(major).\(minor).\(revision)" }

        static func < (lhs: Version, rhs: Version) -> Bool {
            (lhs.major, lhs.minor, lhs.revision) < (rhs.major, rhs.minor, rhs.revision)
        }

        /// Newer than a board that advertises `major.minor` (#346's identity
        /// carries no patch level, so an equal minor is not newer).
        func isNewer(thanMajor boardMajor: UInt8, minor boardMinor: UInt8) -> Bool {
            (major, minor) > (boardMajor, boardMinor)
        }
    }

    enum ParseError: LocalizedError {
        case notMCUboot, truncated, noHash, hashMismatch

        var errorDescription: String? {
            switch self {
            case .notMCUboot: "This file isn't a signed Sophon firmware image."
            case .truncated: "This firmware image is incomplete."
            case .noHash: "This firmware image has no SHA-256 record."
            case .hashMismatch: "This firmware image is damaged: its contents don't match its hash."
            }
        }
    }

    let version: Version
    /// The SHA-256 TLV, which is also how SMP names the image in a slot.
    let hash: Data
    let data: Data

    // MCUboot's image.h: header magic, and the two TLV area magics.
    private static let headerMagic: UInt32 = 0x96F3_B83D
    private static let tlvInfoMagic: UInt16 = 0x6907
    private static let protectedTLVInfoMagic: UInt16 = 0x6908
    private static let sha256TLV: UInt16 = 0x10

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }

        // struct image_header is 32 bytes.
        guard bytes.count >= 32 else { throw ParseError.notMCUboot }
        guard u32(0) == Self.headerMagic else { throw ParseError.notMCUboot }
        let headerSize = Int(u16(8))
        let protectedSize = Int(u16(10))
        let imageSize = Int(u32(12))
        version = Version(major: bytes[20], minor: bytes[21], revision: u16(22))

        // The hash covers header, image and the protected TLV area; the
        // unprotected area that holds it follows.
        let hashed = headerSize + imageSize + protectedSize
        var offset = headerSize + imageSize
        if protectedSize > 0 {
            guard offset + 4 <= bytes.count, u16(offset) == Self.protectedTLVInfoMagic else {
                throw ParseError.truncated
            }
            offset += protectedSize
        }
        guard offset + 4 <= bytes.count, u16(offset) == Self.tlvInfoMagic else { throw ParseError.truncated }
        let end = offset + Int(u16(offset + 2))
        guard end <= bytes.count else { throw ParseError.truncated }

        var found: Data?
        var cursor = offset + 4
        while cursor + 4 <= end {
            let type = u16(cursor)
            let length = Int(u16(cursor + 2))
            guard cursor + 4 + length <= end else { throw ParseError.truncated }
            if type == Self.sha256TLV, length == 32 { found = Data(bytes[(cursor + 4)..<(cursor + 36)]) }
            cursor += 4 + length
        }
        guard let found else { throw ParseError.noHash }
        guard Data(SHA256.hash(data: data.prefix(hashed))) == found else { throw ParseError.hashMismatch }

        hash = found
        self.data = data
    }
}

#if DEBUG
extension SophonProtocolSelfCheck {
    /// A minimal image built to MCUboot's layout: 32-byte header (version
    /// 2.32.7), 16 bytes of body, and an unprotected TLV area holding the hash.
    nonisolated static func checkFirmwareImage() {
        var header = Data(count: 32)
        header.replaceSubrange(0..<4, with: [0x3D, 0xB8, 0xF3, 0x96]) // magic
        header[8] = 32                                                // hdr size
        header[12] = 16                                               // img size
        header[20] = 2; header[21] = 32; header[22] = 7               // 2.32.7
        let body = Data((0..<16).map { UInt8($0) })
        let hash = Data(SHA256.hash(data: header + body))
        let tlv = Data([0x07, 0x69, 40, 0, 0x10, 0x00, 32, 0]) + hash
        let image = header + body + tlv

        guard let parsed = try? FirmwareImage(image) else {
            assertionFailure("FirmwareImage rejected a valid image")
            return
        }
        assert(parsed.version.description == "2.32.7", "version misread")
        assert(parsed.hash == hash, "hash TLV misread")
        assert(parsed.version.isNewer(thanMajor: 2, minor: 31), "2.32 is newer than 2.31")
        assert(!parsed.version.isNewer(thanMajor: 2, minor: 32), "an equal minor is not newer")
        assert((try? FirmwareImage(image.prefix(40))) == nil, "a truncated image must be rejected")
        assert((try? FirmwareImage(Data(count: 8))) == nil, "a short file must be rejected, not trap")
        var damaged = image
        damaged[40] ^= 0xFF
        assert((try? FirmwareImage(damaged)) == nil, "a damaged body must fail its hash")
        var foreign = image
        foreign[0] = 0
        assert((try? FirmwareImage(foreign)) == nil, "a file without the magic must be rejected")
    }
}
#endif
