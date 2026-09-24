import Foundation

/// Writes samples in the same CSV layout as RomRaider's logger, so existing log
/// viewers (RomRaider, DataLog Lab, Datazap, Virtual Dyno) can open the files.
public final class CSVLogWriter {
    public struct Column: Sendable {
        public var id: String
        public var title: String
        public var conversion: Conversion

        public init(id: String, title: String, conversion: Conversion) {
            self.id = id
            self.title = title
            self.conversion = conversion
        }

        public var header: String { "\(title) (\(conversion.units))" }
    }

    public let url: URL
    public let columns: [Column]
    public private(set) var rowCount = 0
    private let handle: FileHandle
    private var pending = Data()
    private var start: Date?

    public init(url: URL, columns: [Column]) throws {
        self.url = url
        self.columns = columns
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        let header = (["Time (msec)"] + columns.map { Self.escape($0.header) }).joined(separator: ",") + "\r\n"
        pending.append(Data(header.utf8))
    }

    public func append(time: Date, values: [String: Double]) {
        if start == nil { start = time }
        let ms = Int((time.timeIntervalSince(start!) * 1000).rounded())
        var fields = [String(ms)]
        fields.reserveCapacity(columns.count + 1)
        for column in columns {
            if let v = values[column.id], v.isFinite {
                fields.append(column.conversion.formatted(v))
            } else {
                fields.append("")
            }
        }
        pending.append(Data((fields.joined(separator: ",") + "\r\n").utf8))
        rowCount += 1
        if pending.count > 16_384 { flush() }
    }

    public func flush() {
        guard !pending.isEmpty else { return }
        try? handle.write(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
    }

    public func close() {
        flush()
        try? handle.close()
    }

    static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// e.g. romraiderlog_20260924_214501.csv, the name RomRaider uses.
    public static func defaultFileName(date: Date = Date(), prefix: String = "subiescope") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "\(prefix)_\(f.string(from: date)).csv"
    }
}
