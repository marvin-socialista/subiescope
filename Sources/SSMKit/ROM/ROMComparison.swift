import Foundation

/// What is not the same in two ROMs of one size: the maps that differ, number by number, and how many
/// bytes differ in all and outside every map. The editor uses it twice: for what changed since a ROM
/// was opened (the ROM as it was then against the ROM now), and for holding the open ROM against
/// another file. It only reads. Neither ROM is changed, and nothing here touches a car.
///
/// The maps come from the RomRaider definition in use (`ROMDefinitionSet.resolvedTables`). Without
/// one no map is known, and every byte that differs counts as outside the maps.
public struct ROMComparison: Sendable, Equatable {
    /// One number of a map that differs, as the real (scaled) value each ROM holds.
    public struct Cell: Sendable, Equatable {
        public let row: Int
        public let column: Int
        public let first: Double
        public let second: Double
    }

    /// One label on an axis that differs. `index` counts along the axis from 0.
    public struct Label: Sendable, Equatable {
        public let index: Int
        public let first: Double
        public let second: Double
    }

    /// The labels along one side of a map that differ. Only an axis that is stored in the ROM can:
    /// a static axis has its labels in the definition.
    public struct Axis: Sendable, Equatable {
        /// "Engine Speed axis", or "Column axis" and "Row axis" for an axis without a name.
        public let name: String
        public let scaling: ROMScaling
        public let labels: [Label]
    }

    /// A map that differs, with every cell and axis label that does.
    public struct Map: Sendable, Equatable {
        public let name: String
        public let category: String
        public let scaling: ROMScaling
        public let rows: Int
        public let columns: Int
        /// The cells that differ, row by row.
        public let cells: [Cell]
        public let xAxis: Axis?
        public let yAxis: Axis?
    }

    /// One difference as a card shows it: where it is, and what each ROM holds there.
    public struct Line: Sendable, Equatable {
        /// "Row 2, column 3"
        public let place: String
        public let first: String
        public let second: String
        /// "ms". Empty for a number without a unit.
        public let units: String
    }

    public enum CompareError: Error, LocalizedError, Equatable {
        case differentSizes(first: Int, second: Int)
        public var errorDescription: String? {
            switch self {
            case .differentSizes(let first, let second):
                return "These two ROMs are not the same size (\(first) and \(second) bytes), so they can't be compared. They are probably for different ECUs."
            }
        }
    }

    /// The maps that differ, in the order of the definition's tables.
    public let maps: [Map]
    /// How many bytes differ in the whole ROM.
    public let differingBytes: Int
    /// How many of those are in no map that could be read: code, data the definition has no table
    /// for, and the checksums.
    public let bytesOutsideMaps: Int
    /// How many of the bytes outside the maps are in the checksum table. Correcting the checksums
    /// changes these and nothing else.
    public let checksumBytes: Int
    /// False when the comparison was made without any table, so no byte could be put in a map.
    public let mapsKnown: Bool
    /// The calibration ID of each ROM, for telling a person that the two are not the same calibration.
    public let firstCalibrationID: String?
    public let secondCalibrationID: String?

    public var isIdentical: Bool { differingBytes == 0 }

    /// Compares `first` with `second`. `tables` are the maps to look in, already resolved, and
    /// `scalings` the shared scalings they refer to by name: the same two things `ROMTable.read`
    /// takes. Throws `CompareError.differentSizes` for two ROMs that are not the same size.
    public init(_ first: ROMImage, _ second: ROMImage, tables: [ROMTableDef] = [], scalings: [String: ROMScaling] = [:]) throws {
        guard let differing = first.differingRanges(from: second) else {
            throw CompareError.differentSizes(first: first.byteCount, second: second.byteCount)
        }
        var maps: [Map] = []
        var covered: [Range<Int>] = []
        if !differing.isEmpty {
            for def in tables {
                // Reading a map costs a formula and every cell, and a ROM has a few hundred of them:
                // only a map with a byte that differs is read.
                let stored = def.storedRanges
                guard stored.contains(where: { Self.overlap($0, differing) }),
                      let one = try? ROMTable.read(first, def: def, scalings: scalings),
                      let other = try? ROMTable.read(second, def: def, scalings: scalings),
                      let storage = def.storageType, let address = def.address else { continue }
                var cells: [Cell] = []
                for row in 0..<one.rows {
                    for column in 0..<one.columns {
                        let offset = address + (row * one.columns + column) * storage.byteCount
                        guard Self.overlap(offset..<(offset + storage.byteCount), differing) else { continue }
                        cells.append(Cell(row: row, column: column, first: one.values[row][column], second: other.values[row][column]))
                    }
                }
                let xAxis = Self.axis(def.columnAxis, fallbackName: "Column axis", one.xLabels, other.xLabels, differing, scalings)
                let yAxis = Self.axis(def.rowAxis, fallbackName: "Row axis", one.yLabels, other.yLabels, differing, scalings)
                guard !cells.isEmpty || xAxis != nil || yAxis != nil else { continue }
                maps.append(Map(name: def.name, category: def.category, scaling: one.scaling, rows: one.rows, columns: one.columns,
                                cells: cells, xAxis: xAxis, yAxis: yAxis))
                covered += stored
            }
        }
        let total = differing.reduce(0) { $0 + $1.count }
        let outside = total - Self.count(of: differing, inside: Self.merged(covered))
        var inChecksums = 0
        if let size = first.size, let layout = SubaruChecksum.Layout.petrol(for: size) {
            let table = layout.tableStart..<(layout.tableStart + layout.recordCount * 12)
            inChecksums = min(outside, Self.count(of: differing, inside: [table]))
        }
        self.maps = maps
        self.differingBytes = total
        self.bytesOutsideMaps = outside
        self.checksumBytes = inChecksums
        self.mapsKnown = !tables.isEmpty
        self.firstCalibrationID = first.calibrationID()
        self.secondCalibrationID = second.calibrationID()
    }

    // MARK: In words

    /// What to say about the bytes that differ outside the maps, or nil when there are none.
    /// Worded to stand under a list of maps, and to stand alone when no map differs.
    public var otherBytesText: String? {
        guard bytesOutsideMaps > 0 else { return nil }
        let bytes = Self.counted(bytesOutsideMaps, maps.isEmpty ? "byte" : "more byte")
        let differ = bytesOutsideMaps == 1 ? "is different" : "are different"
        if checksumBytes == bytesOutsideMaps { return "\(bytes) \(differ), \(bytesOutsideMaps == 1 ? "" : "all ")in the checksums." }
        guard mapsKnown else {
            return "\(bytes) \(differ). With definitions that match this ROM, SubieScope can tell which maps they are in."
        }
        let inChecksums = checksumBytes > 0 ? ", \(checksumBytes) of them in the checksums" : ""
        return "\(bytes) \(differ) in places the definitions have no map for\(inChecksums)."
    }

    /// A warning for two ROMs that are not the same calibration: a definition says where the maps of
    /// one calibration are, and another calibration keeps them elsewhere. Nil when they are the same.
    public var otherCalibrationText: String? {
        guard firstCalibrationID != secondCalibrationID else { return nil }
        let other = secondCalibrationID.map { "The other ROM is a different calibration (\($0))." }
            ?? "The other ROM has no calibration ID that SubieScope can read."
        return "\(other) Its maps may sit in other places, so the numbers shown for it can be wrong."
    }

    /// "1 cell", "12 cells"
    static func counted(_ count: Int, _ thing: String) -> String {
        "\(count) \(thing)\(count == 1 ? "" : "s")"
    }

    // MARK: Helpers

    /// The axis as far as it differs, or nil for an axis that is the same in both ROMs or is not stored in them.
    static func axis(_ axis: ROMAxis?, fallbackName: String, _ one: [Double], _ other: [Double],
                     _ differing: [Range<Int>], _ scalings: [String: ROMScaling]) -> Axis? {
        guard let axis, axis.staticValues?.isEmpty ?? true, let storage = axis.storageType, let address = axis.address else { return nil }
        var labels: [Label] = []
        for index in 0..<min(one.count, other.count) {
            let offset = address + index * storage.byteCount
            guard overlap(offset..<(offset + storage.byteCount), differing) else { continue }
            labels.append(Label(index: index, first: one[index], second: other[index]))
        }
        guard !labels.isEmpty else { return nil }
        return Axis(name: axis.name.isEmpty ? fallbackName : "\(axis.name) axis",
                    scaling: ROMTable.resolveScaling(axis.scaling, axis.scalingName, scalings) ?? ROMScaling(), labels: labels)
    }

    /// Whether `range` has a byte in any of `ranges`, which are in order and apart from each other.
    static func overlap(_ range: Range<Int>, _ ranges: [Range<Int>]) -> Bool {
        // The first of them that ends after the range starts is the only one that can reach into it.
        var low = 0, high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if ranges[middle].upperBound <= range.lowerBound { low = middle + 1 } else { high = middle }
        }
        return low < ranges.count && ranges[low].lowerBound < range.upperBound
    }

    /// The same ranges in order, with those that overlap or touch made into one.
    static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// How many bytes of `ranges` lie inside `covers`. Both are in order, with no two of one list overlapping.
    static func count(of ranges: [Range<Int>], inside covers: [Range<Int>]) -> Int {
        var total = 0
        var start = 0
        for cover in covers {
            while start < ranges.count, ranges[start].upperBound <= cover.lowerBound { start += 1 }
            var index = start
            while index < ranges.count, ranges[index].lowerBound < cover.upperBound {
                total += min(ranges[index].upperBound, cover.upperBound) - max(ranges[index].lowerBound, cover.lowerBound)
                index += 1
            }
        }
        return total
    }
}

extension ROMComparison.Map {
    /// How much of the map differs: "2 cells", "1 cell and 3 axis values".
    public var summary: String {
        let labels = (xAxis?.labels.count ?? 0) + (yAxis?.labels.count ?? 0)
        var parts: [String] = []
        if !cells.isEmpty { parts.append(ROMComparison.counted(cells.count, "cell")) }
        if labels > 0 { parts.append(ROMComparison.counted(labels, "axis value")) }
        return parts.joined(separator: " and ")
    }

    /// Where a cell is, the way the editor counts: "Row 2, column 3". A map of one row has columns
    /// only, and a map of one number has neither.
    public func place(of cell: ROMComparison.Cell) -> String {
        if rows > 1 { return "Row \(cell.row + 1), column \(cell.column + 1)" }
        if columns > 1 { return "Column \(cell.column + 1)" }
        return "Value"
    }

    /// Every difference in the map as a line to show: the cells first, then the axes.
    public var lines: [ROMComparison.Line] {
        var lines = cells.map {
            ROMComparison.Line(place: place(of: $0), first: scaling.text($0.first), second: scaling.text($0.second), units: scaling.units)
        }
        for axis in [xAxis, yAxis] {
            guard let axis else { continue }
            lines += axis.labels.map {
                ROMComparison.Line(place: "\(axis.name), value \($0.index + 1)", first: axis.scaling.text($0.first),
                                   second: axis.scaling.text($0.second), units: axis.scaling.units)
            }
        }
        return lines
    }
}

extension ROMTableDef {
    /// Where the ROM keeps this map: its numbers, laid out the way `ROMTable.read` reads them, and
    /// each axis that is stored in the ROM. Empty for a table without an address or a numeric type.
    var storedRanges: [Range<Int>] {
        guard let storage = storageType, let address, address >= 0 else { return [] }
        let (rows, columns) = gridSize
        var ranges = [address..<(address + rows * columns * storage.byteCount)]
        for (axis, count) in [(columnAxis, columns), (rowAxis, rows)] {
            guard let axis, axis.staticValues?.isEmpty ?? true, let storage = axis.storageType,
                  let address = axis.address, address >= 0 else { continue }
            ranges.append(address..<(address + (axis.size > 1 ? axis.size : count) * storage.byteCount))
        }
        return ranges
    }
}

extension ROMImage {
    /// The stretches of bytes that are not the same in `other`, in order. Nil for two ROMs of
    /// different sizes, which have no byte for byte comparison.
    func differingRanges(from other: ROMImage) -> [Range<Int>]? {
        guard data.count == other.data.count else { return nil }
        // A ROM and a copy of it that was never edited still share their bytes, and are equal at once.
        if data == other.data { return [] }
        return data.withUnsafeBufferPointer { mine in
            other.data.withUnsafeBufferPointer { theirs in
                var ranges: [Range<Int>] = []
                var start: Int?
                for index in 0..<mine.count {
                    if mine[index] != theirs[index] {
                        if start == nil { start = index }
                    } else if let from = start {
                        ranges.append(from..<index)
                        start = nil
                    }
                }
                if let from = start { ranges.append(from..<mine.count) }
                return ranges
            }
        }
    }
}
