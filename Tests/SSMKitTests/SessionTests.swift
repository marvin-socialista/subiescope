import Foundation
import Testing
@testable import SSMKit

final class SampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var errors: [String] = []
    func add(_ s: Sample) { lock.lock(); samples.append(s); lock.unlock() }
    func fail(_ e: Error) { lock.lock(); errors.append(e.localizedDescription); lock.unlock() }
    var all: [Sample] { lock.lock(); defer { lock.unlock() }; return samples }
    var allErrors: [String] { lock.lock(); defer { lock.unlock() }; return errors }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@Suite("Session against the demo ECU", .serialized)
struct SessionTests {
    static let defs = try! LoggerDefinitions.bundled()

    func items(_ names: [String], set: ECUParameterSet) -> [PollItem] {
        names.compactMap { name in
            set.parameters.first { $0.name == name }.map { PollItem(parameter: $0, conversion: $0.conversions[0]) }
        }
    }

    func run(fastPoll: Bool) async throws -> (samples: [Sample], errors: [String], rate: Double) {
        let demo = try DemoECU.make(definitions: Self.defs)
        defer { demo.stop() }
        let session = SSMSession(portPath: demo.ecu.devicePath)
        session.fastPoll = fastPoll
        session.transport.onBreak = { demo.ecu.simulateBreak() }
        let identity = try await session.connect()
        #expect(identity.ecuID == "5A04784207")
        let set = Self.defs.parameterSet(for: identity)
        let wanted = ["Engine Speed", "Manifold Relative Pressure", "Coolant Temperature", "IAM (4-byte)*",
                      "Feedback Knock Correction (4-byte)*", "A/F Sensor #1", "Injector Duty Cycle"]
        let poll = items(wanted, set: set)
        #expect(poll.count == wanted.count, "missing: \(Set(wanted).subtracting(poll.map(\.parameter.name)))")

        let box = SampleBox()
        let all = Dictionary(set.parameters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let start = Date()
        session.startPolling(items: poll, allParameters: all, onSample: { box.add($0) }, onError: { e, _ in box.fail(e) })
        try await Task.sleep(for: .seconds(3))

        // A one-off job in the middle of (fast) polling must still get its own answer.
        let codes = try await session.run { client in try TroubleCodeReport.read(with: client, definitions: set.diagnosticCodes) }
        #expect(codes.memorized.map(\.code) == ["P0420"])
        #expect(codes.current.isEmpty)
        try await session.run { client in try ClearMemory.perform(with: client) }
        let after = try await session.run { client in try TroubleCodeReport.read(with: client, definitions: set.diagnosticCodes) }
        #expect(after.memorized.isEmpty)

        try await Task.sleep(for: .seconds(1))
        session.stopPolling()
        session.close()
        let samples = box.all
        return (samples, box.allErrors, Double(samples.count) / Date().timeIntervalSince(start))
    }

    @Test func pollingAndDiagnostics() async throws {
        let normal = try await run(fastPoll: false)
        #expect(normal.errors.isEmpty, "\(normal.errors)")
        #expect(normal.samples.count > 5)
        let last = try #require(normal.samples.last)
        let rpm = try #require(last.values["P8"])
        #expect(rpm > 600 && rpm < 7500)
        #expect(last.values["E31"] == 1.0)                    // IAM float
        #expect((80...100).contains(last.values["P2"] ?? 0))  // coolant, simulated
        #expect((last.values["P201"] ?? -1) >= 0)             // injector duty, calculated

        let fast = try await run(fastPoll: true)
        #expect(fast.errors.isEmpty, "\(fast.errors)")
        print("samples/s normal: \(normal.rate), fast: \(fast.rate)")
        #expect(fast.rate > normal.rate * 1.3)
    }

    /// A real ECU does not answer a request that is too long: a 2008 STI stayed silent when the
    /// trouble code flags were asked for 84 at a time. The demo ECU does the same.
    @Test func longRequestsAreSplit() async throws {
        let demo = try DemoECU.make(definitions: Self.defs)
        defer { demo.stop() }
        let session = SSMSession(portPath: demo.ecu.devicePath)
        session.transport.onBreak = { demo.ecu.simulateBreak() }
        let streams = Counter()
        session.transport.traffic = { direction, bytes in
            if direction == .sent, bytes.count > 5, bytes[4] == SSMCommand.readAddresses, bytes[5] == 0x01 { streams.add() }
        }
        let set = Self.defs.parameterSet(for: try await session.connect())

        // As many flag bytes as a packet has room for, in one request: no answer.
        let flags = Array(Set(set.diagnosticCodes.flatMap { [$0.currentAddress, $0.memorizedAddress] })).sorted()
        #expect(flags.count > 84)
        await #expect(throws: SSMError.self) {
            try await session.run { client in
                try client.transport.exchange(.readAddressesRequest(Array(flags.prefix(84))), expectedDataLength: 85)
            }
        }
        let codes = try await session.run { client in try TroubleCodeReport.read(with: client, definitions: set.diagnosticCodes) }
        #expect(codes.memorized.map(\.code) == ["P0420"])

        // An ECU that takes less than most (34 addresses): fast poll finds out once, then
        // reads the same values in smaller requests.
        demo.ecu.maxExchangeBytes = 150
        var poll: [PollItem] = []
        var wanted = Set<UInt32>()
        for parameter in set.parameters where !parameter.addresses.isEmpty && wanted.count < 45 {
            guard let conversion = parameter.conversions.first else { continue }
            poll.append(PollItem(parameter: parameter, conversion: conversion))
            wanted.formUnion(parameter.addresses)
        }
        #expect((45...SSMClient.maxAddressesPerStream).contains(wanted.count))

        let box = SampleBox()
        let all = Dictionary(set.parameters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        session.startPolling(items: poll, allParameters: all, onSample: { box.add($0) }, onError: { e, _ in box.fail(e) })
        try await Task.sleep(for: .seconds(4))
        session.stopPolling()
        session.close()
        #expect(box.allErrors.isEmpty, "\(box.allErrors)")
        #expect(box.all.count >= 3)
        #expect(streams.value == 1)
    }
}
