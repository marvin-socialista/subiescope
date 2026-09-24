import Foundation

/// A recorded log in RomRaider's CSV layout: a time column followed by
/// "Name (units)" columns. Also reads logs written by RomRaider on systems with a
/// Dutch/German locale (";" separator, decimal comma) and logs with absolute
/// "HH:mm:ss.SSS" timestamps.
public struct RecordedLog: Sendable {
    public struct Column: Sendable, Hashable {
        public var header: String
        public var name: String
        public var units: String
    }

    public var columns: [Column]
    /// Seconds since the first row.
    public var time: [Double]
    /// values[column][row]; NaN where a cell was empty.
    public var values: [[Double]]

    public var duration: Double { time.last ?? 0 }
    public var rowCount: Int { time.count }

    /// Index of the last row at or before `t` (binary search).
    public func row(at t: Double) -> Int {
        guard !time.isEmpty else { return 0 }
        var lo = 0, hi = time.count - 1
        if t <= time[0] { return 0 }
        if t >= time[hi] { return hi }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if time[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    public static func load(_ url: URL) throws -> RecordedLog {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        return parse(text)
    }

    public static func parse(_ text: String) -> RecordedLog {
        var lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return RecordedLog(columns: [], time: [], values: []) }
        let headerLine = lines.removeFirst()
        let separator: Character = headerLine.contains(";") && !headerLine.contains(",") ? ";" : ","
        let decimalComma = separator == ";"
        let header = split(headerLine, separator)
        let columns = header.dropFirst().map(parseHeader)

        var time: [Double] = []
        var values = Array(repeating: [Double](), count: columns.count)
        var firstAbsolute: Double?
        for line in lines {
            let fields = split(line, separator)
            guard let first = fields.first else { continue }
            let t: Double
            if let ms = number(first, decimalComma: decimalComma) {
                t = ms / 1000
            } else if let clock = clockSeconds(first) {
                if firstAbsolute == nil { firstAbsolute = clock }
                var delta = clock - firstAbsolute!
                if delta < 0 { delta += 86_400 }   // log ran past midnight
                t = delta
            } else {
                continue   // RomRaider repeats the header row when parameters change
            }
            time.append(t)
            for i in columns.indices {
                let v = i + 1 < fields.count ? number(fields[i + 1], decimalComma: decimalComma) : nil
                values[i].append(v ?? .nan)
            }
        }
        // Time (msec) counts from the first row, but be safe with logs that do not.
        if let t0 = time.first, t0 != 0 { time = time.map { $0 - t0 } }
        return RecordedLog(columns: columns, time: time, values: values)
    }

    /// "Engine Speed (rpm)" -> ("Engine Speed", "rpm"); "IAM (4-byte)* (multiplier)" -> ("IAM (4-byte)*", "multiplier")
    static func parseHeader(_ header: String) -> Column {
        let h = header.trimmingCharacters(in: .whitespaces)
        guard h.hasSuffix(")"), let open = h.lastIndex(of: "(") else {
            return Column(header: h, name: h, units: "")
        }
        let name = h[..<open].trimmingCharacters(in: .whitespaces)
        let units = String(h[h.index(after: open)..<h.index(before: h.endIndex)])
        return Column(header: h, name: name.isEmpty ? h : name, units: units)
    }

    static func number(_ field: String, decimalComma: Bool) -> Double? {
        var f = field.trimmingCharacters(in: .whitespaces)
        if f.isEmpty { return nil }
        if decimalComma { f = f.replacingOccurrences(of: ",", with: ".") }
        return Double(f)
    }

    /// "21:45:03.125" -> seconds since midnight
    static func clockSeconds(_ field: String) -> Double? {
        let parts = field.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]),
              let s = Double(parts[2].replacingOccurrences(of: ",", with: ".")) else { return nil }
        return h * 3600 + m * 60 + s
    }

    static func split(_ line: String, _ separator: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        for c in line {
            if c == "\"" { quoted.toggle() }
            else if c == separator && !quoted { fields.append(current); current = "" }
            else { current.append(c) }
        }
        fields.append(current)
        return fields
    }
}
