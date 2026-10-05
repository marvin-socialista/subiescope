import Foundation

public enum SSMError: Error, LocalizedError, Equatable {
    case timeout(command: UInt8, receivedBytes: Int, sawEcho: Bool)
    case unexpectedResponse(String)
    case writeRejected(address: UInt32, wrote: UInt8, got: UInt8)

    public var errorDescription: String? {
        switch self {
        case .timeout(let command, let received, let sawEcho):
            let base = String(format: "No answer from the control unit (command 0x%02X).", command)
            if received == 0 {
                return base + " Nothing came back at all: check that the cable is plugged into the car and the ignition is ON."
            }
            if sawEcho {
                return base + " The cable echoed the request, so the cable works, but the ECU did not reply. Is the ignition ON?"
            }
            return base + " Received \(received) unrecognised bytes."
        case .unexpectedResponse(let detail):
            return "Unexpected response from the control unit: \(detail)"
        case .writeRejected(let address, let wrote, let got):
            return String(format: "The control unit did not accept writing 0x%02X to 0x%06X (answered 0x%02X).", wrote, address, got)
        }
    }
}

/// Raw traffic hook for the debug console.
public enum SSMTrafficDirection: Sendable { case sent, echo, received, garbage }

/// Sends SSM2 requests over the K-line and returns the matching reply.
///
/// K-line is a single wire, so KKL cables hear their own transmission: every
/// request comes back as an echo before the ECU's answer. Instead of assuming
/// the echo is present, incoming bytes are parsed into frames and only the frame
/// addressed to the tester is accepted. That also makes it work over a Tactrix
/// OpenPort 2.0, which leaves the echo out.
public final class SSMTransport {
    public let line: SSMLine
    public var baudRate: UInt32
    /// Extra time allowed for the ECU to start answering.
    public var responseTimeout: TimeInterval = 0.5
    /// Minimum pause between the end of one reply and the next request.
    public var interRequestDelay: TimeInterval = 0.0
    public var traffic: ((SSMTrafficDirection, [UInt8]) -> Void)?

    private var lastExchangeEnd = Date.distantPast
    private var pending: [UInt8] = []

    public init(line: SSMLine, baudRate: UInt32 = 4800) {
        self.line = line
        self.baudRate = baudRate
    }

    public convenience init(port: SerialPort, baudRate: UInt32 = 4800) {
        self.init(line: port, baudRate: baudRate)
    }

    /// Seconds needed to shift `bytes` bytes over the wire (8N1 = 10 bits per byte).
    public func wireTime(_ bytes: Int) -> TimeInterval {
        Double(bytes * 10) / Double(baudRate)
    }

    /// Called after a BREAK was sent. The demo ECU uses it, because a pseudo
    /// terminal cannot carry a real break condition.
    public var onBreak: (() -> Void)?

    public func exchange(_ request: SSMPacket, expectedDataLength: Int? = nil) throws -> SSMPacket {
        let bytes = try request.encoded()
        let sinceLast = Date().timeIntervalSince(lastExchangeEnd)
        if sinceLast < interRequestDelay {
            Thread.sleep(forTimeInterval: interRequestDelay - sinceLast)
        }
        line.discardInput()
        pending.removeAll()
        traffic?(.sent, bytes)
        try line.write(bytes)
        defer { lastExchangeEnd = Date() }

        // Budget: echo of our request + the reply, plus ECU think time.
        let replyBytes = (expectedDataLength.map { $0 + 5 }) ?? 260
        let budget = wireTime(bytes.count + replyBytes) * 1.5 + responseTimeout
        return try receive(replyTo: request, expectedDataLength: expectedDataLength, timeout: budget)
    }

    /// Waits for the next reply frame without sending anything; used while the ECU
    /// streams answers in continuous (fast poll) mode.
    public func receive(replyTo request: SSMPacket, expectedDataLength: Int?, timeout: TimeInterval) throws -> SSMPacket {
        let command = request.command ?? 0
        let deadline = Date().addingTimeInterval(timeout)
        var sawEcho = false
        var received = 0

        while Date() < deadline {
            // Frames first: leftovers from the previous read may already hold one.
            while let (frame, consumed) = Self.extractFrame(from: pending) {
                pending.removeFirst(consumed)
                guard let frame else { continue }
                if frame.destination == request.destination && frame.source == request.source {
                    // Our own request echoed back by the K-line transceiver.
                    sawEcho = true
                    traffic?(.echo, (try? frame.encoded()) ?? [])
                    continue
                }
                guard frame.destination == request.source && frame.source == request.destination else { continue }
                traffic?(.received, (try? frame.encoded()) ?? [])
                if frame.command == 0x7F {
                    throw SSMError.unexpectedResponse("negative response \(frame.data.hexString)")
                }
                if frame.command != SSMCommand.response(to: command) {
                    throw SSMError.unexpectedResponse(
                        String(format: "expected 0x%02X, got %@", SSMCommand.response(to: command), frame.data.hexString))
                }
                if let expectedDataLength, frame.data.count != expectedDataLength {
                    // A stale frame from an earlier request; keep looking.
                    continue
                }
                return frame
            }
            let chunk = try line.read(count: 1, timeout: max(0.001, deadline.timeIntervalSinceNow))
            if chunk.isEmpty { break }
            var more = chunk
            more.append(contentsOf: try line.readAvailable(timeout: 0.0005, idle: 0.0005))
            received += more.count
            pending.append(contentsOf: more)
        }
        if !pending.isEmpty {
            traffic?(.garbage, pending)
            pending.removeAll()
        }
        throw SSMError.timeout(command: command, receivedBytes: received, sawEcho: sawEcho)
    }

    /// Ends continuous mode: a BREAK of one character time, then wait until the ECU
    /// has gone quiet (RomRaider's clearLine).
    public func stopContinuous() {
        line.interrupt(for: max(0.02, wireTime(1)))
        onBreak?()
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            let drained = (try? line.readAvailable(timeout: 0.06, idle: 0.03)) ?? []
            if drained.isEmpty { break }
        }
        pending.removeAll()
        line.discardInput()
    }

    /// Finds the first frame in `buffer`. Returns (frame, bytesConsumed); frame is nil
    /// when leading garbage was skipped. Returns nil when more bytes are needed.
    static func extractFrame(from buffer: [UInt8]) -> (SSMPacket?, Int)? {
        guard !buffer.isEmpty else { return nil }
        guard let start = buffer.firstIndex(of: SSMPacket.header) else {
            return (nil, buffer.count)
        }
        if start > 0 { return (nil, start) }
        // Only three bus addresses exist; anything else means this 0x80 is not a frame start.
        let known: Set<UInt8> = [SSMDevice.engine.rawValue, SSMDevice.transmission.rawValue, SSMDevice.tester.rawValue]
        if buffer.count >= 2, !known.contains(buffer[1]) { return (nil, 1) }
        if buffer.count >= 3, !known.contains(buffer[2]) { return (nil, 1) }
        guard buffer.count >= 4 else { return nil }
        let total = Int(buffer[3]) + 5
        guard buffer.count >= total else { return nil }
        if let frame = try? SSMPacket.decode(Array(buffer[0..<total])) {
            return (frame, total)
        }
        // Not a valid frame at this 0x80: skip it and resync.
        return (nil, 1)
    }
}
