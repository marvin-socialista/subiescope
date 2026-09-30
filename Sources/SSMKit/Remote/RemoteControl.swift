import Darwin
import Foundation

/// Lets the command line tool (and so a person or an AI agent at a terminal) talk to a running
/// SubieScope: send raw requests to the connected OBD-II adapter, read live values, and try
/// things without rebuilding the app. Off by default; the app turns it on in Settings.
///
/// It is a local Unix socket that only your own user can open, and only read-only requests get
/// through (see `CommandPolicy`): nothing that clears codes, writes to the car or reprograms an ECU.
public enum RemoteControl {
    /// ~/Library/Application Support/SubieScope/control.sock, or a short /tmp path when the home
    /// folder path is too long for a socket (the limit is about 100 bytes).
    public static var defaultSocketPath: String {
        let base = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/SubieScope/control.sock"
        return base.utf8.count <= 100 ? base : "/tmp/subiescope-\(getuid()).sock"
    }
}

/// What may be sent to the car through the remote control. Reading is fine; changing things is not.
public enum CommandPolicy {
    /// OBD-II and UDS services that only read: current data, freeze frame, trouble codes, test results,
    /// vehicle info, read-data-by-identifier, read DTC information, tester present.
    public static let readOnlyServices: Set<UInt8> = [0x01, 0x02, 0x03, 0x05, 0x06, 0x07, 0x09, 0x0A, 0x19, 0x22, 0x3E]

    /// Adapter commands that could change the adapter for good or break the link to the app.
    static let blockedAdapterCommands = ["ATPP", "ATBRD", "ATBRT"]

    /// nil when the command may be sent; otherwise a plain explanation of why not.
    public static func check(_ command: String) -> String? {
        let text = command.trimmingCharacters(in: .whitespaces).uppercased()
        if text.isEmpty { return "Empty command." }
        if text.hasPrefix("AT") {
            let compact = text.filter { !$0.isWhitespace }
            if let blocked = blockedAdapterCommands.first(where: { compact.hasPrefix($0) }) {
                return "\(blocked) can change the adapter permanently or break the connection, so it is not allowed here."
            }
            return nil
        }
        let hex = text.filter { !$0.isWhitespace }
        // An odd length is fine: an ELM327 accepts a trailing reply-count digit ("010C1").
        guard hex.count >= 2, hex.allSatisfy(\.isHexDigit) else {
            return "Not a hex request or an AT command."
        }
        guard let service = UInt8(hex.prefix(2), radix: 16) else { return "Not a hex request." }
        guard readOnlyServices.contains(service) else {
            return String(format: "Service %02X is not read-only, so it is not allowed. Allowed: %@.", service,
                          readOnlyServices.sorted().map { String(format: "%02X", $0) }.joined(separator: " "))
        }
        return nil
    }
}

public enum RemoteError: Error, LocalizedError {
    case notRunning(String)
    case socket(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning(let path):
            return "SubieScope is not listening. Open SubieScope and turn on Settings > General > \"Let the command line tool control the app\" (or start it with: open -n SubieScope.app --args -remoteControl YES). Socket: \(path)"
        case .socket(let detail):
            return detail
        }
    }
}

/// Serves one request per connection: a line of text in, lines of text out, ended by a line with a single ".".
public final class RemoteServer: @unchecked Sendable {
    public let path: String
    public typealias Handler = @Sendable (String) -> [String]
    private let handler: Handler
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var running = false

    public init(path: String = RemoteControl.defaultSocketPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RemoteError.socket("Could not create the control socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw RemoteError.socket("The control socket path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, byte) in bytes.enumerated() { buffer[i] = byte }
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw RemoteError.socket("Could not bind the control socket: \(reason)")
        }
        chmod(path, 0o600)   // only this user
        guard listen(fd, 4) == 0 else {
            close(fd); unlink(path)
            throw RemoteError.socket("Could not listen on the control socket.")
        }
        listener = fd
        running = true
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "SubieScope remote control"
        thread.start()
        DiagnosticLog.shared.info("remote", "Control socket listening at \(path)")
    }

    public func stop() {
        lock.lock()
        let fd = listener
        let wasRunning = running
        running = false
        listener = -1
        lock.unlock()
        guard wasRunning else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
        DiagnosticLog.shared.info("remote", "Control socket closed")
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }   // closed by stop()
            let handler = self.handler
            Thread.detachNewThread {
                var line: [UInt8] = []
                var byte: UInt8 = 0
                while line.count < 8192, read(client, &byte, 1) == 1, byte != 10 { line.append(byte) }
                let request = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let reply = handler(request)
                let out = reply.isEmpty ? ".\n" : (reply.joined(separator: "\n") + "\n.\n")
                _ = out.withCString { write(client, $0, strlen($0)) }
                close(client)
            }
        }
    }
}

public enum RemoteClient {
    /// Sends one request and returns the reply lines.
    public static func send(_ line: String, path: String = RemoteControl.defaultSocketPath, timeout: TimeInterval = 30) throws -> [String] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RemoteError.socket(String(cString: strerror(errno))) }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw RemoteError.socket("Socket path too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, byte) in bytes.enumerated() { buffer[i] = byte }
            buffer[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw RemoteError.notRunning(path) }
        let request = line.replacingOccurrences(of: "\n", with: " ") + "\n"
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        if lines.last == "." { lines.removeLast() }
        return lines
    }
}
