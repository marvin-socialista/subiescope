import CSerial
import Foundation

/// Puts a `SimulatedELM` behind a real connection: a pseudo terminal, which stands in for a USB
/// ELM327 cable, or a TCP port on this Mac, which stands in for a Wi-Fi adapter. That way
/// `SerialELMChannel` and `TCPELMChannel` can be tested, and tried in the app, without the hardware.
public final class SimulatedELMServer: @unchecked Sendable {
    public let adapter: SimulatedELM
    /// The device to open, e.g. /dev/ttys012. Only for the pseudo terminal.
    public let devicePath: String?
    /// The port to connect to on 127.0.0.1. Only for TCP.
    public let port: UInt16?

    /// Answers this many requests with noise first, as an adapter does when it is spoken to at the wrong speed.
    public var garbledReplies: Int {
        get { lock.lock(); defer { lock.unlock() }; return _garbledReplies }
        set { lock.lock(); _garbledReplies = newValue; lock.unlock() }
    }

    private let lock = NSLock()
    private var _garbledReplies = 0
    private var running = true
    private var descriptors: [Int32]

    /// A simulated USB cable: open `devicePath` like any serial port.
    public static func serial(adapter: SimulatedELM = SimulatedELM()) throws -> SimulatedELMServer {
        var controller: Int32 = -1
        var device: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        guard cserial_openpty(&controller, &device, &name, Int32(name.count)) == 0 else {
            throw SerialError.openFailed(path: "pty", reason: String(cString: strerror(errno)))
        }
        // The device side stays open here, so the pair survives the client opening and closing it.
        let server = SimulatedELMServer(adapter: adapter, devicePath: String(cString: name), port: nil, descriptors: [controller, device])
        server.start { [controller] in server.serve(controller, untilHangUp: false) }
        return server
    }

    /// A simulated Wi-Fi adapter on 127.0.0.1. Port 0 picks a free one: read it from `port`.
    public static func network(adapter: SimulatedELM = SimulatedELM(), port: UInt16 = 0) throws -> SimulatedELMServer {
        #if os(Windows)
        var bound: Int32 = 0
        let listener = cserial_tcp_listen(Int32(port), &bound)
        guard listener >= 0 else { throw SerialError.openFailed(path: "tcp port \(port)", reason: String(cString: strerror(errno))) }
        let server = SimulatedELMServer(adapter: adapter, devicePath: nil, port: UInt16(bound), descriptors: [listener])
        server.start { server.accept(on: listener) }
        return server
        #else
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw SerialError.openFailed(path: "tcp", reason: String(cString: strerror(errno))) }
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(listener, generic, length) == 0 && listen(listener, 1) == 0 && getsockname(listener, generic, &length) == 0
            }
        }
        guard bound else {
            let reason = String(cString: strerror(errno))
            _ = cserial_release(listener)
            throw SerialError.openFailed(path: "tcp port \(port)", reason: reason)
        }
        let server = SimulatedELMServer(adapter: adapter, devicePath: nil, port: UInt16(bigEndian: address.sin_port), descriptors: [listener])
        server.start { server.accept(on: listener) }
        return server
        #endif
    }

    private init(adapter: SimulatedELM, devicePath: String?, port: UInt16?, descriptors: [Int32]) {
        self.adapter = adapter
        self.devicePath = devicePath
        self.port = port
        self.descriptors = descriptors
    }

    deinit {
        stop()
    }

    public func stop() {
        lock.lock()
        let open = descriptors
        descriptors = []
        running = false
        lock.unlock()
        open.forEach { _ = cserial_release($0) }
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func start(_ work: @escaping @Sendable () -> Void) {
        let thread = Thread(block: work)
        thread.name = "SimulatedELMServer"
        thread.start()
    }

    /// One client at a time, like the real adapters.
    private func accept(on listener: Int32) {
        while isRunning {
            guard cserial_wait_readable(listener, 100) > 0 else { continue }
            #if os(Windows)
            let client = cserial_accept(listener)
            guard client >= 0 else { continue }
            #else
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { continue }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            #endif
            serve(client, untilHangUp: true)
            _ = cserial_release(client)
        }
    }

    /// Answers every request line (ended by a carriage return) with the adapter's reply and its prompt.
    private func serve(_ fd: Int32, untilHangUp: Bool) {
        var line: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 256)
        while isRunning {
            let ready = cserial_wait_readable(fd, 100)
            if ready == 0 { continue }
            let count = ready > 0 ? chunk.withUnsafeMutableBytes { Int(cserial_read(fd, $0.baseAddress, Int32($0.count))) } : -1
            if count <= 0 {
                if untilHangUp { return }
                // A pseudo terminal: no client has the device open right now. Wait for one.
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            for byte in chunk[0..<count] {
                guard byte == 13 else { line.append(byte); continue }
                let command = String(decoding: line, as: UTF8.self)
                line.removeAll()
                if takeGarbledReply() {
                    write([0xF8, 0x00, 0x7E, 0xFC, 0xE0], to: fd)
                } else if let reply = try? adapter.exchange(command, timeout: 1) {
                    write(Array((reply + "\r>").utf8), to: fd)
                }
            }
        }
    }

    private func takeGarbledReply() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _garbledReplies > 0 else { return false }
        _garbledReplies -= 1
        return true
    }

    private func write(_ bytes: [UInt8], to fd: Int32) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Int(cserial_write(fd, $0.baseAddress, Int32($0.count))) }
            if n <= 0 { return }
            offset += n
        }
    }
}
