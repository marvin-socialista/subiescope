import AppKit
import Charts
import SSMKit
import SwiftUI
import UniformTypeIdentifiers

struct DynoView: View {
    @Environment(AppModel.self) private var model
    @State private var files: [LogFile] = []
    @State private var selectedURL: URL?
    @State private var log: RecordedLog?
    @State private var runs: [DynoRun] = []
    @State private var shownRuns: Set<Int> = []
    @State private var settings = DynoView.loadSettings()
    @State private var autoGear = true
    @State private var unit: PowerUnit = UserDefaults.standard.string(forKey: "dynoUnit").flatMap(PowerUnit.init(rawValue:)) ?? .ps
    @State private var hoverRPM: Double?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 300)
            Divider()
            results
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            reloadFiles()
            if selectedURL == nil { selectedURL = model.playback?.url ?? files.first?.url }
        }
        .task(id: selectedURL) { await load() }
        .onChange(of: settings) { _, new in
            if let data = try? JSONEncoder().encode(new) { UserDefaults.standard.set(data, forKey: "dynoSettings") }
            recompute()
        }
        .onChange(of: autoGear) { _, _ in recompute() }
        .onChange(of: unit) { _, u in UserDefaults.standard.set(u.rawValue, forKey: "dynoUnit") }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        Form {
            Section("Log") {
                Picker("Log", selection: $selectedURL) {
                    Text("Choose a log").tag(URL?.none)
                    ForEach(files) { f in Text(f.url.lastPathComponent).tag(Optional(f.url)) }
                    if let url = selectedURL, !files.contains(where: { $0.url == url }) {
                        Text(url.lastPathComponent).tag(Optional(url))
                    }
                }
                .labelsHidden()
                Button("Open Other Log…") { openPanel() }
                Text("Record a pull with Troubleshooting › Full-throttle pull, or log Engine Speed and Throttle (Vehicle Speed and Intake Air Temperature help).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Car") {
                Menu("Fill In From a Car") {
                    ForEach(carYears, id: \.self) { year in
                        Menu(String(year)) {
                            ForEach(DynoCar.library.filter { $0.year == year }) { car in
                                Button(car.name) { settings = settings.applying(car) }
                            }
                        }
                    }
                }
                .help("Takes the weight, gear ratios, final drive, tyre size and drag of a car from RomRaider's list. Check them against your own car afterwards.")
                number("Weight with driver", $settings.massKg, "kg", 0)
                Toggle("Detect gear from speed", isOn: $autoGear)
                if !autoGear {
                    Picker("Gear", selection: Binding(get: { settings.gear ?? 3 }, set: { settings.gear = $0 })) {
                        ForEach(1...settings.gearRatios.count, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
                LabeledContent("Tyres") {
                    HStack(spacing: 2) {
                        TextField("", value: $settings.tireWidthMM, format: .number).frame(width: 44)
                        Text("/")
                        TextField("", value: $settings.tireAspect, format: .number).frame(width: 32)
                        Text("R")
                        TextField("", value: $settings.rimInches, format: .number).frame(width: 32)
                    }
                    .multilineTextAlignment(.trailing)
                }
                number("Final drive", $settings.finalDrive, "", 3)
                number("Drag coefficient", $settings.dragCoefficient, "", 2)
                number("Frontal area", $settings.frontalAreaM2, "m²", 2)
                number("Drivetrain loss", Binding(get: { settings.drivetrainLoss * 100 }, set: { settings.drivetrainLoss = $0 / 100 }), "%", 0)
                Button("Reset to 2008 STI (GRB) values") { settings = DynoSettings() }
            }
            Section("Display") {
                Picker("Power in", selection: $unit) {
                    ForEach(PowerUnit.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var carYears: [Int] {
        Array(Set(DynoCar.library.map(\.year))).sorted()
    }

    private func number(_ title: String, _ value: Binding<Double>, _ units: String, _ decimals: Int) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("", value: value, format: .number.precision(.fractionLength(decimals)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                if !units.isEmpty { Text(units).foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if selectedURL == nil {
            ContentUnavailableView("Choose a log", systemImage: "chart.line.uptrend.xyaxis",
                                   description: Text("The virtual dyno turns a full-throttle pull into a power and torque curve."))
        } else if runs.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("No full-throttle pull found in this log", systemImage: "flag.checkered")
                        .font(.title3.weight(.semibold))
                    Text("A pull needs full throttle with rising rpm for at least 1.5 seconds and 1,500 rpm, in one gear.")
                        .foregroundStyle(.secondary)
                    DynoPullGuide(expanded: true)
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DynoPullGuide(expanded: false)
                    pullVerdict
                    peaks
                    runList
                    DynoChart(title: "Wheel power", unitLabel: unit.label, runs: visibleRuns, hoverRPM: $hoverRPM,
                              value: { unit.convert($0.wheelPower) })
                    DynoChart(title: "Torque at the wheels, at engine speed", unitLabel: "Nm", runs: visibleRuns, hoverRPM: $hoverRPM,
                              value: { $0.torque })
                    Text("An estimate from acceleration, weight and gearing. Road slope, wind, tyre slip and clutch slip all change the result: compare pulls made in the same gear on the same stretch of road.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
        }
    }

    private var visibleRuns: [DynoRun] { runs.filter { shownRuns.contains($0.id) } }

    /// Plain-language answer to "was that a good pull?"
    private var pullVerdict: some View {
        let best = runs.min { $0.quality.verdict < $1.quality.verdict }
        let q = best?.quality ?? PullQuality(verdict: .retry, issues: [])
        let color: Color = q.verdict == .good ? .green : (q.verdict == .usable ? .orange : .red)
        let symbol = q.verdict == .good ? "checkmark.circle.fill" : (q.verdict == .usable ? "exclamationmark.circle.fill" : "arrow.counterclockwise.circle.fill")
        let title: String = {
            switch q.verdict {
            case .good: return runs.count > 1 ? "Pull \(best?.id ?? 1) is a good pull. Trust these numbers." : "Good pull. Trust these numbers."
            case .usable: return "Usable pull, but see the notes before trusting the numbers."
            case .retry: return "Retry: this pull isn't good enough for a reliable result."
            }
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
            ForEach(q.issues, id: \.self) { issue in
                Label(issue, systemImage: "arrow.turn.down.right")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Peaks come only from the best-rated visible pulls: a "retry" pull shouldn't set the headline number.
    private var trustedRuns: [DynoRun] {
        guard let bestVerdict = visibleRuns.map(\.quality.verdict).min() else { return [] }
        return visibleRuns.filter { $0.quality.verdict == bestVerdict }
    }

    private var peaks: some View {
        let best = trustedRuns.compactMap(\.peakPower).max { $0.wheelPower < $1.wheelPower }
        let bestTorque = trustedRuns.compactMap(\.peakTorque).max { $0.torque < $1.torque }
        let loss = settings.drivetrainLoss
        return HStack(spacing: 12) {
            StatTile(title: "Peak wheel power", value: best.map { String(format: "%.0f", unit.convert($0.wheelPower)) } ?? "–",
                     unit: unit.label, detail: best.map { "at \(Int($0.rpm)) rpm" } ?? "")
            StatTile(title: "Peak torque", value: bestTorque.map { String(format: "%.0f", $0.torque) } ?? "–",
                     unit: "Nm", detail: bestTorque.map { "at \(Int($0.rpm)) rpm" } ?? "")
            StatTile(title: "Estimated at the crank", value: best.map { String(format: "%.0f", unit.convert($0.wheelPower / (1 - loss))) } ?? "–",
                     unit: unit.label, detail: "with \(Int(loss * 100)) % drivetrain loss")
        }
    }

    private var runList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pulls in this log").font(.headline)
            ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                Toggle(isOn: Binding(get: { shownRuns.contains(run.id) }, set: { on in
                    if on { shownRuns.insert(run.id) } else { shownRuns.remove(run.id) }
                })) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1).fill(SeriesPalette.color(index)).frame(width: 14, height: 3)
                        Text("Pull \(run.id)")
                        Text("gear \(run.gear) · \(Int(run.rpmRange?.lowerBound ?? 0))–\(Int(run.rpmRange?.upperBound ?? 0)) rpm · at \(formatLogTime(run.startTime, decimals: 0))")
                            .foregroundStyle(.secondary)
                        if let p = run.peakPower {
                            Text("\(String(format: "%.0f", unit.convert(p.wheelPower))) \(unit.label)").monospacedDigit()
                        }
                        Text(run.quality.headline)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background((run.quality.verdict == .good ? Color.green : (run.quality.verdict == .usable ? Color.orange : Color.red)).opacity(0.18), in: Capsule())
                            .help(run.quality.issues.joined(separator: "\n"))
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    // MARK: Data

    private func reloadFiles() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: model.logsFolder, includingPropertiesForKeys: keys)) ?? []
        files = urls.filter { $0.pathExtension.lowercased() == "csv" }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return LogFile(url: url, date: values?.contentModificationDate ?? .distantPast, size: values?.fileSize ?? 0)
        }
        .sorted { $0.date > $1.date }
    }

    private func load() async {
        guard let url = selectedURL else { log = nil; runs = []; return }
        log = try? await Task.detached { try RecordedLog.load(url) }.value
        recompute()
        shownRuns = Set(runs.map(\.id))
    }

    private func recompute() {
        guard let log else { runs = []; return }
        var s = settings
        if autoGear { s.gear = nil }
        runs = VirtualDyno.runs(log: log, settings: s)
        if shownRuns.isEmpty || !shownRuns.isSubset(of: Set(runs.map(\.id))) { shownRuns = Set(runs.map(\.id)) }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.directoryURL = model.logsFolder
        if panel.runModal() == .OK { selectedURL = panel.url }
    }

    static func loadSettings() -> DynoSettings {
        UserDefaults.standard.data(forKey: "dynoSettings").flatMap { try? JSONDecoder().decode(DynoSettings.self, from: $0) } ?? DynoSettings()
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let unit: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).foregroundStyle(.secondary)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One measure per chart; runs share the rpm axis. Hover shows every run's value.
struct DynoChart: View {
    let title: String
    let unitLabel: String
    let runs: [DynoRun]
    @Binding var hoverRPM: Double?
    let value: (DynoPoint) -> Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Text(unitLabel).foregroundStyle(.secondary)
                Spacer()
                if let rpm = hoverRPM {
                    Text(readout(at: rpm)).font(.callout.monospacedDigit())
                }
            }
            Chart {
                ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                    ForEach(run.points, id: \.rpm) { p in
                        LineMark(x: .value("rpm", p.rpm), y: .value(title, value(p)), series: .value("Pull", "Pull \(run.id)"))
                            .foregroundStyle(SeriesPalette.color(index))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.catmullRom)
                    }
                }
                if let rpm = hoverRPM {
                    RuleMark(x: .value("rpm", rpm))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXAxisLabel("rpm")
            .chartXScale(domain: rpmDomain)
            .chartYAxis { AxisMarks(position: .leading) }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                if let frame = proxy.plotFrame {
                                    hoverRPM = proxy.value(atX: location.x - geo[frame].origin.x, as: Double.self)
                                }
                            case .ended:
                                hoverRPM = nil
                            }
                        }
                }
            }
            .frame(height: 220)
        }
    }

    private var rpmDomain: ClosedRange<Double> {
        let all = runs.flatMap(\.points).map(\.rpm)
        guard let lo = all.min(), let hi = all.max(), hi > lo else { return 0...8000 }
        return (floor(lo / 500) * 500)...(ceil(hi / 500) * 500)
    }

    private func readout(at rpm: Double) -> String {
        let parts = runs.compactMap { run -> String? in
            guard let p = run.points.min(by: { abs($0.rpm - rpm) < abs($1.rpm - rpm) }), abs(p.rpm - rpm) <= 150 else { return nil }
            return "Pull \(run.id): \(String(format: "%.0f", value(p)))"
        }
        return "\(Int(rpm)) rpm · " + parts.joined(separator: " · ")
    }
}

/// How to record a pull that gives a trustworthy dyno curve.
struct DynoPullGuide: View {
    @Environment(AppModel.self) private var model
    @State var expanded: Bool

    private let steps: [(String, String)] = [
        ("Prepare the car", "Engine fully warm, good fuel, correct tyre pressures. Note how much fuel is in the tank and who is in the car: weight matters."),
        ("Pick the place", "A flat, straight, closed road or track without wind. Always use the same stretch so pulls can be compared."),
        ("Log the right values", "Press Record a Pull below: SubieScope ticks Engine Speed, Throttle, Speed, boost, knock and fueling for you. You can also tick at least Engine Speed and Throttle in the Logger and press Record."),
        ("Do the pull", "In 3rd gear (4th is even smoother, but faster) roll along at about 2,500 rpm. Press the throttle smoothly to the floor and hold it until just before the rev limiter. Don't change gear during the pull."),
        ("Lift off and stop", "Lift off, slow down calmly and stop the recording."),
        ("Repeat the other way", "Do a second pull in the opposite direction on the same road. Averaging both cancels out slope and wind."),
        ("Check the settings", "Enter the weight with driver and fuel, your tyre size and check the detected gear. The numbers are estimates: use them to compare changes, not to brag."),
    ]

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(i + 1)")
                            .font(.caption.weight(.bold))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(.quaternary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.0).font(.callout.weight(.semibold))
                            Text(step.1).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Label("Only on a closed road, track or dyno. Keep your eyes on the road; SubieScope records everything.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                HStack {
                    Button {
                        if let pull = RecipeCatalog.recipe(id: "pull") {
                            model.section = .recipes
                            model.startRecipe(pull)
                        }
                    } label: {
                        Label("Record a Pull", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.connection.isConnected)
                    if !model.connection.isConnected {
                        Text("Connect to the car first.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.top, 8)
        } label: {
            Text("How to do a dyno pull").font(.headline)
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}
