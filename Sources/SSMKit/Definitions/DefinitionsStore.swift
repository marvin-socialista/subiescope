import CryptoKit
import Foundation

/// Where the RomRaider logger definitions live on this Mac, and how to get them.
///
/// The file has no explicit license, so SubieScope doesn't ship it: it downloads
/// the official v370 file on first launch (from a pinned mirror, verified by
/// checksum, with romraider.com as fallback) into Application Support.
public enum DefinitionsStore {
    public static let fileName = "logger_METRIC_EN_v370.xml"
    static let mirror = URL(string: "https://raw.githubusercontent.com/zhuker/dash22b/3a9f6fa45a2a2885733fca185ae2c2490338dac0/app/src/main/assets/logger_METRIC_EN_v370.xml")!
    /// SHA-256 of the official file with CR characters removed.
    static let sha256LF = "1fb44a6438bf64979ea44e4302306d598da3bd33009da13cf383d7acaa5a964c"
    static let forumPage = URL(string: "https://www.romraider.com/forum/")!
    static let forumZip = URL(string: "https://www.romraider.com/forum/download/file.php?id=38909")!

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SubieScope/Definitions", isDirectory: true)
    }

    public static var installedURL: URL? {
        let url = directory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public enum DownloadError: Error, LocalizedError {
        case checksum
        case unzip

        public var errorDescription: String? {
            switch self {
            case .checksum: return "The downloaded definitions did not match the expected file."
            case .unzip: return "Could not unpack the definitions from romraider.com."
            }
        }
    }

    static func verify(_ data: Data) -> Bool {
        let lf = Data(data.filter { $0 != 0x0D })
        return SHA256.hash(data: lf).map { String(format: "%02x", $0) }.joined() == sha256LF
    }

    /// Downloads and installs the definitions. Returns the installed file.
    @discardableResult
    public static func download() async throws -> URL {
        let data: Data
        do {
            let (d, response) = try await URLSession.shared.data(from: mirror)
            guard (response as? HTTPURLResponse)?.statusCode == 200, verify(d) else { throw DownloadError.checksum }
            data = d
        } catch {
            data = try await downloadFromForum()
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// romraider.com wants a browser user agent and a session cookie from any forum page.
    static func downloadFromForum() async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"]
        let session = URLSession(configuration: config)
        _ = try await session.data(from: forumPage)
        let (zip, _) = try await session.data(from: forumZip)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("subiescope-defs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let zipURL = temp.appendingPathComponent("defs.zip")
        try zip.write(to: zipURL)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipURL.path, temp.path]
        try unzip.run()
        unzip.waitUntilExit()
        let enumerator = FileManager.default.enumerator(at: temp, includingPropertiesForKeys: nil)
        while let file = enumerator?.nextObject() as? URL {
            if file.lastPathComponent == fileName, let data = try? Data(contentsOf: file), verify(data) { return data }
        }
        throw DownloadError.unzip
    }
}
