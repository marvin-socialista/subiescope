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
        ("knock", .knock, .fail),
        ("knock", .mildKnock, .warning),
        ("pull", .leanAtWOT, .fail),
        ("pull", .boostLeak, .fail),
        ("avcs", .stuckAVCS, .fail),
    ])
    func faultIsFound(_ id: String, _ fault: DemoFault, _ expected: Severity) {
        let r = run(id, fault)
        #expect(r.verdict >= expected, "\(id) with \(fault):\n\(describe(r.findings))")
    }

    @Test func knockIsQuantified() {
        let healthy = run("knock", .none).findings
        #expect(healthy.contains { $0.title == "Knock level: Light" || $0.title == "Knock level: None" }, "\(describe(healthy))")
        let mild = run("knock", .mildKnock).findings
        #expect(mild.contains { $0.title == "Knock level: Moderate" }, "\(describe(mild))")
        let heavy = run("knock", .knock).findings
        #expect(heavy.contains { $0.title == "Knock level: Heavy" }, "\(describe(heavy))")
        #expect(heavy.contains { $0.title.hasPrefix("Most knock at") && $0.title.contains("part throttle") }, "\(describe(heavy))")
        #expect(heavy.contains { $0.title == "What to do" })
        print("--- heavy knock report ---\n" + describe(heavy))
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
        let (data, available, _) = RecipeBinding.dataSet(for: recipe, log: log)
        #expect(available.isSuperset(of: ["rpm", "throttle", "coolant", "mrp", "lambda", "fbkc", "iam"]))
        let findings = recipe.analyze(Analysis(log: data, available: available, context: RecipeContext()))
        #expect(Recipe.verdict(findings) == .fail, "\(describe(findings))")
        #expect(findings.contains { $0.title == "IAM is below 1.0" })
    }

    // MARK: With a wideband gauge

    /// The same run with a wideband gauge in the demo car's exhaust, in the role the recipe gives it.
    func runWithGauge(_ id: String, _ fault: DemoFault) -> (verdict: Severity, findings: [Finding]) {
        let recipe = RecipeCatalog.recipe(id: id)!
        let findings = recipe.findings(for: RecipeSimulator.simulate(recipe, fault: fault, useWideband: true))
        return (Recipe.verdict(findings), findings)
    }

    @Test(arguments: RecipeCatalog.all.filter { $0.probe("lambda") != nil }.map(\.id))
    func healthyCarPassesWithTheGauge(_ id: String) {
        let r = runWithGauge(id, .none)
        #expect(r.verdict <= .pass, "\(id):\n\(describe(r.findings))")
    }

    @Test(arguments: [
        ("pull", DemoFault.leanAtWOT, Severity.fail),
        ("pull", .knock, .fail),
        ("pull", .boostLeak, .fail),
        ("knock", .knock, .fail),
        ("fuel-trims", .vacuumLeak, .warning),
        ("front-af", .deadFrontSensor, .fail),
        ("front-af", .lazyFrontSensor, .warning),
    ])
    func faultIsFoundWithTheGauge(_ id: String, _ fault: DemoFault, _ expected: Severity) {
        let r = runWithGauge(id, fault)
        #expect(r.verdict >= expected, "\(id) with \(fault):\n\(describe(r.findings))")
    }

    @Test func aDeadFrontSensorNoLongerSpoilsThePull() {
        // The car's own sensor reads 1.00 whatever the engine burns, which looks like a lean pull.
        #expect(run("pull", .deadFrontSensor).findings.contains { $0.title == "Lean at full throttle" })
        let r = runWithGauge("pull", .deadFrontSensor)
        #expect(r.verdict <= .pass, "\(describe(r.findings))")
        #expect(r.findings.contains { $0.title == "Full-throttle mixture is safe" })
        // The result says which sensor it trusted.
        #expect(r.findings.contains { $0.title == "Mixture read from the wideband gauge" && $0.severity == .info })
        #expect(!run("pull", .none).findings.contains { $0.title.contains("wideband") })
    }

    @Test func theGaugeIsASecondOpinionOnTheCarsOwnSensor() {
        // The Front A/F sensor test keeps testing the car's sensor, with the gauge next to it.
        let healthy = runWithGauge("front-af", .none).findings
        #expect(healthy.contains { $0.title == "Agrees with the wideband gauge" }, "\(describe(healthy))")
        #expect(!healthy.contains { $0.title == "Mixture read from the wideband gauge" })
        let dead = runWithGauge("front-af", .deadFrontSensor).findings
        #expect(dead.contains { $0.title == "A/F sensor reading is flat" }, "\(describe(dead))")
        #expect(dead.contains { $0.title == "The wideband gauge saw the fuel cut, the car's sensor did not" }, "\(describe(dead))")
        // Stuck at 1.00 it matches the gauge at idle, which is no reason to call the two in agreement.
        #expect(!dead.contains { $0.title == "Agrees with the wideband gauge" })

        // A gauge that reads off does not fail the car's sensor: either of the two can be wrong.
        let recipe = RecipeCatalog.recipe(id: "front-af")!
        let sim = RecipeSimulator.simulate(recipe, fault: .none, useWideband: true)
        let shifted = sim.steps.map { DataSet(rows: $0.rows.map { var r = $0; r.v["wideband"] = (r.v["wideband"] ?? 1) + 0.08; return r }) }
        let findings = recipe.findings(for: Analysis(steps: shifted, stepCompleted: sim.stepCompleted, available: sim.available, context: sim.context))
        #expect(findings.contains { $0.title == "Reads richer than the wideband gauge" && $0.severity == .warning }, "\(describe(findings))")
        #expect(Recipe.verdict(findings) == .warning)
    }

    @Test func aTieBetweenRpmBandsNamesTheLowerOne() {
        // One knock event in each rpm band, the highest first. The answer has to be the same on every
        // run, whatever order a dictionary hands the bands out in; several sets, so luck does not pass it.
        for bands in [[6, 5, 4, 3, 2], [7, 6, 5, 4, 3], [6, 4, 2], [7, 5, 3], [5, 4], [6, 5, 4, 3]] {
            var rows: [DataSet.Row] = []
            var t = 0.0
            for band in bands {
                for i in 0..<30 {
                    let knock = (10..<13).contains(i)
                    rows.append(DataSet.Row(t: t, v: ["rpm": Double(band) * 1000 + 500, "throttle": 100, "mrp": 80,
                                                     "fbkc": knock ? -1.4 : 0, "iam": 1, "flkc": 0]))
                    t += 0.1
                }
            }
            let findings = Checks.knockReport(DataSet(rows: rows))
            let lowest = bands.min()! * 1000
            #expect(findings.contains { $0.title.hasPrefix("Most knock at \(lowest)") && $0.measured == "1 of \(bands.count)" },
                    "\(bands):\n\(describe(findings))")
        }
    }

    @Test func aTestsLogKeepsItsColumnsInTheOrderOfItsProbes() throws {
        let car = try LoggerDefinitions.bundled().parameterSet(for: nil).parameters
        for recipe in RecipeCatalog.all {
            let binding = RecipeBinding(recipe: recipe, parameters: car)
            var seen = Set<String>()
            let expected = recipe.probes(useWideband: false).compactMap { binding.bound[$0.key] }
                .filter { seen.insert($0.parameter.id + "|" + $0.conversion.units).inserted }
                .map(\.parameter.id)
            #expect(expected.count > 1 && binding.pollItems.map(\.parameter.id) == expected, "\(recipe.id)")
        }
    }

    @Test func theGaugeTakesTheSensorsPlaceInATest() throws {
        let car = try LoggerDefinitions.bundled().parameterSet(for: nil).parameters
        let withGauge = car + [AEMWideband.definition]
        let pull = RecipeCatalog.recipe(id: "pull")!

        let plain = RecipeBinding(recipe: pull, parameters: withGauge)
        #expect(plain.bound["lambda"]?.parameter.name == "A/F Sensor #1")
        #expect(!plain.mixtureFromWideband && plain.widebandConversion == nil)

        let gauge = RecipeBinding(recipe: pull, parameters: withGauge, useWideband: true)
        #expect(gauge.isRunnable && gauge.mixtureFromWideband)
        #expect(gauge.bound["lambda"]?.probe.label == "Wideband gauge")
        #expect(gauge.widebandConversion?.units == "Lambda")
        #expect(gauge.pollItems.contains { $0.parameter.id == AEMWideband.parameterID })
        #expect(!gauge.pollItems.contains { $0.parameter.name == "A/F Sensor #1" })
        #expect(gauge.row(t: 0, values: [AEMWideband.parameterID: 0.8])["lambda"] == 0.8)

        // The gauge turned off: the car's sensor, as before.
        #expect(RecipeBinding(recipe: pull, parameters: car, useWideband: true).bound["lambda"]?.parameter.name == "A/F Sensor #1")

        // The test of the car's own sensor reads both.
        let frontAF = RecipeBinding(recipe: RecipeCatalog.recipe(id: "front-af")!, parameters: withGauge, useWideband: true)
        #expect(frontAF.bound["lambda"]?.parameter.name == "A/F Sensor #1")
        #expect(frontAF.bound["wideband"]?.parameter.id == AEMWideband.parameterID)
        #expect(!frontAF.mixtureFromWideband)

        // A test that never looks at the mixture is left alone.
        let charging = RecipeBinding(recipe: RecipeCatalog.recipe(id: "charging")!, parameters: withGauge, useWideband: true)
        #expect(charging.widebandConversion == nil)
    }

    @Test func aCarThatDoesNotReportItsAFSensorCanStillDoAPull() {
        // OBD-II: not every car answers the A/F sensor value. The gauge fills that gap.
        let car = OBDParameters.parameters(supported: [0x05, 0x0B, 0x0C, 0x11]) + [AEMWideband.definition]
        let pull = RecipeCatalog.recipe(id: "pull")!
        #expect(RecipeBinding(recipe: pull, parameters: car).missingRequired.map(\.key) == ["lambda"])
        #expect(RecipeBinding(recipe: pull, parameters: car, useWideband: true).isRunnable)
    }

    @Test func aLogWithTheGaugeCanBeAnalysedEitherWay() {
        // A healthy pull, logged with a dead front sensor (a flat 14.7) and the gauge next to it.
        let recipe = RecipeCatalog.recipe(id: "pull")!
        let sim = RecipeSimulator.simulate(recipe, fault: .none, useWideband: true)
        var csv = "Time (msec),Engine Speed (rpm),Throttle Opening Angle (%),Coolant Temperature (C),Manifold Relative Pressure (kPa),A/F Sensor #1 (AFR),AEM Wideband A/F (AFR)\n"
        for row in sim.all.rows {
            let fields = [String(Int(row.t * 1000))] + ["rpm", "throttle", "coolant", "mrp"].map { String(format: "%.3f", row.v[$0] ?? .nan) }
                + ["14.70", String(format: "%.2f", (row.v["lambda"] ?? .nan) * 14.7)]
            csv += fields.joined(separator: ",") + "\n"
        }
        let log = RecordedLog.parse(csv)

        let (car, _, carFromGauge) = RecipeBinding.dataSet(for: recipe, log: log)
        #expect(!carFromGauge)
        #expect(Checks.wotFueling(Checks.wotRows(car)).contains { $0.title == "Lean at full throttle" })

        let (data, available, fromGauge) = RecipeBinding.dataSet(for: recipe, log: log, useWideband: true)
        #expect(fromGauge && available.contains("lambda"))
        var analysis = Analysis(log: data, available: available, context: RecipeContext())
        analysis.mixtureFromWideband = fromGauge
        let findings = recipe.findings(for: analysis)
        #expect(findings.contains { $0.title == "Full-throttle mixture is safe" }, "\(describe(findings))")
        #expect(findings.contains { $0.title == "Mixture read from the wideband gauge" })

        // An older log without the gauge is read as usual.
        let older = RecordedLog.parse(csv.split(separator: "\n").map { $0.split(separator: ",").dropLast().joined(separator: ",") }.joined(separator: "\n"))
        let (_, olderAvailable, olderFromGauge) = RecipeBinding.dataSet(for: recipe, log: older, useWideband: true)
        #expect(!olderFromGauge && olderAvailable.contains("lambda"))
    }

    @Test func aSilentGaugeIsMentionedInTheResult() {
        func withoutMixture(_ id: String) -> [Finding] {
            let recipe = RecipeCatalog.recipe(id: id)!
            let sim = RecipeSimulator.simulate(recipe, fault: .none, useWideband: true)
            let steps = sim.steps.map { DataSet(rows: $0.rows.map { var r = $0; r.v["lambda"] = nil; return r }) }
            var analysis = Analysis(steps: steps, stepCompleted: sim.stepCompleted, available: sim.available, context: sim.context)
            analysis.mixtureFromWideband = true
            return recipe.findings(for: analysis)
        }
        // The pull needs the mixture; the knock check only uses it when it is there.
        #expect(withoutMixture("pull").first.map { $0.title == "No reading from the wideband gauge" && $0.severity == .warning } == true)
        #expect(withoutMixture("knock").first.map { $0.title == "No reading from the wideband gauge" && $0.severity == .info } == true)
    }

    @Test func dutchRomRaiderLogParses() {
        let log = RecordedLog.parse("Time (msec);Engine Speed (rpm);A/F Sensor #1 (AFR)\n0;850;14,70\n100;900;14,5\n")
        #expect(log.rowCount == 2)
        #expect(log.values[1][0] == 14.7)
        #expect(log.time[1] == 0.1)
    }
}
