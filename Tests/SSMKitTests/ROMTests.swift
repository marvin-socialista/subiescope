import Foundation
import Testing
@testable import SSMKit

/// A ROM editor works on a file, never on a car, so it can be tested end to end here: build a ROM in
/// memory, check how it is identified, break a checksum and correct it.
struct ROMTests {

    /// Writes a big-endian 32-bit value into a byte array.
    static func putBE(_ data: inout [UInt8], _ offset: Int, _ value: UInt32) {
        data[offset] = UInt8(value >> 24 & 0xFF)
        data[offset + 1] = UInt8(value >> 16 & 0xFF)
        data[offset + 2] = UInt8(value >> 8 & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    /// A 1 MB ROM (the SH7058 size) with one checksum region, so the petrol layout at 0x0FFB80 applies.
    static func makeROM(calID: String = "AF28A000") -> ROMImage {
        var data = [UInt8](repeating: 0, count: ROMImage.Size.m1.rawValue)
        // Some recognisable bytes in the region we will checksum.
        let regionStart = 0x1000
        let regionEnd = 0x1040
        for i in regionStart..<regionEnd { data[i] = UInt8((i * 7) & 0xFF) }

        // One real checksum record at the start of the table; the rest are "disabled" markers.
        let table = SubaruChecksum.Layout.petrol(for: .m1)!.tableStart
        putBE(&data, table, UInt32(regionStart))
        putBE(&data, table + 4, UInt32(regionEnd))
        putBE(&data, table + 8, correctDiff(data, regionStart, regionEnd))
        for record in 1..<17 {
            let base = table + record * 12
            putBE(&data, base + 8, SubaruChecksum.magic)   // disabled marker: addresses 0, diff = magic
        }

        // Calibration ID at the CAN offset.
        for (i, byte) in calID.utf8.enumerated() { data[0x2004 + i] = byte }
        return ROMImage(data: data)
    }

    static func correctDiff(_ data: [UInt8], _ start: Int, _ end: Int) -> UInt32 {
        var sum: UInt32 = 0
        var j = start
        while j < end { sum = sum &+ SubaruChecksum.beWord(data, j); j += 4 }
        return SubaruChecksum.magic &- sum
    }

    @Test func identifiesSizeAndCalID() {
        let rom = Self.makeROM(calID: "AF28A000")
        #expect(rom.size == .m1)
        #expect(rom.size?.label == "1 MB")
        #expect(rom.calibrationID() == "AF28A000")
    }

    @Test func rejectsNonROM() {
        let rom = ROMImage(data: [UInt8](repeating: 0xFF, count: 1234))
        #expect(rom.size == nil)
        #expect(rom.calibrationID() == nil)
    }

    @Test func freshROMchecksumsAreOK() throws {
        let report = try SubaruChecksum.verifyPetrol(Self.makeROM())
        #expect(report != nil)
        #expect(report!.ok)
        #expect(report!.mismatchCount == 0)
    }

    @Test func editingBreaksThenCorrectingFixesTheChecksum() throws {
        var rom = Self.makeROM()
        // Change a byte inside the checksummed region, as editing a map would.
        let original = rom.bytes(at: 0x1008, length: 1)!
        let edited = rom.replace(at: 0x1008, with: [original[0] &+ 1])
        #expect(edited)

        let broken = try SubaruChecksum.verifyPetrol(rom)!
        #expect(!broken.ok)
        #expect(broken.mismatchCount == 1)

        let (fixed, report) = try SubaruChecksum.correctPetrol(rom)!
        #expect(report.ok)
        #expect(report.mismatchCount == 0)
        // Only the checksum table changed, not the edited region.
        #expect(fixed.bytes(at: 0x1008, length: 1) == [original[0] &+ 1])
        #expect(try SubaruChecksum.verifyPetrol(fixed)!.ok)
    }

    @Test func correctingAnOKromChangesNothing() throws {
        let rom = Self.makeROM()
        let (same, report) = try SubaruChecksum.correctPetrol(rom)!
        #expect(report.ok)
        #expect(same == rom)
    }

    @Test func allDisabledIsReportedAndLeftAlone() throws {
        var data = [UInt8](repeating: 0, count: ROMImage.Size.m1.rawValue)
        let table = SubaruChecksum.Layout.petrol(for: .m1)!.tableStart
        // First record is the whole-table disabled marker.
        Self.putBE(&data, table + 8, SubaruChecksum.magic)
        let rom = ROMImage(data: data)
        let report = try SubaruChecksum.verifyPetrol(rom)!
        #expect(report.allDisabled)
        #expect(report.ok)
        let (same, _) = try SubaruChecksum.correctPetrol(rom)!
        #expect(same == rom)
    }

    @Test func replaceCannotResizeOrOverrun() {
        var rom = ROMImage(data: [1, 2, 3, 4])
        let overran = rom.replace(at: 2, with: [9, 9, 9])   // would run past the end
        #expect(!overran)
        #expect(rom.data == [1, 2, 3, 4])
        let ok = rom.replace(at: 2, with: [9, 9])
        #expect(ok)
        #expect(rom.data == [1, 2, 9, 9])
    }

    @Test func disclaimerSaysItNeverWritesToTheCar() {
        #expect(ROMDisclaimer.full.contains("never erases or writes the ECU's program"))
        #expect(ROMDisclaimer.full.contains("not been tested on a real car"))
        #expect(ROMDisclaimer.noWriteToCar.contains("never writes to the car"))
    }
}
