import Foundation

#if canImport(Network)

import Network

/// An ELM327 adapter over Wi-Fi. These adapters make their own Wi-Fi network and listen on a
/// plain TCP port, nearly always 192.168.0.10 port 35000.
///
/// Experimental: tested against the simulated adapter only.
public final class TCPELMChannel: ELMChannel, @unchecked Sendable {
    private let address: String
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "subiescope.tcp.channel")
    private var opening: CheckedContinuation<Void, Error>?

    private let cond = NSCondition()
    private var buffer = Data()
    private var disconnected = false

    private init(host: String, port: UInt16, timeout: TimeInterval) {
        address = "\(host):\(port)"
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true   // requests are a few bytes each: send them right away
        tcp.connectionTimeout = Int(timeout.rounded(.up))
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port),
                                  using: NWParameters(tls: nil, tcp: tcp))
    }

    /// Connects to the adapter. The Mac has to be on the adapter's Wi-Fi network already.
    public static func open(host: String, port: UInt16, timeout: TimeInterval = 8) async throws -> TCPELMChannel {
        let channel = TCPELMChannel(host: host, port: port, timeout: timeout)
        try await channel.openConnection(timeout: timeout)
        return channel
    }

    private func openConnection(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                opening = continuation
                connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    finishOpening(.failure(OBDError.adapterNotFound(
                        "Could not reach the adapter at \(address). Join the adapter's own Wi-Fi network on your Mac first, with the adapter plugged into the car and the ignition ON. \(Self.permissionHint)")))
                }
            }
        }
    }

    /// The first connection makes macOS ask for permission, and fails while the question is on screen.
    private static let permissionHint = "If macOS asked whether SubieScope may find devices on your local network, allow it and press Connect again."

    private func finishOpening(_ result: Result<Void, Error>) {
        guard let continuation = opening else { return }
        opening = nil
        if case .failure = result { connection.cancel() }
        continuation.resume(with: result)
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            DiagnosticLog.shared.info("tcp", "Connected to \(address)")
            receive()
            finishOpening(.success(()))
        case .waiting(let error):
            // Refused, or no route: the address is wrong or the Mac is on another network.
            DiagnosticLog.shared.warning("tcp", "Waiting: \(error.localizedDescription)")
            finishOpening(.failure(OBDError.adapterNotFound(
                "Could not connect to the adapter at \(address) (\(error.localizedDescription)). Check that your Mac is on the adapter's Wi-Fi network, and the address: most adapters use \(OBDAdapterLink.defaultHost) port \(OBDAdapterLink.defaultPort). \(Self.permissionHint)")))
        case .failed(let error):
            DiagnosticLog.shared.warning("tcp", "Failed: \(error.localizedDescription)")
            markDisconnected()
            finishOpening(.failure(OBDError.adapterNotFound("Could not connect to the adapter at \(address): \(error.localizedDescription).")))
        case .cancelled:
            markDisconnected()
        default:
            break
        }
    }

    private func markDisconnected() {
        cond.lock(); disconnected = true; cond.broadcast(); cond.unlock()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            cond.lock()
            if let data { buffer.append(data) }
            if isComplete || error != nil { disconnected = true }
            cond.broadcast()
            cond.unlock()
            if !isComplete && error == nil { receive() }
        }
    }

    // MARK: ELMChannel

    public func exchange(_ command: String, timeout: TimeInterval) throws -> String {
        cond.lock()
        buffer.removeAll()
        cond.unlock()
        connection.send(content: Data((command + "\r").utf8), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.markDisconnected() }
        })

        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        defer { cond.unlock() }
        while true {
            if let end = buffer.firstIndex(of: UInt8(ascii: ">")) {
                let text = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...end)
                return text
            }
            if disconnected { throw OBDError.disconnected }
            if !cond.wait(until: deadline) { throw OBDError.timeout(command) }
        }
    }

    public func close() {
        connection.cancel()
        markDisconnected()
    }
}

#else

import CSerial

/// An ELM327 adapter over Wi-Fi. These adapters make their own Wi-Fi network and listen on a
/// plain TCP port, nearly always 192.168.0.10 port 35000.
///
/// Experimental: tested against the simulated adapter only.
public final class TCPELMChannel: ELMChannel, @unchecked Sendable {
    private let address: String
    private let socket: Int32

    private let cond = NSCondition()
    private var buffer = Data()
    private var disconnected = false

    private init(address: String, socket: Int32) {
        self.address = address
        self.socket = socket
    }

    /// Connects to the adapter. The PC has to be on the adapter's Wi-Fi network already.
    public static func open(host: String, port: UInt16, timeout: TimeInterval = 8) async throws -> TCPELMChannel {
        let address = "\(host):\(port)"
        let socket: Int32 = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: cserial_tcp_connect(host, Int32(port), Int32(timeout * 1000)))
            }
        }
        guard socket >= 0 else {
            DiagnosticLog.shared.warning("tcp", "Could not connect to \(address)")
            throw OBDError.adapterNotFound(
                "Could not reach the adapter at \(address). Join the adapter's own Wi-Fi network on your PC first, with the adapter plugged into the car and the ignition ON. Check the address too: most adapters use \(OBDAdapterLink.defaultHost) port \(OBDAdapterLink.defaultPort).")
        }
        DiagnosticLog.shared.info("tcp", "Connected to \(address)")
        let channel = TCPELMChannel(address: address, socket: socket)
        let reader = Thread { channel.receive() }
        reader.name = "SubieScope Wi-Fi adapter"
        reader.start()
        return channel
    }

    private func markDisconnected() {
        cond.lock(); disconnected = true; cond.broadcast(); cond.unlock()
    }

    private var isDisconnected: Bool {
        cond.lock(); defer { cond.unlock() }
        return disconnected
    }

    /// Runs on its own thread until the connection ends.
    private func receive() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !isDisconnected {
            let ready = cserial_wait_readable(socket, 200)
            if ready == 0 { continue }
            let count = ready > 0 ? chunk.withUnsafeMutableBytes { cserial_read(socket, $0.baseAddress, Int32($0.count)) } : -1
            if count <= 0 { break }
            cond.lock()
            buffer.append(contentsOf: chunk[0..<Int(count)])
            cond.broadcast()
            cond.unlock()
        }
        markDisconnected()
        _ = cserial_release(socket)
    }

    // MARK: ELMChannel

    public func exchange(_ command: String, timeout: TimeInterval) throws -> String {
        cond.lock()
        buffer.removeAll()
        let gone = disconnected
        cond.unlock()
        if gone { throw OBDError.disconnected }
        let bytes = Array((command + "\r").utf8)
        let sent = bytes.withUnsafeBytes { cserial_write(socket, $0.baseAddress, Int32($0.count)) }
        if sent < 0 { markDisconnected() }

        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        defer { cond.unlock() }
        while true {
            if let end = buffer.firstIndex(of: UInt8(ascii: ">")) {
                let text = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...end)
                return text
            }
            if disconnected { throw OBDError.disconnected }
            if !cond.wait(until: deadline) { throw OBDError.timeout(command) }
        }
    }

    /// The reading thread sees this and closes the socket itself.
    public func close() {
        markDisconnected()
    }
}

#endif
