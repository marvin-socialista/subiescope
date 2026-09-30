import Foundation

/// Which unit to show pressures in, whatever the metric or imperial setting says.
public enum PressureUnit: String, CaseIterable, Sendable, Identifiable {
    /// kPa with metric units, psi with imperial units (the default).
    case automatic
    case kilopascal
    case bar
    case psi

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: return "Automatic (kPa or psi)"
        case .kilopascal: return "kPa"
        case .bar: return "bar"
        case .psi: return "psi"
        }
    }

    /// The conversion of a parameter that is in this pressure unit, or nil when it has none
    /// (a temperature, or a definition that only has kPa) and the normal choice should apply.
    public func choose(from conversions: [Conversion]) -> Conversion? {
        let prefix: String
        switch self {
        case .automatic: return nil
        case .kilopascal: prefix = "kpa"
        case .bar: prefix = "bar"
        case .psi: prefix = "psi"
        }
        return conversions.first { $0.units.lowercased().hasPrefix(prefix) }
    }
}
