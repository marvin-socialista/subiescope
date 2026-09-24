import SSMKit
import SwiftUI

/// Plot area insets shared by every chart so one cursor line lines up across all of them.
private enum PlotInsets {
    static let leading: CGFloat = 60
    static let trailing: CGFloat = 14
}

struct LogViewerView: View {
    let playback: LogPlayback

    var body: some View {
        VStack(spacing: 0) {
            PlaybackControls(playback: playback)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if playback.chartColumns.isEmpty {
                        ContentUnavailableView("No charts", systemImage: "chart.xyaxis.line",
                                               description: Text("Click values in the snapshot list to chart them."))
                    } else {
                        ChartStack(playback: playback)
                    }
                    Divider()
                    OverviewStrip(playback: playback)
                        .frame(height: 58)
                }
                .frame(maxWidth: .infinity)
                Divider()
                SnapshotPanel(playback: playback)
                    .frame(width: 300)
            }
        }
    }
}

// MARK: - Transport

struct PlaybackControls: View {
    @Environment(AppModel.self) private var model
    let playback: LogPlayback

    var body: some View {
        @Bindable var playback = playback
        HStack(spacing: 10) {
            Button { playback.seek(0) } label: { Image(systemName: "backward.end.fill") }
                .help("Back to the start")
            Button { playback.step(rows: -1) } label: { Image(systemName: "backward.frame.fill") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous sample (←)")
            Button { playback.togglePlay() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.borderedProminent)
            .help(playback.isPlaying ? "Pause (space)" : "Play (space)")
            Button { playback.step(rows: 1) } label: { Image(systemName: "forward.frame.fill") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next sample (→)")

            Text("\(formatLogTime(playback.playhead)) / \(formatLogTime(playback.duration))")
                .font(.body.monospacedDigit())
                .frame(minWidth: 120, alignment: .leading)

            Menu("\(playback.speed.formatted())×") {
                ForEach(LogPlayback.speeds, id: \.self) { s in
                    Button("\(s.formatted())×") { playback.speed = s }
                }
            }
            .fixedSize()
            .help("Playback speed")

            if playback.isZoomed {
                Button("Zoom Out") { playback.resetZoom() }
                    .help("Show the whole log (or double-click a chart)")
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(playback.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                Text("\(playback.log.rowCount) rows · \(playback.log.columns.count) values · \(sampleRate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                model.section = .dashboard
            } label: {
                Label("Gauges", systemImage: "gauge.with.dots.needle.67percent")
            }
            .help(model.connection.isConnected ? "The dashboard shows live data while connected" : "Watch the playback on the dashboard gauges")
            .disabled(model.connection.isConnected)
            Button { model.closePlayback() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close this log")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sampleRate: String {
        guard playback.duration > 0 else { return "" }
        return String(format: "%.1f samples/s", Double(playback.log.rowCount - 1) / playback.duration)
    }
}

// MARK: - Charts

struct ChartStack: View {
    let playback: LogPlayback
    private let axisHeight: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let count = CGFloat(playback.chartColumns.count)
            let fitted = (geo.size.height - axisHeight) / max(count, 1)
            let rowHeight = max(96, fitted)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(playback.chartColumns, id: \.self) { column in
                        SeriesChart(playback: playback, column: column)
                            .frame(height: rowHeight)
                    }
                    TimeAxis(range: playback.visibleRange)
                        .frame(height: axisHeight)
                }
                .overlay { CursorLayer(playback: playback) }
            }
            .scrollDisabled(rowHeight == fitted)
        }
    }
}

/// One measure, one axis. Title and value in text colors; the line carries the series color.
struct SeriesChart: View {
    let playback: LogPlayback
    let column: Int

    var body: some View {
        let range = playback.visibleRange
        let yRange = Self.yRange(playback.log, column: column, range: range)
        let color = SeriesPalette.color(playback.colorSlots[column] ?? 0)
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 14, height: 3)
                Text(playback.parameters[column].displayName).font(.caption.weight(.medium))
                Text(playback.conversions[column].displayUnits).font(.caption).foregroundStyle(.secondary)
                Spacer()
                SnapshotValueLabel(playback: playback, column: column)
            }
            .padding(.leading, PlotInsets.leading)
            .padding(.trailing, PlotInsets.trailing)
            ZStack {
                Canvas { context, size in
                    Self.draw(context: context, size: size, log: playback.log, column: column, range: range,
                              yRange: yRange, color: color, decimals: playback.conversions[column].decimals)
                }
                HoverDot(playback: playback, column: column, yRange: yRange, color: color)
            }
        }
        .padding(.top, 6)
        .contextMenu {
            Button("Move Up") { playback.moveChart(column, up: true) }
            Button("Move Down") { playback.moveChart(column, up: false) }
            Button("Remove Chart") { playback.toggleChart(column) }
        }
    }

    static func yRange(_ log: RecordedLog, column: Int, range: ClosedRange<Double>) -> ClosedRange<Double> {
        let first = log.row(at: range.lowerBound), last = min(log.rowCount - 1, log.row(at: range.upperBound) + 1)
        var lo = Double.infinity, hi = -Double.infinity
        if first <= last {
            for i in first...last {
                let v = log.values[column][i]
                if v.isFinite { lo = min(lo, v); hi = max(hi, v) }
            }
        }
        guard lo.isFinite else { return 0...1 }
        if hi - lo < 1e-9 {
            let pad = max(abs(lo) * 0.1, 1)
            return (lo - pad)...(hi + pad)
        }
        let pad = (hi - lo) * 0.08
        return (lo - pad)...(hi + pad)
    }

    static func draw(context: GraphicsContext, size: CGSize, log: RecordedLog, column: Int, range: ClosedRange<Double>,
                     yRange: ClosedRange<Double>, color: Color, decimals: Int) {
        let plot = CGRect(x: PlotInsets.leading, y: 4, width: size.width - PlotInsets.leading - PlotInsets.trailing,
                          height: size.height - 10)
        guard plot.width > 10, plot.height > 10, log.rowCount > 0 else { return }
        let span = range.upperBound - range.lowerBound
        let ySpan = yRange.upperBound - yRange.lowerBound
        func x(_ t: Double) -> CGFloat { plot.minX + CGFloat((t - range.lowerBound) / span) * plot.width }
        func y(_ v: Double) -> CGFloat { plot.maxY - CGFloat((v - yRange.lowerBound) / ySpan) * plot.height }

        // Recessive grid: 3 horizontal lines with labels, vertical lines at time ticks.
        let grid = Color.secondary.opacity(0.15)
        for i in 0...2 {
            let v = yRange.lowerBound + ySpan * (0.1 + 0.4 * Double(i))
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y(v)))
            line.addLine(to: CGPoint(x: plot.maxX, y: y(v)))
            context.stroke(line, with: .color(grid), lineWidth: 1)
            context.draw(Text(String(format: "%.\(min(decimals, 3))f", v)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: plot.minX - 6, y: y(v)), anchor: .trailing)
        }
        for t in TimeAxis.ticks(range) {
            var line = Path()
            line.move(to: CGPoint(x: x(t), y: plot.minY))
            line.addLine(to: CGPoint(x: x(t), y: plot.maxY))
            context.stroke(line, with: .color(grid.opacity(0.6)), lineWidth: 1)
        }

        // Line with min/max decimation per pixel column so long logs stay fast and spikes stay visible.
        let first = max(0, log.row(at: range.lowerBound) - 1)
        let last = min(log.rowCount - 1, log.row(at: range.upperBound) + 1)
        guard first <= last else { return }
        let columns = max(1, Int(plot.width))
        let rows = last - first + 1
        var path = Path()
        var penDown = false
        func plotPoint(_ t: Double, _ v: Double) {
            guard v.isFinite else { penDown = false; return }
            let p = CGPoint(x: x(t), y: y(v))
            if penDown { path.addLine(to: p) } else { path.move(to: p); penDown = true }
        }
        if rows <= columns * 2 {
            for i in first...last { plotPoint(log.time[i], log.values[column][i]) }
        } else {
            var bucket = -1
            var minV = 0.0, maxV = 0.0, minT = 0.0, maxT = 0.0, has = false
            func flush() {
                guard has else { return }
                if minT <= maxT { plotPoint(minT, minV); plotPoint(maxT, maxV) } else { plotPoint(maxT, maxV); plotPoint(minT, minV) }
            }
            for i in first...last {
                let t = log.time[i], v = log.values[column][i]
                let b = Int((t - range.lowerBound) / span * Double(columns))
                if b != bucket { flush(); bucket = b; has = false }
                guard v.isFinite else { continue }
                if !has { minV = v; maxV = v; minT = t; maxT = t; has = true }
                if v < minV { minV = v; minT = t }
                if v > maxV { maxV = v; maxT = t }
            }
            flush()
        }
        context.drawLayer { layer in
            layer.clip(to: Path(plot.insetBy(dx: 0, dy: -2)))
            layer.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Value at the snapshot time, redrawn on its own so the chart line is not.
struct SnapshotValueLabel: View {
    let playback: LogPlayback
    let column: Int

    var body: some View {
        let v = playback.value(column, at: playback.snapshotTime)
        Text(v.isFinite ? playback.conversions[column].formatted(v) : "–")
            .font(.callout.weight(.semibold).monospacedDigit())
    }
}

struct HoverDot: View {
    let playback: LogPlayback
    let column: Int
    let yRange: ClosedRange<Double>
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let t = playback.snapshotTime
            let range = playback.visibleRange
            let v = playback.value(column, at: t)
            let plotWidth = geo.size.width - PlotInsets.leading - PlotInsets.trailing
            let plotHeight = geo.size.height - 10
            if v.isFinite, range.contains(t), plotWidth > 0 {
                let x = PlotInsets.leading + CGFloat((t - range.lowerBound) / (range.upperBound - range.lowerBound)) * plotWidth
                let y = 4 + plotHeight - CGFloat((v - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound)) * plotHeight
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    .position(x: x, y: y)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Playhead, hover crosshair, drag-to-zoom selection and all mouse handling.
struct CursorLayer: View {
    let playback: LogPlayback
    @State private var dragStart: CGFloat?
    @State private var dragCurrent: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width - PlotInsets.leading - PlotInsets.trailing
            let range = playback.visibleRange
            let span = range.upperBound - range.lowerBound
            let toX = { (t: Double) -> CGFloat in PlotInsets.leading + CGFloat((t - range.lowerBound) / span) * width }
            let toT = { (x: CGFloat) -> Double in
                range.lowerBound + Double(min(max(0, (x - PlotInsets.leading) / max(width, 1)), 1)) * span
            }
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                if let a = dragStart, let b = dragCurrent, abs(b - a) > 3 {
                    Rectangle()
                        .fill(Color.scopeBlue.opacity(0.12))
                        .overlay(Rectangle().stroke(Color.scopeBlue.opacity(0.5), lineWidth: 1))
                        .frame(width: abs(b - a), height: geo.size.height)
                        .offset(x: min(a, b))
                }
                if range.contains(playback.playhead) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.8))
                        .frame(width: 1.5, height: geo.size.height)
                        .offset(x: toX(playback.playhead) - 0.75)
                }
                if let hover = playback.hoverTime {
                    Path { p in
                        p.move(to: CGPoint(x: toX(hover), y: 0))
                        p.addLine(to: CGPoint(x: toX(hover), y: geo.size.height))
                    }
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Text(formatLogTime(hover, decimals: 2))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: min(toX(hover) + 6, geo.size.width - 70), y: geo.size.height - 20)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p) where p.x >= PlotInsets.leading && p.x <= geo.size.width - PlotInsets.trailing:
                    playback.hoverTime = toT(p.x)
                default:
                    playback.hoverTime = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStart == nil { dragStart = value.startLocation.x }
                        dragCurrent = value.location.x
                        playback.hoverTime = toT(value.location.x)
                    }
                    .onEnded { value in
                        defer { dragStart = nil; dragCurrent = nil }
                        let a = value.startLocation.x, b = value.location.x
                        if abs(b - a) <= 3 {
                            playback.seek(toT(b))
                        } else {
                            playback.zoom(to: toT(min(a, b))...toT(max(a, b)))
                        }
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { playback.resetZoom() })
            .simultaneousGesture(
                MagnifyGesture()
                    .onEnded { value in
                        let anchor = playback.hoverTime ?? (range.lowerBound + span / 2)
                        playback.zoom(by: 1 / max(0.1, value.magnification), around: anchor)
                    }
            )
        }
        .help("Hover to inspect · click to move the playhead · drag to zoom in · double-click to zoom out")
    }
}

struct TimeAxis: View {
    let range: ClosedRange<Double>

    static func ticks(_ range: ClosedRange<Double>, targetCount: Double = 8) -> [Double] {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return [] }
        let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200]
        let step = steps.first { span / $0 <= targetCount } ?? 1800
        var t = (range.lowerBound / step).rounded(.up) * step
        var out: [Double] = []
        while t <= range.upperBound + 1e-9 {
            out.append(t)
            t += step
        }
        return out
    }

    var body: some View {
        Canvas { context, size in
            let width = size.width - PlotInsets.leading - PlotInsets.trailing
            let span = range.upperBound - range.lowerBound
            guard width > 0, span > 0 else { return }
            let decimals = span < 5 ? 2 : (span < 60 ? 1 : 0)
            for t in Self.ticks(range) {
                let x = PlotInsets.leading + CGFloat((t - range.lowerBound) / span) * width
                context.draw(Text(formatLogTime(t, decimals: decimals)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary),
                             at: CGPoint(x: x, y: size.height / 2))
            }
        }
    }
}

// MARK: - Overview

/// The whole log in miniature, with the zoomed window and the playhead. Drag to move.
struct OverviewStrip: View {
    let playback: LogPlayback

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width - PlotInsets.leading - PlotInsets.trailing
            let duration = max(playback.duration, 0.001)
            let toX = { (t: Double) -> CGFloat in PlotInsets.leading + CGFloat(t / duration) * width }
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    guard let column = playback.chartColumns.first else { return }
                    let full = 0...duration
                    SeriesChart.draw(context: context, size: size, log: playback.log, column: column, range: full,
                                     yRange: SeriesChart.yRange(playback.log, column: column, range: full),
                                     color: .secondary.opacity(0.7), decimals: 0)
                }
                .opacity(0.9)
                let range = playback.visibleRange
                Rectangle()
                    .fill(Color.scopeBlue.opacity(playback.isZoomed ? 0.16 : 0.0))
                    .overlay(Rectangle().stroke(Color.scopeBlue.opacity(playback.isZoomed ? 0.7 : 0), lineWidth: 1))
                    .frame(width: max(2, toX(range.upperBound) - toX(range.lowerBound)), height: geo.size.height)
                    .offset(x: toX(range.lowerBound))
                Rectangle()
                    .fill(Color.primary.opacity(0.8))
                    .frame(width: 1.5, height: geo.size.height)
                    .offset(x: toX(playback.playhead) - 0.75)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let t = Double(min(max(0, (value.location.x - PlotInsets.leading) / max(width, 1)), 1)) * duration
                if playback.isZoomed {
                    let w = playback.visibleRange.upperBound - playback.visibleRange.lowerBound
                    let lo = min(max(0, t - w / 2), duration - w)
                    playback.zoom(to: lo...(lo + w))
                }
                playback.seek(t)
            })
        }
        .help("Whole log. Drag to move through it.")
    }
}

// MARK: - Snapshot

/// Every logged value at the hovered time (or the playhead).
struct SnapshotPanel: View {
    let playback: LogPlayback
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Snapshot").font(.headline)
                    Spacer()
                    Text(formatLogTime(playback.snapshotTime, decimals: 2))
                        .font(.body.monospacedDigit().weight(.semibold))
                }
                Text(playback.hoverTime != nil ? "Values under the pointer" : "Values at the playhead · hover a chart to inspect")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $query)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(12)
            Divider()
            let row = playback.log.row(at: playback.snapshotTime)
            List {
                ForEach(filtered, id: \.self) { column in
                    SnapshotRow(playback: playback, column: column, row: row)
                        .contentShape(Rectangle())
                        .onTapGesture { playback.toggleChart(column) }
                }
            }
            .listStyle(.inset)
            Text("Click a value to add or remove its chart.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private var filtered: [Int] {
        playback.log.columns.indices.filter { query.isEmpty || playback.log.columns[$0].name.localizedCaseInsensitiveContains(query) }
    }
}

struct SnapshotRow: View {
    let playback: LogPlayback
    let column: Int
    let row: Int

    var body: some View {
        let v = playback.log.rowCount > 0 ? playback.log.values[column][row] : .nan
        let conversion = playback.conversions[column]
        let charted = playback.colorSlots[column]
        HStack(spacing: 8) {
            Circle()
                .fill(charted.map { SeriesPalette.color($0) } ?? .clear)
                .overlay(Circle().stroke(charted == nil ? Color.secondary.opacity(0.5) : .clear, lineWidth: 1))
                .frame(width: 9, height: 9)
            Text(playback.parameters[column].displayName)
                .lineLimit(1)
                .help(playback.log.columns[column].header)
            Spacer(minLength: 6)
            Text(v.isFinite ? conversion.formatted(v) : "–")
                .monospacedDigit()
                .fontWeight(.medium)
            Text(conversion.displayUnits)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
                .lineLimit(1)
        }
    }
}
