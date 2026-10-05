import Foundation

/// The wire format of the Tactrix OpenPort 2.0, as far as SubieScope needs it. Pure functions, no I/O.
///
/// Tactrix publishes no specification. The facts here come from the protocol notes of openport-j2534
/// by Biser Atanasov (GPL-3.0-or-later, https://github.com/bisak/openport-j2534), which were measured
/// on a real cable, and from FastECU's J2534 code for Linux (GPLv3).
///
/// The cable is a USB serial device. The computer sends text lines, `at<verb>[<channel>] <args>\r\n`,
/// some followed by binary payload. The cable answers with text replies (`ar<verb> <args>\r\n`) and
/// with binary message frames (`'a' 'r' <channel digit> <length> <status> ...`), mixed on one pipe.
public enum OpenPortWire {
    /// A channel number is the cable's protocol number, so each protocol can be open once.
    public enum Channel {
        /// ISO 9141: raw bytes on the K-line (OBD pin 7). SSM runs here.
        public static let kLine = 3
        /// ISO 15765: diagnostics over CAN. The cable does the ISO-TP splitting and joining itself.
        public static let isoTP = 6
    }

    /// The status byte of a message frame.
    public struct Status: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// A message begins. The frame carries no data of its own.
        public static let start = Status(rawValue: 0x80)
        /// This frame completes a message.
        public static let end = Status(rawValue: 0x40)
        /// An echo of what the cable itself sent.
        public static let loopback = Status(rawValue: 0x20)
        /// The cable finished sending. Not received data.
        public static let transmitDone = Status(rawValue: 0x10)
    }

    public struct Frame: Equatable, Sendable {
        public var channel: Int
        public var status: Status
        /// The bytes after the status byte and, where the frame has one, the timestamp.
        public var data: [UInt8]

        public init(channel: Int, status: Status, data: [UInt8]) {
            self.channel = channel
            self.status = status
            self.data = data
        }
    }

    /// A text reply, e.g. `aro 5`, `are 9 12` or `arr 16 12150 3`.
    public struct TextReply: Equatable, Sendable {
        /// The letter after `ar`: o (done), e (error), i (information), r (pin voltage), f (filter) and so on.
        public var verb: Character
        /// Everything after the verb, as the cable sent it.
        public var body: String

        public init(verb: Character, body: String) {
            self.verb = verb
            self.body = body
        }

        /// The reply as the cable sent it, without the line end.
        public var line: String { "ar\(verb)\(body)" }

        /// The numbers in the body, in order. A channel digit glued to the verb (`arf6 0 8`) comes first.
        public var numbers: [Int] {
            body.split(separator: " ").compactMap { Int($0) }
        }

        /// The number the command carried, which the cable repeats as the last field of its reply.
        public var sequence: Int? {
            guard verb != "i", let last = body.split(separator: " ").last else { return nil }
            return Int(last)
        }
    }

    public enum Reply: Equatable, Sendable {
        case frame(Frame)
        case text(TextReply)
        /// Bytes that are neither: skipped so the reader finds its place again.
        case junk
    }

    /// A text reply is never longer than this; anything longer without a line end is noise.
    static let longestLine = 200

    /// Decodes the first reply in `buffer`. Returns nil when more bytes are needed.
    public static func parse(_ buffer: [UInt8]) -> (reply: Reply, consumed: Int)? {
        guard let first = buffer.first else { return nil }
        guard first == UInt8(ascii: "a") else { return (.junk, 1) }
        guard buffer.count >= 2 else { return nil }
        guard buffer[1] == UInt8(ascii: "r") else { return (.junk, 1) }
        guard buffer.count >= 3 else { return nil }

        // A digit after "ar" is a channel: a message frame. A letter is a text reply.
        if buffer[2] >= UInt8(ascii: "0"), buffer[2] <= UInt8(ascii: "9") {
            guard buffer.count >= 4 else { return nil }
            let length = Int(buffer[3])
            guard buffer.count >= 4 + length else { return nil }
            guard length >= 1 else { return (.junk, 4) }
            let channel = Int(buffer[2] - UInt8(ascii: "0"))
            let status = Status(rawValue: buffer[4])
            var body = Array(buffer[5..<(4 + length)])
            if hasTimestamp(channel: channel, status: status) {
                body = Array(body.dropFirst(4))
            }
            return (.frame(Frame(channel: channel, status: status, data: body)), 4 + length)
        }

        guard (buffer[2] >= UInt8(ascii: "a") && buffer[2] <= UInt8(ascii: "z")) else { return (.junk, 1) }
        var index = 3
        while index + 1 < buffer.count {
            if buffer[index] == 13, buffer[index + 1] == 10 {
                let body = String(decoding: buffer[3..<index], as: UTF8.self)
                return (.text(TextReply(verb: Character(UnicodeScalar(buffer[2])), body: body)), index + 2)
            }
            index += 1
        }
        return buffer.count > longestLine ? (.junk, 1) : nil
    }

    /// Whether the four bytes after the status byte are a timestamp. On CAN they always are. On the
    /// K-line only the frames that mark the start, the end or a finished transmit carry one, and those
    /// carry nothing else: a K-line data frame is the bytes themselves.
    static func hasTimestamp(channel: Int, status: Status) -> Bool {
        guard channel == 3 || channel == 4 else { return true }
        return !status.isDisjoint(with: [.start, .end, .transmitDone])
    }

    // MARK: What the cable's error numbers mean

    /// The cable reports failures as J2534 return codes. These are the ones a driver can meet.
    public static func errorName(_ code: Int) -> String {
        switch code {
        case 1: return "not supported"
        case 3: return "protocol not available"
        case 7: return "command failed"
        case 9: return "timeout: nothing answered"
        case 10: return "invalid message"
        case 12: return "limit reached"
        case 20: return "channel already in use"
        case 22: return "no such filter"
        default: return "error \(code)"
        }
    }
}
