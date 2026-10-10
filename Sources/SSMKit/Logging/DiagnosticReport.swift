import Foundation

/// Everything worth sending when something went wrong, in one zip: the log, a description of
/// the Mac and the connection, and any crash reports macOS wrote for SubieScope.
public enum DiagnosticReport {
    public static var systemCrashReportsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// `context` describes the app state (connection type, adapter, protocol ...).
    public static func build(log: DiagnosticLog = .shared, context: [String], appVersion: String,
                             crashReports: URL? = nil, maxCrashReports: Int = 5) throws -> URL {
        log.flush()
        let fm = FileManager.default
        let stamp = stampFormatter.string(from: Date())
        let folderName = "SubieScope Report \(stamp)"
        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = work.appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let home = NSHomeDirectory()
        var text = ["SubieScope diagnostic report", "Created \(SystemTimeZone.text(Date(), date: .complete, time: .standard))",
                    "App version \(appVersion)", "", "Connection"]
        text += context.map { "  \($0)" }
        text += ["", "System"] + DiagnosticLog.systemSummary().map { "  \($0)" }
        text += ["", "The log below is the end of the log file. The complete files are in the logs folder.", "",
                 log.recentLines(400)]
        try text.joined(separator: "\n").replacingOccurrences(of: home, with: "~")
            .write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)

        let logs = folder.appendingPathComponent("logs", isDirectory: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: log.directory.path)) ?? [] where name.hasPrefix("subiescope") && name.hasSuffix(".log") {
            try? fm.copyItem(at: log.directory.appendingPathComponent(name), to: logs.appendingPathComponent(name))
        }

        // macOS writes a crash report for every crash; the newest ones say exactly where it happened.
        let crashDirectory = crashReports ?? systemCrashReportsDirectory
        let candidates = ((try? fm.contentsOfDirectory(at: crashDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("SubieScope") && ["ips", "crash"].contains($0.pathExtension) }
            .sorted { modified($0) > modified($1) }
            .prefix(maxCrashReports)
        if !candidates.isEmpty {
            let crashes = folder.appendingPathComponent("crash-reports", isDirectory: true)
            try fm.createDirectory(at: crashes, withIntermediateDirectories: true)
            for url in candidates {
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                try? content.replacingOccurrences(of: home, with: "~")
                    .write(to: crashes.appendingPathComponent(url.lastPathComponent), atomically: true, encoding: .utf8)
            }
        }

        let destination = fm.temporaryDirectory.appendingPathComponent("\(folderName).zip")
        try? fm.removeItem(at: destination)
        guard Platform.zip(folder: folder, to: destination) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Could not create the report file."])
        }
        return destination
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
}
