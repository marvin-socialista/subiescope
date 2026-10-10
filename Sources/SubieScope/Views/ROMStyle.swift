import AppKit
import SSMKit
import SwiftUI

/// The ROM editor's own colours and small controls. The design was drawn in the dark look: the dark
/// values are the design's, and each has a light one beside it. The colours of the cells themselves
/// (the heat scale, the rings around a changed cell) are the same in both looks, with near-black numbers.
enum ROMStyle {
    /// One colour in the light look and one in the dark look.
    struct Pair {
        let light: UInt32
        let dark: UInt32

        /// The colour that follows the window's look by itself.
        var color: Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return ROMStyle.nsColor(isDark ? dark : light)
            })
        }

        /// The colour for a look that is known: a `Canvas` is told which one it draws in.
        func color(in scheme: ColorScheme) -> Color { ROMStyle.hex(scheme == .dark ? dark : light) }
    }

    static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    // The surfaces, from the back to the front.
    static let workspace = Pair(light: 0xE3E3E7, dark: 0x161617)
    static let panel = Pair(light: 0xF4F4F6, dark: 0x232324)
    static let window = Pair(light: 0xFFFFFF, dark: 0x2A2A2B)
    static let titleBar = Pair(light: 0xECECEF, dark: 0x333335)
    static let axisCell = Pair(light: 0xD8D8DE, dark: 0x3A3A3C)
    static let field = Pair(light: 0xFFFFFF, dark: 0x1A1A1B)
    static let inset = Pair(light: 0xEFEFF2, dark: 0x1E1E1F)
    static let surfaceBackdrop = Pair(light: 0xEDEDF1, dark: 0x1B1B1C)
    /// A cell of a Difference view that is the same as it was.
    static let plainCell = Pair(light: 0xE9E9ED, dark: 0x2C2C2E)
    static let plainCellText = Pair(light: 0x77777D, dark: 0x8D8D93)
    static let hairline = Color.primary.opacity(0.11)

    // The cells.
    static let cellText = hex(0x0D0E10)
    static let raisedRing = hex(0xB3001B)
    static let loweredRing = hex(0x0B3FC4)
    static let differentRing = hex(0x6B21A8)
    static let otherNumber = hex(0x3B0764)
    static let raisedFill = hex(0xFFB469)
    static let loweredFill = hex(0x9CC2FF)
    static let legendFill = hex(0xF2B46E)
    static let selectionRing = hex(0x5499FF)

    // The accents.
    static let orange = hex(0xFF9F0A)
    static let orangeText = Pair(light: 0xA35A00, dark: 0xFFB340)
    static let badgeText = hex(0x241300)
    static let purple = hex(0xC98BF5)
    static let purpleBadgeText = hex(0x22073A)
    static let purpleText = Pair(light: 0x6B21A8, dark: 0xD9AAF8)
    static let purpleBar = Pair(light: 0xEFE5FB, dark: 0x2B2140)
    static let purpleButton = hex(0x6B3FA0)
    static let chip = hex(0xE58A1F)
    static let chipText = hex(0x1A1205)
    static let folder = hex(0xE0A83A)
    static let fineButton = hex(0x2F6FD6)
    static let coarseButton = hex(0xC96A00)
    static let primaryButton = hex(0x3D86F5)
    static let ok = Pair(light: 0x1A8F3A, dark: 0x5FD97A)
    static let raisedArrow = Pair(light: 0xD9541E, dark: 0xFF9F6B)
    static let loweredArrow = Pair(light: 0x2F6FD6, dark: 0x6EA2FF)
    static let axisTitle3D = Pair(light: 0xC0392B, dark: 0xFF7A6E)

    /// The font of every number in a map.
    static func mono(_ size: CGFloat = 12, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// The ring of a marked cell.
    static func ring(_ mark: ROMEditor.CellLook.Mark) -> Color? {
        switch mark {
        case .none: return nil
        case .raised: return raisedRing
        case .lowered: return loweredRing
        case .different: return differentRing
        }
    }
}

extension Color {
    /// A colour of the heat scale both fronts share.
    init(_ heat: ROMHeatScale.Color) {
        let rgb = heat.rgb
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}

/// A small switch between a few views of the same thing: Now, As opened, Difference.
struct ROMSegments<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        /// A dot in front of the title, the way the tree marks "Changed".
        var dot: Color?
    }

    let options: [Option]
    let selection: Value
    /// Each option takes an equal share of the width, in place of the room its title needs.
    var fills = false
    var height: CGFloat = 20
    let select: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isOn = option.value == selection
                Button { select(option.value) } label: {
                    HStack(spacing: 6) {
                        if let dot = option.dot { Circle().fill(dot).frame(width: 7, height: 7) }
                        // A title is never cut short: the row around the switch gives way instead.
                        Text(option.title).fontWeight(isOn ? .semibold : .regular).lineLimit(1).fixedSize()
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 9)
                    .frame(maxWidth: fills ? .infinity : nil, minHeight: height, maxHeight: height)
                    .background(RoundedRectangle(cornerRadius: 5).fill(isOn ? Color.primary.opacity(0.22) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.09)))
    }
}

/// The look of the editor's own buttons: a flat, rounded tile, as in the design.
struct ROMButtonStyle: ButtonStyle {
    enum Kind {
        /// The toolbar's buttons, and the quieter ones inside a card.
        case toolbar, quiet
        /// A button in a colour of its own, with white on it.
        case filled(Color)
    }

    var kind: Kind = .toolbar
    var height: CGFloat = 30
    var horizontalPadding: CGFloat = 10
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: isFilled ? .semibold : .regular))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: height, maxHeight: height)
            .foregroundStyle(isFilled ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
            .background(RoundedRectangle(cornerRadius: height > 26 ? 7 : 6).fill(fill))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Rectangle())
    }

    private var isFilled: Bool {
        if case .filled = kind { return true }
        return false
    }

    private var fill: Color {
        switch kind {
        case .toolbar: return Color.primary.opacity(0.08)
        case .quiet: return Color.primary.opacity(0.13)
        case .filled(let color): return color
        }
    }
}

/// A count in a rounded badge: the changed cells of a map in orange, the different ones in purple.
struct ROMBadge: View {
    let text: String
    var isCompare = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(isCompare ? ROMStyle.purpleBadgeText : ROMStyle.badgeText)
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 16, maxHeight: 16)
            .background(Capsule().fill(isCompare ? ROMStyle.purple : ROMStyle.orange))
            .fixedSize()
    }
}

/// A card of the overview, and of the screen without a ROM.
struct ROMCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .bold))
            content
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9).fill(ROMStyle.window.color))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ROMStyle.hairline, lineWidth: 1))
    }
}

/// Lays its views out in a row and starts a new row when one does not fit: the toolbar on a narrow window.
struct ROMFlow: Layout {
    var spacing: CGFloat = 14
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: proposal.width ?? .infinity, subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                // Each view is laid out the way it was measured, at the size it asks for. Offering it
                // that size as a number instead can come out a fraction short, and a title turns to dots.
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row(items: [index], width: size.width, height: size.height))
            } else {
                rows[rows.count - 1].items.append(index)
                rows[rows.count - 1].width = needed
                rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            }
        }
        return rows
    }
}
