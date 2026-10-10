#if os(Windows) || DEBUG
import Foundation
import SSMKit

/// Troubleshooting: the list of guided tests, a test while it runs, and what it found.
/// (The code calls a test a "recipe". The Mac's side of this is Views/RecipesView.swift.)
extension Bridge {
    /// The tests to choose from and what the page needs to describe each of them.
    struct RecipesState: Encodable {
        struct Step: Encodable {
            let title: String
            let instruction: String
        }

        /// The switch that has a test read a separate wideband gauge. The same switch for every test.
        struct Wideband: Encodable {
            /// The words next to the switch. They differ with what the gauge is to this test.
            let label: String
            let explanation: String
            /// Something is wrong with the gauge while the switch is on. Shown in orange.
            let problem: String?
        }

        /// Whether this car reports what the test needs, in a sentence under the description.
        struct Availability: Encodable {
            /// "offline" (not connected), "cannot" (a needed value is missing), "partly" (it runs
            /// without some values) or "complete"
            let kind: String
            let text: String
        }

        struct Test: Encodable {
            let id: String
            let title: String
            /// The Mac's name for the test's icon (an SF Symbol). The page has its own drawing for each.
            let symbol: String
            /// Under the title in the list: "Sensors · 5 min"
            let caption: String
            /// Under the title of the description: "In the garage · about 5 minutes · 4 steps"
            let facts: String
            let summary: String
            /// "Helps with": the complaints this test is for.
            let symptoms: [String]
            /// "Before you start"
            let conditions: [String]
            /// A warning in orange, for tests that need care on the road.
            let safety: String?
            /// "What you'll do"
            let steps: [Step]
            /// "What SubieScope looks at"
            let lookFor: [String]
            /// Nil when no wideband gauge is turned on, or when the test never looks at the mixture.
            let wideband: Wideband?
            let availability: Availability
            /// The Start button works: connected, the car reports what is needed, and no test is running.
            let canStart: Bool
        }

        struct Group: Encodable {
            /// "In the garage" or "On the road"
            let label: String
            let tests: [Test]
        }

        struct Fault: Encodable {
            let id: String
            let label: String
        }

        let groups: [Group]
        let connected: Bool
        /// The test that is running or has a result waiting (`recipes.run`, `recipes.results`), by its id.
        let run: String?
        let running: Bool
        /// The test a recorded log was analysed with (`recipes.results`), by its id.
        let analysis: String?
        /// The switch of `Test.wideband`.
        let useWideband: Bool
        /// The demo car only: the fault it has, and the faults to choose from. Nil with a real car.
        let demoFault: String?
        let demoFaults: [Fault]
    }

    /// The test that is running: what stays the same for a whole step.
    struct RecipeRunState: Encodable {
        let test: String
        let title: String
        let symbol: String
        /// "Recording subiescope_maf_2026-10-10_14-03-22.csv"
        let recording: String
        let stepCount: Int
        /// The step that is being done, counted from 0.
        let step: Int
        /// "Step 2 of 4"
        let stepLabel: String
        let stepTitle: String
        let instruction: String
        /// This step ends when the person presses Continue. The others end by themselves and can be skipped.
        let manual: Bool
    }

    /// The running step's live side: it changes with every sample from the car.
    struct RecipeLive: Encodable {
        struct Tip: Encodable {
            let message: String
            /// A safety tip ("Lift off now"), shown large and in red.
            let urgent: Bool
        }

        /// How far the step is.
        struct Goal: Encodable {
            /// "manual" (a sentence), "bar" (words above a bar that fills up) or "waiting" (a spinner and words)
            let kind: String
            let text: String
            /// From 0 to 1, for "bar".
            let progress: Double?
            /// A small line under it.
            let note: String?
            /// The note is a warning (the clock is paused), in orange.
            let noteIsWarning: Bool
        }

        /// One live value to keep an eye on during the step.
        struct Tile: Encodable {
            let key: String
            let label: String
            /// As shown: "812", "0.98", "ON", or a dash when there is no reading.
            let value: String
            let units: String
            /// "in range" or "expected 600–1000". Nil for a value without a range to be in.
            let expected: String?
            /// "in" (in the range), "out" (outside it) or "unknown" (no reading yet)
            let state: String
        }

        /// The step these values belong to, so the page never shows them with another step's texts.
        let step: Int
        let tips: [Tip]
        let goal: Goal
        let tiles: [Tile]
    }

    /// What a test found: after a run, or in a recorded log.
    struct RecipeResult: Encodable {
        struct Finding: Encodable {
            /// "fail", "warning", "pass" or "info"
            let severity: String
            /// The severity in a word, for a screen reader: "Problem", "Attention", "OK", "Info"
            let label: String
            let title: String
            let detail: String
            /// The number behind the finding: "λ 1.046 (AFR 15.4)"
            let measured: String?
        }

        /// A log that the test cannot be run on, said instead of findings.
        struct Unusable: Encodable {
            let title: String
            let text: String
        }

        let test: String
        /// The worst of the findings: "fail", "warning", "pass" or "info"
        let verdict: String
        let verdictLabel: String
        /// Above the headline: the test's name, and "Stopped" or the log's name where that applies.
        let caption: String
        let headline: String
        /// The most important first.
        let findings: [Finding]
        /// The run was recorded: its log can be played back and shown in its folder.
        let hasLog: Bool
        let unusable: Unusable?
    }

    struct RecipeResults: Encodable {
        /// The finished run. Nil while a test runs and when there is none.
        let run: RecipeResult?
        /// The recorded log that was analysed last.
        let analysis: RecipeResult?
        /// "Show in File Explorer"
        let revealLabel: String
    }

    func registerRecipes() {
        // Nothing here reads the running test's live values, so this is only worked out when a test
        // starts or ends, the connection changes or a choice is made.
        slice("recipes") { [model] in
            let connected = model.connection.isConnected
            let run = model.recipeRun
            let running = run?.isRunning ?? false
            // The gauge's status is only read while it has a problem: its text for a working gauge
            // holds the live reading.
            var gaugeProblem: String?
            if model.testsUseWideband && model.widebandHasProblem {
                // The model's own sentence says "your Mac".
                gaugeProblem = model.widebandStatusText.replacingOccurrences(of: "your Mac", with: "your \(Bridge.computer)")
            }
            var groups: [RecipesState.Group] = []
            for setting in RecipeSetting.allCases {
                var tests: [RecipesState.Test] = []
                for recipe in RecipeCatalog.all where recipe.setting == setting {
                    let binding = model.binding(for: recipe)
                    var wideband: RecipesState.Wideband?
                    if model.widebandOn, recipe.probe("lambda") != nil {
                        wideband = Bridge.widebandChoice(for: recipe, problem: gaugeProblem)
                    }
                    var steps: [RecipesState.Step] = []
                    for step in recipe.steps {
                        steps.append(RecipesState.Step(title: step.title, instruction: step.instruction))
                    }
                    tests.append(RecipesState.Test(
                        id: recipe.id, title: recipe.title, symbol: recipe.symbol,
                        caption: "\(recipe.category) · \(recipe.minutes) min",
                        facts: "\(recipe.setting.label) · about \(recipe.minutes) minutes · \(recipe.steps.count) steps",
                        summary: recipe.summary, symptoms: recipe.symptoms, conditions: recipe.conditions, safety: recipe.safety,
                        steps: steps, lookFor: recipe.lookFor, wideband: wideband,
                        availability: Bridge.availability(binding, connected: connected),
                        canStart: connected && binding.isRunnable && !running))
                }
                groups.append(RecipesState.Group(label: setting.label, tests: tests))
            }
            var faults: [RecipesState.Fault] = []
            for fault in DemoFault.allCases {
                faults.append(RecipesState.Fault(id: fault.rawValue, label: fault.label))
            }
            return RecipesState(
                groups: groups, connected: connected, run: run?.recipe.id, running: running,
                analysis: model.logAnalysis?.recipe.id, useWideband: model.testsUseWideband,
                demoFault: model.isDemo ? model.demoFault.rawValue : nil, demoFaults: faults)
        }

        // The step that is being done. It reads the step's number, which the run sets again with every
        // sample, but its texts only change from one step to the next.
        slice("recipes.run") { [model] () -> RecipeRunState? in
            guard let run = model.recipeRun, let step = run.step else { return nil }
            var manual = false
            if case .manual = step.goal { manual = true }
            return RecipeRunState(
                test: run.recipe.id, title: run.recipe.title, symbol: run.recipe.symbol,
                recording: "Recording \(run.logURL?.lastPathComponent ?? "")",
                stepCount: run.recipe.steps.count, step: run.stepIndex,
                stepLabel: "Step \(run.stepIndex + 1) of \(run.recipe.steps.count)",
                stepTitle: step.title, instruction: step.instruction, manual: manual)
        }

        slice("recipes.live", atMost: 20) { [model] () -> RecipeLive? in
            guard let run = model.recipeRun, let step = run.step else { return nil }
            var tips: [RecipeLive.Tip] = []
            for tip in run.coaching {
                tips.append(RecipeLive.Tip(message: tip.message, urgent: tip.urgent))
            }
            var tiles: [RecipeLive.Tile] = []
            for watch in step.watch {
                guard let probe = run.binding.bound[watch.key]?.probe else { continue }
                tiles.append(Bridge.watchTile(watch, probe: probe, value: run.latest[watch.key]))
            }
            return RecipeLive(step: run.stepIndex, tips: tips, goal: Bridge.goal(of: step, in: run), tiles: tiles)
        }

        slice("recipes.results") { [model] in
            var finished: RecipeResult?
            if let run = model.recipeRun, !run.isRunning {
                finished = Bridge.result(of: run.recipe, findings: run.findings ?? [], subtitle: run.aborted ? "Stopped" : nil,
                                         hasLog: run.logURL != nil, unusable: nil)
            }
            var analysed: RecipeResult?
            if let analysis = model.logAnalysis {
                var unusable: RecipeResult.Unusable?
                if !analysis.missing.isEmpty {
                    let labels = analysis.missing.map { $0.label }.joined(separator: ", ")
                    unusable = RecipeResult.Unusable(
                        title: "This log can't be analysed with “\(analysis.recipe.title)”",
                        text: "\(analysis.logName) doesn't contain: \(labels).")
                }
                analysed = Bridge.result(of: analysis.recipe, findings: analysis.findings, subtitle: analysis.logName,
                                         hasLog: false, unusable: unusable)
            }
            return RecipeResults(run: finished, analysis: analysed, revealLabel: "Show in \(Bridge.fileBrowser)")
        }

        action("recipes.start") { [model] arguments in
            guard let recipe = arguments.string("id").flatMap({ RecipeCatalog.recipe(id: $0) }) else { return }
            guard !(model.recipeRun?.isRunning ?? false) else { return }
            model.startRecipe(recipe)
        }
        // Continue on a step that waits for the person.
        action("recipes.continue") { [model] _ in model.advanceRecipe() }
        // Moves on without finishing the step.
        action("recipes.skip") { [model] _ in model.advanceRecipe(completed: false) }
        // Stops the running test. With `analyze` what was recorded so far still gets its result.
        action("recipes.stop") { [model] arguments in
            model.stopRecipe(analyze: arguments.bool("analyze"))
        }
        // Done on a result: of the analysed log with `analysis`, otherwise of the run.
        action("recipes.done") { [model] arguments in
            if arguments.bool("analysis") { model.logAnalysis = nil } else { model.dismissRecipe() }
        }
        // Run Again on a result: puts it away as Done does and starts the test.
        action("recipes.runAgain") { [model] arguments in
            guard let recipe = arguments.string("id").flatMap({ RecipeCatalog.recipe(id: $0) }) else { return }
            if arguments.bool("analysis") { model.logAnalysis = nil } else { model.dismissRecipe() }
            model.startRecipe(recipe)
        }
        // Plays the finished run's log back in Recorded Logs.
        action("recipes.replayLog") { [model] _ in
            guard let run = model.recipeRun, !run.isRunning, let url = run.logURL else { return }
            model.section = .logs
            Task { await model.openLog(url) }
        }
        // Shows the finished run's report (or its log, without one) in its folder.
        action("recipes.revealLog") { [model] _ in
            guard let run = model.recipeRun, !run.isRunning, let url = run.reportURL ?? run.logURL else { return }
            Desktop.reveal(url)
        }
        // Runs a test's analysis on a log that was recorded earlier. The person chooses the file,
        // unless the page names one with `path`.
        action("recipes.analyzeLog") { [model] arguments in
            guard let recipe = arguments.string("id").flatMap({ RecipeCatalog.recipe(id: $0) }) else { return }
            let named = arguments.string("path").map { URL(fileURLWithPath: $0) }
            guard let url = named ?? Desktop.chooseFileToOpen(filter: ["Logs", "*.csv;*.txt"]) else { return }
            Task { await model.analyzeLog(url, with: recipe) }
        }
        // Makes the demo car misbehave, to see how a test reacts.
        action("recipes.demoFault") { [model] arguments in
            guard let fault = arguments.string("fault").flatMap({ DemoFault(rawValue: $0) }) else { return }
            model.demoFault = fault
        }
        // The choice holds for a whole run, so it cannot change during one.
        action("recipes.useWideband") { [model] arguments in
            guard !(model.recipeRun?.isRunning ?? false) else { return }
            model.testsUseWideband = arguments.bool("on")
        }
    }

    // MARK: The same words as the Mac

    /// What the car's values mean for a test. (The Mac's `RecipeDetailView.availability`.)
    static func availability(_ binding: RecipeBinding, connected: Bool) -> RecipesState.Availability {
        if !connected {
            return .init(kind: "offline", text: "Connect to the car to start. SubieScope then checks that your ECU reports every value this test needs.")
        }
        if !binding.missingRequired.isEmpty {
            let labels = binding.missingRequired.map { $0.label }.joined(separator: ", ")
            return .init(kind: "cannot", text: "Your ECU does not report: \(labels). This test can't run on this car.")
        }
        if !binding.missing.isEmpty {
            let labels = binding.missing.map { $0.label }.joined(separator: ", ")
            return .init(kind: "partly", text: "Not reported by your ECU (the test runs without them): \(labels).")
        }
        return .init(kind: "complete", text: "Your ECU reports everything this test needs.")
    }

    /// The wideband switch of a test that looks at the mixture. (The Mac's `WidebandChoice`.)
    static func widebandChoice(for recipe: Recipe, problem: String?) -> RecipesState.Wideband {
        switch recipe.widebandRole {
        case .mixture:
            return .init(label: "Read the mixture from the wideband gauge",
                         explanation: "Off: the tests read the mixture from the car's own front A/F sensor. On: they read it from your AEM gauge instead, which many owners trust more at full throttle. The choice applies to every test, and to logs you analyse that have the gauge in them.",
                         problem: problem)
        case .secondOpinion:
            return .init(label: "Compare the car's sensor with the wideband gauge",
                         explanation: "This test is about the car's own sensor, so that stays the one being tested. With this on, your AEM gauge is read next to it and the result tells you whether the two agree. In the other tests the same switch makes the gauge the source of the mixture.",
                         problem: problem)
        }
    }

    /// How far a step is, in words and as a bar. (The Mac's `GoalProgressView`.)
    static func goal(of step: RecipeStep, in run: RecipeRun) -> RecipeLive.Goal {
        let progress = run.progress.finite ?? 0
        switch step.goal {
        case .manual:
            return .init(kind: "manual", text: "Press Continue when you're done.", progress: nil, note: nil, noteIsWarning: false)
        case .collect(let seconds, let whenever):
            var note: String?
            if let condition = whenever, !run.latest.isEmpty, !condition.test(DataSet.Row(t: 0, v: run.latest)) {
                note = "Paused until: \(condition.description)"
            }
            return .init(kind: "bar", text: "Recording: \(Int(progress * seconds)) of \(Int(seconds)) s",
                         progress: progress, note: note, noteIsWarning: true)
        case .hold(let seconds, let condition):
            let text = progress > 0 ? "Holding: \(Int(progress * seconds)) of \(Int(seconds)) s" : "Waiting for: \(condition.description)"
            return .init(kind: "bar", text: text, progress: progress, note: nil, noteIsWarning: false)
        case .until(let condition, let timeout):
            let elapsed = Int(run.stepElapsed.finite ?? 0)
            let seconds = elapsed % 60
            let clock = "\(elapsed / 60):\(seconds < 10 ? "0" : "")\(seconds)"
            return .init(kind: "waiting", text: "Waiting for: \(condition.description)", progress: nil,
                         note: "Gives up after \(Int(timeout / 60)) min (\(clock) so far)", noteIsWarning: false)
        }
    }

    /// A live value of a step, with whether it is where it should be. (The Mac's `WatchTile`.)
    static func watchTile(_ watch: Watch, probe: Probe, value: Double?) -> RecipeLive.Tile {
        let value = value.flatMap { $0.finite }
        var text = "–"
        if let value {
            text = probe.units == "on/off" ? (value > 0.5 ? "ON" : "OFF") : watchText(value, probe)
        }
        let units: String
        switch probe.units {
        case "C": units = "°C"
        case "Lambda": units = "λ"
        case "on/off", "misfire count": units = ""
        default: units = probe.units
        }
        var expected: String?
        var state = "unknown"
        if let range = watch.expected {
            if let value { state = range.contains(value) ? "in" : "out" }
            expected = state == "in" ? "in range" : "expected \(watchText(range.lowerBound, probe))–\(watchText(range.upperBound, probe))"
        }
        return .init(key: watch.key, label: probe.label, value: text, units: units, expected: expected, state: state)
    }

    /// A value in the number of decimals that suits its units. (The Mac's `WatchTile.format`.)
    static func watchText(_ value: Double, _ probe: Probe) -> String {
        switch probe.units {
        case "Lambda", "V", "A", "multiplier": return String(format: "%.2f", value)
        case "degrees", "%", "ms", "g/s": return String(format: "%.1f", value)
        default: return String(format: "%.0f", value)
        }
    }

    /// The findings of a test as the result page shows them. (The Mac's `RecipeResultView` and `FindingsList`.)
    static func result(of recipe: Recipe, findings: [Finding], subtitle: String?, hasLog: Bool,
                       unusable: RecipeResult.Unusable?) -> RecipeResult {
        // Most important first: problems, then passes, then background info. Equal ones keep their order.
        func rank(_ severity: Severity) -> Int {
            switch severity {
            case .fail: return 0
            case .warning: return 1
            case .pass: return 2
            case .info: return 3
            }
        }
        let ordered = findings.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element.severity), rank(b.element.severity))
            return ra != rb ? ra < rb : a.offset < b.offset
        }
        var shown: [RecipeResult.Finding] = []
        for (_, finding) in ordered {
            shown.append(RecipeResult.Finding(
                severity: Bridge.name(of: finding.severity), label: Bridge.label(of: finding.severity),
                title: finding.title, detail: finding.detail, measured: finding.measured))
        }
        let verdict = Recipe.verdict(findings)
        return RecipeResult(
            test: recipe.id, verdict: Bridge.name(of: verdict), verdictLabel: Bridge.label(of: verdict),
            caption: recipe.title + (subtitle.map { " · \($0)" } ?? ""), headline: recipe.headline(for: findings),
            findings: shown, hasLog: hasLog, unusable: unusable)
    }

    static func name(of severity: Severity) -> String {
        switch severity {
        case .pass: return "pass"
        case .warning: return "warning"
        case .fail: return "fail"
        case .info: return "info"
        }
    }

    /// A severity in a word. (The Mac's `Severity.label`, in RecipesView.swift.)
    static func label(of severity: Severity) -> String {
        switch severity {
        case .pass: return "OK"
        case .warning: return "Attention"
        case .fail: return "Problem"
        case .info: return "Info"
        }
    }
}
#endif
