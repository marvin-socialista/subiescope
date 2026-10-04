import Foundation
import Testing
@testable import SSMKit

@Suite("AEM wideband output")
struct AEMWidebandTests {
    @Test func readsAFRAndLambdaLines() throws {
        // What the gauge shows: AFR out of the box, lambda when the display is set to it.
        #expect(abs(try #require(AEMWideband.lambda(fromLine: "14.7")) - 1.0) < 0.0001)
        #expect(abs(try #require(AEMWideband.lambda(fromLine: "11.0")) - 11.0 / 14.7) < 0.0001)
        #expect(AEMWideband.lambda(fromLine: "1.00") == 1.0)
        #expect(AEMWideband.lambda(fromLine: ".85") == 0.85)
        #expect(AEMWideband.lambda(fromLine: " 0.78 ") == 0.78)
        // The 19200 baud lambda output adds status words.
        #expect(AEMWideband.lambda(fromLine: "0.912\tReady\tNo-errors") == 0.912)
    }

    @Test func ignoresEverythingThatIsNotAReading() {
        for line in ["", "----", "Ready", "nan", "inf", "0x10", "-1.0", "1.0.0", "0.0", "3.7", "99.9", "14,7", "\u{F8}~"] {
            #expect(AEMWideband.lambda(fromLine: line) == nil, "\(line)")
        }
    }

    @Test func afrOnScreenIsWhatTheGaugeShows() throws {
        let afr = try #require(AEMWideband.definition.conversions.first { $0.units == "AFR" })
        let lambda = try #require(AEMWideband.definition.conversions.first { $0.units == "Lambda" })
        let reading = try #require(AEMWideband.lambda(fromLine: "12.3"))
        #expect(afr.formatted(AEMWideband.value(reading, in: afr)) == "12.30")
        #expect(lambda.formatted(AEMWideband.value(reading, in: lambda)) == "0.84")
        // The conversions say the same as the shortcut, for anything that evaluates them.
        #expect(abs(try Expression(afr.expression).evaluate(x: reading) - 12.3) < 0.0001)
        #expect(try Expression(lambda.expression).evaluate(x: reading) == reading)
    }

    @Test func theGaugeIsNotAskedFromTheECU() {
        let item = PollItem(parameter: AEMWideband.definition, conversion: AEMWideband.definition.conversions[0])
        let ssm = PollPlan(items: [item], allParameters: [:])
        #expect(ssm.addresses.isEmpty && ssm.entries.isEmpty)
        let obd = OBDPlan(items: [item], allParameters: [:])
        #expect(obd.pids.isEmpty && obd.entries.isEmpty)
    }
}

/// The real path: the simulated gauge behind a pseudo terminal, read through the normal serial port code.
@Suite("Wideband gauge on a serial port", .serialized)
struct WidebandReaderTests {
    final class Mixture: @unchecked Sendable {
        private let lock = NSLock()
        private var lambda = 1.0
        var value: Double {
            get { lock.lock(); defer { lock.unlock() }; return lambda }
            set { lock.lock(); lambda = newValue; lock.unlock() }
        }
    }

    final class States: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [WidebandReader.State] = []
        func add(_ s: WidebandReader.State) { lock.lock(); seen.append(s); lock.unlock() }
        var all: [WidebandReader.State] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    func wait(_ seconds: Double = 3, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    func makeGauge(_ output: SimulatedWideband.Output = .afr, mixture: Mixture = Mixture()) throws -> SimulatedWideband {
        try SimulatedWideband(output: output, interval: 0.01) { mixture.value }
    }

    @Test func followsTheGauge() async throws {
        let mixture = Mixture()
        let gauge = try makeGauge(mixture: mixture)
        defer { gauge.stop() }
        let reader = WidebandReader(path: gauge.devicePath)
        let states = States()
        reader.onState = { states.add($0) }
        defer { reader.stop() }
        #expect(reader.lambda() == nil)
        reader.start()
        try await wait { reader.lambda() != nil }
        #expect(reader.state == .reading(baud: 9600))
        #expect(states.all == [.reading(baud: 9600)])
        #expect(abs(try #require(reader.lambda()) - 1.0) < 0.001)

        mixture.value = 0.75   // full throttle: the gauge shows 11.0
        try await wait { (reader.lambda() ?? 1) < 0.8 }
        #expect(abs(try #require(reader.lambda()) - 11.0 / 14.7) < 0.001)

        // Out of the gauge's range it shows its limit, 20.0.
        mixture.value = 1.99
        try await wait { (reader.lambda() ?? 0) > 1.3 }
        #expect(abs(try #require(reader.lambda()) - 20.0 / 14.7) < 0.001)
    }

    @Test func readsAGaugeSetToLambda() async throws {
        let mixture = Mixture()
        mixture.value = 0.83
        let gauge = try makeGauge(.lambda, mixture: mixture)
        defer { gauge.stop() }
        let reader = WidebandReader(path: gauge.devicePath)
        defer { reader.stop() }
        reader.start()
        try await wait { reader.lambda() != nil }
        #expect(reader.lambda() == 0.83)
    }

    @Test func triesTheOtherSpeedWhenTheGaugeLooksLikeNoise() async throws {
        let mixture = Mixture()
        mixture.value = 0.912
        let gauge = try makeGauge(.lambdaWithStatus, mixture: mixture)
        defer { gauge.stop() }
        gauge.garbled = true
        let reader = WidebandReader(path: gauge.devicePath, window: 0.5)
        defer { reader.stop() }
        reader.start()
        try await wait { reader.listeningBaud == 19200 }
        #expect(reader.lambda() == nil)
        gauge.garbled = false
        try await wait { reader.lambda() != nil }
        #expect(reader.state == .reading(baud: 19200))
        #expect(reader.lambda() == 0.912)
    }

    @Test func saysSoWhenTheGaugeSendsNothing() async throws {
        let gauge = try makeGauge()
        defer { gauge.stop() }
        gauge.silent = true
        let reader = WidebandReader(path: gauge.devicePath, window: 0.1)
        defer { reader.stop() }
        reader.start()
        try await wait { reader.state == .silent }
        #expect(reader.state == .silent)
        #expect(reader.lambda() == nil)
        // Switched on later (the ignition): it is picked up without reconnecting.
        gauge.silent = false
        try await wait { reader.lambda() != nil }
        #expect(reader.lambda() != nil)
    }

    @Test func aReadingThatStoppedIsNotRepeated() async throws {
        let gauge = try makeGauge()
        defer { gauge.stop() }
        let reader = WidebandReader(path: gauge.devicePath, window: 0.2)
        defer { reader.stop() }
        reader.start()
        try await wait { reader.lambda() != nil }
        let conversion = AEMWideband.definition.conversions[0]
        var sample = Sample(time: Date(), values: ["P8": 2500], roundTrip: 0.05)
        #expect(reader.add(to: &sample, conversion: conversion))
        #expect(abs(try #require(sample.values[AEMWideband.parameterID]) - 14.7) < 0.01)
        #expect(sample.values["P8"] == 2500)

        gauge.silent = true
        try await wait { reader.state == .silent }
        #expect(reader.state == .silent)
        var later = Sample(time: Date().addingTimeInterval(1.5), values: ["P8": 2500], roundTrip: 0.05)
        #expect(!reader.add(to: &later, conversion: conversion))
        #expect(later.values[AEMWideband.parameterID] == nil)
    }

    @Test func noticesTheAdapterBeingUnplugged() async throws {
        let gauge = try makeGauge()
        let reader = WidebandReader(path: gauge.devicePath)
        defer { reader.stop() }
        reader.start()
        try await wait { reader.lambda() != nil }
        gauge.stop()
        try await wait { if case .failed = reader.state { return true } else { return false } }
        guard case .failed = reader.state else { Issue.record("expected a failure, got \(reader.state)"); return }
    }

    @Test func aMissingPortIsReported() async throws {
        let reader = WidebandReader(path: "/dev/cu.no-such-gauge")
        defer { reader.stop() }
        reader.start()
        try await wait(4) { if case .failed = reader.state { return true } else { return false } }
        guard case .failed(let reason) = reader.state else { Issue.record("expected a failure, got \(reader.state)"); return }
        #expect(reason.contains("/dev/cu.no-such-gauge"))
    }

    @Test func stopsWhenTold() async throws {
        let gauge = try makeGauge()
        defer { gauge.stop() }
        let reader = WidebandReader(path: gauge.devicePath)
        reader.start()
        try await wait { reader.lambda() != nil }
        reader.stop()
        #expect(reader.lambda() == nil)
        // The port is free again for a new listener, as after changing a setting in the app.
        let second = WidebandReader(path: gauge.devicePath)
        defer { second.stop() }
        second.start()
        try await wait { second.lambda() != nil }
        #expect(second.lambda() != nil)
    }
}

@Suite("Wideband gauge on the demo car", .serialized)
struct DemoWidebandTests {
    /// The world's exhaust at full throttle in a pull, after running it for a while.
    func exhaustAtFullThrottle(fault: DemoFault) -> (exhaust: Double, frontSensor: Double) {
        let world = DemoWorld(fault: fault)
        world.setScenario(.wotPull)
        var result = (exhaust: 1.0, frontSensor: 1.0)
        for step in 0..<400 {
            let values = world.sample(at: Double(step) * 0.05)
            if (values["throttle"] ?? 0) > 85 && (values["mrp"] ?? 0) > 60 {
                result = (world.exhaustLambda, values["lambda"] ?? 1)
            }
        }
        return result
    }

    @Test func showsTheRealMixtureWhateverTheCarsSensorSays() {
        let healthy = exhaustAtFullThrottle(fault: .none)
        #expect(healthy.exhaust < 0.82)
        #expect(abs(healthy.exhaust - healthy.frontSensor) < 0.05)
        // A dead front sensor reads 1.00 all the time; the gauge in the exhaust still sees the rich mixture.
        let dead = exhaustAtFullThrottle(fault: .deadFrontSensor)
        #expect(dead.exhaust < 0.82)
        #expect(abs(dead.frontSensor - 1.0) < 0.01)
        // The fault a wideband is bought for.
        #expect(abs(exhaustAtFullThrottle(fault: .leanAtWOT).exhaust - 0.9) < 0.02)
    }

    @Test func seesAirWithTheEngineOff() {
        let world = DemoWorld()
        world.setScenario(.engineOff)
        for step in 0..<40 { _ = world.sample(at: Double(step) * 0.05) }
        #expect(world.exhaustLambda > 1.9)
    }

    @Test func ridesAlongWithTheCarsSamples() async throws {
        let defs = try LoggerDefinitions.bundled()
        let demo = try DemoECU.make(definitions: defs)
        defer { demo.stop() }
        let gauge = try SimulatedWideband(world: demo.world, interval: 0.02)
        defer { gauge.stop() }
        let reader = WidebandReader(path: gauge.devicePath)
        defer { reader.stop() }
        reader.start()

        let session = SSMSession(portPath: demo.ecu.devicePath)
        session.transport.onBreak = { demo.ecu.simulateBreak() }
        defer { session.close() }
        let identity = try await session.connect()
        let set = defs.parameterSet(for: identity)
        let rpm = try #require(set.parameters.first { $0.name == "Engine Speed" })
        let wideband = AEMWideband.definition
        // The gauge is in the selection like any parameter; the ECU is only asked for its own.
        let items = [PollItem(parameter: rpm, conversion: rpm.conversions[0]),
                     PollItem(parameter: wideband, conversion: wideband.conversions[0])]
        let box = SampleBox()
        session.startPolling(items: items, allParameters: Dictionary(set.parameters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                             onSample: { sample in
                                 var sample = sample
                                 reader.add(to: &sample, conversion: wideband.conversions[0])
                                 box.add(sample)
                             }, onError: { e, _ in box.fail(e) })
        try await Task.sleep(for: .seconds(2))
        session.stopPolling()
        #expect(box.allErrors.isEmpty, "\(box.allErrors)")
        let withGauge = box.all.filter { $0.values[wideband.id] != nil }
        #expect(withGauge.count > 5)
        let last = try #require(withGauge.last)
        #expect(last.values[rpm.id] != nil)
        #expect((8.0...20.0).contains(last.values[wideband.id] ?? 0))

        // And into a log file with a column of its own.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wideband-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try CSVLogWriter(url: url, columns: items.map {
            CSVLogWriter.Column(id: $0.parameter.id, title: $0.parameter.name, conversion: $0.conversion)
        })
        for sample in withGauge { writer.append(time: sample.time, values: sample.values) }
        writer.close()
        let log = try RecordedLog.load(url)
        #expect(log.columns.map(\.header) == ["Engine Speed (rpm)", "AEM Wideband A/F (AFR)"])
        #expect(log.values[1].allSatisfy { (8.0...20.0).contains($0) })
    }
}
