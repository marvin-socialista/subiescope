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
    /// SSM runs over the OpenPort's CAN side instead of its K-line (experimental).
    public let overCAN: Bool
    /// Called when the ECU turns out to refuse some of the values being polled (it says so over CAN):
    /// the parameters' IDs. They are left out from then on, so the rest keeps coming.
    public var onRefused: (@Sendable ([String]) -> Void)?

    private let line: SSMLine
    private let queue = DispatchQueue(label: "subiescope.ssm.io", qos: .userInitiated)
    private var plan: PollPlan?
    private var pollGeneration = 0
    private var consecutiveErrors = 0

    /// `openPort` says the port is a Tactrix OpenPort 2.0 instead of a KKL cable.
    /// `overCAN` makes that cable talk to the ECU over CAN instead of the K-line.
    public init(portPath: String, baudRate: UInt32 = 4800, openPort: Bool = false, overCAN: Bool = false) {
        self.portPath = portPath
        self.overCAN = openPort && overCAN
        let line: SSMLine
        if openPort {
            let device = OpenPort(path: portPath)
            self.openPort = device
            line = overCAN ? OpenPortCANLine(device: device) : OpenPortKLine(device: device)
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
            let silent: Bool
            switch lastError {
            case SSMError.timeout, OpenPortError.busSilent: silent = true
            default: silent = false
            }
            if let openPort, silent, let volts = try? openPort.batteryVoltage(), volts < 6 {
                throw OpenPortError.noCarPower(volts: volts)
            }
            // An older car has no CAN on its diagnostic plug, and says nothing there.
            if overCAN, silent { throw OpenPortError.noSSMOnCAN }
            if overCAN, case SSMError.refused = lastError { throw OpenPortError.ssmRefusedOnCAN }
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

    /// Reads the freeze frame (OBD-II service 02) through the OpenPort's CAN side, between two polls.
    /// The engine ECU is asked on CAN whichever line SSM itself uses. Nil without an OpenPort, and
    /// when the ECU has no frame stored; throws when nothing answers on CAN (an older car has none
    /// on its diagnostic plug).
    public func readFreezeFrame() async throws -> FreezeFrame? {
        guard let cable = openPort else { return nil }
        return try await run { _ in
            let transport = OpenPortISOTPTransport(device: cable)
            // SSM over CAN already has the channel open, with the filter this needs.
            let borrowed = cable.isChannelOpen(OpenPortWire.Channel.isoTP)
            if !borrowed { try transport.open() }
            defer { if !borrowed { transport.close() } }
            return try FreezeFrame.read(from: transport)
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

    /// Like `close`, but only returns once the ECU's stream has been stopped and the line let go. For
    /// a program that ends right afterwards, which would otherwise leave the ECU streaming.
    public func closeAndWait() {
        queue.sync { [self] in
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
    /// The most addresses a stream is started with. It drops when the ECU turns out not to
    /// answer a request that long (see `readOnce`).
    private var streamLimit = SSMClient.maxAddressesPerStream

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
            reportedRefused.removeAll()
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
        let canStream = fastPoll && line.supportsContinuous && addresses.count <= streamLimit
        guard canStream else { return try client.read(addresses: addresses) }
        if streaming == addresses, let request = streamRequest {
            // Nothing to send: wait for the next frame of the stream.
            let timeout = transport.wireTime(addresses.count + 6) * 3 + transport.responseTimeout
            let frame = try transport.receive(replyTo: request, expectedDataLength: addresses.count + 1, timeout: timeout)
            return Array(frame.payload)
        }
        stopStreaming()
        let request = SSMPacket.readAddressesRequest(addresses, continuous: true)
        let frame: SSMPacket
        do {
            frame = try transport.exchange(request, expectedDataLength: addresses.count + 1)
        } catch SSMError.timeout where addresses.count > client.maxAddressesPerRequest {
            // An ECU stays silent when a request is too long for it, and how long that is
            // differs per ECU. If it does answer the same addresses in smaller requests, the
            // length was the problem: stop streaming this many for the rest of the session.
            transport.stopContinuous()
            let bytes = try client.read(addresses: addresses)
            streamLimit = addresses.count - 1
            return bytes
        }
        streaming = addresses
        streamRequest = request
        return Array(frame.payload)
    }

    /// Addresses the ECU refuses to read. They are left out of every later request.
    private var refusedAddresses: Set<UInt32> = []
    /// The parameters `onRefused` was already told about for the values being polled now.
    private var reportedRefused: Set<String> = []

    /// One round of the plan's addresses, without the ones the ECU refuses: their places are filled
    /// with zeros and named in `missing`.
    private func readAllowed(_ plan: PollPlan) throws -> (bytes: [UInt8], missing: Set<Int>) {
        guard !refusedAddresses.isEmpty else { return (try readOnce(plan.addresses), []) }
        let allowed = plan.addresses.filter { !refusedAddresses.contains($0) }
        var read: ArraySlice<UInt8> = []
        if !allowed.isEmpty { read = try readOnce(allowed)[...] }
        var bytes: [UInt8] = []
        var missing: Set<Int> = []
        for (index, address) in plan.addresses.enumerated() {
            if refusedAddresses.contains(address) {
                bytes.append(0)
                missing.insert(index)
            } else {
                bytes.append(read.popFirst() ?? 0)
            }
        }
        return (bytes, missing)
    }

    /// The ECU refused a request for several values at once. Asking for each parameter by itself
    /// shows which ones it will not give. Returns false when it refuses none of them alone.
    private func sortOutRefused(_ plan: PollPlan) throws -> Bool {
        var found = false
        for entry in plan.entries where !entry.parameter.addresses.allSatisfy(refusedAddresses.contains) {
            do {
                _ = try client.read(addresses: entry.parameter.addresses)
            } catch SSMError.refused {
                refusedAddresses.formUnion(entry.parameter.addresses)
                found = true
            }
        }
        return found
    }

    /// Tells `onRefused` once which of the chosen parameters the ECU does not give: the ones read
    /// from a refused address, and the calculated ones that need such a value. A value that is only
    /// read for a calculation is not named by itself.
    private func reportRefused(_ plan: PollPlan) {
        let refused = Set(plan.entries.filter { $0.parameter.addresses.contains(where: refusedAddresses.contains) }.map(\.parameter.id))
        var ids: [String] = []
        for entry in plan.entries where entry.output && refused.contains(entry.parameter.id) && !ids.contains(entry.parameter.id) {
            ids.append(entry.parameter.id)
        }
        for calculated in plan.calculated where calculated.bindings.values.contains(where: { refused.contains($0.id) }) {
            if !ids.contains(calculated.item.parameter.id) { ids.append(calculated.item.parameter.id) }
        }
        let new = Set(ids).subtracting(reportedRefused)
        guard !new.isEmpty else { return }
        reportedRefused.formUnion(new)
        onRefused?(ids)
    }

    private func poll(generation: Int, onSample: @escaping @Sendable (Sample) -> Void,
                      onError: @escaping @Sendable (Error, Bool) -> Void) {
        guard generation == pollGeneration, let plan else { return }
        let started = Date()
        do {
            let round: (bytes: [UInt8], missing: Set<Int>)
            do {
                round = try readAllowed(plan)
            } catch let refusal as SSMError {
                guard case .refused = refusal, try sortOutRefused(plan) else { throw refusal }
                round = try readAllowed(plan)
            }
            if !round.missing.isEmpty { reportRefused(plan) }
            let values = plan.evaluate(round.bytes, missing: round.missing)
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

    /// `missing` names the places in `bytes` that hold no reading (the ECU refuses those addresses):
    /// what is read from them gets no value.
    func evaluate(_ bytes: [UInt8], missing: Set<Int> = []) -> [String: Double] {
        var values: [String: Double] = [:]
        var byUnits: [String: Double] = [:]
        for entry in entries {
            guard entry.byteIndices.allSatisfy({ $0 < bytes.count && !missing.contains($0) }) else { continue }
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
