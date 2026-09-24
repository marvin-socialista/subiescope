import Foundation

/// Runs a recipe against the simulated engine in virtual time: each step's demo
/// scenario is acted out until the step's goal is met. Used by the tests to
/// check that every recipe recognises the faults it is meant to find.
public enum RecipeSimulator {
    public static func simulate(_ recipe: Recipe, fault: DemoFault, hz: Double = 10, maxStepSeconds: Double = 240) -> Analysis {
        let world = DemoWorld(fault: fault)
        var t = 0.0
        var steps: [DataSet] = []
        var completed: [Bool] = []
        _ = world.sample(at: 0)
        for step in recipe.steps {
            world.setScenario(step.demo)
            var rows: [DataSet.Row] = []
            var collected = 0.0
            var holdStart: Double?
            var success: Bool?
            let start = t
            while success == nil {
                t += 1 / hz
                let row = DataSet.Row(t: t, v: world.sample(at: t))
                rows.append(row)
                let elapsed = t - start
                switch step.goal {
                case .manual:
                    if elapsed >= 5 { success = true }
                case .collect(let seconds, let whenever):
                    if whenever?.test(row) ?? true { collected += 1 / hz }
                    if collected >= seconds { success = true }
                case .hold(let seconds, let condition):
                    if condition.test(row) { holdStart = holdStart ?? t } else { holdStart = nil }
                    if let h = holdStart, t - h >= seconds { success = true }
                case .until(let condition, let timeout):
                    if condition.test(row) { success = true } else if elapsed >= Swift.min(timeout, maxStepSeconds) { success = false }
                }
                if success == nil && elapsed >= maxStepSeconds { success = false }
            }
            steps.append(DataSet(rows: rows))
            completed.append(success ?? false)
        }
        return Analysis(steps: steps, stepCompleted: completed, available: Set(recipe.probes.map(\.key)),
                        context: RecipeContext(displacementLiters: 2.0))
    }
}
