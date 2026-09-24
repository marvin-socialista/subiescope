import Foundation
import Testing
@testable import SSMKit

@Suite("Diagnostic recipes against simulated faults")
struct RecipeTests {
    func run(_ id: String, _ fault: DemoFault) -> (verdict: Severity, findings: [Finding]) {
        let recipe = RecipeCatalog.recipe(id: id)!
        let findings = recipe.analyze(RecipeSimulator.simulate(recipe, fault: fault))
        return (Recipe.verdict(findings), findings)
    }

    func describe(_ findings: [Finding]) -> String {
        findings.map { "[\($0.severity)] \($0.title) \($0.measured ?? "")" }.joined(separator: "\n")
    }

    @Test(arguments: RecipeCatalog.all.map(\.id).filter { $0 != "cold-sensors" && $0 != "warm-up" })
    func healthyCarPasses(_ id: String) {
        let r = run(id, .none)
        #expect(r.verdict <= .pass, "\(id):\n\(describe(r.findings))")
    }

    @Test(arguments: [
        ("front-af", DemoFault.deadFrontSensor, Severity.fail),
        ("front-af", .lazyFrontSensor, .warning),
        ("rear-o2", .deadRearO2, .fail),
        ("rear-o2", .failedCatalyst, .fail),
        ("catalyst", .failedCatalyst, .fail),
        ("maf", .dirtyMAF, .warning),
        ("maf", .vacuumLeak, .fail),
        ("fuel-trims", .vacuumLeak, .warning),
        ("fuel-trims", .dirtyMAF, .warning),
        ("idle", .misfireCylinder3, .fail),
        ("misfire", .misfireCylinder3, .fail),
        ("charging", .weakAlternator, .fail),
        ("pedal", .wornPedal, .fail),
        ("cold-sensors", .badCoolantSensor, .fail),
        ("warm-up", .stuckThermostat, .warning),
        ("cooling", .deadFan, .fail),
        ("pull", .knock, .fail),
        ("pull", .leanAtWOT, .fail),
        ("pull", .boostLeak, .fail),
        ("avcs", .stuckAVCS, .fail),
    ])
    func faultIsFound(_ id: String, _ fault: DemoFault, _ expected: Severity) {
        let r = run(id, fault)
        #expect(r.verdict >= expected, "\(id) with \(fault):\n\(describe(r.findings))")
    }

    @Test func specificDiagnoses() {
        #expect(run("maf", .vacuumLeak).findings.contains { $0.title.contains("better with more airflow") })
        #expect(run("maf", .dirtyMAF).findings.contains { $0.title.contains("Lean everywhere") })
        #expect(run("idle", .misfireCylinder3).findings.contains { $0.title.contains("#3") })
        #expect(run("avcs", .stuckAVCS).findings.contains { $0.title.contains("right") })
        #expect(run("pull", .boostLeak).findings.contains { $0.detail.contains("boost leak") })
    }

    /// Regression: a test run on a cold engine used to report "no data" because
    /// every row was filtered out as cold. It must analyse the data and warn instead.
    @Test func coldEngineStillGetsAnalysed() {
        let recipe = RecipeCatalog.recipe(id: "front-af")!
        var sim = RecipeSimulator.simulate(recipe, fault: .lazyFrontSensor)
        sim.steps = sim.steps.map { DataSet(rows: $0.rows.map { var r = $0; r.v["coolant"] = 50; return r }) }
        let findings = recipe.analyze(Analysis(steps: sim.steps, stepCompleted: sim.stepCompleted, available: sim.available, context: sim.context))
        #expect(!findings.contains { $0.title == "No A/F sensor data" }, "\(describe(findings))")
        #expect(findings.contains { $0.title == "Engine was not fully warm" })
        #expect(findings.contains { $0.title.contains("slowly") }, "\(describe(findings))")
    }

    /// Regression: a warm-up step must not make an already warm demo engine cold.
    @Test func warmUpKeepsWarmEngineWarm() {
        let world = DemoWorld()
        let before = world.sample(at: 0)["coolant"] ?? 0
        world.setScenario(.warmUp)
        let after = world.sample(at: 0.1)["coolant"] ?? 0
        #expect(before > 80 && after > 80)
    }

    @Test func coldSensorsAgreeWhenHealthy() {
        #expect(run("cold-sensors", .none).verdict == .pass)
    }

    @Test func analysisWorksOnARecordedLog() throws {
        // A recipe's analysis runs on a plain log too (no steps): fake one from the simulator.
        let recipe = RecipeCatalog.recipe(id: "pull")!
        let sim = RecipeSimulator.simulate(recipe, fault: .knock)
        let columns = ["Engine Speed (rpm)", "Throttle Opening Angle (%)", "Coolant Temperature (F)", "Manifold Relative Pressure (psi)",
                       "A/F Sensor #1 (AFR)", "Feedback Knock Correction (4-byte)* (degrees)", "IAM (multiplier)"]
        let keys = ["rpm", "throttle", "coolant", "mrp", "lambda", "fbkc", "iam"]
        var csv = "Time (msec)," + columns.joined(separator: ",") + "\n"
        for row in sim.all.rows {
            var fields = [String(Int(row.t * 1000))]
            for key in keys {
                var v = row.v[key] ?? .nan
                if key == "coolant" { v = v * 9 / 5 + 32 }
                if key == "mrp" { v = v / 6.894757 }
                if key == "lambda" { v = v * 14.7 }
                fields.append(String(format: "%.3f", v))
            }
            csv += fields.joined(separator: ",") + "\n"
        }
        let log = RecordedLog.parse(csv)
        let (data, available) = RecipeBinding.dataSet(for: recipe, log: log)
        #expect(available.isSuperset(of: ["rpm", "throttle", "coolant", "mrp", "lambda", "fbkc", "iam"]))
        let findings = recipe.analyze(Analysis(log: data, available: available, context: RecipeContext()))
        #expect(Recipe.verdict(findings) == .fail, "\(describe(findings))")
        #expect(findings.contains { $0.title == "IAM is below 1.0" })
    }

    @Test func dutchRomRaiderLogParses() {
        let log = RecordedLog.parse("Time (msec);Engine Speed (rpm);A/F Sensor #1 (AFR)\n0;850;14,70\n100;900;14,5\n")
        #expect(log.rowCount == 2)
        #expect(log.values[1][0] == 14.7)
        #expect(log.time[1] == 0.1)
    }
}
