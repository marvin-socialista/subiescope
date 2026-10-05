import Foundation

/// Runs a recipe against the simulated engine in virtual time: each step's demo
/// scenario is acted out until the step's goal is met. Used by the tests to
/// check that every recipe recognises the faults it is meant to find. With
/// `useWideband` the demo car has a wideband gauge in its exhaust, in the role
/// the recipe gives it.
public enum RecipeSimulator {
    public static func simulate(_ recipe: Recipe, fault: DemoFault, useWideband: Bool = false, hz: Double = 10,
                                maxStepSeconds: Double = 240) -> Analysis {
        let world = DemoWorld(fault: fault)
        let gauge = useWideband && recipe.probe("lambda") != nil
        func sample(at t: Double) -> [String: Double] {
            var v = world.sample(at: t)
            guard gauge else { return v }
            // What the gauge would send, read back the way the app reads it.
            let reading = AEMWideband.lambda(fromLine: SimulatedWideband.text(for: world.exhaustLambda, output: .afr))
            v[recipe.widebandRole == .mixture ? "lambda" : Probes.wideband.key] = reading
            return v
        }
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
                let row = DataSet.Row(t: t, v: sample(at: t))
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
        var analysis = Analysis(steps: steps, stepCompleted: completed, available: Set(recipe.probes(useWideband: gauge).map(\.key)),
                                context: RecipeContext(displacementLiters: 2.0))
        analysis.mixtureFromWideband = gauge && recipe.widebandRole == .mixture
        return analysis
    }
}
