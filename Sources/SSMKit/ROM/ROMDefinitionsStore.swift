import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where the RomRaider ROM definitions (`ecu_defs.xml`) live on this Mac, and how to get them. Like
/// the logger definitions, the file has no license of its own, so it is not part of the app bundle: it
/// is hosted in the SubieScope repo and downloaded on demand, pinned to a commit and verified by
/// checksum, into Application Support. Credit for the definitions is RomRaider's and the community's.
public enum ROMDefinitionsStore {
    public static let fileName = "ecu_defs.xml"
    static let source = URL(string: "https://raw.githubusercontent.com/marvin-socialista/subiescope/35773756d1750d7762bd605215afe19d9a8a7c13/definitions/ecu_defs.xml")!
    /// SHA-256 of the file with CR characters removed (matches how the download is verified).
    static let sha256LF = "6dc90001bc38ad52aaf2b45d8594b764dd5544bf438ca44d9eb641cec1a5552e"

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SubieScope/Definitions", isDirectory: true)
    }

    public static var installedURL: URL? {
        let url = directory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public enum StoreError: Error, LocalizedError {
        case checksum
        case notReachable
        public var errorDescription: String? {
            switch self {
            case .checksum: return "The downloaded ROM definitions did not match the expected file."
            case .notReachable: return "Could not download the ROM definitions. Check the internet connection, or choose a RomRaider ecu_defs.xml yourself."
            }
        }
    }

    static func verify(_ data: Data) -> Bool {
        let lf = Data(data.filter { $0 != 0x0D })
        return Platform.sha256Hex(lf) == sha256LF
    }

    /// Downloads and installs the definitions, returning the installed file.
    @discardableResult
    public static func download() async throws -> URL {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(from: source)
        } catch {
            throw StoreError.notReachable
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StoreError.notReachable }
        guard verify(data) else { throw StoreError.checksum }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// The cached definitions parsed into a set, downloading them first if needed.
    public static func loadOrDownload() async throws -> ROMDefinitionSet {
        let url: URL
        if let installed = installedURL {
            url = installed
        } else {
            url = try await download()
        }
        return try ROMDefinitionParser.load(url: url)
    }
}
