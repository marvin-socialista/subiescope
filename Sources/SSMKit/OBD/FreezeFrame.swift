import Foundation

/// Whatever can put one OBD-II request to the car: an ELM327 adapter, or a Tactrix OpenPort's CAN side.
public protocol OBDRequester {
    /// Sends one request and returns every answer to it, each from its service byte on
    /// (`42 0C 00 1A F8`). Empty when the car has nothing to say to the request.
    func answers(toOBD request: [UInt8]) throws -> [[UInt8]]
}

/// The freeze frame: what the engine was doing at the moment the ECU stored a trouble code (OBD-II
/// service 02). The ECU keeps one, for the code that came first or matters most, until the codes are
/// cleared. It tells whether the fault showed up cold or warm, at idle or under load.
public struct FreezeFrame: Equatable, Sendable {
    /// One value as the ECU kept it: the same bytes service 01 gives for a live value.
    public struct Reading: Equatable, Sendable {
        public var pid: UInt8
        public var data: [UInt8]

        public init(pid: UInt8, data: [UInt8]) {
            self.pid = pid
            self.data = data
        }
    }

    /// A reading in words: "Engine Speed", "2350 rpm".
    public struct Line: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var value: String
        /// What the value is, for someone who does not know it.
        public var description: String
    }

    /// The trouble code the ECU kept the values for, e.g. "P0420".
    public var code: String
    public var readings: [Reading]

    public init(code: String, readings: [Reading]) {
        self.code = code
        self.readings = readings
    }

    /// The line under the heading "Freeze frame", wherever one is shown.
    public var summary: String { "What the engine was doing at the moment the ECU stored \(code)" }

    /// The readings in words, in the units `conversion` picks (the first ones a value has when it
    /// returns nil), written the way `units` writes them ("°C" for "C").
    public func lines(conversion: (OBDPID) -> Conversion? = { _ in nil },
                      units: (Conversion) -> String = { $0.units }) -> [Line] {
        readings.compactMap { reading in
            guard let pid = OBDParameters.byPID[reading.pid], let raw = pid.raw(from: reading.data) else { return nil }
            if reading.pid == 0x03 {
                return Line(id: pid.id, name: pid.name, value: Self.fuelSystemStatus(reading.data[0]),
                            description: "How the ECU was controlling the mixture.")
            }
            guard let conversion = conversion(pid) ?? pid.conversions.first,
                  let value = (try? Expression(conversion.expression))?.evaluate(x: raw), value.isFinite else { return nil }
            return Line(id: pid.id, name: pid.name, value: "\(conversion.formatted(value)) \(units(conversion))",
                        description: pid.description)
        }
    }

    /// What the first byte of "fuel system status" means.
    static func fuelSystemStatus(_ status: UInt8) -> String {
        switch status {
        case 1: return "Open loop: the engine was not warm enough yet"
        case 2: return "Closed loop: steering on the oxygen sensor (normal)"
        case 4: return "Open loop: under load, or coasting with the fuel cut"
        case 8: return "Open loop: because of a fault"
        case 16: return "Closed loop, but with a fault in the oxygen sensor feedback"
        default: return "Unknown (\(status))"
        }
    }

    // MARK: Reading

    /// The order the values are asked for and shown in: how the car was being driven first, then what
    /// the engine made of it. The rest follows by number.
    static let order: [UInt8] = [0x0C, 0x0D, 0x04, 0x11, 0x05, 0x0F, 0x0B, 0x10, 0x03, 0x06, 0x07, 0x08, 0x09, 0x0E]

    /// Reads the freeze frame. Returns nil when the ECU has none stored, which is the normal case
    /// for a car without stored trouble codes.
    public static func read(from car: OBDRequester) throws -> FreezeFrame? {
        // Value 02 of the frame is the trouble code it belongs to. No code: no frame.
        let codes = try car.answers(toOBD: [0x02, 0x02, 0x00]).compactMap { answer -> String? in
            guard answer.count >= 5, answer[0] == 0x42, answer[1] == 0x02, answer[3] != 0 || answer[4] != 0 else { return nil }
            return ELM327.troubleCode(answer[3], answer[4])
        }
        guard let code = codes.first else { return nil }

        // Which values the frame holds: the same lists of 32 that service 01 has.
        var held: Set<UInt8> = []
        var base: UInt8 = 0x00
        while let mask = try? data(of: base, from: car), mask.count >= 4 {
            let list = OBDParameters.supportedPIDs(base: base, mask: mask)
            held.formUnion(list)
            guard list.contains(base &+ 0x20), base < 0xE0 else { break }
            base += 0x20
        }
        let known = Set(OBDParameters.catalog.map(\.pid))
        // A car that does not say what its frame holds is asked for the usual values.
        let wanted = held.isEmpty ? Set(order) : held.intersection(known)
        let sorted = order.filter(wanted.contains) + wanted.subtracting(order).sorted()

        var readings: [Reading] = []
        var failures = 0
        for pid in sorted {
            do {
                if let data = try data(of: pid, from: car), !data.isEmpty {
                    readings.append(Reading(pid: pid, data: data))
                }
                failures = 0
            } catch {
                // One value that fails should not cost the others. Two in a row is a link that is
                // gone, and waiting for every value in turn would hold everything else up.
                failures += 1
                if failures >= 2 { throw error }
            }
        }
        return FreezeFrame(code: code, readings: readings)
    }

    /// The data bytes of one value of frame 0: the request is `02`, the value, the frame number.
    private static func data(of pid: UInt8, from car: OBDRequester) throws -> [UInt8]? {
        for answer in try car.answers(toOBD: [0x02, pid, 0x00]) where answer.count > 3 && answer[0] == 0x42 && answer[1] == pid {
            return Array(answer.dropFirst(3))
        }
        return nil
    }
}

extension ELM327: OBDRequester {
    public func answers(toOBD request: [UInt8]) throws -> [[UInt8]] {
        guard let service = request.first else { return [] }
        let lines = try send(request.map { String(format: "%02X", $0) }.joined())
        if Self.isNoData(lines) { return [] }
        if let error = Self.errorText(in: lines) { throw OBDError.adapterError(error) }
        return Self.messages(from: lines).filter { $0.first == service &+ 0x40 }
    }
}

extension OpenPortISOTPTransport: OBDRequester {
    /// The engine ECU's answer, or nothing when it says no or stays silent.
    public func answers(toOBD request: [UInt8]) throws -> [[UInt8]] {
        guard let service = request.first else { return [] }
        do {
            let reply = try self.request(request, timeout: 1)
            return reply.first == service &+ 0x40 ? [reply] : []
        } catch OpenPortError.noAnswer {
            return []
        }
    }
}
