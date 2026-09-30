import AppKit
import SSMKit

/// Builds the diagnostic report (log, system info, crash reports) and gets it to the developer.
@MainActor
enum DiagnosticReporter {
    static func context(_ model: AppModel) -> [String] {
        var lines = ["Connection type: \(model.mode.title)",
                     "State: \(describe(model.connection))",
                     "Demo: \(model.isDemo ? "yes" : "no")"]
        if model.mode == .obd {
            lines.append("Adapter: \(model.isDemo ? "simulated" : model.selectedAdapterLabel)")
            if let info = model.obdInfo {
                lines.append("Adapter version: \(info.adapter)")
                lines.append("Bus protocol: \(info.protocolName.isEmpty ? "unknown" : info.protocolName)")
                lines.append("Supported values: \(info.supportedPIDs.count)")
            }
            lines.append("Bluetooth: \(model.bleStatus)")
        } else {
            lines.append("Cable: \(model.isDemo ? "simulated" : model.selectedPortLabel)")
            if let id = model.identity { lines.append("ECU ID: \(id.ecuID)") }
        }
        lines.append("Samples per second: \(String(format: "%.1f", model.samplesPerSecond))")
        if let error = model.pollError { lines.append("Last poll error: \(error)") }
        return lines
    }

    private static func describe(_ state: ConnectionState) -> String {
        switch state {
        case .disconnected: return "not connected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .failed(let message): return "failed: \(message)"
        }
    }

    private static func version() -> String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "dev") (build \(info?["CFBundleVersion"] as? String ?? "0"))"
    }

    private static func build(model: AppModel) -> URL? {
        do {
            return try DiagnosticReport.build(context: context(model), appVersion: version())
        } catch {
            alert("Could not create the report", error.localizedDescription)
            return nil
        }
    }

    /// Opens a new email to the developer with the report attached.
    static func send(model: AppModel) {
        guard let url = build(model: model) else { return }
        let subject = "SubieScope \(version()) diagnostic report"
        let body = "Hi Marvin,\n\nHere is a diagnostic report from SubieScope. What happened (and what car and adapter or cable I use):\n\n\n"
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [body, url]) {
            service.recipients = [Links.supportEmail]
            service.subject = subject
            service.perform(withItems: [body, url])
        } else {
            // No mail app set up: leave the file where it can be found and say what to do with it.
            NSWorkspace.shared.activateFileViewerSelecting([url])
            alert("The report is ready",
                  "No email app is set up on this Mac, so the report is shown in Finder. Please email it to \(Links.supportEmail), or attach it to a report on GitHub.")
        }
    }

    static func save(model: AppModel) {
        guard let url = build(model: model) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            alert("Could not save the report", error.localizedDescription)
        }
    }

    static func revealLog() {
        let log = DiagnosticLog.shared
        log.flush()
        if FileManager.default.fileExists(atPath: log.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log.fileURL])
        } else {
            NSWorkspace.shared.open(log.directory)
        }
    }

    private static func alert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
