import Foundation

/// A software ELM327 adapter with a car behind it: what the Vgate iCar Pro and its
/// cheap cousins do, without any hardware. It answers AT commands and OBD-II
/// requests from the same simulated engine the SSM demo car uses, so the OBD mode
/// can be developed, tested and demonstrated without a car.
public final class SimulatedELM: ELMChannel, @unchecked Sendable {
    public struct Car: Sendable {
        public var name = "Demo car: a newer Subaru WRX"
        public var vin = "JF1VA1A6XG9800001"
        public var confirmedCodes: [String] = ["P0420"]
        public var pendingCodes: [String] = ["P0171"]
        /// The code the ECU kept a freeze frame for: the first confirmed one, as long as it is stored.
        public var freezeFrameCode: String? { confirmedCodes.first }
        /// Multi-frame (CAN) replies for VIN and codes, the way 2008+ cars answer.
        public var usesCAN = true
        public var supported: Set<UInt8> = [
            0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x14, 0x15, 0x1F, 0x24, 0x2F, 0x33,
            0x42, 0x43, 0x44, 0x46, 0x49, 0x5C,
        ]
        public init() {}
    }

    public var car: Car {
        get { lock.lock(); defer { lock.unlock() }; return _car }
        set { lock.lock(); _car = newValue; lock.unlock() }
    }

    public let world: DemoWorld
    /// Time an ELM327 needs per request on the bus, so the demo runs at a realistic rate.
    public var latency: TimeInterval
    /// Delay for the very first request, when a real adapter searches for the protocol.
    public var searchDelay: TimeInterval
    /// A dead ignition: the adapter answers, the car does not.
    public var ignitionOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _ignitionOn }
        set { lock.lock(); _ignitionOn = newValue; lock.unlock() }
    }
    /// Rejects the shorter "0100" + reply count form, like some clones do.
    public var acceptsReplyCount = true

    /// How the adapter and car handle a request for several values at once.
    public enum BatchBehavior: Sendable { case full, firstOnly, rejected }
    public var batchBehavior: BatchBehavior = .full
    /// Values the car lists as supported but does not answer (a sensor that is off right now).
    public var silentPIDs: Set<UInt8> = []
    /// The car does not answer the second list of supported values (PIDs 21 and up).
    public var failsSecondSupportRange = false

    /// Mode 22 values: what the ECU at a header (e.g. "7A2") answers for an identifier. nil means silence.
    public var extendedResponder: (@Sendable (_ header: String, _ did: UInt16) -> [UInt8]?)?
    /// Identifiers answered with "not supported" (7F 22 31): the ECU speaks Mode 22 but lacks the value.
    public var extendedNegativeDIDs: Set<UInt16> = []
    private var currentHeader = "7DF"

    private let lock = NSLock()
    private var _car: Car
    private var _ignitionOn = true
    private let start = Date()
    private var echo = true
    private var spaces = true
    private var connected = false
    private var closed = false

    public init(car: Car = Car(), world: DemoWorld = DemoWorld(), latency: TimeInterval = 0.03, searchDelay: TimeInterval = 0.4) {
        self._car = car
        self.world = world
        self.latency = latency
        self.searchDelay = searchDelay
    }

    public func close() {
        lock.lock(); closed = true; lock.unlock()
    }

    /// The four bytes an ECU answers for one of its "supported" lists (1000, 1020 ...): one bit for each of the
    /// 32 identifiers after `base`, the last one set when another list follows.
    public static func supportList(base: UInt16, of dids: Set<UInt16>, lastList: UInt16) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: 4)
        for bit in 0..<32 where dids.contains(base + 1 + UInt16(bit)) { mask[bit / 8] |= 0x80 >> UInt8(bit % 8) }
        if base < lastList { mask[3] |= 0x01 }
        return mask
    }

    /// Makes the demo car answer a few extended (Mode 22) values like a newer Subaru does: intake VVT (AVCS)
    /// angles, primary boost control, the A/F sensor and the knocking signal, moving with the demo drive.
    /// It also lists them as supported and reports its ROM ID.
    public func enableDemoExtended() {
        let start = self.start
        let world = self.world
        let values: Set<UInt16> = [0x10B4, 0x10B5, 0x10AC, 0x10BE, 0x11D0]
        extendedResponder = { header, did in
            guard header == "7A2" else { return nil }
            if did == 0xF182 { return DemoECU.identity.romID }
            if did % 0x20 == 0, (0x1000...0x11C0).contains(did) { return Self.supportList(base: did, of: values, lastList: 0x11C0) }
            let w = world.sample(at: Date().timeIntervalSince(start))
            let load = min(1, max(0, (w["load"] ?? 0) / 40))
            let rpm = w["rpm"] ?? 800
            switch did {
            case 0x10B4: return [UInt8(max(0, min(255, 50 + load * 22 * min(1, rpm / 3000))))]         // intake VVT right
            case 0x10B5: return [UInt8(max(0, min(255, 50 + load * 21 * min(1, rpm / 3000))))]         // intake VVT left
            case 0x10AC: return [UInt8(max(0, min(255, (w["wgdc"] ?? 0) * 51 / 20)))]                   // primary boost control
            case 0x10BE: return [UInt8(max(0, min(255, (w["lambda"] ?? 1) * 255 / 1.99)))]              // A/F sensor #1
            case 0x11D0: return [UInt8(max(0, min(255, abs(w["fbkc"] ?? 0) * 8)))]                      // knocking signal
            default: return nil
            }
        }
    }

    public func exchange(_ command: String, timeout: TimeInterval) throws -> String {
        lock.lock()
        if closed { lock.unlock(); throw OBDError.disconnected }
        lock.unlock()
        let text = command.uppercased().filter { !$0.isWhitespace }
        Thread.sleep(forTimeInterval: latency)
        let reply = respond(to: text)
        return (echo ? command + "\r" : "") + reply
    }

    // MARK: Adapter

    private func respond(to command: String) -> String {
        if command.isEmpty { return "" }
        if command.hasPrefix("AT") { return atCommand(String(command.dropFirst(2))) }
        // A trailing hex digit after a full request is the expected reply count ("010C1").
        var hex = command
        if command.count % 2 == 1 {
            guard acceptsReplyCount else { return "?\r" }
            hex = String(command.dropLast())
        }
        let request = ELM327.hexBytes(of: hex)
        guard !request.isEmpty else { return "?\r" }
        if request.count >= 3 && request[0] == 0x22 { return extended(did: UInt16(request[1]) << 8 | UInt16(request[2])) }
        return obd(request)
    }

    private func extended(did: UInt16) -> String {
        guard ignitionOn, let responder = extendedResponder else { return "NO DATA\r" }
        if let data = responder(currentHeader, did) {
            let message = [0x62, UInt8(did >> 8), UInt8(did & 0xFF)] + data
            return frames(message)
        }
        if extendedNegativeDIDs.contains(did), currentHeader != "7DF" { return line([0x7F, 0x22, 0x31]) + "\r" }
        return "NO DATA\r"
    }

    private func atCommand(_ command: String) -> String {
        switch command {
        case "Z":
            echo = true; spaces = true; connected = false
            return "\r\rELM327 v2.3\r\r"
        case "I": return "ELM327 v2.3\r"
        case "E0": echo = false; return "OK\r"
        case "E1": echo = true; return "OK\r"
        case "S0": spaces = false; return "OK\r"
        case "S1": spaces = true; return "OK\r"
        case _ where command.hasPrefix("SH"):
            currentHeader = String(command.dropFirst(2)); return "OK\r"
        case "AR": currentHeader = "7DF"; return "OK\r"
        case "DP": return "AUTO, " + (car.usesCAN ? "ISO 15765-4 (CAN 11/500)" : "ISO 9141-2") + "\r"
        case "RV": return "12.6V\r"
        default: return "OK\r"
        }
    }

    private func line(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: spaces ? " " : "")
    }

    private func obd(_ request: [UInt8]) -> String {
        guard ignitionOn else {
            return connected ? "NO DATA\r" : "UNABLE TO CONNECT\r"
        }
        var prefix = ""
        if !connected {
            Thread.sleep(forTimeInterval: searchDelay)
            connected = true
            prefix = "SEARCHING...\r"
        }
        let mode = request[0]
        switch mode {
        case 0x01 where request.count > 2:
            switch batchBehavior {
            case .rejected: return prefix + "?\r"
            case .firstOnly:
                guard let data = pidData(request[1]) else { return prefix + "NO DATA\r" }
                return prefix + line([0x41, request[1]] + data) + "\r"
            case .full:
                var message: [UInt8] = [0x41]
                for pid in request.dropFirst() {
                    if let data = pidData(pid) { message += [pid] + data }
                }
                return prefix + (message.count > 1 ? frames(message) : "NO DATA\r")
            }
        case 0x01 where request.count == 2:
            guard let data = pidData(request[1]) else { return prefix + "NO DATA\r" }
            return prefix + line([0x41, request[1]] + data) + "\r"
        case 0x02:
            guard let answer = DemoFreezeFrame.answer(to: request, code: car.freezeFrameCode) else { return prefix + "NO DATA\r" }
            return prefix + line(answer) + "\r"
        case 0x03: return prefix + codes(car.confirmedCodes, response: 0x43)
        case 0x07: return prefix + codes(car.pendingCodes, response: 0x47)
        case 0x0A: return prefix + "NO DATA\r"
        case 0x04:
            var c = car
            c.confirmedCodes = []
            c.pendingCodes = []
            car = c
            return prefix + line([0x44]) + "\r"
        case 0x09 where request.count >= 2 && request[1] == 0x02:
            return prefix + vin()
        default:
            return prefix + "NO DATA\r"
        }
    }

    // MARK: Trouble codes and VIN

    static func codeBytes(_ code: String) -> [UInt8] {
        let letters = ["P": 0, "C": 1, "B": 2, "U": 3]
        guard code.count == 5, let type = letters[String(code.first!)], let value = UInt16(code.dropFirst(), radix: 16) else { return [0, 0] }
        return [UInt8(type << 6) | UInt8((value >> 8) & 0x3F), UInt8(value & 0xFF)]
    }

    private func codes(_ list: [String], response: UInt8) -> String {
        if list.isEmpty { return car.usesCAN ? line([response, 0x00]) + "\r" : line([response, 0, 0, 0, 0, 0, 0]) + "\r" }
        let pairs = list.flatMap(Self.codeBytes)
        if car.usesCAN {
            let message = [response, UInt8(list.count)] + pairs
            return frames(message)
        }
        // Older buses: three codes per line, padded, no count byte.
        var out = ""
        for chunk in stride(from: 0, to: pairs.count, by: 6) {
            var slice = Array(pairs[chunk..<min(chunk + 6, pairs.count)])
            slice += [UInt8](repeating: 0, count: 6 - slice.count)
            out += line([response] + slice) + "\r"
        }
        return out
    }

    private func vin() -> String {
        frames([0x49, 0x02, 0x01] + Array(car.vin.utf8))
    }

    /// Formats a message the way an ELM327 prints it: one line when it fits a CAN frame, else
    /// a byte count and numbered frames (first frame 6 bytes, then 7 per frame, padded).
    private func frames(_ message: [UInt8]) -> String {
        if message.count <= 7 { return line(message) + "\r" }
        var out = String(format: "%03X", message.count) + "\r"
        var index = 0
        var number = 0
        var size = 6
        while index < message.count {
            var slice = Array(message[index..<min(index + size, message.count)])
            if slice.count < size { slice += [UInt8](repeating: 0, count: size - slice.count) }
            out += "\(number): " + line(slice) + "\r"
            index += size
            number = (number + 1) % 16
            size = 7
        }
        return out
    }

    // MARK: Values

    private func supportBitmask(base: UInt8) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: 4)
        let supported = car.supported.union(car.supported.contains(where: { $0 > 0x20 }) ? [0x20] : [])
            .union(car.supported.contains(where: { $0 > 0x40 }) ? [0x40] : [])
        for pid in supported where Int(pid) > Int(base) && Int(pid) <= Int(base) + 0x20 {
            let offset = Int(pid) - Int(base) - 1
            mask[offset / 8] |= 0x80 >> UInt8(offset % 8)
        }
        return mask
    }

    private func pidData(_ pid: UInt8) -> [UInt8]? {
        if pid % 0x20 == 0 {
            if pid > 0 && failsSecondSupportRange { return nil }
            return supportBitmask(base: pid)
        }
        guard car.supported.contains(pid), !silentPIDs.contains(pid) else { return nil }
        return Self.encode(pid, world: world.sample(at: Date().timeIntervalSince(start)), runTime: Date().timeIntervalSince(start))
    }

    /// The bytes a car answers for one value, given what its engine is doing (`w`, a `DemoWorld` sample).
    static func encode(_ pid: UInt8, world w: [String: Double], runTime: TimeInterval) -> [UInt8]? {
        func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        func word(_ v: Double) -> [UInt8] {
            let n = UInt16(max(0, min(65535, v.rounded())))
            return [UInt8(n >> 8), UInt8(n & 0xFF)]
        }
        switch pid {
        case 0x04: return [byte((w["load"] ?? 0) * 255 / 100 * 2)]
        case 0x05: return [byte((w["coolant"] ?? 20) + 40)]
        case 0x06: return [byte(128 + (w["afc"] ?? 0) * 128 / 100)]
        case 0x07: return [byte(128 + (w["afl"] ?? 0) * 128 / 100)]
        case 0x0B: return [byte(w["map"] ?? 101)]
        case 0x0C: return word((w["rpm"] ?? 0) * 4)
        case 0x0D: return [byte(w["speed"] ?? 0)]
        case 0x0E: return [byte(((w["timing"] ?? 0) + 64) * 2)]
        case 0x0F: return [byte((w["iat"] ?? 20) + 40)]
        case 0x10: return word((w["maf"] ?? 0) * 100)
        case 0x11: return [byte((w["throttle"] ?? 0) * 255 / 100)]
        case 0x14: return [byte(((w["lambda"] ?? 1) < 1 ? 0.8 : 0.2) * 200), 0xFF]
        case 0x15: return [byte((w["rearO2"] ?? 0.65) * 200), 0xFF]
        case 0x1F: return word(runTime)
        case 0x24: return word((w["lambda"] ?? 1) * 32768) + word(3 * 8192 * 0.6)
        case 0x2F: return [byte(62 * 255 / 100)]
        case 0x33: return [101]
        case 0x42: return word((w["battery"] ?? 12.6) * 1000)
        case 0x43: return word((w["load"] ?? 0) * 255 / 100 * 2)
        case 0x44: return word(32768)
        case 0x46: return [byte(21 + 40)]
        case 0x49: return [byte((w["pedal"] ?? 0) * 255 / 100)]
        case 0x5C: return [byte((w["coolant"] ?? 20) + 6 + 40)]
        default: return nil
        }
    }
}
