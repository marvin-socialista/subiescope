import Foundation

/// The K-line of a Tactrix OpenPort 2.0, presented as the same pipe of bytes a KKL cable gives, so
/// `SSMTransport` and everything above it work unchanged.
///
/// The channel is set up the way RomRaider and FastECU set it up for SSM on this cable: ISO 9141
/// without the cable adding or checking checksums, at the SSM speed, with no pauses between bytes and
/// a filter that lets every byte through.
///
/// EXPERIMENTAL: NOT TESTED ON A REAL CABLE. How the cable hands over bytes it receives from an ECU on
/// the K-line was never measured by the notes this follows; it is what three other open-source drivers
/// agree on.
public final class OpenPortKLine: SSMLine {
    public let device: OpenPort
    private let channel = OpenPortWire.Channel.kLine
    private var received: [UInt8] = []

    // J2534 numbers, as the cable takes them.
    private static let noChecksum: UInt32 = 0x200
    private static let passFilter = 1
    /// LOOPBACK off, P1_MAX and P3_MIN at their shortest (half a millisecond), P4_MIN none, no
    /// parity, eight data bits.
    private static let settings: [(parameter: Int, value: UInt32)] = [(3, 0), (7, 1), (10, 1), (12, 0), (22, 0), (32, 0)]

    public init(device: OpenPort) {
        self.device = device
    }

    public var isOpen: Bool { device.isOpen && device.isChannelOpen(channel) }

    public func open(baud: UInt32) throws {
        if !device.isOpen { try device.open() }
        try device.openChannel(channel, flags: Self.noChecksum, baud: baud)
        for setting in Self.settings {
            // A cable that does not know a setting says so and carries on with its default.
            _ = try? device.setConfig(channel, parameter: setting.parameter, value: setting.value)
        }
        try device.addFilter(channel, type: Self.passFilter, txFlags: 0, messages: [[0x00], [0x00]])
        received.removeAll()
    }

    public func close() {
        device.close()
        received.removeAll()
    }

    public func write(_ bytes: [UInt8]) throws {
        try device.transmit(channel, payload: bytes, txFlags: 0, budget: 1)
    }

    public func read(count: Int, timeout: TimeInterval) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        collect()
        while received.count < count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, try device.pump(timeout: remaining) else { break }
            collect()
        }
        let taken = Array(received.prefix(count))
        received.removeFirst(taken.count)
        return taken
    }

    public func readAvailable(timeout: TimeInterval, idle: TimeInterval) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        collect()
        var result = received
        received.removeAll()
        while true {
            let limit = result.isEmpty ? deadline.timeIntervalSinceNow : min(idle, deadline.timeIntervalSinceNow)
            guard limit > 0, try device.pump(timeout: limit) else { break }
            collect()
            result.append(contentsOf: received)
            received.removeAll()
        }
        return result
    }

    public func discardInput() {
        _ = try? device.pump(timeout: 0.001)
        _ = device.takeFrames(on: channel)
        received.removeAll()
    }

    /// The cable cannot hold the line low like a serial port's BREAK. RomRaider stops the ECU's stream
    /// through this cable by sending twenty zero bytes instead, and so does this.
    public func interrupt(for duration: TimeInterval) {
        try? write([UInt8](repeating: 0, count: 20))
    }

    /// Moves the bytes of newly arrived frames into `received`. Frames that only mark the start or the
    /// end of a message, a finished transmit, or an echo of our own bytes carry nothing to keep.
    private func collect() {
        for frame in device.takeFrames(on: channel) where frame.status.isDisjoint(with: [.start, .end, .transmitDone, .loopback]) {
            received.append(contentsOf: frame.data)
        }
    }
}
