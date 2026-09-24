import Foundation

/// All diagnostic recipes. Each analysis works on the recorded data itself
/// (idle rows, 2,500 rpm rows, full-throttle rows...), so it can also be run on
/// any older log that contains the right values.
public enum RecipeCatalog {
    public static let all: [Recipe] = [
        frontAF, rearO2, maf, idle, charging, pedal, coldSensors, warmUp, cooling,
        pull, knock, avcs, fuelTrimsDriving, catalyst, heatSoak, throttleResponse, misfireDriving,
    ]

    public static func recipe(id: String) -> Recipe? { all.first { $0.id == id } }

    typealias P = Probes
    static func opt(_ p: Probe) -> Probe { Probes.optional(p) }

    // MARK: - Shared steps

    static func warmUpStep(extra: String = "") -> RecipeStep {
        RecipeStep(
            "Warm up the engine",
            "Start the engine and let it warm up. Driving gently gets there faster than idling. SubieScope continues by itself once the coolant reaches 75 °C.\(extra)",
            goal: .until(Checks.warm, timeout: 1500),
            watch: [Watch("coolant", expected: 75...105), Watch("rpm")],
            tips: [
                Tip(when: { ($0["rpm"] ?? 0) < 400 }, "Start the engine."),
                Tip(when: { ($0["rpm"] ?? 0) >= 400 && ($0["coolant"] ?? 0) < 75 }) { r in
                    "Warming up: \(fmt(r["coolant"], 0)) °C of 75 °C. Already warm from driving? Then this step finishes in a moment."
                },
            ],
            demo: .warmUp)
    }

    static func idleStep(seconds: Double, title: String = "Idle", extra: String = "") -> RecipeStep {
        RecipeStep(
            title,
            "Let the engine idle in neutral with your foot off the pedal. Switch off the A/C, lights and blower.\(extra)",
            goal: .collect(seconds: seconds, whenever: Checks.atIdle),
            watch: [Watch("rpm", expected: 600...1000), Watch("lambda", expected: 0.95...1.05), Watch("afc", expected: -10...10),
                    Watch("afl", expected: -10...10), Watch("maf")],
            tips: [
                Tip(when: { ($0["rpm"] ?? 0) >= 1200 }, "Take your foot off the pedal and let it idle."),
                Tip(when: { ($0["rpm"] ?? 0) < 400 }, "The engine is off. Start it again."),
            ],
            demo: .idle)
    }

    static func hold2500Step(seconds: Double) -> RecipeStep {
        RecipeStep(
            "Hold 2,500 rpm",
            "In neutral, press the pedal gently and hold the engine at about 2,500 rpm, as steady as you can.",
            goal: .hold(seconds: seconds, Checks.rpm(2200, 2900)),
            watch: [Watch("rpm", expected: 2200...2900), Watch("lambda", expected: 0.95...1.05), Watch("maf"), Watch("rearO2")],
            tips: [
                Tip(when: { ($0["rpm"] ?? 0) < 1200 && ($0["rpm"] ?? 0) > 400 }, "Press the pedal to raise the engine to about 2,500 rpm."),
                Tip(when: { let r = $0["rpm"] ?? 0; return r >= 1200 && r < 2200 }) { r in "A little more: \(fmt(r["rpm"], 0)) rpm, aim for 2,500." },
                Tip(when: { ($0["rpm"] ?? 0) > 2900 }) { r in "Ease off slightly: \(fmt(r["rpm"], 0)) rpm, aim for 2,500." },
            ],
            demo: .hold2500)
    }

    static func revReleaseStep(seconds: Double) -> RecipeStep {
        RecipeStep(
            "Rev and let go",
            "In neutral, blip the throttle quickly to about 4,000 rpm and then let go of the pedal completely. Wait until it is back at idle and repeat, three times in total.",
            goal: .collect(seconds: seconds, whenever: Checks.running),
            watch: [Watch("rpm"), Watch("lambda"), Watch("rearO2")],
            tips: [
                Tip(when: { let r = $0["rpm"] ?? 0; let th = $0["throttle"] ?? 0; return th > 5 && r < 3000 }, "Keep going: rev to about 4,000 rpm, then let go completely."),
                Tip(when: { ($0["rpm"] ?? 0) > 5000 }, "That's high enough: about 4,000 rpm is plenty."),
            ],
            demo: .revAndRelease)
    }

    static func pullStep(title: String = "Full-throttle pull") -> RecipeStep {
        RecipeStep(
            title,
            "In 3rd gear at about 2,500 rpm, press the throttle to the floor and hold it until about 6,500 rpm, then lift off. Only where it is safe and legal.",
            goal: .until(Condition("Full throttle past 6,000 rpm") { ($0["rpm"] ?? 0) >= 6000 && ($0["throttle"] ?? 0) >= 85 }, timeout: 300),
            watch: [Watch("rpm"), Watch("mrp"), Watch("lambda", expected: 0.72...0.85), Watch("fbkc", expected: -1.41...0), Watch("iam", expected: 1...1)],
            tips: [
                Tip(urgent: true, when: { ($0["throttle"] ?? 0) > 85 && ($0["mrp"] ?? 0) > 40 && ($0["lambda"] ?? 0) > 0.88 }) { r in
                    "Running lean (λ \(fmt(r["lambda"], 2))). Lift off now."
                },
                Tip(urgent: true, when: { ($0["fbkc"] ?? 0) <= -4 }) { r in "Heavy knock (\(fmt(r["fbkc"], 1))°). Lift off now." },
                Tip(when: { let th = $0["throttle"] ?? 0; return th > 30 && th < 85 && ($0["rpm"] ?? 0) > 2500 }) { r in
                    "Press the pedal all the way down: throttle is only \(fmt(r["throttle"], 0)) %."
                },
                Tip(when: { ($0["throttle"] ?? 0) < 30 && ($0["rpm"] ?? 0) > 1500 }, "When you're ready: 3rd gear, about 2,500 rpm, then floor it."),
            ],
            demo: .wotPull)
    }

    static func cruiseStep(title: String, seconds: Double, speed: ClosedRange<Double>, instruction: String? = nil) -> RecipeStep {
        let condition = Condition("Steady \(Int(speed.lowerBound))–\(Int(speed.upperBound)) km/h") { r in
            guard let v = r["speed"] else { return (r["rpm"] ?? 0) > 1500 }
            return speed.contains(v) && (r["throttle"] ?? 0) < 45
        }
        return RecipeStep(
            title,
            instruction ?? "Drive at a steady \(Int(speed.lowerBound))–\(Int(speed.upperBound)) km/h in the highest comfortable gear. Keep the throttle steady.",
            goal: .collect(seconds: seconds, whenever: condition),
            watch: [Watch("speed", expected: speed), Watch("rpm"), Watch("afc", expected: -10...10), Watch("afl", expected: -10...10)],
            tips: [
                Tip(when: { r in (r["speed"].map { $0 < speed.lowerBound } ?? false) }) { r in "Speed up a little: \(fmt(r["speed"], 0)) km/h." },
                Tip(when: { r in (r["speed"].map { $0 > speed.upperBound } ?? false) }) { r in "A bit slower: \(fmt(r["speed"], 0)) km/h." },
                Tip(when: { ($0["throttle"] ?? 0) >= 45 }, "Ease off: keep a light, steady throttle."),
            ],
            demo: .cruise)
    }

    // MARK: - In the garage

    static let frontAF = Recipe(
        id: "front-af", setting: .parked, title: "Front A/F sensor", symbol: "sensor.tag.radiowaves.forward",
        category: "Sensors",
        summary: "Checks the wideband air/fuel sensor before the catalyst (the upstream O2 sensor): that it reads correctly, keeps moving, reacts quickly, and that the ECU's fuel corrections are normal.",
        symptoms: ["Check engine light with P0130–P0134 or P0031/P0032", "Poor fuel economy", "Hunting or rough idle", "Fuel smell from the exhaust"],
        conditions: ["Car parked, handbrake on, gearbox in neutral", "A/C, lights and blower off", "The engine may be cold: the test warms it up first"],
        minutes: 5,
        probes: [P.rpm, P.coolant, P.lambda, opt(P.afc), opt(P.afl), opt(P.throttle), opt(P.afHeater)],
        steps: [warmUpStep(), idleStep(seconds: 30), hold2500Step(seconds: 20), revReleaseStep(seconds: 15)],
        lookFor: ["Warm idle should average λ 1.00 (AFR 14.7)",
                  "The reading keeps moving: a dead sensor draws a flat line",
                  "Letting go of the throttle cuts fuel: the sensor should read very lean within about a second",
                  "Fuel corrections within ±8 %"],
        headlines: (pass: "Your front A/F sensor looks healthy.",
                    warning: "Your front A/F sensor works, but something deserves a closer look.",
                    fail: "Your front A/F sensor, or its wiring or heater, is probably faulty."),
        analyze: { a in
            let warm = Checks.warmRows(a)
            let idle = warm.filter { Checks.atIdle.test($0) }
            let steady = warm.filter { Checks.rpm(2200, 2900).test($0) && ($0["throttle"] ?? 0) < 30 }
            var f = Checks.warmUp(a)
            f += Checks.frontSensorActivity(warm)
            f += Checks.idleLambda(idle)
            f += Checks.frontSensorResponse(warm)
            // Trims say more about air/fuel delivery than about the sensor: cap them at a warning here.
            f += Checks.trimPattern(idle: Checks.totalTrim(idle), higher: steady.isEmpty ? nil : Checks.totalTrim(steady), higherLabel: "2,500 rpm")
                .map { var x = $0; if x.severity == .fail { x.severity = .warning }; x.detail += " Run the Mass airflow sensor (MAF) test to dig deeper."; return x }
            f += Checks.heater(warm, key: "afHeater", name: "A/F sensor")
            return f
        })

    static let rearO2 = Recipe(
        id: "rear-o2", setting: .parked, title: "Rear O2 sensor & catalyst", symbol: "aqi.medium",
        category: "Sensors",
        summary: "Checks the downstream O2 sensor behind the catalyst, and whether the catalyst is still storing oxygen.",
        symptoms: ["P0420 (catalyst efficiency)", "P0136–P0141 (rear O2 sensor or heater)", "Failed emissions test"],
        conditions: ["Catalyst hot: ideally drive 10 minutes first", "Car parked, handbrake on, in neutral"],
        minutes: 5,
        probes: [P.rpm, P.coolant, P.rearO2, opt(P.lambda), opt(P.throttle), opt(P.rearHeater)],
        steps: [warmUpStep(extra: " Best after a 10-minute drive so the catalyst is hot."), hold2500Step(seconds: 30), revReleaseStep(seconds: 15),
                idleStep(seconds: 20)],
        lookFor: ["At a steady 2,500 rpm the rear sensor sits steady around 0.5–0.8 V behind a good catalyst",
                  "A rear sensor that switches up and down like the front one means the catalyst no longer stores oxygen",
                  "On over-run it should drop below 0.2 V, when rich rise above 0.6 V"],
        headlines: (pass: "Your rear O2 sensor works and the catalyst is doing its job.",
                    warning: "The rear O2 sensor works, but the catalyst or the sensor may be aging.",
                    fail: "The rear O2 sensor or the catalyst has a problem."),
        analyze: { a in
            let warm = Checks.warmRows(a)
            let steady = warm.filter { Checks.rpm(2000, 3200).test($0) && ($0["throttle"] ?? 0) < 30 }
            var f = Checks.warmUp(a)
            f += Checks.rearO2Alive(warm)
            f += Checks.catalyst(steady)
            f += Checks.rearO2Response(warm)
            f += Checks.heater(warm, key: "rearHeater", name: "Rear O2")
            return f
        })

    static let maf = Recipe(
        id: "maf", setting: .parked, title: "Mass airflow sensor (MAF)", symbol: "wind",
        category: "Sensors",
        summary: "Checks that the MAF reads plausible airflow, responds to engine speed, agrees with manifold pressure, and reads the fuel trims to tell a dirty MAF apart from a vacuum leak.",
        symptoms: ["P0101–P0103 (MAF)", "P0171/P0172 (lean/rich)", "Hesitation or stalling", "Rough idle after an intake change"],
        conditions: ["Car parked, handbrake on, in neutral", "A/C, lights and blower off"],
        minutes: 4,
        probes: [P.rpm, P.coolant, P.maf, opt(P.mafV), opt(P.afc), opt(P.afl), opt(P.map), opt(P.iat), opt(P.throttle)],
        steps: [warmUpStep(), idleStep(seconds: 30), hold2500Step(seconds: 30)],
        lookFor: ["Warm idle airflow of roughly 1–3 g/s per litre of engine size",
                  "Airflow at 2,500 rpm about 2.5–4 times idle",
                  "MAF and manifold pressure tell the same story at idle and 2,500 rpm",
                  "Fuel trims: lean only at idle points to a vacuum leak, lean everywhere to the MAF or fuel supply"],
        headlines: (pass: "Your MAF sensor reads plausibly and the fuel trims are normal.",
                    warning: "Your MAF sensor works, but its readings or the fuel trims are a bit off.",
                    fail: "Your MAF sensor or the intake has a problem."),
        analyze: { a in
            let warm = Checks.warmRows(a)
            let idle = warm.filter { Checks.atIdle.test($0) }
            let steady = warm.filter { Checks.rpm(2200, 2900).test($0) && ($0["throttle"] ?? 0) < 30 }
            var f = Checks.warmUp(a)
            f += Checks.mafIdle(idle, context: a.context)
            if !steady.isEmpty {
                f += Checks.mafScaling(idle: idle, higher: steady)
                f += Checks.mafVersusPressure(idle: idle, higher: steady, context: a.context)
            }
            f += Checks.trimPattern(idle: Checks.totalTrim(idle), higher: steady.isEmpty ? nil : Checks.totalTrim(steady), higherLabel: "2,500 rpm")
            return f
        })

    static let idle = Recipe(
        id: "idle", setting: .parked, title: "Idle quality & misfires", symbol: "waveform.path",
        category: "Engine",
        summary: "Measures how steady the idle is, counts misfires per cylinder and checks the idle fuel trims, first without and then with electrical load.",
        symptoms: ["Shaking at idle", "P0300–P0304 (misfire)", "Idle hunts or dips", "Stalling when coming to a stop"],
        conditions: ["Car parked, handbrake on, in neutral"],
        minutes: 4,
        probes: [P.rpm, P.coolant, opt(P.rough1), opt(P.rough2), opt(P.rough3), opt(P.rough4), opt(P.afc), opt(P.afl), opt(P.isc), opt(P.battery), opt(P.lambda)],
        steps: [warmUpStep(), idleStep(seconds: 60, title: "Idle for a minute", extra: " Don't touch anything for a minute."),
                RecipeStep("Idle with load", "Now switch on the A/C (if fitted), the headlights and the blower on full. The idle should stay steady.",
                           goal: .collect(seconds: 20, whenever: Checks.atIdle),
                           watch: [Watch("rpm", expected: 600...1050), Watch("battery", expected: 13.0...14.9)],
                           demo: .idleWithLoads)],
        lookFor: ["Engine speed varies less than about ±20 rpm", "No misfire counts adding up on one cylinder", "No sudden dips", "Fuel trims at idle within ±8 %"],
        headlines: (pass: "Your engine idles smoothly with no misfires.",
                    warning: "The idle is mostly fine, with something worth watching.",
                    fail: "The idle is not right: see what SubieScope found."),
        analyze: { a in
            let idle = Checks.warmRows(a).filter { Checks.atIdle.test($0) }
            var f = Checks.warmUp(a)
            f += Checks.idleStability(idle)
            f += Checks.misfires(idle)
            if idle.has("afc") || idle.has("afl") {
                f += Checks.trimPattern(idle: Checks.totalTrim(idle), higher: nil, higherLabel: "")
            }
            return f
        })

    static let charging = Recipe(
        id: "charging", setting: .parked, title: "Battery & charging", symbol: "minus.plus.batteryblock",
        category: "Electrical",
        summary: "Checks the battery's state of charge and whether the alternator charges properly, also with lights and blower on.",
        symptoms: ["Slow cranking", "Dim lights at idle", "Battery warning light", "Random electrical faults"],
        conditions: ["Car parked", "Start with the ignition ON and the engine OFF"],
        minutes: 2,
        probes: [P.battery, P.rpm],
        steps: [
            RecipeStep("Ignition on, engine off", "Turn the key to ON without starting the engine.",
                       goal: .collect(seconds: 5, whenever: Checks.engineOff), watch: [Watch("battery", expected: 12.4...13.0)],
                       tips: [Tip(when: { ($0["rpm"] ?? 0) > 50 }, "Switch the engine off (keep the ignition ON) for this step.")],
                       demo: .engineOff),
            RecipeStep("Start the engine", "Start the engine and let it idle.",
                       goal: .hold(seconds: 10, Condition("Engine idling") { ($0["rpm"] ?? 0) > 500 }), watch: [Watch("battery", expected: 13.4...14.9)],
                       demo: .idle),
            RecipeStep("Switch on the loads", "Switch on the headlights (high beam), the blower on full and the rear window heater.",
                       goal: .collect(seconds: 15, whenever: Condition("Engine running") { ($0["rpm"] ?? 0) > 500 }),
                       watch: [Watch("battery", expected: 13.0...14.9)], demo: .idleWithLoads),
        ],
        lookFor: ["Engine off: 12.4 V or more", "Engine running: 13.4–14.9 V", "With loads on: still 13 V or more"],
        headlines: (pass: "Your battery and charging system are fine.",
                    warning: "The charging system works, but the battery or alternator deserves attention.",
                    fail: "The battery or the alternator has a problem."),
        analyze: { a in
            let off = a.steps.count == 3 ? a.step(0).filter { ($0["rpm"] ?? 0) < 50 } : a.all.filter { ($0["rpm"] ?? 0) < 50 }
            let running = a.steps.count == 3 ? a.step(1) : a.all.filter { ($0["rpm"] ?? 0) > 500 }
            var f: [Finding] = []
            f += off.isEmpty ? [Finding(.info, "Battery not measured with the engine off", "")] : Checks.batteryEngineOff(off)
            f += Checks.charging(running.filter { ($0["rpm"] ?? 0) > 500 }, loaded: false)
            if a.steps.count == 3 { f += Checks.charging(a.step(2).filter { ($0["rpm"] ?? 0) > 500 }, loaded: true) }
            return f
        })

    static let pedal = Recipe(
        id: "pedal", setting: .parked, title: "Accelerator pedal sensor", symbol: "pedal.accelerator",
        category: "Electrical",
        summary: "Checks the drive-by-wire pedal sensor: fully closed at rest, reaching full travel, and without dropouts along the way.",
        symptoms: ["Hesitation or surging at steady throttle", "Sudden loss of power (limp mode)", "P2122–P2138 (pedal sensor)"],
        conditions: ["Ignition ON, engine OFF", "Floor mat not in the way of the pedal"],
        minutes: 1,
        probes: [P.pedal, P.rpm, opt(P.throttle)],
        steps: [
            RecipeStep("Foot off the pedal", "Ignition ON, engine OFF. Keep your foot off the accelerator.",
                       goal: .collect(seconds: 3, whenever: Checks.engineOff), watch: [Watch("pedal", expected: 0...3)],
                       tips: [Tip(when: { ($0["rpm"] ?? 0) > 50 }, "Switch the engine off, leave the ignition ON.")],
                       demo: .engineOff),
            RecipeStep("Slowly press and release", "Slowly press the pedal all the way down (take about 5 seconds), then slowly let it come back up.",
                       goal: .collect(seconds: 12, whenever: Checks.engineOff), watch: [Watch("pedal"), Watch("throttle")],
                       demo: .pedalSweep),
        ],
        lookFor: ["0–3 % with the pedal released", "90 % or more with the pedal on the floor", "A smooth rise and fall without sudden jumps"],
        headlines: (pass: "Your accelerator pedal sensor works properly.",
                    warning: "The pedal sensor works, but not perfectly.",
                    fail: "The accelerator pedal sensor looks faulty."),
        analyze: { a in
            let off = a.all.filter { ($0["rpm"] ?? 0) < 50 }
            var f: [Finding] = []
            let rest = a.steps.count == 2 ? a.step(0) : off
            if let lo = rest.max("pedal") {
                f.append(lo <= 3 ? Finding(.pass, "Reads closed at rest", "", measured: fmt(lo, 1, "%"))
                              : Finding(lo <= 6 ? .warning : .fail, "Does not read fully closed at rest",
                                        "With the pedal released it should read 0–3 %. Check the floor mat and pedal, otherwise the sensor has an offset.",
                                        measured: fmt(lo, 1, "%")))
            }
            if let hi = off.max("pedal") {
                f.append(hi >= 90 ? Finding(.pass, "Reaches full travel", "", measured: fmt(hi, 0, "%"))
                              : Finding(hi >= 75 ? .warning : .fail, "Does not reach full travel",
                                        "Floored it should read 90 % or more. Check for a floor mat under the pedal; otherwise the sensor may be worn.",
                                        measured: fmt(hi, 0, "%")))
            }
            let v = off.values("pedal")
            var glitches: [Double] = []
            if v.count > 2 {
                for i in 1..<(v.count - 1) where (v[i] < v[i - 1] - 8 && v[i + 1] > v[i] + 8) || (v[i] > v[i - 1] + 8 && v[i + 1] < v[i] - 8) {
                    glitches.append(v[i - 1])
                }
            }
            if !glitches.isEmpty {
                f.append(Finding(.fail, "Signal dropouts while moving the pedal",
                                 "The reading jumped away and back at around \(fmt(glitches.first, 0, "%")). A worn track in the pedal sensor causes hesitation and can trigger limp mode. The pedal assembly is usually replaced as a unit.",
                                 measured: "\(glitches.count) dropout\(glitches.count == 1 ? "" : "s")"))
            } else if v.count > 10 {
                f.append(Finding(.pass, "Smooth signal along the whole travel", ""))
            }
            return f
        })

    static let coldSensors = Recipe(
        id: "cold-sensors", setting: .parked, title: "Temperature sensors (cold start)", symbol: "thermometer.medium",
        category: "Sensors",
        summary: "After the car has stood still for hours, the coolant and intake air sensors should read nearly the same. A big difference means one of them is wrong.",
        symptoms: ["Hard cold starts", "High idle or rich running when cold", "Temperature gauge acting strange", "P0111–P0118"],
        conditions: ["The car has been off for at least 6 hours (overnight is best)", "Ignition ON, engine OFF"],
        minutes: 1,
        probes: [P.coolant, P.iat, P.rpm],
        steps: [RecipeStep("Ignition on, engine off", "Turn the key to ON without starting the engine.",
                           goal: .collect(seconds: 5, whenever: Checks.engineOff), watch: [Watch("coolant"), Watch("iat")],
                           tips: [Tip(when: { ($0["rpm"] ?? 0) > 50 }, "This test needs the engine OFF and cold.")],
                           demo: .coldEngineOff)],
        lookFor: ["Coolant and intake air within 5 °C of each other on a cold engine", "No impossible values like −40 °C (open circuit)"],
        headlines: (pass: "Your temperature sensors agree.",
                    warning: "The temperature sensors disagree a little.",
                    fail: "One of the temperature sensors reads wrong."),
        analyze: { a in
            let off = a.all.filter { ($0["rpm"] ?? 0) < 50 }
            guard let c = off.mean("coolant"), let i = off.mean("iat") else {
                return [Finding(.info, "Not measured", "Run this with the ignition ON and the engine OFF.")]
            }
            var f: [Finding] = []
            for (name, v) in [("Coolant", c), ("Intake air", i)] where v <= -39 || v >= 140 {
                f.append(Finding(.fail, "\(name) sensor reads \(fmt(v, 0, "°C"))",
                                 v <= -39 ? "That is the value for an open circuit: check the connector and wiring (or the sensor)." : "That is the value for a short circuit: check the wiring.",
                                 measured: fmt(v, 0, "°C")))
            }
            let diff = abs(c - i)
            let measured = "coolant \(fmt(c, 0)) °C, intake \(fmt(i, 0)) °C"
            if c > 45 {
                f.append(Finding(.info, "Engine was not cold", "The coolant is still warm, so the sensors can't be compared. Repeat after the car has stood overnight.", measured: measured))
            } else if diff <= 5 {
                f.append(Finding(.pass, "Coolant and intake air sensors agree", "", measured: measured))
            } else {
                f.append(Finding(diff > 10 ? .fail : .warning, "Coolant and intake air sensors disagree",
                                 "On a cold engine both should read about the outside temperature. The one furthest from the outside temperature is suspect.",
                                 measured: measured))
            }
            return f
        })

    static let warmUp = Recipe(
        id: "warm-up", setting: .parked, title: "Warm-up & thermostat", symbol: "thermometer.sun",
        category: "Cooling",
        summary: "Follows the coolant temperature from a cold start to operating temperature, to spot a thermostat stuck open or an engine running too hot.",
        symptoms: ["Temperature gauge stays low", "Poor heater output", "Poor fuel economy in winter", "P0128 (coolant below thermostat temperature)"],
        conditions: ["Start with a cold engine (below 40 °C)", "You may idle or drive gently; driving is faster"],
        minutes: 15,
        probes: [P.coolant, P.rpm, opt(P.speed), opt(P.iat)],
        steps: [
            RecipeStep("Start and warm up", "Start the engine and idle or drive gently until it reaches operating temperature. SubieScope continues at 82 °C.",
                       goal: .until(Condition("Coolant 82 °C") { ($0["coolant"] ?? 0) >= 82 }, timeout: 1500),
                       watch: [Watch("coolant", expected: 80...100)],
                       tips: [Tip(when: { ($0["rpm"] ?? 0) < 400 }, "Start the engine.")], demo: .coldStart),
            RecipeStep("Keep it running", "Keep the engine running for two more minutes.",
                       goal: .collect(seconds: 120, whenever: Checks.running), watch: [Watch("coolant", expected: 80...100)], demo: .idle),
        ],
        lookFor: ["Coolant reaches about 85–95 °C and stays there", "Warm-up time (idling takes longer than driving)", "Never above 105 °C"],
        headlines: (pass: "The engine warms up normally and holds its temperature.",
                    warning: "Warm-up is a bit off: see the details.",
                    fail: "The cooling system has a problem."),
        analyze: { a in
            let running = a.all.filter { ($0["rpm"] ?? 0) > 400 }
            guard let first = running.rows.first?["coolant"], let peak = running.max("coolant") else {
                return [Finding(.info, "No data", "Start the engine for this test.")]
            }
            var f: [Finding] = []
            if first > 60 {
                f.append(Finding(.info, "Engine was already warm", "The warm-up time can't be judged; the running temperature still is.", measured: fmt(first, 0, "°C")))
            } else if let t82 = running.rows.first(where: { ($0["coolant"] ?? 0) >= 82 })?.t, let t0 = running.rows.first?.t {
                f.append(Finding(.info, "Warm-up time", "Idling takes 10–20 minutes, driving about 5–10.", measured: "\(fmt((t82 - t0) / 60, 1)) min from \(fmt(first, 0)) °C"))
            }
            if peak < 75 {
                f.append(Finding(.warning, "Never reached operating temperature",
                                 "The coolant stayed below 75 °C. A thermostat stuck open is the usual cause (P0128). Confirm on a longer drive: it should settle at 85–95 °C.",
                                 measured: "max \(fmt(peak, 0)) °C"))
            } else if peak > 105 {
                f.append(Finding(.fail, "Overheating", "Check the coolant level, the radiator fan, and for a head gasket leak (bubbles in the header tank, coolant loss).", measured: "max \(fmt(peak, 0)) °C"))
            } else if peak > 100 {
                f.append(Finding(.warning, "Runs hot", "Above 100 °C at idle: check the coolant level and whether the radiator fan switches on.", measured: "max \(fmt(peak, 0)) °C"))
            } else {
                f.append(Finding(.pass, "Operating temperature is normal", "", measured: "max \(fmt(peak, 0)) °C"))
            }
            return f
        })

    static let cooling = Recipe(
        id: "cooling", setting: .parked, title: "Overheating & radiator fan", symbol: "fan",
        category: "Cooling",
        summary: "Idles until the radiator fan should switch on and checks that it does, and that the temperature comes back down.",
        symptoms: ["Temperature rises in traffic", "Fan never seems to run", "Coolant boiling over after a drive"],
        conditions: ["Car parked in a ventilated place", "A/C off", "Takes up to 15 minutes of idling"],
        minutes: 15,
        probes: [P.coolant, P.rpm, opt(P.fan1), opt(P.fan2), opt(P.fanDuty)],
        steps: [warmUpStep(),
                RecipeStep("Idle until the fan runs", "Let it idle. The radiator fan should switch on at about 95–100 °C.",
                           goal: .until(Condition("Fan on or 103 °C") { r in (r["fan1"] ?? 0) > 0.5 || (r["fan2"] ?? 0) > 0.5 || (r["fanDuty"] ?? 0) > 20 || (r["coolant"] ?? 0) >= 103 }, timeout: 900),
                           watch: [Watch("coolant", expected: 80...102), Watch("fan1"), Watch("fanDuty")],
                           tips: [Tip(urgent: true, when: { ($0["coolant"] ?? 0) >= 106 }, "Too hot: switch the engine off and let it cool down.")],
                           demo: .idle),
                idleStep(seconds: 60, title: "Keep idling", extra: " Watch the temperature come back down while the fan runs.")],
        lookFor: ["The fan switches on before the coolant reaches about 102 °C", "The temperature drops again while the fan runs"],
        headlines: (pass: "The radiator fan works and the engine holds its temperature.",
                    warning: "Cooling works, but runs warmer than ideal.",
                    fail: "The engine overheats or the fan does not switch on."),
        analyze: { a in
            let running = a.all.filter { ($0["rpm"] ?? 0) > 400 }
            guard let peak = running.max("coolant") else { return [Finding(.info, "No data", "")] }
            var f: [Finding] = []
            let fanKnown = running.has("fan1") || running.has("fan2") || running.has("fanDuty")
            let fanOn = running.rows.first { ($0["fan1"] ?? 0) > 0.5 || ($0["fan2"] ?? 0) > 0.5 || ($0["fanDuty"] ?? 0) > 20 }
            if fanKnown {
                if let on = fanOn {
                    f.append(Finding(.pass, "Radiator fan switches on", "", measured: "at \(fmt(on["coolant"], 0)) °C"))
                } else if peak >= 100 {
                    f.append(Finding(.fail, "Fan did not switch on",
                                     "The coolant passed 100 °C without the fan running. Check the fan fuse and relays, the fan motor and its connector.",
                                     measured: "max \(fmt(peak, 0)) °C"))
                } else {
                    f.append(Finding(.info, "Fan did not need to run", "The coolant stayed below the switch-on temperature.", measured: "max \(fmt(peak, 0)) °C"))
                }
            } else {
                f.append(Finding(.info, "Fan status not available", "This ECU doesn't report the fan; watch or listen for it instead."))
            }
            if peak > 105 {
                f.append(Finding(.fail, "Overheating", "Check the coolant level, radiator (blocked fins), fan and for head gasket issues.", measured: "max \(fmt(peak, 0)) °C"))
            } else if peak > 102 {
                f.append(Finding(.warning, "Runs hot at idle", "It gets close to overheating before cooling down.", measured: "max \(fmt(peak, 0)) °C"))
            } else if let on = fanOn, let after = running.filter({ $0.t > on.t + 30 }).mean("coolant"), after < (on["coolant"] ?? 0) + 2 {
                f.append(Finding(.pass, "Temperature is kept under control", "", measured: "max \(fmt(peak, 0)) °C"))
            }
            return f
        })
}
