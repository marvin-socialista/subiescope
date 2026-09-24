import Foundation

/// Samples keyed by recipe probe (e.g. "rpm", "lambda"), in canonical units.
public struct DataSet: Sendable {
    public struct Row: Sendable {
        public var t: Double
        public var v: [String: Double]

        public init(t: Double, v: [String: Double]) {
            self.t = t
            self.v = v
        }

        public subscript(_ key: String) -> Double? {
            guard let x = v[key], x.isFinite else { return nil }
            return x
        }
    }

    public var rows: [Row]

    public init(rows: [Row] = []) {
        self.rows = rows
    }

    public var isEmpty: Bool { rows.isEmpty }
    public var count: Int { rows.count }
    public var duration: Double { (rows.last?.t ?? 0) - (rows.first?.t ?? 0) }

    public func has(_ key: String) -> Bool { rows.contains { $0[key] != nil } }

    public func values(_ key: String) -> [Double] { rows.compactMap { $0[key] } }

    public func filter(_ predicate: (Row) -> Bool) -> DataSet { DataSet(rows: rows.filter(predicate)) }

    public func mean(_ key: String) -> Double? { Stats.mean(values(key)) }
    public func min(_ key: String) -> Double? { values(key).min() }
    public func max(_ key: String) -> Double? { values(key).max() }
    public func std(_ key: String) -> Double? { Stats.std(values(key)) }
    public func range(_ key: String) -> Double? {
        guard let lo = min(key), let hi = max(key) else { return nil }
        return hi - lo
    }

    /// How often the value crosses `level` (either direction).
    public func crossings(_ key: String, level: Double, hysteresis: Double = 0) -> Int {
        var count = 0
        var above: Bool?
        for x in values(key) {
            if x > level + hysteresis {
                if above == false { count += 1 }
                above = true
            } else if x < level - hysteresis {
                if above == true { count += 1 }
                above = false
            }
        }
        return count
    }

    /// Increase of a counter (e.g. misfire counts), ignoring resets.
    public func increase(_ key: String) -> Double? {
        let v = values(key)
        guard v.count > 1 else { return nil }
        var total = 0.0
        for i in 1..<v.count where v[i] > v[i - 1] { total += v[i] - v[i - 1] }
        return total
    }

    /// Splits into continuous segments where `predicate` holds (gaps > `gap` seconds end a segment).
    public func segments(minDuration: Double = 0, gap: Double = 1.0, where predicate: (Row) -> Bool) -> [DataSet] {
        var result: [DataSet] = []
        var current: [Row] = []
        for row in rows {
            if predicate(row), current.isEmpty || row.t - current.last!.t <= gap {
                current.append(row)
            } else {
                if !current.isEmpty { result.append(DataSet(rows: current)) }
                current = predicate(row) ? [row] : []
            }
        }
        if !current.isEmpty { result.append(DataSet(rows: current)) }
        return result.filter { $0.duration >= minDuration }
    }
}

public enum Stats {
    public static func mean(_ v: [Double]) -> Double? {
        v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    public static func std(_ v: [Double]) -> Double? {
        guard v.count > 1, let m = mean(v) else { return nil }
        return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count - 1)).squareRoot()
    }

    public static func percentile(_ v: [Double], _ p: Double) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        let i = Swift.min(s.count - 1, Swift.max(0, Int((Double(s.count - 1) * p).rounded())))
        return s[i]
    }
}

/// Converts between the unit spellings used in RomRaider definitions so recipes
/// can judge a log recorded in °F, psi or AFR the same way as a metric one.
public enum UnitNormalizer {
    public static let standardAtmosphere = 101.325

    /// Converts `value` in `from` units to `to` units, or nil if unknown.
    public static func convert(_ value: Double, from: String, to: String) -> Double? {
        let f = from.lowercased().trimmingCharacters(in: .whitespaces)
        let t = to.lowercased().trimmingCharacters(in: .whitespaces)
        if f == t { return value }
        if let si = toCanonical(value, f), let out = fromCanonical(si.value, si.kind, t) { return out }
        return nil
    }

    private enum Kind { case temperature, pressureRelative, pressureAbsolute, pressure, lambda, speed, flow }

    /// Temperature in °C, pressure in kPa, lambda, speed in km/h, flow in g/s.
    private static func toCanonical(_ v: Double, _ u: String) -> (value: Double, kind: Kind)? {
        switch u {
        case "c", "°c": return (v, .temperature)
        case "f", "°f": return ((v - 32) * 5 / 9, .temperature)
        case "lambda": return (v, .lambda)
        case "afr", "estimated afr": return (v / 14.7, .lambda)
        case "fuel-air equivalence ratio": return (v == 0 ? .nan : 1 / v, .lambda)
        case "km/h", "kph": return (v, .speed)
        case "mph": return (v * 1.609344, .speed)
        case "g/s": return (v, .flow)
        case "lb/min", "lbs/min": return (v * 7.5599, .flow)
        default: break
        }
        // Pressures: "kPa", "kPa relative", "psi absolute", "psi relative sea level", "bar", "hPa", "mmHg", "inHg"
        let scale: Double
        if u.hasPrefix("kpa") { scale = 1 }
        else if u.hasPrefix("hpa") { scale = 0.1 }
        else if u.hasPrefix("bar") { scale = 100 }
        else if u.hasPrefix("psi") { scale = 6.894757 }
        else if u.hasPrefix("mmhg") { scale = 0.1333224 }
        else if u.hasPrefix("inhg") { scale = 3.386389 }
        else { return nil }
        let kPa = v * scale
        if u.contains("absolute") { return (kPa, .pressureAbsolute) }
        if u.contains("relative") { return (kPa, .pressureRelative) }
        return (kPa, .pressure)
    }

    private static func fromCanonical(_ v: Double, _ kind: Kind, _ u: String) -> Double? {
        switch kind {
        case .temperature:
            if u == "c" || u == "°c" { return v }
            if u == "f" || u == "°f" { return v * 9 / 5 + 32 }
            return nil
        case .lambda:
            if u == "lambda" { return v }
            if u == "afr" || u == "estimated afr" { return v * 14.7 }
            return nil
        case .speed:
            if u == "km/h" || u == "kph" { return v }
            if u == "mph" { return v / 1.609344 }
            return nil
        case .flow:
            if u == "g/s" { return v }
            if u == "lb/min" || u == "lbs/min" { return v / 7.5599 }
            return nil
        case .pressure, .pressureRelative, .pressureAbsolute:
            let scale: Double
            if u.hasPrefix("kpa") { scale = 1 }
            else if u.hasPrefix("hpa") { scale = 0.1 }
            else if u.hasPrefix("bar") { scale = 100 }
            else if u.hasPrefix("psi") { scale = 6.894757 }
            else { return nil }
            var kPa = v
            // Plain "kPa" is taken as-is; only explicit absolute/relative pairs are shifted.
            if kind == .pressureAbsolute && u.contains("relative") { kPa -= standardAtmosphere }
            if kind == .pressureRelative && u.contains("absolute") { kPa += standardAtmosphere }
            return kPa / scale
        }
    }
}
