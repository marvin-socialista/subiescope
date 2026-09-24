import Foundation
import Observation
import SSMKit

/// A recipe in progress, observable for the UI.
@MainActor
@Observable
final class RecipeRun {
    let recipe: Recipe
    let binding: RecipeBinding
    let startedAt = Date()
    @ObservationIgnored let runner: RecipeRunner
    @ObservationIgnored var writer: CSVLogWriter?

    private(set) var stepIndex = 0
    private(set) var progress: Double = 0
    private(set) var stepElapsed: Double = 0
    private(set) var latest: [String: Double] = [:]
    private(set) var findings: [Finding]?
    private(set) var aborted = false
    var logURL: URL?
    var reportURL: URL?

    init(recipe: Recipe, binding: RecipeBinding, context: RecipeContext) {
        self.recipe = recipe
        self.binding = binding
        runner = RecipeRunner(recipe: recipe, binding: binding, context: context)
    }

    var step: RecipeStep? { stepIndex < recipe.steps.count && findings == nil && !aborted ? recipe.steps[stepIndex] : nil }
    var isRunning: Bool { findings == nil && !aborted }

    var coaching: [(message: String, urgent: Bool)] {
        step?.coaching(for: DataSet.Row(t: 0, v: latest)) ?? []
    }

    /// Returns true when the step changed.
    @discardableResult
    func ingest(_ sample: Sample) -> Bool {
        let before = runner.stepIndex
        runner.ingest(time: sample.time, values: sample.values)
        writer?.append(time: sample.time, values: sample.values)
        sync()
        return runner.stepIndex != before
    }

    func advance(completed: Bool) {
        runner.advance(completed: completed)
        sync()
    }

    /// Stops and analyses what was recorded so far.
    func finishEarly() {
        runner.abort()
        findings = runner.analyzeNow()
        stepIndex = recipe.steps.count
    }

    func abort() {
        runner.abort()
        aborted = true
    }

    private func sync() {
        stepIndex = runner.stepIndex
        progress = runner.progress
        stepElapsed = runner.stepElapsed
        latest = runner.latest
        if case .finished(let f) = runner.state { findings = f }
    }

    /// Plain-text report saved next to the log.
    func reportText() -> String {
        guard let findings else { return "" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        var out = "SubieScope · \(recipe.title)\n\(f.string(from: startedAt))\n\n\(recipe.headline(for: findings))\n\n"
        for finding in findings {
            let mark: String
            switch finding.severity {
            case .pass: mark = "OK  "
            case .warning: mark = "WARN"
            case .fail: mark = "FAIL"
            case .info: mark = "INFO"
            }
            out += "[\(mark)] \(finding.title)"
            if let m = finding.measured { out += " (\(m))" }
            out += "\n"
            if !finding.detail.isEmpty { out += "       \(finding.detail)\n" }
        }
        out += "\nThese results are rules of thumb, not a replacement for a proper diagnosis.\n"
        return out
    }
}

/// Result of running a recipe's analysis on an existing log.
struct LogAnalysisResult: Identifiable {
    let id = UUID()
    let recipe: Recipe
    let logName: String
    let findings: [Finding]
    let missing: [Probe]
}
