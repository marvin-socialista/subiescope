import Foundation

/// What a trouble code means, what usually causes it and how to fix it,
/// written for Subaru engine ECUs. Loaded from TroubleCodes/trouble_codes.json.
public struct TroubleCodeHelp: Codable, Sendable, Hashable {
    public var meaning: String
    /// Most likely first.
    public var causes: [String]
    /// Quickest and cheapest checks first.
    public var fixes: [String]

    public init(meaning: String, causes: [String], fixes: [String]) {
        self.meaning = meaning
        self.causes = causes
        self.fixes = fixes
    }

    /// Every entry by code ("P0420"); empty when the resource is missing.
    public static let library: [String: TroubleCodeHelp] = {
        guard let url = SSMResources.url(forTroubleCodes: "trouble_codes"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: TroubleCodeHelp].self, from: data)) ?? [:]
    }()

    public static func lookup(_ code: String) -> TroubleCodeHelp? {
        library[code.uppercased()]
    }
}

extension DiagnosticCodeDefinition {
    public var help: TroubleCodeHelp? { TroubleCodeHelp.lookup(code) }
}
