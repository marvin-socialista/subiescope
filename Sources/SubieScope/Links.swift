import Foundation
import SSMKit

enum Links {
    static let repository = URL(string: "https://github.com/marvin-socialista/subiescope")!
    static let issues = URL(string: "https://github.com/marvin-socialista/subiescope/issues")!
    static let releases = URL(string: "https://github.com/marvin-socialista/subiescope/releases")!
    /// Where diagnostic reports are sent.
    static let supportEmail = "mail@marvinvisser.nl"
}

enum About {
    static let coffeeURL = URL(string: "https://buymeacoffee.com/socialista")!

    /// Nil when running from `swift run`, which has no Info.plist (on Windows: no VERSION file
    /// next to the program, which the build script puts there).
    static var version: String? {
        #if os(Windows)
        guard let folder = Bundle.main.executableURL?.deletingLastPathComponent(),
              let text = try? String(contentsOf: folder.appendingPathComponent("VERSION"), encoding: .utf8) else { return nil }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
        #else
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        #endif
    }
}

extension Conversion {
    /// Units for display. The CSV keeps RomRaider's own unit strings.
    var displayUnits: String {
        switch units {
        case "C": return "°C"
        case "F": return "°F"
        default: return units
        }
    }
}

extension ParameterDefinition {
    /// Name without RomRaider's variant markers: "IAM (4-byte)*" -> "IAM".
    var displayName: String {
        var n = name
        if let r = n.range(of: #"\s*\((1|2|4)-byte\)"#, options: [.regularExpression, .caseInsensitive]) {
            n.removeSubrange(r)
        }
        return n.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
    }
}
