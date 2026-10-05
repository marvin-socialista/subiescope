import Foundation

/// Subaru's 32-bit Denso ROMs keep a small table of checksums near the end of the flash. Each entry
/// covers a region of the ROM and holds the value that region's bytes must add up to. After you edit
/// a map, those sums no longer match, and an ECU that is flashed with a mismatched ROM rejects it.
/// Correcting the table is the last step of any edit.
///
/// This is a direct port of FastECU's `ChecksumEcuSubaruDensoSH7xxx` (GPLv3), which in turn matches
/// how the ECU itself checks the ROM. It covers the petrol SH7055 and SH7058 families, including the
/// SH7058S "subarucan" ROMs in the 2008+ STI. Diesel ROMs use a different table and are not handled
/// here yet.
public enum SubaruChecksum {
    /// The magic constant every Denso region sum is measured against: stored_diff == MAGIC - sum.
    static let magic: UInt32 = 0x5AA5A55A

    /// Where a ROM's checksum table lives and how it maps stored addresses to file positions.
    public struct Layout: Sendable, Equatable {
        /// File offset of the first 12-byte record.
        public let tableStart: Int
        /// How many 12-byte records the table holds (Subaru petrol ROMs use 17).
        public let recordCount: Int
        /// Added to each stored address to get a file index. 0 for the common petrol ROMs; some ROMs
        /// store absolute addresses that sit above the file and need a negative offset.
        public let addressOffset: Int

        public init(tableStart: Int, recordCount: Int = 17, addressOffset: Int = 0) {
            self.tableStart = tableStart
            self.recordCount = recordCount
            self.addressOffset = addressOffset
        }

        /// The standard petrol layout for a ROM of this size, or nil for sizes we don't have a table for.
        public static func petrol(for size: ROMImage.Size) -> Layout? {
            switch size {
            case .k512: return Layout(tableStart: 0x07FB80)   // SH7055, sti04
            case .m1: return Layout(tableStart: 0x0FFB80)     // SH7058 / SH7058S, sti05 and subarucan
            default: return nil                                // 1.5M/2M are diesel or Hitachi, handled elsewhere
            }
        }
    }

    /// What one checksum record says after we recompute it.
    public struct Record: Sendable, Equatable {
        public let index: Int
        /// Start address stored in the record (as written, before any offset).
        public let startAddress: UInt32
        public let endAddress: UInt32
        /// The value stored in the ROM for this region.
        public let stored: UInt32
        /// The value the region's bytes actually produce now.
        public let computed: UInt32
        /// A record that covers no region (both addresses zero) or is the "disabled" marker.
        public let isBlank: Bool
        public var matches: Bool { isBlank || stored == computed }
    }

    public struct Report: Sendable, Equatable {
        public let records: [Record]
        /// True when the whole table is the "all checksums disabled" marker, as some tuned ROMs ship.
        public let allDisabled: Bool
        /// True when every active record already matches.
        public var ok: Bool { allDisabled || records.allSatisfy { $0.matches } }
        public var mismatchCount: Int { records.filter { !$0.matches }.count }
    }

    enum ChecksumError: Error, LocalizedError {
        case tableOutOfRange
        var errorDescription: String? { "The checksum table does not fit in this ROM; the size or type is wrong." }
    }

    // MARK: Reading

    static func beWord(_ data: [UInt8], _ i: Int) -> UInt32 {
        UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
    }

    /// Looks at every record and reports what matches, without changing anything.
    public static func verify(_ rom: ROMImage, layout: Layout) throws -> Report {
        let data = rom.data
        let tableEnd = layout.tableStart + layout.recordCount * 12
        guard layout.tableStart >= 0, tableEnd <= data.count else { throw ChecksumError.tableOutOfRange }

        var records: [Record] = []
        var offset = layout.addressOffset
        var allDisabled = false

        for record in 0..<layout.recordCount {
            let base = layout.tableStart + record * 12
            let storedLo = beWord(data, base)
            let storedHi = beWord(data, base + 4)
            let storedDiff = beWord(data, base + 8)

            // A record with both addresses zero carries no region; from here on treat addresses as flat.
            if storedLo == 0 && storedHi == 0 { offset = 0 }

            let lo = UInt32(truncatingIfNeeded: Int(storedLo) + offset)
            let hi = UInt32(truncatingIfNeeded: Int(storedHi) + offset)

            // The whole-table "disabled" marker: first record, no region, and the magic in the diff slot.
            if record == 0 && lo == 0 && hi == 0 && storedDiff == Self.magic {
                allDisabled = true
            }

            let blank = (lo == 0 && hi == 0)
            var sum: UInt32 = 0
            if !blank && storedDiff != Self.magic {
                var j = Int(lo)
                let end = Int(hi)
                while j < end {
                    guard j >= 0, j + 4 <= data.count else { throw ChecksumError.tableOutOfRange }
                    sum = sum &+ beWord(data, j)
                    j += 4
                }
            }
            let computed = Self.magic &- sum

            records.append(Record(index: record, startAddress: storedLo, endAddress: storedHi,
                                  stored: storedDiff, computed: blank ? storedDiff : computed, isBlank: blank))
        }
        return Report(records: records, allDisabled: allDisabled)
    }

    /// Verifies against the standard petrol layout for the ROM's size. Nil layout when the size has no
    /// known petrol table.
    public static func verifyPetrol(_ rom: ROMImage) throws -> Report? {
        guard let size = rom.size, let layout = Layout.petrol(for: size) else { return nil }
        return try verify(rom, layout: layout)
    }

    // MARK: Correcting

    /// Writes the correct sums back into the table and returns the fixed ROM, with a report of what it
    /// changed. A ROM whose checksums are all disabled, or already correct, comes back unchanged.
    public static func correct(_ rom: ROMImage, layout: Layout) throws -> (rom: ROMImage, report: Report) {
        let report = try verify(rom, layout: layout)
        guard !report.allDisabled, report.mismatchCount > 0 else { return (rom, report) }

        var fixed = rom
        for record in report.records where !record.matches {
            let diffOffset = layout.tableStart + record.index * 12 + 8
            let value = record.computed
            fixed.replace(at: diffOffset, with: [
                UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
                UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF),
            ])
        }
        // Re-read so the returned report reflects the corrected ROM.
        return (fixed, try verify(fixed, layout: layout))
    }

    public static func correctPetrol(_ rom: ROMImage) throws -> (rom: ROMImage, report: Report)? {
        guard let size = rom.size, let layout = Layout.petrol(for: size) else { return nil }
        return try correct(rom, layout: layout)
    }
}
