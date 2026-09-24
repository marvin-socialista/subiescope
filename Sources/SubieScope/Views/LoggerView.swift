import SSMKit
import SwiftUI

struct LoggerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            ParameterBrowser()
                .frame(width: 400)
            Divider()
            LiveTrends()
                .frame(maxWidth: .infinity)
        }
    }
}

struct ParameterBrowser: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var showOnlyLogged = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                TextField("Search \(model.parameters.count) parameters", text: $query)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Picker("Show", selection: $showOnlyLogged) {
                        Text("All").tag(false)
                        Text("Logged (\(loggedCount))").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Menu {
                        Button("Log Nothing") { model.loggedIDs = [] }
                        Button("Log Dashboard Gauges") { model.loggedIDs = Set(model.dashboardIDs) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(10)
            Divider()
            List {
                if !model.connection.isConnected {
                    Text("Offline: showing every parameter in the definitions. After connecting, only the ones your ECU supports remain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(sections, id: \.title) { section in
                    Section {
                        ForEach(section.items) { p in
                            ParameterRow(parameter: p)
                        }
                    } header: {
                        Text("\(section.title) · \(section.items.count)")
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Text(speedHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(8)
        }
    }

    private var loggedCount: Int {
        model.parameters.filter { model.loggedIDs.contains($0.id) }.count
    }

    private var speedHint: String {
        let bytes = model.parameters.filter { model.loggedIDs.union(model.dashboardIDs).contains($0.id) }
            .reduce(0) { $0 + max(1, $1.addresses.count) }
        let rate = model.samplesPerSecond > 0 ? String(format: " · %.1f samples/s", model.samplesPerSecond) : ""
        return "\(bytes) addresses polled\(rate). Fewer parameters log faster."
    }

    private var sections: [(title: String, items: [ParameterDefinition])] {
        let filtered = model.parameters.filter { p in
            (!showOnlyLogged || model.loggedIDs.contains(p.id))
                && (query.isEmpty || p.name.localizedCaseInsensitiveContains(query) || p.id.localizedCaseInsensitiveContains(query))
        }
        let groups: [(String, ParameterKind)] = [
            ("Standard", .standard), ("ECU Specific (Extended)", .extended), ("Calculated", .calculated), ("Switches", .switchBit),
        ]
        return groups.map { title, kind in (title, filtered.filter { $0.kind == kind }) }.filter { !$0.items.isEmpty }
    }
}

struct ParameterRow: View {
    @Environment(AppModel.self) private var model
    let parameter: ParameterDefinition

    var body: some View {
        let logged = Binding(
            get: { model.loggedIDs.contains(parameter.id) },
            set: { on in
                if on { model.loggedIDs.insert(parameter.id) } else { model.loggedIDs.remove(parameter.id) }
            }
        )
        let onDashboard = model.dashboardIDs.contains(parameter.id)
        let conversion = model.conversion(for: parameter)
        HStack(spacing: 8) {
            Toggle(isOn: logged) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Log this parameter")
            VStack(alignment: .leading, spacing: 1) {
                Text(parameter.name).lineLimit(1)
                if !parameter.description.isEmpty && parameter.description != parameter.id {
                    Text(parameter.description.replacingOccurrences(of: "\(parameter.id)-", with: ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .help(parameter.description)
            Spacer(minLength: 4)
            if let value = model.latest[parameter.id] {
                Text(parameter.kind == .switchBit ? (value != 0 ? "ON" : "OFF") : (conversion?.formatted(value) ?? ""))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            if parameter.kind != .switchBit {
                if parameter.conversions.count > 1 {
                    Menu(conversion?.displayUnits ?? "") {
                        ForEach(parameter.conversions, id: \.units) { c in
                            Button(c.displayUnits) { model.unitChoice[parameter.id] = c.units }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.caption)
                } else {
                    Text(conversion?.displayUnits ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                if onDashboard { model.dashboardIDs.removeAll { $0 == parameter.id } } else { model.dashboardIDs.append(parameter.id) }
            } label: {
                Image(systemName: onDashboard ? "gauge.with.dots.needle.bottom.50percent.badge.minus" : "gauge.with.dots.needle.bottom.50percent.badge.plus")
                    .foregroundStyle(onDashboard ? Color.scopeBlue : .secondary)
            }
            .buttonStyle(.borderless)
            .help(onDashboard ? "Remove from Dashboard" : "Add to Dashboard")
        }
        .contentShape(Rectangle())
    }
}

struct LiveTrends: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            RecordingBar()
            Divider()
            let items = trended
            if items.isEmpty {
                ContentUnavailableView("Nothing to show yet",
                                       systemImage: "waveform.path.ecg",
                                       description: Text(model.connection.isConnected
                                                         ? "Tick parameters on the left to log them."
                                                         : "Connect to the car to see live values."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { p in
                            TrendRow(parameter: p)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var trended: [ParameterDefinition] {
        if model.isPlayingBack { return model.parameters.filter { $0.kind != .switchBit } }
        return model.parameters.filter { model.loggedIDs.contains($0.id) && $0.kind != .switchBit }
    }
}

struct RecordingBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if model.isRecording, let url = model.recordingURL {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Recording \(url.lastPathComponent)").font(.callout.weight(.medium))
                    Text("\(model.recordedRows) rows · \(String(format: "%.1f", model.samplesPerSecond)) samples/s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "record.circle").foregroundStyle(.secondary)
                Text(model.connection.isConnected ? "Press Record (⌘R) to save the ticked parameters to a CSV file."
                                                   : "Not connected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.isRecording ? "Stop" : "Record") { model.toggleRecording() }
                .buttonStyle(.borderedProminent)
                .tint(model.isRecording ? .red : .scopeBlue)
                .disabled(!model.connection.isConnected || model.loggedIDs.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct TrendRow: View {
    @Environment(AppModel.self) private var model
    let parameter: ParameterDefinition

    var body: some View {
        let conversion = model.conversion(for: parameter)
        let points = model.history[parameter.id] ?? []
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(parameter.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(model.latest[parameter.id].map { conversion?.formatted($0) ?? "" } ?? "–")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text(conversion?.displayUnits ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, alignment: .leading)
            Sparkline(points: points, window: AppModel.historySeconds, tint: .scopeBlue)
                .frame(height: 54)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Lightweight line plot over the last `window` seconds.
struct Sparkline: View {
    let points: [ChartPoint]
    let window: Double
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard points.count > 1, let last = points.last else { return }
            let lo = points.map(\.value).min() ?? 0
            let hi = points.map(\.value).max() ?? 1
            let span = hi - lo == 0 ? 1 : hi - lo
            func pos(_ p: ChartPoint) -> CGPoint {
                let x = size.width * CGFloat(1 - (last.t - p.t) / window)
                let y = size.height * CGFloat(1 - (p.value - lo) / span) * 0.9 + size.height * 0.05
                return CGPoint(x: x, y: y)
            }
            var line = Path()
            line.move(to: pos(points[0]))
            for p in points.dropFirst() { line.addLine(to: pos(p)) }
            var fill = line
            fill.addLine(to: CGPoint(x: pos(last).x, y: size.height))
            fill.addLine(to: CGPoint(x: pos(points[0]).x, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.25), tint.opacity(0.02)]),
                                                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            let labelStyle = Font.system(size: 9).monospacedDigit()
            context.draw(Text(String(format: "%.4g", hi)).font(labelStyle).foregroundStyle(.secondary), at: CGPoint(x: 2, y: 2), anchor: .topLeading)
            context.draw(Text(String(format: "%.4g", lo)).font(labelStyle).foregroundStyle(.secondary), at: CGPoint(x: 2, y: size.height - 2), anchor: .bottomLeading)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.35)))
    }
}
