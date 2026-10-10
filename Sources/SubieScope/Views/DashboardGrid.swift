import SSMKit
import SwiftUI

// MARK: - Grid layout with spans

private struct TileSpanKey: LayoutValueKey {
    static let defaultValue: (columns: Int, rows: Int) = (1, 1)
}

extension View {
    func tileSpan(_ size: TileSize) -> some View {
        layoutValue(key: TileSpanKey.self, value: size.span)
    }
}

/// Packs tiles row by row into the first free cells, honouring column and row spans.
struct DashboardGridLayout: Layout {
    var minColumnWidth: CGFloat = 210
    var rowHeight: CGFloat = 196
    var spacing: CGFloat = 14

    private func columns(for width: CGFloat) -> Int {
        max(1, Int((width + spacing) / (minColumnWidth + spacing)))
    }

    private func placements(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let cols = columns(for: width)
        let colWidth = (width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        var occupied: [[Bool]] = []
        var frames: [CGRect] = []
        func free(_ r: Int, _ c: Int, _ w: Int, _ h: Int) -> Bool {
            guard c + w <= cols else { return false }
            for rr in r..<(r + h) {
                while occupied.count <= rr { occupied.append(Array(repeating: false, count: cols)) }
                for cc in c..<(c + w) where occupied[rr][cc] { return false }
            }
            return true
        }
        for view in subviews {
            let span = view[TileSpanKey.self]
            let w = min(span.columns, cols), h = span.rows
            var r = 0
            placed: while true {
                for c in 0..<cols where free(r, c, w, h) {
                    for rr in r..<(r + h) { for cc in c..<(c + w) { occupied[rr][cc] = true } }
                    frames.append(CGRect(x: CGFloat(c) * (colWidth + spacing), y: CGFloat(r) * (rowHeight + spacing),
                                         width: CGFloat(w) * colWidth + CGFloat(w - 1) * spacing,
                                         height: CGFloat(h) * rowHeight + CGFloat(h - 1) * spacing))
                    break placed
                }
                r += 1
            }
        }
        let height = frames.map(\.maxY).max() ?? 0
        return (frames, height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        return CGSize(width: width, height: placements(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (frames, _) = placements(subviews, width: bounds.width)
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

// MARK: - Tile

struct GaugeTile: View {
    @Environment(AppModel.self) private var model
    let parameter: ParameterDefinition
    let config: TileConfig

    var body: some View {
        let conversion = model.conversion(for: parameter)
        let value = model.latest[parameter.id]
        let extremes = model.extremes[parameter.id]
        let range = GaugeRange.for(parameter: parameter, conversion: conversion, extremes: extremes)
        let tint = GaugeRange.tint(parameter: parameter, value: value)
        VStack(alignment: .leading, spacing: 6) {
            Text(parameter.displayName)
                .font(config.size == .large ? .title3.weight(.medium) : .callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(parameter.name + (parameter.description.isEmpty ? "" : "\n" + parameter.description))
            if parameter.kind == .switchBit {
                Spacer(minLength: 0)
                SwitchPill(isOn: (value ?? 0) != 0, known: value != nil)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                switch config.style {
                case .dial:
                    GeometryReader { geo in
                        ZStack {
                            ArcGauge(value: value, range: range, peak: extremes, tint: tint)
                            ValueText(value: value, conversion: conversion, size: min(geo.size.width * 0.8, geo.size.height * 1.1) * 0.24)
                                .frame(width: min(geo.size.width, geo.size.height * 1.25) * 0.62)
                                .offset(y: min(geo.size.width, geo.size.height * 1.25) * 0.08)
                        }
                    }
                case .digital:
                    Spacer(minLength: 0)
                    GeometryReader { geo in
                        ValueText(value: value, conversion: conversion, size: min(geo.size.height * 0.62, geo.size.width * 0.3), alignment: .leading)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                    LinearGauge(value: value, range: range, peak: extremes, tint: tint)
                        .frame(height: 6)
                case .bar:
                    ValueText(value: value, conversion: conversion, size: config.size == .large ? 44 : 28, alignment: .leading)
                    Spacer(minLength: 0)
                    LinearGauge(value: value, range: range, peak: extremes, tint: tint)
                        .frame(height: config.size == .large ? 30 : 18)
                    HStack {
                        Text(conversion?.formatted(range.lowerBound) ?? "")
                        Spacer()
                        Text(conversion?.formatted(range.upperBound) ?? "")
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                case .graph:
                    ValueText(value: value, conversion: conversion, size: config.size == .large ? 40 : 26, alignment: .leading)
                    Sparkline(points: model.history[parameter.id] ?? [], window: AppModel.historySeconds, tint: tint)
                }
            }
            if parameter.kind != .switchBit {
                HStack {
                    Text("min \(extremes.map { conversion?.formatted($0.lowerBound) ?? "" } ?? "–")")
                    Spacer()
                    Text("max \(extremes.map { conversion?.formatted($0.upperBound) ?? "" } ?? "–")")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.resetExtremes(for: parameter.id) }
                .help("Double-click to reset min/max")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
    }
}

/// Big number with units. No rolling-digit animation: values change many times a
/// second and must stay readable.
struct ValueText: View {
    let value: Double?
    let conversion: Conversion?
    let size: CGFloat
    var alignment: HorizontalAlignment = .center

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(value.map { conversion?.formatted($0) ?? String(format: "%.2f", $0) } ?? "–")
                .font(.system(size: max(14, size), weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            Text(conversion?.displayUnits ?? "")
                .font(.system(size: max(10, size * 0.32)))
                .foregroundStyle(.secondary)
        }
    }
}

/// Horizontal gauge with min/max markers; fills from zero when the range crosses it.
struct LinearGauge: View {
    let value: Double?
    let range: ClosedRange<Double>
    let peak: ClosedRange<Double>?
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let origin = range.lowerBound < 0 && range.upperBound > 0 ? fraction(0) : 0
            let end = fraction(value)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: h / 2).fill(.quaternary)
                RoundedRectangle(cornerRadius: h / 2).fill(tint)
                    .frame(width: max(h, w * abs(end - origin)))
                    .offset(x: w * min(origin, end))
                    .opacity(value == nil ? 0 : 1)
                if let peak {
                    Rectangle().fill(.primary.opacity(0.55)).frame(width: 2, height: h + 6).offset(x: w * fraction(peak.upperBound) - 1)
                    Rectangle().fill(.primary.opacity(0.25)).frame(width: 2, height: h + 6).offset(x: w * fraction(peak.lowerBound) - 1)
                }
            }
            .frame(height: h)
        }
    }

    private func fraction(_ v: Double?) -> CGFloat {
        guard let v, v.isFinite, range.upperBound > range.lowerBound else { return 0 }
        return CGFloat(min(1, max(0, (v - range.lowerBound) / (range.upperBound - range.lowerBound))))
    }
}

enum GaugeRange {
    static func `for`(parameter: ParameterDefinition, conversion: Conversion?, extremes: ClosedRange<Double>?) -> ClosedRange<Double> {
        let key = parameter.displayName.lowercased()
        var range: ClosedRange<Double>
        if let lo = conversion?.gaugeMin, let hi = conversion?.gaugeMax, hi > lo {
            range = lo...hi
        } else if key == "iam" {
            range = 0...1
        } else if conversion?.units.lowercased() == "lambda" {
            range = 0.6...1.4
        } else if let extremes, extremes.upperBound > extremes.lowerBound {
            let pad = (extremes.upperBound - extremes.lowerBound) * 0.1
            return (extremes.lowerBound - pad)...(extremes.upperBound + pad)
        } else if let v = extremes?.upperBound {
            range = v >= 0 ? 0...max(1, v * 2) : (v * 2)...0
        } else {
            range = 0...100
        }
        // Never let the needle pin against the end of a too-narrow factory range.
        if let extremes {
            range = min(range.lowerBound, extremes.lowerBound)...max(range.upperBound, extremes.upperBound)
        }
        return range
    }

    /// Knock correction below zero and a dropped IAM are the things to watch.
    static func tint(parameter: ParameterDefinition, value: Double?) -> Color {
        guard let value else { return .scopeBlue }
        let name = parameter.name.lowercased()
        if name.contains("knock") && !name.contains("sum") && value < 0 {
            return value <= -2 ? .red : .orange
        }
        if name.hasPrefix("iam") {
            return value < 1 && value >= 0 ? (value < 0.75 ? .red : .orange) : .green
        }
        return .scopeBlue
    }
}
