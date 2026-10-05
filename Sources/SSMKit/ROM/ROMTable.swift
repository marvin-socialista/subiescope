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

        // The main data grid. 3D is sizeX columns by sizeY rows; 2D is one row of sizeX; 1D is a single cell.
        let columns = max(def.sizeX, 1)
        let rows = def.dimension == .threeD ? max(def.sizeY, 1) : 1
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

        let (xLabels, xUnits) = axisLabels(def.xAxis, count: columns, rom: rom, scalings: scalings)
        let (yLabels, yUnits) = axisLabels(def.yAxis, count: rows, rom: rom, scalings: scalings)

        return ROMTable(def: def, scaling: scaling, xLabels: xLabels, yLabels: yLabels,
                        xUnits: xUnits, yUnits: yUnits, values: grid)
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
        guard let storage = def.storageType, let address = def.address else { throw TableError.notEditable }
        guard scaling.isWritable else { throw TableError.notWritable }
        guard row >= 0, row < rows, column >= 0, column < columns else { throw TableError.outOfRange }
        let toByte = try Self.compile(scaling.toByte, fallback: "x")
        let raw = toByte.evaluate(x: realValue)
        guard raw.isFinite else { throw TableError.badFormula(scaling.toByte) }
        let index = row * columns + column
        let offset = address + index * storage.byteCount
        var edited = rom
        guard edited.replace(at: offset, with: storage.bytes(forRaw: raw, bigEndian: def.bigEndian)) else {
            throw TableError.outOfRange
        }
        return edited
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
