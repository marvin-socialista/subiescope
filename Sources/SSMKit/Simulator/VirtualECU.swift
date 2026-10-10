import CSerial
import Foundation

/// A software SSM2 engine control unit on a pseudo terminal.
///
/// It behaves like an ECU behind a KKL cable: every byte the client writes is
/// echoed back first (the single K-line wire), then the reply follows. Clients
/// connect to `devicePath` through the normal `SerialPort`, so the whole stack
/// including termios handling is exercised.
public final class VirtualECU: @unchecked Sendable {
    public struct Identity: Sendable {
        public var systemID: [UInt8]
        public var romID: [UInt8]
        public var capabilities: [UInt8]

        public init(systemID: [UInt8], romID: [UInt8], capabilities: [UInt8]) {
            self.systemID = systemID
            self.romID = romID
            self.capabilities = capabilities
        }
    }

    public let devicePath: String
    public var identity: Identity
    /// Returns the byte at an address. Called on the simulator thread.
    public var memory: @Sendable (UInt32) -> UInt8
    /// Called for 0xB8 writes; return the value to report back (normally the written one).
    public var onWrite: (@Sendable (UInt32, UInt8) -> UInt8)?
    /// Reply delay, like a real ECU's processing time.
    public var responseDelay: TimeInterval = 0.01
    public var echoesRequests = true
    /// When false the ECU stays silent (simulates ignition off).
    public var isPoweredOn = true
    /// Delay replies as if they travelled at this baud rate (0 = as fast as possible).
    public var simulatedBaudRate: Double = 4800
    /// The most bytes a read request and its answer may take together. A real ECU stays silent
    /// when a request is too long: a 2008 STI answered 37 addresses and ignored 84, and
    /// RomRaider's protocol notes give about 250 bytes for the echoed request plus the answer.
    public var maxExchangeBytes = 250

    /// Addresses being streamed in continuous mode (0xA8 with flag 0x01).
    private var streaming: [UInt32]?

    private let controller: Int32
    private var device: Int32
    private let lock = NSLock()
    private var running = true
    private var thread: Thread?

    public init(identity: Identity, memory: @escaping @Sendable (UInt32) -> UInt8) throws {
        var c: Int32 = -1
        var d: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        guard cserial_openpty(&c, &d, &name, Int32(name.count)) == 0 else {
            throw SerialError.openFailed(path: "pty", reason: String(cString: strerror(errno)))
        }
        controller = c
        device = d
        devicePath = String(cString: name)
        self.identity = identity
        self.memory = memory
        let t = Thread { [weak self] in self?.run() }
        t.name = "VirtualECU"
        thread = t
        t.start()
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

    /// A real ECU stops streaming on a BREAK; a pseudo terminal cannot carry one,
    /// so the client's transport calls this instead.
    public func simulateBreak() {
        lock.lock(); defer { lock.unlock() }
        streaming = nil
    }

    private var streamingAddresses: [UInt32]? {
        lock.lock(); defer { lock.unlock() }
        return streaming
    }

    private func wireTime(_ bytes: Int) -> TimeInterval {
        simulatedBaudRate > 0 ? Double(bytes * 10) / simulatedBaudRate : 0
    }

    private func readReply(_ addresses: [UInt32]) -> SSMPacket {
        reply([0xE8] + addresses.map { memory($0) })
    }

    private func run() {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 512)
        while isRunning {
            let stream = streamingAddresses
            let waitMs = stream.map { max(1, Int32(wireTime($0.count + 6) * 1000)) } ?? 100
            let ready = cserial_wait_readable(controller, waitMs)
            if ready < 0 {
                // No client has the device open right now; wait for one.
                if !isRunning { return }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            if ready == 0 {
                if let stream, isPoweredOn, let encoded = try? readReply(stream).encoded() {
                    writeAll(encoded)
                }
                continue
            }
            let n = chunk.withUnsafeMutableBytes { Int(cserial_read(controller, $0.baseAddress, Int32($0.count))) }
            if n <= 0 {
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            let bytes = Array(chunk[0..<n])
            if echoesRequests { writeAll(bytes) }
            buffer.append(contentsOf: bytes)

            while let (frame, consumed) = SSMTransport.extractFrame(from: buffer) {
                buffer.removeFirst(consumed)
                guard let frame, frame.destination == SSMDevice.engine.rawValue, isPoweredOn else { continue }
                if let reply = handle(frame) {
                    let requestBytes = frame.data.count + 5
                    let replyBytes = reply.data.count + 5
                    Thread.sleep(forTimeInterval: wireTime(requestBytes) + responseDelay + wireTime(replyBytes))
                    if let encoded = try? reply.encoded() { writeAll(encoded) }
                }
            }
        }
    }

    private func writeAll(_ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Int(cserial_write(controller, $0.baseAddress, Int32($0.count))) }
            if n <= 0 { return }
            offset += n
        }
    }

    private func reply(_ data: [UInt8]) -> SSMPacket {
        SSMPacket(destination: SSMDevice.tester.rawValue, source: SSMDevice.engine.rawValue, data: data)
    }

    /// Addresses the ECU refuses to read over CAN (it answers 7F A8 12), as tuneforge's author saw a
    /// 2007 Forester XT do for values in its RAM. Empty: it reads everything.
    public var refusedOverCAN: Set<UInt32> {
        get { lock.lock(); defer { lock.unlock() }; return _refusedOverCAN }
        set { lock.lock(); _refusedOverCAN = newValue; lock.unlock() }
    }
    private var _refusedOverCAN: Set<UInt32> = []

    /// Answers a request that came in over CAN: the same commands without the K-line's header and
    /// checksum, `AA` to identify (answered with `EA`), no continuous mode, and a spoken "no"
    /// (7F, the command, a reason) where the K-line ECU stays silent. Returns nil for silence.
    public func answerOverCAN(_ request: [UInt8]) -> [UInt8]? {
        guard isPoweredOn, let command = request.first else { return nil }
        var data = request
        switch command {
        case OpenPortCANLine.identifyCommand:
            data[0] = SSMCommand.initECU
        case SSMCommand.readAddresses:
            guard data.count >= 5, (data.count - 2) % 3 == 0 else { return [0x7F, command, 0x12] }
            data[1] = 0x00
            let refused = refusedOverCAN
            var i = 2
            while i + 2 < data.count {
                if refused.contains(UInt32(data[i]) << 16 | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2])) { return [0x7F, command, 0x12] }
                i += 3
            }
        case SSMCommand.readBlock, SSMCommand.writeAddress:
            break
        default:
            return [0x7F, command, 0x11]
        }
        let packet = SSMPacket(destination: SSMDevice.engine.rawValue, source: SSMDevice.tester.rawValue, data: data)
        guard var answer = handle(packet, lengthLimit: false)?.data, !answer.isEmpty else { return nil }
        if command == OpenPortCANLine.identifyCommand { answer[0] = SSMCommand.response(to: command) }
        return answer
    }

    func handle(_ request: SSMPacket, lengthLimit: Bool = true) -> SSMPacket? {
        guard let command = request.command else { return nil }
        let p = Array(request.payload)
        switch command {
        case SSMCommand.initECU:
            return reply([0xFF] + identity.systemID + identity.romID + identity.capabilities)
        case SSMCommand.readAddresses:
            guard p.count >= 1 else { return nil }
            var addresses: [UInt32] = []
            var i = 1
            while i + 2 < p.count {
                addresses.append(UInt32(p[i]) << 16 | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]))
                i += 3
            }
            // Too long: no answer at all, only the echo the cable makes by itself.
            guard !lengthLimit || request.data.count + 5 + addresses.count + 6 <= maxExchangeBytes else { return nil }
            lock.lock()
            streaming = p[0] == 0x01 ? addresses : nil
            lock.unlock()
            return readReply(addresses)
        case SSMCommand.readBlock:
            guard p.count >= 5 else { return nil }
            let address = UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
            let count = Int(p[4]) + 1
            return reply([0xE0] + (0..<count).map { memory(address + UInt32($0)) })
        case SSMCommand.writeAddress:
            guard p.count >= 4 else { return nil }
            let address = UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2])
            let value = onWrite?(address, p[3]) ?? p[3]
            return reply([0xF8, value])
        default:
            return reply([0x7F, command])
        }
    }
}
