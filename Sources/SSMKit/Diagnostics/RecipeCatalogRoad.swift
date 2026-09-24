import Foundation

extension RecipeCatalog {
    static let roadSafety = "Only drive where it is safe and legal. Let a passenger watch the screen, or glance at it only when stopped."

    // MARK: - On the road

    static let pull = Recipe(
        id: "pull", setting: .driving, title: "Full-throttle pull", symbol: "flag.checkered",
        category: "Performance",
        summary: "One pull in 3rd gear tells you a lot: whether the engine knocks, whether the mixture is safely rich under boost, whether boost follows its target and how hard the injectors work.",
        symptoms: ["Down on power", "Hesitation under boost", "After a tune, new parts or bad fuel", "Check before a track day"],
        conditions: ["Engine fully warm", "Good fuel in the tank", "A closed road, track or dyno"],
        safety: "Full-throttle pulls are only for a closed road, track or dyno. Keep your eyes on the road; SubieScope records everything.",
        minutes: 5,
        probes: [P.rpm, P.throttle, P.coolant, P.mrp, P.lambda, opt(P.target), opt(P.wgdc), opt(P.fbkc), opt(P.flkc), opt(P.iam),
                 opt(P.timing), opt(P.iat), opt(P.ipw), opt(P.maf)],
        steps: [warmUpStep(), pullStep(),
                cruiseStep(title: "Lift off and cruise", seconds: 5, speed: 20...200, instruction: "Lift off and cruise normally for a few seconds.")],
        lookFor: ["IAM stays at 1.0 and knock corrections stay small", "The mixture under boost is rich: λ 0.75–0.82 (AFR 11–12)",
                  "Boost follows the target", "Injector duty stays below 85–90 %"],
        headlines: (pass: "The pull looks healthy: no real knock, safe fueling and boost on target.",
                    warning: "The pull is mostly fine, with something worth watching.",
                    fail: "The pull shows a problem. Avoid full-throttle driving until it's sorted."),
        analyze: { a in
            let wot = Checks.wotRows(a.all)
            guard wot.count >= 5 else {
                return [Finding(.fail, "No full-throttle pull recorded", "Floor the throttle from about 2,500 rpm to 6,000+ rpm in 3rd gear.")]
            }
            var f = Checks.warmUp(a)
            f += Checks.knock(a.all.filter { ($0["rpm"] ?? 0) > 1500 })
            f += Checks.wotFueling(wot)
            f += Checks.boost(wot)
            f += Checks.injectorDuty(wot)
            if let t = wot.filter({ ($0["rpm"] ?? 0) > 5000 }).mean("timing") {
                f.append(Finding(.info, "Timing near redline", "For reference when comparing pulls.", measured: fmt(t, 1, "°")))
            }
            return f
        })

    static let knock = Recipe(
        id: "knock", setting: .driving, title: "Knock check", symbol: "waveform.badge.exclamationmark",
        category: "Engine",
        summary: "Drives through the conditions where knock happens and measures how much there is: how often the ECU pulls timing, how deep, at which rpm and load, and whether it has learned to pull timing. It also looks at what was going on when it knocked.",
        symptoms: ["Pinging or rattling under acceleration", "Down on power, especially on hot days", "After a tune or a new intake", "Unsure about fuel quality", "IAM below 1.0"],
        conditions: ["Engine fully warm", "A road where you can accelerate in 4th gear safely", "Note which fuel is in the tank"],
        safety: roadSafety,
        minutes: 8,
        probes: [P.rpm, P.throttle, P.coolant, P.fbkc, opt(P.flkc), opt(P.iam), opt(P.timing), opt(P.mrp), opt(P.iat),
                 opt(P.lambda), opt(P.load), opt(P.speed)],
        steps: [warmUpStep(),
                cruiseStep(title: "Cruise", seconds: 60, speed: 40...120,
                           instruction: "Drive normally at a steady speed for a minute. This shows whether there is knock even at light load."),
                RecipeStep("Roll-ons in 4th gear",
                           "In 4th gear at about 2,000 rpm, press the pedal to about three quarters and accelerate to 4,500 rpm, then ease off. Repeat four times. Medium rpm under high load is where knock usually shows up first.",
                           goal: .collect(seconds: 30, whenever: Condition("Three-quarter throttle above 1,800 rpm") { ($0["throttle"] ?? 0) >= 50 && ($0["rpm"] ?? 0) >= 1800 }),
                           watch: [Watch("fbkc", expected: -1.41...0), Watch("rpm"), Watch("mrp"), Watch("iat", expected: 0...45), Watch("iam", expected: 1...1)],
                           tips: [
                               Tip(urgent: true, when: { ($0["fbkc"] ?? 0) <= -4 }) { r in "Heavy knock (\(fmt(r["fbkc"], 1))°). Ease off now." },
                               Tip(when: { let th = $0["throttle"] ?? 0; return th > 10 && th < 50 && ($0["rpm"] ?? 0) > 1500 }) { r in
                                   "Press further: about three quarters throttle (now \(fmt(r["throttle"], 0)) %)."
                               },
                               Tip(when: { ($0["rpm"] ?? 0) > 5000 }, "That's high enough: ease off and start the next roll-on from 2,000 rpm."),
                               Tip(when: { ($0["throttle"] ?? 0) <= 10 && ($0["rpm"] ?? 0) > 1000 }, "Next roll-on: 4th gear, about 2,000 rpm, then three-quarter throttle."),
                           ],
                           demo: .rollOn),
                pullStep(title: "Full-throttle pull (optional)"),
                cruiseStep(title: "Cruise to finish", seconds: 20, speed: 30...130,
                           instruction: "Cruise normally for a moment. Skipped the pull? That's fine, SubieScope still has enough data.")],
        lookFor: ["How often the ECU pulls timing because of knock (feedback knock correction)",
                  "How deep the corrections go: up to −1.4° now and then is normal, −2.8° or more is a problem",
                  "At which rpm and load it happens",
                  "Whether the ECU has learned to pull timing (fine learning correction and IAM)",
                  "Hot intake air, a lean mixture or a hot engine at the moment of knock"],
        headlines: (pass: "No worrying knock: your engine runs clean.",
                    warning: "Some knock: worth finding the cause.",
                    fail: "Serious knock: drive gently until it's sorted."),
        analyze: { a in
            Checks.warmUp(a) + Checks.knockReport(Checks.warmRows(a))
        })

    static let avcs = Recipe(
        id: "avcs", setting: .driving, title: "AVCS (variable valve timing)", symbol: "gearshape.2",
        category: "Engine",
        summary: "Checks that the variable cam timing moves with engine load and that the left and right banks agree, for both intake and exhaust cams where the ECU reports them.",
        symptoms: ["P0011/P0021 (intake cam timing)", "P0014/P0024 (exhaust cam timing)", "Rough idle", "Lazy low-end response"],
        conditions: ["Engine fully warm", "Oil level correct (AVCS runs on oil pressure)"],
        safety: roadSafety,
        minutes: 6,
        probes: [P.rpm, P.coolant, P.avcsInR, P.avcsInL, opt(P.avcsExR), opt(P.avcsExL), opt(P.ocvR), opt(P.ocvL), opt(P.throttle), opt(P.speed), opt(P.load)],
        steps: [warmUpStep(), idleStep(seconds: 20),
                cruiseStep(title: "Steady cruise", seconds: 45, speed: 40...120),
                RecipeStep("Accelerate through the gears",
                           "Accelerate briskly (about half throttle or more) through 2nd and 3rd gear, from 2,000 to 5,000 rpm. Do this three times.",
                           goal: .collect(seconds: 20, whenever: Condition("Accelerating above 2,000 rpm") { ($0["throttle"] ?? 0) > 30 && ($0["rpm"] ?? 0) > 2000 }),
                           watch: [Watch("avcsInR"), Watch("avcsInL"), Watch("avcsExR"), Watch("avcsExL"), Watch("rpm")],
                           tips: [Tip(when: { ($0["throttle"] ?? 0) <= 30 && ($0["rpm"] ?? 0) > 1000 }, "Accelerate harder: at least half throttle.")],
                           demo: .wotPull)],
        lookFor: ["Near zero at idle, advancing clearly with load", "Left and right bank within about 3° of each other", "Both banks move together"],
        headlines: (pass: "Your AVCS works: the cams move and both banks agree.",
                    warning: "AVCS works, but the banks don't agree perfectly.",
                    fail: "AVCS is not working properly on at least one bank."),
        analyze: { a in
            let warm = Checks.warmRows(a)
            var f = Checks.warmUp(a)
            for (right, left, name) in [("avcsInR", "avcsInL", "Intake"), ("avcsExR", "avcsExL", "Exhaust")] {
                guard warm.has(right), warm.has(left) else { continue }
                let moving = warm.filter { ($0["rpm"] ?? 0) > 1500 }
                let spreadR = (Stats.percentile(moving.values(right), 0.95) ?? 0) - (Stats.percentile(warm.values(right), 0.05) ?? 0)
                let spreadL = (Stats.percentile(moving.values(left), 0.95) ?? 0) - (Stats.percentile(warm.values(left), 0.05) ?? 0)
                for (bank, spread) in [("right", spreadR), ("left", spreadL)] {
                    if spread < 5 {
                        f.append(Finding(.fail, "\(name) AVCS on the \(bank) bank hardly moves",
                                         "It should advance clearly when you accelerate. Common causes: a clogged oil filter screen at the AVCS solenoid (OCV), a failed OCV solenoid, low oil level or sludge.",
                                         measured: "range \(fmt(spread, 1))°"))
                    }
                }
                let diffs = moving.rows.compactMap { r -> Double? in
                    guard let x = r[right], let y = r[left] else { return nil }
                    return abs(x - y)
                }
                if let meanDiff = Stats.mean(diffs) {
                    let measured = "average difference \(fmt(meanDiff, 1))°, range right \(fmt(spreadR, 0))° / left \(fmt(spreadL, 0))°"
                    if meanDiff <= 3 {
                        if spreadR >= 5 && spreadL >= 5 {
                            f.append(Finding(.pass, "\(name) AVCS works and both banks agree", "", measured: measured))
                        }
                    } else {
                        f.append(Finding(meanDiff > 6 ? .fail : .warning, "\(name) AVCS banks disagree",
                                         "The two cylinder banks should follow the same target. A lagging bank points at that side's OCV solenoid or its filter screen.",
                                         measured: measured))
                    }
                }
                let idle = warm.filter { Checks.atIdle.test($0) }
                if let atIdle = idle.mean(right), let floor = Stats.percentile(warm.values(right), 0.05), atIdle - floor > 8 {
                    f.append(Finding(.warning, "\(name) AVCS stays advanced at idle",
                                     "Cams advanced at idle cause a rough idle. Check the OCV solenoid on that side.", measured: fmt(atIdle, 1, "°")))
                }
            }
            if f.allSatisfy({ $0.severity == .info || $0.title.contains("warm") }) && !warm.has("avcsInR") {
                f.append(Finding(.info, "AVCS angles not available", "This ECU does not report the cam angles."))
            }
            return f
        })

    static let fuelTrimsDriving = Recipe(
        id: "fuel-trims", setting: .driving, title: "Fuel trims while driving", symbol: "fuelpump",
        category: "Fuel & air",
        summary: "Measures the ECU's fuel corrections at idle and at several steady speeds. The pattern across airflow tells a vacuum leak apart from a dirty MAF or weak fuel supply.",
        symptoms: ["P0171/P0172 (lean/rich)", "Poor fuel economy", "Hesitation", "After an intake or MAF change"],
        conditions: ["Engine fully warm", "A route where you can hold 50, 80 and 100 km/h"],
        safety: roadSafety,
        minutes: 8,
        probes: [P.rpm, P.coolant, P.maf, P.afc, P.afl, opt(P.speed), opt(P.throttle), opt(P.lambda)],
        steps: [warmUpStep(), idleStep(seconds: 45),
                cruiseStep(title: "Cruise at 50 km/h", seconds: 30, speed: 40...60),
                cruiseStep(title: "Cruise at 80 km/h", seconds: 30, speed: 70...90),
                cruiseStep(title: "Cruise at 100 km/h", seconds: 30, speed: 90...115)],
        lookFor: ["Short + long term correction within ±8 % in every airflow range", "Lean only at idle: vacuum leak", "Lean everywhere: MAF or fuel supply", "Rich everywhere: MAF over-reading or leaking injector"],
        headlines: (pass: "Your fuel trims are healthy at every airflow.",
                    warning: "The fuel trims are off somewhere: see the pattern below.",
                    fail: "The ECU corrects the fuel a lot: there is an air or fuel problem."),
        analyze: { a in
            let warm = Checks.warmRows(a).filter { ($0["throttle"] ?? 0) < 60 }
            let closedLoop = warm.has("lambda") ? warm.filter { ($0["lambda"] ?? 1) > 0.9 && ($0["lambda"] ?? 1) < 1.1 } : warm
            let idle = closedLoop.filter { Checks.atIdle.test($0) }
            let bins: [(String, ClosedRange<Double>)] = [("light load (6–20 g/s)", 6...20), ("cruise (20–45 g/s)", 20...45), ("higher load (45+ g/s)", 45...1000)]
            var f = Checks.warmUp(a)
            var cruise: Double?
            for (name, range) in bins {
                let rows = closedLoop.filter { r in (r["maf"].map { range.contains($0) } ?? false) && !Checks.atIdle.test(r) }
                guard rows.count >= 5, let t = Checks.totalTrim(rows) else { continue }
                if range.lowerBound == 20 || cruise == nil { cruise = t }
                f.append(Finding(.info, "Correction at \(name)", "", measured: signed(t, 1, "%")))
            }
            f += Checks.trimPattern(idle: Checks.totalTrim(idle), higher: cruise, higherLabel: "cruise")
            return f
        })

    static let catalyst = Recipe(
        id: "catalyst", setting: .driving, title: "Catalyst efficiency (P0420)", symbol: "leaf",
        category: "Emissions",
        summary: "At a steady cruise, a healthy catalyst keeps the rear O2 sensor steady. If the rear sensor switches like the front one, the catalyst is worn and P0420 follows.",
        symptoms: ["P0420", "Rotten egg smell", "Before an emissions test", "After fitting a sports cat or down-pipe"],
        conditions: ["Engine and catalyst hot: drive at least 10 minutes first", "A road where you can cruise steadily for 3 minutes"],
        safety: roadSafety,
        minutes: 15,
        probes: [P.rpm, P.coolant, P.rearO2, opt(P.speed), opt(P.lambda), opt(P.throttle)],
        steps: [warmUpStep(extra: " Then drive for about 10 minutes so the catalyst gets hot."),
                cruiseStep(title: "Steady cruise", seconds: 180, speed: 70...120, instruction: "Cruise steadily at 70–120 km/h for about three minutes. Avoid accelerating hard or coasting.")],
        lookFor: ["The rear O2 sensor stays fairly steady around 0.5–0.8 V", "Few switches per minute compared with the front sensor"],
        headlines: (pass: "Your catalyst is working.",
                    warning: "Your catalyst may be getting tired.",
                    fail: "Your catalyst is not doing its job (this is what sets P0420)."),
        analyze: { a in
            let warm = Checks.warmRows(a)
            let steady = warm.filter { r in
                (r["speed"].map { $0 >= 60 } ?? ((r["rpm"] ?? 0) > 1800)) && (r["throttle"] ?? 0) < 40 && (r["throttle"] ?? 10) > 2
            }
            var f = Checks.warmUp(a)
            f += Checks.rearO2Alive(warm)
            if steady.duration < 60 {
                f.append(Finding(.info, "Not enough steady cruising", "Cruise steadily for at least a minute (three is better) for a reliable result.", measured: "\(fmt(steady.duration, 0)) s"))
            }
            f += Checks.catalyst(steady)
            return f
        })

    static let heatSoak = Recipe(
        id: "heat-soak", setting: .driving, title: "Intercooler heat soak", symbol: "thermometer.and.liquid.waves",
        category: "Performance",
        summary: "Measures how hot the intake air gets during and between pulls, and how fast it recovers. Hot intake air costs power and invites knock.",
        symptoms: ["Power fades after a few pulls or in traffic", "Knock on hot days", "After fitting a new intercooler"],
        conditions: ["Engine fully warm", "A closed road or track for the two pulls"],
        safety: "The pulls are only for a closed road, track or dyno.",
        minutes: 8,
        probes: [P.iat, P.coolant, P.rpm, P.throttle, opt(P.speed), opt(P.mrp), opt(P.timing), opt(P.fbkc)],
        steps: [warmUpStep(),
                cruiseStep(title: "Cruise", seconds: 45, speed: 40...120),
                pullStep(title: "First pull"),
                idleStep(seconds: 60, title: "Stop and idle", extra: " Pull over safely and let it idle for a minute (like waiting at a light)."),
                pullStep(title: "Second pull"),
                cruiseStep(title: "Cruise to cool down", seconds: 90, speed: 50...120)],
        lookFor: ["Intake air stays below about 50–55 °C", "It rises less than about 15 °C during a pull", "It comes back down within a few minutes of cruising"],
        headlines: (pass: "The intercooler copes well with heat.",
                    warning: "The intake air gets warm: some heat soak.",
                    fail: "Strong heat soak: expect power loss and knock risk when hot."),
        analyze: { a in
            let running = a.all.filter { ($0["rpm"] ?? 0) > 400 }
            guard let baseline = Stats.percentile(running.values("iat"), 0.05), let peak = running.max("iat") else {
                return [Finding(.info, "No intake air data", "")]
            }
            var f = Checks.warmUp(a)
            f.append(Finding(peak > 65 ? .fail : (peak > 55 ? .warning : .pass), peak > 55 ? "Intake air gets hot" : "Intake air stays cool",
                             peak > 55 ? "Hot intake air lowers power and the ECU pulls timing to prevent knock. Top-mount intercoolers soak heat at low speed; drive before pulling, and check the intercooler shroud and scoop." : "",
                             measured: "max \(fmt(peak, 0)) °C, coolest \(fmt(baseline, 0)) °C"))
            for (i, pull) in running.segments(minDuration: 1.5, gap: 1.0, where: { Checks.wot.test($0) }).enumerated() {
                guard let start = pull.rows.first?["iat"], let hi = pull.max("iat") else { continue }
                let rise = hi - start
                f.append(Finding(rise > 15 ? .warning : .info, "Pull \(i + 1): intake air \(rise > 15 ? "rose a lot" : "rise")",
                                 rise > 15 ? "The intercooler can't shed the heat fast enough during a pull." : "",
                                 measured: "\(fmt(start, 0)) → \(fmt(hi, 0)) °C"))
            }
            let idleSoak = running.filter { Checks.atIdle.test($0) }.max("iat").map { $0 - baseline }
            if let soak = idleSoak, soak > 20 {
                f.append(Finding(.warning, "Heat soak while idling", "Standing still heats the intercooler; the next pull starts hot. Normal for top-mount intercoolers, but worth knowing.",
                                 measured: "+\(fmt(soak, 0)) °C above the coolest reading"))
            }
            return f
        })

    static let throttleResponse = Recipe(
        id: "throttle-response", setting: .driving, title: "Throttle response & hesitation", symbol: "speedometer",
        category: "Performance",
        summary: "Checks how quickly the electronic throttle follows your foot, and whether the mixture briefly goes lean when you press the pedal (a common cause of hesitation).",
        symptoms: ["Hesitation or flat spot when pressing the pedal", "Jerky response", "Delay between pedal and power"],
        conditions: ["Engine fully warm", "SI-Drive in S or S# mode (I mode deliberately softens the throttle)"],
        safety: roadSafety,
        minutes: 4,
        probes: [P.pedal, P.throttle, P.rpm, P.coolant, opt(P.lambda), opt(P.mrp), opt(P.speed)],
        steps: [warmUpStep(),
                RecipeStep("Quick pedal presses",
                           "In 3rd or 4th gear at 2,000–2,500 rpm, quickly press the pedal about halfway, hold it for two seconds, then release. Repeat four times.",
                           goal: .collect(seconds: 30, whenever: Checks.running),
                           watch: [Watch("pedal"), Watch("throttle"), Watch("lambda", expected: 0.8...1.05)],
                           demo: .revAndRelease)],
        lookFor: ["The throttle follows the pedal within about a quarter of a second", "No lean spike (λ above about 1.05) right after pressing the pedal"],
        headlines: (pass: "Throttle response is crisp.",
                    warning: "Throttle response is a bit soft or the mixture dips lean on tip-in.",
                    fail: "There is a clear hesitation problem."),
        analyze: { a in
            let rows = a.all.filter { ($0["rpm"] ?? 0) > 400 }.rows
            var lags: [Double] = []
            var leanSpikes: [Double] = []
            var i = 1
            while i < rows.count {
                guard let p0 = rows[i - 1]["pedal"] else { i += 1; continue }
                // A tip-in: the pedal rises 20 % or more within half a second.
                if let j = rows[i...].prefix(while: { $0.t - rows[i - 1].t <= 0.5 }).firstIndex(where: { ($0["pedal"] ?? 0) - p0 >= 20 }) {
                    // Measure from the last sample before the pedal moved.
                    let start = rows[j - 1]
                    let th0 = start["throttle"] ?? 0
                    let pressed = start["pedal"] ?? p0
                    // Only while the pedal stays pressed: releasing it cuts fuel, which is not a tip-in problem.
                    let window = rows[j...].prefix(while: { $0.t - start.t <= 1.5 && ($0["pedal"] ?? 0) >= pressed + 10 })
                    if let thMax = window.compactMap({ $0["throttle"] }).max(), thMax - th0 > 5,
                       let reached = window.first(where: { ($0["throttle"] ?? 0) >= th0 + 0.8 * (thMax - th0) }) {
                        lags.append(reached.t - start.t)
                    }
                    if let lean = window.prefix(while: { $0.t - start.t <= 1.0 }).compactMap({ $0["lambda"] }).max() { leanSpikes.append(lean) }
                    i = j + max(1, window.count)
                    continue
                }
                i += 1
            }
            var f = Checks.warmUp(a)
            guard !lags.isEmpty else {
                return f + [Finding(.info, "No quick pedal presses found", "Press the pedal quickly (about halfway within half a second) a few times.")]
            }
            let worst = lags.max()!
            f.append(worst <= 0.25
                ? Finding(.pass, "Throttle follows the pedal quickly", "", measured: "slowest \(fmt(worst, 2)) s over \(lags.count) presses")
                : Finding(.warning, "Throttle opens slowly",
                          "In SI-Drive I mode this is deliberate. In S/S# it can be a dirty throttle body or the throttle mapping of the tune.",
                          measured: "slowest \(fmt(worst, 2)) s over \(lags.count) presses"))
            if let lean = leanSpikes.max() {
                f.append(lean > 1.05
                    ? Finding(.warning, "Mixture dips lean when pressing the pedal",
                              "A brief lean spike on tip-in feels like a hesitation. Causes: vacuum or boost leak, weak fuel pressure, or tip-in enrichment in the tune.",
                              measured: "up to λ \(fmt(lean, 2))")
                    : Finding(.pass, "No lean dip on tip-in", "", measured: "max λ \(fmt(lean, 2))"))
            }
            return f
        })

    static let misfireDriving = Recipe(
        id: "misfire", setting: .driving, title: "Misfire hunt under load", symbol: "bolt.trianglebadge.exclamationmark",
        category: "Engine",
        summary: "Counts misfires per cylinder at idle, while cruising and while accelerating, so you know which cylinder and under which conditions. Misfires under load often point at coils or plugs.",
        symptoms: ["Stutter or jerk under acceleration", "Flashing check engine light", "P0300–P0304"],
        conditions: ["Engine fully warm"],
        safety: roadSafety,
        minutes: 6,
        probes: [P.rpm, P.coolant, P.rough1, P.rough2, P.rough3, P.rough4, opt(P.throttle), opt(P.speed), opt(P.lambda)],
        steps: [warmUpStep(), idleStep(seconds: 30),
                cruiseStep(title: "Cruise", seconds: 60, speed: 40...120),
                RecipeStep("Accelerate under load",
                           "Accelerate firmly (half throttle or more) in 3rd or 4th gear from 2,000 rpm, a few times.",
                           goal: .collect(seconds: 20, whenever: Condition("Accelerating under load") { ($0["throttle"] ?? 0) > 40 && ($0["rpm"] ?? 0) > 1800 }),
                           watch: [Watch("rough1"), Watch("rough2"), Watch("rough3"), Watch("rough4")],
                           tips: [Tip(when: { ($0["throttle"] ?? 0) <= 40 && ($0["rpm"] ?? 0) > 1000 }, "Accelerate harder: at least half throttle.")],
                           demo: .wotPull)],
        lookFor: ["Which cylinder's counter goes up", "Whether it happens at idle, cruise or under load"],
        headlines: (pass: "No misfires found.",
                    warning: "A few misfire counts: keep an eye on it.",
                    fail: "A cylinder misfires: see which one and when."),
        analyze: { a in
            let warm = Checks.warmRows(a)
            var f = Checks.warmUp(a) + Checks.misfires(warm)
            let bands: [(String, (DataSet.Row) -> Bool)] = [
                ("at idle", { Checks.atIdle.test($0) }),
                ("cruising", { !Checks.atIdle.test($0) && ($0["throttle"] ?? 0) < 40 }),
                ("under load", { ($0["throttle"] ?? 0) >= 40 }),
            ]
            for (name, predicate) in bands {
                let part = warm.filter(predicate)
                let counts = Checks.cylinders.enumerated().compactMap { i, key in part.increase(key).map { (i + 1, $0) } }.filter { $0.1 > 0 }
                if !counts.isEmpty {
                    f.append(Finding(.info, "Misfire counts \(name)", "", measured: counts.map { "#\($0.0): \(Int($0.1))" }.joined(separator: ", ")))
                }
            }
            return f
        })
}
