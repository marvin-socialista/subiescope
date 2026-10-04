import SSMKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.section) {
                Section("Car") {
                    ForEach([AppSection.dashboard, .logger, .diagnostics, .recipes, .ecuInfo]) { section in
                        // The tag must be the outermost modifier or the row can't be selected.
                        Label(section.title, systemImage: section.symbol)
                            .badge(section == .diagnostics ? badgeCount : 0)
                            .tag(section)
                    }
                }
                Section("Files") {
                    Label(AppSection.logs.title, systemImage: AppSection.logs.symbol).tag(AppSection.logs)
                    Label(AppSection.dyno.title, systemImage: AppSection.dyno.symbol).tag(AppSection.dyno)
                }
                Section("Tools") {
                    Label(AppSection.console.title, systemImage: AppSection.console.symbol).tag(AppSection.console)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                ConnectionCard()
                    .padding(10)
            }
        } detail: {
            Group {
                switch model.section {
                case .dashboard: DashboardView()
                case .logger: LoggerView()
                case .recipes: RecipesView()
                case .diagnostics: DiagnosticsView()
                case .ecuInfo: ECUInfoView()
                case .logs: LogsView()
                case .dyno: DynoView()
                case .console: ConsoleView()
                }
            }
            .navigationTitle(model.section.title)
            .toolbar { MainToolbar() }
        }
        .tint(.scopeBlue)
        .sheet(isPresented: $model.showCableSetup) {
            CableSetupView().environment(model)
        }
        .sheet(isPresented: $model.showModeChooser) {
            ModeChooserView().environment(model)
        }
        .sheet(isPresented: $model.showWizard) {
            SetupWizardView().environment(model)
        }
        .sheet(item: $model.updateOffer) { release in
            UpdateView(release: release).environment(model)
        }
        .alert("SubieScope quit unexpectedly last time", isPresented: $model.showCrashPrompt) {
            Button("Send Report…") { DiagnosticReporter.send(model: model) }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Sorry about that. A report helps to find out why. It holds the log of what happened and your Mac model, and nothing else. To be safe, SubieScope did not connect automatically this time: press Connect when you are ready.")
        }
    }

    private var badgeCount: Int {
        model.currentCodes.count + model.memorizedCodes.count
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .navigation) {
            DevicePicker()
                .frame(minWidth: 220, maxWidth: 320)

            Button {
                if model.mode == .obd { model.restartBLEScan() } else { model.refreshPorts() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help(model.mode == .obd ? "Look for Bluetooth adapters again" : "Look for cables again")
            .disabled(model.connection.isConnected)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if model.connection == .connecting {
                ProgressView().controlSize(.small)
            }
            Button {
                if model.connection.isConnected {
                    model.disconnect()
                } else {
                    Task { await model.connect() }
                }
            } label: {
                Label(model.connection.isConnected ? "Disconnect" : "Connect",
                      systemImage: model.connection.isConnected ? "bolt.slash" : "bolt.horizontal")
            }
            .help(model.connection.isConnected ? "Disconnect from the car (⌘K)" : "Connect to the car (⌘K)")
            .disabled(model.connection == .connecting)

            RecordButton()
        }
    }
}

struct RecordButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.toggleRecording()
        } label: {
            if model.isRecording, let start = model.recordingStart {
                HStack(spacing: 6) {
                    Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text(Duration.seconds(context.date.timeIntervalSince(start)).formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit()
                    }
                }
            } else {
                Label("Record", systemImage: "record.circle")
            }
        }
        .help(model.isRecording ? "Stop recording (⌘R)" : "Record the logged parameters to a CSV file (⌘R)")
        .disabled(!model.connection.isConnected || model.loggedIDs.isEmpty)
    }
}
