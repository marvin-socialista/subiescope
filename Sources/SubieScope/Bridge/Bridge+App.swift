#if os(Windows) || DEBUG
import Foundation
import SSMKit

/// The frame around every part of the app: the sidebar, the toolbar and the connection card.
extension Bridge {
    /// Every part of the app adds its slices and actions here.
    func registerAll() {
        registerApp()
        registerDashboard()
        registerLogger()
        registerCodes()
        registerRecipes()
        registerECUInfo()
        registerLogs()
        registerDyno()
        registerROM()
        registerConsole()
        registerSettings()
        registerSetup()
    }

    struct AppState: Encodable {
        struct Device: Encodable {
            let id: String
            let label: String
        }

        struct Status: Encodable {
            let badge: String
            let title: String
            let detail: String
            /// green, orange, red, purple or gray
            let color: String
        }

        let section: String
        /// What the title bar of the section says ("Dashboard").
        let title: String
        let advancedMode: Bool
        let codeCount: Int

        /// "ssm" or "obd"
        let mode: String
        /// "disconnected", "connecting", "connected" or "failed"
        let connection: String
        let connectionError: String?
        let isDemo: Bool
        let isPlayingBack: Bool
        let status: Status
        /// "kline" or "can" while a Tactrix OpenPort is the cable, connected or chosen: the card then
        /// offers the choice. Nil with any other cable.
        let openPortLine: String?

        /// The cables (SSM) or adapters (OBD-II) to choose from, in the order of the list.
        let devices: [Device]
        /// OBD-II only: USB and Wi-Fi adapters, shown under their own heading.
        let experimentalDevices: [Device]
        let demoDevice: Device
        let selectedDevice: String?
        /// Shown in the list when there is nothing to choose ("No cable found").
        let emptyDevicesText: String?
        let canConnect: Bool

        let isRecording: Bool
        /// Seconds since 1970, for the running clock on the Record button.
        let recordingStart: Double?
        let canRecord: Bool

        /// "Mac" or "PC", for texts that tell a person what to do on their computer.
        let computer: String
        let version: String?
    }

    func registerApp() {
        slice("app") { [model] in
            let obd = model.mode == .obd
            var devices: [AppState.Device] = []
            var experimental: [AppState.Device] = []
            var emptyText: String?
            if obd {
                if model.bleAdapters.isEmpty && model.selectedAdapterID == nil {
                    // Nothing is being looked for where Bluetooth LE cannot be used: the list has what there is.
                    emptyText = !Bridge.bluetoothWorks ? "Choose an adapter"
                        : model.bleStatus.message == nil ? "Looking for adapters…" : "No adapter found"
                }
                // A saved adapter that is out of range or unplugged still needs its row.
                if let id = model.selectedAdapterID, !model.listedAdapterIDs.contains(id) {
                    devices.append(.init(id: id, label: model.selectedAdapterLabel))
                }
                devices += model.bleAdapters.map { .init(id: $0.id, label: $0.name) }
                experimental = model.ports.map { .init(id: AppModel.usbAdapterID($0), label: AppModel.usbAdapterLabel($0)) }
                experimental.append(.init(id: model.wifiAdapterID, label: model.wifiAdapterLabel))
            } else {
                if model.ports.isEmpty { emptyText = "No cable found" }
                devices = model.ports.map { .init(id: $0.path, label: $0.displayName) }
            }
            var error: String?
            if case .failed(let message) = model.connection { error = message }
            let selected = obd ? model.selectedAdapterID : model.selectedPortID
            return AppState(
                section: model.section.rawValue,
                title: model.section.title,
                advancedMode: model.advancedMode,
                codeCount: model.currentCodes.count + model.memorizedCodes.count,
                mode: model.mode.rawValue,
                connection: Bridge.name(of: model.connection),
                connectionError: error,
                isDemo: model.isDemo,
                isPlayingBack: model.isPlayingBack,
                status: Bridge.status(model),
                openPortLine: model.openPortIsTheCable ? (model.openPortCAN ? "can" : "kline") : nil,
                devices: devices,
                experimentalDevices: experimental,
                demoDevice: obd ? .init(id: AppModel.demoOBDID, label: "Demo OBD-II car (simulated)")
                    : .init(id: AppModel.demoPortID, label: "Demo ECU (simulated)"),
                selectedDevice: selected,
                emptyDevicesText: emptyText,
                canConnect: selected != nil,
                isRecording: model.isRecording,
                recordingStart: model.recordingStart?.timeIntervalSince1970,
                canRecord: model.connection.isConnected && !model.loggedIDs.isEmpty,
                computer: Bridge.computer,
                version: About.version)
        }

        action("app.section") { [model] arguments in
            guard let section = arguments.string("section").flatMap(AppSection.init(rawValue:)) else { return }
            model.section = section
        }
        action("app.connect") { [model] _ in
            guard model.connection != .connecting, !model.connection.isConnected else { return }
            Task { await model.connect() }
        }
        action("app.disconnect") { [model] _ in model.disconnect() }
        action("app.toggleConnection") { [model] _ in
            if model.connection.isConnected {
                model.disconnect()
            } else if model.connection != .connecting {
                Task { await model.connect() }
            }
        }
        action("app.toggleRecording") { [model] _ in model.toggleRecording() }
        action("app.mode") { [model] arguments in
            guard let mode = arguments.string("mode").flatMap(ConnectionMode.init(rawValue:)) else { return }
            model.setMode(mode)
        }
        action("app.selectDevice") { [model] arguments in
            guard model.connection != .connecting, !model.connection.isConnected else { return }
            let id = arguments.string("id")
            if model.mode == .obd { model.selectedAdapterID = id } else { model.selectedPortID = id }
        }
        // Looks for cables and adapters again: the Refresh button, and the page's own timer while not connected.
        action("app.refresh") { [model] arguments in
            guard !model.connection.isConnected, model.connection != .connecting else { return }
            if model.mode == .obd && !arguments.bool("quiet") { model.restartBLEScan() }
            model.refreshPorts()
        }
        action("app.stopPlayback") { [model] arguments in
            model.closePlayback()
            if arguments.bool("connect") { Task { await model.connect() } }
        }
        action("app.open") { arguments in
            // Only web links leave the app this way, never a file or a program.
            guard let text = arguments.string("url"), let url = URL(string: text), ["https", "http", "mailto"].contains(url.scheme ?? "") else { return }
            Desktop.open(url)
        }
    }

    /// True in the Windows app. A Mac debug build started with `-pretendWindows YES` says true as well,
    /// so the texts and choices of the Windows app can be looked at on a Mac.
    static var onWindows: Bool {
        #if os(Windows)
        return true
        #else
        return UserDefaults.standard.bool(forKey: "pretendWindows")
        #endif
    }

    /// What a person calls this computer, and the program that shows its files. For texts.
    static var computer: String { onWindows ? "PC" : "Mac" }
    static var fileBrowser: String { onWindows ? "File Explorer" : "Finder" }

    /// Bluetooth LE adapters can be used. Not yet on Windows: there a paired adapter is a COM port.
    static var bluetoothWorks: Bool {
        #if canImport(CoreBluetooth)
        return !onWindows
        #else
        return false
        #endif
    }

    static func name(of state: ConnectionState) -> String {
        switch state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .failed: return "failed"
        }
    }

    /// The summary of cable and connection on the connection card, in a person's words.
    /// (The Mac app's `ConnectionStatus`, with "PC" where that says "Mac".)
    static func status(_ model: AppModel) -> AppState.Status {
        func firstSentence(_ message: String) -> String {
            message.components(separatedBy: ". ").first.map { $0.hasSuffix(".") ? $0 : $0 + "." } ?? message
        }
        let computer = Bridge.computer
        let rate = model.samplesPerSecond > 0 ? String(format: " · %.0f samples/s", model.samplesPerSecond) : ""
        // A lost connection is said even with a log open: "Playing log" alone would hide why the gauges stopped.
        var lost = false
        if case .failed = model.connection { lost = true }
        if model.isPlayingBack, let playback = model.playback, !lost {
            return .init(badge: "Playing log", title: "Playing back a log",
                         detail: "\(playback.url.lastPathComponent) · \(formatLogTime(playback.playhead)) / \(formatLogTime(playback.duration))",
                         color: "purple")
        }
        if model.mode == .obd {
            switch model.connection {
            case .connected:
                if model.isDemo {
                    return .init(badge: "Connected", title: "Demo OBD-II car", detail: "Simulated newer Subaru\(rate)", color: "green")
                }
                return .init(badge: "Connected", title: model.obdInfo?.vin.map { "VIN \($0)" } ?? "OBD-II car",
                             detail: "\(model.selectedAdapterLabel)\(rate)", color: "green")
            case .connecting:
                return .init(badge: "Connecting", title: "Talking to the adapter…", detail: model.selectedAdapterLabel, color: "orange")
            case .failed(let message):
                return .init(badge: "Not connected", title: "Can't reach the car", detail: firstSentence(message), color: "red")
            case .disconnected:
                if model.selectedAdapterID == AppModel.demoOBDID {
                    return .init(badge: "Not connected", title: "Demo car selected",
                                 detail: "Press Connect to try SubieScope with a simulated OBD-II car.", color: "gray")
                } else if !Bridge.bluetoothWorks, model.selectedAdapterKind == .bluetooth {
                    // On a PC nothing is chosen yet: a Bluetooth LE adapter cannot be, there.
                    return .init(badge: "Not connected", title: "No adapter chosen",
                                 detail: "Pick a USB, Wi-Fi or paired Bluetooth adapter, then press Connect. See How to connect.", color: "gray")
                } else if model.selectedAdapterKind == .bluetooth, let problem = model.bleStatus.message {
                    return .init(badge: "Not connected", title: "Bluetooth problem", detail: problem, color: "orange")
                } else if model.selectedAdapterKind == .wifi {
                    return .init(badge: "Not connected", title: "Wi-Fi adapter selected",
                                 detail: "Join the adapter's Wi-Fi network on your \(computer), turn the ignition ON, then press Connect.", color: "gray")
                } else if model.selectedAdapterID != nil {
                    return .init(badge: "Not connected", title: "Adapter selected",
                                 detail: "Plug it into the car's OBD port, turn the ignition ON, then press Connect.", color: "gray")
                }
                return .init(badge: "Not connected", title: "No adapter found",
                             detail: "Plug the adapter into the car and turn the ignition ON. See How to connect.", color: "gray")
            }
        }
        switch model.connection {
        case .connected:
            if model.isDemo {
                return .init(badge: "Connected", title: "Demo car", detail: "Simulated 2008 WRX STI\(rate)", color: "green")
            }
            let id = model.identity?.ecuID ?? "?"
            return .init(badge: "Connected",
                         title: model.knownECUDescription.map { $0.components(separatedBy: " (").first ?? $0 } ?? "ECU \(id)",
                         detail: "ECU \(id)\(rate)", color: "green")
        case .connecting:
            return .init(badge: "Connecting", title: "Talking to the ECU…", detail: model.selectedPortLabel, color: "orange")
        case .failed(let message):
            return .init(badge: "Not connected", title: "Can't reach the car", detail: firstSentence(message), color: "red")
        case .disconnected:
            if model.selectedPortID == AppModel.demoPortID {
                return .init(badge: "Not connected", title: "Demo car selected",
                             detail: "Press Connect to try SubieScope with a simulated car.", color: "gray")
            } else if model.cables.contains(where: { model.canUse($0) }) {
                return .init(badge: "Not connected", title: "Cable found",
                             detail: "Plug it into the car's OBD port, turn the ignition ON, then press Connect.", color: "gray")
            } else if let driverless = model.cables.first(where: { $0.serialPath == nil }) {
                return .init(badge: "Not connected", title: "Cable needs a driver",
                             detail: "\(driverless.chip.name). See How to connect.", color: "orange")
            }
            return .init(badge: "Not connected", title: "No cable found",
                         detail: "Plug the cable into your \(computer). See How to connect.", color: "gray")
        }
    }
}
#endif
