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
}
