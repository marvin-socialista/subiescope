#if canImport(Darwin)
import Darwin
#else
import CSerial
#endif
import Foundation

/// A log file that stays on the Mac until the user chooses to send it: what happened, when,
/// and what went wrong. Written to ~/Library/Logs/SubieScope/ (on Windows to
/// %LOCALAPPDATA%\SubieScope\Logs). It never throws and never
/// blocks the caller, so logging can not itself become the reason for a problem.
public final class DiagnosticLog: @unchecked Sendable {
    public enum Level: String, Sendable { case debug = "DEBUG", info = "INFO", warning = "WARN", error = "ERROR" }

    public static let shared = DiagnosticLog()

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("subiescope.log") }

    /// The last session ended without a clean exit: a crash, a force quit or a power cut.
    public private(set) var previousSessionEndedUnexpectedly = false

    static let maxBytes = 1_000_000
    static let keptFiles = 3

    private let queue = DispatchQueue(label: "subiescope.diagnostic-log", qos: .utility)
    private var handle: FileHandle?
    private var started = false
    private var enabled = true
    private let home = NSHomeDirectory()
    /// Lines held back until the file is open (or dropped when it can not be).
    private var written = 0

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    static var defaultDirectory: URL {
        // A test run can keep its log, and the marker of a run that was killed, away from the real ones.
        if let folder = ProcessInfo.processInfo.environment["SUBIESCOPE_LOG_DIR"], !folder.isEmpty {
            return URL(fileURLWithPath: folder, isDirectory: true)
        }
        #if os(Windows)
        let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local", isDirectory: true)
        return local.appendingPathComponent("SubieScope/Logs", isDirectory: true)
        #else
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SubieScope", isDirectory: true)
        #endif
    }

    private static var processID: Int32 { ProcessInfo.processInfo.processIdentifier }

    private static func isRunning(_ pid: Int32) -> Bool {
        #if os(Windows)
        return cserial_process_alive(pid) == 1
        #else
        return kill(pid, 0) == 0
        #endif
    }

    // MARK: Writing

    public func write(_ level: Level, _ category: String, _ message: String) {
        let time = Date()
        queue.async { [self] in
            guard enabled else { return }
            openIfNeeded()
            let line = "\(Self.timestamp(time)) \(level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) [\(category)] \(scrub(message))\n"
            append(line)
        }
    }

    public func debug(_ category: String, _ message: String) { write(.debug, category, message) }
    public func info(_ category: String, _ message: String) { write(.info, category, message) }
    public func warning(_ category: String, _ message: String) { write(.warning, category, message) }
    public func error(_ category: String, _ message: String) { write(.error, category, message) }

    /// Waits until everything written so far is on disk (tests, and just before a report is built).
    public func flush() { queue.sync {} }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        do {
            try handle?.write(contentsOf: data)
            written += data.count
            if written > Self.maxBytes { rotate() }
        } catch {
            // A full disk or a removed folder: stop logging instead of retrying on every line.
            enabled = false
            handle = nil
        }
    }

    private func openIfNeeded() {
        guard handle == nil, enabled else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: fileURL)
            written = Int((try? h.seekToEnd()) ?? 0)
            handle = h
            #if canImport(Darwin)
            crashLogDescriptor = h.fileDescriptor
            #endif
        } catch {
            enabled = false
        }
    }

    private func rotate() {
        handle?.closeFile()
        handle = nil
        let fm = FileManager.default
        let oldest = directory.appendingPathComponent("subiescope.\(Self.keptFiles).log")
        try? fm.removeItem(at: oldest)
        for n in stride(from: Self.keptFiles - 1, through: 1, by: -1) {
            let from = directory.appendingPathComponent("subiescope.\(n).log")
            let to = directory.appendingPathComponent("subiescope.\(n + 1).log")
            try? fm.moveItem(at: from, to: to)
        }
        try? fm.moveItem(at: fileURL, to: directory.appendingPathComponent("subiescope.1.log"))
        written = 0
        openIfNeeded()
    }

    /// Seventeen bytes in a row that are all characters a VIN can have (digits, and capitals without I, O and Q).
    static let vinAsBytes: String = {
        let character = "(?:3[0-9]|4[1-8A-E]|5[02-9A])"
        return "\\b(?:\(character) ){16}\(character)\\b"
    }()

    /// Removes what would identify the person: their home folder name and anything shaped like a VIN.
    func scrub(_ text: String) -> String {
        var result = text.replacingOccurrences(of: home, with: "~")
        result = result.replacingOccurrences(of: #"\b[A-HJ-NPR-Z0-9]{17}\b"#, with: "<VIN>", options: .regularExpression)
        // The same seventeen characters as bytes in a line of traffic ("4A 46 31 ..."): how an SSM car's VIN travels.
        result = result.replacingOccurrences(of: Self.vinAsBytes, with: "<VIN>", options: .regularExpression)
        return result
    }

    static func timestamp(_ date: Date) -> String {
        var t = time_t(date.timeIntervalSince1970)
        var parts = tm()
        #if os(Windows)
        localtime_s(&parts, &t)
        #else
        localtime_r(&t, &parts)
        #endif
        let ms = Int((date.timeIntervalSince1970 - floor(date.timeIntervalSince1970)) * 1000)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d.%03d", parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday,
                      parts.tm_hour, parts.tm_min, parts.tm_sec, ms)
    }

    // MARK: Sessions

    /// Marks the start of a run: notes whether the last one ended badly, writes the header and
    /// installs the crash handlers. Safe to call more than once.
    public func startSession(appVersion: String, build: String) {
        let already: Bool = queue.sync { let s = started; started = true; return s }
        guard !already else { return }
        queue.sync {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            previousSessionEndedUnexpectedly = Self.removeStaleMarkers(in: directory)
            try? "\(Self.processID)\n".write(to: marker, atomically: true, encoding: .utf8)
        }
        info("session", "SubieScope \(appVersion) (build \(build)) started")
        for line in Self.systemSummary() { info("system", line) }
        if previousSessionEndedUnexpectedly {
            warning("session", "The previous session did not end cleanly (crash, force quit or power loss).")
        }
        Self.installCrashHandlers()
    }

    /// Call when the app quits normally; without it the next start reports an unclean exit.
    public func markCleanExit() {
        info("session", "Quit normally")
        flush()
        try? FileManager.default.removeItem(at: marker)
    }

    private var marker: URL { directory.appendingPathComponent("running-\(Self.processID).marker") }

    /// Markers left by processes that no longer exist belong to runs that never quit cleanly.
    static func removeStaleMarkers(in directory: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var stale = false
        for name in files where name.hasPrefix("running-") && name.hasSuffix(".marker") {
            let pidText = name.dropFirst("running-".count).dropLast(".marker".count)
            let alive = Int32(pidText).map { isRunning($0) } ?? false
            if !alive {
                stale = true
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        return stale
    }

    // MARK: System information

    public static func systemSummary() -> [String] {
        #if os(Windows)
        let environment = ProcessInfo.processInfo.environment
        var lines = [ProcessInfo.processInfo.operatingSystemVersionString,
                     "PC with \(environment["PROCESSOR_IDENTIFIER"] ?? "an unknown processor")"]
        #if arch(arm64)
        lines.append("Running as: arm64 (native)")
        #else
        lines.append("Running as: x86_64" + (environment["PROCESSOR_ARCHITEW6432"] == "ARM64" ? " (translated on an ARM PC)" : ""))
        #endif
        lines.append("Memory \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB, \(ProcessInfo.processInfo.activeProcessorCount) cores")
        lines.append("Locale \(Locale.current.identifier), time zone \(SystemTimeZone.zone.identifier)")
        return lines
        #else
        func sysctl(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(cString: buffer)
        }
        func sysctlInt(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
        }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var lines = ["macOS \(os)", "Mac \(sysctl("hw.model") ?? "unknown"), \(sysctl("hw.machine") ?? "unknown")"]
        #if arch(arm64)
        lines.append("Running as: arm64 (native)")
        #else
        lines.append("Running as: x86_64" + (sysctlInt("sysctl.proc_translated") == 1 ? " (translated by Rosetta)" : ""))
        #endif
        lines.append("Memory \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB, \(ProcessInfo.processInfo.activeProcessorCount) cores")
        lines.append("Locale \(Locale.current.identifier), time zone \(SystemTimeZone.zone.identifier)")
        return lines
        #endif
    }

    // MARK: Reading

    /// The newest `count` lines, for showing in the app or putting in a report.
    public func recentLines(_ count: Int = 300) -> String {
        flush()
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(count).joined(separator: "\n")
    }

    // MARK: Crashes

    /// File descriptor the signal handler writes to; set once the log file is open.
    nonisolated(unsafe) static var crashLogDescriptor: Int32 = -1
    private var crashLogDescriptor: Int32 {
        get { Self.crashLogDescriptor }
        set { Self.crashLogDescriptor = newValue }
    }
    nonisolated(unsafe) private static var handlersInstalled = false

    static func installCrashHandlers() {
        guard !handlersInstalled else { return }
        handlersInstalled = true
        #if canImport(Darwin)
        // ObjC exceptions (AppKit, Foundation): note the reason before the process dies.
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(25).joined(separator: "\n    ")
            DiagnosticLog.shared.write(.error, "crash", "Uncaught exception \(exception.name.rawValue): \(exception.reason ?? "no reason")\n    \(stack)")
            DiagnosticLog.shared.flush()
        }
        // Swift runtime failures (force unwrap, array index, fatalError) arrive as SIGTRAP or SIGILL.
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            signal(sig) { number in
                // Only async-signal-safe calls in here (no allocation): write(2), backtrace and the default handler.
                let fd = DiagnosticLog.crashLogDescriptor
                if fd >= 0 {
                    let head: StaticString = "\n*** CRASH: the app received signal "
                    _ = Darwin.write(fd, head.utf8Start, head.utf8CodeUnitCount)
                    var digits: (UInt8, UInt8, UInt8) = (UInt8(48 + (number / 10) % 10), UInt8(48 + number % 10), 10)
                    _ = withUnsafeBytes(of: &digits) { Darwin.write(fd, $0.baseAddress, 3) }
                    let stack: StaticString = "Stack:\n"
                    _ = Darwin.write(fd, stack.utf8Start, stack.utf8CodeUnitCount)
                    withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 64) { frames in
                        let count = backtrace(frames.baseAddress!, 64)
                        backtrace_symbols_fd(frames.baseAddress!, count, fd)
                    }
                    fsync(fd)
                }
                signal(number, SIG_DFL)
                raise(number)
            }
        }
        #endif
        // On Windows a crash leaves no trace of its own in the log: the next start still notices it,
        // from the marker file that was not removed.
    }
}
