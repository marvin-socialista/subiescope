import Foundation
import Observation
import SSMKit

/// The ROM editor: the ROM that is open and everything a screen shows of it and does with it. It is
/// laid out the way RomRaider is: a tree of the ROM's maps by category, and a workspace of the maps
/// that were opened from it, each a table of coloured numbers.
///
/// Both fronts show this one object. The Mac's views (Views/ROMView.swift and the files next to it)
/// draw what it says, and the Windows page is to do the same through the bridge. So nothing in here
/// knows about a window: what it needs of the desktop (a file to open, where to save, a question)
/// goes through `Desktop`.
///
/// All of it is work on a file in memory. Reading a ROM from the car is `AppModel+ROM`'s, and
/// nothing here ever writes to the car.
@MainActor
@Observable
final class ROMEditor {
    /// The app's one editor. It lives as long as the app, so a ROM stays open while the person
    /// looks at another part of it.
    static let shared = ROMEditor()

    // MARK: The ROM

    private(set) var rom: ROMImage?
    private(set) var fileName = ""
    /// The ROM as it was opened or read from the car. "Changed" is measured from here.
    private(set) var opened: ROMImage?
    /// The ROM as it is on disk, or nil for one that was never saved. "Edited" means not this.
    private(set) var saved: ROMImage?
    /// The ROM is not what is on disk: it was edited since, or it came from the car and was never saved.
    private(set) var isEdited = false
    /// Goes up with every ROM that is put in the editor, for a screen that keeps fields of its own.
    private(set) var session = 0
    /// What happened last ("Saved to edited.bin."), for the status bar.
    private(set) var status: String?
    /// The last thing that happened went wrong: the status bar shows it as a warning.
    private(set) var statusIsProblem = false

    var isOpen: Bool { rom != nil }

    // MARK: Definitions

    private(set) var defs: ROMDefinitionSet?
    /// Where the definitions came from ("from the SubieScope repository", or a file's name).
    private(set) var defsSource = ""
    private(set) var loadingDefs = false
    /// The definition in use for this ROM.
    private(set) var matched: ROMDefinition?
    /// The definition's internal ID is in the ROM. False for one the person chose from the suggestions.
    private(set) var matchIsExact = false
    /// Definitions that are close, for a ROM none matches exactly. Never used without asking.
    private(set) var recommendations: [ROMDefinition] = []
    /// Every table of the definition in use, with what its base definitions fill in.
    private(set) var tableDefs: [ROMTableDef] = []
    /// What went wrong with getting or reading the definitions.
    private(set) var definitionsError: String?

    /// The maps the tree lists: the tables of numbers (those with an address and a numeric type), and
    /// RomRaider's switches, which are shown for what they are but cannot be changed here.
    var mapDefs: [ROMTableDef] { tableDefs.filter { $0.isEditable || $0.isSwitch } }

    // MARK: Checksums

    enum ChecksumState: String {
        /// No checksum layout is known for a ROM of this size.
        case unknown
        /// The ROM has its checksums switched off.
        case disabled
        case ok
        /// They do not add up. The screens offer to correct them.
        case mismatch
    }

    private(set) var checksumReport: SubaruChecksum.Report?

    // MARK: Undo, and what changed since the ROM was opened

    private(set) var history = ROMEditHistory()
    /// The ROM as it was opened against the ROM now.
    private(set) var changes: ROMComparison?
    /// How many cells and axis values of each map are not what they were, by the map's name.
    private(set) var changedCounts: [String: Int] = [:]
    /// The Changes panel: every change, map by map.
    private(set) var changeGroups: [ChangeGroup] = []
    /// How many more maps changed than `changeGroups` lists.
    private(set) var changeGroupsMore = 0
    /// The Changes panel is on show next to the maps.
    var showsChanges = false

    // MARK: Comparing with another ROM file

    private(set) var other: ROMImage?
    private(set) var otherName = ""
    /// This ROM against the other one.
    private(set) var comparison: ROMComparison?
    /// Why the file that was chosen could not be compared.
    private(set) var compareError: String?
    /// How many cells and axis values of each map differ from the other ROM, by the map's name.
    private(set) var differentCounts: [String: Int] = [:]

    var isComparing: Bool { other != nil }

    // MARK: The tree

    /// Which maps the tree lists.
    enum Listing: String {
        case all
        /// Only the maps that changed since the ROM was opened.
        case changed
        /// Only the maps that differ from the other ROM. For while one is compared.
        case different
    }

    /// What is typed in the tree's filter field. Maps and categories whose name holds it stay.
    var filterText = ""
    private(set) var listing: Listing = .all
    /// The categories that are folded open while the tree lists every map.
    private(set) var expanded: Set<String> = []
    /// The categories that were folded shut while the tree lists only some maps (it opens them all then).
    private(set) var collapsedWhileNarrowed: Set<String> = []

    // MARK: The workspace

    /// What the workspace shows: the ROM itself, or the maps that are open.
    enum Focus: Equatable {
        /// The header card of the tree is selected: file, definitions, checksums, read from car, bytes.
        case overview
        /// This map is the selected one. The open maps are stacked in the workspace.
        case map(String)
    }

    private(set) var focus: Focus = .overview
    /// The names of the maps that are open, in the order of their windows from the top.
    private(set) var openMaps: [String] = []
    /// Goes up whenever the selected map is to be brought into view: it was opened from the tree or
    /// from the Changes panel. A click inside a map selects it without moving anything.
    private(set) var revealCount = 0
    /// Each open map as the ROM holds it now, as it was opened, and as the other ROM holds it.
    private(set) var tables: [String: ROMTable] = [:]
    private(set) var openedTables: [String: ROMTable] = [:]
    private(set) var otherTables: [String: ROMTable] = [:]
    /// Why an open map could not be read from the ROM.
    private(set) var tableErrors: [String: String] = [:]
    private(set) var views: [String: MapView] = [:]

    /// What the cells of a map show.
    enum Shows: String, CaseIterable {
        case now, asOpened, difference

        var title: String {
            switch self {
            case .now: return "Now"
            case .asOpened: return "As opened"
            case .difference: return "Difference"
            }
        }
    }

    /// What the cells of a map show while another ROM is compared.
    enum CompareShows: String, CaseIterable {
        case both, thisROM, otherROM, difference

        var title: String {
            switch self {
            case .both: return "Both"
            case .thisROM: return "This ROM"
            case .otherROM: return "Other ROM"
            case .difference: return "Difference"
            }
        }
    }

    /// How one open map is looked at. Every map keeps its own.
    struct MapView: Equatable {
        var shows: Shows = .now
        var compareShows: CompareShows = .both
        /// The 3D view, in place of the table.
        var surface = false
        /// The 3D view's angles in degrees, and how tall it draws the highest value.
        var turn = MapView.defaultTurn
        var tilt = MapView.defaultTilt
        var height = MapView.defaultHeight
        /// The 3D view writes each number on its tile.
        var numbers = true

        static let defaultTurn = -32.0, defaultTilt = 56.0, defaultHeight = 6.0
        static let turnRange = -70.0...70.0, tiltRange = 30.0...75.0, heightRange = 2.0...10.0
    }

    // MARK: The selected cells

    /// The cells of the selected map that the toolbar's buttons act on.
    private(set) var selection: Set<ROMTable.Cell> = []
    /// The cell the strip under the map describes. With Shift it is the corner that moves.
    private(set) var cursor: ROMTable.Cell?
    /// The corner of a block of cells that stays where it is.
    private(set) var anchor: ROMTable.Cell?

    // MARK: The toolbar's fields

    /// The step of the Fine and of the Coarse buttons, as typed. A map brings its own when it is selected.
    var fineStepText = ""
    var coarseStepText = ""
    /// The Value field, for Set and Mul.
    var valueText = ""
    /// What the editor itself last put in the Value field. Something a person typed is not replaced.
    @ObservationIgnored private var filledValueText: String?

    enum StepSize { case fine, coarse }

    // MARK: Bytes

    /// Where the Bytes card starts.
    private(set) var viewOffset = 0
    /// Why the last "Show" or "Apply" of the Bytes card did nothing.
    private(set) var bytesError: String?

    /// A map can differ in thousands of cells. The first ones tell enough, and the map itself shows the rest.
    static let lineLimit = 100
    /// How many maps the Changes panel lists in full.
    static let changeGroupLimit = 40

    // MARK: - Opening and saving

    #if os(Windows)
    static let romFilter = ["ECU ROM files (*.bin)", "*.bin"]
    #else
    /// A Mac's dialog offers every file: a ROM is not always called .bin.
    static let romFilter: [String] = []
    #endif

    /// Asks for a ROM file and opens it.
    func openROM() {
        guard mayReplaceROM(doing: "Open Another ROM"),
              let url = Desktop.chooseFileToOpen(filter: Self.romFilter) else { return }
        open(url)
    }

    func open(_ url: URL) {
        do {
            let loaded = try ROMImage(contentsOf: url)
            load(loaded, name: url.lastPathComponent, saved: loaded, status: nil)
        } catch {
            report("Could not open the file: \(error.localizedDescription)", problem: true)
        }
    }

    /// The toolbar's "Read from Car". With a car that can be read it says what the read needs and
    /// asks first, because one click should not start minutes of work on an ECU. Without one it
    /// shows the ROM's overview, where the Read from car card says what is missing.
    func askToReadFromCar(_ model: AppModel) {
        guard model.canReadROMFromCar else {
            if isOpen { showOverview() }
            return
        }
        let answer = Desktop.alert(
            "Read the ROM from the car?",
            "Ignition ON, engine OFF, a healthy battery, and leave the car alone until it finishes. It takes several minutes. It reads only, and never writes anything back to the car.",
            buttons: ["Cancel", "Read the ROM"])
        guard answer == 1 else { return }
        Task { await readFromCar(model) }
    }

    /// Reads the ROM from the car and opens it here. The reading itself is `AppModel+ROM`'s.
    func readFromCar(_ model: AppModel) async {
        guard model.canReadROMFromCar, mayReplaceROM(doing: "Read the ROM from the Car") else { return }
        if let loaded = await model.readROMFromCar() { loadReadROM(loaded) }
    }

    /// A ROM read from the car goes straight into the editor, as if it had been opened from a file.
    /// It is on no disk yet, so it counts as not saved.
    func loadReadROM(_ loaded: ROMImage) {
        let id = loaded.calibrationID() ?? "car"
        load(loaded, name: "\(id)-read.bin", saved: nil,
             status: "Read from the car. Use Save As to keep this file before you edit it.")
    }

    /// With work in the editor that is on no disk, asks before another ROM takes its place.
    private func mayReplaceROM(doing action: String) -> Bool {
        guard rom != nil, isEdited else { return true }
        let what = saved == nil ? "The ROM that is open was never saved." : "The ROM that is open has edits that are not saved."
        return Desktop.alert("This ROM is not saved", "\(what) Another ROM takes its place, and what is not saved is lost.",
                             buttons: ["Cancel", action]) == 1
    }

    private func load(_ loaded: ROMImage, name: String, saved: ROMImage?, status: String?) {
        rom = loaded
        fileName = name
        opened = loaded
        self.saved = saved
        isEdited = saved == nil
        self.status = status
        statusIsProblem = false
        bytesError = nil
        viewOffset = 0
        // Another ROM: nothing to undo yet, nothing changed yet, nothing to compare with.
        history = ROMEditHistory()
        other = nil
        otherName = ""
        compareError = nil
        showsChanges = false
        filterText = ""
        listing = .all
        expanded = []
        collapsedWhileNarrowed = []
        closeEveryMap()
        session += 1
        refreshChecksum()
        if defs == nil {
            refreshChanges()
            Task { await autoLoadDefinitions() }
        } else {
            matchDefinitions()
        }
    }

    /// The name the save dialog starts with: never the name of the file that was opened.
    var suggestedSaveName: String {
        let base = (fileName as NSString).deletingPathExtension
        return base.isEmpty ? "edited.bin" : "\(base)-edited.bin"
    }

    /// Asks where to save the ROM, and saves it there.
    func saveAs() {
        guard rom != nil, let url = Desktop.chooseSaveLocation(suggestedName: suggestedSaveName) else { return }
        save(to: url)
    }

    func save(to url: URL) {
        guard let rom else { return }
        do {
            try rom.write(to: url)
            saved = rom
            isEdited = false
            let checksums = checksumState == .mismatch ? " Its checksums still need correcting." : ""
            report("Saved to \(url.lastPathComponent).\(checksums)", problem: checksumState == .mismatch)
        } catch {
            report("Could not save: \(error.localizedDescription)", problem: true)
        }
    }

    private func report(_ text: String?, problem: Bool = false) {
        status = text
        statusIsProblem = problem && text != nil
    }

    // MARK: - Definitions

    /// Downloads RomRaider's ecu_defs.xml from the SubieScope repository, or takes the copy that is
    /// there from an earlier time, and looks this ROM up in it.
    func autoLoadDefinitions() async {
        guard !loadingDefs else { return }
        loadingDefs = true
        definitionsError = nil
        defer { loadingDefs = false }
        do {
            defs = try await ROMDefinitionsStore.loadOrDownload()
            defsSource = "from the SubieScope repository"
            matchDefinitions()
        } catch {
            definitionsError = error.localizedDescription + " You can still choose a definitions file yourself."
        }
    }

    /// Asks for a RomRaider definitions file and uses it.
    func openDefinitions() {
        guard let url = Desktop.chooseFileToOpen(filter: ["RomRaider definitions (*.xml)", "*.xml"]) else { return }
        openDefinitions(url)
    }

    func openDefinitions(_ url: URL) {
        do {
            defs = try ROMDefinitionParser.load(url: url)
            defsSource = url.lastPathComponent
            definitionsError = nil
            matchDefinitions()
        } catch {
            definitionsError = error.localizedDescription
        }
    }

    private func matchDefinitions() {
        closeEveryMap()
        guard let defs, let rom else {
            matched = nil; matchIsExact = false; tableDefs = []; recommendations = []
            refreshChanges()
            return
        }
        // Only a definition whose internal ID is in the ROM is used without asking. Others are suggested.
        matched = defs.definition(matching: rom)
        matchIsExact = matched != nil
        if let matched {
            tableDefs = defs.resolvedTables(forXmlID: matched.identity.xmlID)
            recommendations = []
        } else {
            tableDefs = []
            recommendations = defs.recommendations(for: rom)
        }
        refreshChanges()
    }

    /// Takes one of the suggested definitions, which the person chose.
    func applyRecommendation(_ xmlID: String) {
        guard let defs, let definition = recommendations.first(where: { $0.identity.xmlID == xmlID }) else { return }
        closeEveryMap()
        matched = definition
        matchIsExact = false
        tableDefs = defs.resolvedTables(forXmlID: definition.identity.xmlID)
        recommendations = []
        refreshChanges()
        report("Using definition \(definition.identity.xmlID). You chose this; it is not an exact match for the ROM.")
    }

    /// "AZ1G201G · ECU 6644D87207"
    static func label(of definition: ROMDefinition) -> String {
        definition.identity.xmlID + (definition.identity.ecuID.map { " · ECU \($0)" } ?? "")
    }

    /// How the definitions stand, for the Definitions card.
    enum DefinitionsState: String {
        /// There are no definitions yet.
        case none
        case matched
        /// No exact match, and some that are close.
        case suggestions
        /// Nothing in them for this ROM.
        case unknown
    }

    var definitionsState: DefinitionsState {
        if defs == nil { return .none }
        if matched != nil { return .matched }
        return recommendations.isEmpty ? .unknown : .suggestions
    }

    /// One sentence on how the definitions stand.
    var definitionsText: String {
        switch definitionsState {
        case .none:
            return loadingDefs ? "Getting the definitions…" : "No definitions yet, so this ROM's maps cannot be shown by name."
        case .matched:
            let id = matched?.identity.xmlID ?? ""
            let groups = Set(mapDefs.map(Self.category)).count
            let maps = "\(Self.counted(mapDefs.count, "map")) in \(Self.counted(groups, "group"))"
            return matchIsExact ? "Matched \(id) exactly: \(maps)" : "Using \(id), which you chose: \(maps)"
        case .suggestions:
            return "No exact match for this ROM's internal ID. These are the closest. Pick one only if you are sure it is right."
        case .unknown:
            return "These definitions have no entry matching this ROM's internal ID."
        }
    }

    // MARK: - What the ROM is

    /// The calibration ID printed in the ROM ("AZ1G500F").
    var calibrationID: String? { rom?.calibrationID() }

    /// What is known about the car this calibration is for.
    var knownECU: KnownECU? {
        if let id = calibrationID, let ecu = KnownECU.library.values.joined().first(where: { $0.calID == id }) { return ecu }
        return matched?.identity.ecuID.flatMap { KnownECU.lookup($0).first }
    }

    /// The line under the file's name: "AZ1G500F · 2009 Impreza STi, JDM, manual".
    var identityText: String {
        let parts = [calibrationID, knownECU?.carName].compactMap { $0 }
        return parts.isEmpty ? "Not a Subaru ROM that SubieScope knows" : parts.joined(separator: " · ")
    }

    /// Whether what is in the editor is also on disk, in a few words.
    var savedText: String {
        guard rom != nil else { return "" }
        if saved == nil { return "Read from the car, not saved yet" }
        if isEdited { return "Edited, not saved" }
        return rom == opened ? "Not edited" : "Edited and saved"
    }

    /// "1 MB · Denso SH7058", or the number of bytes for a file that is no whole ROM.
    var sizeText: String {
        guard let rom else { return "" }
        guard let size = rom.size else { return "\(rom.byteCount) bytes, not a standard Subaru ROM size" }
        return [size.label, processorText].compactMap { $0 }.joined(separator: " · ")
    }

    private var processorText: String? {
        if let processor = knownECU?.processor { return "Denso \(processor)" }
        switch rom?.size {
        case .k512: return "Denso SH7055"
        case .m1: return "Denso SH7058"
        default: return nil
        }
    }

    /// One row of the File card.
    struct FileRow: Identifiable, Equatable {
        var id: String { label }
        let label: String
        let value: String
        /// A code, shown in the font of the numbers.
        let isCode: Bool
    }

    /// The File card.
    var fileRows: [FileRow] {
        guard let rom else { return [] }
        var rows = [FileRow(label: "Name", value: fileName, isCode: false)]
        if let car = knownECU?.carName { rows.append(FileRow(label: "Car", value: car, isCode: false)) }
        rows.append(FileRow(label: "Calibration ID", value: calibrationID ?? "unknown (may not be a Subaru 32-bit ROM)", isCode: calibrationID != nil))
        if let ecuID = matched?.identity.ecuID ?? knownECU?.ecuID { rows.append(FileRow(label: "ECU ID", value: ecuID, isCode: true)) }
        rows.append(FileRow(label: "Size", value: "\(rom.byteCount) bytes" + (rom.size == nil ? " · not a standard Subaru ROM size" : " · \(sizeText)"), isCode: false))
        rows.append(FileRow(label: "Fingerprint", value: rom.quickFingerprint, isCode: true))
        return rows
    }

    /// The status bar's word on the definitions: "Definitions: AZ1G500F, exact match".
    var definitionsSummary: String {
        switch definitionsState {
        case .none: return loadingDefs ? "Getting the definitions…" : "No definitions yet"
        case .matched: return "Definitions: \(matched?.identity.xmlID ?? ""), \(matchIsExact ? "exact match" : "chosen by you")"
        case .suggestions, .unknown: return "Definitions: none for this ROM"
        }
    }

    // MARK: - Checksums

    var checksumState: ChecksumState {
        guard let report = checksumReport else { return .unknown }
        if report.allDisabled { return .disabled }
        return report.ok ? .ok : .mismatch
    }

    /// How the checksums stand, in a few words for the toolbar.
    var checksumShortText: String {
        switch checksumState {
        case .unknown: return "Checksums not known for this ROM"
        case .disabled: return "Checksums are switched off"
        case .ok: return "All checksums match"
        case .mismatch: return "Checksums need correcting"
        }
    }

    /// The same in a whole sentence, for the Checksums card.
    var checksumText: String {
        guard let report = checksumReport else {
            return "No checksum layout is known for this ROM size, so SubieScope can't check or correct it."
        }
        let active = report.records.filter { !$0.isBlank }.count
        switch checksumState {
        case .disabled: return "This ROM has its checksums disabled."
        case .ok: return "All checksums match (\(Self.counted(active, "active region")))"
        default: return "\(report.mismatchCount) of \(Self.counted(active, "checksum region")) do not match."
        }
    }

    private func refreshChecksum() {
        // No layout for this size and a table that does not fit come to the same: nothing to check.
        checksumReport = rom.flatMap { try? SubaruChecksum.verifyPetrol($0) }
    }

    func correctChecksums() {
        guard let rom else { return }
        do {
            guard let (fixed, _) = try SubaruChecksum.correctPetrol(rom), fixed != rom else { return }
            apply(fixed, as: "the checksum correction")
            report("Checksums corrected. Use Save As to write the new ROM.")
        } catch {
            report("Could not correct the checksums: \(error.localizedDescription)", problem: true)
        }
    }

    // MARK: - The tree

    /// One map in the tree.
    struct TreeMap: Identifiable, Equatable {
        /// The map's name in the definition, which is what every action takes.
        let id: String
        /// The name as shown.
        let title: String
        /// "1D", "2D" or "3D", RomRaider's word for a number, a row and a grid, or "SW" for a switch.
        let dimension: String
        /// How many of its cells changed since the ROM was opened.
        let changed: Int
        /// How many of its cells differ from the other ROM.
        let different: Int
        /// It has a window in the workspace.
        let isOpen: Bool
        let isSelected: Bool
    }

    /// One category of the tree, with the maps the listing and the filter leave in it.
    struct TreeCategory: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let maps: [TreeMap]
        /// "6", or "2 of 6" while only some are listed.
        let countText: String
        /// One of its maps changed since the ROM was opened.
        let hasChanges: Bool
        let isExpanded: Bool
    }

    static func category(of def: ROMTableDef) -> String {
        def.category.isEmpty ? "Other" : def.category
    }

    /// RomRaider's word for a map's shape, as the tree's small tag shows it: "1D", "2D", "3D", and
    /// "SW" for a switch. A table that says nothing is one number.
    static func dimension(of def: ROMTableDef) -> String {
        switch def.dimension {
        case .switch: return "SW"
        case .other: return ROMTableDef.Dimension.oneD.rawValue
        default: return def.dimension.rawValue
        }
    }

    /// The tree lists only some maps: by the Changed or Different switch, or by the filter.
    var treeIsNarrowed: Bool { listing != .all || !filterText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The tree as it is shown: the categories by name, and the maps by name within one.
    var tree: [TreeCategory] {
        let needle = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        let narrowed = treeIsNarrowed
        let selected: String? = { if case .map(let name) = focus { return name } else { return nil } }()
        let byCategory = Dictionary(grouping: mapDefs, by: Self.category)
        return byCategory.keys.sorted().compactMap { category in
            let all = (byCategory[category] ?? []).sorted { $0.name < $1.name }
            let categoryMatches = !needle.isEmpty && category.lowercased().contains(needle)
            let kept = all.filter { def in
                switch listing {
                case .all: break
                case .changed: if changedCounts[def.name] == nil { return false }
                case .different: if differentCounts[def.name] == nil { return false }
                }
                return needle.isEmpty || categoryMatches || def.name.lowercased().contains(needle)
            }
            guard !kept.isEmpty else { return nil }
            let maps = kept.map { def in
                TreeMap(id: def.name, title: def.name.trimmingCharacters(in: .whitespaces), dimension: Self.dimension(of: def),
                        changed: changedCounts[def.name] ?? 0, different: differentCounts[def.name] ?? 0,
                        isOpen: openMaps.contains(def.name), isSelected: def.name == selected)
            }
            return TreeCategory(name: category, maps: maps,
                                countText: narrowed ? "\(kept.count) of \(all.count)" : "\(all.count)",
                                hasChanges: all.contains { changedCounts[$0.name] != nil },
                                isExpanded: narrowed ? !collapsedWhileNarrowed.contains(category) : expanded.contains(category))
        }
    }

    var mapCount: Int { mapDefs.count }
    /// How many maps changed since the ROM was opened, and how many differ from the other ROM.
    var changedMapCount: Int { changedCounts.count }
    var differentMapCount: Int { differentCounts.count }

    /// Folds a category open or shut.
    func toggleCategory(_ name: String) {
        if treeIsNarrowed {
            collapsedWhileNarrowed.formSymmetricDifference([name])
        } else {
            expanded.formSymmetricDifference([name])
        }
    }

    /// Lists every map, or only those that changed. While another ROM is compared, "only some" is
    /// the maps that differ from it.
    func list(_ listing: Listing) {
        switch listing {
        case .all: self.listing = .all
        case .changed, .different: self.listing = isComparing ? .different : .changed
        }
        collapsedWhileNarrowed = []
    }

    /// What the tree says under a list of only some maps.
    var treeNote: String? {
        switch listing {
        case .all: return nil
        case .changed:
            return changedCounts.isEmpty ? "No map has changed since this ROM was opened. Choose All to see every map."
                : "Maps you have not changed are hidden. Choose All to see every map again."
        case .different:
            if let otherBytes = comparison?.otherBytesText { return otherBytes }
            return differentCounts.isEmpty ? "No map is different in the other ROM. Choose All to see every map."
                : "Maps that are the same in both ROMs are hidden. Choose All to see every map again."
        }
    }

    // MARK: - The workspace

    /// The map that is selected, or nil while the workspace shows the ROM itself.
    var selectedMap: String? {
        if case .map(let name) = focus { return name }
        return nil
    }

    /// Shows the ROM itself in the workspace. The maps that are open stay open.
    func showOverview() {
        focus = .overview
        clearSelection()
    }

    /// Opens a map in the workspace, on top of the ones that are open, and selects it. A map that
    /// is open already is only selected.
    func openMap(_ name: String) {
        guard mapDefs.contains(where: { $0.name == name }) else { return }
        if !openMaps.contains(name) {
            openMaps.insert(name, at: 0)
            readTables(of: name)
        }
        select(map: name)
        revealCount += 1
    }

    /// Selects a map that is open, where it is in the workspace.
    func selectMap(_ name: String) {
        guard openMaps.contains(name) else { return }
        select(map: name)
    }

    /// Opens a map and selects one of its cells: a line of the Changes panel was clicked.
    func openMap(_ name: String, at cell: ROMTable.Cell) {
        openMap(name)
        guard selectedMap == name else { return }
        setSurface(false, for: name)
        selectCell(cell, in: name)
    }

    func closeMap(_ name: String) {
        guard let index = openMaps.firstIndex(of: name) else { return }
        openMaps.remove(at: index)
        tables[name] = nil; openedTables[name] = nil; otherTables[name] = nil
        tableErrors[name] = nil; views[name] = nil
        guard selectedMap == name else { return }
        clearSelection()
        // The map that takes its place in the stack is the selected one now.
        if openMaps.isEmpty { focus = .overview } else { select(map: openMaps[min(index, openMaps.count - 1)]) }
    }

    private func closeEveryMap() {
        openMaps = []
        tables = [:]; openedTables = [:]; otherTables = [:]; tableErrors = [:]; views = [:]
        focus = .overview
        clearSelection()
    }

    private func select(map name: String) {
        guard focus != .map(name) else { return }
        focus = .map(name)
        clearSelection()
        // The map brings RomRaider's step sizes for its kind of number.
        if let scaling = tables[name]?.scaling {
            fineStepText = Self.plain(scaling.fineStep)
            coarseStepText = Self.plain(scaling.coarseStep)
        }
    }

    /// Reads an open map from the ROM as it is now, as it was opened, and from the other ROM.
    /// A switch has no table of numbers to read: see `switchLook`.
    private func readTables(of name: String) {
        guard let rom, let def = tableDefs.first(where: { $0.name == name }), !def.isSwitch else { return }
        let scalings = defs?.scalings ?? [:]
        do {
            tables[name] = try ROMTable.read(rom, def: def, scalings: scalings)
            tableErrors[name] = nil
        } catch {
            tables[name] = nil
            tableErrors[name] = error.localizedDescription
        }
        openedTables[name] = opened.flatMap { try? ROMTable.read($0, def: def, scalings: scalings) }
        otherTables[name] = other.flatMap { try? ROMTable.read($0, def: def, scalings: scalings) }
    }

    func view(of name: String) -> MapView { views[name] ?? MapView() }

    private func updateView(of name: String, _ change: (inout MapView) -> Void) {
        guard openMaps.contains(name) else { return }
        var view = self.view(of: name)
        change(&view)
        views[name] = view
    }

    func show(_ shows: Shows, in name: String) { updateView(of: name) { $0.shows = shows } }
    func show(_ shows: CompareShows, in name: String) { updateView(of: name) { $0.compareShows = shows } }
    func setSurface(_ on: Bool, for name: String) { updateView(of: name) { $0.surface = on && self.canShowSurface(name) } }
    func setNumbers(_ on: Bool, for name: String) { updateView(of: name) { $0.numbers = on } }
    func resetView(of name: String) {
        updateView(of: name) { $0.turn = MapView.defaultTurn; $0.tilt = MapView.defaultTilt; $0.height = MapView.defaultHeight }
    }

    /// Turns and tilts the 3D view. Both stay within what still reads as a map.
    func setAngles(turn: Double? = nil, tilt: Double? = nil, for name: String) {
        updateView(of: name) {
            if let turn { $0.turn = min(max(turn, MapView.turnRange.lowerBound), MapView.turnRange.upperBound) }
            if let tilt { $0.tilt = min(max(tilt, MapView.tiltRange.lowerBound), MapView.tiltRange.upperBound) }
        }
    }

    func setHeight(_ height: Double, for name: String) {
        updateView(of: name) { $0.height = min(max(height, MapView.heightRange.lowerBound), MapView.heightRange.upperBound) }
    }

    /// A map with rows and columns has a surface to look at. A row of numbers and a single number have none.
    func canShowSurface(_ name: String) -> Bool {
        guard let table = tables[name] else { return false }
        return table.rows > 1 && table.columns > 1
    }

    /// The toolbar's 3D button: the selected map as a surface, or as a table again.
    func toggleSurface() {
        guard let name = selectedMap else { return }
        setSurface(!view(of: name).surface, for: name)
    }

    // MARK: - What a map looks like

    /// One cell as a screen draws it.
    struct CellLook: Equatable {
        enum Fill: Equatable {
            /// The cell's place on the map's heat scale.
            case heat(ROMHeatScale.Color)
            /// The Difference views: a cell that went up, one that went down, and one that is the same.
            case raised, lowered, plain
        }

        /// The ring around a cell that is not what it was, or not what the other ROM holds.
        enum Mark: String {
            case none, raised, lowered, different
        }

        let text: String
        /// The other ROM's number, under this ROM's, in a cell that differs.
        let below: String?
        let fill: Fill
        let mark: Mark
        /// What the cell says when it is pointed at: "Was 15.47 when this ROM was opened".
        let note: String?
        /// Where the cell's value lies between the lowest (0) and the highest (1) of the map: its height in 3D.
        let place: Double
    }

    /// One open map as a screen draws it.
    struct MapLook: Equatable {
        /// What stands under the map to say what the rings mean.
        enum Legend: String {
            case none
            /// Raised, and lowered since this ROM was opened.
            case changes
            /// Raised, lowered, and as opened.
            case difference
            /// This ROM on top, the other ROM below it.
            case compare
            /// Higher in this ROM, lower in this ROM, and the same in both.
            case compareDifference
        }

        let id: String
        let title: String
        let description: String
        let rows: Int
        let columns: Int
        /// "Requested Torque (raw ecu value)" above the columns and "Engine Speed (RPM)" beside the rows.
        let columnTitle: String?
        let rowTitle: String?
        /// What the numbers are: "Boost Target (psi relative sea level)".
        let valueTitle: String
        /// The labels above the columns and in front of the rows. Nil for a map without that axis.
        let columnLabels: [String]?
        let rowLabels: [String]?
        let cells: [[CellLook]]
        /// Every cell has room for two numbers: this ROM's and the other ROM's.
        let twoNumbers: Bool
        let legend: Legend
        /// "4 changed", or "6 cells different" while another ROM is compared.
        let badge: String?
        /// The definition has no formula from a value back to bytes, so the cells cannot be changed.
        let readOnly: Bool
        /// The lowest and the highest value on show, with the unit after the highest: "-4.83" and "19.34 psi".
        let lowText: String
        let highText: String
    }

    /// An open map as it is to be drawn, or nil for one that could not be read (see `tableErrors`).
    func look(of name: String) -> MapLook? {
        guard let table = tables[name] else { return nil }
        let view = self.view(of: name)
        let scaling = table.scaling
        let was = changedCells(of: name)
        let theirs = differentCells(of: name)
        let comparing = isComparing

        // Which numbers the cells show, and whether they show a difference in place of a number.
        var shown = table.values
        var showsDifference = false
        if !view.surface {
            if comparing {
                if view.compareShows == .otherROM, let other = otherTables[name], Self.sameShape(other, table) { shown = other.values }
                showsDifference = view.compareShows == .difference
            } else {
                if view.shows == .asOpened, let opened = openedTables[name], Self.sameShape(opened, table) { shown = opened.values }
                showsDifference = view.shows == .difference
            }
        }
        let twoNumbers = comparing && !view.surface && view.compareShows == .both
        let scale = ROMHeatScale(values: shown)

        var cells: [[CellLook]] = []
        for row in 0..<table.rows {
            var line: [CellLook] = []
            for column in 0..<table.columns {
                let cell = ROMTable.Cell(row: row, column: column)
                let now = table.values[row][column]
                let value = shown[row][column]
                // What the cell is held against: the other ROM while comparing, or else itself as opened.
                let against = comparing ? theirs[cell] : was[cell]
                var mark = CellLook.Mark.none
                var note: String?
                if let against {
                    if comparing {
                        mark = showsDifference ? (now > against ? .raised : .lowered) : .different
                        note = "This ROM \(scaling.text(now)), the other ROM \(scaling.text(against))"
                    } else {
                        mark = now > against ? .raised : .lowered
                        note = showsDifference ? "Was \(scaling.text(against)), now \(scaling.text(now))"
                            : "Was \(scaling.text(against)) when this ROM was opened"
                    }
                }
                let fill: CellLook.Fill
                let text: String
                if showsDifference {
                    fill = against == nil ? .plain : (mark == .raised ? .raised : .lowered)
                    text = against.map { scaling.signedText(now - $0) } ?? scaling.text(now)
                } else {
                    fill = .heat(scale.color(for: value))
                    text = scaling.text(value)
                }
                line.append(CellLook(text: text, below: twoNumbers ? against.map(scaling.text) : nil,
                                     fill: fill, mark: mark, note: note, place: scale.place(of: value)))
            }
            cells.append(line)
        }

        let units = scaling.units.trimmingCharacters(in: .whitespaces)
        let what = units.isEmpty ? table.title : units
        let count = comparing ? differentCounts[name] : changedCounts[name]
        let badge = count.map { comparing ? "\(Self.counted($0, "cell")) different" : "\($0) changed" }
        let legend: MapLook.Legend
        if comparing {
            legend = showsDifference ? .compareDifference : (theirs.isEmpty ? .none : .compare)
        } else {
            legend = showsDifference ? .difference : (was.isEmpty ? .none : .changes)
        }
        let shortUnits = scaling.shortUnits
        return MapLook(
            id: name, title: table.title, description: table.def.description,
            rows: table.rows, columns: table.columns,
            columnTitle: table.columnTitle, rowTitle: table.rowTitle,
            valueTitle: showsDifference ? "Difference in \(what)" : what,
            columnLabels: table.def.columnAxis == nil ? nil : Self.padded(table.columnLabels, to: table.columns),
            rowLabels: table.def.rowAxis == nil ? nil : Self.padded(table.rowLabels, to: table.rows),
            cells: cells, twoNumbers: twoNumbers, legend: legend, badge: badge,
            readOnly: !scaling.isWritable,
            lowText: scaling.text(scale.low),
            highText: scaling.text(scale.high) + (shortUnits.isEmpty ? "" : " \(shortUnits)"))
    }

    /// One open switch as a screen shows it. RomRaider's switches (a trouble code that is checked
    /// or not, for one) are no numbers: the ROM holds one of a few fixed sets of bytes. The editor
    /// says which, and does not change them.
    struct SwitchLook: Equatable {
        let id: String
        let title: String
        let description: String
        /// The position this ROM is in ("on", "off"), or nil when its bytes are none of the switch's.
        let state: String?
        /// The position it was in when the ROM was opened, when that is another one.
        let openedState: String?
        /// The position the other ROM is in, while one is compared and it is another one.
        let otherState: String?
    }

    /// An open switch as it is to be shown, or nil for a map that is a table of numbers.
    func switchLook(of name: String) -> SwitchLook? {
        guard let rom, let def = tableDefs.first(where: { $0.name == name }), def.isSwitch else { return nil }
        let state = def.switchState(in: rom)?.name
        let openedState = opened.flatMap { def.switchState(in: $0)?.name }
        let otherState = other.flatMap { def.switchState(in: $0)?.name }
        return SwitchLook(id: name, title: name.trimmingCharacters(in: .whitespaces), description: def.description, state: state,
                          openedState: opened != nil && openedState != state ? (openedState ?? "neither") : nil,
                          otherState: other != nil && otherState != state ? (otherState ?? "neither") : nil)
    }

    /// What each changed cell of a map held when the ROM was opened.
    private func changedCells(of name: String) -> [ROMTable.Cell: Double] {
        Self.cells(of: changes?.maps.first { $0.name == name }, \.first)
    }

    /// What the other ROM holds in each cell of a map that differs from this one.
    private func differentCells(of name: String) -> [ROMTable.Cell: Double] {
        Self.cells(of: comparison?.maps.first { $0.name == name }, \.second)
    }

    private static func cells(of map: ROMComparison.Map?, _ value: KeyPath<ROMComparison.Cell, Double>) -> [ROMTable.Cell: Double] {
        var result: [ROMTable.Cell: Double] = [:]
        for cell in map?.cells ?? [] { result[ROMTable.Cell(row: cell.row, column: cell.column)] = cell[keyPath: value] }
        return result
    }

    private static func sameShape(_ one: ROMTable, _ other: ROMTable) -> Bool {
        one.rows == other.rows && one.columns == other.columns
    }

    /// An axis can have fewer labels than the map has columns, when a definition does not fit.
    private static func padded(_ labels: [String], to count: Int) -> [String] {
        labels.count >= count ? Array(labels.prefix(count)) : labels + Array(repeating: "", count: count - labels.count)
    }

    // MARK: - Selecting cells

    private func clearSelection() {
        selection = []
        cursor = nil
        anchor = nil
    }

    /// Selects one cell of a map, which becomes the selected map. With `extending` (a Shift-click,
    /// or a drag that reached this cell) the block from where the selection started to here is selected.
    func selectCell(_ cell: ROMTable.Cell, in name: String, extending: Bool = false) {
        guard let table = tables[name], cell.row >= 0, cell.row < table.rows, cell.column >= 0, cell.column < table.columns else { return }
        if selectedMap != name { select(map: name) }
        if extending, let anchor {
            selection = Self.block(from: anchor, to: cell)
        } else {
            anchor = cell
            selection = [cell]
        }
        cursor = cell
        fillValueField()
    }

    /// Moves the selection with the arrow keys. With `extending` (Shift) the block grows or shrinks.
    /// Without a selected cell the first one of the map is taken.
    func moveSelection(rows: Int, columns: Int, extending: Bool = false) {
        guard let name = selectedMap, let table = tables[name], table.rows > 0, table.columns > 0 else { return }
        guard let cursor else {
            selectCell(ROMTable.Cell(row: 0, column: 0), in: name)
            return
        }
        let next = ROMTable.Cell(row: min(max(cursor.row + rows, 0), table.rows - 1),
                                 column: min(max(cursor.column + columns, 0), table.columns - 1))
        selectCell(next, in: name, extending: extending)
    }

    /// Selects every cell of the selected map.
    func selectAllCells() {
        guard let name = selectedMap, let table = tables[name], table.rows > 0, table.columns > 0 else { return }
        anchor = ROMTable.Cell(row: 0, column: 0)
        cursor = ROMTable.Cell(row: table.rows - 1, column: table.columns - 1)
        selection = Self.block(from: anchor!, to: cursor!)
    }

    private static func block(from one: ROMTable.Cell, to other: ROMTable.Cell) -> Set<ROMTable.Cell> {
        var cells: Set<ROMTable.Cell> = []
        for row in min(one.row, other.row)...max(one.row, other.row) {
            for column in min(one.column, other.column)...max(one.column, other.column) {
                cells.insert(ROMTable.Cell(row: row, column: column))
            }
        }
        return cells
    }

    /// The selected cells, row by row.
    private var orderedSelection: [ROMTable.Cell] {
        selection.sorted { ($0.row, $0.column) < ($1.row, $1.column) }
    }

    /// The Value field follows the cell that is selected, until a person types something of their own in it.
    private func fillValueField() {
        guard valueText.isEmpty || valueText == filledValueText,
              let name = selectedMap, let table = tables[name], let cursor,
              cursor.row < table.rows, cursor.column < table.columns else { return }
        valueText = table.scaling.text(table.values[cursor.row][cursor.column])
        filledValueText = valueText
    }

    /// The selected cells as text, a tab between the columns and a line for each row, for the clipboard.
    func copySelection() {
        guard let name = selectedMap, let table = tables[name], !selection.isEmpty else { return }
        let rows = Dictionary(grouping: orderedSelection, by: \.row)
        let text = rows.keys.sorted().map { row in
            (rows[row] ?? []).map { table.scaling.text(table.values[$0.row][$0.column]) }.joined(separator: "\t")
        }.joined(separator: "\n")
        Desktop.copy(text)
        report("Copied \(Self.counted(selection.count, "cell")).")
    }

    /// The strip under the selected map: the cell the selection ends on.
    struct CellDetail: Equatable {
        /// "4000 RPM × 410"
        let place: String
        let now: String
        /// "psi", or "" for a number without a unit.
        let units: String
        /// What the cell held when the ROM was opened, and the difference with its sign ("+0.77").
        /// Nil for a cell that is as it was opened.
        let opened: String?
        let difference: String?
        /// What the other ROM holds, while one is compared and it differs.
        let other: String?
        /// Another ROM is being compared: the strip speaks of that one, not of the ROM as opened.
        let comparing: Bool
        /// "Stored as 0x00D3 at 0x0C0F42"
        let stored: String
        /// How many cells are selected.
        let count: Int
        /// One of the selected cells is not as it was opened, so "Put back as opened" has work to do.
        let canPutBack: Bool
    }

    var cellDetail: CellDetail? {
        guard let name = selectedMap, let table = tables[name], let rom, let cursor,
              cursor.row < table.rows, cursor.column < table.columns else { return nil }
        let scaling = table.scaling
        let now = table.values[cursor.row][cursor.column]
        let changed = changedCells(of: name)
        let was = changed[cursor]
        let theirs = isComparing ? differentCells(of: name)[cursor] : nil
        var stored = ""
        if let offset = table.offset(row: cursor.row, column: cursor.column),
           let bytes = table.storedBytes(in: rom, row: cursor.row, column: cursor.column) {
            stored = "Stored as 0x\(bytes.map { Self.hex(Int($0), width: 2) }.joined()) at 0x\(Self.hex(offset, width: 6))"
        }
        return CellDetail(place: table.place(row: cursor.row, column: cursor.column), now: scaling.text(now),
                          units: scaling.shortUnits, opened: was.map(scaling.text),
                          difference: was.map { scaling.signedText(now - $0) }, other: theirs.map(scaling.text),
                          comparing: isComparing, stored: stored, count: selection.count,
                          canPutBack: !isComparing && selection.contains { changed[$0] != nil })
    }

    // MARK: - Editing cells

    /// The selected map's cells can be changed: it has a way back from a value to bytes, it shows
    /// the ROM as it is now, and no other ROM is being compared.
    var canEditCells: Bool {
        guard let name = selectedMap, let table = tables[name], !isComparing else { return false }
        let view = self.view(of: name)
        return table.scaling.isWritable && (view.surface || view.shows == .now)
    }

    /// Why the selected map's cells cannot be changed, for a screen to say so. Nil when they can.
    var editingNote: String? {
        guard let name = selectedMap, let table = tables[name] else { return nil }
        if isComparing { return "Stop comparing to change this ROM." }
        if !table.scaling.isWritable { return "This map is read-only: its definition has no way back from a value to bytes." }
        let view = self.view(of: name)
        if !view.surface, view.shows != .now { return "Choose Now to change the cells." }
        return nil
    }

    /// Raises or lowers the selected cells by the Fine or the Coarse step.
    func step(_ size: StepSize, up: Bool) {
        let text = size == .fine ? fineStepText : coarseStepText
        guard let step = Self.number(text), step > 0 else {
            report("The \(size == .fine ? "fine" : "coarse") step is not a number above zero.", problem: true)
            return
        }
        change(.step(up ? step : -step)) { count, before, after, cells in
            let scaling = after.scaling
            let units = scaling.shortUnits.isEmpty ? "" : " \(scaling.shortUnits)"
            let did = "\(up ? "Raised" : "Lowered") \(count) in \(after.title)"
            // What the cells really moved, which is not always what was asked for.
            let moved = cells.map { abs(after.values[$0.row][$0.column] - before.values[$0.row][$0.column]) }
            let most = moved.max() ?? step, least = moved.min() ?? step
            if most > step * 1.5 {
                return "\(did) by \(scaling.text(most))\(units), the smallest step these cells can hold."
            }
            if least < step * 0.5 {
                return "\(did) by \(Self.plain(step))\(units) or as far as they go: not every cell had that much room left."
            }
            return "\(did) by \(Self.plain(step))\(units)."
        }
    }

    /// Gives the selected cells one value: the Value field's, or `text` when a number was typed in a cell.
    func setSelection(to text: String? = nil) {
        guard let value = Self.number(text ?? valueText) else {
            report("\"\(text ?? valueText)\" is not a number.", problem: true)
            return
        }
        change(.set(value)) { count, _, after, cells in
            // A cell holds the nearest value it can, and no more than its storage has room for.
            let asked = after.scaling.text(value)
            let held = cells.first.map { after.scaling.text(after.values[$0.row][$0.column]) } ?? asked
            if held != asked { return "Set \(count) in \(after.title) to \(held), the nearest to \(Self.plain(value)) that fits there." }
            return "Set \(count) in \(after.title) to \(asked)."
        }
    }

    /// Multiplies the selected cells by the Value field.
    func multiplySelection() {
        guard let factor = Self.number(valueText) else {
            report("\"\(valueText)\" is not a number.", problem: true)
            return
        }
        change(.multiply(factor)) { count, _, after, _ in "Multiplied \(count) in \(after.title) by \(Self.plain(factor))." }
    }

    /// Makes one change to every selected cell, as one step for Undo to take back. `saying` words
    /// what happened from the map before and after it, and the cells that were changed.
    private func change(_ change: ROMTable.Change, saying: (String, ROMTable, ROMTable, [ROMTable.Cell]) -> String) {
        guard let name = selectedMap, let table = tables[name], let rom else { return }
        guard canEditCells else {
            report(editingNote, problem: true)
            return
        }
        guard !selection.isEmpty else {
            report("Select the cells to change first.", problem: true)
            return
        }
        do {
            let cells = orderedSelection
            let edited = try table.write(rom, cells: cells, change: change)
            guard edited != rom else {
                report("Nothing changed: the selected cells already hold that, or are at the end of what they can hold.")
                return
            }
            apply(edited, as: "the edit in \(table.title)")
            report(saying(Self.counted(cells.count, "cell"), table, tables[name] ?? table, cells))
        } catch {
            report(error.localizedDescription, problem: true)
        }
    }

    /// Writes what was typed for one cell of an open map into the ROM, through the map's scaling,
    /// and returns what the cell holds afterwards. Text that is not a number, or the number that is
    /// there already, changes nothing. This is an edit of the file in memory. It never touches the car.
    @discardableResult
    func editCell(map name: String, row: Int, column: Int, text typed: String) -> String {
        guard let rom, let table = tables[name], row >= 0, row < table.rows, column >= 0, column < table.columns else { return "" }
        let before = table.values[row][column]
        guard table.scaling.isWritable, !isComparing, let value = Self.number(typed), value != before else {
            return table.scaling.text(before)
        }
        do {
            let edited = try table.write(rom, row: row, column: column, realValue: value)
            if edited != rom {
                apply(edited, as: "the edit in \(table.title)")
                report("Edited \(table.title) at \(table.place(row: row, column: column)).")
            }
        } catch {
            report(error.localizedDescription, problem: true)
        }
        guard let now = tables[name], row < now.rows, column < now.columns else { return "" }
        return now.scaling.text(now.values[row][column])
    }

    /// Gives the selected cells the bytes they had when the ROM was opened.
    func putBackSelection() {
        guard let name = selectedMap, let table = tables[name], !isComparing else { return }
        putBack(orderedSelection, of: table, as: "putting cells back in \(table.title)")
    }

    /// Gives every cell of a map the bytes it had when the ROM was opened.
    func putBackMap(_ name: String) {
        guard let table = tables[name], !isComparing, table.rows > 0, table.columns > 0 else { return }
        let all = Self.block(from: ROMTable.Cell(row: 0, column: 0), to: ROMTable.Cell(row: table.rows - 1, column: table.columns - 1))
        putBack(all.sorted { ($0.row, $0.column) < ($1.row, $1.column) }, of: table, as: "putting \(table.title) back")
    }

    private func putBack(_ cells: [ROMTable.Cell], of table: ROMTable, as label: String) {
        guard let rom, let opened else { return }
        var edited = rom
        var count = 0
        for cell in cells {
            guard let offset = table.offset(row: cell.row, column: cell.column),
                  let bytes = table.storedBytes(in: opened, row: cell.row, column: cell.column),
                  edited.bytes(at: offset, length: bytes.count) != bytes else { continue }
            edited.replace(at: offset, with: bytes)
            count += 1
        }
        guard count > 0 else {
            report("Those cells are as they were when this ROM was opened.")
            return
        }
        apply(edited, as: label)
        report("Put \(Self.counted(count, "cell")) in \(table.title) back as opened.")
    }

    /// Makes the whole ROM what it was when it was opened, as one step for Undo to take back.
    func putEverythingBack() {
        guard let rom, let opened, rom != opened, !isComparing else { return }
        apply(opened, as: "putting everything back")
        report("Everything is as it was when this ROM was opened. Undo brings your changes back.")
    }

    // MARK: - Undo and what changed

    var canUndo: Bool { history.canUndo && !isComparing }
    var canRedo: Bool { history.canRedo && !isComparing }

    /// Puts an edited ROM in the editor as one step for Undo to take back.
    private func apply(_ edited: ROMImage, as label: String) {
        guard let rom else { return }
        history.record(label, from: rom, to: edited)
        self.rom = edited
        romChanged()
    }

    /// The bytes are different: everything that is worked out from them is worked out again.
    private func romChanged() {
        isEdited = rom != saved
        refreshChecksum()
        for name in openMaps { readTables(of: name) }
        refreshChanges()
    }

    func undo() {
        guard canUndo, let rom, let label = history.undoLabel, let restored = history.undo(rom) else { return }
        self.rom = restored
        romChanged()
        report("Undid \(label).")
    }

    func redo() {
        guard canRedo, let rom, let label = history.redoLabel, let edited = history.redo(rom) else { return }
        self.rom = edited
        romChanged()
        report("Redid \(label).")
    }

    /// One change in the Changes panel.
    struct ChangeLine: Identifiable, Equatable {
        let id: Int
        /// The cell to go to. Nil for a value on an axis.
        let cell: ROMTable.Cell?
        /// "4000 RPM × 410"
        let place: String
        /// The number when the ROM was opened, and the number now.
        let was: String
        let now: String
        let raised: Bool
    }

    /// The changes of one map in the Changes panel.
    struct ChangeGroup: Identifiable, Equatable {
        /// The map's name in the definition.
        let id: String
        let title: String
        /// "psi"
        let units: String
        let lines: [ChangeLine]
        /// How many more lines there are than these.
        let more: Int
    }

    /// What differs from the ROM as it was opened, and from the file it is compared with. Which map a
    /// byte belongs to comes from the definitions, so this is also worked out again when those change.
    private func refreshChanges() {
        guard let rom, let opened else {
            changes = nil; comparison = nil
            changedCounts = [:]; differentCounts = [:]; changeGroups = []; changeGroupsMore = 0
            return
        }
        let scalings = defs?.scalings ?? [:]
        changes = try? ROMComparison(opened, rom, tables: tableDefs, scalings: scalings)
        comparison = other.flatMap { try? ROMComparison(rom, $0, tables: tableDefs, scalings: scalings) }
        changedCounts = Self.counts(of: changes)
        differentCounts = Self.counts(of: comparison)

        let maps = changes?.maps ?? []
        changeGroupsMore = max(0, maps.count - Self.changeGroupLimit)
        changeGroups = maps.prefix(Self.changeGroupLimit).map { map in
            // The map as it is now says where each cell is in the words of its axes.
            let table = tables[map.name] ?? tableDefs.first { $0.name == map.name }.flatMap { try? ROMTable.read(rom, def: $0, scalings: scalings) }
            var lines: [ChangeLine] = []
            for cell in map.cells.prefix(Self.lineLimit) {
                lines.append(ChangeLine(id: lines.count, cell: ROMTable.Cell(row: cell.row, column: cell.column),
                                        place: table?.place(row: cell.row, column: cell.column) ?? map.place(of: cell),
                                        was: map.scaling.text(cell.first), now: map.scaling.text(cell.second),
                                        raised: cell.second > cell.first))
            }
            var total = map.cells.count
            for axis in [map.xAxis, map.yAxis] {
                guard let axis else { continue }
                total += axis.labels.count
                for label in axis.labels where lines.count < Self.lineLimit {
                    lines.append(ChangeLine(id: lines.count, cell: nil, place: "\(axis.name), value \(label.index + 1)",
                                            was: axis.scaling.text(label.first), now: axis.scaling.text(label.second),
                                            raised: label.second > label.first))
                }
            }
            return ChangeGroup(id: map.name, title: map.name.trimmingCharacters(in: .whitespaces),
                               units: map.scaling.shortUnits, lines: lines, more: total - lines.count)
        }
    }

    private static func counts(of comparison: ROMComparison?) -> [String: Int] {
        var counts: [String: Int] = [:]
        for map in comparison?.maps ?? [] {
            counts[map.name] = map.cells.count + (map.xAxis?.labels.count ?? 0) + (map.yAxis?.labels.count ?? 0)
        }
        return counts
    }

    /// Something is not what it was when the ROM was opened.
    var hasChanges: Bool { !(changes?.isIdentical ?? true) }

    /// The status bar's word on what changed: "5 cells changed in 2 maps since this ROM was opened".
    var changesSummary: String {
        guard let changes, !changes.isIdentical else { return "Nothing changed since this ROM was opened" }
        let cells = changedCounts.values.reduce(0, +)
        guard cells > 0 else {
            return "\(Self.counted(changes.differingBytes, "byte")) changed outside the maps since this ROM was opened"
        }
        return "\(Self.counted(cells, "cell")) changed in \(Self.counted(changedCounts.count, "map")) since this ROM was opened"
    }

    /// What the Changes panel says under its maps about the bytes that changed in no map.
    var changesOtherBytesText: String? { changes?.otherBytesText }

    // MARK: - Comparing

    /// Asks for a second ROM file and holds this ROM against it.
    func compareWithROM() {
        guard rom != nil, let url = Desktop.chooseFileToOpen(filter: Self.romFilter) else { return }
        compare(with: url)
    }

    /// Holds this ROM against another file. Neither is changed.
    func compare(with url: URL) {
        guard let rom else { return }
        do {
            let loaded = try ROMImage(contentsOf: url)
            // Two ROMs of different sizes have no byte for byte comparison, and say so here.
            _ = try ROMComparison(rom, loaded)
            other = loaded
            otherName = url.lastPathComponent
            compareError = nil
            showsChanges = false
            listing = .different
            collapsedWhileNarrowed = []
            for name in openMaps { readTables(of: name) }
            refreshChanges()
            report(nil)
        } catch {
            stopComparing()
            compareError = error is ROMComparison.CompareError ? error.localizedDescription
                : "Could not open the file: \(error.localizedDescription)"
            report(compareError, problem: true)
        }
    }

    func stopComparing() {
        other = nil
        otherName = ""
        compareError = nil
        if listing == .different { listing = .all }
        otherTables = [:]
        refreshChanges()
    }

    /// The toolbar's Compare button: asks for the other file, or stops comparing.
    func toggleComparing() {
        if isComparing { stopComparing() } else { compareWithROM() }
    }

    /// What the bar says after the other file's name: "same calibration, AZ1G500F".
    var compareCalibrationText: String {
        guard let comparison else { return "" }
        if comparison.firstCalibrationID == comparison.secondCalibrationID {
            return comparison.secondCalibrationID.map { "same calibration, \($0)" } ?? "no calibration ID in either"
        }
        return comparison.secondCalibrationID.map { "a different calibration, \($0)" } ?? "no calibration ID that SubieScope can read"
    }

    /// A warning for two ROMs that are not the same calibration. Nil when they are.
    var compareWarning: String? { comparison?.otherCalibrationText }

    /// The status bar's word while comparing: "18 cells are different in 2 maps. Comparing changes neither file."
    var compareSummary: String {
        guard let comparison else { return "" }
        if comparison.isIdentical { return "The two ROMs are the same, byte for byte." }
        let cells = differentCounts.values.reduce(0, +)
        guard cells > 0 else {
            let bytes = comparison.differingBytes
            return "\(Self.counted(bytes, "byte")) \(bytes == 1 ? "is" : "are") different, outside the maps. Comparing changes neither file."
        }
        return "\(Self.counted(cells, "cell")) \(cells == 1 ? "is" : "are") different in \(Self.counted(differentCounts.count, "map")). Comparing changes neither file."
    }

    // MARK: - Bytes

    /// One line of the Bytes card: where it starts, sixteen bytes, and the same bytes as text.
    struct ByteLine: Identifiable, Equatable {
        let id: Int
        /// "00A340"
        let offset: String
        /// "41 5A 31 47 …"
        let hex: String
        /// "AZ1G…", with a dot for every byte that is not a letter, a digit or a sign.
        let text: String
    }

    /// The bytes on show, from `viewOffset`.
    func byteLines(rows: Int = 16) -> [ByteLine] {
        guard let rom else { return [] }
        let width = 16
        let start = max(0, min(viewOffset - (viewOffset % width), max(0, rom.byteCount - width)))
        return (0..<rows).compactMap { row in
            let base = start + row * width
            guard base < rom.byteCount, let bytes = rom.bytes(at: base, length: min(width, rom.byteCount - base)) else { return nil }
            return ByteLine(id: base, offset: Self.hex(base, width: 6),
                            hex: bytes.map { Self.hex(Int($0), width: 2) }.joined(separator: " "),
                            text: String(decoding: bytes.map { (0x20...0x7E).contains($0) ? $0 : UInt8(ascii: ".") }, as: UTF8.self))
        }
    }

    func applyGoto(_ text: String) {
        if let value = Self.parseHex(text) {
            viewOffset = value
            bytesError = nil
        } else {
            bytesError = "Not a valid hex offset."
        }
    }

    func applyEdit(offset offsetText: String, bytes bytesText: String) {
        guard var rom else { return }
        guard !isComparing else { bytesError = "Stop comparing to change this ROM."; return }
        guard let offset = Self.parseHex(offsetText) else { bytesError = "Offset is not valid hex."; return }
        let hex = bytesText.filter { !$0.isWhitespace }
        guard !hex.isEmpty, hex.count % 2 == 0 else { bytesError = "Enter whole bytes, e.g. 41 42 43."; return }
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<next], radix: 16) else { bytesError = "\(hex[i..<next]) is not a hex byte."; return }
            bytes.append(byte)
            i = next
        }
        // An offset far past the end is refused here, before any sum is made with it.
        guard offset <= rom.byteCount, rom.replace(at: offset, with: bytes) else {
            bytesError = "Those \(bytes.count) bytes would run past the end of the ROM."
            return
        }
        let place = "0x\(String(offset, radix: 16, uppercase: true))"
        apply(rom, as: "the bytes written at \(place)")
        bytesError = nil
        viewOffset = offset
        report("Wrote \(Self.counted(bytes.count, "byte")) at \(place).")
    }

    // MARK: - Helpers

    private static func parseHex(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "0x", with: "")
        guard !t.isEmpty else { return nil }
        return Int(t, radix: 16)
    }

    /// A number in capital hex digits, with zeros in front up to `width`.
    static func hex(_ value: Int, width: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    /// A number a person typed. A comma is taken for the decimal point, as many keyboards write it.
    static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    /// A number without zeros it does not need: "0.08", "1", "50".
    static func plain(_ value: Double) -> String {
        String(format: "%g", value)
    }

    /// "1 cell", "12 cells"
    static func counted(_ count: Int, _ thing: String) -> String {
        "\(count) \(thing)\(count == 1 ? "" : "s")"
    }
}
