import SSMKit
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var showingPicker = false
    @State private var dragging: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.definitions == nil && model.mode == .ssm {
                    DefinitionsBanner()
                }
                if model.isPlayingBack, let playback = model.playback {
                    DashboardPlaybackBar(playback: playback)
                } else if !model.connection.isConnected {
                    OfflineBanner()
                }
                if let error = model.pollError, model.connection.isConnected {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                if let notice = model.obdNotice, model.connection.isConnected {
                    Label(notice, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                if model.mode == .obd, model.connection.isConnected, model.obdInfo != nil {
                    let hidden = model.dashboardIDs.count - model.visibleDashboardIDs.count
                    if hidden > 0 {
                        Label("\(hidden) gauge\(hidden == 1 ? " is" : "s are") hidden because this car does not report \(hidden == 1 ? "it" : "them"). Add others with the + tile.",
                              systemImage: "eye.slash")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }
                DashboardGridLayout {
                    ForEach(model.visibleDashboardIDs, id: \.self) { id in
                        if let parameter = model.parametersByID[id] {
                            let config = model.tileConfig(for: id)
                            GaugeTile(parameter: parameter, config: config)
                                .tileSpan(config.size)
                                .opacity(dragging == id ? 0.4 : 1)
                                .draggable(id) {
                                    Text(parameter.displayName)
                                        .padding(10)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                        .onAppear { dragging = id }
                                }
                                .dropDestination(for: String.self) { items, _ in
                                    dragging = nil
                                    guard let moved = items.first else { return false }
                                    model.moveTile(moved, before: id)
                                    return true
                                } isTargeted: { _ in }
                                .contextMenu { tileMenu(parameter, id: id, config: config) }
                        }
                    }
                    addButton.tileSpan(.small)
                }
                .animation(.easeOut(duration: 0.2), value: model.visibleDashboardIDs)
                Text("Right-click a gauge to change its style or size. Drag gauges to reorder them.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(18)
        }
        .onDrop(of: [.text], isTargeted: nil) { _ in dragging = nil; return false }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    model.resetExtremes()
                } label: {
                    Label("Reset Peaks", systemImage: "arrow.counterclockwise.circle")
                }
                .help("Reset the min/max markers")
            }
        }
        .sheet(isPresented: $showingPicker) {
            ParameterPicker(title: "Add Gauge", exclude: Set(model.dashboardIDs)) { parameter in
                model.dashboardIDs.append(parameter.id)
            }
        }
    }

    private var addButton: some View {
        Button {
            showingPicker = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle").font(.system(size: 28, weight: .light))
                Text("Add Gauge").font(.callout)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])).foregroundStyle(.quaternary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func tileMenu(_ parameter: ParameterDefinition, id: String, config: TileConfig) -> some View {
        if parameter.kind != .switchBit {
            Picker("Style", selection: Binding(get: { config.style }, set: { model.setTileStyle(id, $0) })) {
                ForEach(GaugeStyle.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
        }
        Picker("Size", selection: Binding(get: { config.size }, set: { model.setTileSize(id, $0) })) {
            ForEach(TileSize.allCases) { Text($0.label).tag($0) }
        }
        if parameter.conversions.count > 1 {
            Menu("Units") {
                ForEach(parameter.conversions, id: \.units) { c in
                    Button(c.displayUnits) { model.unitChoice[parameter.id] = c.units }
                }
            }
        }
        if parameter.kind != .switchBit {
            Button("Reset Min/Max") { model.resetExtremes(for: id) }
        }
        Divider()
        Button("Move to Start") { model.moveTile(id, before: model.dashboardIDs.first ?? id) }
        Button("Remove from Dashboard", role: .destructive) {
            model.dashboardIDs.removeAll { $0 == id }
        }
    }
}

struct OfflineBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.mode.symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Not connected").font(.headline)
                Text(model.mode == .obd
                     ? "Plug the adapter into the OBD port under the dashboard, turn the ignition ON (engine running or not), pick the adapter in the toolbar, then press Connect. No adapter handy? Pick \"Demo OBD-II car\" in the adapter menu."
                     : "Plug the cable into the OBD port under the dashboard, turn the ignition ON (engine running or not), then press Connect. No cable handy? Pick \"Demo ECU\" in the cable menu.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.mode == .ssm {
                Button("Cable Setup…") { model.showCableSetup = true }
            } else {
                Button("Connection Type…") { model.showModeChooser = true }
            }
            Button("Connect") { Task { await model.connect() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.connection == .connecting)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SwitchPill: View {
    let isOn: Bool
    let known: Bool

    var body: some View {
        Text(known ? (isOn ? "ON" : "OFF") : "–")
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .background(isOn ? Color.green.opacity(0.25) : Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(isOn ? .green : .secondary)
    }
}

/// 240° arc gauge with min/max markers.
struct ArcGauge: View {
    let value: Double?
    let range: ClosedRange<Double>
    let peak: ClosedRange<Double>?
    let tint: Color

    private let start = Angle.degrees(150)
    private let sweep = 240.0

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height * 1.25)
            let lineWidth = size * 0.055
            ZStack {
                ArcShape(start: start, degrees: sweep)
                    .stroke(.quaternary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                let origin = range.lowerBound < 0 && range.upperBound > 0 ? fraction(0) : 0
                let end = fraction(value)
                ArcShape(start: start + .degrees(sweep * min(origin, end)), degrees: sweep * abs(end - origin))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                if origin > 0 {
                    Marker(start: start, degrees: sweep * origin, length: lineWidth * 1.2)
                        .stroke(.secondary.opacity(0.6), lineWidth: 1)
                }
                if let peak {
                    Marker(start: start, degrees: sweep * fraction(peak.upperBound), length: lineWidth * 1.6)
                        .stroke(.primary.opacity(0.55), lineWidth: 2)
                    Marker(start: start, degrees: sweep * fraction(peak.lowerBound), length: lineWidth * 1.6)
                        .stroke(.primary.opacity(0.25), lineWidth: 2)
                }
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: size / 2 + lineWidth)
        }
    }

    private func fraction(_ v: Double?) -> Double {
        guard let v, v.isFinite, range.upperBound > range.lowerBound else { return 0 }
        return min(1, max(0, (v - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }
}

struct ArcShape: Shape {
    var start: Angle
    var degrees: Double

    var animatableData: Double {
        get { degrees }
        set { degrees = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2 * 0.88,
                 startAngle: start, endAngle: start + .degrees(degrees), clockwise: false)
        return p
    }
}

struct Marker: Shape {
    var start: Angle
    var degrees: Double
    var length: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = rect.width / 2 * 0.88
        let a = (start + .degrees(degrees)).radians
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.move(to: CGPoint(x: c.x + cos(a) * (r - length / 2), y: c.y + sin(a) * (r - length / 2)))
        p.addLine(to: CGPoint(x: c.x + cos(a) * (r + length / 2), y: c.y + sin(a) * (r + length / 2)))
        return p
    }
}

/// Searchable list for choosing one parameter.
struct ParameterPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let title: String
    let exclude: Set<String>
    let onPick: (ParameterDefinition) -> Void
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            TextField("Search parameters", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
            List(filtered) { p in
                Button {
                    onPick(p)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(p.name)
                            Text(p.kind.label).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "plus.circle").foregroundStyle(Color.scopeBlue)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 440, height: 520)
    }

    private var filtered: [ParameterDefinition] {
        model.parameters.filter { !exclude.contains($0.id) }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
}

extension ParameterKind {
    var label: String {
        switch self {
        case .standard: return "Standard"
        case .extended: return "Extended (ECU specific)"
        case .switchBit: return "Switch"
        case .calculated: return "Calculated"
        }
    }
}

/// Transport shown above the gauges while a log plays back.
struct DashboardPlaybackBar: View {
    @Environment(AppModel.self) private var model
    let playback: LogPlayback

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Playing back \(playback.url.lastPathComponent)").font(.callout.weight(.medium)).lineLimit(1)
                Text("Gauges show the log, min/max are for the whole log.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { playback.togglePlay() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.borderedProminent)
            Slider(value: Binding(get: { playback.playhead }, set: { playback.seek($0) }), in: 0...max(playback.duration, 0.001))
                .frame(minWidth: 180, maxWidth: 320)
            Text("\(formatLogTime(playback.playhead)) / \(formatLogTime(playback.duration))")
                .font(.callout.monospacedDigit())
            Menu("\(playback.speed.formatted())×") {
                ForEach(LogPlayback.speeds, id: \.self) { s in Button("\(s.formatted())×") { playback.speed = s } }
            }
            .fixedSize()
            Button("Charts") { model.section = .logs }
            Button {
                model.closePlayback()
                Task { await model.connect() }
            } label: {
                Label("Connect to Car", systemImage: "bolt.horizontal.fill")
            }
            .help("Stop the playback and show live data from the car")
            Button { model.closePlayback() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close the log")
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Shown until RomRaider's parameter definitions are available.
struct DefinitionsBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if model.downloadingDefinitions {
                ProgressView().controlSize(.small)
                Text("Downloading the parameter definitions (one time only)…")
            } else {
                Image(systemName: "icloud.and.arrow.down").foregroundStyle(.orange)
                Text(model.definitionsError ?? "The parameter definitions are missing.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Try Again") { Task { await model.downloadDefinitions() } }
            }
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}
