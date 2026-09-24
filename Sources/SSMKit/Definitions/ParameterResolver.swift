import Foundation

/// Finds "the" parameter for a concept such as "IAM" or "Rear O2 Sensor" among
/// RomRaider's definitions, where the same value often exists in several variants
/// (16-bit vs 32-bit ECUs, 1 vs 4 byte versions).
public enum ParameterResolver {
    /// Variants tried in order, keyed by base name.
    public static let preferredVariants: [String: [String]] = [
        "feedback knock correction": ["Feedback Knock Correction (4-byte)*", "Feedback Knock Correction*", "Feedback Knock Correction (1-byte)**"],
        "fine learning knock correction": ["Fine Learning Knock Correction (4-byte)*", "Fine Learning Knock Correction*",
                                           "Fine Learning Knock Correction (1-byte)**", "Fine Learning Knock Correction"],
        "iam": ["IAM (4-byte)*", "IAM*", "IAM (1-byte)**", "IAM"],
        "knock correction advance": ["Knock Correction Advance (4-byte)*", "Knock Correction Advance"],
        "target boost": ["Target Boost Relative (4-byte)*", "Target Boost (4-byte)*", "Target Boost (2-byte)**", "Target Boost*"],
    ]

    /// "Feedback Knock Correction (4-byte)*" -> "feedback knock correction"
    public static func baseName(_ name: String) -> String {
        var n = name.replacingOccurrences(of: "*", with: "")
        if let r = n.range(of: #"\s*\((1|2|4)-byte\)"#, options: [.regularExpression, .caseInsensitive]) {
            n.removeSubrange(r)
        }
        return n.trimmingCharacters(in: .whitespaces).lowercased()
    }

    public static func resolve(_ concept: String, in parameters: [ParameterDefinition]) -> ParameterDefinition? {
        let key = baseName(concept)
        for name in preferredVariants[key] ?? [] {
            if let p = parameters.first(where: { $0.name == name }) { return p }
        }
        let lower = concept.lowercased()
        return parameters.first { baseName($0.name) == key }
            ?? parameters.first { $0.name.lowercased() == lower }
            ?? parameters.first { $0.name.lowercased().hasPrefix(lower) }
    }

    /// The conversion whose units match the first available preference.
    public static func conversion(for parameter: ParameterDefinition, preferring units: [String]) -> Conversion? {
        for u in units {
            if let c = parameter.conversions.first(where: { $0.units.caseInsensitiveCompare(u) == .orderedSame }) { return c }
        }
        return units.isEmpty ? parameter.conversions.first : nil
    }
}
