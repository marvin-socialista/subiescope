import CWebView2
import Foundation
import SSMKit
import WinSDK

/// SubieScope for Windows starts here. The Mac app starts in SubieScopeApp.swift; both are a
/// front on the same AppModel.
@main
@MainActor
enum WindowsApp {
    static let defaults = UserDefaults.standard
    static let programFolder = Bundle.main.executableURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: ".")
    /// %LOCALAPPDATA%\SubieScope: where the app keeps what it needs between runs.
    static let localData = (ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory).appendingPathComponent("SubieScope", isDirectory: true)

    static func main() {
        // For developing the page: -debugPort 9222 lets a browser's developer tools attach to it.
        let debugPort = defaults.string(forKey: "debugPort").flatMap { Int($0) }
        if let debugPort {
            _putenv_s("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", "--remote-debugging-port=\(debugPort)")
        }

        SystemTimeZone.apply()

        // The model starts the log, looks for cables and connects when it was asked to.
        let model = AppModel.shared
        let bridge = Bridge(model: model)

        guard let window = AppWindow(title: "SubieScope", size: (1280, 820), activate: !defaults.bool(forKey: "background")) else {
            Desktop.alert("SubieScope could not open its window", "Windows refused to make the window. Restart the PC and try again.")
            exit(1)
        }

        // -webRoot points at the page's files in the source tree, so a change shows after a reload.
        // Otherwise they are next to the program, in the folder SwiftPM made for this target's resources
        // (its name differs between SwiftPM versions).
        let webRoot = defaults.string(forKey: "webRoot").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? ["SubieScope_SubieScope.bundle/Web", "SubieScope_SubieScope.resources/Web", "Web"]
                .map { programFolder.appendingPathComponent($0, isDirectory: true) }
                .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
            ?? programFolder.appendingPathComponent("SubieScope_SubieScope.bundle/Web", isDirectory: true)
        let dark = host_dark_mode() != 0

        window.webView.onReady = { ok, detail in
            guard ok else {
                DiagnosticLog.shared.error("window", "No web view: \(detail)")
                Desktop.alert("SubieScope could not start", "SubieScope shows its window with WebView2, a part of Windows that also comes with the Edge browser. It could not be started: \(detail).\n\nInstall the \"WebView2 Runtime\" from Microsoft and start SubieScope again.")
                exit(1)
            }
            DiagnosticLog.shared.info("window", "Web view ready, page from \(webRoot.path)")
            // The colour of the page itself, so nothing flashes while it loads.
            if dark {
                window.webView.setBackground(red: 0x1E, green: 0x1E, blue: 0x1E)
            } else {
                window.webView.setBackground(red: 0xF4, green: 0xF4, blue: 0xF5)
            }
            window.webView.setDeveloperMode(defaults.bool(forKey: "devTools") || debugPort != nil)
            window.webView.map(host: "subiescope.example", to: webRoot)
            window.webView.navigate("https://subiescope.example/index.html")
        }
        // A log file dropped on the program's icon, or opened with it from File Explorer.
        if let log = CommandLine.arguments.dropFirst().first(where: { $0.lowercased().hasSuffix(".csv") && !$0.hasPrefix("-") }) {
            Task { @MainActor in
                model.section = .logs
                await model.openLog(URL(fileURLWithPath: log))
            }
        }

        // The page and the model talk through the bridge, in both directions.
        bridge.transmit = { json in window.webView.post(json: json) }
        window.webView.onMessage = { json in bridge.receive(json) }
        window.onClose = {
            if model.isRecording { model.toggleRecording() }
            model.disconnect()
            DiagnosticLog.shared.markCleanExit()
        }
        window.webView.start(in: window.handle, loader: programFolder.appendingPathComponent("WebView2Loader.dll"),
                             dataFolder: localData.appendingPathComponent("WebView", isDirectory: true))
        exit(window.run())
    }
}
