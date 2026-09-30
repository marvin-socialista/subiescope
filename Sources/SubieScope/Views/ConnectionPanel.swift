import SSMKit
import SwiftUI

/// The connection status at the bottom of the sidebar: a clear badge, a Connect
/// button when not connected, and a panel with instructions and details.
struct ConnectionCard: View {
    @Environment(AppModel.self) private var model
    @State private var showingPanel = false
    private let rescan = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        let status = ConnectionStatus(model: model)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showingPanel.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        StatusBadge(connected: model.connection.isConnected, text: status.badge, color: status.color)
                        Spacer(minLength: 0)
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                    Text(status.title).font(.callout.weight(.semibold))
                    Text(status.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Connection details and instructions")

            if model.isPlayingBack {
                Button {
                    model.closePlayback()
                    Task { await model.connect() }
                } label: {
                    Label("Connect to Car", systemImage: "bolt.horizontal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Stop the playback and show live data from the car")
                Button("Stop playback") { model.closePlayback() }
                    .buttonStyle(.link)
                    .font(.callout)
            } else if model.connection.isConnected {
                HStack {
                    Button("Details") { showingPanel = true }
                        .buttonStyle(.link)
                    Spacer()
                    Button("Disconnect") { model.disconnect() }
                        .controlSize(.small)
                }
            } else if model.connection == .connecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.callout)
                }
            } else {
                ConnectionSettings()
                Button {
                    Task { await model.connect() }
                } label: {
                    Label("Connect", systemImage: "bolt.horizontal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.mode == .obd ? model.selectedAdapterID == nil : model.selectedPortID == nil)
                .help((model.mode == .obd ? model.selectedAdapterID == nil : model.selectedPortID == nil)
                      ? "Pick \(model.mode == .obd ? "an adapter" : "a cable") first, or try the demo car" : "Connect to the car (⌘K)")
                Button {
                    showingPanel = true
                } label: {
                    Label("How to connect", systemImage: "questionmark.circle")
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(status.color.opacity(0.45), lineWidth: model.connection.isConnected ? 1.5 : 1))
        .popover(isPresented: $showingPanel, arrowEdge: .trailing) {
            ConnectionPanel(close: { showingPanel = false })
                .environment(model)
        }
        .onReceive(rescan) { _ in
            // Notice a cable being plugged in or out while not connected.
            if !model.connection.isConnected && model.connection != .connecting { model.refreshPorts() }
        }
    }
}

/// The type (SSM cable or OBD-II adapter) and the device to use, right where you press Connect.
struct ConnectionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Connection type", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                Text("SSM cable").tag(ConnectionMode.ssm)
                Text("OBD-II").tag(ConnectionMode.obd)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("SSM: Subaru's own protocol over a USB cable, for cars up to about 2014.\nOBD-II: standard protocol over a Bluetooth adapter, for newer cars.")

            DevicePicker()
                .labelsHidden()
                .frame(maxWidth: .infinity)

            Button("Which one do I need?") { model.showModeChooser = true }
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}

/// The cable list in SSM mode, the Bluetooth adapter list in OBD-II mode, each with its demo car.
struct DevicePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.mode == .obd {
                Picker("Adapter", selection: $model.selectedAdapterID) {
                    if model.bleAdapters.isEmpty && model.selectedAdapterID == nil {
                        Text(model.bleStatus.message == nil ? "Looking for adapters…" : "No adapter found").tag(String?.none)
                    }
                    if let id = model.selectedAdapterID, id != AppModel.demoOBDID, !model.bleAdapters.contains(where: { $0.id == id }) {
                        Text(model.selectedAdapterLabel).tag(Optional(id))
                    }
                    ForEach(model.bleAdapters) { adapter in
                        Text(adapter.name).tag(Optional(adapter.id))
                    }
                    Divider()
                    Text("Demo OBD-II car (simulated)").tag(Optional(AppModel.demoOBDID))
                }
                .help("The Bluetooth adapter to use. Plug it into the car and turn the ignition ON so it shows up.")
            } else {
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
                .help("The USB cable to use. FTDI cables show up as \"FT232R USB UART\".")
            }
        }
        .disabled(model.connection == .connecting || model.connection.isConnected)
    }
}

/// "CONNECTED" in green, or the reason it isn't.
struct StatusBadge: View {
    let connected: Bool
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(color: connected ? .white : color, pulsing: false)
            Text(text).font(.caption.weight(.bold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(connected ? .white : color)
        .background(connected ? AnyShapeStyle(Color.green) : AnyShapeStyle(color.opacity(0.15)), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if pulsing { Circle().stroke(color.opacity(0.4), lineWidth: 3).scaleEffect(1.7) }
            }
            .accessibilityHidden(true)
    }
}

/// Human-readable summary of cable and connection state.
@MainActor
struct ConnectionStatus {
    let badge: String
    let title: String
    let detail: String
    let color: Color

    init(model: AppModel) {
        let cable = model.cables.first { $0.serialPath != nil && $0.chip != .openPort2 }
        let driverless = model.cables.first { $0.serialPath == nil }
        if model.isPlayingBack, let playback = model.playback {
            badge = "Playing log"
            title = "Playing back a log"
            detail = "\(playback.url.lastPathComponent) · \(formatLogTime(playback.playhead)) / \(formatLogTime(playback.duration))"
            color = .purple
            return
        }
        if model.mode == .obd {
            let rate = model.samplesPerSecond > 0 ? String(format: " · %.0f samples/s", model.samplesPerSecond) : ""
            switch model.connection {
            case .connected:
                badge = "Connected"
                if model.isDemo {
                    title = "Demo OBD-II car"
                    detail = "Simulated newer Subaru\(rate)"
                } else {
                    title = model.obdInfo?.vin.map { "VIN \($0)" } ?? "OBD-II car"
                    detail = "\(model.selectedAdapterLabel)\(rate)"
                }
                color = .green
            case .connecting:
                badge = "Connecting"
                title = "Talking to the adapter…"
                detail = model.selectedAdapterLabel
                color = .orange
            case .failed(let message):
                badge = "Not connected"
                title = "Can't reach the car"
                detail = message.components(separatedBy: ". ").first.map { $0.hasSuffix(".") ? $0 : $0 + "." } ?? message
                color = .red
            case .disconnected:
                badge = "Not connected"
                if model.selectedAdapterID == AppModel.demoOBDID {
                    title = "Demo car selected"
                    detail = "Press Connect to try SubieScope with a simulated OBD-II car."
                    color = .secondary
                } else if let problem = model.bleStatus.message {
                    title = "Bluetooth problem"
                    detail = problem
                    color = .orange
                } else if model.selectedAdapterID != nil {
                    title = "Adapter selected"
                    detail = "Plug it into the car's OBD port, turn the ignition ON, then press Connect."
                    color = .secondary
                } else {
                    title = "No adapter found"
                    detail = "Plug the adapter into the car and turn the ignition ON. See How to connect."
                    color = .secondary
                }
            }
            return
        }
        switch model.connection {
        case .connected:
            let rate = model.samplesPerSecond > 0 ? String(format: " · %.0f samples/s", model.samplesPerSecond) : ""
            badge = "Connected"
            if model.isDemo {
                title = "Demo car"
                detail = "Simulated 2008 WRX STI\(rate)"
            } else {
                title = model.knownECUDescription.map { $0.components(separatedBy: " (").first ?? $0 } ?? "ECU \(model.identity?.ecuID ?? "?")"
                detail = "ECU \(model.identity?.ecuID ?? "?")\(rate)"
            }
            color = .green
        case .connecting:
            badge = "Connecting"
            title = "Talking to the ECU…"
            detail = model.selectedPortLabel
            color = .orange
        case .failed(let message):
            badge = "Not connected"
            title = "Can't reach the car"
            detail = message.components(separatedBy: ". ").first.map { $0.hasSuffix(".") ? $0 : $0 + "." } ?? message
            color = .red
        case .disconnected:
            badge = "Not connected"
            if model.selectedPortID == AppModel.demoPortID {
                title = "Demo car selected"
                detail = "Press Connect to try SubieScope with a simulated car."
                color = .secondary
            } else if cable != nil {
                title = "Cable found"
                detail = "Plug it into the car's OBD port, turn the ignition ON, then press Connect."
                color = .secondary
            } else if let driverless {
                title = "Cable needs a driver"
                detail = "\(driverless.chip.name). See How to connect."
                color = .orange
            } else {
                title = "No cable found"
                detail = "Plug the cable into your Mac. See How to connect."
                color = .secondary
            }
        }
    }
}

/// Popover with everything about the connection, and the actions to change it.
struct ConnectionPanel: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void

    var body: some View {
        @Bindable var model = model
        let status = ConnectionStatus(model: model)
        let cable = model.cables.first { $0.serialPath != nil && $0.chip != .openPort2 }
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                StatusDot(color: status.color, pulsing: model.connection.isConnected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title).font(.title3.weight(.semibold))
                    Text(status.detail).font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack {
                Label("\(model.mode.title): \(model.mode == .ssm ? "USB cable" : "Bluetooth adapter")", systemImage: model.mode.symbol)
                    .font(.callout.weight(.medium))
                Spacer()
                Button("Change…") {
                    close()
                    model.showModeChooser = true
                }
                .controlSize(.small)
                .disabled(model.connection.isConnected || model.connection == .connecting)
                .help("Switch between the Subaru SSM cable and an OBD-II Bluetooth adapter")
            }

            if model.mode == .obd {
                adapterSection
            }

            // Cable
            if model.mode == .ssm { PanelSection(title: "Cable", symbol: "cable.connector") {
                if model.cables.isEmpty && model.ports.isEmpty {
                    Text("No USB cable found. Plug the KKL cable into your Mac (use a USB-C adapter if needed).")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.cables) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(c.productName ?? "USB cable") · \(c.chip.name)").font(.callout.weight(.medium))
                            if let path = c.serialPath {
                                Text("Ready as \((path as NSString).lastPathComponent)\(c.chip == .ftdi ? ", no driver needed" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(c.chip.driverAdvice).font(.caption).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if model.ports.count > 1 && !model.connection.isConnected {
                        Picker("Use", selection: $model.selectedPortID) {
                            ForEach(model.ports) { Text($0.displayName).tag(Optional($0.path)) }
                            Text("Demo ECU (simulated)").tag(Optional(AppModel.demoPortID))
                        }
                    }
                }
            } }

            // Car
            PanelSection(title: "Car", symbol: "car.side") {
                if model.mode == .obd {
                    obdCarSection
                } else if model.connection.isConnected, let id = model.identity {
                    LabeledContent("ECU ID", value: id.ecuID).font(.callout.monospaced())
                    if let car = model.knownECUDescription { LabeledContent("Car", value: car).font(.callout) }
                    if let engine = EngineDiagnostics.engineType(systemID: id.systemID) { LabeledContent("Engine", value: engine).font(.callout) }
                    LabeledContent("Speed", value: String(format: "%.1f samples/s", model.samplesPerSecond)).font(.callout)
                } else {
                    Text("How to connect").font(.callout.weight(.semibold))
                    ChecklistRow(done: cable != nil, text: "Plug the cable into your Mac",
                                 detail: "A VAG KKL cable with an FTDI chip needs no driver. Use a USB-C adapter if needed.")
                    ChecklistRow(done: false, text: "Plug it into the car and turn the ignition ON",
                                 detail: "The OBD port is under the dashboard on the driver's side. The engine may be off or running. Cable with a switch: use the K-line (pin 7) position.")
                    ChecklistRow(done: false, text: "Press Connect",
                                 detail: "SubieScope finds the ECU and remembers the cable. Not working? Cable Setup tests each step and tells you what's wrong.")
                }
            }

            if case .failed(let message) = model.connection {
                Label {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                if model.mode == .ssm {
                    Button("Cable Setup…") {
                        close()
                        model.showCableSetup = true
                    }
                }
                if !model.connection.isConnected {
                    Button("Use Demo Car") {
                        close()
                        if model.mode == .obd { model.selectedAdapterID = AppModel.demoOBDID } else { model.selectedPortID = AppModel.demoPortID }
                        Task { await model.connect() }
                    }
                }
                Spacer()
                if model.connection.isConnected {
                    Button("Disconnect") { model.disconnect() }
                } else {
                    Button {
                        Task { await model.connect() }
                    } label: {
                        if model.connection == .connecting { ProgressView().controlSize(.small) } else { Text("Connect") }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.connection == .connecting || (model.mode == .obd ? model.selectedAdapterID == nil : model.selectedPortID == nil))
                }
            }
        }
        .padding(18)
        .frame(width: 360)
        .onAppear { model.refreshPorts() }
    }

    @ViewBuilder
    private var adapterSection: some View {
        @Bindable var model = model
        PanelSection(title: "Bluetooth adapter", symbol: "wave.3.right") {
            if let problem = model.bleStatus.message {
                Label {
                    Text(problem).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
            } else if model.bleAdapters.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for adapters nearby…").foregroundStyle(.secondary)
                }
                Text("An adapter only shows up while it is plugged into a car with the ignition ON.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.bleAdapters.prefix(6)) { adapter in
                    Button {
                        model.selectedAdapterID = adapter.id
                    } label: {
                        HStack {
                            Image(systemName: model.selectedAdapterID == adapter.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(model.selectedAdapterID == adapter.id ? Color.scopeBlue : .secondary)
                            Text(adapter.name).font(.callout.weight(adapter.looksLikeOBD ? .medium : .regular))
                            Spacer()
                            if adapter.looksLikeOBD { Text("OBD-II").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.connection.isConnected || model.connection == .connecting)
                }
            }
        }
    }

    @ViewBuilder
    private var obdCarSection: some View {
        if model.connection.isConnected, let info = model.obdInfo {
            LabeledContent("Adapter", value: info.adapter).font(.callout)
            if !info.protocolName.isEmpty { LabeledContent("Protocol", value: info.protocolName).font(.callout) }
            if let vin = info.vin { LabeledContent("VIN", value: vin).font(.callout.monospaced()) }
            LabeledContent("Values", value: "\(model.parameters.count) available").font(.callout)
            LabeledContent("Speed", value: String(format: "%.1f samples/s", model.samplesPerSecond)).font(.callout)
        } else {
            Text("How to connect").font(.callout.weight(.semibold))
            ChecklistRow(done: model.bleStatus.message == nil, text: "Plug the adapter into the car",
                         detail: "The OBD port is under the dashboard on the driver's side. Use an ELM327 adapter with Bluetooth 4.0 (BLE), such as the Vgate iCar Pro.")
            ChecklistRow(done: !model.bleAdapters.isEmpty, text: "Turn the ignition ON",
                         detail: "The engine may be off or running. The adapter switches on and appears in the list. Close other apps that use it: it accepts one connection at a time.")
            ChecklistRow(done: model.selectedAdapterID != nil, text: "Pick it and press Connect",
                         detail: "The first time, macOS asks whether SubieScope may use Bluetooth. Say yes. Finding the car can take up to 10 seconds.")
        }
    }
}

private struct PanelSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChecklistRow: View {
    let done: Bool
    let text: String
    var detail: String? = nil

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.callout)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? .green : .secondary)
        }
    }
}
