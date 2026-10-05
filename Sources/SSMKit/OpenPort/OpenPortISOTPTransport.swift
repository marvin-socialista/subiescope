import Foundation

/// An ISO-TP transport to the engine ECU through a Tactrix OpenPort 2.0, for reading a ROM. The cable
/// splits long requests into CAN frames and joins long replies itself, so a 1 KB page comes back as
/// one message.
///
/// The channel is set up the way FastECU sets it up for this ECU: ISO 15765 at 500 kbit/s, requests
/// on 7E0 padded to full frames, and a flow control filter for replies from 7E8.
///
/// EXPERIMENTAL: NOT TESTED ON A REAL CABLE OR CAR. It has only run against a simulated cable and ECU.
public final class OpenPortISOTPTransport: SH7058Transport {
    private let device: OpenPort
    private let channel = OpenPortWire.Channel.isoTP
    private let tester: UInt32 = 0x7E0
    private let ecu: UInt32 = 0x7E8

    // J2534 numbers, as the cable takes them.
    private static let framePad: UInt32 = 0x40
    private static let flowControlFilter = 3
    /// LOOPBACK off, and no limits on how fast the ECU may send (block size and separation time 0).
    private static let settings: [(parameter: Int, value: UInt32)] = [(3, 0), (30, 0), (31, 0)]

    /// How long to keep waiting after the ECU said it is still busy with a request.
    public var busyTimeout: TimeInterval = 5

    public init(device: OpenPort) {
        self.device = device
    }

    /// Opens the CAN channel. The cable itself may already be open (for SSM on the K-line).
    public func open() throws {
        if !device.isOpen { try device.open() }
        try device.openChannel(channel, flags: 0, baud: 500_000)
        for setting in Self.settings {
            _ = try? device.setConfig(channel, parameter: setting.parameter, value: setting.value)
        }
        try device.addFilter(channel, type: Self.flowControlFilter, txFlags: Self.framePad,
                             messages: [[0xFF, 0xFF, 0xFF, 0xFF], Self.identifier(ecu), Self.identifier(tester)])
    }

    /// Closes the CAN channel and leaves the cable open.
    public func close() {
        device.closeChannel(channel)
    }

    public func request(_ payload: [UInt8], responseCount: Int = 1, timeout: TimeInterval) throws -> [UInt8] {
        // Anything still on its way belongs to an earlier request.
        try device.pump(timeout: 0.001)
        _ = device.takeFrames(on: channel)
        try device.transmit(channel, payload: Self.identifier(tester) + payload, txFlags: Self.framePad,
                            budget: min(max(timeout, 1), 5))
        var reply: [UInt8] = []
        for _ in 0..<max(1, responseCount) {
            reply.append(contentsOf: try receive(timeout: timeout))
        }
        return reply
    }

    /// Waits for one whole message from the ECU. A long one arrives as an announcement and then the
    /// data in pieces, each starting with the CAN identifier again; the last piece is marked as the end.
    private func receive(timeout: TimeInterval) throws -> [UInt8] {
        var deadline = Date().addingTimeInterval(timeout)
        var message: [UInt8] = []
        var waiting: [OpenPortWire.Frame] = []
        while true {
            if waiting.isEmpty {
                // The answer may already be in: it can arrive together with the cable's "sent".
                waiting = device.takeFrames(on: channel)
                if waiting.isEmpty {
                    let remaining = deadline.timeIntervalSinceNow
                    guard remaining > 0 else { throw OpenPortError.noAnswer }
                    try device.pump(timeout: remaining)
                }
                continue
            }
            let frame = waiting.removeFirst()
            if !frame.status.isDisjoint(with: [.transmitDone, .loopback]) { continue }
            if frame.status.contains(.start), !frame.status.contains(.end) {
                message.removeAll()
                continue
            }
            guard frame.data.count >= 4, Array(frame.data.prefix(4)) == Self.identifier(ecu) else { continue }
            message.append(contentsOf: frame.data.dropFirst(4))
            guard frame.status.contains(.end) else { continue }
            if message.count == 3, message[0] == 0x7F, message[2] == 0x78 {
                // "Still busy, answer follows": keep waiting for the real one.
                deadline = Date().addingTimeInterval(max(timeout, busyTimeout))
                message.removeAll()
                continue
            }
            // Put back what came after this message, for a caller that expects more than one.
            if !waiting.isEmpty { device.returnFrames(waiting, to: channel) }
            return message
        }
    }

    static func identifier(_ id: UInt32) -> [UInt8] {
        [UInt8(id >> 24 & 0xFF), UInt8(id >> 16 & 0xFF), UInt8(id >> 8 & 0xFF), UInt8(id & 0xFF)]
    }
}
