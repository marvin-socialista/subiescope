import Foundation

/// A value a recipe needs, e.g. key "lambda" = concept "A/F Sensor #1" in lambda.
public struct Probe: Sendable, Hashable {
    public var key: String
    /// Parameter name as in the RomRaider definitions (variants are resolved).
    public var concept: String
    /// Canonical units the analysis works in.
    public var units: String
    public var required: Bool
    public var label: String

    public init(_ key: String, _ concept: String, units: String, required: Bool = true, label: String? = nil) {
        self.key = key
        self.concept = concept
        self.units = units
        self.required = required
        self.label = label ?? concept
    }
}

public struct Condition: Sendable {
    public var description: String
    public var test: @Sendable (DataSet.Row) -> Bool

    public init(_ description: String, _ test: @escaping @Sendable (DataSet.Row) -> Bool) {
        self.description = description
        self.test = test
    }
}

public enum StepGoal: Sendable {
    /// The user presses Continue.
    case manual
    /// Record for this long; the clock only runs while `whenever` holds (if given).
    case collect(seconds: Double, whenever: Condition? = nil)
    /// The condition must hold without interruption for this long.
    case hold(seconds: Double, Condition)
    /// Wait for something to happen, up to `timeout` seconds.
    case until(Condition, timeout: Double)
}

/// A live value shown while a step runs, with the range it should be in.
public struct Watch: Sendable {
    public var key: String
    public var expected: ClosedRange<Double>?
    public var note: String?

    public init(_ key: String, expected: ClosedRange<Double>? = nil, note: String? = nil) {
        self.key = key
        self.expected = expected
        self.note = note
    }
}

/// What the demo ECU should act out during a step.
public enum DemoScenario: String, Sendable, CaseIterable {
    case engineOff, coldEngineOff, idle, idleWithLoads, hold2500, revAndRelease, pedalSweep, wotPull, rollOn, warmUp, coldStart, cruise
}

/// Live coaching: shown while `when` holds for the latest sample.
public struct Tip: Sendable {
    public var when: @Sendable (DataSet.Row) -> Bool
    public var message: @Sendable (DataSet.Row) -> String
    /// Safety tips are shown prominently (e.g. "lift off, running lean").
    public var urgent: Bool

    public init(urgent: Bool = false, when: @escaping @Sendable (DataSet.Row) -> Bool, _ message: @escaping @Sendable (DataSet.Row) -> String) {
        self.when = when
        self.message = message
        self.urgent = urgent
    }

    public init(urgent: Bool = false, when: @escaping @Sendable (DataSet.Row) -> Bool, _ message: String) {
        self.init(urgent: urgent, when: when) { _ in message }
    }
}

public struct RecipeStep: Sendable {
    public var title: String
    public var instruction: String
    public var goal: StepGoal
    public var watch: [Watch]
    public var tips: [Tip]
    public var demo: DemoScenario?

    public init(_ title: String, _ instruction: String, goal: StepGoal, watch: [Watch] = [], tips: [Tip] = [],
                demo: DemoScenario? = nil) {
        self.title = title
        self.instruction = instruction
        self.goal = goal
        self.watch = watch
        self.tips = tips
        self.demo = demo
    }

    /// The condition the goal is waiting for, if any.
    public var goalCondition: Condition? {
        switch goal {
        case .manual: return nil
        case .collect(_, let c): return c
        case .hold(_, let c): return c
        case .until(let c, _): return c
        }
    }

    /// Tips for the latest sample: urgent ones first, then step tips, then what the goal still needs.
    public func coaching(for row: DataSet.Row?) -> [(message: String, urgent: Bool)] {
        guard let row else { return [] }
        let matched = tips.filter { $0.when(row) }.sorted { $0.urgent && !$1.urgent }
        var out = matched.map { ($0.message(row), $0.urgent) }
        if out.isEmpty, let c = goalCondition, !c.test(row) {
            switch goal {
            case .until: break
            default: out.append(("Needed: \(c.description)", false))
            }
        }
        return out
    }
}

public enum Severity: Int, Sendable, Comparable, CaseIterable {
    case info = 0, pass = 1, warning = 2, fail = 3
    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

public struct Finding: Identifiable, Sendable {
    public let id = UUID()
    public var severity: Severity
    public var title: String
    public var detail: String
    public var measured: String?

    public init(_ severity: Severity, _ title: String, _ detail: String = "", measured: String? = nil) {
        self.severity = severity
        self.title = title
        self.detail = detail
        self.measured = measured
    }
}

public enum RecipeSetting: String, Sendable, CaseIterable {
    /// Car parked, engine off or idling / revving in neutral.
    case parked
    /// Needs a drive.
    case driving

    public var label: String { self == .parked ? "In the garage" : "On the road" }
}

/// What a separate wideband gauge is to a recipe, when the tests are set to use one.
public enum WidebandRole: Sendable {
    /// The mixture ("lambda") is read from the gauge instead of the car's front A/F sensor.
    case mixture
    /// The recipe is about the car's own sensor: the gauge is read next to it ("wideband"), as a second opinion.
    case secondOpinion
}

/// Engine facts some checks need.
public struct RecipeContext: Sendable {
    public var displacementLiters: Double

    public init(displacementLiters: Double = 2.0) {
        self.displacementLiters = displacementLiters
    }

    public init(identity: ECUIdentity?) {
        let engine = identity.flatMap { EngineDiagnostics.engineType(systemID: $0.systemID) } ?? ""
        displacementLiters = engine.hasPrefix("2.5") ? 2.5 : (engine.hasPrefix("3.") ? 3.0 : 2.0)
    }
}

/// Everything an analysis gets: data per step (guided) or the whole log.
public struct Analysis: Sendable {
    public var steps: [DataSet]
    public var stepCompleted: [Bool]
    public var all: DataSet
    public var available: Set<String>
    public var context: RecipeContext
    /// "lambda" in this data is a separate wideband gauge, not the car's front A/F sensor.
    public var mixtureFromWideband = false

    public init(steps: [DataSet], stepCompleted: [Bool], available: Set<String>, context: RecipeContext) {
        self.steps = steps
        self.stepCompleted = stepCompleted
        self.all = DataSet(rows: steps.flatMap(\.rows))
        self.available = available
        self.context = context
    }

    public init(log: DataSet, available: Set<String>, context: RecipeContext) {
        steps = [log]
        stepCompleted = [true]
        all = log
        self.available = available
        self.context = context
    }

    public func step(_ i: Int) -> DataSet { i < steps.count ? steps[i] : DataSet() }
    public func completed(_ i: Int) -> Bool { i < stepCompleted.count && stepCompleted[i] }
}

public struct Recipe: Identifiable, Sendable {
    public var id: String
    public var setting: RecipeSetting
    public var title: String
    public var symbol: String
    public var category: String
    /// What the recipe finds out.
    public var summary: String
    /// Complaints it helps with.
    public var symptoms: [String]
    /// Before you start.
    public var conditions: [String]
    public var safety: String?
    public var minutes: Int
    public var probes: [Probe]
    public var widebandRole: WidebandRole
    public var steps: [RecipeStep]
    /// What the analysis looks at, in plain words.
    public var lookFor: [String]
    /// One-sentence verdicts for the result screen: pass, warning, fail.
    public var headlines: (pass: String, warning: String, fail: String)
    public var analyze: @Sendable (Analysis) -> [Finding]

    public func headline(for findings: [Finding]) -> String {
        switch Self.verdict(findings) {
        case .fail: return headlines.fail
        case .warning: return headlines.warning
        case .pass: return headlines.pass
        case .info: return "Not enough data to judge. Check that the steps were followed."
        }
    }

    public init(id: String, setting: RecipeSetting, title: String, symbol: String, category: String, summary: String,
                symptoms: [String] = [], conditions: [String] = [], safety: String? = nil, minutes: Int,
                probes: [Probe], widebandRole: WidebandRole = .mixture, steps: [RecipeStep], lookFor: [String] = [],
                headlines: (pass: String, warning: String, fail: String),
                analyze: @escaping @Sendable (Analysis) -> [Finding]) {
        self.headlines = headlines
        self.id = id
        self.setting = setting
        self.title = title
        self.symbol = symbol
        self.category = category
        self.summary = summary
        self.symptoms = symptoms
        self.conditions = conditions
        self.safety = safety
        self.minutes = minutes
        self.probes = probes
        self.widebandRole = widebandRole
        self.steps = steps
        self.lookFor = lookFor
        self.analyze = analyze
    }

    public func probe(_ key: String) -> Probe? { probes.first { $0.key == key } }

    /// The values the recipe reads when the tests use a separate wideband gauge: the gauge takes the place
    /// of the car's front A/F sensor, or is read next to it. A recipe that never looks at the mixture is unchanged.
    public func probes(useWideband: Bool) -> [Probe] {
        guard useWideband, let sensor = probe("lambda") else { return probes }
        switch widebandRole {
        case .mixture:
            var gauge = Probes.wideband
            gauge.key = sensor.key
            gauge.required = sensor.required
            return probes.map { $0.key == sensor.key ? gauge : $0 }
        case .secondOpinion:
            return probes + [Probes.wideband]
        }
    }

    /// The analysis, plus a line about the wideband gauge when the mixture came from it, so a result
    /// always says which sensor it trusted.
    public func findings(for analysis: Analysis) -> [Finding] {
        var findings = analyze(analysis)
        guard analysis.mixtureFromWideband else { return findings }
        if analysis.all.has("lambda") {
            findings.append(Finding(.info, "Mixture read from the wideband gauge",
                                    "Where this test shows or judges the air/fuel mixture, it used your AEM wideband gauge instead of the car's own front A/F sensor."))
        } else {
            // Only a test that needs the mixture is held up by a silent gauge.
            findings.insert(Finding(probe("lambda")?.required == true ? .warning : .info, "No reading from the wideband gauge",
                                    "The test was set to take the mixture from your wideband gauge, but no readings arrived, so the mixture was not judged. Check the gauge in Settings > Wideband, or switch this test back to the car's own sensor."),
                            at: 0)
        }
        return findings
    }

    /// Overall result: the worst finding, ignoring info.
    public static func verdict(_ findings: [Finding]) -> Severity {
        findings.map(\.severity).filter { $0 != .info }.max() ?? .info
    }
}

/// A recipe's probes matched to the parameters of one ECU (or one log).
public struct RecipeBinding: Sendable {
    public struct Bound: Sendable {
        public var probe: Probe
        public var parameter: ParameterDefinition
        public var conversion: Conversion
    }

    public var bound: [String: Bound]
    public var missing: [Probe]
    /// The keys of `bound` in the order of the recipe's probes; a dictionary has no order of its own.
    private var order: [String] = []

    public var missingRequired: [Probe] { missing.filter(\.required) }
    public var isRunnable: Bool { missingRequired.isEmpty }
    public var available: Set<String> { Set(bound.keys) }

    /// How the wideband gauge is read for this recipe, when it is one of its values.
    public var widebandConversion: Conversion? {
        bound.values.first { $0.parameter.id == AEMWideband.parameterID }?.conversion
    }
    /// The mixture ("lambda") comes from the wideband gauge instead of the car's front A/F sensor.
    public var mixtureFromWideband: Bool { bound["lambda"]?.parameter.id == AEMWideband.parameterID }

    /// Matches probes against live parameters, preferring a conversion in the canonical units. With
    /// `useWideband`, a wideband gauge among the parameters gets the role the recipe gives it.
    public init(recipe: Recipe, parameters: [ParameterDefinition], useWideband: Bool = false) {
        var bound: [String: Bound] = [:]
        var order: [String] = []
        var missing: [Probe] = []
        let gauge = useWideband && parameters.contains { $0.id == AEMWideband.parameterID }
        for probe in recipe.probes(useWideband: gauge) {
            guard let p = ParameterResolver.resolve(probe.concept, in: parameters), !p.conversions.isEmpty else {
                missing.append(probe)
                continue
            }
            let conversion = p.conversions.first { $0.units.caseInsensitiveCompare(probe.units) == .orderedSame }
                ?? p.conversions.first { UnitNormalizer.convert(1, from: $0.units, to: probe.units) != nil }
                ?? p.conversions[0]
            if bound[probe.key] == nil { order.append(probe.key) }
            bound[probe.key] = Bound(probe: probe, parameter: p, conversion: conversion)
        }
        self.bound = bound
        self.missing = missing
        self.order = order
    }

    /// What to ask the car for, in the order of the recipe's probes, so a recipe's log always has its
    /// columns in the same order.
    public var pollItems: [PollItem] {
        var seen = Set<String>()
        return order.compactMap { bound[$0] }.compactMap { b in
            let key = b.parameter.id + "|" + b.conversion.units
            guard seen.insert(key).inserted else { return nil }
            return PollItem(parameter: b.parameter, conversion: b.conversion)
        }
    }

    /// Converts polled values (by parameter ID) into a row keyed by probe, in canonical units.
    public func row(t: Double, values: [String: Double]) -> DataSet.Row {
        var v: [String: Double] = [:]
        for (key, b) in bound {
            guard let raw = values[b.parameter.id], raw.isFinite else { continue }
            v[key] = UnitNormalizer.convert(raw, from: b.conversion.units, to: b.probe.units) ?? raw
        }
        return DataSet.Row(t: t, v: v)
    }

    /// Maps a recorded log's columns onto the recipe's probes. With `useWideband`, a wideband gauge
    /// column in the log gets the role the recipe gives it; a log without one is read as usual.
    public static func dataSet(for recipe: Recipe, log: RecordedLog, useWideband: Bool = false)
        -> (DataSet, available: Set<String>, mixtureFromWideband: Bool) {
        var columnFor: [String: (Int, String, Probe)] = [:]
        let columns = log.columns.enumerated().map { i, c in
            ParameterDefinition(id: "C\(i)", name: c.name, kind: .standard, conversions: [Conversion(units: c.units, expression: "x")])
        }
        let gauge = useWideband && ParameterResolver.resolve(Probes.wideband.concept, in: columns) != nil
        for probe in recipe.probes(useWideband: gauge) {
            if let p = ParameterResolver.resolve(probe.concept, in: columns), let i = Int(p.id.dropFirst()) {
                columnFor[probe.key] = (i, log.columns[i].units, probe)
            }
        }
        var rows: [DataSet.Row] = []
        rows.reserveCapacity(log.rowCount)
        for r in 0..<log.rowCount {
            var v: [String: Double] = [:]
            for (key, (i, units, probe)) in columnFor {
                let raw = log.values[i][r]
                guard raw.isFinite else { continue }
                v[key] = UnitNormalizer.convert(raw, from: units, to: probe.units) ?? raw
            }
            rows.append(DataSet.Row(t: log.time[r], v: v))
        }
        return (DataSet(rows: rows), Set(columnFor.keys), gauge && recipe.widebandRole == .mixture && columnFor["lambda"] != nil)
    }
}

// MARK: - Formatting helpers for findings

func fmt(_ v: Double?, _ decimals: Int = 1, _ units: String = "") -> String {
    guard let v, v.isFinite else { return "–" }
    let s = String(format: "%.\(decimals)f", v)
    return units.isEmpty ? s : "\(s) \(units)"
}

func signed(_ v: Double?, _ decimals: Int = 1, _ units: String = "") -> String {
    guard let v, v.isFinite else { return "–" }
    let s = String(format: "%+.\(decimals)f", v)
    return units.isEmpty ? s : "\(s) \(units)"
}
