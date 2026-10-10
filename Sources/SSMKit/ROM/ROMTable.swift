import Foundation

/// Reads a table's real-world values out of a ROM and writes an edited value back. This is where a
/// resolved `ROMTableDef`, the ROM bytes and the scaling formulas meet. It works entirely on the
/// in-memory `ROMImage`; nothing here touches a car.
public struct ROMTable: Sendable {
    public let def: ROMTableDef
    public let scaling: ROMScaling
    /// Column headers (X axis) and row headers (Y axis) as real values, when the table has axes.
    public let xLabels: [Double]
    public let yLabels: [Double]
    public let xUnits: String
    public let yUnits: String
    /// How each axis writes its labels. Nil for an axis that is not stored in the ROM (a static one, or none).
    public let xScaling: ROMScaling?
    public let yScaling: ROMScaling?
    /// The cell values, `rows` (Y) by `columns` (X), already scaled to real-world units.
    public let values: [[Double]]

    public var rows: Int { values.count }
    public var columns: Int { values.first?.count ?? 0 }
    public var units: String { scaling.units }
    public var format: String { scaling.format }

    public enum TableError: Error, LocalizedError {
        case notEditable
        case badFormula(String)
        case outOfRange
        case notWritable
        public var errorDescription: String? {
            switch self {
            case .notEditable: return "This table has no address or numeric type in the definition, so it can't be shown."
            case .badFormula(let f): return "The scaling formula could not be read: \(f)"
            case .outOfRange: return "The table runs past the end of the ROM; the definition may not match this ROM."
            case .notWritable: return "This table has no real-to-byte formula, so its values can't be edited."
            }
        }
    }

    // MARK: Reading

    /// Builds a readable table from a ROM. `scalings` supplies shared scalings referenced by name.
    public static func read(_ rom: ROMImage, def: ROMTableDef, scalings: [String: ROMScaling]) throws -> ROMTable {
        guard let storage = def.storageType, let address = def.address else { throw TableError.notEditable }
        let scaling = resolveScaling(def.scaling, def.scalingName, scalings) ?? ROMScaling()
        let toReal = try compile(scaling.expression, fallback: "x")

        // The main data grid. 3D is sizeX columns by sizeY rows; 2D is one row; 1D is a single cell.
        let (rows, columns) = def.gridSize
        var grid: [[Double]] = []
        let step = storage.byteCount
        for r in 0..<rows {
            var row: [Double] = []
            for c in 0..<columns {
                let index = (r * columns + c)
                let offset = address + index * step
                guard let raw = storage.readRaw(rom.data, at: offset, bigEndian: def.bigEndian) else { throw TableError.outOfRange }
                row.append(toReal.evaluate(x: raw))
            }
            grid.append(row)
        }

        let (xLabels, xUnits) = axisLabels(def.columnAxis, count: columns, rom: rom, scalings: scalings)
        let (yLabels, yUnits) = axisLabels(def.rowAxis, count: rows, rom: rom, scalings: scalings)

        return ROMTable(def: def, scaling: scaling, xLabels: xLabels, yLabels: yLabels,
                        xUnits: xUnits, yUnits: yUnits,
                        xScaling: storedScaling(def.columnAxis, scalings), yScaling: storedScaling(def.rowAxis, scalings),
                        values: grid)
    }

    /// The scaling of an axis whose labels are read from the ROM. Nil for a static axis and for none.
    static func storedScaling(_ axis: ROMAxis?, _ scalings: [String: ROMScaling]) -> ROMScaling? {
        guard let axis, axis.staticValues?.isEmpty ?? true, axis.storageType != nil, axis.address != nil else { return nil }
        return resolveScaling(axis.scaling, axis.scalingName, scalings) ?? ROMScaling()
    }

    static func axisLabels(_ axis: ROMAxis?, count: Int, rom: ROMImage, scalings: [String: ROMScaling]) -> ([Double], String) {
        guard let axis else { return ((0..<count).map { Double($0) }, "") }
        if let statics = axis.staticValues, !statics.isEmpty { return (statics, "") }
        guard let storage = axis.storageType, let address = axis.address else {
            return ((0..<count).map { Double($0) }, "")
        }
        let scaling = resolveScaling(axis.scaling, axis.scalingName, scalings) ?? ROMScaling()
        let toReal = (try? compile(scaling.expression, fallback: "x")) ?? (try! Expression("x"))
        var labels: [Double] = []
        let n = axis.size > 1 ? axis.size : count
        for i in 0..<n {
            guard let raw = storage.readRaw(rom.data, at: address + i * storage.byteCount, bigEndian: axis.bigEndian) else { break }
            labels.append(toReal.evaluate(x: raw))
        }
        return (labels, scaling.units)
    }

    // MARK: Writing

    /// Returns a copy of the ROM with the cell at (row, column) set to the real value `newValue`. The
    /// value is run back through the scaling's real-to-byte formula, clamped to the storage range, and
    /// written. The ROM's checksums are NOT corrected here: do that explicitly after editing.
    public func write(_ rom: ROMImage, row: Int, column: Int, realValue: Double) throws -> ROMImage {
        try write(rom, cells: [Cell(row: row, column: column)], change: .set(realValue))
    }

    /// One cell of a map: its row and its column, counted from 0.
    public struct Cell: Hashable, Sendable {
        public let row: Int
        public let column: Int

        public init(row: Int, column: Int) {
            self.row = row
            self.column = column
        }
    }

    /// A change made to several cells at once, the way RomRaider's toolbar does it.
    public enum Change: Sendable, Equatable {
        /// Adds this to each cell, in real units. A negative step lowers them.
        case step(Double)
        /// Gives every cell this real value.
        case set(Double)
        /// Multiplies each cell by this.
        case multiply(Double)
    }

    /// Returns a copy of the ROM with `change` made to each of `cells`. Each cell starts from what
    /// `rom` holds for it now, so a step or a factor works on the newest bytes. Every new value is
    /// clamped to what the storage type can hold, as a single cell's is. A map without a
    /// real-to-byte formula is read-only and refuses with `notWritable`, and a cell outside the map
    /// refuses the whole change: the ROM that was passed in is never half edited.
    ///
    /// A step always moves a cell, as it does in RomRaider: a step smaller than the smallest amount
    /// the cell can hold moves it by that smallest amount, in the direction that was asked for.
    public func write(_ rom: ROMImage, cells: [Cell], change: Change) throws -> ROMImage {
        guard let storage = def.storageType, let address = def.address else { throw TableError.notEditable }
        guard scaling.isWritable else { throw TableError.notWritable }
        guard cells.allSatisfy({ $0.row >= 0 && $0.row < rows && $0.column >= 0 && $0.column < columns }) else {
            throw TableError.outOfRange
        }
        let toByte = try Self.compile(scaling.toByte, fallback: "x")
        let toReal = try Self.compile(scaling.expression, fallback: "x")
        var edited = rom
        for cell in cells {
            let offset = address + (cell.row * columns + cell.column) * storage.byteCount
            guard let stored = storage.readRaw(edited.data, at: offset, bigEndian: def.bigEndian) else { throw TableError.outOfRange }
            let real = toReal.evaluate(x: stored)
            var raw: Double
            switch change {
            case .set(let value):
                raw = toByte.evaluate(x: value)
            case .multiply(let factor):
                raw = toByte.evaluate(x: real * factor)
            case .step(let step):
                raw = toByte.evaluate(x: real + step)
                // A whole number that rounds back to what is stored would not have moved at all.
                if storage != .float, step != 0, raw.isFinite, raw.rounded() == stored {
                    // Most scalings rise with the stored number. Some fall (an air/fuel ratio).
                    let rises = toReal.evaluate(x: stored + 1) >= real
                    raw = stored + ((step > 0) == rises ? 1 : -1)
                }
            }
            guard raw.isFinite else { throw TableError.badFormula(scaling.toByte) }
            guard edited.replace(at: offset, with: storage.bytes(forRaw: raw, bigEndian: def.bigEndian)) else {
                throw TableError.outOfRange
            }
        }
        return edited
    }

    // MARK: Where a cell is

    /// Where the ROM keeps a cell: the offset of its first byte in the file. Nil for a cell outside
    /// the map, and for a map without an address or a numeric type.
    public func offset(row: Int, column: Int) -> Int? {
        guard let storage = def.storageType, let address = def.address,
              row >= 0, row < rows, column >= 0, column < columns else { return nil }
        return address + (row * columns + column) * storage.byteCount
    }

    /// The bytes a cell is stored as in `rom`, in the order they are in the file.
    public func storedBytes(in rom: ROMImage, row: Int, column: Int) -> [UInt8]? {
        guard let storage = def.storageType, let offset = offset(row: row, column: column) else { return nil }
        return rom.bytes(at: offset, length: storage.byteCount)
    }

    /// The map's name without the spaces RomRaider's definitions leave around some of them ("Target Boost ").
    public var title: String { def.name.trimmingCharacters(in: .whitespaces) }

    /// What stands above the columns: "Requested Torque (raw ecu value)". Nil for a map without a column axis.
    public var columnTitle: String? { Self.axisTitle(def.columnAxis, units: xUnits) }
    /// What stands beside the rows: "Engine Speed (RPM)". Nil for a map without a row axis.
    public var rowTitle: String? { Self.axisTitle(def.rowAxis, units: yUnits) }

    /// The label of each column and of each row, as the axis itself writes its numbers.
    public var columnLabels: [String] { Self.labelTexts(Array(xLabels.prefix(columns)), xScaling) }
    public var rowLabels: [String] { Self.labelTexts(Array(yLabels.prefix(rows)), yScaling) }

    /// Where a cell is, in the words of the axes: "4000 RPM × 410" in a map with rows and columns,
    /// "104 Degrees F" in a map of one row, and "Value" for a map that is one number. A map without
    /// an axis counts instead: "Row 2, column 3".
    public func place(row: Int, column: Int) -> String {
        let columnText = def.columnAxis == nil ? nil : Self.labelText(at: column, columnLabels, xScaling)
        let rowText = def.rowAxis == nil ? nil : Self.labelText(at: row, rowLabels, yScaling)
        if rows > 1 {
            if let rowText, let columnText { return "\(rowText) × \(columnText)" }
            return "Row \(row + 1), column \(column + 1)"
        }
        if columns > 1 { return columnText ?? "Column \(column + 1)" }
        return "Value"
    }

    /// An axis's name with its unit: "Engine Speed (RPM)". A unit that says the name already is used alone.
    static func axisTitle(_ axis: ROMAxis?, units: String) -> String? {
        guard let axis else { return nil }
        let name = axis.name.trimmingCharacters(in: .whitespaces)
        let units = units.trimmingCharacters(in: .whitespaces)
        if units.isEmpty { return name.isEmpty ? nil : name }
        if name.isEmpty || units.lowercased().hasPrefix(name.lowercased()) { return units }
        return "\(name) (\(units))"
    }

    /// Axis labels as text. They get the decimals of the axis's format, and none at all when every
    /// label is a whole number: "410", not "410.0". A static axis has no format, so it shows up to two.
    static func labelTexts(_ labels: [Double], _ scaling: ROMScaling?) -> [String] {
        let whole = labels.allSatisfy { $0.isFinite && $0 == $0.rounded() }
        let decimals = whole ? 0 : (scaling?.decimals ?? 2)
        return labels.map { String(format: "%.\(decimals)f", $0) }
    }

    /// One label with its unit, when that is short enough to read as one: "4000 RPM".
    static func labelText(at index: Int, _ texts: [String], _ scaling: ROMScaling?) -> String? {
        guard index >= 0, index < texts.count else { return nil }
        let units = scaling?.shortUnits ?? ""
        return units.isEmpty ? texts[index] : "\(texts[index]) \(units)"
    }

    // MARK: Helpers

    static func resolveScaling(_ inline: ROMScaling?, _ name: String?, _ scalings: [String: ROMScaling]) -> ROMScaling? {
        if let inline { return inline }
        if let name, let shared = scalings[name] { return shared }
        return nil
    }

    static func compile(_ formula: String, fallback: String) throws -> Expression {
        let f = formula.trimmingCharacters(in: .whitespaces)
        do { return try Expression(f.isEmpty ? fallback : f) }
        catch { throw TableError.badFormula(formula) }
    }
}
