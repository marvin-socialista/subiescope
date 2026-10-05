import Foundation
import Testing
@testable import SSMKit

/// QA for reading and editing ROM maps from a RomRaider definition. A ROM editor works on files, so
/// the whole path (parse a definition, match a ROM, resolve base inheritance, read a scaled table,
/// write a value back) is tested here against a hand-built definition and ROM, with no hardware.
struct ROMDefinitionTests {

    // A RomRaider-style ecu_defs.xml: shared scalings, a base ROM with the full table layout, and a
    // concrete ROM that supplies only its identity and the real addresses, inheriting the rest.
    static let defsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <roms>
      <scaling name="InjectorPulse" units="ms" expression="x*0.5" to_byte="x/0.5" format="0.00"/>
      <scaling name="RPMScale" units="RPM" expression="x" to_byte="x" format="0"/>
      <scaling name="BoostScale" units="bar" expression="x*0.01" to_byte="x/0.01" format="0.00"/>
      <scaling name="Locked" units="mode" expression="x" to_byte=" " format="0"/>

      <rom>
        <romid><xmlid>32BITBASE</xmlid></romid>
        <table name="Primary Fuel" type="3D" storagetype="uint8" sizex="3" sizey="2" category="Fuel">
          <scaling name="InjectorPulse"/>
          <table type="X Axis" name="RPM" storagetype="uint16" sizex="3"><scaling name="RPMScale"/></table>
          <table type="Static Y Axis" name="Load" sizey="2"><data>0.5</data><data>1.0</data></table>
        </table>
        <table name="Target Boost" type="2D" storagetype="int16" sizex="4" category="Boost">
          <scaling name="BoostScale"/>
          <table type="X Axis" name="RPM2" storagetype="uint16" sizex="4"><scaling name="RPMScale"/></table>
        </table>
        <table name="Rev Limit" type="1D" storagetype="uint16" category="Limits">
          <scaling name="RPMScale"/>
        </table>
        <table name="LE Test" type="2D" storagetype="uint16" endian="little" sizex="2" category="Misc">
          <scaling units="raw" expression="x" to_byte="x" format="0"/>
        </table>
        <table name="Map Switch" type="1D" storagetype="uint8" category="Misc">
          <scaling name="Locked"/>
        </table>
        <table name="Base Only" type="2D" storagetype="uint8" sizex="2" storageaddress="0x5000" category="Hidden">
          <scaling units="raw" expression="x" to_byte="x"/>
        </table>
      </rom>

      <rom base="32BITBASE">
        <romid>
          <xmlid>TESTROM1</xmlid>
          <internalidaddress>2000</internalidaddress>
          <internalidstring>TESTROM1</internalidstring>
          <ecuid>1234567890</ecuid>
          <make>Subaru</make>
        </romid>
        <table name="Primary Fuel" address="3000">
          <table type="X Axis" address="3100"/>
        </table>
        <table name="Target Boost" address="3200">
          <table type="X Axis" address="3300"/>
        </table>
        <table name="Rev Limit" storageaddress="0x3400"/>
        <table name="LE Test" address="3500"/>
        <table name="Map Switch" address="3600"/>
      </rom>
    </roms>
    """

    static func putBE(_ d: inout [UInt8], _ off: Int, _ v: UInt16) { d[off] = UInt8(v >> 8); d[off + 1] = UInt8(v & 0xFF) }
    static func putLE(_ d: inout [UInt8], _ off: Int, _ v: UInt16) { d[off] = UInt8(v & 0xFF); d[off + 1] = UInt8(v >> 8) }

    static func makeROM() -> ROMImage {
        var d = [UInt8](repeating: 0, count: 0x100000)
        for (i, b) in "TESTROM1".utf8.enumerated() { d[0x2000 + i] = b }
        // Primary Fuel 3D uint8 at 0x3000: 2 rows x 3 cols.
        let fuel: [UInt8] = [10, 20, 30, 40, 50, 60]
        for (i, b) in fuel.enumerated() { d[0x3000 + i] = b }
        putBE(&d, 0x3100, 800); putBE(&d, 0x3102, 2000); putBE(&d, 0x3104, 4000)   // RPM axis
        // Target Boost 2D int16 at 0x3200: 4 cells, including a negative one.
        putBE(&d, 0x3200, UInt16(bitPattern: -50)); putBE(&d, 0x3202, 0); putBE(&d, 0x3204, 100); putBE(&d, 0x3206, 200)
        putBE(&d, 0x3300, 1000); putBE(&d, 0x3302, 2000); putBE(&d, 0x3304, 3000); putBE(&d, 0x3306, 4000)
        putBE(&d, 0x3400, 7200)                // Rev Limit
        putLE(&d, 0x3500, 0x1234); putLE(&d, 0x3502, 0x5678)   // LE Test (little endian)
        d[0x3600] = 1                          // Map Switch
        return ROMImage(data: d)
    }

    static func load() throws -> ROMDefinitionSet {
        try ROMDefinitionParser.load(data: Data(defsXML.utf8))
    }

    // MARK: Parsing

    @Test func parsesScalingsAndDefinitions() throws {
        let set = try Self.load()
        #expect(set.definitions["32BITBASE"] != nil)
        #expect(set.definitions["TESTROM1"] != nil)
        #expect(set.scalings["InjectorPulse"]?.expression == "x*0.5")
        #expect(set.scalings["InjectorPulse"]?.toByte == "x/0.5")
        #expect(set.scalings["BoostScale"]?.units == "bar")
    }

    @Test func rejectsNonDefinition() {
        #expect(throws: (any Error).self) {
            try ROMDefinitionParser.load(data: Data("<nope/>".utf8))
        }
    }

    @Test func matchesROMByInternalID() throws {
        let set = try Self.load()
        let def = set.definition(matching: Self.makeROM())
        #expect(def?.identity.xmlID == "TESTROM1")
        #expect(def?.identity.ecuID == "1234567890")
        #expect(def?.identity.make == "Subaru")
    }

    @Test func doesNotMatchWrongROM() throws {
        let set = try Self.load()
        var d = [UInt8](repeating: 0, count: 0x100000)   // no internal ID string
        for (i, b) in "OTHER999".utf8.enumerated() { d[0x2000 + i] = b }
        #expect(set.definition(matching: ROMImage(data: d)) == nil)
    }

    // MARK: Inheritance

    @Test func concreteInheritsLayoutFromBase() throws {
        let set = try Self.load()
        let tables = set.resolvedTables(forXmlID: "TESTROM1")
        let fuel = try #require(tables.first { $0.name == "Primary Fuel" })
        // Address from the concrete ROM; type, storage, sizes, scaling and axes from the base.
        #expect(fuel.address == 0x3000)
        #expect(fuel.storageType == .uint8)
        #expect(fuel.dimension == .threeD)
        #expect(fuel.sizeX == 3 && fuel.sizeY == 2)
        #expect(fuel.scalingName == "InjectorPulse")
        #expect(fuel.xAxis?.address == 0x3100)         // axis address from concrete
        #expect(fuel.xAxis?.storageType == .uint16)    // axis storage from base
        #expect(fuel.yAxis?.staticValues == [0.5, 1.0])
        #expect(fuel.isEditable)
    }

    @Test func storageAddressAttributeIsRead() throws {
        // The real RomRaider file uses storageaddress (0x-prefixed), not address.
        let set = try Self.load()
        let rev = try #require(set.resolvedTables(forXmlID: "TESTROM1").first { $0.name == "Rev Limit" })
        #expect(rev.address == 0x3400)
    }

    @Test func templateOnlyTablesAreNotExposed() throws {
        // "Base Only" is declared just in the 32BITBASE template, so a real ROM should not show it.
        let set = try Self.load()
        let names = set.resolvedTables(forXmlID: "TESTROM1").map(\.name)
        #expect(!names.contains("Base Only"))
        // ...but inspecting the template directly still shows it.
        #expect(set.resolvedTables(forXmlID: "32BITBASE").map(\.name).contains("Base Only"))
    }

    // MARK: Reading

    @Test func readsScaled3DTableWithAxes() throws {
        let set = try Self.load()
        let def = try #require(set.resolvedTables(forXmlID: "TESTROM1").first { $0.name == "Primary Fuel" })
        let table = try ROMTable.read(Self.makeROM(), def: def, scalings: set.scalings)
        #expect(table.rows == 2 && table.columns == 3)
        #expect(table.values == [[5, 10, 15], [20, 25, 30]])   // x*0.5
        #expect(table.units == "ms")
        #expect(table.xLabels == [800, 2000, 4000])
        #expect(table.yLabels == [0.5, 1.0])
    }

    @Test func readsSignedTable() throws {
        let set = try Self.load()
        let def = try #require(set.resolvedTables(forXmlID: "TESTROM1").first { $0.name == "Target Boost" })
        let table = try ROMTable.read(Self.makeROM(), def: def, scalings: set.scalings)
        #expect(table.rows == 1 && table.columns == 4)
        #expect(table.values[0] == [-0.5, 0, 1.0, 2.0])   // int16 * 0.01
    }

    @Test func readsLittleEndianTable() throws {
        let set = try Self.load()
        let def = try #require(set.resolvedTables(forXmlID: "TESTROM1").first { $0.name == "LE Test" })
        let table = try ROMTable.read(Self.makeROM(), def: def, scalings: set.scalings)
        #expect(table.values[0] == [Double(0x1234), Double(0x5678)])
    }

    // MARK: Writing (round-trips)

    @Test func writesCellAndReadsItBack() throws {
        let set = try Self.load()
        let def = try #require(set.resolvedTables(forXmlID: "TESTROM1").first { $0.name == "Primary Fuel" })
        let table = try ROMTable.read(Self.makeROM(), def: def, scalings: set.scalings)
        let edited = try table.write(Self.makeROM(), row: 1, column: 2, realValue: 33.0)   // 33ms -> raw 66
        #expect(edited.data[0x3005] == 66)
        let reread = try ROMTable.read(edited, def: def, scalings: set.scalings)
        #expect(reread.values[1][2] == 33.0)
        // Only that one byte changed.
        #expect(edited.data[0x3004] == 50)
    }

    @Test func writeSignedRoundTrips() throws {
        let set = try Self.load()
        let def = try #require(set.resolvedTables(forXmlID: "TESTROM1").first { $0.name == "Target Boost" })
        let table = try ROMTable.read(Self.makeROM(), def: def, scalings: set.scalings)
        let edited = try table.write(Self.makeROM(), row: 0, column: 0, realValue: -1.23)   // raw -123
        let reread = try ROMTable.read(edited, def: def, scalings: set.scalings)
        #expect(abs(reread.values[0][0] - -1.23) < 0.0001)
    }

    @Test func writeClampsToStorageRange() throws {
        let set = try Self.load()
        let def = try #require(set.resolvedTables(forXmlID: "TESTROM1").first { $0.name == "Primary Fuel" })
        let table = try ROMTable.read(Self.makeROM(), def: def, scalings: set.scalings)
        // 200ms -> raw 400, clamped to a uint8 max of 255.
        let edited = try table.write(Self.makeROM(), row: 0, column: 0, realValue: 200.0)
        #expect(edited.data[0x3000] == 255)
    }

    @Test func readOnlyTableRefusesWrite() throws {
        let set = try Self.load()
        let def = try #require(set.resolvedTables(forXmlID: "TESTROM1").first { $0.name == "Map Switch" })
        let table = try ROMTable.read(Self.makeROM(), def: def, scalings: set.scalings)
        #expect(throws: ROMTable.TableError.self) {
            _ = try table.write(Self.makeROM(), row: 0, column: 0, realValue: 2)
        }
    }

    @Test func tableAddressPastEndIsCaught() throws {
        var def = ROMTableDef(name: "Bad", dimension: .twoD, storageType: .uint16, address: 0x0FFFFF, sizeX: 8)
        def.scaling = ROMScaling(expression: "x", toByte: "x")
        #expect(throws: ROMTable.TableError.self) {
            _ = try ROMTable.read(Self.makeROM(), def: def, scalings: [:])
        }
    }

    // MARK: Recommendations and store

    @Test func recommendsCloseMatchWhenNoExactMatch() throws {
        let set = try Self.load()
        var d = [UInt8](repeating: 0, count: 0x100000)
        for (i, b) in "TESTROM9".utf8.enumerated() { d[0x2000 + i] = b }   // close to TESTROM1, but not equal
        let rom = ROMImage(data: d)
        #expect(set.definition(matching: rom) == nil)                      // no exact match
        let recs = set.recommendations(for: rom)
        #expect(recs.contains { $0.identity.xmlID == "TESTROM1" })         // but recommended
    }

    @Test func storeRejectsCorruptDownload() {
        #expect(!ROMDefinitionsStore.verify(Data("not the real file".utf8)))
    }

    // MARK: Storage round-trips

    @Test(arguments: [ROMStorageType.uint8, .int8, .uint16, .int16, .uint32, .int32, .float])
    func storageRoundTrips(_ type: ROMStorageType) {
        for bigEndian in [true, false] {
            let value = type.isSigned ? -3.0 : 7.0
            let bytes = type.bytes(forRaw: value, bigEndian: bigEndian)
            #expect(bytes.count == type.byteCount)
            let back = type.readRaw(bytes, at: 0, bigEndian: bigEndian)
            #expect(back == value)
        }
    }
}
