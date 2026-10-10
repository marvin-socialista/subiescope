import SSMKit
import SwiftUI

@main
struct SubieScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        // One main window: every view shares the same connection and model.
        Window("SubieScope", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1020, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About SubieScope") { About.showPanel() }
                Button("Check for Updates…") { Task { await model.checkForUpdates(manual: true) } }
                    .disabled(model.checkingForUpdates)
            }
            CommandGroup(replacing: .help) {
                Button("SubieScope on GitHub") { NSWorkspace.shared.open(Links.repository) }
                Button("Report a Problem…") { NSWorkspace.shared.open(Links.issues) }
                Button("Send Diagnostic Report…") { DiagnosticReporter.send(model: model) }
                Button("Save Diagnostic Report…") { DiagnosticReporter.save(model: model) }
                Button("Show Log in Finder") { DiagnosticReporter.revealLog() }
                Divider()
                Button("Buy Me a Coffee ☕︎") { NSWorkspace.shared.open(About.coffeeURL) }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Log…") { openLogPanel(model) }
                    .keyboardShortcut("o", modifiers: [.command])
            }
            CommandMenu("Car") {
                Button(model.connection.isConnected ? "Disconnect" : "Connect") {
                    if model.connection.isConnected { model.disconnect() } else { Task { await model.connect() } }
                }
                .keyboardShortcut("k", modifiers: [.command])
                Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggleRecording() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(!model.connection.isConnected)
                Divider()
                Button("Read Trouble Codes") { Task { await model.readTroubleCodes() } }
                    .disabled(!model.connection.isConnected)
                Divider()
                Button("Setup Wizard…") { model.showWizard = true }
                    .disabled(model.connection == .connecting)
                Button("Connection Type…") { model.showModeChooser = true }
                    .disabled(model.connection.isConnected || model.connection == .connecting)
                if model.mode == .obd {
                    Button("Refresh Adapter List") { model.restartBLEScan() }
                } else {
                    Button("Refresh Cable List") { model.refreshPorts() }
                    Button("Cable Setup…") { model.showCableSetup = true }
                }
            }
            CommandGroup(after: .sidebar) {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { model.section = section }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
    func applicationWillFinishLaunching(_ notification: Notification) {
        // A run that only serves the page must not put a window on the screen, not even for a moment.
        if WebDevServer.isAskedFor { NSApp.setActivationPolicy(.prohibited) }
    }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare executable (swift run) is not a real app bundle: make it behave like one.
        #if DEBUG
        // -webDev: this run only serves the Windows app's page (see WebDevServer), without a window.
        if WebDevServer.isAskedFor {
            WebDevServer.startIfAskedFor()
            return
        }
        #endif
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        #if DEBUG
        if WebDevServer.isAskedFor { return false }
        #endif
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticLog.shared.markCleanExit()
    }

    /// CSV logs opened from Finder ("Open With > SubieScope") or dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "csv" }) else { return }
        Task { @MainActor in
            AppModel.shared.section = .logs
            await AppModel.shared.openLog(url)
        }
    }
}
