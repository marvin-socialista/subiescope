import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            Form {
                Picker("Units", selection: $model.unitSystem) {
                    Text("Metric (°C, kPa, km/h)").tag(UnitSystem.metric)
                    Text("Imperial (°F, psi, mph)").tag(UnitSystem.imperial)
                }
                Text("You can still pick other units per parameter in the Logger.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Logs folder") {
                    HStack {
                        Text(model.logsFolder.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Change…") { chooseLogsFolder() }
                    }
                }

                Toggle("Connect automatically when SubieScope opens", isOn: $model.autoConnect)

                Toggle("Fast poll (continuous mode)", isOn: $model.fastPoll)
                Text("The ECU keeps sending values without being asked each time, roughly doubling the sample rate. Turn it off if logging stalls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                if let defs = model.definitions {
                    LabeledContent("Loaded", value: defs.sourceURL.lastPathComponent)
                    LabeledContent("Version", value: defs.version ?? "?")
                    LabeledContent("Contents", value: "\(defs.standard.count) standard, \(defs.extended.count) ECU specific, \(defs.switches.count) switches, \(defs.codes.count) trouble codes")
                }
                if let error = model.definitionsError {
                    Text(error).foregroundStyle(.red)
                }
                HStack {
                    Button("Choose Definition File…") { chooseDefinitions() }
                    Button("Use Downloaded") { model.useBundledDefinitions() }
                    Button(model.downloadingDefinitions ? "Downloading…" : "Download Again") {
                        Task { await model.downloadDefinitions() }
                    }
                    .disabled(model.downloadingDefinitions)
                }
                Text("SubieScope reads RomRaider logger definitions (logger_METRIC_EN_v370.xml or newer). Newer files add ECU IDs and parameters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("RomRaider logger definitions", destination: URL(string: "https://www.romraider.com/forum/post66788.html")!)
            }
            .formStyle(.grouped)
            .tabItem { Label("Definitions", systemImage: "doc.text") }

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 360)
    }

    private func chooseLogsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.logsFolder
        if panel.runModal() == .OK, let url = panel.url { model.logsFolder = url }
    }

    private func chooseDefinitions() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { model.loadDefinitions(from: url) }
    }
}
