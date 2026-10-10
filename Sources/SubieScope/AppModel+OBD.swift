import Foundation
import SSMKit

/// The OBD-II side of the app model: an ELM327 adapter (Bluetooth, USB or Wi-Fi) instead of a KKL cable.
extension AppModel {
    static let demoOBDID = "demo-obd"

    // MARK: Switching mode

    /// Changes between the SSM cable and the OBD-II adapter. Each mode remembers its own gauges.
    func setMode(_ new: ConnectionMode, scan: Bool = true) {
        guard new != mode else { return }
        if isRecording { stopRecording() }
        dismissRecipe()
        disconnect()
        closePlayback()
        suppressPersist = true
        mode = new
        let saved = Self.savedSelection(for: new)
        loggedIDs = saved.logged
        dashboardIDs = saved.dashboard
        unitChoice = saved.units
        tileConfigs = saved.tiles
        suppressPersist = false
        applyParameters()
        applyDefaultSelection()
        resetLive()
        currentCodes = []
        memorizedCodes = []
        codeReadState = .idle
        clearState = nil
        connection = .disconnected
        if new == .obd {
            if scan { startBLEScan() }
        } else {
            bleScanner.stop()
            if definitions == nil { Task { await downloadDefinitions() } }
        }
    }

    /// From the "which one do I need" sheet: remembers the choice, even when it is the mode already active.
    func chooseMode(_ new: ConnectionMode) {
        applyChosenMode(new, scan: true)
        showModeChooser = false
        if new == .ssm && !UserDefaults.standard.bool(forKey: "cableSetupSeen") {
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                showCableSetup = true
            }
        }
    }

    /// Remembers the mode as a deliberate choice. The wizard passes `scan: false`: it explains
    /// the Bluetooth permission first and starts the scan itself.
    func applyChosenMode(_ new: ConnectionMode, scan: Bool = false) {
        UserDefaults.standard.set(new.rawValue, forKey: "connectionMode")
        setMode(new, scan: scan)
    }

    func finishSetupWizard() {
        UserDefaults.standard.set(true, forKey: "setupWizardDone")
        UserDefaults.standard.set(true, forKey: "cableSetupSeen")
        showWizard = false
        if mode == .obd && bleStatus == .idle { startBLEScan() }
    }

    // MARK: Bluetooth adapters

    func startBLEScan() {
        bleScanner.onChange = { [weak self] status, list in
            Task { @MainActor in self?.bleScanChanged(status, list) }
        }
        bleScanner.start()
    }

    func restartBLEScan() {
        bleScanner.stop()
        bleAdapters = []
        startBLEScan()
    }

    private func bleScanChanged(_ status: BLEStatus, _ list: [BLEAdapter]) {
        bleStatus = status
        bleAdapters = list
        // An adapter stops advertising while connected, so it drops out of the list. Remember its name.
        for adapter in list { rememberedAdapterNames[adapter.id] = adapter.name }
        if let id = selectedAdapterID, let name = rememberedAdapterNames[id] { UserDefaults.standard.set(name, forKey: "selectedAdapterName") }
        // Pick the adapter automatically when there is one obvious choice. A USB or Wi-Fi adapter was
        // chosen on purpose, so it stays.
        let known = Set(list.map(\.id) + [Self.demoOBDID])
        if selectedAdapterID == nil || (selectedAdapterKind == .bluetooth && !known.contains(selectedAdapterID!)
                                        && !connection.isConnected && connection != .connecting),
           let first = list.first(where: \.looksLikeOBD) {
            selectedAdapterID = first.id
        }
    }

    // MARK: USB and Wi-Fi adapters (experimental)

    enum AdapterKind { case bluetooth, usb, wifi }

    /// How the selected adapter is reached. Nothing for the demo car, or when none is selected.
    var selectedLink: OBDAdapterLink? {
        guard let id = selectedAdapterID, id != Self.demoOBDID else { return nil }
        return OBDAdapterLink(id: id)
    }

    var selectedAdapterKind: AdapterKind {
        switch selectedLink {
        case .serial: return .usb
        case .network: return .wifi
        case .bluetooth, nil: return .bluetooth
        }
    }

    /// "Bluetooth adapter", "USB adapter" or "Wi-Fi adapter".
    var adapterKindLabel: String {
        switch selectedAdapterKind {
        case .bluetooth: return "Bluetooth adapter"
        case .usb: return "USB adapter"
        case .wifi: return "Wi-Fi adapter"
        }
    }

    /// The Wi-Fi adapter at the typed address, as an adapter to select.
    var wifiAdapterID: String { OBDAdapterLink.network(address: wifiAddress).id }
    var wifiAdapterLabel: String { "Wi-Fi adapter (\(OBDAdapterLink.network(address: wifiAddress).address))" }

    /// Every adapter the lists offer right now. A saved one that is missing here is out of range or unplugged.
    var listedAdapterIDs: Set<String> {
        Set(bleAdapters.map(\.id) + ports.map(Self.usbAdapterID) + [wifiAdapterID, Self.demoOBDID])
    }

    static func usbAdapterID(_ port: SerialPortInfo) -> String { OBDAdapterLink.serial(path: port.path).id }

    /// A serial port as an adapter choice. A paired Bluetooth Classic adapter is a serial port too, without USB.
    static func usbAdapterLabel(_ port: SerialPortInfo) -> String {
        "\(port.isUSB ? "USB" : "Serial port"): \(port.displayName)"
    }

    var selectedAdapterLabel: String {
        if selectedAdapterID == Self.demoOBDID { return "Demo OBD-II car (simulated)" }
        switch selectedLink {
        case .serial(let path):
            if let port = ports.first(where: { $0.path == path }) { return Self.usbAdapterLabel(port) }
            let name = (path as NSString).lastPathComponent
            return connection.isConnected ? "USB: \(name)" : "USB: \(name) (not plugged in)"
        case .network:
            return wifiAdapterLabel
        case .bluetooth, nil:
            break
        }
        if let adapter = bleAdapters.first(where: { $0.id == selectedAdapterID }) { return adapter.name }
        if let id = selectedAdapterID {
            // Connected adapters stop advertising, so they are not in the scan list: use the name we saw earlier.
            if let name = rememberedAdapterNames[id] ?? UserDefaults.standard.string(forKey: "selectedAdapterName") {
                return connection.isConnected ? name : "\(name) (not in range)"
            }
            return "Saved adapter (not in range)"
        }
        return "No adapter found"
    }

    // MARK: Connecting

    func connectOBD() async {
        guard connection != .connecting else { return }
        guard let id = selectedAdapterID else {
            connection = .failed("No adapter selected. Plug the adapter into the car, turn the ignition ON, and pick it from the list.")
            return
        }
        disconnect()
        playback?.pause()
        connection = .connecting
        pollError = nil
        do {
            isDemo = id == Self.demoOBDID
            let channel: ELMChannel
            if isDemo {
                let simulator = SimulatedELM()
                simulator.enableDemoExtended()
                simulator.world.setFault(demoFault)
                simulatedELM = simulator
                channel = simulator
                log("Starting the simulated OBD-II adapter")
            } else {
                switch OBDAdapterLink(id: id) {
                case .bluetooth(let peripheral):
                    log("Connecting to \(selectedAdapterLabel) over Bluetooth")
                    channel = try await BLEChannel.open(id: peripheral)
                case .serial(let path):
                    log("Opening \(path) and finding the adapter's speed")
                    let serial = try await SerialELMChannel.open(path: path)
                    log("The adapter answers at \(serial.baud) baud")
                    channel = serial
                case .network(let host, let port):
                    log("Connecting to the Wi-Fi adapter at \(host):\(port)")
                    channel = try await TCPELMChannel.open(host: host, port: port)
                }
            }
            let session = OBDSession(channel: channel)
            session.elm.traffic = { [weak self] direction, text in
                Task { @MainActor in self?.logOBDTraffic(direction, text) }
            }
            obdSession = session
            obdNotice = nil
            session.onSkip = { [weak self] pids in
                Task { @MainActor in self?.obdValuesSkipped(pids) }
            }
            let info = try await session.connect()
            obdInfo = info
            vin = info.vin
            vinState = info.vin ?? "Not reported by this car"
            log("Adapter \(info.adapter), protocol \(info.protocolName.isEmpty ? "unknown" : info.protocolName), \(info.supportedPIDs.count) values supported")
            applyOBDParameters()
            connection = .connected
            resetLive()
            startWideband()
            startPolling()
            await readOBDTroubleCodes()
            if extendedValuesOn { Task { await discoverExtendedValues() } }
            if let recipeID = UserDefaults.standard.string(forKey: "startRecipe"), let recipe = RecipeCatalog.recipe(id: recipeID), recipeRun == nil {
                section = .recipes
                startRecipe(recipe)
            }
        } catch {
            log("Connect failed: \(error.localizedDescription)")
            connection = .failed(error.localizedDescription)
            closeOBD()
        }
    }

    /// The car keeps not answering some values: hide them and say so, instead of showing stale numbers.
    func obdValuesSkipped(_ pids: Set<UInt8>) {
        var names: [String] = []
        for pid in pids.sorted() {
            let id = OBDParameters.id(forPID: pid)
            latest[id] = nil
            if pid == 0x0B { latest[OBDParameters.boostID] = nil }
            if let name = OBDParameters.byPID[pid]?.name { names.append(name) }
        }
        obdNotice = "This car does not answer right now: \(names.joined(separator: ", ")). Those values are skipped so the rest stays fast."
    }

    /// Asks the car which extended (Mode 22) values it answers and offers those.
    func discoverExtendedValues() async {
        guard let session = obdSession, connection.isConnected, !extendedSearching else { return }
        guard obdInfo != nil else { return }
        extendedSearching = true
        extendedState = "Looking for extended values…"
        defer { extendedSearching = false }
        do {
            let found = try await session.discoverExtended()
            extendedDiscovery = found
            extendedIDs = found.ids
            applyOBDParameters()
            var state: String
            if found.ids.isEmpty {
                state = "This car does not answer any of the extended values SubieScope knows. That is normal for most cars, and for Subarus before about 2015."
            } else {
                state = "Found \(found.ids.count) extended value\(found.ids.count == 1 ? "" : "s"). Add them in the Logger."
            }
            // Values the car has and SubieScope cannot name yet. A report from this car is how they get added.
            if found.unnamedCount > 0 {
                state += " Your car also lists \(found.unnamedCount) value\(found.unnamedCount == 1 ? "" : "s") SubieScope has no name for yet. Help > Send Diagnostic Report… tells the developer which ones, so they can be added."
            }
            extendedState = state
            log(state)
        } catch {
            extendedState = "Could not look for extended values: \(error.localizedDescription)"
            log(extendedState ?? "")
        }
    }

    func closeOBD() {
        extendedIDs = []
        extendedDiscovery = nil
        extendedState = nil
        obdNotice = nil
        obdSession?.stopPolling()
        obdSession?.close()
        obdSession = nil
        simulatedELM = nil
        if obdInfo != nil { obdInfo = nil; if mode == .obd { applyOBDParameters() } }
    }

    func applyOBDParameters() {
        var list = obdInfo.map { OBDParameters.parameters(supported: $0.supportedPIDs) } ?? OBDParameters.allParameters
        // Extended values only appear once the car has shown it answers them.
        if extendedValuesOn { list += ExtendedParameters.definitions(for: extendedIDs) }
        list += widebandParameters
        parameters = list
        parametersByID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        codeDefinitions = []
    }

    // MARK: Polling

    func startOBDPolling() {
        guard let session = obdSession else { return }
        let items = polledItems
        if isRecording { rotateRecordingIfColumnsChangedForOBD(items) }
        let choice = unitChoice
        let system = unitSystem
        let pressure = pressureUnit
        pollEpoch += 1
        let epoch = pollEpoch
        session.startPolling(items: items, allParameters: parametersByID, conversionFor: { p in
            if let units = choice[p.id], let c = p.conversions.first(where: { $0.units == units }) { return c }
            return AppModel.preferredConversion(p.conversions, system: system, pressure: pressure)
        }, onSample: { [weak self] sample in
            Task { @MainActor in
                guard let self, epoch == self.pollEpoch else { return }
                self.ingest(sample)
            }
        }, onError: { [weak self] error, fatal in
            Task { @MainActor in
                guard let self, epoch == self.pollEpoch else { return }
                self.pollFailed(error, fatal: fatal)
            }
        })
    }

    private func rotateRecordingIfColumnsChangedForOBD(_ items: [PollItem]) {
        let wanted = items.filter { loggedIDs.contains($0.parameter.id) }.map { $0.parameter.id + $0.conversion.units }
        let current = recordedColumnKeys
        if wanted != current {
            stopRecording()
            startRecording()
        }
    }

    // MARK: Trouble codes

    /// OBD-II gives only the code; the description comes from SubieScope's own list of explanations.
    private func codeDefinition(_ code: String) -> DiagnosticCodeDefinition {
        let meaning = TroubleCodeHelp.lookup(code)?.meaning.split(separator: ".").first.map(String.init)
        return DiagnosticCodeDefinition(id: code, name: "\(code) \(meaning ?? "No description for this code in SubieScope's list")",
                                        currentAddress: 0, memorizedAddress: 0, bit: 0)
    }

    func readOBDTroubleCodes() async {
        guard let session = obdSession, connection.isConnected else { return }
        codeReadState = .reading
        do {
            let report = try await session.run { elm in try elm.readTroubleCodes() }
            let confirmed = report.confirmed + report.permanent.filter { !report.confirmed.contains($0) }
            currentCodes = confirmed.map(codeDefinition)
            memorizedCodes = report.pending.filter { !confirmed.contains($0) }.map(codeDefinition)
            // A bonus: a car that fumbles the freeze frame still shows its codes.
            freezeFrame = try? await session.run { elm in try FreezeFrame.read(from: elm) }
            codeReadState = .read(Date())
            log("Trouble codes: \(currentCodes.count) confirmed, \(memorizedCodes.count) pending" + (freezeFrame.map { ", freeze frame for \($0.code)" } ?? ""))
        } catch {
            codeReadState = .failed(error.localizedDescription)
        }
    }

    func clearOBDTroubleCodes() async {
        guard let session = obdSession, connection.isConnected else { return }
        clearState = "Clearing…"
        do {
            try await session.run { elm in try elm.clearTroubleCodes() }
            clearState = "Codes cleared and the check engine light is off. If a fault is still there, the code comes back after a short drive."
            log("Trouble codes cleared")
            currentCodes = []
            memorizedCodes = []
            freezeFrame = nil
            codeReadState = .idle
        } catch {
            clearState = "Clearing failed: \(error.localizedDescription)"
        }
    }

    // MARK: Console

    func logOBDTraffic(_ direction: ELMTrafficDirection, _ text: String) {
        if trafficLogBudget > 0 {
            trafficLogBudget -= 1
            DiagnosticLog.shared.debug("obd", "\(direction == .sent ? "->" : "<-") \(text)")
        }
        guard consoleCapturesTraffic else { return }
        appendConsole(ConsoleLine(id: nextConsoleID(), time: Date(), kind: direction == .sent ? .sent : .received, text: text))
    }
}
