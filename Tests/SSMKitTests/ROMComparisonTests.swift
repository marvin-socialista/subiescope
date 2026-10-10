import Foundation
import Testing
@testable import SSMKit

/// Comparing two ROMs: what changed since a ROM was opened, and how a ROM differs from another file.
/// Both are the same comparison, tested here on the hand-built ROM and definition of
/// `ROMDefinitionTests`, where every map's place and scaling is known.
struct ROMComparisonTests {

    static func tables() throws -> (tables: [ROMTableDef], scalings: [String: ROMScaling]) {
        let set = try ROMDefinitionTests.load()
        return (set.resolvedTables(forXmlID: "TESTROM1"), set.scalings)
    }

    static func compare(_ first: ROMImage, _ second: ROMImage) throws -> ROMComparison {
        let (tables, scalings) = try tables()
        return try ROMComparison(first, second, tables: tables, scalings: scalings)
    }

    @Test func aROMIsTheSameAsItself() throws {
        let rom = ROMDefinitionTests.makeROM()
        let same = try Self.compare(rom, ROMImage(data: rom.data))
        #expect(same.isIdentical)
        #expect(same.maps.isEmpty)
        #expect(same.differingBytes == 0 && same.bytesOutsideMaps == 0)
        #expect(same.otherBytesText == nil)
        #expect(same.otherCalibrationText == nil)
    }

    @Test func findsExactlyTheChangedCells() throws {
        let opened = ROMDefinitionTests.makeROM()
        var now = try ROMEditHistoryTests.editing(opened, "Primary Fuel", row: 1, column: 2, to: 33)
        now = try ROMEditHistoryTests.editing(now, "Primary Fuel", row: 0, column: 0, to: 6)
        now = try ROMEditHistoryTests.editing(now, "Target Boost", row: 0, column: 0, to: -1.23)

        let changes = try Self.compare(opened, now)
        // In the order of the definition's tables: by category, then by name.
        #expect(changes.maps.map(\.name) == ["Target Boost", "Primary Fuel"])
        let fuel = changes.maps[1]
        #expect(fuel.cells == [
            .init(row: 0, column: 0, first: 5, second: 6),
            .init(row: 1, column: 2, first: 30, second: 33),
        ])
        #expect(fuel.rows == 2 && fuel.columns == 3)
        #expect(fuel.xAxis == nil && fuel.yAxis == nil)
        let boost = changes.maps[0]
        #expect(boost.cells.count == 1)
        #expect(boost.cells[0].row == 0 && boost.cells[0].column == 0)
        #expect(boost.cells[0].first == -0.5)
        #expect(abs(boost.cells[0].second - -1.23) < 0.0001)
        // Two bytes of fuel, and the low byte of the boost cell: -50 and -123 share their high byte.
        #expect(changes.differingBytes == 3)
        #expect(changes.bytesOutsideMaps == 0)
        #expect(changes.otherBytesText == nil)
    }

    @Test func aCellOfSeveralBytesIsOneCell() throws {
        let opened = ROMDefinitionTests.makeROM()
        let now = try ROMEditHistoryTests.editing(opened, "LE Test", row: 0, column: 1, to: Double(0x4321))
        let changes = try Self.compare(opened, now)
        #expect(changes.maps.map(\.name) == ["LE Test"])
        #expect(changes.maps[0].cells == [.init(row: 0, column: 1, first: Double(0x5678), second: Double(0x4321))])
        #expect(changes.differingBytes == 2)
    }

    @Test func bytesOutsideEveryMapAreCounted() throws {
        let opened = ROMDefinitionTests.makeROM()
        var now = try ROMEditHistoryTests.editing(opened, "Rev Limit", row: 0, column: 0, to: 7000)
        now.replace(at: 0x9000, with: [1, 2, 3])
        now.replace(at: 0x9010, with: [4])
        // The byte right after Primary Fuel's six cells belongs to no map.
        now.replace(at: 0x3006, with: [0xAA])

        let changes = try Self.compare(opened, now)
        #expect(changes.maps.map(\.name) == ["Rev Limit"])
        #expect(changes.maps[0].cells == [.init(row: 0, column: 0, first: 7200, second: 7000)])
        #expect(changes.bytesOutsideMaps == 5)
        #expect(changes.differingBytes == 5 + 2)   // 7200 and 7000 differ in both of their bytes
        #expect(changes.checksumBytes == 0)
        #expect(changes.otherBytesText == "5 more bytes are different in places the definitions have no map for.")
    }

    @Test func withoutADefinitionEveryByteIsOutside() throws {
        let opened = ROMDefinitionTests.makeROM()
        let now = try ROMEditHistoryTests.editing(opened, "Primary Fuel", row: 1, column: 2, to: 33)
        let changes = try ROMComparison(opened, now)
        #expect(!changes.mapsKnown)
        #expect(changes.maps.isEmpty)
        #expect(changes.differingBytes == 1 && changes.bytesOutsideMaps == 1)
        #expect(changes.otherBytesText == "1 byte is different. With definitions that match this ROM, SubieScope can tell which maps they are in.")
    }

    @Test func aChangedAxisBelongsToItsMap() throws {
        let opened = ROMDefinitionTests.makeROM()
        var now = opened
        now.replace(at: 0x3102, with: [0x08, 0x98])   // the fuel map's second RPM label: 2000 becomes 2200
        let changes = try Self.compare(opened, now)
        #expect(changes.maps.map(\.name) == ["Primary Fuel"])
        let fuel = changes.maps[0]
        #expect(fuel.cells.isEmpty)
        #expect(fuel.xAxis?.name == "RPM axis")
        #expect(fuel.xAxis?.labels == [.init(index: 1, first: 2000, second: 2200)])
        #expect(fuel.yAxis == nil)   // its labels are in the definition, not in the ROM
        #expect(fuel.summary == "1 axis value")
        #expect(fuel.lines == [.init(place: "RPM axis, value 2", first: "2000", second: "2200", units: "RPM")])
        #expect(changes.bytesOutsideMaps == 0)
    }

    @Test func correctedChecksumsAreToldApart() throws {
        let opened = ROMTests.makeROM()
        var edited = opened
        edited.replace(at: 0x1008, with: [0x55])
        let fixed = try #require(try SubaruChecksum.correctPetrol(edited)).rom
        let changes = try ROMComparison(opened, fixed)
        #expect(changes.checksumBytes >= 1)
        #expect(changes.bytesOutsideMaps == changes.checksumBytes + 1)

        // With nothing but the checksums changed, that is all there is to say.
        let onlySums = try ROMComparison(edited, fixed)
        #expect(onlySums.checksumBytes == onlySums.differingBytes)
        #expect(onlySums.otherBytesText?.hasSuffix("in the checksums.") == true)
    }

    @Test func differentSizesAreRefused() throws {
        let rom = ROMDefinitionTests.makeROM()
        let small = ROMImage(data: [UInt8](repeating: 0, count: ROMImage.Size.k512.rawValue))
        #expect(throws: ROMComparison.CompareError.differentSizes(first: 0x100000, second: 0x080000)) {
            _ = try Self.compare(rom, small)
        }
        // What a person reads is a whole sentence with both sizes in it.
        let message = ROMComparison.CompareError.differentSizes(first: 0x100000, second: 0x080000).localizedDescription
        #expect(message.contains("1048576") && message.contains("524288"))
        #expect(message.contains("can't be compared"))
    }

    @Test func anotherCalibrationIsPointedOut() throws {
        let rom = ROMDefinitionTests.makeROM()
        var data = rom.data
        for (i, byte) in "OTHER999".utf8.enumerated() { data[0x2000 + i] = byte }
        let other = try Self.compare(rom, ROMImage(data: data))
        #expect(other.firstCalibrationID == "TESTROM1" && other.secondCalibrationID == "OTHER999")
        #expect(other.otherCalibrationText?.contains("OTHER999") == true)
    }

    @Test func differencesInWords() throws {
        let opened = ROMDefinitionTests.makeROM()
        var now = try ROMEditHistoryTests.editing(opened, "Primary Fuel", row: 1, column: 2, to: 33)
        now = try ROMEditHistoryTests.editing(now, "Primary Fuel", row: 0, column: 1, to: 12)
        now = try ROMEditHistoryTests.editing(now, "Target Boost", row: 0, column: 3, to: 1.5)
        now = try ROMEditHistoryTests.editing(now, "Rev Limit", row: 0, column: 0, to: 7000)
        let changes = try Self.compare(opened, now)
        let byName = Dictionary(uniqueKeysWithValues: changes.maps.map { ($0.name, $0) })

        // A map with rows and columns, a map of one row, and a single number.
        let fuel = try #require(byName["Primary Fuel"])
        #expect(fuel.summary == "2 cells")
        #expect(fuel.lines == [
            .init(place: "Row 1, column 2", first: "10.00", second: "12.00", units: "ms"),
            .init(place: "Row 2, column 3", first: "30.00", second: "33.00", units: "ms"),
        ])
        let boost = try #require(byName["Target Boost"])
        #expect(boost.summary == "1 cell")
        #expect(boost.lines == [.init(place: "Column 4", first: "2.00", second: "1.50", units: "bar")])
        let limit = try #require(byName["Rev Limit"])
        #expect(limit.lines == [.init(place: "Value", first: "7200", second: "7000", units: "RPM")])
    }

    @Test func undoingEveryEditLeavesNoChanges() throws {
        let opened = ROMDefinitionTests.makeROM()
        var history = ROMEditHistory()
        let one = try ROMEditHistoryTests.editing(opened, "Primary Fuel", row: 1, column: 2, to: 33)
        history.record("one", from: opened, to: one)
        let two = try ROMEditHistoryTests.editing(one, "Rev Limit", row: 0, column: 0, to: 7000)
        history.record("two", from: one, to: two)
        #expect(try Self.compare(opened, two).maps.count == 2)

        let undone = history.undo(two)
        let back = try #require(undone)
        #expect(try Self.compare(opened, back).maps.map(\.name) == ["Primary Fuel"])
        let undoneAgain = history.undo(back)
        let start = try #require(undoneAgain)
        #expect(try Self.compare(opened, start).isIdentical)
    }

    /// The comparison works out where a map's numbers are before it reads the map. That has to be the
    /// same place `ROMTable.read` reads them from, for every shape of table, or a cell that changed
    /// would be counted as a byte outside the maps.
    @Test func aMapIsLookedForWhereItIsReadFrom() throws {
        let rom = ROMDefinitionTests.makeROM()
        let (tables, scalings) = try Self.tables()
        // The float tables add a map with both of its axes in the ROM. They bring their own scalings.
        let floats = try ROMDefinitionParser.load(data: Data(ROMFloatTests.defsXML.utf8))
        for def in tables + floats.resolvedTables(forXmlID: "FLOATROM1") {
            let table = try ROMTable.read(rom, def: def, scalings: scalings)
            let address = try #require(def.address)
            let storage = try #require(def.storageType)
            #expect(def.storedRanges.first == address..<(address + table.rows * table.columns * storage.byteCount), "\(def.name)")
            // An axis kept in the ROM has a range of its own; one kept in the definition has none.
            let axesInROM = [def.columnAxis, def.rowAxis].filter { $0?.address != nil && $0?.staticValues == nil }.count
            #expect(def.storedRanges.count == 1 + axesInROM, "\(def.name)")
        }
    }
}
