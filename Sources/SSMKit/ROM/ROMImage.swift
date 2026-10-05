import Foundation

/// A Subaru ECU ROM file held in memory: the raw bytes plus what we can tell about them from the
/// bytes alone. This works only on a file; it never talks to a car. Opening and saving a ROM is the
/// "reading and editing" that is safe to do without any hardware.
///
/// Facts about where Subaru keeps its calibration ID and checksum tables come from FastECU
/// (GPLv3, `config/protocols.cfg` and its checksum modules) and RomRaider.
public struct ROMImage: Sendable, Equatable {
    /// The whole file, byte for byte. Edits happen here.
    public private(set) var data: [UInt8]

    public init(data: [UInt8]) {
        self.data = data
    }

    public init(contentsOf url: URL) throws {
        let raw = try Data(contentsOf: url)
        self.data = [UInt8](raw)
    }

    public func write(to url: URL) throws {
        try Data(data).write(to: url)
    }

    public var byteCount: Int { data.count }

    // MARK: Size

    /// The flash sizes Subaru 32-bit ECUs come in. A file that is not one of these is not a whole,
    /// untrimmed ROM, and the app says so rather than guessing.
    public enum Size: Int, Sendable, CaseIterable {
        case k512 = 0x080000
        case m1 = 0x100000
        case m1_5 = 0x180000
        case m2 = 0x200000

        public var label: String {
            switch self {
            case .k512: return "512 KB"
            case .m1: return "1 MB"
            case .m1_5: return "1.5 MB"
            case .m2: return "2 MB"
            }
        }
    }

    public var size: Size? { Size(rawValue: data.count) }

    // MARK: Identity

    /// Offsets where Subaru stores the 8-character calibration ID in a flat 32-bit ROM: 0x2000 on the
    /// older K-line Denso ROMs, 0x2004 on the CAN (SH7058S) ones. We read both and take the one that
    /// looks like a real ID.
    static let calibrationIDOffsets = [0x2000, 0x2004]
    static let calibrationIDLength = 8

    /// The calibration (CAL) ID printed in the ROM, e.g. "AF28A000". Nil when neither offset holds a
    /// clean ID, which means this is probably not a Subaru 32-bit ROM.
    public func calibrationID() -> String? {
        for offset in Self.calibrationIDOffsets {
            // A real CAL ID is a solid run of printable characters, so the field must have no gaps
            // (embedded NULs). That stops a half-empty slot yielding a truncated "AF28".
            guard let bytes = self.bytes(at: offset, length: Self.calibrationIDLength),
                  bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { continue }
            let id = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if Self.looksLikeID(id) { return id }
        }
        return nil
    }

    /// Reads `length` bytes at `offset` as ASCII, trimming trailing spaces and NULs. Nil when the
    /// range runs past the end of the file or holds a non-printable byte.
    public func asciiField(at offset: Int, length: Int) -> String? {
        guard offset >= 0, offset + length <= data.count else { return nil }
        let bytes = data[offset..<(offset + length)]
        guard bytes.allSatisfy({ $0 == 0x00 || (0x20...0x7E).contains($0) }) else { return nil }
        let text = String(decoding: bytes.filter { $0 != 0x00 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// A CAL ID is letters and digits, at least a few characters long.
    static func looksLikeID(_ text: String) -> Bool {
        text.count >= 4 && text.allSatisfy { $0.isLetter || $0.isNumber }
    }

    // MARK: Editing

    /// Replaces the bytes at `offset`. Returns false and changes nothing when the range would run
    /// past the end of the file, so an edit can never resize a ROM.
    @discardableResult
    public mutating func replace(at offset: Int, with bytes: [UInt8]) -> Bool {
        guard offset >= 0, offset + bytes.count <= data.count else { return false }
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        return true
    }

    public func bytes(at offset: Int, length: Int) -> [UInt8]? {
        guard offset >= 0, offset + length <= data.count else { return nil }
        return Array(data[offset..<(offset + length)])
    }

    /// A SHA-256-free, cheap fingerprint for telling two ROMs apart in the UI and in logs: sum of
    /// every byte, as hex. Not a security hash, just an at-a-glance "did this change".
    public var quickFingerprint: String {
        var sum: UInt32 = 0
        for byte in data { sum = sum &+ UInt32(byte) }
        return String(format: "%08X", sum)
    }
}
