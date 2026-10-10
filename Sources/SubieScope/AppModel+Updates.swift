import Foundation
import SSMKit

/// Looks on GitHub for a newer release: once a day when the app opens, and from the SubieScope menu.
extension AppModel {
    /// Another sheet or prompt is already asking for attention.
    private var isShowingPrompt: Bool { showWizard || showCrashPrompt || showCableSetup || showModeChooser }

    /// When the app opens. A development build (swift run) has no version to compare, so it only checks on request.
    func checkForUpdatesAtLaunch() {
        guard autoUpdateCheck, About.version != nil else { return }
        let last = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "lastUpdateCheck"))
        guard abs(Date().timeIntervalSince(last)) > 24 * 3600 else { return }
        Task { await checkForUpdates(manual: false) }
    }

    /// `manual` is a check from the menu: it always answers, also with "up to date", with what went wrong,
    /// and with a version that was skipped before. The automatic check only speaks up for a new version.
    func checkForUpdates(manual: Bool) async {
        guard !checkingForUpdates else { return }
        checkingForUpdates = true
        defer { checkingForUpdates = false }

        let release: UpdateRelease
        do {
            release = try await UpdateCheck.latest()
        } catch {
            DiagnosticLog.shared.info("update", "Update check failed: \(error.localizedDescription)")
            if manual { updateCheckFailed(error) }
            return
        }

        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        guard release.isNewer(than: About.version) else {
            defaults.set(now, forKey: "lastUpdateCheck")
            if manual {
                Desktop.alert("SubieScope is up to date",
                              "You have version \(About.version ?? "?"). The newest release is \(release.version).")
            }
            return
        }
        DiagnosticLog.shared.info("update", "SubieScope \(release.version) is available")
        if !manual {
            #if os(Windows)
            // A release without a Windows build is news for Mac users only.
            if release.download == nil {
                defaults.set(now, forKey: "lastUpdateCheck")
                return
            }
            #endif
            if defaults.string(forKey: "skippedUpdate") == release.version {
                defaults.set(now, forKey: "lastUpdateCheck")
                return
            }
            // Not on top of the setup wizard or the crash prompt: the next launch looks again.
            if isShowingPrompt { return }
        }
        defaults.set(now, forKey: "lastUpdateCheck")
        updateOffer = release
    }

    private func updateCheckFailed(_ error: Error) {
        let choice = Desktop.alert(
            "Could not check for updates",
            "SubieScope could not ask GitHub for the newest version. Check the internet connection and try again, or look at the releases page yourself.\n\nWhat went wrong: \(error.localizedDescription)",
            buttons: ["OK", "Open Releases Page"])
        if choice == 1 { Desktop.open(Links.releases) }
    }

    /// Hands the disk image to the browser. A release without one opens its page instead.
    func downloadUpdate(_ release: UpdateRelease) {
        Desktop.open(release.download ?? release.page)
        updateOffer = nil
    }

    /// Stay quiet about this version. The next one is offered again.
    func skipUpdate(_ release: UpdateRelease) {
        UserDefaults.standard.set(release.version, forKey: "skippedUpdate")
        updateOffer = nil
    }
}
