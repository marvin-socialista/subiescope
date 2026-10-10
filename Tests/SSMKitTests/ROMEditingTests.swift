import Foundation
import Testing
@testable import SSMKit

/// What the ROM editor's toolbar and its coloured tables rest on: RomRaider's step sizes, the heat
/// scale both fronts colour their cells with, and changing several cells at once. All of it works on
/// a ROM in memory, built here by hand, so none of it needs a file or a car.
struct ROMEditingTests {

    // A boost map the way RomRaider defines one (one byte per cell, with its two step sizes), a
    // signed map, an air/fuel map whose numbers fall as the stored byte rises, a float map, and a
    // map that is read-only because it has no formula back to bytes.
    static let defsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <roms>
      <scaling name="Speed" units="RPM" expression="x" to_byte="x" format="#" fineincrement="50" coarseincrement="100"/>
      <scaling name="Locked" units="mode" expression="x" to_byte=" " format="0"/>
      <rom>
        <romid><xmlid>32BITBASE</xmlid></romid>
        <table name="Target Boost " type="3D" storagetype="uint8" sizex="3" sizey="2" category="Boost">
          <scaling units="Boost Target (psi relative sea level)" expression="(x*.15469416)-14.6959452" to_byte="(x+14.6959452)/.15469416" format="0.00" fineincrement=".08" coarseincrement="1"/>
          <table type="X Axis" name="Requested Torque" storagetype="uint16" sizex="3">
            <scaling units="raw ecu value" expression="x" to_byte="x" format="0.0" fineincrement="1" coarseincrement="10"/>
          </table>
          <table type="Y Axis" name="Engine Speed" storagetype="uint16" sizey="2"><scaling name="Speed"/></table>
        </table>
        <table name="Timing Trim" type="2D" storagetype="int8" sizex="3" category="Ignition">
          <scaling units="degrees" expression="x*0.5" to_byte="x/0.5" format="0.0"/>
          <table type="X Axis" name="Intake Temperature" storagetype="uint8" sizex="3">
            <scaling units="Degrees F" expression="x" to_byte="x" format="#"/>
          </table>
        </table>
        <table name="Fuel Target" type="2D" storagetype="uint8" sizex="2" category="Fuel">
          <scaling units="Estimated Air/Fuel Ratio" expression="14.7/(1+x*.0078125)" to_byte="(14.7/x-1)/.0078125" format="0.00" fineincrement=".01" coarseincrement=".5"/>
        </table>
        <table name="Float Map" type="2D" storagetype="float" sizex="2" category="Misc">
          <scaling units="g/s" expression="x" to_byte="x" format="0.00"/>
        </table>
        <table name="Rev Limit" type="1D" storagetype="uint16" category="Limits"><scaling name="Speed"/></table>
        <table name="Map Switch" type="1D" storagetype="uint8" category="Misc"><scaling name="Locked"/></table>
        <table type="Switch" name="(P0011) CAMSHAFT POS." category="Diagnostic Trouble Codes" sizey="3">
          <description>To disable this DTC, make sure the box above is unchecked.</description>
          <state name="on" data="04 00 11" />
          <state name="off" data="05 00 00" />
        </table>
        <table type="Switch" name="Template Only" category="Diagnostic Trouble Codes" sizey="1">
          <state name="on" data="01" />
          <state name="off" data="00" />
        </table>
      </rom>
      <rom base="32BITBASE">
        <romid>
          <xmlid>EDITROM1</xmlid>
          <internalidaddress>2000</internalidaddress>
          <internalidstring>EDITROM1</internalidstring>
        </romid>
        <table name="Target Boost " address="3000">
          <table type="X Axis" address="3100"/>
          <table type="Y Axis" address="3200"/>
        </table>
        <table name="Timing Trim" address="3300"><table type="X Axis" address="3310"/></table>
        <table name="Fuel Target" address="3400"/>
        <table name="Float Map" address="3500"/>
        <table name="Rev Limit" address="3600"/>
        <table name="Map Switch" address="3700"/>
        <table name="(P0011) CAMSHAFT POS." storageaddress="0x3800"/>
      </rom>
    </roms>
    """

    static func putBE(_ d: inout [UInt8], _ offset: Int, _ value: UInt16) {
        d[offset] = UInt8(value >> 8)
        d[offset + 1] = UInt8(value & 0xFF)
    }

    static func makeROM() -> ROMImage {
        var d = [UInt8](repeating: 0, count: 0x100000)
        for (i, b) in "EDITROM1".utf8.enumerated() { d[0x2000 + i] = b }
        // Target Boost: 2 rows by 3 columns of one byte each, with both axes in the ROM.
        for (i, b) in ([100, 150, 200, 210, 254, 1] as [UInt8]).enumerated() { d[0x3000 + i] = b }
        putBE(&d, 0x3100, 80); putBE(&d, 0x3102, 145); putBE(&d, 0x3104, 410)
        putBE(&d, 0x3200, 4000); putBE(&d, 0x3202, 4400)
        // Timing Trim: -4, 0 and 125 as signed bytes, over 86, 104 and 122 degrees.
        d[0x3300] = UInt8(bitPattern: -4); d[0x3301] = 0; d[0x3302] = 125
        d[0x3310] = 86; d[0x3311] = 104; d[0x3312] = 122
        // Fuel Target: two bytes of an air/fuel ratio.
        d[0x3400] = 40; d[0x3401] = 0
        // Float Map: 1.5 and 250.25, big-endian.
        for (i, value) in ([1.5, 250.25] as [Float]).enumerated() {
            let bits = value.bitPattern
            for byte in 0..<4 { d[0x3500 + i * 4 + byte] = UInt8(bits >> UInt32(24 - byte * 8) & 0xFF) }
        }
        putBE(&d, 0x3600, 6700)
        d[0x3700] = 1
        // The trouble code's switch, in its "on" position.
        d[0x3800] = 0x04; d[0x3801] = 0x00; d[0x3802] = 0x11
        return ROMImage(data: d)
    }

    static func table(_ name: String, in rom: ROMImage) throws -> ROMTable {
        let set = try ROMDefinitionParser.load(data: Data(defsXML.utf8))
        let def = try #require(set.resolvedTables(forXmlID: "EDITROM1").first { $0.name == name })
        return try ROMTable.read(rom, def: def, scalings: set.scalings)
    }

    static func cell(_ row: Int, _ column: Int) -> ROMTable.Cell { ROMTable.Cell(row: row, column: column) }

    // MARK: Step sizes

    @Test func incrementsAreParsedFromInlineAndSharedScalings() throws {
        let set = try ROMDefinitionParser.load(data: Data(Self.defsXML.utf8))
        // RomRaider writes ".08" without a zero in front.
        let boost = try Self.table("Target Boost ", in: Self.makeROM())
        #expect(boost.scaling.fineIncrement == 0.08)
        #expect(boost.scaling.coarseIncrement == 1)
        #expect(set.scalings["Speed"]?.fineIncrement == 50)
        #expect(set.scalings["Speed"]?.coarseIncrement == 100)
        #expect(boost.yScaling?.fineIncrement == 50)
        #expect(boost.xScaling?.coarseIncrement == 10)
    }

    @Test func aScalingWithoutIncrementsHasNone() throws {
        let trim = try Self.table("Timing Trim", in: Self.makeROM())
        #expect(trim.scaling.fineIncrement == nil)
        #expect(trim.scaling.coarseIncrement == nil)
        #expect(ROMDefinitionParser.increment(nil) == nil)
        #expect(ROMDefinitionParser.increment("") == nil)
        #expect(ROMDefinitionParser.increment("fast") == nil)
        #expect(ROMDefinitionParser.increment(" .5 ") == 0.5)
    }

    @Test func stepsComeFromTheIncrementsOrElseFromTheFormat() {
        let defined = ROMScaling(format: "0.00", fineIncrement: 0.08, coarseIncrement: 1)
        #expect(defined.fineStep == 0.08)
        #expect(defined.coarseStep == 1)
        // Without increments: the smallest step the format shows, and ten of those.
        #expect(ROMScaling(format: "0.00").fineStep == 0.01)
        #expect(abs(ROMScaling(format: "0.00").coarseStep - 0.1) < 1e-12)
        #expect(ROMScaling(format: "#").fineStep == 1)
        #expect(ROMScaling(format: "#").coarseStep == 10)
        // A step is a size: a negative or empty increment never makes "up" lower a number.
        #expect(ROMScaling(format: "0.0", fineIncrement: -0.3, coarseIncrement: 0).fineStep == 0.3)
        #expect(abs(ROMScaling(format: "0.0", fineIncrement: -0.3, coarseIncrement: 0).coarseStep - 3) < 1e-12)
    }

    @Test func decimalsAndSignedTextFollowTheFormat() {
        #expect(ROMScaling(format: "0.00").decimals == 2)
        #expect(ROMScaling(format: "#").decimals == 0)
        #expect(ROMScaling(format: "#0.000").decimals == 3)
        #expect(ROMScaling(format: "0.00").signedText(0.77) == "+0.77")
        #expect(ROMScaling(format: "0.00").signedText(-3.41) == "-3.41")
        #expect(ROMScaling(format: "#").signedText(0) == "0")
    }

    @Test func shortUnitsAreWhatFitsAfterANumber() {
        #expect(ROMScaling(units: "Boost Target (psi relative sea level)").shortUnits == "psi")
        #expect(ROMScaling(units: "Target Boost (psia) Compensation (%)").shortUnits == "%")
        #expect(ROMScaling(units: "Base Ignition Timing (degrees BTDC)").shortUnits == "degrees BTDC")
        #expect(ROMScaling(units: "RPM").shortUnits == "RPM")
        #expect(ROMScaling(units: "Degrees F").shortUnits == "Degrees F")
        #expect(ROMScaling(units: "").shortUnits == "")
        // Neither of these names a unit.
        #expect(ROMScaling(units: "raw ecu value").shortUnits == "")
        #expect(ROMScaling(units: "Requested Torque (raw ecu value)").shortUnits == "")
        #expect(ROMScaling(units: "Estimated Air/Fuel Ratio").shortUnits == "")
    }

    // MARK: Heat scale

    @Test func theScaleRunsFromBlueForTheLowestToRedForTheHighest() {
        let scale = ROMHeatScale(values: [[-4.83, 0, 7.255], [19.34, 2, 3]])
        #expect(scale.low == -4.83)
        #expect(scale.high == 19.34)
        #expect(scale.place(of: -4.83) == 0)
        #expect(scale.place(of: 19.34) == 1)
        #expect(abs(scale.place(of: 7.255) - 0.5) < 1e-9)
        #expect(scale.color(for: -4.83) == ROMHeatScale.Color(hue: 250, saturation: 0.84, lightness: 0.70))
        #expect(scale.color(for: 19.34) == ROMHeatScale.Color(hue: 0, saturation: 0.84, lightness: 0.70))
        #expect(scale.color(for: 7.255).hue == 125)
        // As the design's style sheet writes them.
        #expect(scale.color(for: -4.83).css == "hsl(250, 84%, 70%)")
        #expect(scale.color(for: 19.34).css == "hsl(0, 84%, 70%)")
    }

    @Test func aValueOutsideTheScaleTakesTheNearestEnd() {
        let scale = ROMHeatScale(low: 0, high: 10)
        #expect(scale.place(of: -5) == 0)
        #expect(scale.place(of: 25) == 1)
        #expect(scale.color(for: 25).hue == 0)
        // The ends may be given either way round.
        #expect(ROMHeatScale(low: 10, high: 0) == scale)
        #expect(ROMHeatScale.color(at: 2).hue == 0)
        #expect(ROMHeatScale.color(at: -1).hue == 250)
        #expect(ROMHeatScale.color(at: .nan).hue == 250)
    }

    @Test func aMapWhoseValuesAreAllTheSameIsOneColour() {
        let flat = ROMHeatScale(values: [[0, 0, 0], [0, 0, 0]])
        #expect(flat.isFlat)
        #expect(flat.place(of: 0) == 0)
        #expect(flat.color(for: 0) == ROMHeatScale.color(at: 0))
        #expect(flat.color(for: 123) == flat.color(for: 0))
        // One number, and no number at all, are flat too.
        #expect(ROMHeatScale(values: [[6700]]).isFlat)
        #expect(ROMHeatScale(values: []).isFlat)
        #expect(ROMHeatScale(values: []).low == 0)
    }

    @Test func aValueThatIsNotANumberDoesNotStretchTheScale() {
        let scale = ROMHeatScale(values: [[1, .nan, 3], [.infinity, 2, -.infinity]])
        #expect(scale.low == 1)
        #expect(scale.high == 3)
        #expect(scale.place(of: .nan) == 0)
    }

    @Test func coloursComeOutAsRedGreenAndBlue() {
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.005 }
        // hsl(0, 84%, 70%) is #F37272 and hsl(250, 84%, 70%) is #8872F3.
        let red = ROMHeatScale.color(at: 1).rgb
        #expect(close(red.red, 0.952) && close(red.green, 0.448) && close(red.blue, 0.448))
        let blue = ROMHeatScale.color(at: 0).rgb
        #expect(close(blue.red, 0.532) && close(blue.green, 0.448) && close(blue.blue, 0.952))
        // Halfway is a green: hsl(125, 84%, 70%).
        let green = ROMHeatScale.color(at: 0.5).rgb
        #expect(green.green > green.red && green.green > green.blue)
        #expect(close(green.green, 0.952))
        // Grey has no hue to speak of.
        let grey = ROMHeatScale.Color(hue: 200, saturation: 0, lightness: 0.5).rgb
        #expect(close(grey.red, 0.5) && close(grey.green, 0.5) && close(grey.blue, 0.5))
    }

    // MARK: Changing several cells at once

    @Test func steppingRaisesAndLowersEverySelectedCell() throws {
        let rom = Self.makeROM()
        let boost = try Self.table("Target Boost ", in: rom)
        // One coarse step is 1 psi, which is 6.46 stored steps: 6 after rounding.
        let raised = try boost.write(rom, cells: [Self.cell(0, 0), Self.cell(0, 1), Self.cell(1, 0)], change: .step(1))
        #expect(raised.bytes(at: 0x3000, length: 6) == [106, 156, 200, 216, 254, 1])
        let lowered = try boost.write(rom, cells: [Self.cell(0, 2)], change: .step(-1))
        #expect(lowered.bytes(at: 0x3000, length: 6) == [100, 150, 194, 210, 254, 1])
        // Nothing but the map's own bytes was touched, and the ROM passed in is as it was.
        #expect(raised.bytes(at: 0x3100, length: 6) == rom.bytes(at: 0x3100, length: 6))
        #expect(rom.bytes(at: 0x3000, length: 6) == [100, 150, 200, 210, 254, 1])
    }

    @Test func aStepSmallerThanACellCanHoldStillMovesIt() throws {
        let rom = Self.makeROM()
        let boost = try Self.table("Target Boost ", in: rom)
        // 0.01 psi is a fifteenth of a stored step. RomRaider moves the cell by one step then, and so do we.
        let up = try boost.write(rom, cells: [Self.cell(0, 0)], change: .step(0.01))
        #expect(up.data[0x3000] == 101)
        let down = try boost.write(rom, cells: [Self.cell(0, 0)], change: .step(-0.01))
        #expect(down.data[0x3000] == 99)
        // A step of nothing is no step.
        #expect(try boost.write(rom, cells: [Self.cell(0, 0)], change: .step(0)) == rom)
    }

    @Test func aStepFollowsTheNumberOnAScaleThatFalls() throws {
        let rom = Self.makeROM()
        let fuel = try Self.table("Fuel Target", in: rom)
        #expect(abs(fuel.values[0][0] - 11.2) < 1e-9)
        // "Up" means a higher air/fuel ratio, which is a lower stored byte here.
        let up = try fuel.write(rom, cells: [Self.cell(0, 0)], change: .step(0.01))
        #expect(up.data[0x3400] == 39)
        let down = try fuel.write(rom, cells: [Self.cell(0, 0)], change: .step(-0.01))
        #expect(down.data[0x3400] == 41)
        #expect(try Self.table("Fuel Target", in: up).values[0][0] > fuel.values[0][0])
    }

    @Test func eachStepStartsFromWhatTheROMHoldsNow() throws {
        let rom = Self.makeROM()
        let boost = try Self.table("Target Boost ", in: rom)
        // The table was read before the first step. The second one still builds on the first.
        let once = try boost.write(rom, cells: [Self.cell(0, 0)], change: .step(1))
        let twice = try boost.write(once, cells: [Self.cell(0, 0)], change: .step(1))
        #expect(twice.data[0x3000] == 112)
        // A cell named twice is stepped twice.
        let doubled = try boost.write(rom, cells: [Self.cell(0, 0), Self.cell(0, 0)], change: .step(1))
        #expect(doubled.data[0x3000] == 112)
    }

    @Test func settingGivesEveryCellTheSameValue() throws {
        let rom = Self.makeROM()
        let trim = try Self.table("Timing Trim", in: rom)
        let set = try trim.write(rom, cells: [Self.cell(0, 0), Self.cell(0, 2)], change: .set(-10))
        #expect(set.bytes(at: 0x3300, length: 3) == [UInt8(bitPattern: -20), 0, UInt8(bitPattern: -20)])
        #expect(try Self.table("Timing Trim", in: set).values[0] == [-10, 0, -10])
        // One cell through the old call is the same edit.
        #expect(try trim.write(rom, row: 0, column: 1, realValue: 3) == trim.write(rom, cells: [Self.cell(0, 1)], change: .set(3)))
    }

    @Test func multiplyingScalesEachCellByAFactor() throws {
        let rom = Self.makeROM()
        let trim = try Self.table("Timing Trim", in: rom)
        // -2, 0 and 62.5 degrees, each times 1.5: -3, 0 and 93.75, which is past what a signed byte holds.
        let scaled = try trim.write(rom, cells: [Self.cell(0, 0), Self.cell(0, 1), Self.cell(0, 2)], change: .multiply(1.5))
        #expect(scaled.bytes(at: 0x3300, length: 3) == [UInt8(bitPattern: -6), 0, 127])
        // A float map keeps the fraction.
        let floats = try Self.table("Float Map", in: rom)
        let halved = try floats.write(rom, cells: [Self.cell(0, 0), Self.cell(0, 1)], change: .multiply(0.5))
        #expect(try Self.table("Float Map", in: halved).values[0] == [0.75, 125.125])
    }

    @Test func everyChangeIsClampedToWhatTheStorageTypeHolds() throws {
        let rom = Self.makeROM()
        let boost = try Self.table("Target Boost ", in: rom)
        // 254 and 1 are next to the ends of a byte: steps of 5 psi stop at 255 and at 0.
        let high = try boost.write(rom, cells: [Self.cell(1, 1)], change: .step(5))
        #expect(high.data[0x3004] == 255)
        let low = try boost.write(rom, cells: [Self.cell(1, 2)], change: .step(-5))
        #expect(low.data[0x3005] == 0)
        #expect(try boost.write(rom, cells: [Self.cell(0, 0)], change: .set(1000)).data[0x3000] == 255)
        #expect(try boost.write(rom, cells: [Self.cell(0, 0)], change: .set(-1000)).data[0x3000] == 0)
        // That cell holds 0.77 psi: a hundred times that is past the top of a byte, and minus a hundred times past the bottom.
        #expect(try boost.write(rom, cells: [Self.cell(0, 0)], change: .multiply(100)).data[0x3000] == 255)
        #expect(try boost.write(rom, cells: [Self.cell(0, 0)], change: .multiply(-100)).data[0x3000] == 0)
        // A cell that is at the end stays there. It does not wrap around.
        let top = try boost.write(high, cells: [Self.cell(1, 1)], change: .step(0.01))
        #expect(top.data[0x3004] == 255)
        let signed = try Self.table("Timing Trim", in: rom)
        #expect(try signed.write(rom, cells: [Self.cell(0, 2)], change: .step(50)).data[0x3302] == 127)
        #expect(try signed.write(rom, cells: [Self.cell(0, 0)], change: .set(-500)).data[0x3300] == UInt8(bitPattern: -128))
        let limit = try Self.table("Rev Limit", in: rom)
        #expect(try limit.write(rom, cells: [Self.cell(0, 0)], change: .multiply(100)).bytes(at: 0x3600, length: 2) == [0xFF, 0xFF])
    }

    @Test func aFloatMapStepsByExactlyTheStep() throws {
        let rom = Self.makeROM()
        let floats = try Self.table("Float Map", in: rom)
        let stepped = try floats.write(rom, cells: [Self.cell(0, 0)], change: .step(0.25))
        #expect(try Self.table("Float Map", in: stepped).values[0] == [1.75, 250.25])
    }

    @Test func aReadOnlyMapRefusesEveryChange() throws {
        let rom = Self.makeROM()
        let locked = try Self.table("Map Switch", in: rom)
        #expect(!locked.scaling.isWritable)
        for change in [ROMTable.Change.step(1), .set(0), .multiply(2)] {
            #expect { _ = try locked.write(rom, cells: [Self.cell(0, 0)], change: change) } throws: { error in
                if case ROMTable.TableError.notWritable = error { return true }
                return false
            }
        }
    }

    @Test func aCellOutsideTheMapRefusesTheWholeChange() throws {
        let rom = Self.makeROM()
        let boost = try Self.table("Target Boost ", in: rom)
        for bad in [Self.cell(2, 0), Self.cell(0, 3), Self.cell(-1, 0), Self.cell(0, -1)] {
            #expect { _ = try boost.write(rom, cells: [Self.cell(0, 0), bad], change: .step(1)) } throws: { error in
                if case ROMTable.TableError.outOfRange = error { return true }
                return false
            }
        }
        // No cell to change is no change.
        #expect(try boost.write(rom, cells: [], change: .set(5)) == rom)
    }

    @Test func aValueThatIsNoNumberIsRefused() throws {
        let rom = Self.makeROM()
        let boost = try Self.table("Target Boost ", in: rom)
        #expect(throws: (any Error).self) { _ = try boost.write(rom, cells: [Self.cell(0, 0)], change: .set(.nan)) }
        #expect(throws: (any Error).self) { _ = try boost.write(rom, cells: [Self.cell(0, 0)], change: .multiply(.infinity)) }
    }

    // MARK: Switches

    @Test func aSwitchIsReadWithItsPositionsAndInheritsThemFromItsBase() throws {
        let set = try ROMDefinitionParser.load(data: Data(Self.defsXML.utf8))
        let tables = set.resolvedTables(forXmlID: "EDITROM1")
        let code = try #require(tables.first { $0.name == "(P0011) CAMSHAFT POS." })
        #expect(code.dimension == .switch)
        #expect(code.category == "Diagnostic Trouble Codes")
        // The positions come from the base, the address from the ROM's own definition.
        #expect(code.states == [ROMSwitchState(name: "on", data: [0x04, 0x00, 0x11]), ROMSwitchState(name: "off", data: [0x05, 0x00, 0x00])])
        #expect(code.address == 0x3800)
        #expect(code.isSwitch)
        // It is no table of numbers: it has no storage type, and reading it as one refuses.
        #expect(!code.isEditable)
        #expect(code.gridSize.rows == 1 && code.gridSize.columns == 1)
        #expect(throws: (any Error).self) { _ = try ROMTable.read(Self.makeROM(), def: code, scalings: set.scalings) }
        // A switch this ROM gives no address for is not one of its maps, and a table of numbers is no switch.
        #expect(!tables.contains { $0.name == "Template Only" })
        #expect(set.definitions["32BITBASE"]?.tables["Template Only"]?.isSwitch == false)
        let boost = try #require(tables.first { $0.name == "Target Boost " })
        #expect(!boost.isSwitch && boost.states.isEmpty)
        #expect(boost.switchState(in: Self.makeROM()) == nil)
    }

    @Test func aSwitchSaysWhichPositionTheROMIsIn() throws {
        let set = try ROMDefinitionParser.load(data: Data(Self.defsXML.utf8))
        let code = try #require(set.resolvedTables(forXmlID: "EDITROM1").first { $0.name == "(P0011) CAMSHAFT POS." })
        var rom = Self.makeROM()
        #expect(code.switchState(in: rom)?.name == "on")
        rom.replace(at: 0x3800, with: [0x05, 0x00, 0x00])
        #expect(code.switchState(in: rom)?.name == "off")
        // Bytes that are neither position are no position.
        rom.replace(at: 0x3800, with: [0x05, 0x00, 0x11])
        #expect(code.switchState(in: rom) == nil)
        // A switch past the end of the ROM is in no position either.
        var far = code
        far.address = 0x0FFFFF
        #expect(far.switchState(in: rom) == nil)
    }

    @Test func aSwitchsBytesAreReadAsHex() {
        #expect(ROMDefinitionParser.hexBytes("04 00 11") == [0x04, 0x00, 0x11])
        #expect(ROMDefinitionParser.hexBytes("  5A a5\tA5 5a ") == [0x5A, 0xA5, 0xA5, 0x5A])
        #expect(ROMDefinitionParser.hexBytes("7") == [7])
        #expect(ROMDefinitionParser.hexBytes(nil) == nil)
        #expect(ROMDefinitionParser.hexBytes("") == nil)
        #expect(ROMDefinitionParser.hexBytes("04 0G") == nil)
        #expect(ROMDefinitionParser.hexBytes("123") == nil)
    }

    /// The real file: the 2009 JDM STI's calibration has 187 tables of numbers and 110 switches (the
    /// trouble codes, the checksum fix and one for OBD-II), in 26 categories.
    @Test func romRaidersDefinitionsListTheSwitchesOfACalibration() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("definitions/ecu_defs.xml")
        guard let data = try? Data(contentsOf: file) else { return }   // not there: nothing to check
        let set = try ROMDefinitionParser.load(data: data)
        let tables = set.resolvedTables(forXmlID: "AZ1G500F")
        let numbers = tables.filter(\.isEditable), switches = tables.filter(\.isSwitch)
        #expect(numbers.count == 187)
        #expect(switches.count == 110)
        #expect(Set((numbers + switches).map(\.category)).count == 26)
        #expect(switches.filter { $0.category == "Diagnostic Trouble Codes" }.count == 108)
        // Every switch has an "on" and an "off", of the same length.
        for table in switches {
            #expect(table.states.map(\.name).sorted() == ["off", "on"], "\(table.name)")
            #expect(Set(table.states.map(\.data.count)).count == 1, "\(table.name)")
        }
        // Target Boost brings the step sizes RomRaider gives a boost target.
        let boost = try #require(tables.first { $0.name == "Target Boost " })
        #expect(boost.gridSize.rows == 18 && boost.gridSize.columns == 13)
        #expect(boost.scaling?.fineIncrement == 0.01)
        #expect(boost.scaling?.coarseIncrement == 0.5)
    }

    // MARK: Where a cell is, and what the axes are called

    @Test func aCellKnowsWhereTheROMKeepsIt() throws {
        let rom = Self.makeROM()
        let boost = try Self.table("Target Boost ", in: rom)
        #expect(boost.offset(row: 0, column: 0) == 0x3000)
        #expect(boost.offset(row: 1, column: 2) == 0x3005)
        #expect(boost.offset(row: 2, column: 0) == nil)
        #expect(boost.storedBytes(in: rom, row: 1, column: 1) == [254])
        let floats = try Self.table("Float Map", in: rom)
        #expect(floats.offset(row: 0, column: 1) == 0x3504)
        #expect(floats.storedBytes(in: rom, row: 0, column: 0) == [0x3F, 0xC0, 0x00, 0x00])
        let limit = try Self.table("Rev Limit", in: rom)
        #expect(limit.storedBytes(in: rom, row: 0, column: 0) == [0x1A, 0x2C])
    }

    @Test func axesAreNamedWithTheirUnitsAndLabelledInTheirOwnFormat() throws {
        let rom = Self.makeROM()
        let boost = try Self.table("Target Boost ", in: rom)
        #expect(boost.title == "Target Boost")
        #expect(boost.columnTitle == "Requested Torque (raw ecu value)")
        #expect(boost.rowTitle == "Engine Speed (RPM)")
        // The torque axis has the format "0.0", and every label on it is whole: no ".0" then.
        #expect(boost.columnLabels == ["80", "145", "410"])
        #expect(boost.rowLabels == ["4000", "4400"])
        let trim = try Self.table("Timing Trim", in: rom)
        #expect(trim.columnTitle == "Intake Temperature (Degrees F)")
        #expect(trim.rowTitle == nil)
        #expect(trim.columnLabels == ["86", "104", "122"])
        let limit = try Self.table("Rev Limit", in: rom)
        #expect(limit.columnTitle == nil)
        // A unit that names the axis already is not said twice.
        #expect(ROMTable.axisTitle(ROMAxis(name: "Engine Speed"), units: "Engine Speed (RPM)") == "Engine Speed (RPM)")
        #expect(ROMTable.axisTitle(ROMAxis(name: ""), units: "RPM") == "RPM")
        #expect(ROMTable.axisTitle(ROMAxis(name: "Gear"), units: "") == "Gear")
        #expect(ROMTable.axisTitle(nil, units: "RPM") == nil)
        // Labels that are not all whole keep the decimals of the axis's format.
        #expect(ROMTable.labelTexts([0.5, 1, 1.25], ROMScaling(format: "0.00")) == ["0.50", "1.00", "1.25"])
        #expect(ROMTable.labelTexts([0.5, 1], nil) == ["0.50", "1.00"])
    }

    @Test func aCellIsPlacedInTheWordsOfItsAxes() throws {
        let rom = Self.makeROM()
        // Rows by columns: the row first, with a unit only where there is one to name.
        #expect(try Self.table("Target Boost ", in: rom).place(row: 0, column: 2) == "4000 RPM × 410")
        #expect(try Self.table("Target Boost ", in: rom).place(row: 1, column: 0) == "4400 RPM × 80")
        #expect(try Self.table("Timing Trim", in: rom).place(row: 0, column: 1) == "104 Degrees F")
        #expect(try Self.table("Rev Limit", in: rom).place(row: 0, column: 0) == "Value")
        // A row of numbers without an axis counts its columns.
        #expect(try Self.table("Fuel Target", in: rom).place(row: 0, column: 1) == "Column 2")
    }
}
