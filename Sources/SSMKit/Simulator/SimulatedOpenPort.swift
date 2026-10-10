import CSerial
import Foundation

/// A software Tactrix OpenPort 2.0 on a pseudo terminal, so the OpenPort code can be tested, and
/// tried in the app, without the cable.
///
/// It speaks the cable's protocol as openport-j2534's notes describe it: numbered commands, text
/// replies and binary message frames. Behind its K-line sits a `VirtualECU` (the demo car); behind its
/// CAN channel sits whatever `canECU` answers. How it hands over K-line bytes from the ECU follows
/// the layout three open-source drivers agree on; that part was never measured on a real cable.
public final class SimulatedOpenPort: @unchecked Sendable {
    /// The device to open, e.g. /dev/ttys012.
    public let devicePath: String

    /// Answers a request on the CAN channel. It gets the bytes after the CAN identifier and returns
    /// the reply's bytes, or nil to stay silent.
    public var canECU: (@Sendable ([UInt8]) -> [UInt8]?)? {
        get { lock.lock(); defer { lock.unlock() }; return _canECU }
        set { lock.lock(); _canECU = newValue; lock.unlock() }
    }
    /// What pin 16 of the OBD plug measures. A cable on USB power alone reads about 140.
    public var batteryMillivolts: Int {
        get { lock.lock(); defer { lock.unlock() }; return _batteryMillivolts }
        set { lock.lock(); _batteryMillivolts = newValue; lock.unlock() }
    }
    /// When false nothing acknowledges CAN frames, as with the ignition off.
    public var canBusAlive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _canBusAlive }
        set { lock.lock(); _canBusAlive = newValue; lock.unlock() }
    }
    /// When false the cable stays silent, like a serial port that is not an OpenPort.
    public var answers: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _answers }
        set { lock.lock(); _answers = newValue; lock.unlock() }
    }
    /// Every command line received, for tests.
    public var commands: [String] {
        lock.lock(); defer { lock.unlock() }
        return _commands
    }

    public static let firmware = "1.17.4877"

    private struct Channel {
        var flags: Int
        var baud: Int
        var config: [Int: Int] = [:]
        /// Filter type by id, with the messages it was installed with.
        var filters: [Int: (type: Int, messages: [[UInt8]])] = [:]
    }

    private let lock = NSLock()
    private var _canECU: (@Sendable ([UInt8]) -> [UInt8]?)?
    private var _batteryMillivolts = 12_150
    private var _canBusAlive = true
    private var _answers = true
    private var _commands: [String] = []
    private var running = true

    private let controller: Int32
    private var device: Int32
    private let ecu: VirtualECU?
    private var ecuPort: SerialPort?
    private var channels: [Int: Channel] = [:]
    private var nextFilterID = 0
    private let started = Date()

    // J2534 return codes, as the cable reports them.
    private static let notSupported = 1, invalidProtocol = 3, failed = 7, timeout = 9, invalidMessage = 10
    private static let limit = 12, pinInvalid = 19, inUse = 20, invalidFilter = 22
    /// How many arguments each command takes. One more is the sequence number.
    private static let knownArguments: [Character: Int] = [
        "o": 3, "t": 3, "f": 3, "k": 1, "g": 1, "s": 2, "r": 1, "v": 2, "c": 0, "l": 0, "a": 0, "z": 0, "i": 0,
    ]
    private static let kLineSettings: Set<Int> = [3, 7, 10, 12, 14, 15, 16, 17, 18, 19, 20, 21, 22, 25, 32, 33]
    private static let canSettings: Set<Int> = [1, 3, 23, 24, 30, 31, 34, 35, 37]

    /// `ecu` is the car on the K-line. The cable, not the car, makes the echo, so the ECU's own is
    /// switched off.
    public init(ecu: VirtualECU? = nil) throws {
        var c: Int32 = -1
        var d: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        guard cserial_openpty(&c, &d, &name, Int32(name.count)) == 0 else {
            throw SerialError.openFailed(path: "pty", reason: String(cString: strerror(errno)))
        }
        controller = c
        device = d
        devicePath = String(cString: name)
        self.ecu = ecu
        ecu?.echoesRequests = false
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "SimulatedOpenPort"
        thread.start()
    }

    deinit {
        stop()
    }

    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        guard wasRunning else { return }
        _ = cserial_release(controller)
        if device >= 0 { _ = cserial_release(device) }
        device = -1
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    // MARK: Serving

    private func run() {
        var input: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1024)
        while isRunning {
            let ready = cserial_wait_readable(controller, ecuPort == nil ? 50 : 2)
            if ready < 0 {
                // No client has the device open right now; wait for one.
                if !isRunning { return }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            if ready > 0 {
                let n = chunk.withUnsafeMutableBytes { Int(cserial_read(controller, $0.baseAddress, Int32($0.count))) }
                if n <= 0 {
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }
                input.append(contentsOf: chunk[0..<n])
                while let (line, payload, consumed) = Self.nextCommand(in: input) {
                    input.removeFirst(consumed)
                    handle(line, payload: payload)
                }
            }
            forwardKLine()
        }
        ecuPort?.close()
    }

    /// Splits off the first command line and the binary payload it announces. Returns nil until
    /// both are complete.
    static func nextCommand(in input: [UInt8]) -> (line: String, payload: [UInt8], consumed: Int)? {
        guard let newline = input.firstIndex(of: 10) else { return nil }
        let line = String(decoding: input[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var need = 0
        if line.hasPrefix("att") || line.hasPrefix("atf") {
            let arguments = Self.arguments(String(line.dropFirst(3))).arguments
            if line.hasPrefix("att") {
                need = arguments.first.flatMap { Int($0) } ?? 0
            } else if arguments.count >= 3, let type = Int(arguments[0]), let each = Int(arguments[2]) {
                need = each * (type == 3 ? 3 : 2)
            }
        }
        let end = newline + 1 + need
        guard input.count >= end else { return nil }
        return (line, Array(input[(newline + 1)..<end]), end)
    }

    /// "6 0 500000 0 4" -> (6, ["0", "500000", "0", "4"]); the channel digit is glued to the verb.
    private static func arguments(_ rest: String) -> (channel: Int?, arguments: [String]) {
        let digits = rest.prefix { $0.isNumber }
        let arguments = rest.dropFirst(digits.count).split(separator: " ").map(String.init)
        return (Int(digits), arguments)
    }

    private func handle(_ line: String, payload: [UInt8]) {
        guard !line.isEmpty else { return }
        lock.lock()
        _commands.append(line)
        let answers = _answers
        lock.unlock()
        guard answers, line.hasPrefix("at"), line.count >= 3 else { return }   // unknown: silence
        let verb = line[line.index(line.startIndex, offsetBy: 2)]
        let rest = String(line.dropFirst(3))
        let pinVerb = verb == "r" || verb == "v"
        let (channel, arguments) = pinVerb ? (nil, rest.split(separator: " ").map(String.init)) : Self.arguments(rest)
        var sequence: Int?
        if let known = Self.knownArguments[verb], arguments.count > known { sequence = arguments.last.flatMap { Int($0) } }
        let numbers = arguments.map { Int($0) }

        func ok() { reply("aro", sequence) }
        func error(_ code: Int) { reply("are \(code)", sequence) }

        switch verb {
        case "i":
            reply("ari main code version : \(Self.firmware)", nil)
        case "a", "z":
            channels.removeAll()
            nextFilterID = 0
            ecuPort?.close()
            ecuPort = nil
            ok()
        case "o":
            guard let channel, numbers.count >= 3, let flags = numbers[0], let baud = numbers[1] else { return error(Self.failed) }
            guard (3...9).contains(channel) else { return error(Self.invalidProtocol) }
            guard channels[channel] == nil else { return error(Self.inUse) }
            // ISO 9141 and ISO 14230 share the K-line.
            if (channel == 3 && channels[4] != nil) || (channel == 4 && channels[3] != nil) { return error(Self.invalidProtocol) }
            channels[channel] = Channel(flags: flags, baud: baud)
            if channel == 3, let ecu {
                let port = SerialPort(path: ecu.devicePath)
                try? port.open(baud: UInt32(baud), parity: "N", stopBits: 1)
                ecuPort = port
            }
            ok()
        case "c":
            guard let channel else { return error(Self.failed) }
            channels[channel] = nil
            if channel == 3 {
                ecuPort?.close()
                ecuPort = nil
            }
            ok()
        case "r":
            guard let pin = numbers.first ?? nil else { return error(Self.failed) }
            guard pin == 16 else { return error(Self.pinInvalid) }
            reply("arr \(pin) \(batteryMillivolts)", sequence)
        case "s":
            guard let channel, channels[channel] != nil, numbers.count >= 2, let parameter = numbers[0], let value = numbers[1] else {
                return error(Self.failed)
            }
            guard (channel == 6 ? Self.canSettings : Self.kLineSettings).contains(parameter) else { return error(Self.notSupported) }
            channels[channel]?.config[parameter] = value
            ok()
        case "g":
            guard let channel, let open = channels[channel], let parameter = numbers.first ?? nil else { return error(Self.failed) }
            guard (channel == 6 ? Self.canSettings : Self.kLineSettings).contains(parameter) else { return error(Self.notSupported) }
            reply("arg\(channel) \(parameter) \(open.config[parameter] ?? 0) \(sequence ?? 0)", nil)
        case "f":
            guard let channel, let open = channels[channel], numbers.count >= 3, let type = numbers[0], let each = numbers[2] else {
                return error(Self.failed)
            }
            let count = type == 3 ? 3 : 2
            guard (1...3).contains(type) else { return error(Self.invalidFilter) }
            guard each > 0, payload.count == count * each else { return error(Self.invalidMessage) }
            guard open.filters.count < 10 else { return error(Self.limit) }
            let messages = (0..<count).map { Array(payload[($0 * each)..<(($0 + 1) * each)]) }
            channels[channel]?.filters[nextFilterID] = (type, messages)
            reply("arf\(channel) \(nextFilterID) \(sequence ?? 0)", nil)
            nextFilterID += 1
        case "k":
            guard let channel, channels[channel] != nil, let id = numbers.first ?? nil else { return error(Self.failed) }
            if id == -1 {
                channels[channel]?.filters.removeAll()
            } else if channels[channel]?.filters.removeValue(forKey: id) == nil {
                return error(Self.invalidFilter)
            }
            ok()
        case "t":
            transmit(channel, numbers: numbers, payload: payload, sequence: sequence)
        default:
            return   // the cable answers nothing to what it does not know
        }
    }

    private func transmit(_ channel: Int?, numbers: [Int?], payload: [UInt8], sequence: Int?) {
        guard let channel, let declared = numbers.first ?? nil else { return reply("are \(Self.failed)", sequence) }
        guard declared == payload.count else { return reply("are \(Self.invalidMessage)", sequence) }
        // The cable answers a transmit without a number with nothing at all.
        func done() { if sequence != nil { reply("aro", sequence) } }
        guard let open = channels[channel] else { return done() }
        let flags = numbers.count > 1 ? (numbers[1] ?? 0) : 0

        if channel == 3 || channel == 4 {
            if open.config[3] == 1 { sendKLine(channel, payload, loopback: true) }
            if payload.count >= 10, payload.allSatisfy({ $0 == 0 }) {
                // A run of zero bytes holds the line low nearly all the time: to the ECU that is a
                // BREAK, which a pseudo terminal cannot carry.
                ecu?.simulateBreak()
            } else if let ecuPort {
                try? ecuPort.write(payload)
            }
            return done()
        }

        guard canBusAlive else {
            // Nothing acknowledges the frame: the cable keeps trying, then gives up.
            Thread.sleep(forTimeInterval: 0.2)
            return reply("are \(Self.timeout)", sequence)
        }
        done()
        guard payload.count >= 4 else { return }
        let identifier = Array(payload.prefix(4))
        let request = Array(payload.dropFirst(4))
        frame(channel, status: 0x10, body: timestamp() + identifier)   // the transmit went out
        // A short frame that is not padded to eight bytes is ignored by a real ECU.
        if request.count < 7, flags & 0x40 == 0 { return }
        // Replies only get through a flow control filter, which also names the ECU's identifier.
        guard let filter = open.filters.values.first(where: { $0.type == 3 && $0.messages.count == 3 && $0.messages[2] == identifier }),
              let answer = canECU?(request), !answer.isEmpty else { return }
        sendCAN(channel, identifier: filter.messages[1], data: answer)
    }

    // MARK: Frames to the computer

    /// A message that fits one CAN frame is one frame marked as the end. A longer one is announced by
    /// a start frame with only the identifier, then comes in pieces that each repeat the identifier:
    /// 69 bytes first, then 70 at a time, the last one marked as the end.
    private func sendCAN(_ channel: Int, identifier: [UInt8], data: [UInt8]) {
        guard data.count > 7 else {
            return frame(channel, status: 0x40, body: timestamp() + identifier + data)
        }
        frame(channel, status: 0x80, body: timestamp() + identifier)
        var pieces: [[UInt8]] = [Array(data.prefix(69))]
        var offset = 69
        while offset < data.count {
            pieces.append(Array(data[offset..<min(offset + 70, data.count)]))
            offset += 70
        }
        for (index, piece) in pieces.enumerated() {
            frame(channel, status: index == pieces.count - 1 ? 0x40 : 0x00, body: timestamp() + identifier + piece)
        }
    }

    /// K-line bytes come between a start and an end frame that carry only a timestamp. The frames
    /// with the bytes themselves have no timestamp.
    private func sendKLine(_ channel: Int, _ bytes: [UInt8], loopback: Bool) {
        let mark: UInt8 = loopback ? 0x20 : 0x00
        frame(channel, status: 0x80 | mark, body: timestamp())
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 254, bytes.count)
            frame(channel, status: mark, body: Array(bytes[offset..<end]))
            offset = end
        }
        frame(channel, status: 0x40 | mark, body: timestamp())
    }

    /// Passes on what the ECU sent on the K-line, if a filter lets it through.
    private func forwardKLine() {
        guard let ecuPort, let open = channels[3] else { return }
        guard let bytes = try? ecuPort.readAvailable(timeout: 0.001, idle: 0.001), !bytes.isEmpty else { return }
        guard !open.filters.isEmpty else { return }
        sendKLine(3, bytes, loopback: false)
    }

    private func frame(_ channel: Int, status: UInt8, body: [UInt8]) {
        write([UInt8(ascii: "a"), UInt8(ascii: "r"), UInt8(ascii: "0") + UInt8(channel), UInt8(body.count + 1), status] + body)
    }

    private func reply(_ text: String, _ sequence: Int?) {
        write(Array((text + (sequence.map { " \($0)" } ?? "") + "\r\n").utf8))
    }

    /// Microseconds since the cable got power, big-endian.
    private func timestamp() -> [UInt8] {
        let micros = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince(started) * 1_000_000))
        return [UInt8(micros >> 24 & 0xFF), UInt8(micros >> 16 & 0xFF), UInt8(micros >> 8 & 0xFF), UInt8(micros & 0xFF)]
    }

    private func write(_ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Int(cserial_write(controller, $0.baseAddress, Int32($0.count))) }
            if n <= 0 { return }
            offset += n
        }
    }
}
