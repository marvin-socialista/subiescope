import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A version such as "0.4.0", or a release tag such as "v0.4.0", compared number by number.
struct AppVersion: Comparable {
    /// Without trailing zeros, so 0.4 and 0.4.0 are the same version.
    let parts: [Int]

    /// Nil when the text is not a dotted number ("dev", "").
    init?(_ text: String) {
        var text = Substring(text.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        // "0.5.0-beta1" counts as 0.5.0.
        text = text.prefix { $0 != "-" && $0 != "+" }
        var numbers: [Int] = []
        for piece in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard let number = Int(piece), number >= 0 else { return nil }
            numbers.append(number)
        }
        while numbers.last == 0 { numbers.removeLast() }
        parts = numbers
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        a.parts.lexicographicallyPrecedes(b.parts)
    }
}

/// A published SubieScope release on GitHub.
public struct UpdateRelease: Equatable, Identifiable, Sendable {
    /// "0.5.0": the release tag without its "v".
    public let version: String
    /// The release notes, as Markdown.
    public let notes: String
    /// The release page on GitHub.
    public let page: URL
    /// The file to download for this computer, when the release has one: the disk image on a Mac,
    /// the Windows build on a PC.
    public let download: URL?

    public var id: String { version }

    public init(version: String, notes: String, page: URL, download: URL?) {
        self.version = version
        self.notes = notes
        self.page = page
        self.download = download
    }

    /// Whether this release is newer than the running app. A development build has no version
    /// (nil), so every release counts as newer.
    public func isNewer(than current: String?) -> Bool {
        guard let mine = AppVersion(version) else { return false }
        guard let current, let theirs = AppVersion(current) else { return true }
        return mine > theirs
    }

    /// The notes as shown in the app: the list of changes, without the "What's new" heading above it
    /// and without the install instructions and links below it, which belong on the release page.
    public var whatsNew: String {
        var lines = notes.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if let install = lines.firstIndex(where: { $0.lowercased().hasPrefix("**install") }) {
            lines.removeSubrange(install...)
        }
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[first].lowercased().replacingOccurrences(of: "’", with: "'").hasPrefix("**what's new") {
            lines.removeSubrange(...first)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Asks GitHub for the newest SubieScope release.
public enum UpdateCheck {
    /// Drafts and pre-releases are never "latest", so this only ever answers a finished release.
    static let latestRelease = URL(string: "https://api.github.com/repos/marvin-socialista/subiescope/releases/latest")!

    public enum CheckError: Error, LocalizedError {
        case server(Int)
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .server(let status): return "GitHub answered with an error (\(status))."
            case .unreadable: return "GitHub's answer could not be read."
            }
        }
    }

    public static func latest() async throws -> UpdateRelease {
        var request = URLRequest(url: latestRelease, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CheckError.server(status) }
        return try parse(data)
    }

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }

        let tagName: String
        let htmlUrl: URL
        let body: String?
        let assets: [Asset]?
    }

    /// Whether a file of a release is the download for a Windows PC ("SubieScope-0.7.0-windows-x64.zip",
    /// or an installer) or for a Mac (the .dmg).
    static func isDownload(_ name: String, windows: Bool) -> Bool {
        let name = name.lowercased()
        if windows {
            return name.contains("windows") && (name.hasSuffix(".zip") || name.hasSuffix(".exe") || name.hasSuffix(".msi"))
        }
        return name.hasSuffix(".dmg")
    }

    /// Reads GitHub's "latest release" answer. `windows` says which computer the download is for.
    static func parse(_ data: Data, windows: Bool = Platform.isWindows) throws -> UpdateRelease {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(Payload.self, from: data), AppVersion(payload.tagName) != nil else {
            throw CheckError.unreadable
        }
        var version = payload.tagName.trimmingCharacters(in: .whitespaces)
        if version.first == "v" || version.first == "V" { version.removeFirst() }
        let download = payload.assets?.first { isDownload($0.name, windows: windows) }
        return UpdateRelease(version: version, notes: payload.body ?? "", page: payload.htmlUrl, download: download?.browserDownloadUrl)
    }
}
