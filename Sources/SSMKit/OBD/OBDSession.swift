import Foundation

/// What was learned about the car and the adapter when connecting.
public struct OBDInfo: Equatable, Sendable {
    /// e.g. "ELM327 v2.3"
    public var adapter: String
    /// e.g. "ISO 15765-4 (CAN 11/500)"
    public var protocolName: String
    public var supportedPIDs: Set<UInt8>
    public var vin: String?
    /// Voltage the adapter measures on the OBD port.
    public var voltage: Double?
}

/// Owns the adapter. Like `SSMSession`, all I/O runs on one serial queue and the
/// polling loop re-enqueues itself, so one-off jobs (reading codes) run between two polls.
public final class OBDSession: @unchecked Sendable {
    public let elm: ELM327
    public private(set) var info: OBDInfo?

    private let channel: ELMChannel
    private let queue = DispatchQueue(label: "subiescope.obd.io", qos: .userInitiated)
    private var plan: OBDPlan?
    private var pollGeneration = 0
    private var consecutiveErrors = 0
    private var timeoutStreak = 0
    private var cycle = 0
    private var lastReplies: [UInt8: [UInt8]] = [:]
    private var missCounts: [UInt8: Int] = [:]
    private var statsStart = Date()
    private var statsSamples = 0

    /// Values this car keeps not answering. They are left out so they do not slow the others down.
    public private(set) var skippedPIDs: Set<UInt8> = []
    /// Called (on the I/O queue) when the set of skipped values grows.
    public var onSkip: (@Sendable (Set<UInt8>) -> Void)?

    public init(channel: ELMChannel) {
        self.channel = channel
        self.elm = ELM327(channel: channel)
    }

    deinit { channel.close() }

    public func connect() async throws -> OBDInfo {
        try await run { elm in
            try elm.start()
            let supported: Set<UInt8>
            do {
                supported = try elm.supportedPIDs()
            } catch {
                // Some cars will not list what they support. Ask for the common values one by one instead.
                DiagnosticLog.shared.warning("obd", "No list of supported values (\(error.localizedDescription)); probing the common ones")
                let found = elm.probePIDs([0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11])
                guard !found.isEmpty else { throw error }
                let info = OBDInfo(adapter: elm.version, protocolName: elm.protocolName, supportedPIDs: found,
                                   vin: (try? elm.readVIN()).flatMap { $0 }, voltage: elm.adapterVoltage())
                self.info = info
                return info
            }
            let info = OBDInfo(adapter: elm.version, protocolName: elm.protocolName, supportedPIDs: supported,
                               vin: (try? elm.readVIN()).flatMap { $0 }, voltage: elm.adapterVoltage())
            self.info = info
            return info
        }
    }

    public func run<T>(_ work: @escaping (ELM327) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result { try work(elm) })
            }
        }
    }

    public func close() {
        queue.async { [self] in
            pollGeneration += 1
            plan = nil
            channel.close()
        }
    }

    // MARK: Polling

    public func startPolling(items: [PollItem], allParameters: [String: ParameterDefinition],
                             conversionFor: @escaping (ParameterDefinition) -> Conversion? = { $0.conversions.first },
                             onSample: @escaping @Sendable (Sample) -> Void,
                             onError: @escaping @Sendable (Error, _ fatal: Bool) -> Void) {
        queue.async { [self] in
            pollGeneration += 1
            consecutiveErrors = 0
            timeoutStreak = 0
            cycle = 0
            lastReplies = [:]
            missCounts = [:]
            skippedPIDs = []
            statsStart = Date()
            statsSamples = 0
            let newPlan = OBDPlan(items: items, allParameters: allParameters, conversionFor: conversionFor)
            guard !newPlan.pids.isEmpty else {
                plan = nil
                return
            }
            plan = newPlan
            let generation = pollGeneration
            queue.async { self.poll(generation: generation, onSample: onSample, onError: onError) }
        }
    }

    public func stopPolling() {
        queue.async { [self] in
            pollGeneration += 1
            plan = nil
        }
    }

    private func poll(generation: Int, onSample: @escaping @Sendable (Sample) -> Void,
                      onError: @escaping @Sendable (Error, Bool) -> Void) {
        guard generation == pollGeneration, let plan else { return }
        let started = Date()
        cycle += 1
        let active = plan.pids.filter { !skippedPIDs.contains($0) }
        // Fast-moving values every round, slow ones (temperatures, voltage) every eighth round.
        let fast = active.filter { !OBDParameters.slowPIDs.contains($0) }
        let due = fast.isEmpty || cycle % 8 == 1 ? active : fast
        do {
            guard !due.isEmpty else { throw OBDError.noData }
            let replies = try elm.readPIDs(due)
            timeoutStreak = 0
            guard !replies.isEmpty else { throw OBDError.noData }
            lastReplies.merge(replies) { _, new in new }
            noteMisses(due: due, replies: replies)
            consecutiveErrors = 0
            statsSamples += 1
            onSample(Sample(time: started, values: plan.evaluate(lastReplies), roundTrip: Date().timeIntervalSince(started)))
            logStatsIfDue()
        } catch {
            consecutiveErrors += 1
            if case OBDError.timeout = error {
                timeoutStreak += 1
                if timeoutStreak == 2 { elm.relaxTiming() }
            }
            let fatal = consecutiveErrors >= 5 || (error as? OBDError) == .disconnected
            DiagnosticLog.shared.warning("obd", "Poll error \(consecutiveErrors): \(error.localizedDescription)\(fatal ? " (giving up)" : "")")
            onError(error, fatal)
            if fatal {
                pollGeneration += 1
                self.plan = nil
                return
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        queue.async { self.poll(generation: generation, onSample: onSample, onError: onError) }
    }

    /// A value that stays silent for three rounds in a row is dropped from the rounds.
    private func noteMisses(due: [UInt8], replies: [UInt8: [UInt8]]) {
        var newlySkipped: Set<UInt8> = []
        for pid in due {
            if replies[pid] != nil {
                missCounts[pid] = 0
            } else {
                missCounts[pid, default: 0] += 1
                if missCounts[pid]! >= 3 { newlySkipped.insert(pid) }
            }
        }
        guard !newlySkipped.isEmpty else { return }
        skippedPIDs.formUnion(newlySkipped)
        for pid in newlySkipped { lastReplies[pid] = nil }
        DiagnosticLog.shared.warning("obd", "Not answered, skipping: \(newlySkipped.sorted().map { String(format: "%02X", $0) }.joined(separator: " "))")
        onSkip?(skippedPIDs)
    }

    /// Every half minute: how fast this adapter and car really are. Useful when someone reports "it is slow".
    private func logStatsIfDue() {
        let elapsed = Date().timeIntervalSince(statsStart)
        guard elapsed >= 30 else { return }
        DiagnosticLog.shared.info("obd", String(format: "Polling: %.1f samples/s, %.0f ms per request, %d values, batching %@, %@ timing, %d skipped",
                                                Double(statsSamples) / elapsed, elm.averageRequestMilliseconds, plan?.pids.count ?? 0,
                                                elm.batchingWorks ? "on" : "off", elm.aggressiveTiming ? "fast" : "normal", skippedPIDs.count))
        statsStart = Date()
        statsSamples = 0
    }
}

/// The OBD-II values to read for a set of parameters, and how to turn replies into numbers.
struct OBDPlan {
    struct Entry {
        var pid: OBDPID
        var parameterID: String
        var conversion: Conversion
        var expression: Expression?
        var output: Bool
    }

    var pids: [UInt8] = []
    var entries: [Entry] = []
    var calculated: [(item: PollItem, expression: Expression?, bindings: [String: (id: String, units: String?)])] = []

    init(items: [PollItem], allParameters: [String: ParameterDefinition],
         conversionFor: (ParameterDefinition) -> Conversion? = { $0.conversions.first }) {
        func add(_ parameter: ParameterDefinition, _ conversion: Conversion, output: Bool) {
            guard let pid = OBDParameters.catalog.first(where: { $0.id == parameter.id }) else { return }
            if !pids.contains(pid.pid) { pids.append(pid.pid) }
            entries.append(Entry(pid: pid, parameterID: parameter.id, conversion: conversion,
                                 expression: try? Expression(conversion.expression), output: output))
        }
        for item in items where item.parameter.kind != .calculated {
            add(item.parameter, item.conversion, output: true)
        }
        for item in items where item.parameter.kind == .calculated {
            let expression = try? Expression(item.conversion.expression)
            var bindings: [String: (id: String, units: String?)] = [:]
            for variable in expression?.variables ?? [] {
                let binding = PollPlan.parseReference(variable)
                bindings[variable] = binding
                guard let dependency = allParameters[binding.id], dependency.kind != .calculated else { continue }
                let conversion = binding.units.flatMap { units in dependency.conversions.first { $0.units == units } }
                    ?? conversionFor(dependency)
                if let conversion, !entries.contains(where: { $0.parameterID == dependency.id && $0.conversion.units == conversion.units }) {
                    add(dependency, conversion, output: false)
                }
            }
            calculated.append((item, expression, bindings))
        }
    }

    func evaluate(_ replies: [UInt8: [UInt8]]) -> [String: Double] {
        var values: [String: Double] = [:]
        var byUnits: [String: Double] = [:]
        for entry in entries {
            guard let data = replies[entry.pid.pid], let raw = entry.pid.raw(from: data) else { continue }
            let value = entry.expression?.evaluate(x: raw) ?? raw
            byUnits[entry.parameterID + "|" + entry.conversion.units] = value
            if entry.output || byUnits[entry.parameterID] == nil { byUnits[entry.parameterID] = value }
            if entry.output { values[entry.parameterID] = value }
        }
        for calc in calculated {
            var vars: [String: Double] = [:]
            for (variable, binding) in calc.bindings {
                if let units = binding.units, let v = byUnits[binding.id + "|" + units] {
                    vars[variable] = v
                } else {
                    vars[variable] = byUnits[binding.id] ?? .nan
                }
            }
            values[calc.item.parameter.id] = calc.expression?.evaluate(vars) ?? .nan
        }
        return values
    }
}
