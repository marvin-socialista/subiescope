#if os(Windows) || DEBUG
import Foundation
import Observation
import SSMKit

/// The ROM editor, which sits behind Advanced mode: a ROM that is opened from a file or read from the
/// car, what it is, its checksums, its maps as tables to edit, its raw bytes, and saving it as a new
/// file. Reading is the one thing here that talks to the car. Nothing here writes to it.
extension Bridge {
    /// Advanced mode and the warning in front of it. The page shows that warning wherever in the app
    /// the person is, so it is a piece of its own.
    struct ROMAdvancedState: Encodable {
        /// Advanced mode is on: the ROM editor is there. Off: its place says how to turn it on.
        let on: Bool
        /// The warning that has to be accepted before Advanced mode turns on is up.
        let showDisclaimer: Bool
        /// ROMDisclaimer's texts, with "PC" where they say "Mac" in the Windows app.
        let short: String
        let noWriteToCar: String
        /// Paragraphs, with an empty line between them.
        let full: String
        /// "Mac" or "PC".
        let computer: String
    }

    /// The "Read from car" card.
    struct ROMReadState: Encodable {
        let inProgress: Bool
        /// From 0 to 1.
        let progress: Double
        /// What the read is doing, or how the last one ended.
        let status: String?
        /// The last read failed: its status is shown in red.
        let failed: Bool
        /// Why reading is or is not possible right now.
        let availability: String
        let canRead: Bool
        /// The adapter is being asked what kind it is.
        let checkingAdapter: Bool
    }

    /// The ROM in the editor, without the numbers of its maps and without its bytes.
    struct ROMState: Encodable {
        struct Row: Encodable {
            let label: String
            let value: String
        }

        struct Checksums: Encodable {
            /// "unknown" (no layout is known for this size), "disabled", "ok" or "mismatch".
            /// With a mismatch the page offers to correct them.
            let state: String
            let text: String
        }

        struct Suggestion: Encodable {
            let id: String
            /// "AZ1G201G · ECU 6644D87207"
            let label: String
        }

        struct Definitions: Encodable {
            let loading: Bool
            /// Where they came from ("from the SubieScope repository", or a file's name). Empty while there are none.
            let source: String
            /// "none" (no definitions yet), "matched", "suggestions" (no exact match, some that are
            /// close) or "unknown" (nothing in them for this ROM).
            let state: String
            /// "Matched: AZ1G201G · ECU 6644D87207"
            let matchedText: String?
            let suggestions: [Suggestion]
        }

        /// False until a ROM is opened or read. The page then invites to open one.
        let isOpen: Bool
        /// Goes up with every ROM that is put in the editor: the page starts its own fields again.
        let session: Int
        /// The File card: Name, Size, Calibration ID and Fingerprint.
        let file: [Row]
        let checksums: Checksums?
        /// What happened last ("Saved to edited.bin.").
        let status: String?
        let definitions: Definitions
        /// What went wrong with the definitions or with a map.
        let mapError: String?
        /// The name of the map on show, or "" for none. The maps to choose from are the slice `rom.maps`.
        let selectedMap: String
        /// Goes up whenever the numbers of the map on show may all be different. The page then asks
        /// for them again with `rom.map`.
        let mapVersion: Int
        /// Why the last "Show" or "Apply" of the Bytes card did nothing.
        let bytesError: String?
    }

    /// The maps to choose from as the list shows them: by category, and by name within one.
    struct ROMMapCategory: Encodable {
        let name: String
        let maps: [String]
    }

    /// One line of the Bytes card: where it starts, sixteen bytes, and the same bytes as text.
    struct ROMBytesLine: Encodable {
        /// "00A340"
        let offset: String
        /// "41 5A 31 47 …"
        let hex: String
        /// "AZ1G…", with a dot for every byte that is not a letter, a digit or a sign.
        let text: String
    }

    /// One map with its numbers. It can be large, so it is not a slice: the page asks for it (`rom.map`)
    /// when `mapVersion` changes, and an edit answers with the one cell that changed.
    struct ROMMap: Encodable {
        let name: String
        /// "ms". Shown in brackets after the name when there are any.
        let units: String
        let description: String
        /// The definition has no formula from a value back to bytes, so the cells cannot be changed.
        let readOnly: Bool
        /// The labels above the columns, or nil for a map without that line.
        let columns: [String]?
        /// The label in front of each row. "" for a row without one.
        let rows: [String]
        /// The cells as the table shows them, row by row.
        let cells: [[String]]
    }

    struct ROMCellReply: Encodable {
        /// What the cell holds now. The same as before when what was typed is not a number, or changed nothing.
        let text: String
    }

    func registerROM() {
        let editor = ROMEditor()

        slice("rom.advanced") { [model] in
            ROMAdvancedState(on: model.advancedMode, showDisclaimer: model.showAdvancedDisclaimer,
                             short: Bridge.romText(ROMDisclaimer.short), noWriteToCar: Bridge.romText(ROMDisclaimer.noWriteToCar),
                             full: Bridge.romText(ROMDisclaimer.full), computer: Bridge.computer)
        }

        // The progress of a read changes with every page of the ROM, a thousand times in all.
        slice("rom.read", atMost: 10) { [model] in
            ROMReadState(inProgress: model.romReadInProgress, progress: model.romReadProgress.finite ?? 0,
                         status: model.romReadInProgress ? (model.romReadStatus ?? "Reading…") : model.romReadStatus,
                         failed: model.romReadError != nil, availability: model.romReadAvailability,
                         canRead: model.canReadROMFromCar, checkingAdapter: model.checkingAdapterType)
        }

        slice("rom") { () -> ROMState in
            let definitions = ROMState.Definitions(
                loading: editor.loadingDefs, source: editor.defs == nil ? "" : editor.defsSource,
                state: editor.defs == nil ? "none" : editor.matched != nil ? "matched" : editor.recommendations.isEmpty ? "unknown" : "suggestions",
                matchedText: editor.matched.map { "Matched: \(ROMEditor.label(of: $0))" },
                suggestions: editor.recommendations.map { .init(id: $0.identity.xmlID, label: ROMEditor.label(of: $0)) })
            guard let rom = editor.rom else {
                return ROMState(isOpen: false, session: editor.session, file: [], checksums: nil, status: editor.status,
                                definitions: definitions, mapError: editor.mapError, selectedMap: "", mapVersion: editor.mapVersion,
                                bytesError: nil)
            }
            var checksums: ROMState.Checksums?
            if editor.noLayout {
                checksums = .init(state: "unknown", text: "No checksum layout is known for this ROM size, so SubieScope can't check or correct it.")
            } else if let report = editor.report {
                if report.allDisabled {
                    checksums = .init(state: "disabled", text: "This ROM has its checksums disabled.")
                } else if report.ok {
                    checksums = .init(state: "ok", text: "All checksums match.")
                } else {
                    let active = report.records.filter { !$0.isBlank }.count
                    checksums = .init(state: "mismatch", text: "\(report.mismatchCount) of \(active) checksum regions do not match.")
                }
            }
            return ROMState(
                isOpen: true, session: editor.session,
                file: [
                    .init(label: "Name", value: editor.fileName + (editor.dirty ? " (edited, not saved)" : "")),
                    .init(label: "Size", value: "\(rom.byteCount) bytes" + (rom.size.map { " · \($0.label)" } ?? " · not a standard Subaru ROM size")),
                    .init(label: "Calibration ID", value: rom.calibrationID() ?? "unknown (may not be a Subaru 32-bit ROM)"),
                    .init(label: "Fingerprint", value: rom.quickFingerprint),
                ],
                checksums: checksums, status: editor.status, definitions: definitions, mapError: editor.mapError,
                selectedMap: editor.selectedTableName ?? "", mapVersion: editor.mapVersion, bytesError: editor.editError)
        }

        // A ROM has a few hundred maps. Their names only change with the ROM or the definitions, not with an edit.
        slice("rom.maps") { () -> [ROMMapCategory] in
            let categories = Dictionary(grouping: editor.tableDefs.filter { $0.isEditable }, by: { $0.category.isEmpty ? "Other" : $0.category })
            return categories.keys.sorted().map { category in
                ROMMapCategory(name: category, maps: (categories[category] ?? []).map(\.name).sorted())
            }
        }

        slice("rom.bytes") { () -> [ROMBytesLine] in
            guard let rom = editor.rom else { return [] }
            let rowBytes = 16, dumpRows = 16
            let start = max(0, min(editor.viewOffset - (editor.viewOffset % rowBytes), max(0, rom.byteCount - rowBytes)))
            return (0..<dumpRows).compactMap { row in
                let base = start + row * rowBytes
                guard base < rom.byteCount, let bytes = rom.bytes(at: base, length: min(rowBytes, rom.byteCount - base)) else { return nil }
                return ROMBytesLine(
                    offset: Bridge.romHex(base, width: 6),
                    hex: bytes.map { Bridge.romHex(Int($0), width: 2) }.joined(separator: " "),
                    text: String(decoding: bytes.map { (0x20...0x7E).contains($0) ? $0 : UInt8(ascii: ".") }, as: UTF8.self))
            }
        }

        // MARK: Advanced mode

        action("rom.showDisclaimer") { [model] _ in model.showAdvancedDisclaimer = true }
        action("rom.dismissDisclaimer") { [model] _ in model.showAdvancedDisclaimer = false }
        // Advanced mode only ever turns on from the warning, so not while that is not up.
        action("rom.acceptDisclaimer") { [model] _ in
            guard model.showAdvancedDisclaimer else { return }
            model.advancedMode = true
            model.section = .rom
            model.showAdvancedDisclaimer = false
        }

        // MARK: Reading from the car

        // Finds out whether the adapter can read a ROM. The Mac's view asks when it appears and
        // whenever the connection changes, and so does the page.
        action("rom.checkAdapter") { [model] _ in
            Task { await model.checkROMReadCapability() }
        }
        action("rom.readFromCar") { [model] _ in
            guard model.canReadROMFromCar else { return }
            Task {
                if let loaded = await model.readROMFromCar() { editor.loadReadROM(loaded) }
            }
        }
        action("rom.stopRead") { [model] _ in model.cancelROMRead() }

        // MARK: Files

        // The three below ask for a file. With a `path` they take that file and ask nothing, which is
        // how the page is tested where nobody can answer a dialog.
        romAction("rom.open") { [model] arguments in
            guard model.advancedMode else { return }
            guard let url = arguments.string("path").map({ URL(fileURLWithPath: $0) })
                    ?? Desktop.chooseFileToOpen(filter: ["ECU ROM files (*.bin)", "*.bin"]) else { return }
            editor.open(url)
        }
        romAction("rom.saveAs") { [model] arguments in
            guard model.advancedMode, editor.rom != nil else { return }
            guard let url = arguments.string("path").map({ URL(fileURLWithPath: $0) })
                    ?? Desktop.chooseSaveLocation(suggestedName: editor.suggestedSaveName) else { return }
            editor.save(to: url)
        }
        romAction("rom.openDefinitions") { [model] arguments in
            guard model.advancedMode else { return }
            guard let url = arguments.string("path").map({ URL(fileURLWithPath: $0) })
                    ?? Desktop.chooseFileToOpen(filter: ["RomRaider definitions (*.xml)", "*.xml"]) else { return }
            editor.openDefinitions(url)
        }
        action("rom.getDefinitions") { [model] _ in
            guard model.advancedMode else { return }
            Task { await editor.autoLoadDefinitions() }
        }
        romAction("rom.useDefinition") { arguments in
            guard let id = arguments.string("id") else { return }
            editor.applyRecommendation(id)
        }

        // MARK: Editing

        romAction("rom.selectMap") { arguments in
            editor.selectTable(arguments.string("name") ?? "")
        }
        request("rom.map") { _ in editor.map() }
        // `map` is the name of the map the page shows: a cell of another one is never written.
        request("rom.editCell") { arguments in
            ROMCellReply(text: editor.editCell(map: arguments.string("map") ?? "", row: arguments.int("row") ?? -1,
                                               column: arguments.int("column") ?? -1, text: arguments.string("text") ?? ""))
        }
        romAction("rom.correctChecksums") { _ in editor.correctChecksums() }
        romAction("rom.showOffset") { arguments in
            editor.applyGoto(arguments.string("offset") ?? "")
        }
        romAction("rom.writeBytes") { arguments in
            editor.applyEdit(offset: arguments.string("offset") ?? "", bytes: arguments.string("bytes") ?? "")
        }
    }

    /// An action on the ROM that waits its turn. A cell that was just typed is written by a request,
    /// and the bridge answers a request a moment later than it does an action. Without the wait,
    /// "Correct Checksums" or "Save As" pressed right after typing could come before that cell.
    /// It also lets a file dialog come up after the page's message has been dealt with, not in the middle of it.
    private func romAction(_ name: String, _ handler: @escaping @MainActor (Arguments) -> Void) {
        action(name) { arguments in
            Task { @MainActor in handler(arguments) }
        }
    }

    /// A number in capital hex digits, with zeros in front up to `width`.
    static func romHex(_ value: Int, width: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    /// The ROM warnings say "your Mac" (they are SSMKit's, and the same in the Mac app and the command line tool).
    static func romText(_ text: String) -> String {
        text.replacingOccurrences(of: "your Mac", with: "your \(Bridge.computer)")
    }
}

/// What the ROM editor holds: the ROM that is open and everything worked out from it.
///
/// In the Mac app this is the state of `ROMView` (Views/ROMView.swift), and the functions below are
/// that view's own. They are restated here because the Windows app has no view to keep them in: the
/// page only shows what this says. It lives as long as the bridge, so a ROM stays open while the
/// person looks at another part of the app.
@MainActor
@Observable
final class ROMEditor {
    var rom: ROMImage?
    var fileName = ""
    var dirty = false
    var report: SubaruChecksum.Report?
    var noLayout = false
    var status: String?
    var session = 0

    // The bytes
    var viewOffset = 0
    var editError: String?

    // The maps (RomRaider's definitions)
    var defs: ROMDefinitionSet?
    var matched: ROMDefinition?
    var tableDefs: [ROMTableDef] = []
    var selectedTableName: String?
    var currentTable: ROMTable?
    var mapError: String?
    var recommendations: [ROMDefinition] = []
    var loadingDefs = false
    var defsSource = ""
    var mapVersion = 0

    /// "AZ1G201G · ECU 6644D87207"
    static func label(of definition: ROMDefinition) -> String {
        definition.identity.xmlID + (definition.identity.ecuID.map { " · ECU \($0)" } ?? "")
    }

    // MARK: Opening and saving

    func open(_ url: URL) {
        do {
            let loaded = try ROMImage(contentsOf: url)
            load(loaded, name: url.lastPathComponent, dirty: false, status: nil)
        } catch {
            status = "Could not open the file: \(error.localizedDescription)"
        }
    }

    /// A ROM read from the car goes straight into the editor, as if it had been opened from a file.
    /// It is not on disk yet, so it counts as not saved.
    func loadReadROM(_ loaded: ROMImage) {
        let id = loaded.calibrationID() ?? "car"
        load(loaded, name: "\(id)-read.bin", dirty: true,
             status: "Read from the car. Use Save As… to keep this file before you edit it.")
    }

    private func load(_ loaded: ROMImage, name: String, dirty: Bool, status: String?) {
        rom = loaded
        fileName = name
        self.dirty = dirty
        self.status = status
        editError = nil
        viewOffset = 0
        selectedTableName = nil
        currentTable = nil
        session += 1
        mapVersion += 1
        refreshChecksum()
        if defs == nil {
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

    func save(to url: URL) {
        guard let rom else { return }
        do {
            try rom.write(to: url)
            dirty = false
            status = "Saved to \(url.lastPathComponent)."
        } catch {
            status = "Could not save: \(error.localizedDescription)"
        }
    }

    // MARK: Definitions

    /// Downloads RomRaider's ecu_defs.xml from the SubieScope repository, or takes the copy that is
    /// there from an earlier time, and looks this ROM up in it.
    func autoLoadDefinitions() async {
        guard !loadingDefs else { return }
        loadingDefs = true
        mapError = nil
        defer { loadingDefs = false }
        do {
            defs = try await ROMDefinitionsStore.loadOrDownload()
            defsSource = "from the SubieScope repository"
            matchDefinitions()
        } catch {
            mapError = error.localizedDescription + " You can still choose a definitions file yourself."
        }
    }

    func openDefinitions(_ url: URL) {
        do {
            defs = try ROMDefinitionParser.load(url: url)
            defsSource = url.lastPathComponent
            mapError = nil
            matchDefinitions()
        } catch {
            defs = nil
            mapError = error.localizedDescription
        }
    }

    private func matchDefinitions() {
        guard let defs, let rom else { matched = nil; tableDefs = []; recommendations = []; return }
        // Only a definition whose internal ID is in the ROM is used without asking. Others are suggested.
        matched = defs.definition(matching: rom)
        if let matched {
            tableDefs = defs.resolvedTables(forXmlID: matched.identity.xmlID)
            recommendations = []
        } else {
            tableDefs = []
            recommendations = defs.recommendations(for: rom)
        }
        selectedTableName = nil
        currentTable = nil
        mapVersion += 1
    }

    /// Takes one of the suggested definitions, which the person chose.
    func applyRecommendation(_ xmlID: String) {
        guard let defs, let definition = recommendations.first(where: { $0.identity.xmlID == xmlID }) else { return }
        matched = definition
        tableDefs = defs.resolvedTables(forXmlID: definition.identity.xmlID)
        recommendations = []
        selectedTableName = nil
        currentTable = nil
        mapVersion += 1
        status = "Using definition \(definition.identity.xmlID). You chose this; it is not an exact match for the ROM."
    }

    // MARK: Maps

    func selectTable(_ name: String) {
        selectedTableName = name.isEmpty ? nil : name
        refreshTable()
    }

    /// Reads the chosen map from the ROM again. `announce` tells the page that all its numbers may be new.
    private func refreshTable(announce: Bool = true) {
        defer { if announce || currentTable == nil { mapVersion += 1 } }
        guard let rom, let defs, let name = selectedTableName,
              let def = tableDefs.first(where: { $0.name == name }) else { currentTable = nil; return }
        do {
            currentTable = try ROMTable.read(rom, def: def, scalings: defs.scalings)
            mapError = nil
        } catch {
            currentTable = nil
            mapError = error.localizedDescription
        }
    }

    /// The map on show, for the page. (The Mac's `ROMTableGrid` decides the same things.)
    func map() -> Bridge.ROMMap? {
        guard let table = currentTable else { return nil }
        let threeD = table.def.dimension == .threeD
        return Bridge.ROMMap(
            name: table.def.name, units: table.units, description: table.def.description,
            readOnly: !table.scaling.isWritable,
            columns: threeD || !table.xLabels.isEmpty ? table.xLabels.prefix(table.columns).map { Self.text($0, in: table) } : nil,
            rows: (0..<table.rows).map { threeD && $0 < table.yLabels.count ? Self.text(table.yLabels[$0], in: table) : "" },
            cells: table.values.map { row in row.map { Self.text($0, in: table) } })
    }

    /// A number of a map as its table shows it: with the decimals of RomRaider's format, such as "0.00".
    static func text(_ value: Double, in table: ROMTable) -> String {
        var decimals = 0
        if let dot = table.format.firstIndex(of: ".") {
            decimals = table.format.distance(from: table.format.index(after: dot), to: table.format.endIndex)
        }
        return String(format: "%.\(decimals)f", value)
    }

    /// Writes what was typed in a cell into the ROM, through the map's scaling, and returns what the
    /// cell holds afterwards. Text that is not a number, or the number that is there already, changes
    /// nothing. This is an edit of the file in memory. It never touches the car.
    func editCell(map name: String, row: Int, column: Int, text typed: String) -> String {
        guard let rom, let table = currentTable, table.def.name == name,
              row >= 0, row < table.rows, column >= 0, column < table.columns else { return "" }
        let before = table.values[row][column]
        guard table.scaling.isWritable, let value = Double(typed.trimmingCharacters(in: .whitespaces)), value != before else {
            return Self.text(before, in: table)
        }
        do {
            self.rom = try table.write(rom, row: row, column: column, realValue: value)
            dirty = true
            refreshChecksum()
            refreshTable(announce: false)
            status = "Edited \(table.def.name) at row \(row + 1), column \(column + 1). Correct the checksums before using this ROM."
        } catch {
            mapError = error.localizedDescription
        }
        guard let now = currentTable, row < now.rows, column < now.columns else { return "" }
        return Self.text(now.values[row][column], in: now)
    }

    // MARK: Checksums

    private func refreshChecksum() {
        guard let rom else { return }
        // No layout for this size and a table that does not fit come to the same: nothing to check.
        report = try? SubaruChecksum.verifyPetrol(rom)
        noLayout = report == nil
    }

    func correctChecksums() {
        guard let rom else { return }
        do {
            if let (fixed, report) = try SubaruChecksum.correctPetrol(rom) {
                self.rom = fixed
                self.report = report
                dirty = true
                status = "Checksums corrected. Save As… to write the new ROM."
            }
        } catch {
            status = "Could not correct the checksums: \(error.localizedDescription)"
        }
    }

    // MARK: Bytes

    func applyGoto(_ text: String) {
        if let value = Self.parseHex(text) {
            viewOffset = value
            editError = nil
        } else {
            editError = "Not a valid hex offset."
        }
    }

    func applyEdit(offset offsetText: String, bytes bytesText: String) {
        guard var rom else { return }
        guard let offset = Self.parseHex(offsetText) else { editError = "Offset is not valid hex."; return }
        let hex = bytesText.filter { !$0.isWhitespace }
        guard !hex.isEmpty, hex.count % 2 == 0 else { editError = "Enter whole bytes, e.g. 41 42 43."; return }
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<next], radix: 16) else { editError = "\(hex[i..<next]) is not a hex byte."; return }
            bytes.append(byte)
            i = next
        }
        // An offset far past the end is refused here, before any sum is made with it.
        guard offset <= rom.byteCount, rom.replace(at: offset, with: bytes) else {
            editError = "Those \(bytes.count) bytes would run past the end of the ROM."
            return
        }
        self.rom = rom
        dirty = true
        editError = nil
        viewOffset = offset
        status = "Wrote \(bytes.count) byte(s) at 0x\(String(offset, radix: 16, uppercase: true)). Checksums need correcting."
        refreshChecksum()
        // The bytes may be those of the map on show.
        if currentTable != nil { refreshTable() }
    }

    private static func parseHex(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "0x", with: "")
        guard !t.isEmpty else { return nil }
        return Int(t, radix: 16)
    }
}
#endif
