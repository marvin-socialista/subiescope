import Foundation

/// The parts of a RomRaider ECU definition (`ecu_defs.xml`) that SubieScope needs to show and edit a
/// ROM's maps by name. RomRaider's editor definitions are the same kind of data as its logger
/// definitions: there is no explicit license on the file, so it is never bundled or committed. The
/// user points at their own copy, exactly as they already supply the ROM file itself.
///
/// This models the format (which is just facts, not copyrightable); the parser is in
/// `ROMDefinitionParser`. Facts about the format and about Subaru ROMs come from RomRaider and from
/// FastECU's reader (`file_defs_romraider.cpp`, GPLv3).

/// How a number is stored in the ROM.
public enum ROMStorageType: String, Sendable, Equatable {
    case uint8, uint16, uint32
    case int8, int16, int32
    case float

    public var byteCount: Int {
        switch self {
        case .uint8, .int8: return 1
        case .uint16, .int16: return 2
        case .uint32, .int32, .float: return 4
        }
    }

    public var isSigned: Bool {
        switch self {
        case .int8, .int16, .int32: return true
        default: return false
        }
    }

    /// The RomRaider strings, which include a few we treat as a width (e.g. "uint8", "int16"). Unknown
    /// or non-numeric types (bloblist, char) return nil and the table is shown but not edited.
    public init?(romRaider: String) {
        switch romRaider.trimmingCharacters(in: .whitespaces).lowercased() {
        case "uint8": self = .uint8
        case "uint16": self = .uint16
        case "uint32": self = .uint32
        case "int8": self = .int8
        case "int16": self = .int16
        case "int32": self = .int32
        case "float": self = .float
        default: return nil
        }
    }

    /// Reads one value as a raw number (before any scaling) from `data` at `offset`.
    public func readRaw(_ data: [UInt8], at offset: Int, bigEndian: Bool) -> Double? {
        guard offset >= 0, offset + byteCount <= data.count else { return nil }
        var bytes = Array(data[offset..<(offset + byteCount)])
        if !bigEndian { bytes.reverse() }
        var value: UInt32 = 0
        for b in bytes { value = (value << 8) | UInt32(b) }
        switch self {
        case .uint8, .uint16, .uint32:
            return Double(value)
        case .int8:
            return Double(Int8(bitPattern: UInt8(value & 0xFF)))
        case .int16:
            return Double(Int16(bitPattern: UInt16(value & 0xFFFF)))
        case .int32:
            return Double(Int32(bitPattern: value))
        case .float:
            return Double(Float(bitPattern: value))
        }
    }

    /// Clamps `raw` to this type's range and returns the bytes in the given order.
    public func bytes(forRaw raw: Double, bigEndian: Bool) -> [UInt8] {
        var out: [UInt8]
        switch self {
        case .float:
            let f = Float(raw)
            let bits = f.bitPattern
            out = [UInt8(bits >> 24 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
        case .uint8:
            out = [UInt8(clamp(raw.rounded(), 0, 255))]
        case .int8:
            out = [UInt8(bitPattern: Int8(clamp(raw.rounded(), -128, 127)))]
        case .uint16:
            let v = UInt16(clamp(raw.rounded(), 0, 65535))
            out = [UInt8(v >> 8), UInt8(v & 0xFF)]
        case .int16:
            let v = Int16(clamp(raw.rounded(), -32768, 32767))
            let u = UInt16(bitPattern: v)
            out = [UInt8(u >> 8), UInt8(u & 0xFF)]
        case .uint32:
            let v = UInt32(clamp(raw.rounded(), 0, 4294967295))
            out = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        case .int32:
            let v = Int32(clamp(raw.rounded(), -2147483648, 2147483647))
            let u = UInt32(bitPattern: v)
            out = [UInt8(u >> 24 & 0xFF), UInt8(u >> 16 & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u & 0xFF)]
        }
        if !bigEndian { out.reverse() }
        return out
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
}

/// How raw numbers become real-world values and back: `expression` is byte→real (e.g. "x*0.0625"),
/// `toByte` is real→byte (e.g. "x/0.0625").
public struct ROMScaling: Sendable, Equatable {
    public var name: String?
    public var units: String
    public var expression: String
    public var toByte: String
    public var format: String
    public var min: Double?
    public var max: Double?
    /// RomRaider's two step sizes for raising and lowering a value with its fine and coarse buttons,
    /// in real units (`fineincrement` and `coarseincrement`: .08 and 1 for a boost target in psi).
    /// Nil when the definition gives none.
    public var fineIncrement: Double?
    public var coarseIncrement: Double?

    public init(name: String? = nil, units: String = "", expression: String = "x", toByte: String = "x",
                format: String = "0.00", min: Double? = nil, max: Double? = nil,
                fineIncrement: Double? = nil, coarseIncrement: Double? = nil) {
        self.name = name
        self.units = units
        self.expression = expression
        self.toByte = toByte
        self.format = format
        self.min = min
        self.max = max
        self.fineIncrement = fineIncrement
        self.coarseIncrement = coarseIncrement
    }

    /// True when a real value can be written back (there is a real→byte formula).
    public var isWritable: Bool { !toByte.isEmpty && toByte != " " }

    /// How many decimals the RomRaider format shows: two for "0.00", none for "#".
    public var decimals: Int {
        guard let dot = format.firstIndex(of: ".") else { return 0 }
        return format.distance(from: format.index(after: dot), to: format.endIndex)
    }

    /// A real value as text, with as many decimals as the RomRaider format has ("0.00" gives two).
    public func text(_ value: Double) -> String {
        String(format: "%.\(decimals)f", value)
    }

    /// The difference between two real values as text, always with its sign: "+0.77", "-3.41".
    public func signedText(_ difference: Double) -> String {
        let text = self.text(difference)
        return difference > 0 && !text.hasPrefix("+") ? "+" + text : text
    }

    /// The step the fine buttons take: the definition's, or else the smallest step the format shows
    /// (0.01 for "0.00"). Always above zero, so "up" raises the number.
    public var fineStep: Double {
        if let fine = fineIncrement, fine != 0, fine.isFinite { return abs(fine) }
        return pow(10, -Double(decimals))
    }

    /// The step the coarse buttons take: the definition's, or else ten fine steps.
    public var coarseStep: Double {
        if let coarse = coarseIncrement, coarse != 0, coarse.isFinite { return abs(coarse) }
        return fineStep * 10
    }

    /// The unit to put after a single number. RomRaider's units are often a whole title, such as
    /// "Boost Target (psi relative sea level)": that gives "psi", "Target Boost (psia) Compensation (%)"
    /// gives "%", and a short unit ("RPM", "Degrees F") stays as it is. Empty for a long text
    /// without a unit in brackets ("raw ecu value"), which says nothing after a number.
    public var shortUnits: String {
        let text = units.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            let inner = text[text.index(after: open)..<text.index(before: text.endIndex)].trimmingCharacters(in: .whitespaces)
            // A raw value is the ECU's own number: it has no unit to name.
            if inner.lowercased().hasPrefix("raw") { return "" }
            if inner.count <= Self.shortUnitLength { return inner }
            let first = inner.split(separator: " ").first.map(String.init) ?? ""
            return first.count <= Self.shortUnitLength ? first : ""
        }
        return text.count <= Self.shortUnitLength ? text : ""
    }

    /// The longest text that still reads as a unit after a number.
    static let shortUnitLength = 12
}

public struct ROMAxis: Sendable, Equatable {
    public var name: String
    public var storageType: ROMStorageType?
    /// The order of a value's bytes in the ROM. For a float this is not what the definition's `endian`
    /// says: see `ROMDefinitionSet.resolvedTables`.
    public var bigEndian: Bool
    public var address: Int?
    public var size: Int
    public var scalingName: String?
    public var scaling: ROMScaling?
    /// A static axis carries its labels in the definition instead of in the ROM.
    public var staticValues: [Double]?

    public init(name: String = "", storageType: ROMStorageType? = nil, bigEndian: Bool = true, address: Int? = nil,
                size: Int = 1, scalingName: String? = nil, scaling: ROMScaling? = nil, staticValues: [Double]? = nil) {
        self.name = name
        self.storageType = storageType
        self.bigEndian = bigEndian
        self.address = address
        self.size = size
        self.scalingName = scalingName
        self.scaling = scaling
        self.staticValues = staticValues
    }
}

/// One position of a RomRaider switch: its name ("on" or "off") and the bytes the ROM holds at the
/// switch's address when it is in that position.
public struct ROMSwitchState: Sendable, Equatable {
    public var name: String
    public var data: [UInt8]

    public init(name: String, data: [UInt8]) {
        self.name = name
        self.data = data
    }
}

public struct ROMTableDef: Sendable, Equatable {
    /// RomRaider's kinds of table: one number, a row of numbers, a grid of them, and a switch,
    /// which is no number at all but one of a few fixed byte patterns (see `states`).
    public enum Dimension: String, Sendable { case oneD = "1D", twoD = "2D", threeD = "3D", `switch` = "Switch", other = "" }

    /// The grid the map's numbers form in the ROM. A 3D map is `sizeX` columns by `sizeY` rows. A 2D
    /// map is one row. RomRaider's Subaru definitions give its length as `sizey` (every one of the 2D
    /// maps in ecu_defs.xml does), others as `sizex`, so the larger of the two is taken. Anything
    /// else is a single number.
    public var gridSize: (rows: Int, columns: Int) {
        switch dimension {
        case .threeD: return (max(sizeY, 1), max(sizeX, 1))
        case .twoD: return (1, max(sizeX, sizeY, 1))
        case .oneD, .switch, .other: return (1, max(sizeX, 1))
        }
    }

    /// The axis along the columns. A 2D map has one axis, and those definitions call it its Y axis.
    public var columnAxis: ROMAxis? { dimension == .twoD ? (xAxis ?? yAxis) : xAxis }
    /// The axis along the rows. Only a 3D map has one.
    public var rowAxis: ROMAxis? { dimension == .threeD ? yAxis : nil }

    public var name: String
    public var category: String
    public var dimension: Dimension
    public var storageType: ROMStorageType?
    /// The order of a value's bytes in the ROM. For a float this is not what the definition's `endian`
    /// says: see `ROMDefinitionSet.resolvedTables`.
    public var bigEndian: Bool
    public var address: Int?
    public var sizeX: Int
    public var sizeY: Int
    public var scalingName: String?
    public var scaling: ROMScaling?
    public var xAxis: ROMAxis?
    public var yAxis: ROMAxis?
    public var description: String
    /// The positions of a switch, each with its bytes. Empty for a table of numbers.
    public var states: [ROMSwitchState]

    public init(name: String, category: String = "", dimension: Dimension = .other,
                storageType: ROMStorageType? = nil, bigEndian: Bool = true, address: Int? = nil,
                sizeX: Int = 1, sizeY: Int = 1, scalingName: String? = nil, scaling: ROMScaling? = nil,
                xAxis: ROMAxis? = nil, yAxis: ROMAxis? = nil, description: String = "",
                states: [ROMSwitchState] = []) {
        self.name = name
        self.category = category
        self.dimension = dimension
        self.storageType = storageType
        self.bigEndian = bigEndian
        self.address = address
        self.sizeX = sizeX
        self.sizeY = sizeY
        self.scalingName = scalingName
        self.scaling = scaling
        self.xAxis = xAxis
        self.yAxis = yAxis
        self.description = description
        self.states = states
    }

    /// A table can be shown and edited only when it has an address and a numeric storage type.
    public var isEditable: Bool { address != nil && storageType != nil }

    /// A switch whose position can be read from a ROM: it has an address and its positions' bytes.
    public var isSwitch: Bool { dimension == .switch && address != nil && !states.isEmpty }

    /// The position a switch is in: the one whose bytes the ROM holds at the switch's address. Nil
    /// for a table that is no switch, and for bytes that are none of its positions (a ROM that was
    /// edited by hand there, or a definition that does not fit this ROM).
    public func switchState(in rom: ROMImage) -> ROMSwitchState? {
        guard isSwitch, let address else { return nil }
        return states.first { !$0.data.isEmpty && rom.bytes(at: address, length: $0.data.count) == $0.data }
    }
}

public struct ROMIdentity: Sendable, Equatable {
    public var xmlID: String
    public var base: String?
    public var internalIDAddress: Int?
    public var internalIDString: String?
    public var ecuID: String?
    public var make: String?
    public var market: String?
    public var flashMethod: String?
    public var memModel: String?
    /// The byte order of the ROM's processor, when the definition states it (`<memmodel endian="…">`).
    /// RomRaider's Subaru definitions do not: nil then.
    public var memModelBigEndian: Bool?

    public init(xmlID: String, base: String? = nil) {
        self.xmlID = xmlID
        self.base = base
    }
}

public struct ROMDefinition: Sendable, Equatable {
    public var identity: ROMIdentity
    public var tables: [String: ROMTableDef]

    public init(identity: ROMIdentity, tables: [String: ROMTableDef] = [:]) {
        self.identity = identity
        self.tables = tables
    }
}

/// Every ROM definition and shared scaling parsed from one `ecu_defs.xml`.
public struct ROMDefinitionSet: Sendable {
    public var definitions: [String: ROMDefinition]   // keyed by xmlID
    public var scalings: [String: ROMScaling]         // shared scalings, keyed by name

    public init(definitions: [String: ROMDefinition] = [:], scalings: [String: ROMScaling] = [:]) {
        self.definitions = definitions
        self.scalings = scalings
    }

    /// Finds the definition whose internal ID string sits at its internal ID address in this ROM, the
    /// way RomRaider identifies which maps a ROM uses.
    public func definition(matching rom: ROMImage) -> ROMDefinition? {
        for def in definitions.values {
            guard let address = def.identity.internalIDAddress,
                  let marker = def.identity.internalIDString, !marker.isEmpty,
                  let field = rom.bytes(at: address, length: marker.utf8.count) else { continue }
            if field.elementsEqual(marker.utf8) { return def }
        }
        return nil
    }

    /// When there is no exact match, definitions whose internal ID is close to the ROM's calibration ID,
    /// best first, as suggestions for the user to confirm. Never applied automatically.
    public func recommendations(for rom: ROMImage, limit: Int = 6) -> [ROMDefinition] {
        guard let cal = rom.calibrationID() else { return [] }
        func sharedPrefix(_ a: String, _ b: String) -> Int {
            zip(a, b).prefix { $0 == $1 }.count
        }
        return definitions.values
            .filter { $0.identity.internalIDString != nil }
            .map { (def: $0, score: sharedPrefix($0.identity.internalIDString ?? "", cal)) }
            .filter { $0.score >= 3 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.def)
    }

    /// The tables a ROM really has, with everything its base definitions fill in (type, scaling, axes).
    /// RomRaider's concrete ROMs usually list only a table's name and address and inherit the rest.
    public func resolvedTables(forXmlID xmlID: String) -> [ROMTableDef] {
        guard definitions[xmlID] != nil else { return [] }
        // Walk the base chain from the most generic to the most specific, merging as we go.
        var chain: [ROMDefinition] = []
        var current: String? = xmlID
        var guardCount = 0
        while let id = current, let def = definitions[id], guardCount < 32 {
            chain.append(def)
            current = def.identity.base
            guardCount += 1
        }
        chain.reverse()   // base first, concrete last

        // A base like 32BITBASE is a template catalog (no internal ID): it supplies table definitions
        // but a ROM only exposes a table it, or a real ROM in its chain, actually declares.
        var declaredByReal: Set<String> = []
        for def in chain where def.identity.internalIDString != nil {
            declaredByReal.formUnion(def.tables.keys)
        }

        var merged: [String: ROMTableDef] = [:]
        for def in chain {
            for (name, table) in def.tables {
                if var existing = merged[name] {
                    existing.merge(from: table)
                    merged[name] = existing
                } else {
                    merged[name] = table
                }
            }
        }
        // If no real ROM in the chain declared tables (e.g. asking for a template directly), fall back
        // to everything merged, so the template can still be inspected.
        let names = declaredByReal.isEmpty ? Set(merged.keys) : declaredByReal
        // The most specific definition that states the processor's byte order decides it for floats.
        let memModelBigEndian = chain.last { $0.identity.memModelBigEndian != nil }?.identity.memModelBigEndian
        return merged.values.filter { names.contains($0.name) }
            .map { $0.withFloatByteOrder(memModelBigEndian: memModelBigEndian) }
            .sorted { ($0.category, $0.name) < ($1.category, $1.name) }
    }

    /// The byte order of float values, the way RomRaider reads them (`RomAttributeParser.byteToFloat`):
    /// the processor's own order when the definition states it, and big-endian otherwise, whatever
    /// the table's `endian` says. RomRaider's Subaru definitions mark nearly every float table
    /// `endian="little"`, on processors that are big-endian (SH7055, SH7058); RomRaider calls that
    /// "improperly defined float table endian in legacy definition files" and corrects it when
    /// reading, and FastECU reads floats big-endian for the same reason. Taken at its word, the
    /// attribute would turn every float map and axis into noise.
    static func floatsAreBigEndian(memModelBigEndian: Bool?) -> Bool {
        memModelBigEndian ?? true
    }

    /// The scaling for a table or axis: an inline one if present, else the shared one by name.
    public func scaling(for name: String?, inline: ROMScaling?) -> ROMScaling? {
        if let inline { return inline }
        if let name, let shared = scalings[name] { return shared }
        return nil
    }
}

extension ROMTableDef {
    /// The table with the byte order its float values really have (see `ROMDefinitionSet.floatsAreBigEndian`).
    /// Whole numbers keep the order the definition gives them.
    func withFloatByteOrder(memModelBigEndian: Bool?) -> ROMTableDef {
        let floatsBigEndian = ROMDefinitionSet.floatsAreBigEndian(memModelBigEndian: memModelBigEndian)
        var table = self
        if table.storageType == .float { table.bigEndian = floatsBigEndian }
        if table.xAxis?.storageType == .float { table.xAxis?.bigEndian = floatsBigEndian }
        if table.yAxis?.storageType == .float { table.yAxis?.bigEndian = floatsBigEndian }
        return table
    }

    /// Fills empty fields from a more specific definition's table of the same name. The more specific
    /// values (address above all) win; anything it leaves out keeps the base value.
    mutating func merge(from child: ROMTableDef) {
        if child.address != nil { address = child.address }
        if child.storageType != nil { storageType = child.storageType }
        if child.dimension != .other { dimension = child.dimension }
        if child.sizeX != 1 { sizeX = child.sizeX }
        if child.sizeY != 1 { sizeY = child.sizeY }
        if !child.category.isEmpty { category = child.category }
        if child.scaling != nil { scaling = child.scaling }
        if child.scalingName != nil { scalingName = child.scalingName }
        if child.xAxis != nil { xAxis = mergeAxis(xAxis, child.xAxis!) }
        if child.yAxis != nil { yAxis = mergeAxis(yAxis, child.yAxis!) }
        if !child.description.isEmpty { description = child.description }
        if !child.states.isEmpty { states = child.states }
        // Endian is big by default; only a child that states little overrides.
        if !child.bigEndian { bigEndian = false }
    }

    private func mergeAxis(_ base: ROMAxis?, _ child: ROMAxis) -> ROMAxis {
        guard var result = base else { return child }
        if !child.name.isEmpty { result.name = child.name }
        if child.storageType != nil { result.storageType = child.storageType }
        if child.address != nil { result.address = child.address }
        if child.size != 1 { result.size = child.size }
        if child.scaling != nil { result.scaling = child.scaling }
        if child.scalingName != nil { result.scalingName = child.scalingName }
        if child.staticValues != nil { result.staticValues = child.staticValues }
        if !child.bigEndian { result.bigEndian = false }
        return result
    }
}
