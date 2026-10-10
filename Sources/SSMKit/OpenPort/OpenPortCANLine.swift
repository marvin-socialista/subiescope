import Foundation

/// SSM over CAN through a Tactrix OpenPort 2.0, presented as the pipe of bytes a K-line gives, so
/// `SSMTransport` and everything above it work unchanged.
///
/// Subarus from about 2008 on (and some 2007 cars) answer the SSM commands on CAN as well as on the
/// K-line: the same commands without the K-line's header and checksum, on 7E0 with the answer on 7E8,
/// and the ECU identifies itself to `AA` where the K-line uses `BF`. That is RomRaider's "CAN bus"
/// logging (its logger definitions give the identifiers), and tuneforge by Andrey Sazonov
/// (https://github.com/firefighter-19/tuneforge, GPL-2.0-or-later) logged a 2007 Forester XT this way
/// through an OpenPort: identify first, then `A8 00` and the addresses, answered with `E8` and the
/// values. A whole exchange takes a few hundredths of a second, where the K-line at 4800 baud needs
/// a few tenths, so there is no continuous mode here and none is needed.
///
/// A request written here as a K-line frame goes out as one CAN message, and the ECU's answer comes
/// back from `read` as the K-line frame it would have been.
///
/// EXPERIMENTAL. It has run on one real cable and car (a replica cable on a 2009 JDM Impreza WRX STI, on a Mac, on 10 October 2026):
/// identifying, reading and logging worked, at about 50 to 66 samples a second, but that ECU refuses
/// every address in its RAM this way (7F A8 12), which is every ECU specific value. It does so with
/// the engine running or off, and also inside an extended diagnostic session (10 03), which it only
/// enters with the engine off. Those values stay on the K-line.
public final class OpenPortCANLine: SSMLine {
    public let device: OpenPort
    private let channel = OpenPortWire.Channel.isoTP
    private var received: [UInt8] = []
    /// The pieces of a long answer that have arrived so far.
    private var partial: [UInt8] = []
    /// Who the last request went to, and what it asked: its answer is handed over as coming from there.
    private var asked: (unit: UInt8, tester: UInt8, command: UInt8, answerFrom: [UInt8])?
    /// The control units whose answers the cable lets through. Each needs a filter of its own.
    private var listeningTo: Set<UInt8> = []

    /// The CAN identifiers of the control units, by their address on the K-line.
    static let identifiers: [UInt8: (request: UInt32, answer: UInt32)] = [
        SSMDevice.engine.rawValue: (0x7E0, 0x7E8),
        SSMDevice.transmission.rawValue: (0x7E1, 0x7E9),
    ]
    /// "Identify yourself" over CAN, answered with `EA` and what the K-line's `BF` is answered with.
    static let identifyCommand: UInt8 = 0xAA

    // J2534 numbers, as the cable takes them.
    private static let framePad: UInt32 = 0x40
    private static let flowControlFilter = 3
    /// LOOPBACK off, and no limits on how fast the ECU may send (block size and separation time 0).
    private static let settings: [(parameter: Int, value: UInt32)] = [(3, 0), (30, 0), (31, 0)]

    public init(device: OpenPort) {
        self.device = device
    }

    public var isOpen: Bool { device.isOpen }
    public var supportsContinuous: Bool { false }

    /// `baud` is the K-line's and means nothing here: diagnostics on CAN run at 500 kbit/s.
    public func open(baud: UInt32) throws {
        if !device.isOpen { try device.open() }
        try openChannel()
        received.removeAll()
        partial.removeAll()
    }

    /// Reading a ROM borrows the same channel and closes it when it is done, so it is opened again
    /// whenever it turns out to be closed. It is set up exactly as for reading a ROM: one flow control
    /// filter, for the engine ECU.
    private func openChannel() throws {
        try device.openChannel(channel, flags: 0, baud: 500_000)
        for setting in Self.settings {
            _ = try? device.setConfig(channel, parameter: setting.parameter, value: setting.value)
        }
        listeningTo.removeAll()
        try listen(to: SSMDevice.engine.rawValue)
    }

    /// Installs the filter that lets one control unit's answers through, the first time it is asked something.
    private func listen(to unit: UInt8) throws {
        guard !listeningTo.contains(unit), let ids = Self.identifiers[unit] else { return }
        try device.addFilter(channel, type: Self.flowControlFilter, txFlags: Self.framePad,
                             messages: [[0xFF, 0xFF, 0xFF, 0xFF], OpenPortISOTPTransport.identifier(ids.answer),
                                        OpenPortISOTPTransport.identifier(ids.request)])
        listeningTo.insert(unit)
    }

    public func close() {
        device.close()
        received.removeAll()
        partial.removeAll()
        asked = nil
        listeningTo.removeAll()
    }

    public func write(_ bytes: [UInt8]) throws {
        // Anything that is not one whole request for a control unit on CAN gets no answer, like a
        // request to nobody on the K-line.
        guard let packet = try? SSMPacket.decode(bytes), let command = packet.command,
              let ids = Self.identifiers[packet.destination] else { return }
        if !device.isChannelOpen(channel) { try openChannel() }
        try listen(to: packet.destination)
        var data = packet.data
        if command == SSMCommand.initECU { data[0] = Self.identifyCommand }
        // "Keep answering" does not exist on CAN: every request is answered once.
        if command == SSMCommand.readAddresses, data.count > 1 { data[1] = 0x00 }
        asked = (packet.destination, packet.source, command, OpenPortISOTPTransport.identifier(ids.answer))
        partial.removeAll()
        try device.transmit(channel, payload: OpenPortISOTPTransport.identifier(ids.request) + data,
                            txFlags: Self.framePad, budget: 1)
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
        partial.removeAll()
    }

    /// There is no stream to interrupt on CAN.
    public func interrupt(for duration: TimeInterval) {}

    /// Turns the messages that have arrived from the ECU into the K-line frames they stand for. A
    /// long message comes as an announcement and then in pieces that each start with the CAN
    /// identifier again, the last one marked as the end.
    private func collect() {
        for frame in device.takeFrames(on: channel) {
            if !frame.status.isDisjoint(with: [.transmitDone, .loopback]) { continue }
            if frame.status.contains(.start), !frame.status.contains(.end) {
                partial.removeAll()
                continue
            }
            guard let asked, frame.data.count >= 4, Array(frame.data.prefix(4)) == asked.answerFrom else { continue }
            partial.append(contentsOf: frame.data.dropFirst(4))
            guard frame.status.contains(.end) else { continue }
            var message = partial
            partial.removeAll()
            // "Still busy, the answer follows": keep waiting for the real one.
            if message.count == 3, message[0] == 0x7F, message[2] == 0x78 { continue }
            guard !message.isEmpty else { continue }
            if asked.command == SSMCommand.initECU, message[0] == SSMCommand.response(to: Self.identifyCommand) {
                message[0] = SSMCommand.response(to: SSMCommand.initECU)
            }
            let reply = SSMPacket(destination: asked.tester, source: asked.unit, data: message)
            if let encoded = try? reply.encoded() { received.append(contentsOf: encoded) }
        }
    }
}
