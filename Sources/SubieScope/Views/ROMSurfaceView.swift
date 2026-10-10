import SSMKit
import SwiftUI

/// Where a map's tiles are in the 3D view. The map lies on a plane, as a table does: the columns
/// along x, the rows along y, with the labels along its top and left. Each tile is lifted off the
/// plane by its value. The plane is turned about its middle and tilted away from the viewer, and
/// looked at from far away, so a tile stays a parallelogram and its number can lie flat on it.
struct ROMSurfaceScene {
    static let tileWidth: CGFloat = 44
    static let tileHeight: CGFloat = 24
    static let gap: CGFloat = 2
    /// The room the row labels and the column labels take on the plane.
    static let labelColumn: CGFloat = 40
    static let labelRow: CGFloat = 16
    /// How far the highest value is lifted for each step of the Height slider.
    static let liftPerStep: CGFloat = 24
    /// Where the names of the axes lie on the plane: the columns' above it, the rows' to its left.
    static let columnTitleY: CGFloat = -50
    static let rowTitleX: CGFloat = -70
    /// About how wide one letter of an axis name is, for making room for it.
    static let titleCharacterWidth: CGFloat = 8.4

    let look: ROMEditor.MapLook
    let turn: CGFloat
    let tilt: CGFloat
    let lift: CGFloat
    let scale: CGFloat
    let origin: CGPoint

    /// The size of the plane: the labels and every tile.
    var planeSize: CGSize { Self.planeSize(of: look) }

    static func planeSize(of look: ROMEditor.MapLook) -> CGSize {
        CGSize(width: labelColumn + CGFloat(look.columns) * (tileWidth + gap) - gap,
               height: labelRow + CGFloat(look.rows) * (tileHeight + gap) - gap)
    }

    /// The plane with a margin around it, which is drawn as the floor under the tiles.
    var floor: CGRect {
        CGRect(x: -44, y: -30, width: planeSize.width + 58, height: planeSize.height + 44)
    }

    /// Fits the whole scene, with its axis titles and its highest tile, into `size`.
    init(look: ROMEditor.MapLook, view: ROMEditor.MapView, size: CGSize) {
        self.look = look
        turn = CGFloat(view.turn) * .pi / 180
        tilt = CGFloat(view.tilt) * .pi / 180
        lift = CGFloat(view.height) * Self.liftPerStep
        let plane = Self.planeSize(of: look)
        let flat = ROMSurfaceScene(look: look, turn: turn, tilt: tilt, lift: lift, scale: 1, origin: .zero)
        // The room on the screen that is drawn in: the floor, the names of the axes on it, and each
        // tile where it floats. The scene is made as large as fits.
        var bounds = CGRect.null
        func add(_ rect: CGRect, at height: CGFloat) {
            let transform = flat.transform(height: height)
            for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
                bounds = bounds.union(CGRect(origin: corner.applying(transform), size: .zero))
            }
        }
        add(flat.floor, at: 0)
        if let title = look.columnTitle {
            let width = CGFloat(title.count) * Self.titleCharacterWidth
            add(CGRect(x: plane.width / 2 - width / 2, y: Self.columnTitleY - 11, width: width, height: 22), at: 0)
        }
        if let title = look.rowTitle {
            let width = CGFloat(title.count) * Self.titleCharacterWidth
            add(CGRect(x: Self.rowTitleX - 11, y: plane.height / 2 - width / 2, width: 22, height: width), at: 0)
        }
        for row in 0..<look.rows {
            for column in 0..<look.columns {
                add(flat.tileRect(row: row, column: column).insetBy(dx: -4, dy: -4), at: flat.height(row: row, column: column))
            }
        }
        let fit = min((size.width - 28) / max(bounds.width, 1), (size.height - 28) / max(bounds.height, 1))
        scale = max(min(fit, 1.7), 0.05)
        origin = CGPoint(x: size.width / 2 - bounds.midX * scale, y: size.height / 2 - bounds.midY * scale)
    }

    private init(look: ROMEditor.MapLook, turn: CGFloat, tilt: CGFloat, lift: CGFloat, scale: CGFloat, origin: CGPoint) {
        self.look = look
        self.turn = turn
        self.tilt = tilt
        self.lift = lift
        self.scale = scale
        self.origin = origin
    }

    /// From a point on the plane, `height` above it, to the screen.
    func transform(height: CGFloat) -> CGAffineTransform {
        let middle = CGPoint(x: planeSize.width / 2, y: planeSize.height / 2)
        let cosTurn = cos(turn), sinTurn = sin(turn), cosTilt = cos(tilt), sinTilt = sin(tilt)
        return CGAffineTransform(
            a: scale * cosTurn, b: scale * sinTurn * cosTilt,
            c: -scale * sinTurn, d: scale * cosTurn * cosTilt,
            tx: origin.x - scale * (middle.x * cosTurn - middle.y * sinTurn),
            ty: origin.y - scale * ((middle.x * sinTurn + middle.y * cosTurn) * cosTilt + height * sinTilt))
    }

    func tileRect(row: Int, column: Int) -> CGRect {
        CGRect(x: Self.labelColumn + CGFloat(column) * (Self.tileWidth + Self.gap),
               y: Self.labelRow + CGFloat(row) * (Self.tileHeight + Self.gap),
               width: Self.tileWidth, height: Self.tileHeight)
    }

    func height(row: Int, column: Int) -> CGFloat {
        CGFloat(look.cells[row][column].place) * lift
    }

    /// The tiles from the back to the front, so a tile that is nearer is drawn over one behind it.
    var tilesBackToFront: [ROMTable.Cell] {
        var tiles: [(cell: ROMTable.Cell, depth: CGFloat, height: CGFloat)] = []
        let middle = CGPoint(x: planeSize.width / 2, y: planeSize.height / 2)
        for row in 0..<look.rows {
            for column in 0..<look.columns {
                let rect = tileRect(row: row, column: column)
                // How far down the turned plane the tile is: the bottom of the plane is the near side.
                let depth = (rect.midX - middle.x) * sin(turn) + (rect.midY - middle.y) * cos(turn)
                tiles.append((ROMTable.Cell(row: row, column: column), depth, height(row: row, column: column)))
            }
        }
        return tiles.sorted { ($0.depth, $0.height) < ($1.depth, $1.height) }.map(\.cell)
    }

    /// The tile under a point of the screen: the nearest one, when tiles overlap there.
    func cell(at point: CGPoint) -> ROMTable.Cell? {
        for cell in tilesBackToFront.reversed() {
            let onPlane = point.applying(transform(height: height(row: cell.row, column: cell.column)).inverted())
            if tileRect(row: cell.row, column: cell.column).contains(onPlane) { return cell }
        }
        return nil
    }
}

/// The 3D view of a map: every cell a tile in its heat colour, floating at the height of its value,
/// so the shape of the map shows. It turns and tilts with the sliders and by dragging, and a click
/// on a tile selects that cell. The rings of the table are here too: a tile that was changed since
/// the ROM was opened is ringed, and the selected one has the blue ring.
struct ROMSurfaceView: View {
    let editor: ROMEditor
    let name: String
    let look: ROMEditor.MapLook
    /// The selected cells of this map. Empty for a map that is not the selected one.
    let selection: Set<ROMTable.Cell>
    let onCell: (ROMTable.Cell) -> Void

    @Environment(\.colorScheme) private var scheme
    /// The angles when a drag began, and whether it has moved far enough to be a turn and not a click.
    @State private var dragStart: (turn: Double, tilt: Double)?
    @State private var isTurning = false

    static let height: CGFloat = 560

    var body: some View {
        let view = editor.view(of: name)
        VStack(spacing: 0) {
            controls(view)
            Divider()
            GeometryReader { geometry in
                let scene = ROMSurfaceScene(look: look, view: view, size: geometry.size)
                Canvas { context, _ in draw(scene, numbers: view.numbers, in: &context) }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let start = dragStart ?? (view.turn, view.tilt)
                                dragStart = start
                                guard isTurning || abs(value.translation.width) > 3 || abs(value.translation.height) > 3 else { return }
                                isTurning = true
                                editor.setAngles(turn: start.turn + value.translation.width * 0.35,
                                                 tilt: start.tilt - value.translation.height * 0.25, for: name)
                            }
                            .onEnded { value in
                                if !isTurning, let cell = scene.cell(at: value.location) { onCell(cell) }
                                dragStart = nil
                                isTurning = false
                            }
                    )
            }
            .frame(height: Self.height)
            .background(ROMStyle.surfaceBackdrop.color)
            .accessibilityLabel("\(look.title) drawn in 3D, from \(look.lowText) to \(look.highText)")
            Divider()
            footer
        }
    }

    // MARK: The controls

    private func controls(_ view: ROMEditor.MapView) -> some View {
        ROMFlow(spacing: 18, lineSpacing: 8) {
            slider("Turn", view.turn, ROMEditor.MapView.turnRange) { editor.setAngles(turn: $0, for: name) }
            slider("Tilt", view.tilt, ROMEditor.MapView.tiltRange) { editor.setAngles(tilt: $0, for: name) }
            slider("Height", view.height, ROMEditor.MapView.heightRange) { editor.setHeight($0, for: name) }
            Toggle("Numbers on the tiles", isOn: Binding(get: { view.numbers }, set: { editor.setNumbers($0, for: name) }))
                .toggleStyle(.checkbox)
            Text("Drag to turn it. Click a tile to select that cell.").foregroundStyle(.secondary)
            Button("Reset View") { editor.resetView(of: name) }
                .buttonStyle(ROMButtonStyle(kind: .quiet, height: 24))
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func slider(_ title: String, _ value: Double, _ range: ClosedRange<Double>, _ set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 7) {
            Text(title).foregroundStyle(.secondary)
            Slider(value: Binding(get: { value }, set: set), in: range)
                .controlSize(.small)
                .frame(width: 130)
                .accessibilityLabel(title)
        }
    }

    private var footer: some View {
        HStack(spacing: 18) {
            if selection.isEmpty == false, let detail = editor.cellDetail {
                Text(detail.place).fontWeight(.bold)
                ROMCellNumbers(detail: detail)
            } else {
                Text("No cell selected").foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Text(look.lowText).font(ROMStyle.mono(12, .regular))
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.125).map { Color(ROMHeatScale.color(at: $0)) },
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 180, height: 10)
                    .clipShape(Capsule())
                    .accessibilityHidden(true)
                Text(look.highText).font(ROMStyle.mono(12, .regular))
            }
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    // MARK: Drawing

    private func draw(_ scene: ROMSurfaceScene, numbers: Bool, in context: inout GraphicsContext) {
        let dark = scheme == .dark
        let ink = dark ? Color.white : Color.black
        let plane = scene.planeSize

        // The floor, with the labels and the names of the axes lying on it.
        var floor = context
        floor.concatenate(scene.transform(height: 0))
        floor.fill(Path(scene.floor), with: .color(ink.opacity(dark ? 0.05 : 0.04)))
        floor.stroke(Path(scene.floor), with: .color(ink.opacity(0.25)), lineWidth: 1)
        for (column, label) in (look.columnLabels ?? []).enumerated() {
            let rect = scene.tileRect(row: 0, column: column)
            floor.draw(Text(label).font(ROMStyle.mono(10, .bold)).foregroundColor(ink.opacity(0.8)),
                       at: CGPoint(x: rect.midX, y: ROMSurfaceScene.labelRow / 2))
        }
        for (row, label) in (look.rowLabels ?? []).enumerated() {
            let rect = scene.tileRect(row: row, column: 0)
            floor.draw(Text(label).font(ROMStyle.mono(10, .bold)).foregroundColor(ink.opacity(0.8)),
                       at: CGPoint(x: ROMSurfaceScene.labelColumn - 6, y: rect.midY), anchor: .trailing)
        }
        let titleColor = ROMStyle.axisTitle3D.color(in: scheme)
        if let title = look.columnTitle {
            floor.draw(Text(title).font(.system(size: 15, weight: .bold)).foregroundColor(titleColor),
                       at: CGPoint(x: plane.width / 2, y: ROMSurfaceScene.columnTitleY))
        }
        if let title = look.rowTitle {
            var side = floor
            side.translateBy(x: ROMSurfaceScene.rowTitleX, y: plane.height / 2)
            // Along the rows, and the way round that reads from the left on the screen: turned to
            // the left the plane's own left side faces down, and the name would stand on its head.
            side.rotate(by: .degrees(scene.turn < 0 ? 90 : -90))
            side.draw(Text(title).font(.system(size: 15, weight: .bold)).foregroundColor(titleColor), at: .zero)
        }

        // The tiles, the far ones first.
        for cell in scene.tilesBackToFront {
            let tile = look.cells[cell.row][cell.column]
            let rect = scene.tileRect(row: cell.row, column: cell.column)
            var lifted = context
            lifted.concatenate(scene.transform(height: scene.height(row: cell.row, column: cell.column)))
            if case .heat(let heat) = tile.fill { lifted.fill(Path(rect), with: .color(Color(heat))) }
            lifted.stroke(Path(rect), with: .color(.black.opacity(0.3)), lineWidth: 0.6)
            if let ring = ROMStyle.ring(tile.mark) {
                ROMMapGrid.drawMark(tile.mark, ring: ring, in: rect, context: &lifted, triangle: true)
            }
            if selection.contains(cell) {
                lifted.stroke(Path(rect.insetBy(dx: -1, dy: -1)), with: .color(.white), lineWidth: 2)
                lifted.stroke(Path(rect.insetBy(dx: -3, dy: -3)), with: .color(ROMStyle.selectionRing), lineWidth: 2)
            }
            if numbers {
                lifted.draw(Text(tile.text).font(ROMStyle.mono(10, .bold)).foregroundColor(ROMStyle.cellText), at: rect.center)
            }
        }
    }
}

/// What the selected cell holds, in the words of the strip under a map: now, as opened with the
/// difference, and what the other ROM holds while one is compared.
struct ROMCellNumbers: View {
    let detail: ROMEditor.CellDetail

    var body: some View {
        HStack(spacing: 18) {
            number("Now", detail.now)
            if let other = detail.other {
                number("Other ROM", other).foregroundStyle(ROMStyle.purpleText.color)
            } else if detail.comparing {
                Text("The same in the other ROM").foregroundStyle(.secondary)
            } else if let opened = detail.opened {
                (Text("As opened ") + Text(opened).font(ROMStyle.mono(12, .bold)) + Text(units) + Text(" (\(detail.difference ?? ""))"))
                    .foregroundStyle(ROMStyle.orangeText.color)
            } else {
                Text("Same as opened").foregroundStyle(.secondary)
            }
        }
    }

    private var units: String { detail.units.isEmpty ? "" : " \(detail.units)" }

    private func number(_ title: String, _ value: String) -> Text {
        Text("\(title) ") + Text(value).font(ROMStyle.mono(12, .bold)) + Text(units)
    }
}
