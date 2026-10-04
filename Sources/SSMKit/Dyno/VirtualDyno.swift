import Foundation

/// Car data the virtual dyno needs. Defaults: 2008 Impreza WRX STI (GRB), JDM.
public struct DynoSettings: Sendable, Equatable, Codable {
    /// Car + driver + fuel.
    public var massKg: Double = 1480 + 80
    public var gearRatios: [Double] = [3.636, 2.375, 1.761, 1.346, 1.062, 0.842]
    public var finalDrive: Double = 3.900
    /// 1-based gear of the pull; nil = detect from speed.
    public var gear: Int? = 3
    public var tireWidthMM: Double = 245
    public var tireAspect: Double = 40
    public var rimInches: Double = 18
    public var dragCoefficient: Double = 0.33
    public var frontalAreaM2: Double = 2.2
    public var rollingResistance: Double = 0.015
    /// Share of crank power lost in the drivetrain (AWD manual: about 15–20 %).
    public var drivetrainLoss: Double = 0.17

    public init() {}

    public var tireDiameterM: Double { rimInches * 0.0254 + 2 * tireWidthMM * tireAspect / 100 / 1000 }
    public var tireCircumferenceM: Double { .pi * tireDiameterM }

    /// Road speed (m/s) at `rpm` in `gear`.
    public func speed(rpm: Double, gear: Int) -> Double {
        let ratio = gearRatios[max(0, min(gearRatios.count - 1, gear - 1))] * finalDrive
        return rpm / 60 * tireCircumferenceM / ratio
    }
}

public struct DynoPoint: Sendable, Hashable {
    public var rpm: Double
    /// Power at the wheels, W.
    public var wheelPower: Double
    /// Wheel power expressed as torque at engine speed, Nm (what chassis dynos report).
    public var torque: Double
    public var boost: Double?
}

/// Whether a pull is good enough to trust, with reasons a driver understands.
public struct PullQuality: Sendable {
    public enum Verdict: Int, Sendable, Comparable {
        case good, usable, retry
        public static func < (a: Verdict, b: Verdict) -> Bool { a.rawValue < b.rawValue }
    }

    public var verdict: Verdict
    /// Why it isn't perfect, and what to do next time.
    public var issues: [String]

    public init(verdict: Verdict, issues: [String]) {
        self.verdict = verdict
        self.issues = issues
    }

    public var headline: String {
        switch verdict {
        case .good: return "Good pull"
        case .usable: return "Usable, with notes"
        case .retry: return "Retry this pull"
        }
    }
}

public struct DynoRun: Sendable, Identifiable {
    public var id: Int
    public var quality = PullQuality(verdict: .good, issues: [])
    public var startTime: Double
    public var duration: Double
    public var gear: Int
    public var points: [DynoPoint]
    public var settings: DynoSettings

    public var peakPower: DynoPoint? { points.max { $0.wheelPower < $1.wheelPower } }
    public var peakTorque: DynoPoint? { points.max { $0.torque < $1.torque } }
    public var rpmRange: ClosedRange<Double>? {
        guard let lo = points.first?.rpm, let hi = points.last?.rpm else { return nil }
        return lo...hi
    }

    /// Estimated flywheel power from wheel power and drivetrain loss.
    public func crankPower(_ wheel: Double) -> Double { wheel / (1 - settings.drivetrainLoss) }
}

public enum PowerUnit: String, CaseIterable, Sendable {
    case ps, hp, kW

    public func convert(_ watts: Double) -> Double {
        switch self {
        case .ps: return watts / 735.49875
        case .hp: return watts / 745.69987
        case .kW: return watts / 1000
        }
    }

    public var label: String {
        switch self {
        case .ps: return "PS"
        case .hp: return "hp"
        case .kW: return "kW"
        }
    }
}

public enum VirtualDyno {
    struct Columns {
        var rpm: Int
        var throttle: Int?
        var knock: Int?
        var speed: (Int, String)?
        var iat: (Int, String)?
        var atm: (Int, String)?
        var boost: (Int, String)?
    }

    static func columns(_ log: RecordedLog) -> Columns? {
        let params = log.columns.enumerated().map { i, c in
            ParameterDefinition(id: "\(i)", name: c.name, kind: .standard, conversions: [Conversion(units: c.units, expression: "x")])
        }
        func find(_ concept: String) -> Int? { ParameterResolver.resolve(concept, in: params).flatMap { Int($0.id) } }
        guard let rpm = find("Engine Speed") else { return nil }
        let throttle = find("Throttle Opening Angle") ?? find("Accelerator Pedal Angle")
        func withUnits(_ i: Int?) -> (Int, String)? { i.map { ($0, log.columns[$0].units) } }
        return Columns(rpm: rpm, throttle: throttle, knock: find("Feedback Knock Correction"), speed: withUnits(find("Vehicle Speed")),
                       iat: withUnits(find("Intake Air Temperature")),
                       atm: withUnits(find("Atmospheric Pressure")), boost: withUnits(find("Manifold Relative Pressure")))
    }

    /// Row ranges of full-throttle pulls where rpm keeps rising (at least 1.5 s, 1,500 rpm).
    public static func findPulls(in log: RecordedLog) -> [ClosedRange<Int>] {
        guard let c = columns(log) else { return [] }
        var pulls: [ClosedRange<Int>] = []
        var start: Int?
        var peak = 0.0
        func close(_ end: Int) {
            if let s = start, end > s, log.time[end] - log.time[s] >= 1.5,
               log.values[c.rpm][end] - log.values[c.rpm][s] >= 1500 {
                pulls.append(s...end)
            }
            start = nil
        }
        for i in 0..<log.rowCount {
            let rpm = log.values[c.rpm][i]
            let wot = c.throttle.map { log.values[$0][i] >= 85 } ?? true
            if wot && rpm.isFinite {
                if start == nil { start = i; peak = rpm }
                // A drop of more than 150 rpm means a shift or lift: end of this pull.
                if rpm < peak - 150 { close(i - 1); start = i; peak = rpm }
                peak = max(peak, rpm)
            } else if start != nil {
                close(i - 1)
            }
        }
        if start != nil { close(log.rowCount - 1) }
        return pulls
    }

    /// Guesses the gear by comparing engine speed with road speed.
    public static func detectGear(log: RecordedLog, rows: ClosedRange<Int>, settings: DynoSettings) -> Int? {
        guard let c = columns(log), let (si, units) = c.speed else { return nil }
        var ratios: [Double] = []
        for i in rows {
            let rpm = log.values[c.rpm][i]
            guard let kmh = UnitNormalizer.convert(log.values[si][i], from: units, to: "km/h"), kmh > 15, rpm > 1000 else { continue }
            ratios.append(kmh / 3.6 / rpm)
        }
        guard let observed = Stats.mean(ratios) else { return nil }
        return (1...settings.gearRatios.count).min {
            abs(settings.speed(rpm: 1, gear: $0) - observed) < abs(settings.speed(rpm: 1, gear: $1) - observed)
        }
    }

    public static func run(log: RecordedLog, rows: ClosedRange<Int>, settings: DynoSettings, id: Int = 0) -> DynoRun? {
        guard let c = columns(log), rows.count >= 8 else { return nil }
        let gear = settings.gear ?? detectGear(log: log, rows: rows, settings: settings) ?? 3
        let t = rows.map { log.time[$0] }
        let rpm = rows.map { log.values[c.rpm][$0] }
        let v = rpm.map { settings.speed(rpm: $0, gear: gear) }

        // Air density from intake temperature and atmospheric pressure when logged.
        let iat = c.iat.flatMap { col, units in Stats.mean(rows.compactMap { UnitNormalizer.convert(log.values[col][$0], from: units, to: "C") }.filter(\.isFinite)) } ?? 25
        let atm = c.atm.flatMap { col, units in Stats.mean(rows.compactMap { UnitNormalizer.convert(log.values[col][$0], from: units, to: "kPa") }.filter(\.isFinite)) } ?? 101.3
        let rho = atm * 1000 / (287.05 * (iat + 273.15))

        var points: [DynoPoint] = []
        let half = 0.4
        for i in 0..<t.count {
            // Local quadratic fit of speed over ±0.4 s; its slope at t[i] is the acceleration.
            var sx = 0.0, sx2 = 0.0, sx3 = 0.0, sx4 = 0.0, sy = 0.0, sxy = 0.0, sx2y = 0.0, n = 0.0
            for j in 0..<t.count where abs(t[j] - t[i]) <= half {
                let x = t[j] - t[i], y = v[j]
                sx += x; sx2 += x * x; sx3 += x * x * x; sx4 += x * x * x * x
                sy += y; sxy += x * y; sx2y += x * x * y; n += 1
            }
            guard n >= 4 else { continue }
            // Solve [n sx sx2; sx sx2 sx3; sx2 sx3 sx4] [c0 c1 c2] = [sy sxy sx2y] for c1.
            let m = [[n, sx, sx2], [sx, sx2, sx3], [sx2, sx3, sx4]]
            let det = determinant(m)
            guard abs(det) > 1e-12 else { continue }
            let m1 = [[n, sy, sx2], [sx, sxy, sx3], [sx2, sx2y, sx4]]
            let accel = determinant(m1) / det
            let speed = v[i]
            let force = settings.massKg * accel + 0.5 * rho * settings.dragCoefficient * settings.frontalAreaM2 * speed * speed
                + settings.rollingResistance * settings.massKg * 9.81
            let power = force * speed
            let omega = rpm[i] * 2 * .pi / 60
            // An empty cell in the log is not a number, and one of those would spoil the average of its whole bin.
            let boost = c.boost.flatMap { col, units in UnitNormalizer.convert(log.values[col][rows.lowerBound + i], from: units, to: "kPa") }
                .flatMap { $0.isFinite ? $0 : nil }
            points.append(DynoPoint(rpm: rpm[i], wheelPower: power, torque: omega > 0 ? power / omega : 0, boost: boost))
        }
        // Average into 100 rpm bins, then smooth lightly.
        let binned = Dictionary(grouping: points) { ($0.rpm / 100).rounded() * 100 }
            .compactMap { rpm, group -> DynoPoint? in
                guard let p = Stats.mean(group.map(\.wheelPower)), let tq = Stats.mean(group.map(\.torque)) else { return nil }
                return DynoPoint(rpm: rpm, wheelPower: p, torque: tq, boost: Stats.mean(group.compactMap(\.boost)))
            }
            .sorted { $0.rpm < $1.rpm }
        let smoothed = binned.indices.map { i -> DynoPoint in
            let window = binned[max(0, i - 1)...min(binned.count - 1, i + 1)]
            var p = binned[i]
            p.wheelPower = window.map(\.wheelPower).reduce(0, +) / Double(window.count)
            p.torque = window.map(\.torque).reduce(0, +) / Double(window.count)
            return p
        }
        guard smoothed.count >= 3 else { return nil }
        var run = DynoRun(id: id, startTime: t.first ?? 0, duration: (t.last ?? 0) - (t.first ?? 0), gear: gear, points: smoothed, settings: settings)
        run.quality = quality(log: log, rows: rows, columns: c, gear: gear, settings: settings)
        return run
    }

    static func quality(log: RecordedLog, rows: ClosedRange<Int>, columns c: Columns, gear: Int, settings: DynoSettings) -> PullQuality {
        var issues: [String] = []
        var verdict = PullQuality.Verdict.good
        func flag(_ v: PullQuality.Verdict, _ text: String) {
            verdict = max(verdict, v)
            issues.append(text)
        }
        let rpm = rows.map { log.values[c.rpm][$0] }
        let duration = log.time[rows.upperBound] - log.time[rows.lowerBound]
        let startRPM = rpm.first ?? 0, endRPM = rpm.max() ?? 0

        if startRPM > 3500 {
            flag(.retry, "Started at \(Int(startRPM)) rpm. Start lower (about 2,500 rpm) so the curve includes the boost build-up.")
        } else if startRPM > 3000 {
            flag(.usable, "Started at \(Int(startRPM)) rpm; starting around 2,500 rpm shows the whole boost build-up.")
        }
        if endRPM < 5500 {
            flag(.retry, "Ended at \(Int(endRPM)) rpm. Hold full throttle until just before the rev limiter.")
        } else if endRPM < 6200 {
            flag(.usable, "Ended at \(Int(endRPM)) rpm; holding on a bit longer shows the top end.")
        }
        if let th = c.throttle, let lowest = rows.map({ log.values[th][$0] }).filter(\.isFinite).min(), lowest < 95 {
            flag(.usable, "The throttle dipped to \(Int(lowest)) %. Keep the pedal flat on the floor for the whole pull.")
        }
        let rate = Double(rows.count - 1) / max(duration, 0.001)
        if rate < 6 {
            flag(.retry, String(format: "Only %.1f samples per second: too few for a smooth curve. Log fewer parameters and keep Fast poll on.", rate))
        } else if rate < 10 {
            flag(.usable, String(format: "%.1f samples per second. Logging fewer parameters gives a smoother curve.", rate))
        }
        var dips = 0
        var peak = 0.0
        for r in rpm {
            if r < peak - 80 { dips += 1 }
            peak = max(peak, r)
        }
        if dips > 1 {
            flag(.retry, "The rpm dropped during the pull. That's wheelspin, clutch slip or a lift: try a higher gear or a smoother throttle.")
        }
        // Wheelspin or clutch slip shows as rpm running away from road speed.
        if let (si, units) = c.speed {
            let expected = settings.speed(rpm: 1, gear: gear)
            let ratios = rows.compactMap { i -> Double? in
                guard let kmh = UnitNormalizer.convert(log.values[si][i], from: units, to: "km/h"), kmh > 20 else { return nil }
                return kmh / 3.6 / log.values[c.rpm][i] / expected
            }
            if let lo = ratios.min(), lo < 0.9 {
                flag(.retry, "Engine speed ran ahead of road speed: wheelspin or a slipping clutch. Use a higher gear, or check the clutch.")
            }
        }
        if let k = c.knock, let worst = rows.map({ log.values[k][$0] }).filter(\.isFinite).min(), worst < -1.41 {
            flag(.usable, String(format: "Knock during the pull (%.1f°): the engine made less power than it can. Check fuel and heat before comparing.", worst))
        }
        if duration < 3 && verdict == .good {
            flag(.usable, "A short pull (\(String(format: "%.1f", duration)) s). A higher gear gives a longer, more accurate pull.")
        }
        return PullQuality(verdict: verdict, issues: issues)
    }

    public static func runs(log: RecordedLog, settings: DynoSettings) -> [DynoRun] {
        findPulls(in: log).enumerated().compactMap { i, rows in run(log: log, rows: rows, settings: settings, id: i + 1) }
    }

    static func determinant(_ m: [[Double]]) -> Double {
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    }
}
