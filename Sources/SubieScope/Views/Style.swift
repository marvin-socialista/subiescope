import AppKit
import SSMKit
import SwiftUI

extension Color {
    /// Light WR Blue; used instead of the system accent so gauges stay blue
    /// even when macOS is set to the graphite accent.
    static let scopeBlue = Color(red: 0.33, green: 0.60, blue: 1.0)
}

extension SeriesPalette {
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
