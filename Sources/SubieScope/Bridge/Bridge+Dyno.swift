#if os(Windows) || DEBUG
import Foundation
import SSMKit

/// The virtual dyno: the log it reads, the car's details, and the pulls it finds with their curves.
/// (The Mac app's `DynoView`.)
extension Bridge {
    /// Everything the dyno shows. Slice `dyno`.
    struct DynoState: Encodable {
        struct Log: Encodable {
            /// The file's whole path. It is how the page names the log in `dyno.select`.
            let path: String
            /// What the list shows: the file's name.
            let name: String
        }

        struct Unit: Encodable {
            /// ps, hp or kW
            let value: String
            let label: String
        }

        /// The car's details, each as the text its field shows ("1,560"). A field is changed with
        /// `dyno.set`, by its name here.
        struct Car: Encodable {
            let massKg: String
            let tireWidthMM: String
            let tireAspect: String
            let rimInches: String
            let finalDrive: String
            let dragCoefficient: String
            let frontalAreaM2: String
            /// In percent.
            let drivetrainLoss: String
        }

        /// Counts the visits to this part of the app. `dyno.appear` answers with the number of the
        /// visit it started, so the page knows when this state is about that visit.
        let visit: Int
        /// The logs in the recordings folder, newest first. A log opened from somewhere else comes last.
        let logs: [Log]
        /// The path of the chosen log. Nil while none is chosen.
        let selected: String?
        /// The chosen log is still being read.
        let loading: Bool

        let car: Car
        /// The gear is worked out from road speed and engine speed. When off, `gear` is used.
        let detectGear: Bool
        let gear: Int
        let gearCount: Int

        /// The unit power is shown in, and the ones to choose from.
        let unit: String
        let units: [Unit]

        /// Recording a pull needs the car.
        let connected: Bool

        /// How this computer writes numbers ("," and "." in English), for the numbers along the charts.
        let groupingSeparator: String
        let decimalSeparator: String

        /// What the pulls in the log gave. Nil while there is no log, and for a log without a pull.
        let result: DynoResult?
    }

    /// The right side, for a log with at least one pull in it.
    struct DynoResult: Encodable {
        /// The answer to "was that a good pull?".
        struct Verdict: Encodable {
            /// good, usable or retry
            let quality: String
            let title: String
            /// Why it is not perfect, and what to do next time.
            let issues: [String]
        }

        /// One of the three large numbers.
        struct Tile: Encodable {
            let title: String
            let value: String
            let unit: String
            let detail: String
        }

        struct Run: Encodable {
            let id: Int
            /// Which of the eight series colours belongs to this pull (`--series-0` to `--series-7`).
            let color: Int
            /// Its curves are drawn.
            let shown: Bool
            /// "Pull 1"
            let name: String
            /// "gear 3 · 2600–6800 rpm · at 0:05"
            let detail: String
            /// "218 PS"
            let power: String?
            /// good, usable or retry
            let quality: String
            /// "Good pull"
            let badge: String
            /// The pull's issues, one on each line, for the tooltip.
            let notes: String
        }

        struct Chart: Encodable {
            struct Series: Encodable {
                let id: Int
                let name: String
                let color: Int
                /// Engine speed and value in turn: [rpm, value, rpm, value, …], by rising rpm.
                let points: [Double]
            }

            let title: String
            let unit: String
            /// The ends of the rpm axis.
            let low: Double
            let high: Double
            /// The pulls that are shown.
            let series: [Series]
        }

        let verdict: Verdict
        let tiles: [Tile]
        let runs: [Run]
        /// Wheel power, then torque.
        let charts: [Chart]
    }

    /// A car whose details can be filled in, as a row of the list to choose from. Request `dyno.cars`.
    struct DynoCarChoice: Encodable {
        /// How the page names the car in `dyno.fillIn`.
        let id: String
        /// "2009 E/USDM STi 6MT"
        let name: String
        /// The list is in the order of the years, and has a heading for each.
        let year: Int
    }

    func registerDyno() {
        let dyno = DynoSession(model: model)
        dyno.changed = { [weak self] in self?.invalidate("dyno") }

        slice("dyno") { [model] in
            let settings = dyno.settings
            var logs = dyno.files.map { DynoState.Log(path: $0.path, name: $0.url.lastPathComponent) }
            if let url = dyno.selectedURL, !dyno.files.contains(where: { $0.path == DynoSession.path(url) }) {
                logs.append(.init(path: DynoSession.path(url), name: url.lastPathComponent))
            }
            let numbers = Bridge.dynoFormatter(decimals: nil)
            return DynoState(
                visit: dyno.visit, logs: logs, selected: dyno.selectedURL.map(DynoSession.path), loading: dyno.isLoading,
                car: Bridge.dynoCar(settings),
                detectGear: dyno.autoGear, gear: settings.gear ?? 3, gearCount: settings.gearRatios.count,
                unit: dyno.unit.rawValue, units: PowerUnit.allCases.map { .init(value: $0.rawValue, label: $0.label) },
                connected: model.connection.isConnected,
                groupingSeparator: numbers.groupingSeparator ?? ",", decimalSeparator: numbers.decimalSeparator ?? ".",
                result: Bridge.dynoResult(dyno))
        }

        // The page shows this part of the app. Answers with the number of the visit (see `DynoState.visit`).
        request("dyno.appear") { _ in dyno.appear() }
        action("dyno.disappear") { _ in dyno.disappear() }

        // `path` is one of the logs in the list; without it no log is chosen.
        action("dyno.select") { arguments in
            guard let path = arguments.string("path"), !path.isEmpty else { return dyno.select(nil) }
            if let file = dyno.files.first(where: { $0.path == path }) { dyno.select(file.url) }
        }
        action("dyno.openOther") { _ in
            // The Mac's panel starts in the recordings folder. `Desktop` cannot say where to start.
            guard let url = Desktop.chooseFileToOpen(filter: ["Logs", "*.csv;*.txt"]) else { return }
            dyno.select(url)
        }

        // What was typed in one of the car's fields (`field` is its name in `DynoState.Car`).
        // Text that is not a number changes nothing. Answers with what the fields show now, so the
        // page can put the old number back, or the new one as the app writes it.
        request("dyno.set") { arguments in
            if let field = arguments.string("field"), let number = Bridge.dynoNumber(arguments.string("text") ?? "") {
                dyno.change { settings in
                    switch field {
                    case "massKg": settings.massKg = number
                    case "tireWidthMM": settings.tireWidthMM = number
                    case "tireAspect": settings.tireAspect = number
                    case "rimInches": settings.rimInches = number
                    case "finalDrive": settings.finalDrive = number
                    case "dragCoefficient": settings.dragCoefficient = number
                    case "frontalAreaM2": settings.frontalAreaM2 = number
                    case "drivetrainLoss": settings.drivetrainLoss = number / 100
                    default: break
                    }
                }
            }
            return Bridge.dynoCar(dyno.settings)
        }
        action("dyno.detectGear") { arguments in dyno.setAutoGear(arguments.bool("on")) }
        action("dyno.gear") { arguments in
            guard let gear = arguments.int("gear"), (1...max(1, dyno.settings.gearRatios.count)).contains(gear) else { return }
            dyno.change { $0.gear = gear }
        }
        action("dyno.reset") { _ in dyno.change { $0 = DynoSettings() } }

        // "Fill In From a Car": the cars of RomRaider's list by year, as the Mac's menu has them
        // (one submenu for every year there). The list never changes, so the page asks for it once.
        request("dyno.cars") { _ in
            DynoCar.library.enumerated()
                .sorted { ($0.element.year, $0.offset) < ($1.element.year, $1.offset) }
                .map { _, car in DynoCarChoice(id: car.id, name: car.name, year: car.year) }
        }
        // Takes the weight, gear ratios, final drive, tyre size and drag of that car.
        action("dyno.fillIn") { arguments in
            guard let id = arguments.string("car"), let car = DynoCar.library.first(where: { $0.id == id }) else { return }
            dyno.change { $0 = $0.applying(car) }
        }
        action("dyno.unit") { arguments in
            guard let unit = arguments.string("unit").flatMap(PowerUnit.init(rawValue:)) else { return }
            dyno.setUnit(unit)
        }
        // Ticks or unticks a pull in the list.
        action("dyno.show") { arguments in
            guard let id = arguments.int("id") else { return }
            dyno.setShown(id, arguments.bool("shown"))
        }
        // "Record a Pull" in the guide: the full-throttle pull of Troubleshooting.
        action("dyno.recordPull") { [model] _ in
            guard let pull = RecipeCatalog.recipe(id: "pull") else { return }
            model.section = .recipes
            model.startRecipe(pull)
        }
    }

    // MARK: What the pulls gave

    /// The verdict, the three large numbers, the list of pulls and the two charts. (The Mac's
    /// `pullVerdict`, `peaks`, `runList` and `DynoChart`, with the same words and the same rounding.)
    static func dynoResult(_ dyno: DynoSession) -> DynoResult? {
        let runs = dyno.runs
        guard !runs.isEmpty else { return nil }
        let unit = dyno.unit
        let visible = runs.filter { dyno.shownRuns.contains($0.id) }
        func name(_ verdict: PullQuality.Verdict) -> String {
            switch verdict {
            case .good: return "good"
            case .usable: return "usable"
            case .retry: return "retry"
            }
        }
        func rounded(_ value: Double) -> String { String(format: "%.0f", value) }

        // The best pull of the log speaks for it, shown or not.
        let best = runs.min { $0.quality.verdict < $1.quality.verdict }
        let quality = best?.quality ?? PullQuality(verdict: .retry, issues: [])
        let title: String
        switch quality.verdict {
        case .good: title = runs.count > 1 ? "Pull \(best?.id ?? 1) is a good pull. Trust these numbers." : "Good pull. Trust these numbers."
        case .usable: title = "Usable pull, but see the notes before trusting the numbers."
        case .retry: title = "Retry: this pull isn't good enough for a reliable result."
        }

        // Peaks come only from the best-rated visible pulls: a "retry" pull shouldn't set the headline number.
        var trusted: [DynoRun] = []
        if let bestVerdict = visible.map(\.quality.verdict).min() {
            trusted = visible.filter { $0.quality.verdict == bestVerdict }
        }
        let peak = trusted.compactMap(\.peakPower).max { $0.wheelPower < $1.wheelPower }
        let peakTorque = trusted.compactMap(\.peakTorque).max { $0.torque < $1.torque }
        let loss = dyno.settings.drivetrainLoss
        let tiles = [
            DynoResult.Tile(title: "Peak wheel power", value: peak.map { rounded(unit.convert($0.wheelPower)) } ?? "–",
                            unit: unit.label, detail: peak.map { "at \(dynoWhole($0.rpm)) rpm" } ?? ""),
            DynoResult.Tile(title: "Peak torque", value: peakTorque.map { rounded($0.torque) } ?? "–",
                            unit: "Nm", detail: peakTorque.map { "at \(dynoWhole($0.rpm)) rpm" } ?? ""),
            DynoResult.Tile(title: "Estimated at the crank", value: peak.map { rounded(unit.convert($0.wheelPower / (1 - loss))) } ?? "–",
                            unit: unit.label, detail: "with \(dynoWhole(loss * 100)) % drivetrain loss"),
        ]

        // A pull keeps its colour whether the others are shown or not, so the line always matches the
        // mark in the list. (On the Mac the lines take their colours in the order they are drawn.)
        var colors: [Int: Int] = [:]
        for (index, run) in runs.enumerated() { colors[run.id] = index % SeriesPalette.count }

        let rows = runs.map { run in
            DynoResult.Run(
                id: run.id, color: colors[run.id] ?? 0, shown: dyno.shownRuns.contains(run.id), name: "Pull \(run.id)",
                detail: "gear \(run.gear) · \(dynoWhole(run.rpmRange?.lowerBound ?? 0))–\(dynoWhole(run.rpmRange?.upperBound ?? 0)) rpm · at \(formatLogTime(run.startTime, decimals: 0))",
                power: run.peakPower.map { "\(rounded(unit.convert($0.wheelPower))) \(unit.label)" },
                quality: name(run.quality.verdict), badge: run.quality.headline, notes: run.quality.issues.joined(separator: "\n"))
        }

        func chart(_ title: String, _ unitLabel: String, _ value: (DynoPoint) -> Double) -> DynoResult.Chart {
            // The rpm axis runs from and to a round 500, around every pull that is shown.
            let all = visible.flatMap(\.points).map(\.rpm)
            var low = 0.0, high = 8000.0
            if let lowest = all.min(), let highest = all.max(), highest > lowest {
                low = (lowest / 500).rounded(.down) * 500
                high = (highest / 500).rounded(.up) * 500
            }
            let series = visible.map { run -> DynoResult.Chart.Series in
                var points: [Double] = []
                points.reserveCapacity(run.points.count * 2)
                for point in run.points {
                    let y = value(point)
                    if point.rpm.isFinite, y.isFinite { points += [point.rpm, y] }
                }
                return .init(id: run.id, name: "Pull \(run.id)", color: colors[run.id] ?? 0, points: points)
            }
            return .init(title: title, unit: unitLabel, low: low, high: high, series: series)
        }

        return DynoResult(
            verdict: .init(quality: name(quality.verdict), title: title, issues: quality.issues),
            tiles: tiles, runs: rows,
            charts: [chart("Wheel power", unit.label) { unit.convert($0.wheelPower) },
                     chart("Torque at the wheels, at engine speed", "Nm") { $0.torque }])
    }

    /// A number without its fraction, as the Mac's `Int(value)` writes it. A dash for a value that is
    /// not a number, which `Int` cannot take.
    static func dynoWhole(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 1e15 else { return "–" }
        return String(Int(value))
    }

    // MARK: Numbers in the car's fields

    /// The car's details as their fields show them, with the decimals the Mac's fields have.
    static func dynoCar(_ settings: DynoSettings) -> DynoState.Car {
        DynoState.Car(massKg: dynoText(settings.massKg, decimals: 0),
                      tireWidthMM: dynoText(settings.tireWidthMM, decimals: nil),
                      tireAspect: dynoText(settings.tireAspect, decimals: nil),
                      rimInches: dynoText(settings.rimInches, decimals: nil),
                      finalDrive: dynoText(settings.finalDrive, decimals: 3),
                      dragCoefficient: dynoText(settings.dragCoefficient, decimals: 2),
                      frontalAreaM2: dynoText(settings.frontalAreaM2, decimals: 2),
                      drivetrainLoss: dynoText(settings.drivetrainLoss * 100, decimals: 0))
    }

    /// Writes and reads numbers the way this computer does. With `decimals` a number always has that
    /// many; without, as many as it needs, up to three. (The Mac's fields: `.number.precision(.fractionLength(decimals))`
    /// and `.number`.)
    static func dynoFormatter(decimals: Int?) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = decimals ?? 0
        formatter.maximumFractionDigits = decimals ?? 3
        return formatter
    }

    static func dynoText(_ value: Double, decimals: Int?) -> String {
        dynoFormatter(decimals: decimals).string(from: NSNumber(value: value)) ?? String(value)
    }

    /// The number a person typed, or nil when it is not one.
    static func dynoNumber(_ text: String) -> Double? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        let formatter = dynoFormatter(decimals: nil)
        formatter.isLenient = true
        let number = formatter.number(from: typed)?.doubleValue ?? Double(typed)
        guard let number, number.isFinite else { return nil }
        return number
    }
}

/// What the dyno keeps while it is on screen. On the Mac this is the view's own state (`@State` in
/// `DynoView`), which starts again with every visit; here `appear()` does that. The car's details
/// and the unit for power are saved under the same names as on the Mac ("dynoSettings", "dynoUnit").
@MainActor
final class DynoSession {
    struct LogFile {
        let url: URL
        let path: String
        let date: Date
    }

    private let model: AppModel
    /// Called after a change to anything the page shows.
    var changed: () -> Void = {}

    private(set) var visit = 0
    private(set) var files: [LogFile] = []
    private(set) var selectedURL: URL?
    private(set) var isLoading = false
    private(set) var runs: [DynoRun] = []
    private(set) var shownRuns: Set<Int> = []
    private(set) var settings = DynoSession.savedSettings()
    private(set) var autoGear = true
    private(set) var unit = DynoSession.savedUnit()
    private var log: RecordedLog?
    private var loading: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    /// One way to write a file's place, so that the same file from two sources compares as equal.
    static func path(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    static func savedSettings() -> DynoSettings {
        UserDefaults.standard.data(forKey: "dynoSettings").flatMap { try? JSONDecoder().decode(DynoSettings.self, from: $0) } ?? DynoSettings()
    }

    static func savedUnit() -> PowerUnit {
        UserDefaults.standard.string(forKey: "dynoUnit").flatMap(PowerUnit.init(rawValue:)) ?? .ps
    }

    /// The dyno comes on screen: everything starts as on the Mac, with the log that is playing back
    /// or else the newest recording. Returns the number of this visit.
    func appear() -> Int {
        visit += 1
        loading?.cancel()
        settings = DynoSession.savedSettings()
        unit = DynoSession.savedUnit()
        autoGear = true
        log = nil
        runs = []
        shownRuns = []
        selectedURL = nil
        isLoading = false
        reloadFiles()
        if let url = model.playback?.url ?? files.first?.url { select(url) } else { changed() }
        return visit
    }

    /// The dyno leaves the screen: the log it read is let go.
    func disappear() {
        loading?.cancel()
        loading = nil
        log = nil
        runs = []
        shownRuns = []
        selectedURL = nil
        isLoading = false
    }

    private func reloadFiles() {
        let folder = model.logsFolder
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        files = names.filter { ($0 as NSString).pathExtension.lowercased() == "csv" }.map { name in
            let url = folder.appendingPathComponent(name)
            let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            return LogFile(url: url, path: DynoSession.path(url), date: date ?? .distantPast)
        }
        .sorted { $0.date > $1.date }
    }

    /// Chooses a log and reads it. The pulls of the log before stay on screen until the new one is read.
    func select(_ url: URL?) {
        guard url.map(DynoSession.path) != selectedURL.map(DynoSession.path) else { return }
        selectedURL = url
        loading?.cancel()
        guard let url else {
            log = nil
            runs = []
            isLoading = false
            changed()
            return
        }
        isLoading = true
        changed()
        loading = Task { [weak self] in
            let read = try? await Task.detached { try RecordedLog.load(url) }.value
            guard let self, !Task.isCancelled else { return }
            self.log = read
            self.isLoading = false
            self.recompute()
            self.shownRuns = Set(self.runs.map(\.id))
            self.changed()
        }
    }

    /// Changes the car's details, saves them and works the pulls out again.
    func change(_ edit: (inout DynoSettings) -> Void) {
        var edited = settings
        edit(&edited)
        guard edited != settings else { return }
        settings = edited
        if let data = try? JSONEncoder().encode(edited) { UserDefaults.standard.set(data, forKey: "dynoSettings") }
        recompute()
        changed()
    }

    func setAutoGear(_ on: Bool) {
        guard on != autoGear else { return }
        autoGear = on
        recompute()
        changed()
    }

    func setUnit(_ new: PowerUnit) {
        guard new != unit else { return }
        unit = new
        UserDefaults.standard.set(new.rawValue, forKey: "dynoUnit")
        changed()
    }

    func setShown(_ id: Int, _ shown: Bool) {
        guard runs.contains(where: { $0.id == id }) else { return }
        if shown { shownRuns.insert(id) } else { shownRuns.remove(id) }
        changed()
    }

    private func recompute() {
        guard let log else { runs = []; return }
        var used = settings
        if autoGear { used.gear = nil }
        runs = VirtualDyno.runs(log: log, settings: used)
        if shownRuns.isEmpty || !shownRuns.isSubset(of: Set(runs.map(\.id))) { shownRuns = Set(runs.map(\.id)) }
    }
}
#endif
