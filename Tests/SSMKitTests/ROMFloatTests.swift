import Foundation
import Testing
@testable import SSMKit

/// Float maps in a ROM. RomRaider's Subaru definitions mark nearly every float table
/// `endian="little"`, on processors that are big-endian. RomRaider itself reads those floats
/// big-endian all the same (it calls the attribute "improperly defined ... in legacy definition
/// files"), and so does FastECU. Taken at its word, the attribute turns every float map into noise.
struct ROMFloatTests {

    // The shapes RomRaider's file has: a float map with float axes, all marked "little"; the one
    // float table that is marked "big"; and a table of whole numbers that really is little-endian.
    static let defsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <roms>
      <rom>
        <romid><xmlid>FLOATBASE</xmlid></romid>
        <table name="Airflow Map" type="3D" storagetype="float" endian="little" sizex="2" sizey="2" category="Fuel">
          <scaling units="g/s" expression="x" to_byte="x" format="0.00"/>
          <table type="X Axis" name="Load" storagetype="float" endian="little" sizex="2">
            <scaling units="g/rev" expression="x" to_byte="x" format="0.00"/>
          </table>
          <table type="Y Axis" name="Engine Speed" storagetype="float" endian="little" sizey="2">
            <scaling units="RPM" expression="x" to_byte="x" format="0"/>
          </table>
        </table>
        <table name="Marked Big" type="2D" storagetype="float" endian="big" sizex="2" category="Fuel">
          <scaling units="deg" expression="x*2" to_byte="x/2" format="0.0"/>
        </table>
        <table name="Words" type="2D" storagetype="uint16" endian="little" sizex="2" category="Misc">
          <scaling units="raw" expression="x" to_byte="x" format="0"/>
        </table>
      </rom>

      <rom base="FLOATBASE">
        <romid>
          <xmlid>FLOATROM1</xmlid>
          <internalidaddress>2000</internalidaddress>
          <internalidstring>FLOATROM1</internalidstring>
          <memmodel>SH7058</memmodel>
        </romid>
        <table name="Airflow Map" address="4000">
          <table type="X Axis" address="4100"/>
          <table type="Y Axis" address="4200"/>
        </table>
        <table name="Marked Big" address="4300"/>
        <table name="Words" address="4400"/>
      </rom>

      <rom base="FLOATBASE">
        <romid>
          <xmlid>FLOATROM2</xmlid>
          <internalidaddress>2000</internalidaddress>
          <internalidstring>FLOATROM2</internalidstring>
          <memmodel endian="little">MADEUP</memmodel>
        </romid>
        <table name="Airflow Map" address="4000">
          <table type="X Axis" address="4100"/>
          <table type="Y Axis" address="4200"/>
        </table>
      </rom>
    </roms>
    """

    static func put(_ d: inout [UInt8], _ offset: Int, _ values: [Float], bigEndian: Bool) {
        for (i, value) in values.enumerated() {
            let bits = value.bitPattern
            var bytes = [UInt8(bits >> 24 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
            if !bigEndian { bytes.reverse() }
            for (j, byte) in bytes.enumerated() { d[offset + i * 4 + j] = byte }
        }
    }

    /// A ROM with its floats in the given order, as the processor would store them.
    static func makeROM(id: String, floatsBigEndian: Bool) -> ROMImage {
        var d = [UInt8](repeating: 0, count: 0x100000)
        for (i, b) in id.utf8.enumerated() { d[0x2000 + i] = b }
        put(&d, 0x4000, [1.5, 2.25, 3.0, 100.0], bigEndian: floatsBigEndian)   // Airflow Map, 2 x 2
        put(&d, 0x4100, [0.5, 1.0], bigEndian: floatsBigEndian)                // Load axis
        put(&d, 0x4200, [800, 6400], bigEndian: floatsBigEndian)               // Engine Speed axis
        put(&d, 0x4300, [10, -4.5], bigEndian: floatsBigEndian)                // Marked Big
        d[0x4400] = 0x34; d[0x4401] = 0x12; d[0x4402] = 0x78; d[0x4403] = 0x56   // Words, little-endian
        return ROMImage(data: d)
    }

    static func table(_ name: String, in xmlID: String, rom: ROMImage) throws -> ROMTable {
        let set = try ROMDefinitionParser.load(data: Data(defsXML.utf8))
        let def = try #require(set.resolvedTables(forXmlID: xmlID).first { $0.name == name })
        return try ROMTable.read(rom, def: def, scalings: set.scalings)
    }

    @Test func floatsMarkedLittleAreReadBigEndian() throws {
        let table = try Self.table("Airflow Map", in: "FLOATROM1", rom: Self.makeROM(id: "FLOATROM1", floatsBigEndian: true))
        #expect(table.values == [[1.5, 2.25], [3.0, 100.0]])
        #expect(table.xLabels == [0.5, 1.0])
        #expect(table.yLabels == [800, 6400])
    }

    @Test func aFloatMarkedBigIsReadBigEndianToo() throws {
        let table = try Self.table("Marked Big", in: "FLOATROM1", rom: Self.makeROM(id: "FLOATROM1", floatsBigEndian: true))
        #expect(table.values == [[20, -9]])
    }

    @Test func wholeNumbersKeepTheOrderTheDefinitionGives() throws {
        let table = try Self.table("Words", in: "FLOATROM1", rom: Self.makeROM(id: "FLOATROM1", floatsBigEndian: true))
        #expect(table.values == [[Double(0x1234), Double(0x5678)]])
    }

    @Test func writingAFloatPutsItBackBigEndian() throws {
        let rom = Self.makeROM(id: "FLOATROM1", floatsBigEndian: true)
        let table = try Self.table("Airflow Map", in: "FLOATROM1", rom: rom)
        let edited = try table.write(rom, row: 1, column: 0, realValue: 12.5)
        // 12.5 as a float is 41 48 00 00, most significant byte first.
        #expect(edited.bytes(at: 0x4000 + 2 * 4, length: 4).map(Array.init) == [0x41, 0x48, 0x00, 0x00])
        let reread = try Self.table("Airflow Map", in: "FLOATROM1", rom: edited)
        #expect(reread.values == [[1.5, 2.25], [12.5, 100.0]])
        // Nothing else in the ROM has moved.
        #expect(zip(rom.data, edited.data).filter { $0 != $1 }.count == 2)
    }

    /// RomRaider's newer definitions can state the processor's byte order. Floats follow that.
    @Test func aDefinitionThatStatesALittleEndianProcessorIsBelieved() throws {
        let set = try ROMDefinitionParser.load(data: Data(Self.defsXML.utf8))
        #expect(set.definitions["FLOATROM1"]?.identity.memModelBigEndian == nil)
        #expect(set.definitions["FLOATROM2"]?.identity.memModelBigEndian == false)
        let table = try Self.table("Airflow Map", in: "FLOATROM2", rom: Self.makeROM(id: "FLOATROM2", floatsBigEndian: false))
        #expect(table.values == [[1.5, 2.25], [3.0, 100.0]])
        #expect(table.xLabels == [0.5, 1.0])
        #expect(table.yLabels == [800, 6400])
    }

    /// The real file: after resolving, no float table or axis of any Subaru ROM is left little-endian.
    @Test func everyFloatInRomRaidersDefinitionsIsBigEndian() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("definitions/ecu_defs.xml")
        guard let data = try? Data(contentsOf: file) else { return }   // not there: nothing to check
        let set = try ROMDefinitionParser.load(data: data)
        var floatTables = 0, floatAxes = 0
        for id in set.definitions.keys {
            for table in set.resolvedTables(forXmlID: id) {
                if table.storageType == .float {
                    floatTables += 1
                    #expect(table.bigEndian, "\(id): \(table.name)")
                }
                for axis in [table.xAxis, table.yAxis].compactMap({ $0 }) where axis.storageType == .float {
                    floatAxes += 1
                    #expect(axis.bigEndian, "\(id): \(table.name), axis \(axis.name)")
                }
            }
        }
        // The file is full of them: a count of zero would mean this test looked at nothing.
        #expect(floatTables > 1000)
        #expect(floatAxes > 1000)
    }
}
