import AppKit
import SSMKit
import SwiftUI

enum Links {
    static let repository = URL(string: "https://github.com/marvin-socialista/subiescope")!
    static let issues = URL(string: "https://github.com/marvin-socialista/subiescope/issues")!
    static let releases = URL(string: "https://github.com/marvin-socialista/subiescope/releases")!
}

extension Color {
    /// Light WR Blue; used instead of the system accent so gauges stay blue
    /// even when macOS is set to the graphite accent.
    static let scopeBlue = Color(red: 0.33, green: 0.60, blue: 1.0)
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

/// Categorical series colors in a fixed order, with separate steps for light and
/// dark appearance (validated reference palette from the dataviz guidelines).
enum SeriesPalette {
    private static let light = [0x2a78d6, 0xeb6834, 0x1baf7a, 0xeda100, 0xe87ba4, 0x008300, 0x4a3aa7, 0xe34948]
    private static let dark = [0x3987e5, 0xd95926, 0x199e70, 0xc98500, 0xd55181, 0x008300, 0x9085e9, 0xe66767]
    static let count = light.count

    static func color(_ slot: Int) -> Color {
        let i = ((slot % count) + count) % count
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark[i] : light[i]
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
