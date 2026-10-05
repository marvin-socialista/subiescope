import Foundation

/// A parameter to poll together with the unit conversion to report it in.
public struct PollItem: Sendable {
    public var parameter: ParameterDefinition
    public var conversion: Conversion

    public init(parameter: ParameterDefinition, conversion: Conversion) {
        self.parameter = parameter
        self.conversion = conversion
    }
}

public struct Sample: Sendable {
    public var time: Date
    /// Converted values keyed by parameter ID.
    public var values: [String: Double]
    /// Seconds the poll took on the wire.
    public var roundTrip: TimeInterval
}

/// Owns the cable. All I/O runs on one serial queue: the polling loop re-enqueues
/// itself after every round, so one-off jobs such as reading trouble codes run
/// between two polls instead of colliding with them on the K-line.
public final class SSMSession: @unchecked Sendable {
    public let portPath: String
    public let transport: SSMTransport
    public let client: SSMClient
    public private(set) var identity: ECUIdentity?
    /// The Tactrix OpenPort 2.0 this session talks through, or nil with a KKL cable. Use it only
    /// inside `run`, so it is not spoken to from two places at once.
    public let openPort: OpenPort?

    private let line: SSMLine
    private let queue = DispatchQueue(label: "subiescope.ssm.io", qos: .userInitiated)
    private var plan: PollPlan?
    private var pollGeneration = 0
    private var consecutiveErrors = 0

    /// `openPort` says the port is a Tactrix OpenPort 2.0 (experimental) instead of a KKL cable.
    public init(portPath: String, baudRate: UInt32 = 4800, openPort: Bool = false) {
        self.portPath = portPath
        let line: SSMLine
        if openPort {
            let device = OpenPort(path: portPath)
            self.openPort = device
            line = OpenPortKLine(device: device)
        } else {
            self.openPort = nil
            line = SerialPort(path: portPath)
        }
        self.line = line
        self.transport = SSMTransport(line: line, baudRate: baudRate)
        self.client = SSMClient(transport: transport)
    }

    deinit {
        line.close()
    }

    /// Opens the port and identifies the ECU, retrying a few times because the
    /// first request after plugging in is sometimes lost.
    public func connect(attempts: Int = 3) async throws -> ECUIdentity {
        try await run { [self] client in
            if !line.isOpen {
                try line.open(baud: transport.baudRate)
                // Let the transceiver settle after DTR/RTS came up.
                Thread.sleep(forTimeInterval: 0.1)
            }
            var lastError: Error = SSMError.timeout(command: SSMCommand.initECU, receivedBytes: 0, sawEcho: false)
            for attempt in 0..<attempts {
                do {
                    let id = try client.identify()
                    identity = id
                    return id
                } catch let error as SerialError {
                    throw error
                } catch {
                    lastError = error
                    if attempt < attempts - 1 { Thread.sleep(forTimeInterval: 0.3) }
                }
            }
            // An OpenPort measures the car's battery, which tells a silent ECU from a cable that is
            // not plugged into the car.
            if let openPort, case SSMError.timeout = lastError, let volts = try? openPort.batteryVoltage(), volts < 6 {
                throw OpenPortError.noCarPower(volts: volts)
            }
            throw lastError
        }
    }

    /// Runs `work` on the I/O queue between polls. A running fast-poll stream is
    /// stopped first; polling restarts it on its next round.
    public func run<T>(_ work: @escaping (SSMClient) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                stopStreaming()
                continuation.resume(with: Result { try work(client) })
            }
        }
    }

    public func close() {
        queue.async { [self] in
            pollGeneration += 1
            plan = nil
            stopStreaming()
            line.close()
        }
    }

    // MARK: Polling

    /// Fast poll: the ECU keeps answering one 0xA8 request by itself, so only
    /// replies travel over the wire. Roughly doubles the sample rate at 4800 baud.
    public var fastPoll = true

    /// Addresses the ECU is currently streaming, if in continuous mode.
    private var streaming: [UInt32]?
    private var streamRequest: SSMPacket?

    private func stopStreaming() {
        guard streaming != nil else { return }
        transport.stopContinuous()
        streaming = nil
        streamRequest = nil
    }

    /// `conversionFor` picks the units a bare dependency reference (P8 rather than [P8:rpm]) is read in.
    public func startPolling(items: [PollItem], allParameters: [String: ParameterDefinition],
                             conversionFor: @escaping (ParameterDefinition) -> Conversion? = { $0.conversions.first },
                             onSample: @escaping @Sendable (Sample) -> Void,
                             onError: @escaping @Sendable (Error, _ fatal: Bool) -> Void) {
        queue.async { [self] in
            pollGeneration += 1
            consecutiveErrors = 0
            stopStreaming()
            let newPlan = PollPlan(items: items, allParameters: allParameters, conversionFor: conversionFor)
            guard !newPlan.addresses.isEmpty else {
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
            stopStreaming()
        }
    }

    private func readOnce(_ addresses: [UInt32]) throws -> [UInt8] {
        let canStream = fastPoll && addresses.count <= client.maxAddressesPerRequest
        guard canStream else { return try client.read(addresses: addresses) }
        if streaming == addresses, let request = streamRequest {
            // Nothing to send: wait for the next frame of the stream.
            let timeout = transport.wireTime(addresses.count + 6) * 3 + transport.responseTimeout
            let frame = try transport.receive(replyTo: request, expectedDataLength: addresses.count + 1, timeout: timeout)
            return Array(frame.payload)
        }
        stopStreaming()
        let request = SSMPacket.readAddressesRequest(addresses, continuous: true)
        let frame = try transport.exchange(request, expectedDataLength: addresses.count + 1)
        streaming = addresses
        streamRequest = request
        return Array(frame.payload)
    }

    private func poll(generation: Int, onSample: @escaping @Sendable (Sample) -> Void,
                      onError: @escaping @Sendable (Error, Bool) -> Void) {
        guard generation == pollGeneration, let plan else { return }
        let started = Date()
        do {
            let bytes = try readOnce(plan.addresses)
            let values = plan.evaluate(bytes)
            consecutiveErrors = 0
            onSample(Sample(time: started, values: values, roundTrip: Date().timeIntervalSince(started)))
        } catch {
            consecutiveErrors += 1
            // Start over with a fresh request after a hiccup in the stream.
            stopStreaming()
            let fatal = error is SerialError || consecutiveErrors >= 5
            onError(error, fatal)
            if fatal {
                pollGeneration += 1
                self.plan = nil
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        queue.async { self.poll(generation: generation, onSample: onSample, onError: onError) }
    }
}

/// Precomputed address list and decoding for a set of parameters.
struct PollPlan {
    struct Entry {
        var parameter: ParameterDefinition
        var conversion: Conversion
        var byteIndices: [Int]
        var expression: Expression?
        var output: Bool
    }

    var addresses: [UInt32] = []
    var entries: [Entry] = []
    /// Calculated parameters, in dependency order.
    var calculated: [(item: PollItem, expression: Expression?, bindings: [String: (id: String, units: String?)])] = []
    private var dependencyConversions: [String: Entry] = [:]

    init(items: [PollItem], allParameters: [String: ParameterDefinition],
         conversionFor: (ParameterDefinition) -> Conversion? = { $0.conversions.first }) {
        var addressIndex: [UInt32: Int] = [:]
        func index(for address: UInt32) -> Int {
            if let i = addressIndex[address] { return i }
            addresses.append(address)
            addressIndex[address] = addresses.count - 1
            return addresses.count - 1
        }
        func addReadable(_ parameter: ParameterDefinition, _ conversion: Conversion, output: Bool) {
            let indices = parameter.addresses.map(index(for:))
            let entry = Entry(parameter: parameter, conversion: conversion, byteIndices: indices,
                              expression: try? Expression(conversion.expression), output: output)
            entries.append(entry)
        }

        let outputIDs = Set(items.map { $0.parameter.id + "|" + $0.conversion.units })
        // A separate gauge is not read from the ECU: its reading is added to the samples afterwards.
        for item in items where item.parameter.kind != .calculated && item.parameter.kind != .external {
            addReadable(item.parameter, item.conversion, output: true)
        }
        for item in items where item.parameter.kind == .calculated {
            let expression = try? Expression(item.conversion.expression)
            var bindings: [String: (id: String, units: String?)] = [:]
            for variable in expression?.variables ?? [] {
                let binding = Self.parseReference(variable)
                bindings[variable] = binding
                guard let dependency = allParameters[binding.id], dependency.kind != .calculated else { continue }
                let conversion = binding.units.flatMap { units in dependency.conversions.first { $0.units == units } }
                    ?? conversionFor(dependency)
                guard let conversion else { continue }
                let key = dependency.id + "|" + conversion.units
                if !outputIDs.contains(key) && !entries.contains(where: { $0.parameter.id == dependency.id && $0.conversion.units == conversion.units }) {
                    addReadable(dependency, conversion, output: false)
                }
            }
            calculated.append((item, expression, bindings))
        }
    }

    /// "[P8:rpm]" -> ("P8", "rpm"); "P8" -> ("P8", nil)
    static func parseReference(_ variable: String) -> (id: String, units: String?) {
        var name = variable
        if name.hasPrefix("[") && name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : nil)
    }

    func evaluate(_ bytes: [UInt8]) -> [String: Double] {
        var values: [String: Double] = [:]
        var byUnits: [String: Double] = [:]
        for entry in entries {
            guard entry.byteIndices.allSatisfy({ $0 < bytes.count }) else { continue }
            let raw = entry.parameter.rawValue(from: ArraySlice(entry.byteIndices.map { bytes[$0] }), conversion: entry.conversion)
            let value: Double
            if entry.parameter.kind == .switchBit || entry.parameter.bit != nil && entry.expression == nil {
                value = raw
            } else {
                value = entry.expression?.evaluate(x: raw) ?? raw
            }
            byUnits[entry.parameter.id + "|" + entry.conversion.units] = value
            // Bare references use the conversion chosen for the parameter itself.
            if entry.output || byUnits[entry.parameter.id] == nil { byUnits[entry.parameter.id] = value }
            if entry.output { values[entry.parameter.id] = value }
        }
        for calc in calculated {
            var vars: [String: Double] = [:]
            for (variable, binding) in calc.bindings {
                if let units = binding.units, let v = byUnits[binding.id + "|" + units] {
                    vars[variable] = v
                } else {
                    vars[variable] = byUnits[binding.id] ?? values[binding.id] ?? .nan
                }
            }
            let value = calc.expression?.evaluate(vars) ?? .nan
            values[calc.item.parameter.id] = value
            byUnits[calc.item.parameter.id] = value
        }
        return values
    }
}
