import Foundation

public enum OpenPortError: Error, LocalizedError, Equatable {
    /// The port opened, but what is on it does not answer like an OpenPort.
    case notAnOpenPort
    /// The cable did not answer a command in time.
    case noReply(command: String)
    /// The cable answered a command with an error number.
    case rejected(command: String, code: Int)
    /// A message could not be sent on CAN: nothing on the bus acknowledged it.
    case busSilent
    /// The message went out, but the ECU did not answer.
    case noAnswer
    /// The cable measures no battery voltage on the OBD plug.
    case noCarPower(volts: Double)

    public var errorDescription: String? {
        switch self {
        case .notAnOpenPort:
            return "The Tactrix OpenPort did not answer. Unplug it and plug it back in. If there is a microSD card in the cable, take it out first: with a card in, the cable shows up as a USB disk."
        case .noReply(let command):
            return "The OpenPort stopped answering (\(command)). Unplug it, plug it back in and try again."
        case .rejected(let command, let code):
            return "The OpenPort refused a command (\(command): \(OpenPortWire.errorName(code)))."
        case .busSilent:
            return "Nothing in the car answered on the CAN bus. Check that the OpenPort is plugged into the OBD port and the ignition is ON."
        case .noAnswer:
            return "The ECU did not answer. Check that the ignition is ON."
        case .noCarPower(let volts):
            return String(format: "The OpenPort gets no power from the car (it measures %.1f V). Plug it firmly into the OBD port under the dashboard.", volts)
        }
    }
}

/// A Tactrix OpenPort 2.0, talked to through the serial port macOS makes for it (no driver needed).
///
/// This is the cable itself: opening it, sending it commands and sorting what it sends back. The
/// K-line that SSM uses and the CAN channel that reading a ROM uses sit on top of it
/// (`OpenPortKLine`, `OpenPortISOTPTransport`).
///
/// EXPERIMENTAL: NOT TESTED ON A REAL CABLE. It follows the protocol notes of openport-j2534 by Biser
/// Atanasov (GPL-3.0-or-later), which were measured on a real OpenPort, and runs here only against a
/// simulated cable.
///
/// Not thread safe: use it from one thread or queue, like `SerialPort`.
public final class OpenPort: @unchecked Sendable {
    public let path: String
    /// What `ati` reported, e.g. "1.17.4877". Set once the cable is open.
    public private(set) var firmware: String?
    /// Every line sent to the cable and every reply, for the console and the log file.
    public var log: ((String) -> Void)?

    private let port: SerialPort
    private var ready = false
    private var buffer: [UInt8] = []
    private var sequence = 1000
    private var openChannels: Set<Int> = []
    private var inbox: [Int: [OpenPortWire.Frame]] = [:]
    /// Counts frames put into an inbox, to notice that sorting produced something.
    private var framesSorted = 0

    /// Frames kept per channel while nobody reads them; older ones are dropped beyond this.
    private let inboxLimit = 4096

    public init(path: String) {
        self.path = path
        self.port = SerialPort(path: path)
    }

    deinit {
        close()
    }

    public var isOpen: Bool { port.isOpen && ready }

    // MARK: Opening and closing

    /// Opens the cable and checks that it answers. Leaves every channel closed.
    public func open() throws {
        close()
        // The speed means nothing here: it is USB all the way to the cable.
        try port.open(baud: 115_200, parity: "N", stopBits: 1)
        do {
            try handshake()
            ready = true
        } catch {
            port.close()
            throw error
        }
    }

    public func close() {
        guard port.isOpen else { return }
        if ready {
            // Closes every channel and switches every output off, so nothing is left running.
            _ = try? command("atz", timeout: 0.5)
        }
        ready = false
        port.close()
        buffer.removeAll()
        inbox.removeAll()
        openChannels.removeAll()
    }

    private func handshake() throws {
        for attempt in 0..<2 {
            // Newlines end a half-typed line that an interrupted session may have left behind.
            try port.write(Array("\r\n\r\n".utf8))
            if attempt > 0 { try port.write(Array("atz\r\n".utf8)) }
            // Whatever is still waiting belongs to an earlier session.
            _ = try port.readAvailable(timeout: 0.15, idle: 0.05)
            buffer.removeAll()
            do {
                firmware = try version()
                // Closes any channel still open from before, and switches every output off.
                try command("ata")
                return
            } catch let error as SerialError {
                throw error
            } catch {
                continue
            }
        }
        throw OpenPortError.notAnOpenPort
    }

    /// `ati` is the one command the cable does not number, so its reply is recognised by its letter.
    private func version() throws -> String {
        note("→ ati")
        try port.write(Array("ati\r\n".utf8))
        let deadline = Date().addingTimeInterval(1.0)
        while true {
            while let reply = nextText() {
                note("← \(reply.line)")
                guard reply.verb == "i" else { continue }
                let text = reply.body.split(separator: ":").last.map(String.init) ?? reply.body
                return text.trimmingCharacters(in: .whitespaces)
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, try fill(timeout: remaining) else { throw OpenPortError.noReply(command: "ati") }
        }
    }

    // MARK: Commands

    /// Sends one command and waits for its reply. Every command carries a number that the cable
    /// repeats in its reply: that is how a late reply to an earlier command is told apart and dropped.
    @discardableResult
    func command(_ text: String, payload: [UInt8] = [], timeout: TimeInterval = 1.0) throws -> OpenPortWire.TextReply {
        guard port.isOpen else { throw SerialError.notOpen }
        sequence = sequence >= 29_999 ? 1000 : sequence + 1
        let number = sequence
        if log != nil { note("→ \(text) \(number)" + (payload.isEmpty ? "" : " + \(payload.hexString)")) }
        try port.write(Array("\(text) \(number)\r\n".utf8) + payload)

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            while let reply = nextText() {
                guard reply.sequence == number else {
                    note("← \(reply.line) (late, dropped)")
                    continue
                }
                note("← \(reply.line)")
                if reply.verb == "e" {
                    throw OpenPortError.rejected(command: text, code: reply.numbers.first ?? 0)
                }
                return reply
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, try fill(timeout: remaining) else { throw OpenPortError.noReply(command: text) }
        }
    }

    /// The car battery's voltage, measured on pin 16 of the OBD plug. On USB power alone it reads
    /// about 0.1 V, so this tells whether the cable is plugged into a car.
    public func batteryVoltage() throws -> Double {
        let reply = try command("atr 16", timeout: 2)
        let numbers = reply.numbers
        guard reply.verb == "r", numbers.count >= 2 else { throw OpenPortError.noReply(command: "atr 16") }
        return Double(numbers[1]) / 1000
    }

    // MARK: Channels

    func openChannel(_ channel: Int, flags: UInt32, baud: UInt32) throws {
        let open = "ato\(channel) \(flags) \(baud) 0"
        do {
            try command(open)
        } catch OpenPortError.rejected(_, 20) {
            // Still open from a session that did not end cleanly.
            try command("atc\(channel)")
            try command(open)
        }
        openChannels.insert(channel)
        inbox[channel] = []
    }

    func closeChannel(_ channel: Int) {
        guard openChannels.remove(channel) != nil else { return }
        inbox[channel] = nil
        _ = try? command("atc\(channel)", timeout: 0.5)
    }

    func isChannelOpen(_ channel: Int) -> Bool { openChannels.contains(channel) }

    /// Writes one J2534 configuration value (the parameter numbers are J2534's).
    func setConfig(_ channel: Int, parameter: Int, value: UInt32) throws {
        try command("ats\(channel) \(parameter) \(value)")
    }

    /// Installs a filter: 1 lets matching messages through, 3 is the ISO-TP flow control filter.
    /// `messages` is mask and pattern, plus the flow control message for type 3, all the same length.
    func addFilter(_ channel: Int, type: Int, txFlags: UInt32, messages: [[UInt8]]) throws {
        let length = messages.first?.count ?? 0
        try command("atf\(channel) \(type) \(txFlags) \(length)", payload: messages.flatMap { $0 })
    }

    /// Sends one message. `budget` is how long the cable may try to get it onto the wire.
    func transmit(_ channel: Int, payload: [UInt8], txFlags: UInt32, budget: TimeInterval) throws {
        let microseconds = Int(budget * 1_000_000)
        do {
            try command("att\(channel) \(payload.count) \(txFlags) \(microseconds)", payload: payload, timeout: budget + 1)
        } catch OpenPortError.rejected(_, 9) {
            throw OpenPortError.busSilent
        }
    }

    // MARK: Received frames

    /// Hands over the frames that arrived on a channel since the last call.
    func takeFrames(on channel: Int) -> [OpenPortWire.Frame] {
        sortWaiting()
        guard let frames = inbox[channel], !frames.isEmpty else { return [] }
        inbox[channel] = []
        return frames
    }

    /// Puts frames back at the front of a channel's inbox, for whoever reads next.
    func returnFrames(_ frames: [OpenPortWire.Frame], to channel: Int) {
        inbox[channel, default: []].insert(contentsOf: frames, at: 0)
    }

    /// Reads what the cable has sent, for up to `timeout`, and sorts it into the channels' inboxes.
    /// Returns false when nothing arrived.
    @discardableResult
    func pump(timeout: TimeInterval) throws -> Bool {
        guard port.isOpen else { throw SerialError.notOpen }
        // Frames often arrive together with the reply to a command, and are then already here.
        let before = framesSorted
        sortWaiting()
        if framesSorted != before { return true }
        let arrived = try fill(timeout: timeout)
        sortWaiting()
        return arrived
    }

    /// Sorts the bytes that were read but not looked at yet. No command is waiting for a reply at
    /// this point, so a text reply among them is a late one and is dropped.
    private func sortWaiting() {
        while let stale = nextText() {
            note("← \(stale.line) (not expected, dropped)")
        }
    }

    /// Waits up to `timeout` for bytes from the cable. Returns false when none came.
    private func fill(timeout: TimeInterval) throws -> Bool {
        let bytes = try port.readAvailable(timeout: timeout, idle: 0.0005)
        buffer.append(contentsOf: bytes)
        return !bytes.isEmpty
    }

    /// Works through what has arrived: message frames go to their channel's inbox, and the first
    /// text reply is returned.
    private func nextText() -> OpenPortWire.TextReply? {
        while let (reply, consumed) = OpenPortWire.parse(buffer) {
            buffer.removeFirst(consumed)
            switch reply {
            case .frame(let frame):
                guard openChannels.contains(frame.channel) else { continue }
                if log != nil { note(String(format: "← frame ch%d status %02X ", frame.channel, frame.status.rawValue) + frame.data.hexString) }
                inbox[frame.channel, default: []].append(frame)
                framesSorted &+= 1
                if let count = inbox[frame.channel]?.count, count > inboxLimit {
                    inbox[frame.channel]?.removeFirst(count - inboxLimit)
                }
            case .text(let text):
                return text
            case .junk:
                continue
            }
        }
        return nil
    }

    private func note(_ text: @autoclosure () -> String) {
        log?(text())
    }
}
