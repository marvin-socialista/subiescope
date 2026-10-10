import Foundation
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
            if let found = model.extendedDiscovery {
                lines.append("ECU ID (ROM ID): \(found.romID ?? "not reported")")
                lines.append("Extended values answered: \(found.ids.count)")
                for (ecu, identifiers) in found.unnamed.sorted(by: { $0.key < $1.key }) {
                    lines.append("Listed by \(ecu) without a definition (\(identifiers.count)): \(ExtendedDiscovery.hex(identifiers))")
                }
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
        #if os(Windows)
        return About.version ?? "dev"
        #else
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "dev") (build \(info?["CFBundleVersion"] as? String ?? "0"))"
        #endif
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
        if !Desktop.composeEmail(to: Links.supportEmail, subject: subject, body: body, attachment: url) {
            // No mail app set up: leave the file where it can be found and say what to do with it.
            Desktop.reveal(url)
            alert("The report is ready",
                  "\(Desktop.noMailApp), so the report is shown in \(Desktop.fileBrowser). Please email it to \(Links.supportEmail), or attach it to a report on GitHub.")
        }
    }

    static func save(model: AppModel) {
        guard let url = build(model: model) else { return }
        guard let destination = Desktop.chooseSaveLocation(suggestedName: url.lastPathComponent) else { return }
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
            Desktop.reveal(log.fileURL)
        } else {
            Desktop.open(log.directory)
        }
    }

    private static func alert(_ title: String, _ detail: String) {
        Desktop.alert(title, detail)
    }
}
