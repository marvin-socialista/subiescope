import AppKit
import SSMKit
import SwiftUI

/// Where everything of a map's table is, in points: the labels along the top and the left, and the
/// cells. The table is drawn in one piece (see `ROMMapGrid`), so a click is turned into a cell here.
struct ROMGridMetrics {
    /// Room around the cells for the rings of a marked or a selected cell, which reach outside it.
    static let inset: CGFloat = 5
    static let gap: CGFloat = 1
    static let headerHeight: CGFloat = 23
    static let maxCellWidth: CGFloat = 84

    let rows: Int
    let columns: Int
    let hasColumnLabels: Bool
    let hasRowLabels: Bool
    /// The width of the labels in front of the rows.
    let labelWidth: CGFloat
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    /// The size of the numbers: 12, or 11 where that is what makes the whole table fit.
    let fontSize: CGFloat
    /// The table is wider than the room there is for it, so it scrolls sideways.
    let scrolls: Bool

    /// The cells share the width there is, up to a width that still reads as a table. When the
    /// numbers do not fit at their own size, they get a point smaller before the table starts to
    /// scroll: a map that is on screen whole shows every changed cell at once.
    init(look: ROMEditor.MapLook, available: CGFloat) {
        rows = look.rows
        columns = look.columns
        hasColumnLabels = look.columnLabels != nil
        hasRowLabels = look.rowLabels != nil
        cellHeight = Self.cellHeight(of: look)
        var longest = 4
        for row in look.cells { for cell in row { longest = max(longest, cell.text.count, cell.below?.count ?? 0) } }
        for label in look.columnLabels ?? [] { longest = max(longest, label.count) }
        let longestLabel = (look.rowLabels ?? []).map(\.count).max() ?? 0
        labelWidth = hasRowLabels ? min(max((CGFloat(longestLabel) * 7.4 + 16).rounded(.up), 44), 72) : 0
        // What a number of the longest length needs at a font size: the digits and a little air,
        // a point less of it at the smaller size, where every point counts.
        func needed(_ size: CGFloat) -> CGFloat { (CGFloat(longest) * size * 0.61 + (size < 12 ? 5 : 6)).rounded(.up) }
        let labels = hasRowLabels ? labelWidth + Self.gap : 0
        let room = available - 2 * Self.inset - labels - Self.gap * CGFloat(max(columns - 1, 0))
        let share = columns > 0 ? (room / CGFloat(columns)).rounded(.down) : needed(12)
        if share >= needed(12) {
            fontSize = 12
            cellWidth = min(share, max(Self.maxCellWidth, needed(12)))
            scrolls = false
        } else if share >= needed(11) {
            fontSize = 11
            cellWidth = share
            scrolls = false
        } else {
            fontSize = 12
            cellWidth = needed(12)
            scrolls = true
        }
    }

    static func cellHeight(of look: ROMEditor.MapLook) -> CGFloat { look.twoNumbers ? 34 : 23 }

    /// How tall the table is. It does not depend on the width, so the window can make room for it first.
    static func height(of look: ROMEditor.MapLook) -> CGFloat {
        let header = look.columnLabels == nil ? 0 : headerHeight + gap
        return 2 * inset + header + CGFloat(look.rows) * cellHeight(of: look) + gap * CGFloat(max(look.rows - 1, 0))
    }

    /// Where the first column of cells starts.
    var left: CGFloat { Self.inset + (hasRowLabels ? labelWidth + Self.gap : 0) }
    private var top: CGFloat { Self.inset + (hasColumnLabels ? Self.headerHeight + Self.gap : 0) }

    var width: CGFloat { left + CGFloat(columns) * cellWidth + Self.gap * CGFloat(max(columns - 1, 0)) + Self.inset }
    var height: CGFloat { top + CGFloat(rows) * cellHeight + Self.gap * CGFloat(max(rows - 1, 0)) + Self.inset }

    func rect(row: Int, column: Int) -> CGRect {
        CGRect(x: left + CGFloat(column) * (cellWidth + Self.gap), y: top + CGFloat(row) * (cellHeight + Self.gap),
               width: cellWidth, height: cellHeight)
    }

    func headerRect(column: Int) -> CGRect {
        CGRect(x: left + CGFloat(column) * (cellWidth + Self.gap), y: Self.inset, width: cellWidth, height: Self.headerHeight)
    }

    func labelRect(row: Int) -> CGRect {
        CGRect(x: Self.inset, y: top + CGFloat(row) * (cellHeight + Self.gap), width: labelWidth, height: cellHeight)
    }

    /// The cell under a point. With `nearest`, a point outside the cells gives the cell closest to
    /// it: a drag that runs off the table keeps selecting along its edge.
    func cell(at point: CGPoint, nearest: Bool = false) -> ROMTable.Cell? {
        guard rows > 0, columns > 0 else { return nil }
        let column = Int(((point.x - left) / (cellWidth + Self.gap)).rounded(.down))
        let row = Int(((point.y - top) / (cellHeight + Self.gap)).rounded(.down))
        if nearest {
            return ROMTable.Cell(row: min(max(row, 0), rows - 1), column: min(max(column, 0), columns - 1))
        }
        guard row >= 0, row < rows, column >= 0, column < columns else { return nil }
        return ROMTable.Cell(row: row, column: column)
    }
}

/// A map as a table of coloured cells, the way RomRaider shows one: each number on the colour of
/// its place between the map's lowest and highest value, with the axes along the top and the left.
/// A cell that is not what it was when the ROM was opened has a ring around it, red when it was
/// raised and blue when it was lowered, and a small triangle in its corner that points the same way.
///
/// The whole table is one drawing. A map can have hundreds of cells, and the rings of a marked cell
/// reach over its neighbours, which separate views would cut off.
struct ROMMapGrid: View {
    /// What of the table a drawing holds. A table that fits is one drawing. One that scrolls sideways
    /// is two: the labels in front of the rows stay where they are, and the cells scroll past them.
    enum Part {
        case whole, rowLabels, cells
    }

    let look: ROMEditor.MapLook
    let metrics: ROMGridMetrics
    var part: Part = .whole
    /// The selected cells of this map, and the one the selection ends on. Empty and nil for a map
    /// that is not the selected one.
    let selection: Set<ROMTable.Cell>
    let cursor: ROMTable.Cell?
    /// The number being typed into the selected cells. Empty while none is.
    let typed: String
    /// A cell was clicked, or a drag reached it. The second value says whether that extends the selection.
    let onCell: (ROMTable.Cell, Bool) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var dragged: ROMTable.Cell?
    @State private var hovered: ROMTable.Cell?

    /// How far the cells' own drawing is moved to the left: by the labels that are not in it.
    private var shift: CGFloat { part == .cells ? metrics.left - ROMGridMetrics.inset : 0 }
    private var width: CGFloat { part == .rowLabels ? metrics.left : metrics.width - shift }

    var body: some View {
        if part == .rowLabels {
            Canvas { context, _ in draw(in: &context) }
                .frame(width: width, height: metrics.height)
                .accessibilityHidden(true)
        } else {
            Canvas { context, _ in draw(in: &context) }
                .frame(width: width, height: metrics.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if let last = dragged {
                                // The drag reached another cell: the block from where it started to here.
                                guard let cell = cell(at: value.location, nearest: true), cell != last else { return }
                                dragged = cell
                                onCell(cell, true)
                            } else if let cell = cell(at: value.startLocation) {
                                dragged = cell
                                onCell(cell, NSEvent.modifierFlags.contains(.shift))
                            }
                        }
                        .onEnded { _ in dragged = nil }
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hovered = cell(at: point)
                    case .ended: hovered = nil
                    }
                }
                .help(hovered.flatMap { look.cells[safe: $0.row]?[safe: $0.column]?.note } ?? "")
                .accessibilityLabel("\(look.title), \(look.rows) by \(look.columns) cells")
        }
    }

    /// The cell under a point of this drawing.
    private func cell(at point: CGPoint, nearest: Bool = false) -> ROMTable.Cell? {
        metrics.cell(at: CGPoint(x: point.x + shift, y: point.y), nearest: nearest)
    }

    private func draw(in context: inout GraphicsContext) {
        let size = metrics.fontSize
        let labelFill = ROMStyle.axisCell.color(in: scheme)
        let labelText = scheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.85)
        if part != .cells {
            for (row, label) in (look.rowLabels ?? []).enumerated() {
                let rect = metrics.labelRect(row: row)
                context.fill(Path(rect), with: .color(labelFill))
                context.draw(Text(label).font(ROMStyle.mono(size, .bold)).foregroundColor(labelText), at: rect.center)
            }
        }
        guard part != .rowLabels else { return }
        context.translateBy(x: -shift, y: 0)
        for (column, label) in (look.columnLabels ?? []).enumerated() {
            let rect = metrics.headerRect(column: column)
            context.fill(Path(rect), with: .color(labelFill))
            context.draw(Text(label).font(ROMStyle.mono(size, .bold)).foregroundColor(labelText), at: rect.center)
        }

        // The cells first, then the rings: a ring reaches two points over the cells next to it.
        for row in 0..<look.rows {
            for column in 0..<look.columns {
                let cell = look.cells[row][column]
                let rect = metrics.rect(row: row, column: column)
                context.fill(Path(rect), with: .color(fill(of: cell)))
                let color = cell.fill == .plain ? ROMStyle.plainCellText.color(in: scheme) : ROMStyle.cellText
                let weight: Font.Weight = cell.fill == .plain ? .medium : (cell.fill == .raised || cell.fill == .lowered ? .bold : .semibold)
                if let below = cell.below {
                    context.draw(Text(cell.text).font(ROMStyle.mono(size, weight)).foregroundColor(color),
                                 at: CGPoint(x: rect.midX, y: rect.midY - 7))
                    context.draw(Text(below).font(ROMStyle.mono(size - 1.5, .bold)).foregroundColor(ROMStyle.otherNumber),
                                 at: CGPoint(x: rect.midX, y: rect.midY + 7))
                } else {
                    context.draw(Text(cell.text).font(ROMStyle.mono(size, weight)).foregroundColor(color), at: rect.center)
                }
            }
        }
        for row in 0..<look.rows {
            for column in 0..<look.columns {
                let cell = look.cells[row][column]
                guard let ring = ROMStyle.ring(cell.mark) else { continue }
                Self.drawMark(cell.mark, ring: ring, in: metrics.rect(row: row, column: column), context: &context,
                              triangle: cell.fill != .raised && cell.fill != .lowered)
            }
        }
        drawSelection(in: &context)
    }

    private func fill(of cell: ROMEditor.CellLook) -> Color {
        switch cell.fill {
        case .heat(let heat): return Color(heat)
        case .raised: return ROMStyle.raisedFill
        case .lowered: return ROMStyle.loweredFill
        case .plain: return ROMStyle.plainCell.color(in: scheme)
        }
    }

    /// The ring of a marked cell: two points in its colour just inside the cell, two points of white
    /// just outside it, and a triangle in the corner that points up for raised and down for lowered.
    static func drawMark(_ mark: ROMEditor.CellLook.Mark, ring: Color, in rect: CGRect, context: inout GraphicsContext, triangle: Bool) {
        context.stroke(Path(rect.insetBy(dx: -1, dy: -1)), with: .color(.white), lineWidth: 2)
        context.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(ring), lineWidth: 2)
        guard triangle, mark == .raised || mark == .lowered else { return }
        var path = Path()
        let right = rect.maxX - 3
        if mark == .raised {
            path.move(to: CGPoint(x: right - 8, y: rect.minY + 8))
            path.addLine(to: CGPoint(x: right, y: rect.minY + 8))
            path.addLine(to: CGPoint(x: right - 4, y: rect.minY + 2))
        } else {
            path.move(to: CGPoint(x: right - 8, y: rect.maxY - 8))
            path.addLine(to: CGPoint(x: right, y: rect.maxY - 8))
            path.addLine(to: CGPoint(x: right - 4, y: rect.maxY - 2))
        }
        path.closeSubpath()
        context.fill(path, with: .color(ring))
    }

    /// The selection is a block of cells: a white and a blue ring around the whole of it, and a thin
    /// blue line inside each cell of a block of more than one.
    private func drawSelection(in context: inout GraphicsContext) {
        guard !selection.isEmpty else { return }
        var block = CGRect.null
        for cell in selection where cell.row < look.rows && cell.column < look.columns {
            let rect = metrics.rect(row: cell.row, column: cell.column)
            block = block.union(rect)
            if selection.count > 1 {
                context.stroke(Path(rect.insetBy(dx: 0.75, dy: 0.75)), with: .color(ROMStyle.selectionRing), lineWidth: 1.5)
            }
        }
        guard !block.isNull else { return }
        // A number is being typed: it shows in the cell the selection ends on, on white.
        if !typed.isEmpty, let cursor, cursor.row < look.rows, cursor.column < look.columns {
            let rect = metrics.rect(row: cursor.row, column: cursor.column)
            context.fill(Path(rect), with: .color(.white))
            let text = context.resolve(Text(typed).font(ROMStyle.mono(metrics.fontSize, .bold)).foregroundColor(ROMStyle.cellText))
            let size = text.measure(in: rect.size)
            context.draw(text, at: rect.center)
            let caret = CGRect(x: min(rect.midX + size.width / 2 + 1, rect.maxX - 3), y: rect.minY + 4, width: 1.5, height: rect.height - 8)
            context.fill(Path(caret), with: .color(ROMStyle.selectionRing))
        }
        context.stroke(Path(block.insetBy(dx: -1, dy: -1)), with: .color(.white), lineWidth: 2)
        context.stroke(Path(block.insetBy(dx: -3, dy: -3)), with: .color(ROMStyle.selectionRing), lineWidth: 2)
    }
}

/// The small cell in a legend that shows what a ring means.
struct ROMLegendSample: View {
    let mark: ROMEditor.CellLook.Mark
    var fill: Color = ROMStyle.legendFill
    /// The legend of a table in a Difference view has no triangle: the colour of the cell says it there.
    var triangle = true

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: 3, y: 3, width: size.width - 6, height: size.height - 6)
            context.fill(Path(rect), with: .color(fill))
            if let ring = ROMStyle.ring(mark) {
                ROMMapGrid.drawMark(mark, ring: ring, in: rect, context: &context, triangle: triangle)
            } else {
                // A cell without a ring is close to the colour behind it: a thin line sets it apart.
                context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.gray.opacity(0.6)), lineWidth: 1)
            }
        }
        .frame(width: 32, height: 22)
        .accessibilityHidden(true)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension Array {
    /// The element at an index, or nil for an index outside the array.
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}
