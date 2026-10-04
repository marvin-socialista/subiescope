import Foundation

/// Faults the demo car can simulate, to see how the recipes react.
public enum DemoFault: String, CaseIterable, Sendable, Identifiable {
    case none, dirtyMAF, vacuumLeak, deadFrontSensor, lazyFrontSensor, deadRearO2, failedCatalyst, stuckAVCS,
         weakAlternator, stuckThermostat, deadFan, mildKnock, knock, leanAtWOT, boostLeak, misfireCylinder3, wornPedal, badCoolantSensor

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: return "No fault (healthy car)"
        case .dirtyMAF: return "Dirty MAF sensor"
        case .vacuumLeak: return "Vacuum leak"
        case .deadFrontSensor: return "Dead front A/F sensor"
        case .lazyFrontSensor: return "Slow front A/F sensor"
        case .deadRearO2: return "Dead rear O2 sensor"
        case .failedCatalyst: return "Worn catalyst"
        case .stuckAVCS: return "Stuck AVCS (right intake)"
        case .weakAlternator: return "Weak alternator"
        case .stuckThermostat: return "Thermostat stuck open"
        case .deadFan: return "Radiator fan not working"
        case .mildKnock: return "Mild knock (small, frequent)"
        case .knock: return "Knock under load"
        case .leanAtWOT: return "Lean at full throttle"
        case .boostLeak: return "Boost leak"
        case .misfireCylinder3: return "Misfire on cylinder 3"
        case .wornPedal: return "Worn accelerator pedal sensor"
        case .badCoolantSensor: return "Coolant sensor reading high"
        }
    }
}

/// A virtual 2008 Impreza WRX STI (GRB, JDM, EJ207). Without a scenario it drives
/// a 45 second loop (idle, 2nd and 3rd gear pull with a small knock event,
/// lift-off, cruise). During a recipe the app sets a scenario per step so the
/// demo car "does" what the instructions say.
public final class DemoECU: @unchecked Sendable {
    public static let identity = ECUIdentity(
        systemID: [0xA2, 0x10, 0x0F],                  // 2.0L DOHC Turbo
        romID: [0x5A, 0x04, 0x78, 0x42, 0x07],          // JDM GRB, AZ1G301F
        capabilities: []
    )

    public let ecu: VirtualECU
    let memory: DemoMemory

    public static func make(definitions: LoggerDefinitions?) throws -> DemoECU {
        try DemoECU(definitions: definitions)
    }

    init(definitions: LoggerDefinitions?) throws {
        let memory = DemoMemory(definitions: definitions)
        self.memory = memory
        let id = Self.identity
        ecu = try VirtualECU(
            identity: .init(systemID: id.systemID, romID: id.romID, capabilities: memory.capabilities),
            memory: { memory.byte(at: $0) }
        )
        ecu.onWrite = { address, value in memory.write(address: address, value: value) }
    }

    public func stop() {
        ecu.stop()
    }

    /// The simulated engine behind the ECU, for a simulated gauge that sits in the same exhaust.
    public var world: DemoWorld { memory.world }

    /// What the demo car is doing; nil = the default drive loop.
    public func setScenario(_ scenario: DemoScenario?) { memory.world.setScenario(scenario) }
    public func setFault(_ fault: DemoFault) { memory.world.setFault(fault) }
}

// MARK: - The simulated engine

/// Produces engine values (keyed like `Probes`, in canonical units) over time.
public final class DemoWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var scenario: DemoScenario?
    private var scenarioStart: Double = 0
    private var fault: DemoFault = .none
    private var lastT: Double?

    // Slow state carried between samples
    private var coolant: Double = 88
    private var fanOn = false
    private var lambdaSensor: Double = 1.0
    private var exhaust: Double = 1.0
    private var rearO2: Double = 0.65
    private var rough: [Double] = [0, 0, 0, 0]
    private var knockEvents = 0.0

    public init(fault: DemoFault = .none) {
        self.fault = fault
    }

    public func setScenario(_ s: DemoScenario?) {
        lock.lock(); defer { lock.unlock() }
        guard s != scenario else { return }
        scenario = s
        scenarioStart = lastT ?? 0
        if s == .coldEngineOff { coolant = fault == .badCoolantSensor ? 36 : 14 }
        // A warm-up step on an engine that is already warm just finishes; only a cold start resets.
        if s == .coldStart { coolant = 18 }
    }

    public func setFault(_ f: DemoFault) {
        lock.lock(); defer { lock.unlock() }
        fault = f
    }

    public var currentFault: DemoFault {
        lock.lock(); defer { lock.unlock() }
        return fault
    }

    /// The mixture in the exhaust at the last sample, as lambda: what a separate wideband gauge reads,
    /// whatever the car's own front sensor reports.
    public var exhaustLambda: Double {
        lock.lock(); defer { lock.unlock() }
        return exhaust
    }

    /// Engine state at time `t` (seconds, monotonic).
    public func sample(at t: Double) -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        let dt = lastT.map { Swift.max(0, Swift.min(0.5, t - $0)) } ?? 0
        lastT = t
        let tau = t - scenarioStart
        var s = scenario.map { Self.scenarioState($0, tau: tau, fault: fault) } ?? Self.loopState(t: t)
        applyFaultsAndDynamics(&s, t: t, dt: dt)
        return s.values
    }

    struct State {
        var running = true
        var rpm = 850.0, speed = 0.0, throttle = 1.2, pedal = 0.0
        var boost = -66.0, target = -66.0, gear = 0.0
        var mixture = 1.0          // actual lambda the engine burns
        var fuelCut = false
        var loads = false
        var wotKnockZone = false
        var values: [String: Double] = [:]
    }

    private static func lerp(_ a: Double, _ b: Double, _ f: Double) -> Double { a + (b - a) * Swift.min(1, Swift.max(0, f)) }
    private static let ratios = [0, 3.636, 2.375, 1.761, 1.346, 1.062, 0.842]
    private static func speedFor(_ rpm: Double, _ gear: Int) -> Double { rpm / (ratios[gear] * 3.9) * 2.0 * 60 / 1000 }

    /// The default 45 s loop shown on the dashboard.
    static func loopState(t rawT: Double) -> State {
        var s = State()
        let t = rawT.truncatingRemainder(dividingBy: 45)
        let wobble = sin(rawT * 7.3) * 0.5 + sin(rawT * 2.1) * 0.5
        switch t {
        case ..<6:
            s.rpm = 850 + wobble * 15
        case ..<14:
            let f = (t - 6) / 8
            s.gear = 2; s.rpm = lerp(2600, 7100, f); s.throttle = 100; s.pedal = 100
            s.speed = speedFor(s.rpm, 2)
            s.target = s.rpm < 3600 ? lerp(10, 125, (s.rpm - 2600) / 1000) : (s.rpm < 6000 ? 125 : lerp(125, 100, (s.rpm - 6000) / 1100))
            s.boost = Swift.min(s.target, lerp(-10, 128, (s.rpm - 2600) / 1300)) + wobble * 2
            s.mixture = s.boost > 60 ? 0.78 : 0.9
            s.wotKnockZone = t > 10.8 && t < 11.5
        case ..<15:
            s.gear = 2; s.rpm = lerp(7100, 5000, t - 14); s.speed = speedFor(7100, 2); s.throttle = 0; s.boost = 20; s.target = 20
            s.fuelCut = true
        case ..<19:
            let f = (t - 15) / 4
            s.gear = 3; s.rpm = lerp(5000, 6900, f); s.throttle = 100; s.pedal = 100; s.speed = speedFor(s.rpm, 3)
            s.target = lerp(125, 105, f); s.boost = s.target + 3 + wobble * 2; s.mixture = 0.79
        case ..<23:
            let f = (t - 19) / 4
            s.gear = 3; s.rpm = lerp(6900, 2800, f); s.speed = speedFor(s.rpm, 3); s.throttle = 0
            s.boost = lerp(40, -72, f * 3); s.target = s.boost; s.fuelCut = true
        case ..<38:
            s.gear = 5; s.rpm = 2750 + wobble * 30; s.speed = speedFor(s.rpm, 5); s.throttle = 17 + wobble; s.pedal = 15 + wobble
            s.boost = -38 + wobble * 3; s.target = s.boost
        default:
            let f = (t - 38) / 7
            s.gear = f < 0.8 ? 5 : 0
            s.rpm = f < 0.8 ? lerp(2700, 1100, f / 0.8) : lerp(1100, 850, (f - 0.8) / 0.2)
            s.speed = f < 0.8 ? speedFor(s.rpm, 5) * (1 - f) : 0
            s.boost = -68; s.target = -68; s.fuelCut = f < 0.8
        }
        return s
    }

    static func scenarioState(_ scenario: DemoScenario, tau: Double, fault: DemoFault) -> State {
        var s = State()
        let wobble = sin(tau * 7.3) * 0.5 + sin(tau * 2.1) * 0.5
        switch scenario {
        case .engineOff, .coldEngineOff:
            s.running = false; s.rpm = 0; s.throttle = 0; s.boost = 0; s.target = 0
        case .idle, .warmUp, .coldStart:
            s.rpm = 820 + wobble * 12
        case .idleWithLoads:
            s.rpm = 840 + wobble * 15; s.loads = true
        case .hold2500:
            s.rpm = tau < 2 ? lerp(820, 2550, tau / 2) : 2550 + wobble * 25
            s.throttle = tau < 2 ? 12 : 9; s.pedal = s.throttle; s.boost = -52; s.target = -52
        case .revAndRelease:
            let c = tau.truncatingRemainder(dividingBy: 6)
            if c < 0.5 {
                s.rpm = lerp(850, 4200, c / 0.5); s.throttle = 45; s.pedal = 55; s.boost = -30; s.mixture = 0.88
            } else if c < 3.2 {
                s.rpm = lerp(4200, 850, (c - 0.5) / 2.7); s.throttle = 0; s.pedal = 0; s.boost = -72
                s.fuelCut = s.rpm > 1500
            } else {
                s.rpm = 850 + wobble * 12
            }
            s.target = s.boost
        case .pedalSweep:
            s.running = false; s.rpm = 0; s.boost = 0; s.target = 0
            let c = tau.truncatingRemainder(dividingBy: 12)
            s.pedal = c < 5 ? c / 5 * 100 : (c < 6 ? 100 : (c < 11 ? (1 - (c - 6) / 5) * 100 : 0))
            s.throttle = s.pedal * 0.85
        case .wotPull:
            let c = tau.truncatingRemainder(dividingBy: 20)
            s.gear = 3
            if c < 3 {
                s.rpm = 2500 + wobble * 20; s.throttle = 20; s.pedal = 18; s.boost = -30
            } else if c < 11 {
                let f = (c - 3) / 8
                s.rpm = lerp(2600, 6800, f); s.throttle = 100; s.pedal = 100
                s.target = s.rpm < 3600 ? lerp(10, 125, (s.rpm - 2600) / 1000) : (s.rpm < 6000 ? 125 : lerp(125, 105, (s.rpm - 6000) / 800))
                s.boost = Swift.min(s.target, lerp(-10, 128, (s.rpm - 2600) / 1300)) + wobble * 2
                s.mixture = s.boost > 60 ? 0.78 : 0.88
                s.wotKnockZone = s.rpm > 4000 && s.rpm < 4800
            } else {
                s.rpm = lerp(6800, 3000, (c - 11) / 4); s.throttle = 0; s.boost = -70; s.fuelCut = true
            }
            if s.target == -66 { s.target = s.boost }
            s.speed = speedFor(s.rpm, 3)
        case .rollOn:
            // 4th gear: from 2,000 rpm at three-quarter throttle to 4,500 rpm, ease off, repeat.
            let c = tau.truncatingRemainder(dividingBy: 11)
            s.gear = 4
            if c < 2 {
                s.rpm = 2000 + wobble * 15; s.throttle = 15; s.pedal = 14; s.boost = -35
            } else if c < 8 {
                let f = (c - 2) / 6
                s.rpm = lerp(2000, 4500, f); s.throttle = 75; s.pedal = 72
                s.target = s.rpm < 3000 ? lerp(-10, 110, (s.rpm - 2000) / 1000) : 110
                s.boost = Swift.min(s.target, lerp(-20, 112, (s.rpm - 2000) / 1100)) + wobble * 2
                s.mixture = s.boost > 50 ? 0.82 : 0.95
            } else {
                s.rpm = lerp(4500, 2000, (c - 8) / 3); s.throttle = 0; s.boost = -60; s.fuelCut = true
            }
            if s.target == -66 { s.target = s.boost }
            s.speed = speedFor(s.rpm, 4)
        case .cruise:
            // Steps through 50, 80 and 100 km/h so every cruise step finds its speed.
            let targets: [Double] = [50, 80, 100]
            let v = targets[Int(tau / 25) % 3]
            s.gear = v < 60 ? 4 : 5
            s.speed = v + wobble * 2
            s.rpm = s.speed / speedFor(1, Int(s.gear))
            s.throttle = 12 + v * 0.08 + wobble; s.pedal = s.throttle
            s.boost = -45 + v * 0.15 + wobble * 2; s.target = s.boost
        }
        return s
    }

    private func applyFaultsAndDynamics(_ s: inout State, t: Double, dt: Double) {
        let wobble = sin(t * 7.3) * 0.5 + sin(t * 2.1) * 0.5
        let idle = s.running && s.rpm < 1200 && s.throttle < 5
        var v: [String: Double] = [:]

        // Coolant: warms towards the thermostat temperature, fan cycling at idle.
        if s.running {
            let thermostat = fault == .stuckThermostat ? 68.0 : 91.0
            // Demo time runs fast: warming up takes seconds instead of minutes.
            let warming = scenario == .warmUp || scenario == .coldStart
            if coolant < thermostat { coolant += dt * (warming ? 1.6 : 0.4) }
            if idle && coolant >= thermostat - 1 && !warming && fault != .stuckThermostat {
                // Heats up at idle until the fan runs.
                coolant += dt * (fanOn ? -0.25 : 0.15)
                if coolant >= 97 && fault != .deadFan { fanOn = true }
                if coolant <= 92 { fanOn = false }
            } else if !idle && coolant > thermostat + 1 {
                coolant -= dt * 0.3
                fanOn = false
            }
        }

        // Airflow and load
        let map = s.running ? s.boost + 101.3 : 101.3
        var maf = s.running ? Swift.max(3.4, map / 101.3 * s.rpm / 7000 * 110) : 0
        if s.loads { maf += 0.6 }
        let mafReading = fault == .dirtyMAF ? maf * 0.8 : maf
        let load = maf * 60 / Swift.max(s.rpm, 1)

        // Fuel trims (closed loop only when not at full throttle or on fuel cut)
        let closedLoop = s.running && s.throttle < 60 && !s.fuelCut
        var learning = 2.3, correctionBias = 0.0
        switch fault {
        case .dirtyMAF: learning = 11; correctionBias = 2
        case .vacuumLeak:
            if idle { learning = 12; correctionBias = 6 } else if s.rpm < 3000 { learning = 3.5; correctionBias = 1 } else { learning = 2.5 }
        default: break
        }
        let correction = closedLoop ? correctionBias + sin(t * 2 * .pi * 1.1) * 3 : 0

        // Actual mixture and what the front sensor reports
        var mixture = s.fuelCut ? 1.99 : (closedLoop ? 1.0 + 0.012 * sin(t * 2 * .pi * 1.1) : s.mixture)
        if fault == .leanAtWOT && s.throttle > 85 && s.boost > 40 { mixture = 0.9 }
        // A wideband gauge in the exhaust follows the real mixture quickly, and sees plain air with the engine off.
        exhaust += ((s.running ? mixture : 1.99) - exhaust) * Swift.min(1, dt / 0.08)
        if !s.running { mixture = 1.0 }
        switch fault {
        case .deadFrontSensor:
            lambdaSensor = 1.0 + 0.0003 * sin(t)
        case .lazyFrontSensor:
            // An aged sensor: takes well over a second to react.
            lambdaSensor += (mixture - lambdaSensor) * Swift.min(1, dt / 6)
        default:
            lambdaSensor += (mixture - lambdaSensor) * Swift.min(1, dt / 0.15)
        }

        // Rear O2: steady behind a good catalyst, follows the front when it's worn.
        if !s.running {
            rearO2 = 0.1
        } else if fault == .deadRearO2 {
            rearO2 = 0.04
        } else if fault == .failedCatalyst && closedLoop {
            rearO2 = 0.45 + 0.35 * (sin(t * 2 * .pi * 0.9) > 0 ? 1 : -1)
        } else {
            let target = s.fuelCut ? 0.06 : (mixture < 0.95 ? 0.84 : 0.66 + 0.02 * sin(t * 0.7))
            rearO2 += (target - rearO2) * Swift.min(1, dt / (s.fuelCut ? 0.6 : 1.5))
        }

        // Knock (demo loop has one small event; the knock fault adds real knock)
        var fbkc = s.wotKnockZone ? (fault == .knock ? -4.22 : -1.41) : 0
        if fault == .knock && s.throttle > 85 && s.rpm > 3800 && s.rpm < 5200 { fbkc = -4.22 }
        // Part-throttle knock in the mid-rpm, high-load area where it usually shows up first.
        let partLoad = s.throttle > 50 && s.rpm > 2400 && s.rpm < 4200
        if fault == .knock && partLoad && sin(t * 4.3) > 0.55 { fbkc = sin(t * 1.3) > 0 ? -4.22 : -2.11 }
        if fault == .mildKnock && partLoad && sin(t * 4.3) > 0.7 { fbkc = -1.41 }
        let flkc = fault == .knock ? -2.81 : (fault == .mildKnock ? -1.41 : (s.throttle > 85 && s.rpm > 5200 && s.rpm < 6000 ? -1.41 : 0))
        let iam = fault == .knock ? 0.75 : 1.0
        if fbkc < 0 { knockEvents += dt * 4 }

        // Boost leak: under target with the wastegate nearly shut
        var boost = s.boost
        var wgdc = s.throttle > 60 ? Swift.min(88, 45 + Swift.max(0, s.target) * 0.35) : 0
        if fault == .boostLeak && s.throttle > 85 && s.target > 20 {
            boost = s.target - 35 + wobble * 2
            wgdc = 92
        }

        // Timing
        let timing = !s.running ? 0 : (s.throttle > 60 ? Swift.max(4, 20 - boost * 0.1) + fbkc : (s.rpm < 1000 ? 12 : 34))

        // AVCS
        let loadFactor = Swift.min(1, load / 2.2)
        var inR = s.running && !idle ? 8 + 22 * loadFactor * Swift.min(1, s.rpm / 3000) - Swift.max(0, s.rpm - 5500) * 0.01 : 0.5
        var inL = inR + 0.6 * sin(t * 1.3)
        inR += 0.6 * sin(t * 1.7)
        if fault == .stuckAVCS { inR = 0.8 + 0.2 * sin(t) }
        let exR = s.running && !idle ? 4 + 12 * loadFactor : 0
        let exL = exR + 0.4 * sin(t * 1.1)
        inL = Swift.max(0, inL)

        // Misfires
        if fault == .misfireCylinder3 && s.running { rough[2] = (rough[2] + dt * (idle ? 0.6 : 1.2)).truncatingRemainder(dividingBy: 256) }
        let rpmNoise = fault == .misfireCylinder3 && idle ? sin(t * 5.1) * 55 + (sin(t * 0.9) > 0.95 ? -180 : 0) : 0

        // Electrical
        var battery = s.running ? (s.loads ? 13.8 : 14.1) : 12.6
        if fault == .weakAlternator { battery = s.running ? (s.loads ? 12.5 : 13.1) : 12.25 }

        // Pedal sensor dropout
        var pedal = s.pedal
        if fault == .wornPedal && pedal > 38 && pedal < 44 && sin(t * 40) > 0.3 { pedal = 3 }

        v["rpm"] = s.running ? Swift.max(0, s.rpm + rpmNoise) : 0
        v["speed"] = s.speed
        v["throttle"] = s.throttle
        v["pedal"] = pedal
        v["coolant"] = coolant
        v["iat"] = scenario == .coldEngineOff ? 15 : 31 + Swift.max(0, boost) * 0.05 + (idle ? 6 : 0)
        v["lambda"] = lambdaSensor
        v["afc"] = correction
        v["afl"] = s.running ? learning : 0
        v["rearO2"] = rearO2
        v["rearHeater"] = s.running && fault != .deadRearO2 ? 0.42 : 0
        v["afHeater"] = s.running && fault != .deadFrontSensor ? 0.85 : 0
        v["maf"] = mafReading
        v["mafV"] = s.running ? 0.8 + 0.16 * mafReading.squareRoot() : 0.99
        v["map"] = s.running ? boost + 101.3 : 101.3
        v["mrp"] = s.running ? boost : 0
        v["target"] = s.running ? s.target : 0
        v["wgdc"] = wgdc
        v["battery"] = battery
        v["fbkc"] = fbkc
        v["flkc"] = flkc
        v["iam"] = iam
        v["timing"] = timing
        v["ipw"] = s.running && !s.fuelCut ? 1.2 + load * 4.4 : 0
        v["load"] = Swift.min(100, map / 2.4)
        v["rough1"] = rough[0]; v["rough2"] = rough[1]; v["rough3"] = rough[2]; v["rough4"] = rough[3]
        v["isc"] = idle ? 32 + wobble * 2 : 20
        v["avcsInR"] = inR; v["avcsInL"] = inL; v["avcsExR"] = exR; v["avcsExL"] = exL
        v["ocvR"] = s.running ? 45 + inR : 0; v["ocvL"] = s.running ? 45 + inL : 0
        v["fan1"] = fanOn ? 1 : 0
        v["fan2"] = fanOn && coolant > 99 ? 1 : 0
        v["fanDuty"] = fanOn ? 60 : 0
        v["ac"] = s.loads ? 1 : 0
        v["gear"] = s.gear
        v["knockSum"] = knockEvents.rounded()
        s.values = v
    }
}

// MARK: - From engine values to ECU memory

final class DemoMemory: @unchecked Sendable {
    private struct Writer {
        let parameter: ParameterDefinition
        let conversion: Conversion
        let expression: Expression
        let key: String?
        let canonicalUnits: String
        let fallback: Double?
    }

    let capabilities: [UInt8]
    let world = DemoWorld()
    private let writers: [Writer]
    private let switches: [(address: UInt32, bit: Int, key: String?)]
    private let codes: [DiagnosticCodeDefinition]
    private let lock = NSLock()
    private var bytes: [UInt32: UInt8] = [:]
    private var builtAt = Date.distantPast
    private let start = Date()
    private var memorizedCodeIDs: Set<String>

    /// Parameters a petrol turbo EJ ECU reports, by RomRaider ID.
    static let supportedStandard: Set<String> = [
        "P1", "P2", "P3", "P4", "P7", "P8", "P9", "P10", "P11", "P12", "P13", "P14", "P15", "P17", "P18", "P19",
        "P21", "P22", "P23", "P24", "P25", "P29", "P30", "P31", "P33", "P36", "P41", "P47", "P48", "P49", "P50", "P51",
        "P54", "P58", "P60", "P61", "P63", "P64", "P69", "P70", "P83", "P84", "P90", "P91", "P92", "P239", "P240", "P241",
    ]
    static let supportedSwitches: Set<String> = [
        "S2", "S4", "S7", "S9", "S11", "S15", "S18", "S19", "S20", "S21", "S22", "S23", "S28", "S29", "S30", "S63", "S64", "S67", "S69",
    ]

    /// Which world value feeds a parameter, by the parameter's base name.
    static let keyByBaseName: [String: String] = {
        var map: [String: String] = [:]
        for p in Probes.all { map[ParameterResolver.baseName(p.concept)] = p.key }
        map["gear position"] = "gear"
        map["gear (calculated)"] = "gear"
        map["target boost relative"] = "target"
        map["knock sum"] = "knockSum"
        map["knock correction advance"] = nil
        return map
    }()

    static let canonicalUnits: [String: String] = {
        var map = Dictionary(Probes.all.map { ($0.key, $0.units) }, uniquingKeysWith: { a, _ in a })
        map["gear"] = "gear"
        map["knockSum"] = "count"
        return map
    }()

    init(definitions: LoggerDefinitions?) {
        var caps = [UInt8](repeating: 0, count: 48)
        func enable(_ byte: Int?, _ bit: Int?) {
            guard let byte, let bit, byte >= 8, byte - 8 < caps.count else { return }
            caps[byte - 8] |= 1 << UInt8(bit)
        }
        for p in definitions?.standard ?? [] where Self.supportedStandard.contains(p.id) { enable(p.capabilityByte, p.capabilityBit) }
        for s in definitions?.switches ?? [] where Self.supportedSwitches.contains(s.id) { enable(s.capabilityByte, s.capabilityBit) }
        caps[11] |= 0xA0     // test mode and D-Check flags present
        caps[12] |= 0x08     // ignition switch flag present
        capabilities = caps

        let identity = ECUIdentity(systemID: DemoECU.identity.systemID, romID: DemoECU.identity.romID, capabilities: caps)
        let set = definitions?.parameterSet(for: identity)
        var unmatched: [Writer] = []
        var matched: [Writer] = []
        for p in set?.parameters ?? [] where p.kind == .standard || p.kind == .extended {
            guard let conversion = p.conversions.first, let expression = try? Expression(conversion.expression) else { continue }
            let key = Self.key(for: p)
            let writer = Writer(parameter: p, conversion: conversion, expression: expression, key: key,
                                canonicalUnits: key.flatMap { Self.canonicalUnits[$0] } ?? conversion.units,
                                fallback: Self.fallbackValue(conversion))
            if key != nil { matched.append(writer) } else { unmatched.append(writer) }
        }
        // Parameters fed by the world go last so they win where addresses overlap.
        writers = unmatched + matched
        switches = (set?.parameters ?? []).filter { $0.kind == .switchBit }.compactMap { s in
            guard let address = s.addresses.first, let bit = s.bit else { return nil }
            let name = s.name.lowercased()
            let key: String?
            if name.contains("ignition switch") || name.contains("fuel pump relay") || name.contains("crankshaft") || name.contains("camshaft") {
                key = "on"
            } else if name.contains("neutral") { key = "neutral" }
            else if name.contains("radiator fan relay #1") { key = "fan1" }
            else if name.contains("radiator fan relay #2") { key = "fan2" }
            else if name.contains("air conditioning switch") || name.contains("light switch") || name.contains("blower") || name.contains("defogger") { key = "ac" }
            else if name.contains("knocking") { key = "knocking" }
            else { key = nil }
            return (address, bit, key)
        }
        codes = set?.diagnosticCodes ?? []
        memorizedCodeIDs = Set(codes.filter { $0.code == "P0420" }.prefix(1).map(\.id))
    }

    static func key(for p: ParameterDefinition) -> String? {
        let base = ParameterResolver.baseName(p.name)
        if let k = keyByBaseName[base] { return k }
        if base.hasPrefix("knock correction advance") { return nil }
        if base.hasPrefix("target boost") { return "target" }
        if base.hasPrefix("iam") { return "iam" }
        return nil
    }

    func byte(at address: UInt32) -> UInt8 {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(builtAt) > 0.04 { rebuild() }
        return bytes[address] ?? 0
    }

    func write(address: UInt32, value: UInt8) -> UInt8 {
        lock.lock()
        defer { lock.unlock() }
        if address == ClearMemory.address && value == ClearMemory.value {
            memorizedCodeIDs.removeAll()
            builtAt = .distantPast
        }
        return value
    }

    private func rebuild() {
        let values = world.sample(at: Date().timeIntervalSince(start))
        var out: [UInt32: UInt8] = [:]
        for w in writers {
            var value: Double?
            if let key = w.key, let raw = values[key] {
                value = UnitNormalizer.convert(raw, from: w.canonicalUnits, to: w.conversion.units) ?? raw
                if w.conversion.units == "gear" && key == "gear" { value = Swift.max(1, raw) }
            } else {
                value = w.fallback
            }
            guard let value else { continue }
            let encoded = Self.encode(value, parameter: w.parameter, conversion: w.conversion, expression: w.expression)
            for (address, byte) in zip(w.parameter.addresses, encoded) { out[address] = byte }
        }
        for s in switches {
            let on: Bool
            switch s.key {
            case "on": on = true
            case "neutral": on = (values["gear"] ?? 0) == 0
            case "knocking": on = (values["fbkc"] ?? 0) < 0
            case let k?: on = (values[k] ?? 0) > 0.5
            case nil: on = false
            }
            if on { out[s.address, default: 0] |= 1 << UInt8(s.bit) }
        }
        out[0x62, default: 0] |= 0x08   // ignition on
        for code in codes where memorizedCodeIDs.contains(code.id) {
            out[code.memorizedAddress, default: 0] |= 1 << UInt8(code.bit)
        }
        bytes = out
        builtAt = Date()
    }

    // MARK: Encoding

    /// Finds raw bytes that make `expression` produce `value`.
    static func encode(_ value: Double, parameter: ParameterDefinition, conversion: Conversion, expression: Expression) -> [UInt8] {
        let n = Swift.max(1, parameter.addresses.count)
        let f0 = expression.evaluate(x: 0), f1 = expression.evaluate(x: 1), f2 = expression.evaluate(x: 2)
        let linear = f0.isFinite && f1.isFinite && abs(f2 - 2 * f1 + f0) < 1e-9 * Swift.max(1, abs(f1)) && f1 != f0
        if conversion.storageType == .float && n == 4 {
            let raw = linear ? (value - f0) / (f1 - f0) : value
            return withUnsafeBytes(of: Float(raw).bitPattern.bigEndian, Array.init)
        }
        let signed = conversion.storageType.map { [.int8, .int16, .int32].contains($0) } ?? false
        let bits = n * 8
        let maxRaw = signed ? Double((1 << (bits - 1)) - 1) : Double((1 << bits) - 1)
        let minRaw = signed ? -Double(1 << (bits - 1)) : 0
        var raw: Double
        if linear {
            raw = ((value - f0) / (f1 - f0)).rounded()
        } else if n == 1 {
            raw = (Int(minRaw)...Int(maxRaw)).min { abs(expression.evaluate(x: Double($0)) - value) < abs(expression.evaluate(x: Double($1)) - value) }.map(Double.init) ?? 0
        } else {
            raw = 0
        }
        raw = Swift.min(maxRaw, Swift.max(minRaw, raw))
        let word = UInt32(bitPattern: Int32(truncatingIfNeeded: Int64(raw)))
        return (0..<n).map { UInt8((word >> UInt32(8 * (n - 1 - $0))) & 0xFF) }
    }

    static func fallbackValue(_ c: Conversion) -> Double? {
        if let lo = c.gaugeMin, let hi = c.gaugeMax, hi > lo {
            return lo <= 0 && hi >= 0 ? 0 : lo + (hi - lo) * 0.25
        }
        return nil
    }
}
