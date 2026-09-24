import AppKit
import SSMKit
import SwiftUI

struct ECUInfoView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Control unit") {
                if let id = model.identity {
                    row("ECU ID", id.ecuID, mono: true)
                    row("Car", model.knownECUDescription ?? "Not in SubieScope's list of 2008 STI ECUs")
                    row("Engine", EngineDiagnostics.engineType(systemID: id.systemID) ?? "Unknown")
                    row("SSM system ID", id.systemIDString, mono: true)
                    row("Capability bytes", "\(id.capabilities.count)")
                    row("VIN", model.vinState)
                } else {
                    Text("Connect to read the ECU's identification.").foregroundStyle(.secondary)
                }
            }
            if let status = model.engineStatus {
                Section("Status") {
                    if let v = status.ignitionOn { row("Ignition", v ? "On" : "Off") }
                    if let v = status.testMode { row("Test mode connector", v ? "Connected (test mode)" : "Not connected") }
                    if let v = status.dCheckPending { row("Self check (D-Check)", v ? "Not yet completed" : "Completed") }
                }
            }
            Section("Parameters for this ECU") {
                let kinds: [(String, ParameterKind)] = [("Standard", .standard), ("ECU specific (extended)", .extended),
                                                        ("Calculated", .calculated), ("Switches", .switchBit)]
                ForEach(kinds, id: \.0) { title, kind in
                    row(title, "\(model.parameters.filter { $0.kind == kind }.count)")
                }
                row("Trouble codes known", "\(model.codeDefinitions.count)")
                if model.identity != nil && model.extendedCount == 0 {
                    Label("This ECU ID is not in the definitions, so knock learning, IAM and other ECU-specific values are unavailable. Standard parameters still work.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
            Section("Definitions") {
                if let defs = model.definitions {
                    row("File", defs.sourceURL.lastPathComponent)
                    row("Version", defs.version ?? "?")
                    row("ECU IDs with extended parameters", "\(defs.ecuIDCount)")
                } else {
                    Text(model.definitionsError ?? "No definitions loaded").foregroundStyle(.red)
                }
            }
            Section("Connection") {
                row("Cable", model.selectedPortLabel)
                row("Protocol", "SSM2 over K-line (ISO 9141), 4800 baud 8N1")
                row("Fast poll", model.fastPoll ? "On" : "Off")
                if model.connection.isConnected {
                    row("Sample rate", String(format: "%.1f samples/s", model.samplesPerSecond))
                    row("Last poll", String(format: "%.0f ms", model.lastRoundTrip * 1000))
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary, forType: .string)
                } label: {
                    Label("Copy Info", systemImage: "doc.on.doc")
                }
                .help("Copy the ECU details, e.g. to ask for help on a forum")
                .disabled(model.identity == nil)
            }
        }
    }

    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(mono ? .body.monospaced() : .body)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }

    private var summary: String {
        guard let id = model.identity else { return "" }
        return """
        ECU ID: \(id.ecuID)
        SSM system ID: \(id.systemIDString) (\(EngineDiagnostics.engineType(systemID: id.systemID) ?? "unknown engine"))
        Car: \(model.knownECUDescription ?? "unknown")
        Capabilities (\(id.capabilities.count) bytes): \(id.capabilities.hexString)
        Definitions: \(model.definitions?.sourceURL.lastPathComponent ?? "-") v\(model.definitions?.version ?? "?")
        Extended parameters available: \(model.extendedCount)
        """
    }
}
