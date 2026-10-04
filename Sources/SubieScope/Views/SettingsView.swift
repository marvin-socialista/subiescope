import AppKit
import SSMKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            Form {
                LabeledContent("Connection type") {
                    HStack {
                        Text("\(model.mode.title): \(model.mode.hardware)").foregroundStyle(.secondary)
                        Button("Change…") { model.showModeChooser = true }
                            .disabled(model.connection.isConnected)
                    }
                }
                Picker("Units", selection: $model.unitSystem) {
                    Text("Metric (°C, kPa, km/h)").tag(UnitSystem.metric)
                    Text("Imperial (°F, psi, mph)").tag(UnitSystem.imperial)
                }
                Picker("Pressure", selection: $model.pressureUnit) {
                    ForEach(PressureUnit.allCases) { Text($0.title).tag($0) }
                }
                Text("Boost and other pressures in kPa, bar or psi. You can still pick other units per parameter in the Logger.")
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

                Toggle("Check for updates automatically", isOn: $model.autoUpdateCheck)
                Text("Once a day when SubieScope opens, it asks GitHub for the newest version and tells you when there is one. Nothing about you or your car is sent. You can always look yourself with SubieScope > Check for Updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.mode == .obd {
                    Toggle("Extended values (experimental)", isOn: $model.extendedValuesOn)
                    Text("Asks the car for manufacturer specific values such as AVCS (VVT) angles, knock and boost control, using OBD-II Mode 22. Only some cars answer, mostly newer Subarus, and the values come from community data, so check them against what you expect. Nothing is shown when your car does not answer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Let the command line tool control the app (developer)", isOn: $model.remoteControlOn)
                Text("Lets programs you run on this Mac send read-only requests to the connected adapter through subiescope-cli. Off by default. Nothing that clears codes or writes to the car gets through.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.mode == .ssm {
                    Toggle("Fast poll (continuous mode)", isOn: $model.fastPoll)
                    Text("The ECU keeps sending values without being asked each time, roughly doubling the sample rate. Turn it off if logging stalls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
