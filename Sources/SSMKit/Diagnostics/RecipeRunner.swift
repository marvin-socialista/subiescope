import Foundation

/// Drives a guided recipe: feeds samples into the current step, decides when the
/// step is done, and runs the analysis at the end. Not thread safe; the app uses
/// it from the main actor.
public final class RecipeRunner {
    public enum State: Sendable {
        case running
        case finished([Finding])
        case aborted
    }

    public let recipe: Recipe
    public let binding: RecipeBinding
    public let context: RecipeContext
    public private(set) var state: State = .running
    public private(set) var stepIndex = 0
    /// 0...1 progress of the current step's goal.
    public private(set) var progress: Double = 0
    /// Seconds since the current step started.
    public private(set) var stepElapsed: Double = 0
    public private(set) var latest: [String: Double] = [:]
    public private(set) var stepData: [DataSet]
    public private(set) var stepCompleted: [Bool]
    /// Every sample of the run, for saving as a log.
    public private(set) var allRows: [DataSet.Row] = []
    public var onStepChange: ((Int) -> Void)?

    private var stepStart: Double?
    private var collected: Double = 0
    private var holdStart: Double?
    private var lastT: Double?
    private var start: Date?

    public init(recipe: Recipe, binding: RecipeBinding, context: RecipeContext = RecipeContext()) {
        self.recipe = recipe
        self.binding = binding
        self.context = context
        stepData = Array(repeating: DataSet(), count: recipe.steps.count)
        stepCompleted = Array(repeating: false, count: recipe.steps.count)
    }

    public var currentStep: RecipeStep? {
        guard case .running = state, stepIndex < recipe.steps.count else { return nil }
        return recipe.steps[stepIndex]
    }

    public var isFinished: Bool {
        if case .running = state { return false }
        return true
    }

    /// Feeds one poll result (values keyed by parameter ID).
    public func ingest(time: Date, values: [String: Double]) {
        guard case .running = state, stepIndex < recipe.steps.count else { return }
        if start == nil { start = time }
        let t = time.timeIntervalSince(start!)
        let row = binding.row(t: t, values: values)
        latest = row.v
        allRows.append(row)
        stepData[stepIndex].rows.append(row)
        if stepStart == nil { stepStart = t }
        stepElapsed = t - stepStart!
        let dt = lastT.map { Swift.max(0, Swift.min(1, t - $0)) } ?? 0
        lastT = t

        switch recipe.steps[stepIndex].goal {
        case .manual:
            progress = 0
        case .collect(let seconds, let whenever):
            if whenever?.test(row) ?? true { collected += dt }
            progress = Swift.min(1, collected / seconds)
            if collected >= seconds { finishStep(completed: true) }
        case .hold(let seconds, let condition):
            if condition.test(row) {
                if holdStart == nil { holdStart = t }
                progress = Swift.min(1, (t - holdStart!) / seconds)
                if t - holdStart! >= seconds { finishStep(completed: true) }
            } else {
                holdStart = nil
                progress = 0
            }
        case .until(let condition, let timeout):
            progress = Swift.min(1, stepElapsed / timeout)
            if condition.test(row) {
                finishStep(completed: true)
            } else if stepElapsed >= timeout {
                finishStep(completed: false)
            }
        }
    }

    /// The user pressed Continue (manual steps) or Skip.
    public func advance(completed: Bool = true) {
        guard case .running = state else { return }
        finishStep(completed: completed)
    }

    public func abort() {
        state = .aborted
    }

    /// Analysis over the data gathered so far (for "finish early").
    public func analyzeNow() -> [Finding] {
        recipe.analyze(Analysis(steps: stepData, stepCompleted: stepCompleted, available: binding.available, context: context))
    }

    private func finishStep(completed: Bool) {
        stepCompleted[stepIndex] = completed
        stepIndex += 1
        stepStart = nil
        collected = 0
        holdStart = nil
        progress = 0
        stepElapsed = 0
        if stepIndex >= recipe.steps.count {
            state = .finished(analyzeNow())
        }
        onStepChange?(stepIndex)
    }
}
