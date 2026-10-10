import CSerial
import Foundation

public enum SerialError: Error, LocalizedError, Equatable {
    case openFailed(path: String, reason: String)
    /// Another program has the port open. A port goes to one program at a time.
    case inUse(path: String)
    case configureFailed(String)
    case notOpen
    case writeFailed(String)
    case readFailed(String)
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let reason): return "Could not open \(path): \(reason)"
        case .inUse(let path):
            return "Another program is using this port right now (\(path)), so it can't be opened here. That can be SubieScope itself (the app, or subiescope-cli in a terminal) or a tool such as RomRaider. Close it there, or disconnect it, and try again."
        case .configureFailed(let reason): return "Could not configure the serial port: \(reason)"
        case .notOpen: return "The serial port is not open."
        case .writeFailed(let reason): return "Writing to the cable failed: \(reason)"
        case .readFailed(let reason): return "Reading from the cable failed: \(reason)"
        case .disconnected: return "The cable was disconnected."
        }
    }
}

/// Blocking serial port (a POSIX device on a Mac, a COM port on Windows). Not thread safe: use it from one thread or queue.
public final class SerialPort {
    public let path: String
    private var fd: Int32 = -1

    public init(path: String) {
        self.path = path
    }

    deinit {
        close()
    }

    public var isOpen: Bool { fd >= 0 }

    public func open(baud: UInt32, parity: Character = "N", stopBits: Int = 1) throws {
        close()
        let handle = cserial_open(path)
        guard handle >= 0 else {
            if errno == EBUSY { throw SerialError.inUse(path: path) }
            throw SerialError.openFailed(path: path, reason: String(cString: strerror(errno)))
        }
        fd = handle
        let parityByte = CChar(parity.asciiValue ?? UInt8(ascii: "N"))
        guard cserial_configure(fd, baud, parityByte, Int32(stopBits)) == 0 else {
            let reason = String(cString: strerror(errno))
            close()
            throw SerialError.configureFailed(reason)
        }
        // Best effort: FTDI adapters otherwise hold received bytes for up to 16 ms.
        _ = cserial_set_read_latency(fd, 1000)
        // DTR on, RTS off: what FreeSSM and RomRaider use with KKL cables.
        _ = cserial_set_control_lines(fd, 1, 0)
        _ = cserial_flush(fd, 2)
    }

    public func close() {
        guard fd >= 0 else { return }
        _ = cserial_set_break(fd, 0)
        _ = cserial_close(fd)
        fd = -1
    }

    public func setControlLines(dtr: Bool, rts: Bool) throws {
        guard fd >= 0 else { throw SerialError.notOpen }
        _ = cserial_set_control_lines(fd, dtr ? 1 : 0, rts ? 1 : 0)
    }

    public func setBreak(_ on: Bool) throws {
        guard fd >= 0 else { throw SerialError.notOpen }
        guard cserial_set_break(fd, on ? 1 : 0) == 0 else {
            throw SerialError.writeFailed(String(cString: strerror(errno)))
        }
    }

    public func discardInput() {
        guard fd >= 0 else { return }
        _ = cserial_flush(fd, 0)
    }

    /// Writes all bytes and waits until they have left the UART.
    public func write(_ bytes: [UInt8]) throws {
        guard fd >= 0 else { throw SerialError.notOpen }
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { buf in
                Int(cserial_write(fd, buf.baseAddress, Int32(buf.count)))
            }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                if errno == ENXIO || errno == EIO { throw SerialError.disconnected }
                throw SerialError.writeFailed(String(cString: strerror(errno)))
            }
            offset += n
        }
        _ = cserial_drain(fd)
    }

    /// Reads until `count` bytes arrived or `timeout` elapsed. Returns what was read,
    /// which may be fewer than `count` bytes on timeout.
    public func read(count: Int, timeout: TimeInterval) throws -> [UInt8] {
        guard fd >= 0 else { throw SerialError.notOpen }
        var result: [UInt8] = []
        result.reserveCapacity(count)
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: max(count, 1))
        while result.count < count {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            let ready = cserial_wait_readable(fd, Int32(max(1, (remaining * 1000).rounded(.up))))
            if ready < 0 { throw SerialError.disconnected }
            if ready == 0 { break }
            let want = count - result.count
            let n = buffer.withUnsafeMutableBytes { buf in
                Int(cserial_read(fd, buf.baseAddress, Int32(want)))
            }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw SerialError.readFailed(String(cString: strerror(errno)))
            }
            if n == 0 {
                // Readable but no data: the device is gone.
                throw SerialError.disconnected
            }
            result.append(contentsOf: buffer[0..<n])
        }
        return result
    }

    /// Returns whatever arrives within `timeout`, stopping early once the line has
    /// been quiet for `idle` seconds after the first byte.
    public func readAvailable(timeout: TimeInterval, idle: TimeInterval = 0.05) throws -> [UInt8] {
        guard fd >= 0 else { throw SerialError.notOpen }
        var result: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let limit = result.isEmpty ? deadline.timeIntervalSinceNow : min(idle, deadline.timeIntervalSinceNow)
            if limit <= 0 { break }
            let ready = cserial_wait_readable(fd, Int32(max(1, (limit * 1000).rounded(.up))))
            if ready < 0 { throw SerialError.disconnected }
            if ready == 0 { break }
            let n = buffer.withUnsafeMutableBytes { buf in
                Int(cserial_read(fd, buf.baseAddress, Int32(buf.count)))
            }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw SerialError.readFailed(String(cString: strerror(errno)))
            }
            if n == 0 { throw SerialError.disconnected }
            result.append(contentsOf: buffer[0..<n])
        }
        return result
    }
}
