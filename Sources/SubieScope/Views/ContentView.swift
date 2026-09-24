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
    }

    private var badgeCount: Int {
        model.currentCodes.count + model.memorizedCodes.count
    }
}

/// Connection status shown at the bottom of the sidebar.
struct ConnectionCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(state: model.connection)
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var title: String {
        if model.isPlayingBack { return "Log playback" }
        switch model.connection {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected: return model.isDemo ? "Demo ECU" : "Connected"
        case .failed: return "Connection problem"
        }
    }

    private var detail: String {
        if model.isPlayingBack, let playback = model.playback {
            return "\(playback.url.lastPathComponent) · \(formatLogTime(playback.playhead)) / \(formatLogTime(playback.duration))"
        }
        switch model.connection {
        case .connected:
            let rate = model.samplesPerSecond > 0 ? String(format: " · %.1f samples/s", model.samplesPerSecond) : ""
            return "ECU \(model.identity?.ecuID ?? "?")\(rate)"
        case .failed(let message):
            return message
        case .connecting:
            return model.selectedPortLabel
        case .disconnected:
            return model.ports.isEmpty ? "Plug in the cable, or pick Demo ECU to try the app." : model.selectedPortLabel
        }
    }
}

struct StatusDot: View {
    let state: ConnectionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay {
                if state == .connected {
                    Circle().stroke(color.opacity(0.4), lineWidth: 4).scaleEffect(1.6)
                }
            }
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .navigation) {
            Picker("Cable", selection: $model.selectedPortID) {
                if model.ports.isEmpty {
                    Text("No cable found").tag(String?.none)
                }
                ForEach(model.ports) { port in
                    Text(port.displayName).tag(Optional(port.path))
                }
                Divider()
                Text("Demo ECU (simulated)").tag(Optional(AppModel.demoPortID))
            }
            .frame(minWidth: 220, maxWidth: 320)
            .disabled(model.connection == .connecting || model.connection.isConnected)
            .help("The USB cable to use. FTDI cables show up as \"FT232R USB UART\".")

            Button {
                model.refreshPorts()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Look for cables again")
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
            .help(model.connection.isConnected ? "Disconnect from the ECU (⌘K)" : "Connect to the ECU (⌘K)")
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
