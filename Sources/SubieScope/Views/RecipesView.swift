import AppKit
import SSMKit
import SwiftUI
import UniformTypeIdentifiers

struct RecipesView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: String? = RecipeCatalog.all.first?.id

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(RecipeSetting.allCases, id: \.self) { setting in
                    Section(setting.label) {
                        ForEach(RecipeCatalog.all.filter { $0.setting == setting }) { recipe in
                            RecipeRow(recipe: recipe, running: model.recipeRun?.recipe.id == recipe.id && model.recipeRun?.isRunning == true)
                                .tag(recipe.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 290)
            Divider()
            Group {
                if let run = model.recipeRun, run.recipe.id == selectedID || run.isRunning {
                    if run.isRunning {
                        RecipeRunView(run: run)
                    } else {
                        RecipeResultView(recipe: run.recipe, findings: run.findings ?? [], logURL: run.logURL,
                                         reportURL: run.reportURL, subtitle: run.aborted ? "Stopped" : nil) {
                            model.dismissRecipe()
                        }
                    }
                } else if let analysis = model.logAnalysis, analysis.recipe.id == selectedID {
                    LogAnalysisView(result: analysis)
                } else if let recipe = RecipeCatalog.all.first(where: { $0.id == selectedID }) {
                    RecipeDetailView(recipe: recipe)
                } else {
                    ContentUnavailableView("Pick a test", systemImage: "stethoscope")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.recipeRun?.recipe.id) { _, id in
            if let id { selectedID = id }
        }
    }
}

struct RecipeRow: View {
    let recipe: Recipe
    let running: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: recipe.symbol)
                .font(.title3)
                .foregroundStyle(Color.scopeBlue)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.title).lineLimit(1)
                Text("\(recipe.category) · \(recipe.minutes) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if running {
                Image(systemName: "record.circle.fill").foregroundStyle(.red).symbolEffect(.pulse)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail

struct RecipeDetailView: View {
    @Environment(AppModel.self) private var model
    let recipe: Recipe

    var body: some View {
        let binding = model.binding(for: recipe)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: recipe.symbol)
                        .font(.system(size: 30))
                        .foregroundStyle(Color.scopeBlue)
                        .frame(width: 52, height: 52)
                        .background(Color.scopeBlue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recipe.title).font(.title2.weight(.semibold))
                        Text("\(recipe.setting.label) · about \(recipe.minutes) minutes · \(recipe.steps.count) steps")
                            .foregroundStyle(.secondary)
                    }
                }
                Text(recipe.summary).font(.body).fixedSize(horizontal: false, vertical: true)

                if !recipe.symptoms.isEmpty {
                    DetailSection(title: "Helps with") {
                        FlowChips(items: recipe.symptoms)
                    }
                }
                if !recipe.conditions.isEmpty {
                    DetailSection(title: "Before you start") {
                        BulletList(items: recipe.conditions, symbol: "checkmark.circle")
                    }
                }
                if let safety = recipe.safety {
                    Label(safety, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                if model.widebandOn && recipe.probe("lambda") != nil {
                    WidebandChoice(recipe: recipe)
                }
                DetailSection(title: "What you'll do") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(recipe.steps.enumerated()), id: \.offset) { i, step in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(i + 1)")
                                    .font(.caption.weight(.bold))
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(.quaternary))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.title).font(.callout.weight(.medium))
                                    Text(step.instruction).font(.callout).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                DetailSection(title: "What SubieScope looks at") {
                    BulletList(items: recipe.lookFor, symbol: "magnifyingglass")
                }
                availability(binding)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button("Analyze a Log…") { chooseLog() }
                    .help("Run this test's analysis on a log you recorded earlier")
                if model.isDemo {
                    Picker("Demo fault", selection: Bindable(model).demoFault) {
                        ForEach(DemoFault.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(maxWidth: 300)
                    .help("Make the demo car misbehave to see how the test reacts")
                }
                Spacer()
                let canStart = model.connection.isConnected && binding.isRunnable && !(model.recipeRun?.isRunning ?? false)
                Button {
                    model.startRecipe(recipe)
                } label: {
                    // The icon and the word are laid out and coloured here, not left to the button:
                    // as a `Label` the front window drew this one as a blue button with nothing on it.
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Start")
                    }
                    .foregroundStyle(canStart ? Color.white : Color.secondary)
                    .frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canStart)
            }
            .padding(14)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func availability(_ binding: RecipeBinding) -> some View {
        if !model.connection.isConnected {
            Label("Connect to the car to start. SubieScope then checks that your ECU reports every value this test needs.",
                  systemImage: "cable.connector")
                .foregroundStyle(.secondary)
        } else if !binding.missingRequired.isEmpty {
            Label("Your ECU does not report: \(binding.missingRequired.map(\.label).joined(separator: ", ")). This test can't run on this car.",
                  systemImage: "xmark.octagon")
                .foregroundStyle(.red)
        } else if !binding.missing.isEmpty {
            Label("Not reported by your ECU (the test runs without them): \(binding.missing.map(\.label).joined(separator: ", ")).",
                  systemImage: "info.circle")
                .foregroundStyle(.secondary)
                .font(.callout)
        } else {
            Label("Your ECU reports everything this test needs.", systemImage: "checkmark.seal")
                .foregroundStyle(.green)
        }
    }

    private func chooseLog() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.directoryURL = model.logsFolder
        panel.message = "Choose a log to analyse with “\(recipe.title)”"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.analyzeLog(url, with: recipe) }
        }
    }
}

/// For tests that look at the mixture, when a wideband gauge is turned on: read it from the gauge
/// instead of the car's own A/F sensor. One choice for every test and for logs that are analysed.
struct WidebandChoice: View {
    @Environment(AppModel.self) private var model
    let recipe: Recipe

    var body: some View {
        @Bindable var model = model
        DetailSection(title: "Wideband gauge") {
            Toggle(recipe.widebandRole == .mixture ? "Read the mixture from the wideband gauge" : "Compare the car's sensor with the wideband gauge",
                   isOn: $model.testsUseWideband)
                .disabled(model.recipeRun?.isRunning ?? false)
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.testsUseWideband && model.widebandHasProblem {
                Label(model.widebandStatusText, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var explanation: String {
        switch recipe.widebandRole {
        case .mixture:
            return "Off: the tests read the mixture from the car's own front A/F sensor. On: they read it from your AEM gauge instead, which many owners trust more at full throttle. The choice applies to every test, and to logs you analyse that have the gauge in them."
        case .secondOpinion:
            return "This test is about the car's own sensor, so that stays the one being tested. With this on, your AEM gauge is read next to it and the result tells you whether the two agree. In the other tests the same switch makes the gauge the source of the mixture."
        }
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
    }
}

struct BulletList: View {
    let items: [String]
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Label {
                    Text(item).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct FlowChips: View {
    let items: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(items, id: \.self) { item in
            Text(item)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: Capsule())
        }
    }
}

// MARK: - Running

struct RecipeRunView: View {
    @Environment(AppModel.self) private var model
    let run: RecipeRun
    @State private var confirmStop = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if let step = run.step {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Step \(run.stepIndex + 1) of \(run.recipe.steps.count)")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Color.scopeBlue)
                            Text(step.title).font(.largeTitle.weight(.semibold))
                            Text(step.instruction).font(.title3).fixedSize(horizontal: false, vertical: true)
                        }
                        CoachingView(tips: run.coaching)
                        GoalProgressView(step: step, run: run)
                        WatchGrid(run: run, step: step)
                    }
                    .padding(24)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack {
                Button("Stop…") { confirmStop = true }
                Spacer()
                if case .manual = run.step?.goal {
                    Button("Continue") { model.advanceRecipe() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [])
                } else {
                    Button("Skip Step") { model.advanceRecipe(completed: false) }
                        .help("Move on without finishing this step. The result may be less complete.")
                }
            }
            .padding(14)
        }
        .confirmationDialog("Stop \(run.recipe.title)?", isPresented: $confirmStop) {
            Button("Stop and Analyse What's Recorded") { model.stopRecipe(analyze: true) }
            Button("Stop Without Results", role: .destructive) { model.stopRecipe(analyze: false) }
            Button("Keep Going", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: run.recipe.symbol).font(.title2).foregroundStyle(Color.scopeBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.recipe.title).font(.headline)
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red).symbolEffect(.pulse)
                    Text("Recording \(run.logURL?.lastPathComponent ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            StepDots(count: run.recipe.steps.count, current: run.stepIndex)
        }
        .padding(14)
    }
}

struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i < current ? Color.scopeBlue : (i == current ? Color.scopeBlue.opacity(0.6) : Color.secondary.opacity(0.25)))
                    .frame(width: i == current ? 22 : 8, height: 8)
            }
        }
        .animation(.easeOut, value: current)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

struct CoachingView: View {
    let tips: [(message: String, urgent: Bool)]

    var body: some View {
        if !tips.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in
                    Label {
                        Text(tip.message).font(tip.urgent ? .title3.weight(.semibold) : .body)
                    } icon: {
                        Image(systemName: tip.urgent ? "exclamationmark.octagon.fill" : "lightbulb")
                    }
                    .foregroundStyle(tip.urgent ? Color.red : Color.primary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((tip.urgent ? Color.red : Color.yellow).opacity(tip.urgent ? 0.15 : 0.1), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

struct GoalProgressView: View {
    let step: RecipeStep
    let run: RecipeRun

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch step.goal {
            case .manual:
                Text("Press Continue when you're done.").foregroundStyle(.secondary)
            case .collect(let seconds, let whenever):
                ProgressView(value: run.progress) {
                    Text("Recording: \(Int(run.progress * seconds)) of \(Int(seconds)) s")
                }
                if let c = whenever, !c.test(DataSet.Row(t: 0, v: run.latest)), !run.latest.isEmpty {
                    Text("Paused until: \(c.description)").font(.caption).foregroundStyle(.orange)
                }
            case .hold(let seconds, let c):
                ProgressView(value: run.progress) {
                    Text(run.progress > 0 ? "Holding: \(Int(run.progress * seconds)) of \(Int(seconds)) s" : "Waiting for: \(c.description)")
                }
            case .until(let c, let timeout):
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for: \(c.description)")
                }
                Text("Gives up after \(Int(timeout / 60)) min (\(Int(run.stepElapsed / 60)):\(String(format: "%02d", Int(run.stepElapsed) % 60)) so far)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct WatchGrid: View {
    let run: RecipeRun
    let step: RecipeStep

    var body: some View {
        let watches = step.watch.filter { run.binding.bound[$0.key] != nil }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            ForEach(watches, id: \.key) { watch in
                WatchTile(watch: watch, probe: run.binding.bound[watch.key]!.probe, value: run.latest[watch.key])
            }
        }
    }
}

struct WatchTile: View {
    let watch: Watch
    let probe: Probe
    let value: Double?

    var body: some View {
        let inRange = value.flatMap { v in watch.expected.map { $0.contains(v) } }
        VStack(alignment: .leading, spacing: 4) {
            Text(probe.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formatted).font(.title2.weight(.semibold).monospacedDigit())
                Text(units).font(.caption).foregroundStyle(.secondary)
            }
            if let expected = watch.expected {
                Label(inRange == true ? "in range" : "expected \(Self.format(expected.lowerBound, probe))–\(Self.format(expected.upperBound, probe))",
                      systemImage: inRange == true ? "checkmark.circle.fill" : "arrow.left.and.right.circle")
                    .font(.caption)
                    .foregroundStyle(inRange == true ? Color.green : (inRange == false ? Color.orange : Color.secondary))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var units: String {
        switch probe.units {
        case "C": return "°C"
        case "Lambda": return "λ"
        case "on/off", "misfire count": return ""
        default: return probe.units
        }
    }

    private var formatted: String {
        guard let value else { return "–" }
        if probe.units == "on/off" { return value > 0.5 ? "ON" : "OFF" }
        return Self.format(value, probe)
    }

    static func format(_ v: Double, _ probe: Probe) -> String {
        switch probe.units {
        case "Lambda": return String(format: "%.2f", v)
        case "V", "A": return String(format: "%.2f", v)
        case "multiplier": return String(format: "%.2f", v)
        case "degrees", "%", "ms", "g/s": return String(format: "%.1f", v)
        default: return String(format: "%.0f", v)
        }
    }
}

// MARK: - Results

struct RecipeResultView: View {
    @Environment(AppModel.self) private var model
    let recipe: Recipe
    let findings: [Finding]
    let logURL: URL?
    let reportURL: URL?
    let subtitle: String?
    let onDone: () -> Void

    var body: some View {
        let verdict = Recipe.verdict(findings)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .center, spacing: 16) {
                        VerdictBadge(severity: verdict)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recipe.title + (subtitle.map { " · \($0)" } ?? "")).font(.callout).foregroundStyle(.secondary)
                            Text(recipe.headline(for: findings)).font(.title2.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    FindingsList(findings: findings)
                    Text("These results are rules of thumb from the logged data, not a replacement for a proper diagnosis. When in doubt, ask a Subaru specialist and bring the log.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if let logURL {
                    Button("Replay Log") {
                        model.section = .logs
                        Task { await model.openLog(logURL) }
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([reportURL ?? logURL]) }
                }
                Spacer()
                Button("Run Again") {
                    onDone()
                    model.startRecipe(recipe)
                }
                .disabled(!model.connection.isConnected)
                Button("Done") { onDone() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
    }
}

struct LogAnalysisView: View {
    @Environment(AppModel.self) private var model
    let result: LogAnalysisResult

    var body: some View {
        if !result.missing.isEmpty {
            ContentUnavailableView {
                Label("This log can't be analysed with “\(result.recipe.title)”", systemImage: "doc.questionmark")
            } description: {
                Text("\(result.logName) doesn't contain: \(result.missing.map(\.label).joined(separator: ", ")).")
            } actions: {
                Button("Back") { model.logAnalysis = nil }
            }
        } else {
            RecipeResultView(recipe: result.recipe, findings: result.findings, logURL: nil, reportURL: nil,
                             subtitle: result.logName) { model.logAnalysis = nil }
        }
    }
}

struct VerdictBadge: View {
    let severity: Severity

    var body: some View {
        Image(systemName: severity.symbol)
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
            .background(severity.color, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityLabel(severity.label)
    }
}

struct FindingsList: View {
    let findings: [Finding]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Most important first: problems, then passes, then background info.
            ForEach(findings.sorted { rank($0.severity) < rank($1.severity) }) { finding in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: finding.severity.symbol)
                        .foregroundStyle(finding.severity.color)
                        .font(.title3)
                        .frame(width: 24)
                        .accessibilityLabel(finding.severity.label)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(finding.title).font(.body.weight(.semibold))
                            Spacer()
                            if let measured = finding.measured {
                                Text(measured).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        if !finding.detail.isEmpty {
                            Text(finding.detail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func rank(_ s: Severity) -> Int {
        switch s {
        case .fail: return 0
        case .warning: return 1
        case .pass: return 2
        case .info: return 3
        }
    }
}

extension Severity {
    var symbol: String {
        switch self {
        case .pass: return "checkmark"
        case .warning: return "exclamationmark"
        case .fail: return "xmark"
        case .info: return "info"
        }
    }

    var color: Color {
        switch self {
        case .pass: return .green
        case .warning: return .orange
        case .fail: return .red
        case .info: return .gray
        }
    }

    var label: String {
        switch self {
        case .pass: return "OK"
        case .warning: return "Attention"
        case .fail: return "Problem"
        case .info: return "Info"
        }
    }
}
