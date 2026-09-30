import Foundation
import SSMKit

/// The OBD-II side of the app model: a Bluetooth adapter instead of a KKL cable.
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
        if dashboardIDs.isEmpty { dashboardIDs = defaultDashboard(); applyDefaultTileConfigs() }
        if loggedIDs.isEmpty { loggedIDs = Set(defaultLogged()) }
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
        // Pick the adapter automatically when there is one obvious choice.
        let known = Set(list.map(\.id) + [Self.demoOBDID])
        if selectedAdapterID == nil || (!known.contains(selectedAdapterID!) && !connection.isConnected && connection != .connecting),
           let first = list.first(where: \.looksLikeOBD) {
            selectedAdapterID = first.id
        }
    }

    var selectedAdapterLabel: String {
        if selectedAdapterID == Self.demoOBDID { return "Demo OBD-II car (simulated)" }
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
                simulator.world.setFault(demoFault)
                simulatedELM = simulator
                channel = simulator
                log("Starting the simulated OBD-II adapter")
            } else {
                log("Connecting to \(selectedAdapterLabel) over Bluetooth")
                channel = try await BLEChannel.open(id: id)
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
            startPolling()
            await readOBDTroubleCodes()
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

    func closeOBD() {
        obdNotice = nil
        obdSession?.stopPolling()
        obdSession?.close()
        obdSession = nil
        simulatedELM = nil
        if obdInfo != nil { obdInfo = nil; if mode == .obd { applyOBDParameters() } }
    }

    func applyOBDParameters() {
        let list = obdInfo.map { OBDParameters.parameters(supported: $0.supportedPIDs) } ?? OBDParameters.allParameters
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
        session.startPolling(items: items, allParameters: parametersByID, conversionFor: { p in
            if let units = choice[p.id], let c = p.conversions.first(where: { $0.units == units }) { return c }
            return AppModel.preferredConversion(p.conversions, system: system)
        }, onSample: { [weak self] sample in
            Task { @MainActor in self?.ingest(sample) }
        }, onError: { [weak self] error, fatal in
            Task { @MainActor in self?.pollFailed(error, fatal: fatal) }
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
            codeReadState = .read(Date())
            log("Trouble codes: \(currentCodes.count) confirmed, \(memorizedCodes.count) pending")
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
