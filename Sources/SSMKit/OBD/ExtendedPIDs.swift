import Foundation

/// A manufacturer specific value read with OBD-II "Mode 22" (UDS ReadDataByIdentifier). Not part of the
/// OBD-II standard: only some cars answer, mostly newer Subarus, and what a value means can differ
/// between models. The definitions are community data from OBDb (CC BY-SA 4.0).
public struct ExtendedPID: Sendable, Decodable, Hashable {
    /// The ECU to ask, e.g. "7A2", and the address its answer comes from, e.g. "7AA".
    public var header: String
    public var response: String
    /// The two byte identifier as hex, e.g. "10B4".
    public var did: String
    public var name: String
    public var bits: Int
    public var signed: Bool
    public var mul: Double
    public var div: Double
    public var add: Double
    public var unit: String
    public var min: Double?
    public var max: Double?
    public var models: [String]

    public var id: String { "X\(header)_\(did)" }
    public var didValue: UInt16 { UInt16(did, radix: 16) ?? 0 }
    public var byteCount: Int { bits / 8 }

    /// value = raw * mul / div + add, written for the expression evaluator (x is the raw number).
    var formula: String {
        var text = "x"
        if mul != 1 { text += "*\(Self.number(mul))" }
        if div != 1 { text += "/\(Self.number(div))" }
        if add > 0 { text += "+\(Self.number(add))" } else if add < 0 { text += "-\(Self.number(-add))" }
        return text
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// The bytes of the answer as a number (big-endian), negative when the value is signed.
    public func raw(from data: [UInt8]) -> Double? {
        guard data.count >= byteCount else { return nil }
        var value: UInt64 = 0
        for byte in data.prefix(byteCount) { value = value << 8 | UInt64(byte) }
        if signed && bits < 64 && value & (1 << UInt64(bits - 1)) != 0 {
            return Double(Int64(value) - Int64(1 << UInt64(bits)))
        }
        return Double(value)
    }
}

public enum ExtendedParameters {
    struct File: Decodable {
        var source: String
        var license: String
        var entries: [ExtendedPID]
    }

    /// Every known value, from the bundled OBDb data. Empty when the resource is missing.
    public static let catalog: [ExtendedPID] = {
        guard let url = SSMResources.url(forExtendedPIDs: "subaru_mode22"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.entries
    }()

    public static let byID: [String: ExtendedPID] = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    /// Units as the rest of the app writes them, with an imperial alternative where one makes sense.
    private static func conversions(for pid: ExtendedPID) -> [Conversion] {
        let f = pid.formula
        let decimals = (pid.mul != 1 || pid.div != 1) ? "0.00" : "0"
        func c(_ units: String, _ expression: String) -> Conversion {
            Conversion(units: units, expression: expression, format: decimals, gaugeMin: pid.min, gaugeMax: pid.max)
        }
        switch pid.unit {
        case "celsius": return [c("C", f), c("F", "(\(f))*1.8+32")]
        case "kilopascal": return [c("kPa", f), c("bar", "(\(f))/100"), c("psi", "(\(f))*0.145038")]
        case "kilometersPerHour": return [c("km/h", f), c("mph", "(\(f))*0.621371")]
        case "kilometers": return [c("km", f), c("miles", "(\(f))*0.621371")]
        case "percent": return [c("%", f)]
        case "degrees": return [c("degrees", f)]
        case "volts": return [c("V", f)]
        case "milliseconds": return [c("ms", f)]
        case "milliamps": return [c("mA", f)]
        case "gramsPerSecond": return [c("g/s", f)]
        case "newtonMeters": return [c("Nm", f)]
        case "rpm": return [c("rpm", f)]
        default: return [c(pid.unit == "scalar" ? "value" : pid.unit, f)]
        }
    }

    public static func definition(for pid: ExtendedPID) -> ParameterDefinition {
        ParameterDefinition(
            id: pid.id, name: pid.name,
            description: "Experimental extended value (Mode 22 on \(pid.header)), from community data for \(pid.models.joined(separator: ", ")). Only some cars answer, and the meaning can differ between models.",
            kind: .extended, conversions: conversions(for: pid))
    }

    public static func definitions(for ids: Set<String>) -> [ParameterDefinition] {
        catalog.filter { ids.contains($0.id) }.map(definition(for:))
    }
}
