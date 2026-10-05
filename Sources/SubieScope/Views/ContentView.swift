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
                    if model.advancedMode {
                        Label(AppSection.rom.title, systemImage: AppSection.rom.symbol).tag(AppSection.rom)
                    }
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
                case .rom: if model.advancedMode { ROMView() } else { AdvancedLockedView() }
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
        .sheet(isPresented: $model.showAdvancedDisclaimer) {
            AdvancedModeDisclaimer().environment(model)
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
                if model.mode == .obd { model.restartBLEScan() }
                model.refreshPorts()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help(model.mode == .obd ? "Look for adapters again" : "Look for cables again")
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

/// Shown in place of the ROM editor when Advanced mode is off, so the section explains itself rather
/// than being silently empty (e.g. if opened by a keyboard shortcut or a launch argument).
struct AdvancedLockedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("ROM reading and editing is in Advanced mode")
                .font(.title3.weight(.semibold))
            Text("This is for reading a ROM (an ECU tune) from the car and editing it on your Mac. It is risky and separate from the normal logging and diagnostics, so it is off until you turn it on.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            Button { model.showAdvancedDisclaimer = true } label: {
                Label("Turn On Advanced Mode…", systemImage: "exclamationmark.shield")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The warning the user must accept before Advanced mode (ROM reading and editing) turns on.
struct AdvancedModeDisclaimer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Turn on Advanced mode?", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.orange)
            Text("Advanced mode unlocks the ROM Editor: reading a ROM (an ECU tune) from a file or from the car, and editing it on your Mac.")
                .font(.headline)
            ScrollView {
                Text(ROMDisclaimer.full)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.3), lineWidth: 1))

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    model.advancedMode = true
                    model.section = .rom
                    dismiss()
                } label: {
                    Label("I Understand, Turn It On", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}
