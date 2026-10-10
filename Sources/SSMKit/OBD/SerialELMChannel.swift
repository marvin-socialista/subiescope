import Foundation

/// An ELM327 adapter on a serial port: a USB ELM327 cable, or a Bluetooth Classic adapter that
/// macOS shows as a serial port once it is paired.
///
/// Experimental: written from the ELM327 data sheet and tested against the simulated adapter only.
public final class SerialELMChannel: ELMChannel, @unchecked Sendable {
    /// Speeds USB adapters are known to use, most likely first: 38400 is the ELM327's own default,
    /// 115200 is what OBDLink and vLinker cables use, 9600 is the ELM327's other factory setting.
    public static let baudRates: [UInt32] = [38400, 115200, 9600, 57600, 230400, 500000]

    /// The speed the adapter answered at.
    public let baud: UInt32

    private let port: SerialPort
    private let lock = NSLock()
    private var closed = false
    private var busy = false

    /// Opens the port and finds the adapter's speed, which takes a few seconds at worst.
    public static func open(path: String) async throws -> SerialELMChannel {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try SerialELMChannel(path: path) })
            }
        }
    }

    init(path: String, baudRates: [UInt32] = SerialELMChannel.baudRates, probeTimeout: TimeInterval = 0.6) throws {
        let port = SerialPort(path: path)
        var found: UInt32?
        for rate in baudRates {
            do {
                try port.open(baud: rate)
            } catch SerialError.configureFailed {
                continue   // a speed this port cannot do
            } catch {
                throw OBDError.adapterNotFound("\(error.localizedDescription). Is the adapter still plugged into your \(Platform.computer), and is no other app using it?")
            }
            // The port opens the way a KKL cable wants it, with RTS off. An adapter that looks at RTS
            // takes that as "do not send", so raise it, like terminal programs do.
            try? port.setControlLines(dtr: true, rts: true)
            // Give the adapter a moment after the port opens before talking to it.
            Thread.sleep(forTimeInterval: 0.05)
            if Self.answers(port, timeout: probeTimeout) {
                found = rate
                break
            }
        }
        guard let found else {
            port.close()
            throw OBDError.adapterNotFound(
                "No OBD-II adapter answered on this port. Check that it is an ELM327 type adapter (a VAG KKL cable only works in Subaru SSM mode), and that it is plugged into the car with the ignition ON.")
        }
        self.port = port
        baud = found
        DiagnosticLog.shared.info("elm", "Serial adapter on \(path) answers at \(found) baud")
    }

    /// Whether an ELM327 answers at the port's current speed. "ATI" only asks for its name. At the
    /// wrong speed the reply is noise, or nothing at all.
    private static func answers(_ port: SerialPort, timeout: TimeInterval) -> Bool {
        port.discardInput()
        guard (try? port.write(Array("ATI\r".utf8))) != nil else { return false }
        var reply: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        while !reply.contains(prompt) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let chunk = try? port.readAvailable(timeout: remaining, idle: 0) else { return false }
            reply += chunk.filter { $0 != 0 }
        }
        return reply.allSatisfy { $0 == 13 || $0 == 10 || (32...126).contains($0) }
    }

    private static let prompt = UInt8(ascii: ">")

    // MARK: ELMChannel

    public func exchange(_ command: String, timeout: TimeInterval) throws -> String {
        lock.lock()
        if closed { lock.unlock(); throw OBDError.disconnected }
        busy = true
        lock.unlock()
        defer { finish() }
        do {
            port.discardInput()
            try port.write(Array((command + "\r").utf8))
            var reply: [UInt8] = []
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if let end = reply.firstIndex(of: Self.prompt) {
                    return String(decoding: reply[..<end], as: UTF8.self)
                }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { throw OBDError.timeout(command) }
                if isClosed { throw OBDError.disconnected }
                // Short waits, so a close() from another thread is noticed quickly. An ELM327 may
                // slip null bytes into its replies; the data sheet says to ignore them.
                reply += try port.readAvailable(timeout: min(remaining, 0.2), idle: 0).filter { $0 != 0 }
            }
        } catch SerialError.disconnected, SerialError.notOpen {
            throw OBDError.disconnected
        }
    }

    public func close() {
        lock.lock()
        closed = true
        // An exchange that is still waiting closes the port itself, rather than losing it mid-read.
        if !busy { port.close() }
        lock.unlock()
    }

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    private func finish() {
        lock.lock()
        busy = false
        if closed { port.close() }
        lock.unlock()
    }
}
