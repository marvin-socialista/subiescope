import Foundation
import Testing
@testable import SSMKit

@Suite("Update check")
struct UpdateCheckTests {
    /// GitHub's answer for a release, cut down to the fields that matter plus a few that don't.
    static func answer(tag: String, body: String = "**What's new**\n- Something", assets: [String] = ["SubieScope.dmg"]) -> Data {
        let assetList = assets.map { name in
            ["name": name, "size": 1, "browser_download_url": "https://github.com/marvin-socialista/subiescope/releases/download/\(tag)/\(name)"] as [String: Any]
        }
        let json: [String: Any] = [
            "tag_name": tag, "name": "SubieScope", "draft": false, "prerelease": false,
            "html_url": "https://github.com/marvin-socialista/subiescope/releases/tag/\(tag)",
            "body": body, "assets": assetList,
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func comparesVersionsByNumber() throws {
        let v = { (text: String) in try #require(AppVersion(text)) }
        #expect(try v("0.4.0") < v("0.5.0"))
        #expect(try v("0.9.0") < v("0.10.0")) // not alphabetical
        #expect(try v("0.4.9") < v("1.0"))
        #expect(try v("0.4") < v("0.4.1"))
        #expect(try v("0.4") == v("0.4.0"))
        #expect(try v("v0.4.0") == v("0.4.0"))
        #expect(try v("0.5.0-beta1") == v("0.5.0"))
        #expect(try !(v("0.4.0") < v("0.4.0")))
        #expect(AppVersion("dev") == nil)
        #expect(AppVersion("") == nil)
        #expect(AppVersion("1..2") == nil)
    }

    @Test func readsTheLatestRelease() throws {
        let release = try UpdateCheck.parse(Self.answer(tag: "v0.5.0"), windows: false)
        #expect(release.version == "0.5.0")
        #expect(release.page.absoluteString == "https://github.com/marvin-socialista/subiescope/releases/tag/v0.5.0")
        #expect(release.download?.absoluteString == "https://github.com/marvin-socialista/subiescope/releases/download/v0.5.0/SubieScope.dmg")
    }

    @Test func picksTheDiskImageAmongTheFiles() throws {
        let release = try UpdateCheck.parse(Self.answer(tag: "v0.5.0", assets: ["checksums.txt", "SubieScope.dmg"]), windows: false)
        #expect(release.download?.lastPathComponent == "SubieScope.dmg")
        let bare = try UpdateCheck.parse(Self.answer(tag: "v0.5.0", assets: []))
        #expect(bare.download == nil)
        // Each computer gets its own file, and never the other's.
        let both = Self.answer(tag: "v0.7.0", assets: ["SubieScope.dmg", "SubieScope-0.7.0-windows-x64.zip"])
        #expect(try UpdateCheck.parse(both, windows: true).download?.lastPathComponent == "SubieScope-0.7.0-windows-x64.zip")
        #expect(try UpdateCheck.parse(both, windows: false).download?.lastPathComponent == "SubieScope.dmg")
        #expect(try UpdateCheck.parse(Self.answer(tag: "v0.5.0", assets: ["SubieScope.dmg"]), windows: true).download == nil)
    }

    @Test func offersOnlyNewerReleases() throws {
        let release = try UpdateCheck.parse(Self.answer(tag: "v0.5.0"))
        #expect(release.isNewer(than: "0.4.0"))
        #expect(release.isNewer(than: "0.4.9"))
        #expect(!release.isNewer(than: "0.5.0"))
        #expect(!release.isNewer(than: "0.6.0")) // a build that is ahead of the releases
        #expect(release.isNewer(than: nil)) // development build
    }

    @Test func rejectsAnswersThatAreNotARelease() {
        #expect(throws: UpdateCheck.CheckError.self) { try UpdateCheck.parse(Data("{\"message\":\"Not Found\"}".utf8)) }
        #expect(throws: UpdateCheck.CheckError.self) { try UpdateCheck.parse(Data("<html>".utf8)) }
        #expect(throws: UpdateCheck.CheckError.self) { try UpdateCheck.parse(Self.answer(tag: "nightly")) }
    }

    @Test func showsOnlyTheChangesFromTheNotes() throws {
        let body = """
        **What's new**
        - **Pressure in bar.** Boost in kPa, bar or psi.
        - **Fixed:** a connected adapter showed as "not in range".

        **Install:** download `SubieScope.dmg` below, open it and drag SubieScope to Applications.

        Please report how it works on your car: https://github.com/marvin-socialista/subiescope/issues
        """
        let release = try UpdateCheck.parse(Self.answer(tag: "v0.5.0", body: body))
        #expect(release.whatsNew == "- **Pressure in bar.** Boost in kPa, bar or psi.\n- **Fixed:** a connected adapter showed as \"not in range\".")

        // Notes in another shape are shown as they are.
        let plain = try UpdateCheck.parse(Self.answer(tag: "v0.5.0", body: "Small fixes.\r\nNothing else."))
        #expect(plain.whatsNew == "Small fixes.\nNothing else.")
    }

    /// The notes of every release so far follow the shape the popup relies on.
    @Test func cutsThePublishedNotesCleanly() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/release-notes")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "md" }
        #expect(!files.isEmpty)
        for file in files {
            let version = file.deletingPathExtension().lastPathComponent
            let release = UpdateRelease(version: version, notes: try String(contentsOf: file, encoding: .utf8),
                                        page: URL(string: "https://example.com")!, download: nil)
            #expect(release.whatsNew.contains("\n- ") || release.whatsNew.hasPrefix("- "), "\(version)")
            #expect(!release.whatsNew.lowercased().contains("**what's new"), "\(version)")
            #expect(!release.whatsNew.lowercased().contains("**install"), "\(version)")
            #expect(!release.whatsNew.contains("buymeacoffee"), "\(version)")
        }
    }
}
