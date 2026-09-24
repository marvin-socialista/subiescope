import Foundation

/// Reusable analysis building blocks. Thresholds are deliberately conservative
/// rules of thumb for Subaru EJ turbo engines; findings say "likely" and point
/// at what to check, they do not replace a proper diagnosis.
enum Checks {
    // MARK: Conditions

    static let running = Condition("Engine running") { ($0["rpm"] ?? 0) > 400 }
    static let engineOff = Condition("Engine off, ignition on") { ($0["rpm"] ?? 0) < 50 }
    static let atIdle = Condition("Engine idling") { r in (r["rpm"] ?? 0) > 400 && (r["rpm"] ?? 0) < 1200 }
    static let warm = Condition("Coolant at 75 °C or more, engine running") { r in (r["coolant"] ?? 0) >= 75 && (r["rpm"] ?? 0) > 400 }

    static func rpm(_ lo: Double, _ hi: Double) -> Condition {
        Condition("Engine speed \(Int(lo))–\(Int(hi)) rpm") { r in
            guard let v = r["rpm"] else { return false }
            return v >= lo && v <= hi
        }
    }

    static let wot = Condition("Full throttle above 3,000 rpm") { r in (r["throttle"] ?? 0) >= 85 && (r["rpm"] ?? 0) >= 3000 }

    static func wotRows(_ ds: DataSet) -> DataSet { ds.filter { wot.test($0) } }

    // MARK: Warm-up

    static func warmUp(_ a: Analysis, step: Int = 0) -> [Finding] {
        let running = a.all.filter { ($0["rpm"] ?? 0) > 400 }
        let warmCount = running.rows.filter { ($0["coolant"] ?? 0) >= 70 }.count
        let mostlyCold = running.has("coolant") && running.count >= 20 && Double(warmCount) < 0.3 * Double(running.count)
        if a.completed(step) && !mostlyCold { return [] }
        return [Finding(.warning, "Engine was not fully warm",
                        "Most of the test ran with coolant below 70 °C. A cold engine runs richer and reacts differently, so these results are less reliable; repeat the test once the coolant is above 75 °C.")]
    }

    /// Running rows from a warm engine; falls back to all running rows when the
    /// engine was cold for most of the test (warmUp() then adds a warning).
    static func warmRows(_ a: Analysis) -> DataSet {
        let running = a.all.filter { ($0["rpm"] ?? 0) > 400 }
        guard running.has("coolant") else { return running }
        let warm = running.filter { ($0["coolant"] ?? 0) >= 70 }
        return warm.count >= Swift.max(20, Int(0.3 * Double(running.count))) ? warm : running
    }

    // MARK: Fuel trims

    /// Interprets short + long term trims at idle versus a higher airflow.
    static func trimPattern(idle: Double?, higher: Double?, higherLabel: String) -> [Finding] {
        guard let idle else { return [Finding(.info, "Fuel trims not measured", "No A/F correction or learning values were recorded.")] }
        var out: [Finding] = []
        let measured = "idle \(signed(idle, 1, "%"))" + (higher.map { ", \(higherLabel) \(signed($0, 1, "%"))" } ?? "")
        let worst = Swift.max(abs(idle), abs(higher ?? 0))
        let sev: Severity = worst > 15 ? .fail : .warning
        if abs(idle) <= 8 && abs(higher ?? 0) <= 8 {
            out.append(Finding(.pass, "Fuel trims are normal", "Total correction (short + long term) stays within ±8 %.", measured: measured))
        } else if idle > 8, let higher, higher < idle - 6 {
            out.append(Finding(sev, "Lean at idle, better with more airflow",
                               "Classic sign of unmetered air: a vacuum leak (PCV hoses, intake coupler, brake booster line, cracked hose after the MAF, loose oil cap or dipstick). Smoke test the intake, or spray carb cleaner around joints at idle and watch the trims drop.",
                               measured: measured))
        } else if idle > 8, (higher ?? idle) > 8 {
            out.append(Finding(sev, "Lean everywhere",
                               "The ECU adds fuel at all airflows. Likely causes: MAF reading low (dirty or oiled sensor, wrong intake/tune scaling), low fuel pressure (pump, filter, regulator) or restricted injectors. Clean the MAF with MAF cleaner first.",
                               measured: measured))
        } else if idle < -8, (higher ?? idle) < -8 {
            out.append(Finding(sev, "Rich everywhere",
                               "The ECU removes fuel at all airflows. Likely causes: MAF over-reading, a leaking injector, too much fuel pressure, or fuel in the oil (short trips). A new intake without a matching tune also does this.",
                               measured: measured))
        } else if let higher, higher > 8, idle <= 8 {
            out.append(Finding(.warning, "Lean at higher airflow only",
                               "Trims are fine at idle but lean when more air flows: weak fuel pump or clogged filter, or the MAF under-reading at higher flow.",
                               measured: measured))
        } else {
            out.append(Finding(.warning, "Fuel trims are off", "Total correction is outside ±8 %. Watch it over a few drives.", measured: measured))
        }
        return out
    }

    static func totalTrim(_ ds: DataSet) -> Double? {
        let c = ds.mean("afc"), l = ds.mean("afl")
        if c == nil && l == nil { return nil }
        return (c ?? 0) + (l ?? 0)
    }

    // MARK: A/F sensor (front, wideband)

    static func frontSensorActivity(_ ds: DataSet) -> [Finding] {
        guard let std = ds.std("lambda"), let range = ds.range("lambda") else {
            return [Finding(.fail, "No A/F sensor data", "The front A/F sensor value was not received.")]
        }
        if std < 0.002 && range < 0.01 {
            return [Finding(.fail, "A/F sensor reading is flat",
                            "A working sensor moves constantly as the ECU corrects the mixture. A flat line points at a failed sensor, a sensor heater fault (check fuse and connector) or wiring. Codes P0130–P0134 or P0031/P0032 often come with it.",
                            measured: "spread \(fmt(range, 3))")]
        }
        return [Finding(.pass, "A/F sensor signal is alive", "The reading moves as the ECU trims the mixture.", measured: "spread \(fmt(range, 3)) λ")]
    }

    static func idleLambda(_ ds: DataSet) -> [Finding] {
        guard let m = ds.mean("lambda") else { return [] }
        let measured = "λ \(fmt(m, 3)) (AFR \(fmt(m * 14.7, 1)))"
        if m >= 0.97 && m <= 1.03 {
            return [Finding(.pass, "Idle mixture is stoichiometric", "Closed-loop idle should sit around λ 1.00.", measured: measured)]
        }
        let sev: Severity = (m < 0.94 || m > 1.06) ? .fail : .warning
        return [Finding(sev, m > 1 ? "Idle mixture reads lean" : "Idle mixture reads rich",
                        "Warm closed-loop idle should average λ 0.97–1.03. Check the fuel trims result: if trims are near zero while the sensor reads off, the sensor itself is suspect.",
                        measured: measured)]
    }

    /// Lean spike on over-run (fuel cut) and rich dip on a blip.
    static func frontSensorResponse(_ ds: DataSet) -> [Finding] {
        var out: [Finding] = []
        guard let maxL = ds.max("lambda"), let minL = ds.min("lambda") else { return out }
        if maxL >= 1.25 {
            out.append(Finding(.pass, "Goes lean on over-run", "Fuel cut shows up as a lean spike, as it should.", measured: "max λ \(fmt(maxL, 2))"))
        } else if maxL >= 1.1 {
            out.append(Finding(.warning, "Only a small lean spike on over-run",
                               "Rev above 3,000 rpm before letting go so the ECU cuts fuel. If it stays small, the sensor may be slow (aging or contaminated).",
                               measured: "max λ \(fmt(maxL, 2))"))
        } else {
            out.append(Finding(.fail, "No lean response on over-run",
                               "When the throttle snaps shut the mixture should read very lean. No response means a lazy or failed sensor, or an exhaust leak ahead of it.",
                               measured: "max λ \(fmt(maxL, 2))"))
        }
        if minL <= 0.95 {
            out.append(Finding(.pass, "Goes rich on a throttle blip", "Acceleration enrichment is visible.", measured: "min λ \(fmt(minL, 2))"))
        } else {
            out.append(Finding(.info, "No clear rich dip on the blip", "Blip the throttle more sharply to see enrichment; not a fault by itself.", measured: "min λ \(fmt(minL, 2))"))
        }
        // Response time from throttle closing to lean.
        if ds.has("throttle") {
            var times: [Double] = []
            var closedAt: Double?
            var wasOpen = false
            for r in ds.rows {
                guard let th = r["throttle"] else { continue }
                if th > 20 { wasOpen = true; closedAt = nil }
                if wasOpen && th < 3 && closedAt == nil { closedAt = r.t; wasOpen = false }
                if let c = closedAt, let l = r["lambda"], l > 1.2 {
                    times.append(r.t - c)
                    closedAt = nil
                }
            }
            if let worst = times.max() {
                let sev: Severity = worst <= 1.0 ? .pass : (worst <= 2.0 ? .warning : .fail)
                out.append(Finding(sev, sev == .pass ? "Sensor responds quickly" : "Sensor responds slowly",
                                   "Time from throttle closing to a lean reading. Healthy sensors react within about a second.",
                                   measured: "\(fmt(worst, 2)) s"))
            }
        }
        return out
    }

    static func heater(_ ds: DataSet, key: String, name: String) -> [Finding] {
        guard let m = ds.mean(key) else { return [] }
        if m < 0.05 {
            return [Finding(.warning, "\(name) heater draws no current",
                            "With a warm engine the heater should draw some current. Check the heater fuse, connector and heater resistance.",
                            measured: fmt(m, 2, "A"))]
        }
        return [Finding(.info, "\(name) heater current", "The heater is drawing current.", measured: fmt(m, 2, "A"))]
    }

    // MARK: Rear O2 / catalyst

    static func rearO2Alive(_ ds: DataSet) -> [Finding] {
        guard let lo = ds.min("rearO2"), let hi = ds.max("rearO2") else {
            return [Finding(.fail, "No rear O2 data", "The rear O2 sensor value was not received.")]
        }
        if hi < 0.15 {
            return [Finding(.fail, "Rear O2 sensor stays low",
                            "It never went above 0.15 V. Likely a failed sensor or heater, a wiring fault, or an exhaust leak just before the sensor.",
                            measured: "\(fmt(lo, 2))–\(fmt(hi, 2)) V")]
        }
        if hi - lo < 0.05 {
            // Steady is normal behind a good catalyst at constant speed; only over-run proves it stuck.
            let sawFuelCut = ds.rows.contains { ($0["throttle"] ?? 100) < 2 && ($0["rpm"] ?? 0) > 1800 }
            if sawFuelCut {
                return [Finding(.fail, "Rear O2 sensor is stuck", "The voltage barely moves, not even on over-run. Check the sensor, its heater and the wiring.",
                                measured: "\(fmt(lo, 2))–\(fmt(hi, 2)) V")]
            }
            return [Finding(.info, "Rear O2 sensor reads steady", "At a constant speed that's normal behind a working catalyst.",
                            measured: "\(fmt(lo, 2))–\(fmt(hi, 2)) V")]
        }
        return [Finding(.pass, "Rear O2 sensor signal is alive", "The voltage moves with the mixture.", measured: "\(fmt(lo, 2))–\(fmt(hi, 2)) V")]
    }

    /// Steady-state behaviour: behind a good catalyst the rear sensor sits fairly
    /// steady around 0.5–0.8 V instead of switching like a front sensor.
    static func catalyst(_ steady: DataSet) -> [Finding] {
        guard steady.count > 5, let mean = steady.mean("rearO2") else { return [] }
        var out: [Finding] = []
        let minutes = Swift.max(steady.duration / 60, 0.1)
        let perMinute = Double(steady.crossings("rearO2", level: 0.45, hysteresis: 0.05)) / minutes
        let measured = "\(fmt(perMinute, 0)) switches/min, average \(fmt(mean, 2)) V"
        if perMinute <= 12 {
            out.append(Finding(.pass, "Catalyst is storing oxygen", "The rear sensor stays steady at a constant speed, which means the catalyst evens out the mixture.", measured: measured))
        } else if perMinute <= 30 {
            out.append(Finding(.warning, "Rear sensor switches more than expected",
                               "The catalyst's oxygen storage may be reduced (aging catalyst). Keep an eye out for P0420.", measured: measured))
        } else {
            out.append(Finding(.fail, "Rear sensor switches like a front sensor",
                               "The catalyst is barely doing anything: worn or damaged catalyst, or a de-cat / high-flow pipe. This is what sets P0420.", measured: measured))
        }
        if mean < 0.3 && perMinute <= 12 {
            out.append(Finding(.warning, "Rear sensor reads lean at a steady speed",
                               "Usually an exhaust leak ahead of the sensor pulling in air, or an aging sensor.", measured: fmt(mean, 2, "V")))
        }
        return out
    }

    static func rearO2Response(_ ds: DataSet) -> [Finding] {
        guard let lo = ds.min("rearO2"), let hi = ds.max("rearO2") else { return [] }
        var out: [Finding] = []
        if lo < 0.2 {
            out.append(Finding(.pass, "Rear sensor drops on fuel cut", "It reads lean on over-run as it should.", measured: "min \(fmt(lo, 2)) V"))
        } else {
            out.append(Finding(lo < 0.35 ? .warning : .fail, "Rear sensor does not drop on fuel cut",
                               "On over-run the rear sensor should fall below 0.2 V within a few seconds. A slow or failed sensor does not.",
                               measured: "min \(fmt(lo, 2)) V"))
        }
        if hi > 0.6 {
            out.append(Finding(.pass, "Rear sensor rises when rich", "It reads rich after a throttle blip.", measured: "max \(fmt(hi, 2)) V"))
        } else {
            out.append(Finding(.warning, "Rear sensor stays below 0.6 V", "It should read rich (0.7 V or more) after enrichment. Possibly an aging sensor or exhaust leak.", measured: "max \(fmt(hi, 2)) V"))
        }
        return out
    }

    // MARK: MAF

    static func mafIdle(_ idle: DataSet, context: RecipeContext) -> [Finding] {
        guard let maf = idle.mean("maf") else { return [Finding(.fail, "No MAF data", "The mass airflow value was not received.")] }
        var out: [Finding] = []
        let lo = 1.0 * context.displacementLiters, hi = 3.25 * context.displacementLiters
        if maf >= lo && maf <= hi {
            out.append(Finding(.pass, "Idle airflow is plausible", "Expected about \(fmt(lo, 1))–\(fmt(hi, 1)) g/s at a warm idle for a \(fmt(context.displacementLiters, 1)) L engine.", measured: fmt(maf, 2, "g/s")))
        } else if maf < lo {
            out.append(Finding(.warning, "Idle airflow reads low",
                               "The MAF may be dirty or contaminated, or air enters after the MAF (intake leak). Combine with the fuel trim result.",
                               measured: fmt(maf, 2, "g/s")))
        } else {
            out.append(Finding(.warning, "Idle airflow reads high",
                               "Switch off A/C and electrical loads. If it stays high, the MAF may over-read or idle speed is raised.",
                               measured: fmt(maf, 2, "g/s")))
        }
        if let v = idle.mean("mafV") {
            out.append(v >= 0.9 && v <= 1.8
                ? Finding(.pass, "MAF signal voltage is normal at idle", "", measured: fmt(v, 2, "V"))
                : Finding(.warning, "MAF signal voltage is unusual at idle", "Around 1.0–1.6 V is typical at a warm idle. Check the connector and the sensor.", measured: fmt(v, 2, "V")))
        }
        if let std = idle.std("maf"), maf > 0 {
            let noise = std / maf
            if noise > 0.25 {
                out.append(Finding(.warning, "MAF signal is noisy at idle",
                                   "The reading jumps around. Check the connector, look for intake leaks and clean the sensor.",
                                   measured: "±\(fmt(noise * 100, 0)) %"))
            }
        }
        return out
    }

    static func mafScaling(idle: DataSet, higher: DataSet) -> [Finding] {
        guard let a = idle.mean("maf"), let b = higher.mean("maf"), a > 0 else { return [] }
        let ratio = b / a
        if ratio < 1.6 {
            return [Finding(.fail, "MAF barely responds to more air",
                            "At 2,500 rpm the airflow should be roughly 2.5–4× idle. A MAF that hardly changes is faulty or the reading is not reaching the ECU.",
                            measured: "×\(fmt(ratio, 1))")]
        }
        return [Finding(.pass, "MAF responds to engine speed", "Airflow rises with rpm as expected.", measured: "×\(fmt(ratio, 1)) from idle to 2,500 rpm")]
    }

    /// Compares the MAF with an airflow estimate from manifold pressure (speed density).
    static func mafVersusPressure(idle: DataSet, higher: DataSet, context: RecipeContext) -> [Finding] {
        func ratio(_ ds: DataSet) -> Double? {
            guard let maf = ds.mean("maf"), let map = ds.mean("map"), let rpm = ds.mean("rpm") else { return nil }
            let iat = ds.mean("iat") ?? 25
            let ve = 0.85
            let estimate = map * 1000 * (context.displacementLiters / 1000) * (rpm / 120) * ve / (287.05 * (iat + 273.15)) * 1000
            return estimate > 0 ? maf / estimate : nil
        }
        guard let r1 = ratio(idle), let r2 = ratio(higher) else { return [] }
        let drift = abs(r1 / r2 - 1)
        let measured = "MAF/estimate idle \(fmt(r1, 2)), 2,500 rpm \(fmt(r2, 2))"
        if drift > 0.35 {
            return [Finding(.warning, "MAF and manifold pressure disagree",
                            "Relative to what manifold pressure predicts, the MAF reads differently at idle than at 2,500 rpm. Suggests a MAF curve problem or an air leak.",
                            measured: measured)]
        }
        return [Finding(.info, "MAF agrees with manifold pressure", "The MAF tracks an airflow estimate from manifold pressure consistently.", measured: measured)]
    }

    // MARK: Knock, boost, fueling at full throttle

    static func knock(_ ds: DataSet) -> [Finding] {
        var out: [Finding] = []
        if let iam = ds.min("iam") {
            if iam >= 0.99 {
                out.append(Finding(.pass, "IAM is 1.0", "The ECU has full confidence in the timing.", measured: fmt(iam, 3)))
            } else {
                out.append(Finding(iam < 0.75 ? .fail : .warning, "IAM is below 1.0",
                                   "The ECU has reduced timing after seeing knock. Check fuel quality (use the octane the tune needs), heat soak, and have the car's tune looked at. Resetting the ECU restarts IAM learning.",
                                   measured: fmt(iam, 3)))
            }
        }
        if let fb = ds.min("fbkc") {
            let events = ds.segments(gap: 0.5) { ($0["fbkc"] ?? 0) < -0.3 }.count
            let worstRow = ds.rows.min { ($0["fbkc"] ?? 0) < ($1["fbkc"] ?? 0) }
            let at = worstRow.flatMap { $0["rpm"] }.map { " at \(fmt($0, 0)) rpm" } ?? ""
            if fb >= -1.41 {
                out.append(Finding(.pass, "Feedback knock is minimal",
                                   events == 0 ? "No knock corrections." : "Small, single corrections are normal.",
                                   measured: "worst \(fmt(fb, 2))°\(at), \(events) event\(events == 1 ? "" : "s")"))
            } else {
                out.append(Finding(fb < -2.81 ? .fail : .warning, "Knock under load",
                                   "The ECU pulled timing because it heard knock. Repeated knock at the same rpm points at fuel, heat or the tune; random single events can be false knock (loose heat shields, clutch/driveline noise).",
                                   measured: "worst \(fmt(fb, 2))°\(at), \(events) event\(events == 1 ? "" : "s")"))
            }
        }
        if let fl = ds.min("flkc") {
            if fl >= -0.01 {
                out.append(Finding(.pass, "No learned knock correction", "Fine learning knock correction is zero.", measured: fmt(fl, 2, "°")))
            } else if fl >= -1.41 {
                out.append(Finding(.pass, "Small learned knock correction",
                                   "A small learned correction in one load/rpm area is common and not a concern by itself.", measured: fmt(fl, 2, "°")))
            } else {
                out.append(Finding(fl < -2.81 ? .fail : .warning, "Learned knock correction present",
                                   "The ECU has learned to pull timing in some load/rpm cells: knock happened there repeatedly.",
                                   measured: fmt(fl, 2, "°")))
            }
        }
        if let iat = ds.max("iat"), iat > 55 {
            out.append(Finding(.warning, "Hot intake air", "Intake air above 55 °C makes knock more likely. Let the intercooler cool down (drive, don't idle) and retest.", measured: fmt(iat, 0, "°C")))
        }
        return out
    }

    static func wotFueling(_ wotRows: DataSet) -> [Finding] {
        let high = wotRows.filter { ($0["rpm"] ?? 0) >= 4000 }
        guard let mean = high.mean("lambda"), let worst = high.max("lambda") else { return [] }
        let measured = "average λ \(fmt(mean, 2)) (AFR \(fmt(mean * 14.7, 1))), leanest λ \(fmt(worst, 2))"
        if worst > 0.86 {
            return [Finding(.fail, "Lean at full throttle",
                            "A turbo engine needs a rich mixture under boost (around λ 0.75–0.82). Stop doing pulls and check fuel pressure, pump, injectors, MAF and the tune.",
                            measured: measured)]
        }
        if mean > 0.83 {
            return [Finding(.warning, "Slightly lean at full throttle", "Richer (λ 0.75–0.82) is safer under boost.", measured: measured)]
        }
        if mean < 0.72 {
            return [Finding(.warning, "Very rich at full throttle", "Overly rich costs power and can foul plugs; check the tune or MAF scaling.", measured: measured)]
        }
        return [Finding(.pass, "Full-throttle mixture is safe", "Rich enough for boost.", measured: measured)]
    }

    static func injectorDuty(_ ds: DataSet) -> [Finding] {
        let duty = ds.rows.compactMap { r -> Double? in
            guard let rpm = r["rpm"], let ipw = r["ipw"] else { return nil }
            return rpm * ipw / 1200
        }
        guard let peak = duty.max() else { return [] }
        if peak > 95 {
            return [Finding(.fail, "Injectors are maxed out", "Duty cycle above 95 % means the injectors can't deliver more fuel: the engine may run lean.", measured: fmt(peak, 0, "%"))]
        }
        if peak > 85 {
            return [Finding(.warning, "Injector duty cycle is high", "Above 85 % leaves little margin.", measured: fmt(peak, 0, "%"))]
        }
        return [Finding(.pass, "Injector duty cycle is fine", "", measured: "peak \(fmt(peak, 0, "%"))")]
    }

    static func boost(_ wotRows: DataSet) -> [Finding] {
        var out: [Finding] = []
        let high = wotRows.filter { ($0["rpm"] ?? 0) >= 4000 }
        guard let peak = wotRows.max("mrp") else { return out }
        let spoolRow = wotRows.rows.first { ($0["mrp"] ?? -100) >= 0.8 * peak }
        out.append(Finding(.info, "Peak boost", "", measured: "\(fmt(peak, 0, "kPa")) (\(fmt(peak / 100, 2, "bar")))" + (spoolRow?["rpm"].map { ", 80 % of peak at \(fmt($0, 0)) rpm" } ?? "")))
        guard wotRows.has("target"), let errMean = Stats.mean(high.rows.compactMap { r in
            guard let t = r["target"], let m = r["mrp"] else { return nil }
            return t - m
        }) else { return out }
        let overshoot = wotRows.rows.compactMap { r -> Double? in
            guard let t = r["target"], let m = r["mrp"] else { return nil }
            return m - t
        }.max() ?? 0
        let wgdc = high.mean("wgdc")
        if errMean > 15 {
            let leak = (wgdc ?? 0) > 70
            out.append(Finding(errMean > 30 ? .fail : .warning, "Underboost",
                               leak ? "Boost stays below target while the wastegate duty is high: a boost leak is likely (intercooler couplers, bypass valve, turbo inlet). Pressure test the intake."
                                    : "Boost stays below target: check for boost leaks, the wastegate actuator and the boost control solenoid.",
                               measured: "\(fmt(errMean, 0)) kPa below target" + (wgdc.map { ", wastegate duty \(fmt($0, 0, "%"))" } ?? "")))
        } else if overshoot > 15 {
            out.append(Finding(overshoot > 25 ? .fail : .warning, "Boost overshoots target",
                               "Boost spikes above target: check the wastegate actuator and boost control solenoid, and have the boost control tuning looked at.",
                               measured: "up to \(fmt(overshoot, 0)) kPa over"))
        } else {
            out.append(Finding(.pass, "Boost follows target", "Actual boost stays within about 15 kPa of target.", measured: "average error \(signed(-errMean, 0, "kPa"))"))
        }
        if let creep = high.rows.filter({ ($0["wgdc"] ?? 100) < 5 }).compactMap({ r -> Double? in
            guard let t = r["target"], let m = r["mrp"] else { return nil }
            return m - t
        }).max(), creep > 15 {
            out.append(Finding(.warning, "Boost creep", "Boost rises above target at high rpm even with the wastegate fully open: wastegate port too small for the exhaust flow.", measured: "+\(fmt(creep, 0)) kPa"))
        }
        return out
    }

    // MARK: Idle and misfires

    static let cylinders = ["rough1", "rough2", "rough3", "rough4"]

    static func misfires(_ ds: DataSet) -> [Finding] {
        let counts = cylinders.enumerated().compactMap { i, key in ds.increase(key).map { (i + 1, $0) } }
        guard !counts.isEmpty else {
            return [Finding(.info, "Misfire counters not available", "This ECU does not report per-cylinder roughness counters.")]
        }
        let minutes = Swift.max(ds.duration / 60, 0.25)
        let bad = counts.filter { $0.1 / minutes >= 5 }
        let some = counts.filter { $0.1 > 0 }
        let measured = counts.map { "#\($0.0): \(Int($0.1))" }.joined(separator: ", ")
        if !bad.isEmpty {
            return [Finding(.fail, "Misfires on cylinder \(bad.map { "#\($0.0)" }.joined(separator: " and "))",
                            "Cylinders 1 and 3 are on the right side of the car, 2 and 4 on the left (front to back). Swap that cylinder's coil with a neighbour and retest: if the misfire moves, replace the coil; if not, check the spark plug, injector and compression.",
                            measured: measured)]
        }
        if !some.isEmpty {
            return [Finding(.warning, "Occasional misfire counts", "A few counts can be normal; watch whether one cylinder keeps adding up.", measured: measured)]
        }
        return [Finding(.pass, "No misfires counted", "", measured: measured)]
    }

    static func idleStability(_ idle: DataSet) -> [Finding] {
        guard let mean = idle.mean("rpm"), let std = idle.std("rpm"), let lo = idle.min("rpm") else { return [] }
        var out: [Finding] = []
        let measured = "\(fmt(mean, 0)) rpm ± \(fmt(std, 0))"
        if std <= 20 {
            out.append(Finding(.pass, "Idle is steady", "", measured: measured))
        } else {
            out.append(Finding(std > 45 ? .fail : .warning, "Idle speed hunts",
                               "Unsteady idle: vacuum leaks, a dirty throttle body, misfires or a failing idle control are the usual suspects.",
                               measured: measured))
        }
        if lo < mean - 150 {
            out.append(Finding(.warning, "Idle dips", "The engine speed drops sharply at times (stumble). Common with misfires or vacuum leaks.", measured: "lowest \(fmt(lo, 0)) rpm"))
        }
        if mean > 1000 {
            out.append(Finding(.info, "Idle speed is high", "Is the engine fully warm and the A/C off?", measured: fmt(mean, 0, "rpm")))
        }
        return out
    }

    // MARK: Charging

    static func batteryEngineOff(_ ds: DataSet) -> [Finding] {
        guard let v = ds.mean("battery") else { return [] }
        if v >= 12.4 { return [Finding(.pass, "Battery is charged", "Engine off it should read 12.4 V or more (12.6 V when fully charged).", measured: fmt(v, 2, "V"))] }
        if v >= 12.0 { return [Finding(.warning, "Battery is partly discharged", "Charge it and retest; if it keeps dropping, test the battery or look for a drain.", measured: fmt(v, 2, "V"))] }
        return [Finding(.fail, "Battery is flat or failing", "Below 12.0 V with the engine off. Charge and load-test the battery.", measured: fmt(v, 2, "V"))]
    }

    static func charging(_ ds: DataSet, loaded: Bool) -> [Finding] {
        guard let v = ds.mean("battery") else { return [] }
        if loaded {
            if v >= 13.0 { return [Finding(.pass, "Charging holds up under load", "", measured: fmt(v, 2, "V"))] }
            return [Finding(v < 12.6 ? .fail : .warning, "Voltage sags under load",
                            "With lights, blower and defogger on the alternator should still deliver 13 V or more. Check the drive belt, alternator and the battery terminals.",
                            measured: fmt(v, 2, "V"))]
        }
        if v > 15.0 { return [Finding(.fail, "Overcharging", "Above 15 V damages the battery and electronics: voltage regulator fault.", measured: fmt(v, 2, "V"))] }
        if v >= 13.4 { return [Finding(.pass, "Alternator is charging", "13.4–14.9 V is normal with the engine running.", measured: fmt(v, 2, "V"))] }
        return [Finding(v < 13.0 ? .fail : .warning, "Charging voltage is low",
                        "Check the alternator, its belt and the battery terminals. Some ECUs lower the charge voltage when the battery is full, so recheck after switching on loads.",
                        measured: fmt(v, 2, "V"))]
    }
}
