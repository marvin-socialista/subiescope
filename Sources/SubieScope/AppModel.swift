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
    case dashboard, logger, recipes, diagnostics, ecuInfo, logs, dyno, console
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
        didSet { UserDefaults.standard.set(selectedPortID, forKey: "selectedPort") }
    }
    var connection: ConnectionState = .disconnected
    var identity: ECUIdentity?
    var isDemo = false
    private var session: SSMSession?
    private var demoECU: DemoECU?

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
    var unitChoice: [String: String] = [:] { didSet { persistSelection(); selectionChanged() } }
    /// Style and size per dashboard gauge, keyed by parameter ID.
    var tileConfigs: [String: TileConfig] = [:] {
        didSet { if let data = try? JSONEncoder().encode(tileConfigs) { UserDefaults.standard.set(data, forKey: "tileConfigs") } }
    }
    var unitSystem: UnitSystem = .metric {
        didSet { UserDefaults.standard.set(unitSystem.rawValue, forKey: "unitSystem"); selectionChanged() }
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
    private var liveStart = Date()
    private var restartTask: Task<Void, Never>?

    // MARK: Recording
    var isRecording = false
    var recordingURL: URL?
    var recordingStart: Date?
    var recordedRows = 0
    private var writer: CSVLogWriter?
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
        let defaults = UserDefaults.standard
        logsFolder = defaults.string(forKey: "logsFolder").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("SubieScope Logs")
        unitSystem = UnitSystem(rawValue: defaults.string(forKey: "unitSystem") ?? "") ?? .metric
        loggedIDs = Set(defaults.stringArray(forKey: "loggedIDs") ?? [])
        dashboardIDs = defaults.stringArray(forKey: "dashboardIDs") ?? []
        unitChoice = (defaults.dictionary(forKey: "unitChoice") as? [String: String]) ?? [:]
        tileConfigs = defaults.data(forKey: "tileConfigs").flatMap { try? JSONDecoder().decode([String: TileConfig].self, from: $0) } ?? [:]
        selectedPortID = defaults.string(forKey: "selectedPort")
        loadDefinitions()
        if definitions == nil {
            Task { await downloadDefinitions() }
        }
        refreshPorts()
        if dashboardIDs.isEmpty { dashboardIDs = defaultDashboard(); applyDefaultTileConfigs() }
        if loggedIDs.isEmpty { loggedIDs = Set(defaultLogged()) }
        if let raw = defaults.string(forKey: "section"), let s = AppSection(rawValue: raw) { section = s }
        // Demo only: start with a simulated fault (e.g. -demoFault vacuumLeak).
        if let raw = defaults.string(forKey: "demoFault"), let fault = DemoFault(rawValue: raw) { demoFault = fault }
        if autoConnect && selectedPortID != nil {
            Task { await connect() }
        } else if !defaults.bool(forKey: "cableSetupSeen") {
            showCableSetup = true
        }
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
            applyDefinitions()
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
            if dashboardIDs.isEmpty { dashboardIDs = defaultDashboard(); applyDefaultTileConfigs() }
            if loggedIDs.isEmpty { loggedIDs = Set(defaultLogged()) }
            log("Downloaded the RomRaider parameter definitions")
        } catch {
            definitionsError = "Could not download the parameter definitions: \(error.localizedDescription). Check the internet connection and try again, or choose a RomRaider logger XML in Settings."
        }
    }

    func useBundledDefinitions() {
        UserDefaults.standard.removeObject(forKey: "customDefinitions")
        loadDefinitions()
    }

    private func applyDefinitions() {
        guard let definitions else { return }
        let set = definitions.parameterSet(for: identity)
        parameters = set.parameters
        parametersByID = Dictionary(set.parameters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        codeDefinitions = set.diagnosticCodes
    }

    /// A varied first-run layout, so the gauge styles are visible from the start.
    private func applyDefaultTileConfigs() {
        guard tileConfigs.isEmpty else { return }
        let layout: [(String, GaugeStyle, TileSize)] = [
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

    private func defaultDashboard() -> [String] {
        let wanted = ["Engine Speed", "Manifold Relative Pressure", "A/F Sensor #1", "Feedback Knock Correction",
                      "Fine Learning Knock Correction", "IAM", "Ignition Total Timing", "Coolant Temperature",
                      "Intake Air Temperature", "Throttle Opening Angle"]
        return wanted.compactMap { resolve($0)?.id }
    }

    private func defaultLogged() -> [String] {
        let extra = ["Vehicle Speed", "Engine Load (Relative)", "Mass Airflow", "A/F Correction #1", "A/F Learning #1",
                     "Knock Correction Advance", "Primary Wastegate Duty Cycle", "Fuel Injector #1 Pulse Width",
                     "Accelerator Pedal Angle", "Gear Position", "Target Boost"]
        return defaultDashboard() + extra.compactMap { resolve($0)?.id }
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
        return Self.preferredConversion(parameter.conversions, system: unitSystem)
    }

    /// The metric definition file lists metric units first, so metric uses the
    /// file's default and imperial looks for an imperial unit by exact name.
    static func preferredConversion(_ conversions: [Conversion], system: UnitSystem) -> Conversion? {
        guard system == .imperial else { return conversions.first }
        let imperial: Set<String> = ["f", "°f", "psi", "psi relative", "psi absolute", "psi relative sea level", "mph",
                                     "miles", "lb/min", "lbs/min", "inhg", "ft-lb", "lbf-ft", "gal/hr", "mpg"]
        return conversions.first { imperial.contains($0.units.lowercased()) } ?? conversions.first
    }

    private func persistSelection() {
        let d = UserDefaults.standard
        d.set(Array(loggedIDs).sorted(), forKey: "loggedIDs")
        d.set(dashboardIDs, forKey: "dashboardIDs")
        d.set(unitChoice, forKey: "unitChoice")
    }

    // MARK: Ports

    func refreshPorts() {
        ports = SerialPortList.available()
        let valid = Set(ports.map(\.path)).union([Self.demoPortID])
        if selectedPortID == nil || !valid.contains(selectedPortID!) {
            selectedPortID = ports.first(where: { $0.isFTDI })?.path ?? ports.first(where: { $0.isUSB })?.path ?? ports.first?.path
        }
    }

    var selectedPortLabel: String {
        if selectedPortID == Self.demoPortID { return "Demo ECU (simulated)" }
        return ports.first { $0.path == selectedPortID }?.displayName ?? "No cable found"
    }

    // MARK: Connection

    func connect() async {
        guard connection != .connecting, let portID = selectedPortID else {
            if selectedPortID == nil { connection = .failed("No cable found. Plug in the USB cable and press Refresh.") }
            return
        }
        disconnect()
        playback?.pause()
        connection = .connecting
        pollError = nil
        do {
            var path = portID
            isDemo = portID == Self.demoPortID
            if isDemo {
                let demo = try DemoECU.make(definitions: definitions)
                demoECU = demo
                path = demo.ecu.devicePath
            }
            let session = SSMSession(portPath: path)
            session.fastPoll = fastPoll
            session.transport.traffic = { [weak self] direction, bytes in
                Task { @MainActor in self?.logTraffic(direction, bytes) }
            }
            if let demo = demoECU {
                session.transport.onBreak = { demo.ecu.simulateBreak() }
            }
            self.session = session
            log("Opening \(isDemo ? "demo ECU on \(path)" : path) at 4800 baud")
            let identity = try await session.connect()
            self.identity = identity
            log("ECU answered: ECU ID \(identity.ecuID), system ID \(identity.systemIDString), \(identity.capabilities.count) capability bytes")
            applyDefinitions()
            remapSelections()
            connection = .connected
            resetLive()
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
            demoECU?.stop()
            demoECU = nil
        }
    }

    func disconnect() {
        stopRecording()
        session?.stopPolling()
        session?.close()
        session = nil
        demoECU?.stop()
        demoECU = nil
        if connection == .connected { log("Disconnected") }
        connection = .disconnected
        engineStatus = nil
        if playback != nil {
            lastPlaybackRow = -1
            showPlaybackParameters()
            applyPlayback(at: playback?.playhead ?? 0)
        }
        vin = nil
        vinState = "–"
        samplesPerSecond = 0
    }

    // MARK: Polling

    var polledItems: [PollItem] {
        if let run = recipeRun, run.isRunning { return run.binding.pollItems }
        let ids = loggedIDs.union(dashboardIDs)
        return parameters.filter { ids.contains($0.id) }.compactMap { p in
            conversion(for: p).map { PollItem(parameter: p, conversion: $0) }
        }
    }

    private func selectionChanged() {
        guard connection.isConnected else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.startPolling()
        }
    }

    private func startPolling() {
        guard let session else { return }
        let items = polledItems
        if isRecording { rotateRecordingIfColumnsChanged(items) }
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

    private func resetLive() {
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

    private func ingest(_ sample: Sample) {
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

    private func pollFailed(_ error: Error, fatal: Bool) {
        pollError = error.localizedDescription
        log("Poll error: \(error.localizedDescription)")
        if fatal {
            stopRecording()
            connection = .failed("Lost contact with the ECU: \(error.localizedDescription)")
            session?.close()
            session = nil
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
        }
    }

    func clearTroubleCodes() async {
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
            let all = definitions?.parameterSet(for: nil).parameters ?? []
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
        didSet { demoECU?.setFault(demoFault) }
    }

    func binding(for recipe: Recipe) -> RecipeBinding {
        RecipeBinding(recipe: recipe, parameters: parameters)
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
        demoECU?.setFault(demoFault)
        demoECU?.setScenario(recipe.steps.first?.demo)
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
            demoECU?.setScenario(run.step?.demo)
        } else {
            finishRecipe(run)
        }
    }

    private func finishRecipe(_ run: RecipeRun) {
        run.writer?.close()
        run.writer = nil
        demoECU?.setScenario(nil)
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
            let (data, available) = RecipeBinding.dataSet(for: recipe, log: log)
            let missing = recipe.probes.filter { $0.required && !available.contains($0.key) }
            let findings = missing.isEmpty
                ? recipe.analyze(Analysis(log: data, available: available, context: RecipeContext(identity: identity)))
                : []
            logAnalysis = LogAnalysisResult(recipe: recipe, logName: url.lastPathComponent, findings: findings, missing: missing)
        } catch {
            logAnalysis = LogAnalysisResult(recipe: recipe, logName: url.lastPathComponent,
                                            findings: [Finding(.fail, "Could not read the log", error.localizedDescription)], missing: [])
        }
    }

    // MARK: Console

    func log(_ text: String) {
        appendConsole(ConsoleLine(id: nextConsoleID(), time: Date(), kind: nil, text: text))
    }

    private func logTraffic(_ direction: SSMTrafficDirection, _ bytes: [UInt8]) {
        guard consoleCapturesTraffic else { return }
        appendConsole(ConsoleLine(id: nextConsoleID(), time: Date(), kind: direction, text: bytes.hexString))
    }

    private func nextConsoleID() -> Int {
        consoleCounter += 1
        return consoleCounter
    }

    private func appendConsole(_ line: ConsoleLine) {
        consoleLines.append(line)
        if consoleLines.count > 3000 { consoleLines.removeFirst(consoleLines.count - 3000) }
    }

    func clearConsole() { consoleLines = [] }
}
