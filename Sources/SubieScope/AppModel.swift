import AppKit
import Foundation
import Observation
import SSMKit

struct ChartPoint: Identifiable, Hashable {
    let id: Int
    let t: Double
    let value: Double
}

struct ConsoleLine: Identifiable {
    let id: Int
    let time: Date
    let kind: SSMTrafficDirection?
    let text: String
}

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard, logger, recipes, diagnostics, ecuInfo, logs, dyno, rom, console
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .logger: return "Logger"
        case .recipes: return "Troubleshooting"
        case .diagnostics: return "Trouble Codes"
        case .ecuInfo: return "ECU Info"
        case .logs: return "Recorded Logs"
        case .dyno: return "Virtual Dyno"
        case .rom: return "ROM Editor"
        case .console: return "Console"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .logger: return "waveform.path.ecg"
        case .recipes: return "stethoscope"
        case .diagnostics: return "exclamationmark.triangle"
        case .ecuInfo: return "cpu"
        case .logs: return "doc.text.magnifyingglass"
        case .dyno: return "chart.line.uptrend.xyaxis"
        case .rom: return "memorychip"
        case .console: return "terminal"
        }
    }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var isConnected: Bool { self == .connected }
}

enum UnitSystem: String, CaseIterable, Identifiable {
    case metric, imperial
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    static let demoPortID = "demo"
    static let historySeconds: Double = 60

    // MARK: Navigation
    var section: AppSection = .dashboard

    // MARK: Ports and connection
    var ports: [SerialPortInfo] = []
    var selectedPortID: String? {
        // The demo car is a one-off choice: it must not stay selected the next time the app starts.
        didSet { if selectedPortID != Self.demoPortID { UserDefaults.standard.set(selectedPortID, forKey: "selectedPort") } }
    }
    var connection: ConnectionState = .disconnected
    var identity: ECUIdentity?
    var isDemo = false
    private var session: SSMSession?
    private var demoECU: DemoECU?
    /// A simulated Tactrix OpenPort between the app and the demo car (testing: -demoCable openport).
    private var demoOpenPort: SimulatedOpenPort?
    /// Experimental: use a Tactrix OpenPort 2.0 as the cable in SSM mode.
    var openPortOn: Bool = UserDefaults.standard.bool(forKey: "openPortOn") {
        didSet {
            UserDefaults.standard.set(openPortOn, forKey: "openPortOn")
            refreshPorts()
        }
    }
    /// The SSM session while connected through a Tactrix OpenPort, for reading a ROM over its CAN side.
    var openPortSession: SSMSession? { session?.openPort == nil ? nil : session }

    // MARK: Connection mode (SSM cable or OBD-II adapter)
    var mode: ConnectionMode = .saved {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "connectionMode") }
    }
    /// The "which one do I need" sheet: Car > Connection Type.
    var showModeChooser = false
    /// The first-run wizard (also Car > Setup Wizard).
    var showWizard = false
    /// The last run ended without a clean exit: offer to send a report.
    var showCrashPrompt = false
    /// Traffic lines still to be written to the log file for this connection (the start says the most).
    @ObservationIgnored var trafficLogBudget = 250
    var bleAdapters: [BLEAdapter] = []
    var bleStatus: BLEStatus = .idle
    var selectedAdapterID: String? {
        didSet { if selectedAdapterID != Self.demoOBDID { UserDefaults.standard.set(selectedAdapterID, forKey: "selectedAdapter") } }
    }
    /// Address of a Wi-Fi adapter, as typed: "192.168.0.10:35000" is what nearly all of them use.
    var wifiAddress: String = UserDefaults.standard.string(forKey: "wifiAdapterAddress") ?? OBDAdapterLink.network(address: "").address {
        didSet {
            UserDefaults.standard.set(wifiAddress, forKey: "wifiAdapterAddress")
            // Keep pointing at the Wi-Fi adapter while its address is being edited.
            if case .network = selectedLink, selectedAdapterID != wifiAdapterID { selectedAdapterID = wifiAdapterID }
        }
    }
    var obdInfo: OBDInfo?
    var obdSession: OBDSession?
    /// Something worth knowing about the car's answers (values it does not report), shown on the dashboard.
    var obdNotice: String?
    /// Command line remote control (developer): the control socket, and whether raw requests paused live polling.
    @ObservationIgnored var remoteServer: RemoteServer?
    var remoteHold = false
    /// Experimental: Mode 22 extended values (AVCS, knock and more) on cars that answer them.
    var extendedValuesOn: Bool = UserDefaults.standard.bool(forKey: "extendedValues") {
        didSet {
            UserDefaults.standard.set(extendedValuesOn, forKey: "extendedValues")
            applyOBDParameters()
            if extendedValuesOn && connection.isConnected && mode == .obd { Task { await discoverExtendedValues() } }
        }
    }
    /// IDs of the extended values this car answered, and a sentence about how the search went.
    var extendedIDs: Set<String> = []
    /// Everything the search found: also the ECU's ROM ID and the values the car lists that have no name yet.
    var extendedDiscovery: ExtendedDiscovery?
    var extendedState: String?
    var extendedSearching = false
    /// Names of adapters seen while scanning, by identifier.
    var rememberedAdapterNames: [String: String] = [:]
    /// Reading and editing a ROM is advanced and risky, so the ROM Editor is hidden until the user
    /// turns this on and accepts the warning. Off by default; only set true after the warning is shown.
    var advancedMode: Bool = UserDefaults.standard.bool(forKey: "advancedMode") {
        didSet {
            UserDefaults.standard.set(advancedMode, forKey: "advancedMode")
            if !advancedMode && section == .rom { section = .dashboard }
        }
    }
    /// Presents the Advanced-mode warning that must be accepted before it turns on.
    var showAdvancedDisclaimer = false

    // MARK: Reading a ROM from the car (advanced, OBD-II + STN adapter only)
    /// Whether the connected OBD-II adapter is an STN chip (OBDLink EX). nil until it has been checked.
    /// Only an STN adapter can read a ROM; a plain ELM327 clone cannot do the ISO-TP transfer reliably.
    var obdAdapterIsSTN: Bool?
    /// True while the adapter type is being probed.
    var checkingAdapterType = false
    /// True while a ROM read is running.
    var romReadInProgress = false
    /// 0...1 progress of the running read (it reads about 1 MB slowly).
    var romReadProgress: Double = 0
    /// A short line about what the read is doing, or how it ended.
    var romReadStatus: String?
    /// Set when the last read failed, for red styling; nil on success or while running.
    var romReadError: String?
    /// Lets the ROM read be stopped from the UI while it runs on the adapter's queue.
    @ObservationIgnored let romReadCancel = CancelFlag()

    var remoteControlOn: Bool = UserDefaults.standard.bool(forKey: "remoteControl") {
        didSet {
            UserDefaults.standard.set(remoteControlOn, forKey: "remoteControl")
            applyRemoteControl()
        }
    }
    @ObservationIgnored var simulatedELM: SimulatedELM?
    @ObservationIgnored let bleScanner = BLEScanner()
    /// Set while a whole selection is swapped (a mode change), so half of it is never saved.
    @ObservationIgnored var suppressPersist = false

    // MARK: Wideband gauge
    /// A separate AEM wideband gauge on its own serial port, logged next to the car's values (experimental).
    var widebandOn: Bool = UserDefaults.standard.bool(forKey: "widebandOn") {
        didSet {
            UserDefaults.standard.set(widebandOn, forKey: "widebandOn")
            widebandSettingChanged()
        }
    }
    /// The serial port the gauge's output wire is on.
    var widebandPortID: String? = UserDefaults.standard.string(forKey: "widebandPort") {
        didSet {
            UserDefaults.standard.set(widebandPortID, forKey: "widebandPort")
            if connection.isConnected { startWideband() }
        }
    }
    /// The troubleshooting tests read the mixture from the gauge instead of the car's own A/F sensor.
    var testsUseWideband: Bool = UserDefaults.standard.bool(forKey: "testsUseWideband") {
        didSet { UserDefaults.standard.set(testsUseWideband, forKey: "testsUseWideband") }
    }
    /// What the gauge's listener is doing. nil while it is not running.
    var widebandState: WidebandReader.State?
    @ObservationIgnored var widebandReader: WidebandReader?
    @ObservationIgnored var simulatedWideband: SimulatedWideband?
    /// The simulated engine of the demo car that is connected, in either mode.
    var demoWorld: DemoWorld? { demoECU?.world ?? simulatedELM?.world }

    // MARK: Updates
    /// A newer release on GitHub: shows the update popup.
    var updateOffer: UpdateRelease?
    var checkingForUpdates = false
    /// On unless turned off, in Settings or with `-autoUpdateCheck NO`.
    var autoUpdateCheck: Bool = UserDefaults.standard.object(forKey: "autoUpdateCheck") == nil || UserDefaults.standard.bool(forKey: "autoUpdateCheck") {
        didSet { UserDefaults.standard.set(autoUpdateCheck, forKey: "autoUpdateCheck") }
    }

    // MARK: Definitions
    var definitions: LoggerDefinitions?
    var definitionsError: String?
    /// Parameters valid for the connected ECU (every parameter while offline).
    var parameters: [ParameterDefinition] = []
    var parametersByID: [String: ParameterDefinition] = [:]
    var codeDefinitions: [DiagnosticCodeDefinition] = []

    // MARK: Selection (persisted)
    var loggedIDs: Set<String> = [] { didSet { persistSelection(); selectionChanged() } }
    var dashboardIDs: [String] = [] { didSet { persistSelection(); selectionChanged() } }
    var unitChoice: [String: String] = [:] {
        didSet {
            persistSelection()
            forgetLive(Set(oldValue.keys).union(unitChoice.keys).filter { oldValue[$0] != unitChoice[$0] })
            selectionChanged()
        }
    }
    /// Style and size per dashboard gauge, keyed by parameter ID.
    var tileConfigs: [String: TileConfig] = [:] {
        didSet {
            guard !suppressPersist, let data = try? JSONEncoder().encode(tileConfigs) else { return }
            UserDefaults.standard.set(data, forKey: "tileConfigs" + mode.keySuffix)
        }
    }
    /// Pressures in kPa, bar or psi whatever the units setting says.
    var pressureUnit: PressureUnit = PressureUnit(rawValue: UserDefaults.standard.string(forKey: "pressureUnit") ?? "") ?? .automatic {
        didSet { UserDefaults.standard.set(pressureUnit.rawValue, forKey: "pressureUnit"); forgetLive(); selectionChanged() }
    }
    var unitSystem: UnitSystem = .metric {
        didSet { UserDefaults.standard.set(unitSystem.rawValue, forKey: "unitSystem"); forgetLive(); selectionChanged() }
    }

    // MARK: Live data
    var latest: [String: Double] = [:]
    var history: [String: [ChartPoint]] = [:]
    var extremes: [String: ClosedRange<Double>] = [:]
    var samplesPerSecond: Double = 0
    var lastRoundTrip: TimeInterval = 0
    var pollError: String?
    private var sampleCounter = 0
    private var pointCounter = 0
    private var rateWindow: [Date] = []
    /// Counts the sets of values asked from the car. A sample or an error that was already on its way when
    /// the set changed or the connection ended carries the old number and is dropped: its values are in the
    /// old set's units (a test's first row would read 190 °F as 190 °C), and its error belongs to a
    /// connection that is gone.
    @ObservationIgnored var pollEpoch = 0
    private var liveStart = Date()
    private var restartTask: Task<Void, Never>?

    // MARK: Recording
    var isRecording = false
    var recordingURL: URL?
    var recordingStart: Date?
    var recordedRows = 0
    private var writer: CSVLogWriter?
    /// Parameter and units of each column of the file being recorded.
    var recordedColumnKeys: [String] { writer?.columns.map { $0.id + $0.conversion.units } ?? [] }
    var logsFolder: URL {
        didSet { UserDefaults.standard.set(logsFolder.path, forKey: "logsFolder") }
    }

    // MARK: Trouble codes
    enum CodeReadState: Equatable { case idle, reading, read(Date), failed(String) }
    var currentCodes: [DiagnosticCodeDefinition] = []
    var memorizedCodes: [DiagnosticCodeDefinition] = []
    var codeReadState: CodeReadState = .idle
    var clearState: String?

    // MARK: Console
    var consoleLines: [ConsoleLine] = []
    var consoleCapturesTraffic = true
    private var consoleCounter = 0

    init() {
        let info = Bundle.main.infoDictionary
        DiagnosticLog.shared.startSession(appVersion: info?["CFBundleShortVersionString"] as? String ?? "dev",
                                          build: info?["CFBundleVersion"] as? String ?? "0")
        // After a crash: no automatic connecting or Bluetooth scanning this once, in case that was the cause.
        let safeStart = DiagnosticLog.shared.previousSessionEndedUnexpectedly
        showCrashPrompt = safeStart
        let defaults = UserDefaults.standard
        logsFolder = defaults.string(forKey: "logsFolder").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("SubieScope Logs")
        unitSystem = UnitSystem(rawValue: defaults.string(forKey: "unitSystem") ?? "") ?? .metric
        // First launch shows the setup wizard. People who used SubieScope before the OBD-II mode existed
        // keep the SSM cable and are not interrupted; they can still run the wizard from the Car menu.
        if defaults.object(forKey: "setupWizardDone") == nil {
            let existingUser = ["cableSetupSeen", "dashboardIDs", "selectedPort"].contains { defaults.object(forKey: $0) != nil }
            if existingUser {
                defaults.set(true, forKey: "setupWizardDone")
                if !ConnectionMode.hasChosen { mode = .ssm }
            }
        }
        let saved = Self.savedSelection(for: mode)
        loggedIDs = saved.logged
        dashboardIDs = saved.dashboard
        unitChoice = saved.units
        tileConfigs = saved.tiles
        selectedPortID = defaults.string(forKey: "selectedPort")
        selectedAdapterID = defaults.string(forKey: "selectedAdapter")
        if case .network = selectedLink, let address = selectedLink?.address { wifiAddress = address }
        loadDefinitions()
        if definitions == nil && mode == .ssm {
            Task { await downloadDefinitions() }
        }
        refreshPorts()
        if mode == .obd && !safeStart { startBLEScan() }
        applyRemoteControl()
        applyDefaultSelection()
        if let raw = defaults.string(forKey: "section"), let s = AppSection(rawValue: raw) { section = s }
        if section == .rom && !advancedMode { section = .dashboard }   // the ROM editor is behind Advanced mode
        // Demo only: start with a simulated fault (e.g. -demoFault vacuumLeak).
        if let raw = defaults.string(forKey: "demoFault"), let fault = DemoFault(rawValue: raw) { demoFault = fault }
        if autoConnect && !safeStart && (mode == .obd ? selectedAdapterID != nil : selectedPortID != nil) {
            Task { await connect() }
        } else if !defaults.bool(forKey: "setupWizardDone") {
            showWizard = true
        }
        checkForUpdatesAtLaunch()
    }

    /// Shown on first launch and from the Car menu.
    var showCableSetup = false

    var autoConnect: Bool = UserDefaults.standard.bool(forKey: "autoConnect") {
        didSet { UserDefaults.standard.set(autoConnect, forKey: "autoConnect") }
    }

    // MARK: Definitions

    func loadDefinitions(from url: URL? = nil) {
        do {
            let defs: LoggerDefinitions
            if let url {
                defs = try LoggerDefinitions.load(url: url)
                UserDefaults.standard.set(url.path, forKey: "customDefinitions")
            } else if let custom = UserDefaults.standard.string(forKey: "customDefinitions"),
                      FileManager.default.fileExists(atPath: custom) {
                defs = try LoggerDefinitions.load(url: URL(fileURLWithPath: custom))
            } else {
                defs = try LoggerDefinitions.bundled()
            }
            definitions = defs
            definitionsError = nil
            applyParameters()
        } catch {
            definitionsError = error.localizedDescription
        }
    }

    var downloadingDefinitions = false

    /// First launch: fetch RomRaider's definitions (not shipped with the app).
    func downloadDefinitions() async {
        guard !downloadingDefinitions else { return }
        downloadingDefinitions = true
        defer { downloadingDefinitions = false }
        do {
            try await DefinitionsStore.download()
            loadDefinitions()
            applyDefaultSelection()
            log("Downloaded the RomRaider parameter definitions")
        } catch {
            definitionsError = "Could not download the parameter definitions: \(error.localizedDescription). Check the internet connection and try again, or choose a RomRaider logger XML in Settings."
        }
    }

    func useBundledDefinitions() {
        UserDefaults.standard.removeObject(forKey: "customDefinitions")
        loadDefinitions()
    }

    /// The parameters to offer: RomRaider's for the connected ECU in SSM mode, standard OBD-II ones in OBD mode.
    func applyParameters() {
        mode == .obd ? applyOBDParameters() : applyDefinitions()
    }

    private func applyDefinitions() {
        guard let definitions else {
            // Not downloaded yet: nothing to offer, rather than the other connection type's values.
            parameters = []
            parametersByID = [:]
            codeDefinitions = []
            return
        }
        let set = definitions.parameterSet(for: identity)
        let list = set.parameters + widebandParameters
        parameters = list
        parametersByID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        codeDefinitions = set.diagnosticCodes
    }

    /// The standard gauges and logged values, when nothing usable is saved: nothing at all, or only values
    /// this connection type does not have (saved once when the definitions were not there yet).
    func applyDefaultSelection() {
        guard !parameters.isEmpty else { return }   // nothing to choose from yet; this runs again when there is
        let known: (String) -> Bool = { id in
            self.parametersByID[id] != nil || (self.definitions != nil && self.equivalentID(for: id) != nil)
        }
        if !dashboardIDs.contains(where: known) {
            if !tileConfigs.keys.contains(where: known) { tileConfigs = [:] }
            dashboardIDs = defaultDashboard()
            applyDefaultTileConfigs()
        }
        if !loggedIDs.contains(where: known) { loggedIDs = Set(defaultLogged()) }
    }

    /// A varied first-run layout, so the gauge styles are visible from the start.
    func applyDefaultTileConfigs() {
        guard tileConfigs.isEmpty else { return }
        let layout: [(String, GaugeStyle, TileSize)] = mode == .obd ? [
            ("Engine Speed", .dial, .large), ("Manifold Relative Pressure", .dial, .large),
            ("Vehicle Speed", .digital, .small), ("Calculated Engine Load", .bar, .small),
            ("Short Term Fuel Trim Bank 1", .bar, .small), ("Long Term Fuel Trim Bank 1", .bar, .small),
            ("Ignition Total Timing", .graph, .wide), ("Coolant Temperature", .dial, .small),
            ("Intake Air Temperature", .dial, .small), ("Throttle Opening Angle", .bar, .wide),
        ] : [
            ("Engine Speed", .dial, .large), ("Manifold Relative Pressure", .dial, .large),
            ("A/F Sensor #1", .digital, .small), ("IAM", .digital, .small),
            ("Feedback Knock Correction", .bar, .small), ("Fine Learning Knock Correction", .bar, .small),
            ("Ignition Total Timing", .graph, .wide), ("Coolant Temperature", .dial, .small),
            ("Intake Air Temperature", .dial, .small), ("Throttle Opening Angle", .bar, .wide),
        ]
        var configs: [String: TileConfig] = [:]
        for (concept, style, size) in layout {
            if let p = resolve(concept) { configs[p.id] = TileConfig(style: style, size: size) }
        }
        tileConfigs = configs
    }

    func defaultDashboard() -> [String] {
        if mode == .obd {
            let wanted = ["Engine Speed", "Manifold Relative Pressure", "Vehicle Speed", "Calculated Engine Load",
                          "Short Term Fuel Trim Bank 1", "Long Term Fuel Trim Bank 1", "Ignition Total Timing",
                          "Coolant Temperature", "Intake Air Temperature", "Throttle Opening Angle"]
            return wanted.compactMap { resolve($0)?.id }
        }
        let wanted = ["Engine Speed", "Manifold Relative Pressure", "A/F Sensor #1", "Feedback Knock Correction",
                      "Fine Learning Knock Correction", "IAM", "Ignition Total Timing", "Coolant Temperature",
                      "Intake Air Temperature", "Throttle Opening Angle"]
        return wanted.compactMap { resolve($0)?.id }
    }

    func defaultLogged() -> [String] {
        if mode == .obd {
            let extra = ["Mass Airflow", "A/F Sensor #1", "Battery Voltage", "Absolute Engine Load", "Accelerator Pedal Angle",
                         "Commanded Lambda", "Engine Oil Temperature"]
            return defaultDashboard() + extra.compactMap { resolve($0)?.id } + widebandParameters.map(\.id)
        }
        let extra = ["Vehicle Speed", "Engine Load (Relative)", "Mass Airflow", "A/F Correction #1", "A/F Learning #1",
                     "Knock Correction Advance", "Primary Wastegate Duty Cycle", "Fuel Injector #1 Pulse Width",
                     "Accelerator Pedal Angle", "Gear Position", "Target Boost"]
        return defaultDashboard() + extra.compactMap { resolve($0)?.id } + widebandParameters.map(\.id)
    }

    /// Several definitions exist for the same value (for 16-bit vs 32-bit ECUs, or
    /// 1 vs 4 byte versions). These are tried in order.
    static let preferredVariants: [String: [String]] = [
        "feedback knock correction": ["Feedback Knock Correction (4-byte)*", "Feedback Knock Correction*", "Feedback Knock Correction (1-byte)**"],
        "fine learning knock correction": ["Fine Learning Knock Correction (4-byte)*", "Fine Learning Knock Correction*",
                                           "Fine Learning Knock Correction (1-byte)**", "Fine Learning Knock Correction"],
        "iam": ["IAM (4-byte)*", "IAM*", "IAM (1-byte)**", "IAM"],
        "knock correction advance": ["Knock Correction Advance (4-byte)*", "Knock Correction Advance"],
        "target boost": ["Target Boost Relative (4-byte)*", "Target Boost (4-byte)*", "Target Boost (2-byte)**", "Target Boost*"],
    ]

    /// "Feedback Knock Correction (4-byte)*" -> "feedback knock correction"
    static func baseName(_ name: String) -> String {
        var n = name.replacingOccurrences(of: "*", with: "")
        if let r = n.range(of: #"\s*\((1|2|4)-byte\)"#, options: [.regularExpression, .caseInsensitive]) {
            n.removeSubrange(r)
        }
        return n.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The best available parameter for a concept such as "IAM" or "Engine Speed".
    func resolve(_ concept: String) -> ParameterDefinition? {
        let key = Self.baseName(concept)
        for name in Self.preferredVariants[key] ?? [] {
            if let p = parameters.first(where: { $0.name == name }) { return p }
        }
        return parameters.first { Self.baseName($0.name) == key } ?? bestMatch(for: concept)
    }

    func tileConfig(for id: String) -> TileConfig {
        tileConfigs[id] ?? tileConfigs[dashboardIDs.first { equivalentID(for: $0) == id } ?? ""] ?? TileConfig()
    }

    func setTileStyle(_ id: String, _ style: GaugeStyle) {
        var c = tileConfig(for: id)
        c.style = style
        tileConfigs[id] = c
    }

    func setTileSize(_ id: String, _ size: TileSize) {
        var c = tileConfig(for: id)
        c.size = size
        tileConfigs[id] = c
    }

    /// Moves a gauge in front of another one (drag and drop).
    func moveTile(_ id: String, before target: String) {
        guard id != target else { return }
        let source = dashboardIDs.contains(id) ? id : (dashboardIDs.first { equivalentID(for: $0) == id } ?? id)
        let destination = dashboardIDs.contains(target) ? target : (dashboardIDs.first { equivalentID(for: $0) == target } ?? target)
        guard let from = dashboardIDs.firstIndex(of: source) else { return }
        var ids = dashboardIDs
        ids.remove(at: from)
        let to = ids.firstIndex(of: destination) ?? ids.count
        ids.insert(source, at: to)
        dashboardIDs = ids
    }

    /// A parameter in the current set that measures the same thing as `id` (same
    /// name apart from RomRaider's 1/2/4-byte variant markers).
    func equivalentID(for id: String) -> String? {
        guard let name = allDefinitionNames[id] else { return nil }
        let key = Self.baseName(name)
        return parameters.first { Self.baseName($0.name) == key }?.id
    }

    @ObservationIgnored private lazy var allDefinitionNames: [String: String] = {
        let everything = definitions?.parameterSet(for: nil).parameters ?? []
        return Dictionary(everything.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }()

    /// After connecting, swaps saved parameter IDs this ECU does not have for a
    /// same-named variant it does have (e.g. E10 -> E39 for Feedback Knock Correction).
    private func remapSelections() {
        guard identity != nil, let definitions else { return }
        let everything = definitions.parameterSet(for: nil).parameters
        let names = Dictionary(everything.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        func remap(_ id: String) -> String {
            if parametersByID[id] != nil { return id }
            guard let name = names[id], let replacement = resolve(name) else { return id }
            return replacement.id
        }
        let newDashboard = dashboardIDs.map(remap).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let newLogged = Set(loggedIDs.map(remap))
        if newDashboard != dashboardIDs { dashboardIDs = newDashboard }
        if newLogged != loggedIDs { loggedIDs = newLogged }
    }

    /// Finds a parameter by name, preferring an exact match, then a prefix match.
    func bestMatch(for name: String) -> ParameterDefinition? {
        let lower = name.lowercased()
        return parameters.first { $0.name.lowercased() == lower }
            ?? parameters.first { $0.name.lowercased().hasPrefix(lower) }
            ?? parameters.first { $0.name.lowercased().contains(lower) }
    }

    func conversion(for parameter: ParameterDefinition) -> Conversion? {
        if isPlayingBack, let playback, let i = playback.parameters.firstIndex(where: { $0.id == parameter.id }) {
            return playback.conversions[i]
        }
        if let chosen = unitChoice[parameter.id], let c = parameter.conversions.first(where: { $0.units == chosen }) {
            return c
        }
        return Self.preferredConversion(parameter.conversions, system: unitSystem, pressure: pressureUnit)
    }

    /// The metric definition file lists metric units first, so metric uses the
    /// file's default and imperial looks for an imperial unit by exact name.
    static func preferredConversion(_ conversions: [Conversion], system: UnitSystem, pressure: PressureUnit = .automatic) -> Conversion? {
        // A chosen pressure unit wins for every parameter that is a pressure; other values follow the units setting.
        if let chosen = pressure.choose(from: conversions) { return chosen }
        guard system == .imperial else { return conversions.first }
        let imperial: Set<String> = ["f", "°f", "psi", "psi relative", "psi absolute", "psi relative sea level", "mph",
                                     "miles", "lb/min", "lbs/min", "inhg", "ft-lb", "lbf-ft", "gal/hr", "mpg"]
        return conversions.first { imperial.contains($0.units.lowercased()) } ?? conversions.first
    }

    private func persistSelection() {
        guard !suppressPersist else { return }
        let d = UserDefaults.standard
        let suffix = mode.keySuffix
        d.set(Array(loggedIDs).sorted(), forKey: "loggedIDs" + suffix)
        d.set(dashboardIDs, forKey: "dashboardIDs" + suffix)
        d.set(unitChoice, forKey: "unitChoice" + suffix)
    }

    /// Gauges, logged parameters and units are remembered separately for each connection mode.
    static func savedSelection(for mode: ConnectionMode) -> (logged: Set<String>, dashboard: [String], units: [String: String], tiles: [String: TileConfig]) {
        let d = UserDefaults.standard
        let suffix = mode.keySuffix
        return (Set(d.stringArray(forKey: "loggedIDs" + suffix) ?? []),
                d.stringArray(forKey: "dashboardIDs" + suffix) ?? [],
                (d.dictionary(forKey: "unitChoice" + suffix) as? [String: String]) ?? [:],
                d.data(forKey: "tileConfigs" + suffix).flatMap { try? JSONDecoder().decode([String: TileConfig].self, from: $0) } ?? [:])
    }

    // MARK: Ports

    /// USB cables with a known chip, including ones still waiting for a driver.
    var cables: [USBCable] = []

    func refreshPorts() {
        ports = SerialPortList.available()
        cables = CableScanner.scan()
        let valid = Set(ports.map(\.path)).union([Self.demoPortID])
        // A Tactrix OpenPort is only picked by itself while its (experimental) support is on.
        let usable = ports.filter { openPortOn || !$0.isOpenPort }
        if selectedPortID == nil || !valid.contains(selectedPortID!) || (!openPortOn && isOpenPort(selectedPortID)) {
            selectedPortID = usable.first(where: { $0.isFTDI })?.path ?? usable.first(where: { $0.isOpenPort })?.path
                ?? usable.first(where: { $0.isUSB })?.path ?? usable.first?.path
        }
    }

    /// Whether the port at `path` is a Tactrix OpenPort 2.0.
    func isOpenPort(_ path: String?) -> Bool {
        guard let path, path != Self.demoPortID else { return false }
        // A port plugged in after the last refresh is looked up fresh.
        let port = ports.first { $0.path == path } ?? SerialPortList.available().first { $0.path == path }
        return port?.isOpenPort ?? false
    }

    /// Whether SubieScope can connect through this cable right now.
    func canUse(_ cable: USBCable) -> Bool {
        cable.isUsable(openPortSupport: openPortOn)
    }

    var selectedPortLabel: String {
        if mode == .obd { return selectedAdapterLabel }
        if selectedPortID == Self.demoPortID { return "Demo ECU (simulated)" }
        return ports.first { $0.path == selectedPortID }?.displayName ?? "No cable found"
    }

    // MARK: Connection

    func connect() async {
        trafficLogBudget = 250
        if mode == .obd { await connectOBD(); return }
        guard connection != .connecting, let portID = selectedPortID else {
            if selectedPortID == nil { connection = .failed("No cable found. Plug in the USB cable and press Refresh.") }
            return
        }
        if isOpenPort(portID) && !openPortOn {
            connection = .failed("This cable is a Tactrix OpenPort 2.0. SubieScope's support for it is experimental: turn on \"Tactrix OpenPort 2.0 cable\" in Settings first.")
            return
        }
        disconnect()
        playback?.pause()
        connection = .connecting
        pollError = nil
        do {
            var path = portID
            var throughOpenPort = isOpenPort(portID)
            isDemo = portID == Self.demoPortID
            if isDemo {
                let demo = try DemoECU.make(definitions: definitions)
                demoECU = demo
                path = demo.ecu.devicePath
                // Testing without the cable: -demoCable openport puts a simulated OpenPort in between.
                if UserDefaults.standard.string(forKey: "demoCable") == "openport" {
                    let cable = try SimulatedOpenPort(ecu: demo.ecu)
                    demoOpenPort = cable
                    path = cable.devicePath
                    throughOpenPort = true
                }
            }
            let session = SSMSession(portPath: path, openPort: throughOpenPort)
            session.fastPoll = fastPoll
            if throughOpenPort {
                // The cable's own conversation says the most when something does not work.
                trafficLogBudget = 600
                session.openPort?.log = { [weak self] line in
                    Task { @MainActor in self?.logOpenPort(line) }
                }
            }
            session.transport.traffic = { [weak self] direction, bytes in
                Task { @MainActor in self?.logTraffic(direction, bytes) }
            }
            if let demo = demoECU {
                session.transport.onBreak = { demo.ecu.simulateBreak() }
            }
            self.session = session
            log("Opening \(isDemo ? "demo ECU on \(path)" : path) at 4800 baud\(throughOpenPort ? " through a Tactrix OpenPort 2.0 (experimental)" : "")")
            let identity = try await session.connect()
            self.identity = identity
            log("ECU answered: ECU ID \(identity.ecuID), system ID \(identity.systemIDString), \(identity.capabilities.count) capability bytes")
            if let cable = session.openPort {
                let volts = try? await session.run { _ in try cable.batteryVoltage() }
                log("Tactrix OpenPort firmware \(cable.firmware ?? "?")" + (volts.map { String(format: ", car battery %.1f V", $0) } ?? ""))
            }
            applyDefinitions()
            remapSelections()
            connection = .connected
            resetLive()
            startWideband()
            startPolling()
            await readECUDetails()
            await readTroubleCodes()
            // Demo and screenshot automation: -startRecipe <id>
            if let id = UserDefaults.standard.string(forKey: "startRecipe"), let recipe = RecipeCatalog.recipe(id: id), recipeRun == nil {
                section = .recipes
                startRecipe(recipe)
            }
        } catch {
            log("Connect failed: \(error.localizedDescription)")
            connection = .failed(error.localizedDescription)
            session?.close()
            session = nil
            demoOpenPort?.stop()
            demoOpenPort = nil
            demoECU?.stop()
            demoECU = nil
        }
    }

    func disconnect() {
        pollEpoch += 1
        stopRecording()
        session?.stopPolling()
        session?.close()
        session = nil
        demoOpenPort?.stop()
        demoOpenPort = nil
        demoECU?.stop()
        demoECU = nil
        closeOBD()
        stopWideband()
        remoteHold = false
        // A test that was running ends with what it has recorded, instead of a step that never moves again.
        if let run = recipeRun, run.isRunning { stopRecipe(analyze: true) }
        if connection == .connected { log("Disconnected") }
        connection = .disconnected
        engineStatus = nil
        showPlaybackIfOpen()
        vin = nil
        vinState = "–"
        samplesPerSecond = 0
    }

    /// With a log open and no car connected, the gauges show the log again.
    private func showPlaybackIfOpen() {
        guard playback != nil else { return }
        lastPlaybackRow = -1
        showPlaybackParameters()
        applyPlayback(at: playback?.playhead ?? 0)
    }

    // MARK: Polling

    var polledItems: [PollItem] {
        if let run = recipeRun, run.isRunning { return run.binding.pollItems }
        let ids = loggedIDs.union(dashboardIDs)
        return parameters.filter { ids.contains($0.id) }.compactMap { p in
            conversion(for: p).map { PollItem(parameter: p, conversion: $0) }
        }
    }

    func selectionChanged() {
        guard connection.isConnected else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.startPolling()
        }
    }

    func startPolling() {
        if mode == .obd { startOBDPolling(); return }
        guard let session else { return }
        let items = polledItems
        if isRecording { rotateRecordingIfColumnsChanged(items) }
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

    /// After a change of units the lowest and highest value and the line of the last minute are numbers in
    /// the old units: they start again, for the values in `ids` or for all of them. Samples still on their
    /// way are in the old units too, so they are dropped until the car is asked again.
    private func forgetLive(_ ids: [String]? = nil) {
        guard connection.isConnected, ids?.isEmpty != true else { return }
        pollEpoch += 1
        if let ids {
            for id in ids {
                extremes[id] = nil
                history[id] = nil
            }
        } else {
            extremes = [:]
            history = [:]
        }
    }

    func resetLive() {
        latest = [:]
        history = [:]
        extremes = [:]
        liveStart = Date()
        rateWindow = []
    }

    func resetExtremes() { extremes = [:] }

    func resetExtremes(for id: String) {
        extremes[id] = latest[id].flatMap { $0.isFinite ? $0...$0 : nil }
    }

    func ingest(_ sample: Sample) {
        var sample = sample
        addWideband(to: &sample)
        pollError = nil
        latest.merge(sample.values) { _, new in new }
        lastRoundTrip = sample.roundTrip
        let t = sample.time.timeIntervalSince(liveStart)
        for (id, value) in sample.values where value.isFinite {
            pointCounter += 1
            var series = history[id, default: []]
            series.append(ChartPoint(id: pointCounter, t: t, value: value))
            if let first = series.first, t - first.t > Self.historySeconds {
                series.removeFirst(series.firstIndex { t - $0.t <= Self.historySeconds } ?? 0)
            }
            history[id] = series
            if let range = extremes[id] {
                extremes[id] = min(range.lowerBound, value)...max(range.upperBound, value)
            } else {
                extremes[id] = value...value
            }
        }
        rateWindow.append(sample.time)
        rateWindow.removeAll { sample.time.timeIntervalSince($0) > 3 }
        if let first = rateWindow.first, rateWindow.count > 1 {
            samplesPerSecond = Double(rateWindow.count - 1) / max(0.001, sample.time.timeIntervalSince(first))
        }
        if let writer {
            writer.append(time: sample.time, values: sample.values)
            recordedRows = writer.rowCount
        }
        if let run = recipeRun, run.isRunning, run.ingest(sample) {
            recipeStepChanged(run)
        }
    }

    func pollFailed(_ error: Error, fatal: Bool) {
        pollError = error.localizedDescription
        log("Poll error: \(error.localizedDescription)")
        if fatal {
            pollEpoch += 1
            stopRecording()
            connection = .failed(mode == .obd ? "Lost contact with the adapter: \(error.localizedDescription)"
                                               : "Lost contact with the ECU: \(error.localizedDescription)")
            session?.close()
            session = nil
            closeOBD()
            stopWideband()
            // A test that was running ends here with what it has recorded, and an open log gets the gauges back.
            if let run = recipeRun, run.isRunning { stopRecipe(analyze: true) }
            showPlaybackIfOpen()
        }
    }

    // MARK: Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard connection.isConnected else { return }
        let items = polledItems.filter { loggedIDs.contains($0.parameter.id) }
        guard !items.isEmpty else { return }
        do {
            let url = logsFolder.appendingPathComponent(CSVLogWriter.defaultFileName())
            writer = try CSVLogWriter(url: url, columns: items.map {
                CSVLogWriter.Column(id: $0.parameter.id, title: $0.parameter.name, conversion: $0.conversion)
            })
            recordingURL = url
            recordingStart = Date()
            recordedRows = 0
            isRecording = true
            log("Recording to \(url.path)")
        } catch {
            pollError = "Could not create log file: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        writer?.close()
        writer = nil
        isRecording = false
        log("Saved \(recordedRows) rows to \(recordingURL?.lastPathComponent ?? "log")")
    }

    /// A CSV has a fixed header, so a change in logged parameters starts a new file.
    private func rotateRecordingIfColumnsChanged(_ items: [PollItem]) {
        let wanted = items.filter { loggedIDs.contains($0.parameter.id) }.map { $0.parameter.id + $0.conversion.units }
        let current = writer?.columns.map { $0.id + $0.conversion.units } ?? []
        if wanted != current {
            stopRecording()
            startRecording()
        }
    }

    // MARK: Trouble codes

    func readTroubleCodes() async {
        if mode == .obd { await readOBDTroubleCodes(); return }
        guard let session, connection.isConnected else { return }
        let defs = codeDefinitions
        guard !defs.isEmpty else {
            codeReadState = .failed("The loaded definitions contain no trouble codes.")
            return
        }
        codeReadState = .reading
        do {
            let report = try await session.run { client in try TroubleCodeReport.read(with: client, definitions: defs) }
            currentCodes = report.current
            memorizedCodes = report.memorized
            if let identity {
                engineStatus = try? await session.run { client in try EngineDiagnostics.readStatus(with: client, identity: identity) }
            }
            codeReadState = .read(Date())
            log("Trouble codes: \(currentCodes.count) current, \(memorizedCodes.count) memorized")
        } catch {
            codeReadState = .failed(error.localizedDescription)
            log("Reading trouble codes failed: \(error.localizedDescription)")
        }
    }

    func clearTroubleCodes() async {
        if mode == .obd { await clearOBDTroubleCodes(); return }
        guard let session, connection.isConnected else { return }
        clearState = "Clearing…"
        do {
            try await session.run { client in try ClearMemory.perform(with: client) }
            clearState = "Memory cleared. Turn the ignition OFF, wait 10 seconds, then turn it back ON."
            log("Clear memory command accepted")
            currentCodes = []
            memorizedCodes = []
            codeReadState = .idle
        } catch {
            clearState = "Clearing failed: \(error.localizedDescription)"
        }
    }

    // MARK: ECU details

    var vin: String?
    var vinState: String = "–"
    var engineStatus: EngineDiagnostics.Status?

    var fastPoll: Bool = UserDefaults.standard.object(forKey: "fastPoll") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(fastPoll, forKey: "fastPoll")
            session?.fastPoll = fastPoll
            selectionChanged()
        }
    }

    var extendedCount: Int { parameters.filter { $0.kind == .extended }.count }

    var knownECUDescription: String? {
        identity.flatMap { EngineDiagnostics.knownECUs[$0.ecuID] }
    }

    private func readECUDetails() async {
        guard let session, let identity else { return }
        engineStatus = try? await session.run { client in try EngineDiagnostics.readStatus(with: client, identity: identity) }
        if EngineDiagnostics.supportsVIN(identity) {
            do {
                vin = try await session.run { client in try EngineDiagnostics.readVIN(with: client) }
                vinState = vin ?? "Not programmed (normal for JDM cars)"
            } catch {
                vinState = "Could not read: \(error.localizedDescription)"
            }
        } else {
            vin = nil
            vinState = "Not supported by this ECU"
        }
    }

    // MARK: Log playback

    var playback: LogPlayback?
    var playbackError: String?

    /// The dashboard and trends show the open log instead of live data (only while offline).
    var isPlayingBack: Bool { playback != nil && !connection.isConnected }

    /// Dashboard gauges to show: the saved ones that exist, or the log's first columns.
    var visibleDashboardIDs: [String] {
        var existing: [String] = []
        for id in dashboardIDs {
            guard let match = parametersByID[id] != nil ? id : equivalentID(for: id) else { continue }
            if !existing.contains(match) { existing.append(match) }
        }
        if isPlayingBack && existing.isEmpty, let playback {
            return Array(playback.parameters.filter { $0.kind != .switchBit }.prefix(9).map(\.id))
        }
        return existing
    }

    func openLog(_ url: URL) async {
        if playback?.url == url { return }
        closePlayback()
        do {
            let log = try await Task.detached { try RecordedLog.load(url) }.value
            guard log.rowCount > 0, !log.columns.isEmpty else {
                playbackError = "\(url.lastPathComponent) contains no log rows."
                return
            }
            let all = (definitions?.parameterSet(for: nil).parameters ?? []) + [AEMWideband.definition]
            let playback = LogPlayback(url: url, log: log, definitions: all)
            playback.onPlayhead = { [weak self] t in self?.applyPlayback(at: t) }
            self.playback = playback
            playbackError = nil
            if !connection.isConnected {
                showPlaybackParameters()
                applyPlayback(at: 0)
            }
            self.log("Opened \(url.lastPathComponent): \(log.rowCount) rows, \(log.columns.count) columns")
        } catch {
            playbackError = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func closePlayback() {
        guard let playback else { return }
        playback.pause()
        self.playback = nil
        if !connection.isConnected {
            applyDefinitions()
            resetLive()
        }
    }

    private func showPlaybackParameters() {
        guard let playback else { return }
        parameters = playback.parameters
        parametersByID = Dictionary(playback.parameters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        extremes = [:]
        for (i, p) in playback.parameters.enumerated() {
            if let r = playback.extremes[i] { extremes[p.id] = r }
        }
    }

    private var lastPlaybackRow = -1

    private func applyPlayback(at t: Double) {
        guard isPlayingBack, let playback else { return }
        let log = playback.log
        let row = log.row(at: t)
        guard row != lastPlaybackRow else { return }
        lastPlaybackRow = row
        latest = playback.values(at: t)
        // Trend lines: the minute before the playhead.
        let first = log.row(at: max(0, t - Self.historySeconds))
        var history: [String: [ChartPoint]] = [:]
        for (i, p) in playback.parameters.enumerated() {
            var points: [ChartPoint] = []
            points.reserveCapacity(row - first + 1)
            for r in first...row where log.values[i][r].isFinite {
                points.append(ChartPoint(id: r, t: log.time[r], value: log.values[i][r]))
            }
            history[p.id] = points
        }
        self.history = history
        let rate = playback.duration > 0 ? Double(log.rowCount - 1) / playback.duration : 0
        samplesPerSecond = rate
    }

    // MARK: Recipes

    var recipeRun: RecipeRun?
    var logAnalysis: LogAnalysisResult?
    var demoFault: DemoFault = .none {
        didSet { setDemoFault(demoFault) }
    }

    func setDemoFault(_ fault: DemoFault) {
        demoECU?.setFault(fault)
        simulatedELM?.world.setFault(fault)
    }

    func setDemoScenario(_ scenario: DemoScenario?) {
        demoECU?.setScenario(scenario)
        simulatedELM?.world.setScenario(scenario)
    }

    func binding(for recipe: Recipe) -> RecipeBinding {
        RecipeBinding(recipe: recipe, parameters: parameters, useWideband: recipesUseWideband)
    }

    func startRecipe(_ recipe: Recipe) {
        guard connection.isConnected else { return }
        let binding = binding(for: recipe)
        guard binding.isRunnable else { return }
        stopRecording()
        let run = RecipeRun(recipe: recipe, binding: binding, context: RecipeContext(identity: identity))
        let url = logsFolder.appendingPathComponent(CSVLogWriter.defaultFileName(prefix: "subiescope_\(recipe.id)"))
        run.writer = try? CSVLogWriter(url: url, columns: binding.pollItems.map {
            CSVLogWriter.Column(id: $0.parameter.id, title: $0.parameter.name, conversion: $0.conversion)
        })
        run.logURL = run.writer == nil ? nil : url
        recipeRun = run
        logAnalysis = nil
        setDemoFault(demoFault)
        setDemoScenario(recipe.steps.first?.demo)
        log("Recipe started: \(recipe.title)")
        startPolling()
    }

    func advanceRecipe(completed: Bool = true) {
        guard let run = recipeRun, run.isRunning else { return }
        run.advance(completed: completed)
        recipeStepChanged(run)
    }

    /// Stop now; with `analyze` the data so far is still analysed.
    func stopRecipe(analyze: Bool) {
        guard let run = recipeRun, run.isRunning else { return }
        if analyze { run.finishEarly() } else { run.abort() }
        finishRecipe(run)
    }

    func dismissRecipe() {
        if let run = recipeRun, run.isRunning { stopRecipe(analyze: false) }
        recipeRun = nil
    }

    private func recipeStepChanged(_ run: RecipeRun) {
        if run.isRunning {
            setDemoScenario(run.step?.demo)
        } else {
            finishRecipe(run)
        }
    }

    private func finishRecipe(_ run: RecipeRun) {
        run.writer?.close()
        run.writer = nil
        setDemoScenario(nil)
        if run.findings != nil, let logURL = run.logURL {
            let reportURL = logURL.deletingPathExtension().appendingPathExtension("txt")
            try? run.reportText().write(to: reportURL, atomically: true, encoding: .utf8)
            run.reportURL = reportURL
        }
        log(run.aborted ? "Recipe stopped: \(run.recipe.title)" : "Recipe finished: \(run.recipe.title)")
        startPolling()
    }

    /// Runs a recipe's analysis on an existing CSV log.
    func analyzeLog(_ url: URL, with recipe: Recipe) async {
        do {
            let log = try await Task.detached { try RecordedLog.load(url) }.value
            let (data, available, fromWideband) = RecipeBinding.dataSet(for: recipe, log: log, useWideband: recipesUseWideband)
            let missing = recipe.probes.filter { $0.required && !available.contains($0.key) }
            var analysis = Analysis(log: data, available: available, context: RecipeContext(identity: identity))
            analysis.mixtureFromWideband = fromWideband
            let findings = missing.isEmpty ? recipe.findings(for: analysis) : []
            logAnalysis = LogAnalysisResult(recipe: recipe, logName: url.lastPathComponent, findings: findings, missing: missing)
        } catch {
            logAnalysis = LogAnalysisResult(recipe: recipe, logName: url.lastPathComponent,
                                            findings: [Finding(.fail, "Could not read the log", error.localizedDescription)], missing: [])
        }
    }

    // MARK: Console

    func log(_ text: String) {
        appendConsole(ConsoleLine(id: nextConsoleID(), time: Date(), kind: nil, text: text))
        DiagnosticLog.shared.info("app", text)
    }

    func logTraffic(_ direction: SSMTrafficDirection, _ bytes: [UInt8]) {
        if trafficLogBudget > 0 {
            trafficLogBudget -= 1
            DiagnosticLog.shared.debug("ssm", "\(direction) \(bytes.hexString)")
        }
        guard consoleCapturesTraffic else { return }
        appendConsole(ConsoleLine(id: nextConsoleID(), time: Date(), kind: direction, text: bytes.hexString))
    }

    /// A line of the conversation with a Tactrix OpenPort: its commands, replies and message frames.
    func logOpenPort(_ line: String) {
        if trafficLogBudget > 0 {
            trafficLogBudget -= 1
            DiagnosticLog.shared.debug("openport", line)
        }
        guard consoleCapturesTraffic else { return }
        appendConsole(ConsoleLine(id: nextConsoleID(), time: Date(), kind: nil, text: line))
    }

    func nextConsoleID() -> Int {
        consoleCounter += 1
        return consoleCounter
    }

    func appendConsole(_ line: ConsoleLine) {
        consoleLines.append(line)
        if consoleLines.count > 3000 { consoleLines.removeFirst(consoleLines.count - 3000) }
    }

    func clearConsole() { consoleLines = [] }
}
