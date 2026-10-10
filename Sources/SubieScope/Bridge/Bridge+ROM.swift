#if os(Windows) || DEBUG
import Foundation
import SSMKit

/// The ROM editor, which sits behind Advanced mode: a ROM that is opened from a file or read from the
/// car, the tree of its maps, the maps that are open as tables or in 3D, what changed since it was
/// opened, how it differs from another file, and saving it as a new file.
///
/// All of it is `ROMEditor`'s (ROMEditor.swift), the one model the Mac's views draw too. Nothing is
/// kept or worked out here: the slices say what the editor says, piece by piece, and the actions pass
/// on what a person does in the page. Reading is the one thing here that talks to the car. Nothing
/// here writes to it.
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

    /// The editor around its maps: the toolbar, the card of the ROM itself, the bar while another
    /// ROM is compared, and the status bar. Slice `rom`.
    struct ROMState: Encodable {
        struct Checksums: Encodable {
            /// "unknown" (no layout is known for this size), "disabled", "ok" or "mismatch".
            /// With a mismatch the page offers to correct them.
            let state: String
            /// A few words for the toolbar, and a whole sentence for the Checksums card.
            let short: String
            let text: String
        }

        struct Definitions: Encodable {
            /// "none" (no definitions yet), "matched", "suggestions" (no exact match, some that are
            /// close) or "unknown" (nothing in them for this ROM).
            let state: String
            let loading: Bool
            /// One sentence on how they stand, and the status bar's few words.
            let text: String
            let summary: String
        }

        /// Undo, or Redo.
        struct Step: Encodable {
            let can: Bool
            /// What it would take back or put back, worded to follow the word: "the edit in Primary Fuel".
            let label: String?
        }

        /// The other ROM, while one is compared.
        struct Compare: Encodable {
            /// The other file's name.
            let other: String
            /// "same calibration, AZ1G500F"
            let calibration: String
            /// The two are not the same calibration, so the numbers shown for the other may be wrong.
            let warning: String?
            /// The status bar's word on how much differs.
            let summary: String
        }

        /// How far the 3D view turns, tilts and lifts, each as its lowest and highest value.
        struct Surface: Encodable {
            let turn: [Double]
            let tilt: [Double]
            let height: [Double]
        }

        /// False until a ROM is opened or read. The page then invites to open one.
        let isOpen: Bool
        /// Goes up with every ROM that is put in the editor: the page starts its own fields again.
        let session: Int
        let fileName: String
        /// "AZ1G500F · 2009 Impreza STi, JDM, manual"
        let identity: String
        /// "Edited, not saved"
        let saved: String
        /// The ROM is not what is on disk.
        let isEdited: Bool
        /// "1 MB · Denso SH7058"
        let size: String
        /// What happened last ("Saved to edited.bin."), and whether that went wrong.
        let status: String?
        let statusIsProblem: Bool
        let checksums: Checksums
        let definitions: Definitions
        let undo: Step
        let redo: Step
        /// Something is not what it was when the ROM was opened, in the status bar's words, and
        /// whether the Changes panel is on show.
        let hasChanges: Bool
        let changesSummary: String
        let showsChanges: Bool
        /// Nil while this ROM is compared with no other.
        let compare: Compare?
        /// The workspace shows the ROM itself, not its maps.
        let overview: Bool
        /// The name of the selected map (`rom.maps` has it), or nil.
        let selectedMap: String?
        /// Goes up whenever the selected map is to be brought into view.
        let revealCount: Int
        /// The toolbar's fields, as typed.
        let fineStep: String
        let coarseStep: String
        let value: String
        /// The selected map's cells can be changed, and why not when they cannot.
        let canEditCells: Bool
        let editingNote: String?
        let surface: Surface
        /// The heat scale from its lowest to its highest colour, for the bar under the 3D view.
        let heatScale: [String]
    }

    /// The tree on the left: the maps by category, as the listing and the filter leave them. Slice `rom.tree`.
    struct ROMTreeState: Encodable {
        struct Map: Encodable {
            /// The map's name in the definition, which is what every action takes.
            let id: String
            let title: String
            /// "1D", "2D", "3D" or "SW"
            let dimension: String
            /// How many of its cells changed since the ROM was opened, and differ from the other ROM.
            let changed: Int
            let different: Int
            let isOpen: Bool
            let isSelected: Bool
        }

        struct Category: Encodable {
            let name: String
            /// "6", or "2 of 6" while only some are listed.
            let countText: String
            let hasChanges: Bool
            let isExpanded: Bool
            /// The maps on show. Empty for a category that is folded shut: the page does not draw those.
            let maps: [Map]
        }

        let mapCount: Int
        let changedMapCount: Int
        let differentMapCount: Int
        /// "all", "changed" or "different"
        let listing: String
        let filter: String
        /// What the tree says under a list of only some maps.
        let note: String?
        let categories: [Category]
    }

    /// One open map as its window shows it. Slice `rom.maps`, in the order of the windows from the top.
    struct ROMMapWindow: Encodable {
        /// One cell of a table (`ROMEditor.CellLook`).
        struct Cell: Encodable {
            let text: String
            /// The other ROM's number, under this ROM's, in a cell that differs.
            let below: String?
            /// The cell's colour on the map's heat scale, the way a style sheet writes it. Nil in a Difference view.
            let color: String?
            /// "raised", "lowered" or "plain" in a Difference view. Nil for a cell on the heat scale.
            let fill: String?
            /// The ring around the cell: "raised", "lowered" or "different". Nil for a cell without one.
            let mark: String?
            /// What the cell says when it is pointed at.
            let note: String?
            /// From 0 to 1: how high the cell's tile floats in 3D. Only there while the map is shown in 3D.
            let place: Double?
        }

        /// A map of numbers (`ROMEditor.MapLook`).
        struct Table: Encodable {
            let description: String
            let rows: Int
            let columns: Int
            let columnTitle: String?
            let rowTitle: String?
            let valueTitle: String
            /// Nil for a map without that axis.
            let columnLabels: [String]?
            let rowLabels: [String]?
            let cells: [[Cell]]
            /// Every cell has room for two numbers: this ROM's and the other ROM's.
            let twoNumbers: Bool
            /// What stands under the map to say what the rings mean: "none", "changes", "difference",
            /// "compare" or "compareDifference".
            let legend: String
            /// "4 changed", or "6 cells different" while another ROM is compared.
            let badge: String?
            let readOnly: Bool
            /// The lowest and the highest value on show, with the unit after the highest.
            let lowText: String
            let highText: String
        }

        /// A RomRaider switch (`ROMEditor.SwitchLook`): no table, one of a few fixed positions.
        struct Switch: Encodable {
            let description: String
            /// The position this ROM is in, or nil when its bytes are none of the switch's.
            let state: String?
            /// The position it was in when the ROM was opened, and that the other ROM is in, when that is another one.
            let openedState: String?
            let otherState: String?
            /// The colour of the position's tag on the heat scale. Nil for a ROM in neither position.
            let color: String?
        }

        /// The map's name in the definition, with any spaces at its end: what every action takes.
        let id: String
        let title: String
        /// One of these two, or neither for a map that could not be read: `error` says why then.
        let table: Table?
        let toggle: Switch?
        let error: String?
        /// What the cells show: "now", "asOpened" or "difference", and while another ROM is
        /// compared "both", "thisROM", "otherROM" or "difference".
        let shows: String
        let compareShows: String
        /// The 3D view, in place of the table, and whether it writes each number on its tile.
        let surface: Bool
        let numbers: Bool
        /// A map with rows and columns has a 3D view.
        let canShowSurface: Bool
        /// Something in it is not what it was when the ROM was opened.
        let isChanged: Bool
    }

    /// How one open map's 3D view is turned, in degrees, and how tall it draws the highest value.
    /// Slice `rom.angles`. They are apart from `rom.maps` because they change while nothing else
    /// of a map does, and a map's cells are a lot to send again.
    struct ROMAngles: Encodable {
        let id: String
        let turn: Double
        let tilt: Double
        let height: Double
    }

    /// The selected cells, which are in the selected map, and the strip under it. Slice `rom.selection`.
    struct ROMSelection: Encodable {
        /// The cell the selection ends on (`ROMEditor.CellDetail`).
        struct Detail: Encodable {
            /// "4000 RPM × 410"
            let place: String
            let now: String
            let units: String
            /// What the cell held when the ROM was opened and the difference, for a cell that is not as it was.
            let opened: String?
            let difference: String?
            /// What the other ROM holds, while one is compared and it differs.
            let other: String?
            let comparing: Bool
            /// "Stored as 0x00D3 at 0x0C0F42"
            let stored: String
            let count: Int
            let canPutBack: Bool
        }

        let map: String?
        /// Row and column in turn: [row, column, row, column, …].
        let cells: [Int]
        /// The row and the column of the cell the selection ends on.
        let cursor: [Int]?
        let detail: Detail?
    }

    /// The Changes panel. Slice `rom.changes`. Empty while the panel is not on show.
    struct ROMChanges: Encodable {
        struct Line: Encodable {
            /// The cell to go to. Nil for a value on an axis.
            let row: Int?
            let column: Int?
            let place: String
            let was: String
            let now: String
            let raised: Bool
        }

        struct Group: Encodable {
            let id: String
            let title: String
            let units: String
            let lines: [Line]
            /// How many more lines there are than these.
            let more: Int
        }

        let groups: [Group]
        /// How many more maps changed than `groups` lists.
        let more: Int
        /// What changed in no map.
        let otherBytes: String?
    }

    /// What the workspace shows while the ROM itself is selected. Slice `rom.overview`. Empty while it is not.
    struct ROMOverview: Encodable {
        struct Row: Encodable {
            let label: String
            let value: String
            /// A code, shown in the font of the numbers.
            let isCode: Bool
        }

        struct Suggestion: Encodable {
            let id: String
            /// "AZ1G201G · ECU 6644D87207"
            let label: String
        }

        /// One line of the Bytes card: where it starts, sixteen bytes, and the same bytes as text.
        struct ByteLine: Encodable {
            let offset: String
            let hex: String
            let text: String
        }

        let file: [Row]
        /// Where the definitions came from ("from the SubieScope repository", or a file's name). Empty while there are none.
        let definitionsSource: String
        let definitionsError: String?
        let suggestions: [Suggestion]
        let bytes: [ByteLine]
        /// Why the last "Show" or "Apply" of the Bytes card did nothing.
        let bytesError: String?
    }

    func registerROM() {
        let editor = ROMEditor.shared

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
            typealias View = ROMEditor.MapView
            return ROMState(
                isOpen: editor.isOpen, session: editor.session, fileName: editor.fileName,
                identity: editor.identityText, saved: editor.savedText, isEdited: editor.isEdited, size: editor.sizeText,
                status: editor.status, statusIsProblem: editor.statusIsProblem,
                checksums: .init(state: editor.checksumState.rawValue, short: editor.checksumShortText, text: editor.checksumText),
                definitions: .init(state: editor.definitionsState.rawValue, loading: editor.loadingDefs,
                                   text: editor.definitionsText, summary: editor.definitionsSummary),
                undo: .init(can: editor.canUndo, label: editor.history.undoLabel),
                redo: .init(can: editor.canRedo, label: editor.history.redoLabel),
                hasChanges: editor.hasChanges, changesSummary: editor.changesSummary, showsChanges: editor.showsChanges,
                compare: editor.isComparing ? .init(other: editor.otherName, calibration: editor.compareCalibrationText,
                                                    warning: editor.compareWarning, summary: editor.compareSummary) : nil,
                overview: editor.focus == .overview, selectedMap: editor.selectedMap, revealCount: editor.revealCount,
                fineStep: editor.fineStepText, coarseStep: editor.coarseStepText, value: editor.valueText,
                canEditCells: editor.canEditCells, editingNote: editor.editingNote,
                surface: .init(turn: [View.turnRange.lowerBound, View.turnRange.upperBound],
                               tilt: [View.tiltRange.lowerBound, View.tiltRange.upperBound],
                               height: [View.heightRange.lowerBound, View.heightRange.upperBound]),
                heatScale: stride(from: 0.0, through: 1.0, by: 0.125).map { ROMHeatScale.color(at: $0).css })
        }

        // A ROM has a few hundred maps. Only those of the categories that are folded open are sent.
        slice("rom.tree") { () -> ROMTreeState in
            ROMTreeState(
                mapCount: editor.mapCount, changedMapCount: editor.changedMapCount, differentMapCount: editor.differentMapCount,
                listing: editor.listing.rawValue, filter: editor.filterText, note: editor.treeNote,
                categories: editor.tree.map { category in
                    .init(name: category.name, countText: category.countText, hasChanges: category.hasChanges,
                          isExpanded: category.isExpanded,
                          maps: !category.isExpanded ? [] : category.maps.map {
                              .init(id: $0.id, title: $0.title, dimension: $0.dimension, changed: $0.changed,
                                    different: $0.different, isOpen: $0.isOpen, isSelected: $0.isSelected)
                          })
                })
        }

        slice("rom.maps") { () -> [ROMMapWindow] in
            editor.openMaps.map { name in
                let view = editor.view(of: name)
                let look = editor.look(of: name)
                let toggle = look == nil ? editor.switchLook(of: name) : nil
                return ROMMapWindow(
                    id: name, title: look?.title ?? toggle?.title ?? name.trimmingCharacters(in: .whitespaces),
                    table: look.map { Bridge.romTable($0, withPlaces: view.surface) },
                    toggle: toggle.map { Bridge.romSwitch($0) },
                    error: look == nil && toggle == nil ? (editor.tableErrors[name] ?? "This map could not be read from the ROM.") : nil,
                    shows: view.shows.rawValue, compareShows: view.compareShows.rawValue,
                    surface: view.surface, numbers: view.numbers, canShowSurface: editor.canShowSurface(name),
                    isChanged: editor.changedCounts[name] != nil)
            }
        }

        slice("rom.angles") { () -> [ROMAngles] in
            editor.openMaps.map { name in
                let view = editor.view(of: name)
                return ROMAngles(id: name, turn: view.turn, tilt: view.tilt, height: view.height)
            }
        }

        slice("rom.selection") { () -> ROMSelection in
            let cells = editor.selection.sorted { ($0.row, $0.column) < ($1.row, $1.column) }
            return ROMSelection(
                map: editor.selectedMap, cells: cells.flatMap { [$0.row, $0.column] },
                cursor: editor.cursor.map { [$0.row, $0.column] },
                detail: editor.cellDetail.map {
                    .init(place: $0.place, now: $0.now, units: $0.units, opened: $0.opened, difference: $0.difference,
                          other: $0.other, comparing: $0.comparing, stored: $0.stored, count: $0.count, canPutBack: $0.canPutBack)
                })
        }

        // The list can run to thousands of lines, and the panel is shut most of the time.
        slice("rom.changes") { () -> ROMChanges in
            guard editor.showsChanges, !editor.isComparing else { return ROMChanges(groups: [], more: 0, otherBytes: nil) }
            return ROMChanges(
                groups: editor.changeGroups.map { group in
                    .init(id: group.id, title: group.title, units: group.units,
                          lines: group.lines.map {
                              .init(row: $0.cell?.row, column: $0.cell?.column, place: $0.place, was: $0.was, now: $0.now, raised: $0.raised)
                          },
                          more: group.more)
                },
                more: editor.changeGroupsMore, otherBytes: editor.changesOtherBytesText)
        }

        slice("rom.overview") { () -> ROMOverview in
            guard editor.isOpen, editor.focus == .overview else {
                return ROMOverview(file: [], definitionsSource: "", definitionsError: nil, suggestions: [], bytes: [], bytesError: nil)
            }
            return ROMOverview(
                file: editor.fileRows.map { .init(label: $0.label, value: $0.value, isCode: $0.isCode) },
                definitionsSource: editor.defs == nil ? "" : editor.defsSource, definitionsError: editor.definitionsError,
                suggestions: editor.recommendations.map { .init(id: $0.identity.xmlID, label: ROMEditor.label(of: $0)) },
                bytes: editor.byteLines().map { .init(offset: $0.offset, hex: $0.hex, text: $0.text) },
                bytesError: editor.bytesError)
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
        // The toolbar's button says what a read needs and asks first. The card's button has said it already.
        romAction("rom.askToRead") { [model] _ in editor.askToReadFromCar(model) }
        romAction("rom.readFromCar") { [model] _ in
            Task { await editor.readFromCar(model) }
        }
        action("rom.stopRead") { [model] _ in model.cancelROMRead() }

        // MARK: Files

        // The four below that ask for a file take the file of a `path` and ask nothing when there is
        // one, which is how the page is driven where nobody can answer a dialog.
        romAction("rom.open") { arguments in
            if let url = Bridge.romFile(arguments) { editor.open(url) } else { editor.openROM() }
        }
        romAction("rom.saveAs") { arguments in
            if let url = Bridge.romFile(arguments) { editor.save(to: url) } else { editor.saveAs() }
        }
        romAction("rom.compare") { arguments in
            if let url = Bridge.romFile(arguments) { editor.compare(with: url) } else { editor.compareWithROM() }
        }
        romAction("rom.openDefinitions") { arguments in
            if let url = Bridge.romFile(arguments) { editor.openDefinitions(url) } else { editor.openDefinitions() }
        }
        // The toolbar's Compare button: asks for the other file, or stops comparing.
        romAction("rom.toggleCompare") { _ in editor.toggleComparing() }
        romAction("rom.stopCompare") { _ in editor.stopComparing() }
        romAction("rom.getDefinitions") { _ in
            Task { await editor.autoLoadDefinitions() }
        }
        romAction("rom.useDefinition") { arguments in
            guard let id = arguments.string("id") else { return }
            editor.applyRecommendation(id)
        }
        romAction("rom.correctChecksums") { _ in editor.correctChecksums() }

        // MARK: The tree and the workspace

        // What is typed in the tree's filter and in the toolbar's fields is the editor's, as the
        // Mac's fields are bound to it.
        romAction("rom.type") { arguments in
            let text = arguments.string("text") ?? ""
            switch arguments.string("field") {
            case "filter": editor.filterText = text
            case "fineStep": editor.fineStepText = text
            case "coarseStep": editor.coarseStepText = text
            case "value": editor.valueText = text
            default: break
            }
        }
        romAction("rom.list") { arguments in
            guard let listing = arguments.string("listing").flatMap(ROMEditor.Listing.init(rawValue:)) else { return }
            editor.list(listing)
        }
        romAction("rom.toggleCategory") { arguments in
            guard let name = arguments.string("name") else { return }
            editor.toggleCategory(name)
        }
        romAction("rom.showOverview") { _ in editor.showOverview() }
        // With a `row` and a `column` the map opens on that cell: a line of the Changes panel was clicked.
        romAction("rom.openMap") { arguments in
            guard let name = arguments.string("map") else { return }
            if let cell = Bridge.romCell(arguments) { editor.openMap(name, at: cell) } else { editor.openMap(name) }
        }
        romAction("rom.selectMap") { arguments in
            guard let name = arguments.string("map") else { return }
            editor.selectMap(name)
        }
        romAction("rom.closeMap") { arguments in
            guard let name = arguments.string("map") else { return }
            editor.closeMap(name)
        }
        romAction("rom.showChanges") { arguments in editor.showsChanges = arguments.bool("on") }

        // MARK: How a map is looked at

        romAction("rom.show") { arguments in
            guard let name = arguments.string("map"), let shows = arguments.string("shows").flatMap(ROMEditor.Shows.init(rawValue:)) else { return }
            editor.show(shows, in: name)
        }
        romAction("rom.showCompared") { arguments in
            guard let name = arguments.string("map"),
                  let shows = arguments.string("shows").flatMap(ROMEditor.CompareShows.init(rawValue:)) else { return }
            editor.show(shows, in: name)
        }
        romAction("rom.surface") { arguments in
            guard let name = arguments.string("map") else { return }
            editor.setSurface(arguments.bool("on"), for: name)
        }
        // The toolbar's 3D button, which works on the selected map.
        romAction("rom.toggleSurface") { _ in editor.toggleSurface() }
        romAction("rom.numbers") { arguments in
            guard let name = arguments.string("map") else { return }
            editor.setNumbers(arguments.bool("on"), for: name)
        }
        // The page turns the 3D view by itself while it is dragged, and says here where it ended.
        romAction("rom.angles") { arguments in
            guard let name = arguments.string("map") else { return }
            editor.setAngles(turn: arguments.double("turn"), tilt: arguments.double("tilt"), for: name)
            if let height = arguments.double("height") { editor.setHeight(height, for: name) }
        }
        romAction("rom.resetView") { arguments in
            guard let name = arguments.string("map") else { return }
            editor.resetView(of: name)
        }

        // MARK: Selecting and changing cells

        romAction("rom.selectCell") { arguments in
            guard let name = arguments.string("map"), let cell = Bridge.romCell(arguments) else { return }
            editor.selectCell(cell, in: name, extending: arguments.bool("extending"))
        }
        romAction("rom.move") { arguments in
            editor.moveSelection(rows: arguments.int("rows") ?? 0, columns: arguments.int("columns") ?? 0,
                                 extending: arguments.bool("extending"))
        }
        // With a `map` that one is selected first: its own Edit menu asked.
        romAction("rom.selectAll") { arguments in
            if let name = arguments.string("map") { editor.selectMap(name) }
            editor.selectAllCells()
        }
        romAction("rom.copy") { _ in editor.copySelection() }
        romAction("rom.step") { arguments in
            editor.step(arguments.string("size") == "coarse" ? .coarse : .fine, up: arguments.bool("up"))
        }
        // With a `text` that is the number: it was typed into the selected cells. Without, the Value field's.
        romAction("rom.set") { arguments in editor.setSelection(to: arguments.string("text")) }
        romAction("rom.multiply") { _ in editor.multiplySelection() }
        romAction("rom.putBack") { _ in editor.putBackSelection() }
        romAction("rom.putBackMap") { arguments in
            guard let name = arguments.string("map") else { return }
            editor.putBackMap(name)
        }
        romAction("rom.putEverythingBack") { _ in editor.putEverythingBack() }
        romAction("rom.undo") { _ in editor.undo() }
        romAction("rom.redo") { _ in editor.redo() }

        // MARK: Bytes

        romAction("rom.showOffset") { arguments in
            editor.applyGoto(arguments.string("offset") ?? "")
        }
        romAction("rom.writeBytes") { arguments in
            editor.applyEdit(offset: arguments.string("offset") ?? "", bytes: arguments.string("bytes") ?? "")
        }
    }

    /// Something a person does in the ROM editor, which is only there in Advanced mode. Every one
    /// waits its turn, so they happen in the order they were asked for, and a question or a file
    /// dialog comes up after the page's message has been dealt with, not in the middle of it.
    private func romAction(_ name: String, _ handler: @escaping @MainActor (Arguments) -> Void) {
        action(name) { [model] arguments in
            Task { @MainActor in
                guard model.advancedMode else { return }
                handler(arguments)
            }
        }
    }

    /// The file an action came with, in place of asking for one.
    private static func romFile(_ arguments: Arguments) -> URL? {
        arguments.string("path").map { URL(fileURLWithPath: $0) }
    }

    private static func romCell(_ arguments: Arguments) -> ROMTable.Cell? {
        guard let row = arguments.int("row"), let column = arguments.int("column") else { return nil }
        return ROMTable.Cell(row: row, column: column)
    }

    /// A map of numbers the way the page draws it. The colours are the heat scale's own, so a cell
    /// has the same colour here as in the Mac app.
    private static func romTable(_ look: ROMEditor.MapLook, withPlaces: Bool) -> ROMMapWindow.Table {
        ROMMapWindow.Table(
            description: look.description, rows: look.rows, columns: look.columns,
            columnTitle: look.columnTitle, rowTitle: look.rowTitle, valueTitle: look.valueTitle,
            columnLabels: look.columnLabels, rowLabels: look.rowLabels,
            cells: look.cells.map { row in
                row.map { cell in
                    var color: String?, fill: String?
                    switch cell.fill {
                    case .heat(let heat): color = heat.css
                    case .raised: fill = "raised"
                    case .lowered: fill = "lowered"
                    case .plain: fill = "plain"
                    }
                    // Four decimals are finer than a tile's height is drawn.
                    return .init(text: cell.text, below: cell.below, color: color, fill: fill,
                                 mark: cell.mark == .none ? nil : cell.mark.rawValue, note: cell.note,
                                 place: withPlaces ? (cell.place * 10_000).rounded() / 10_000 : nil)
                }
            },
            twoNumbers: look.twoNumbers, legend: look.legend.rawValue, badge: look.badge, readOnly: look.readOnly,
            lowText: look.lowText, highText: look.highText)
    }

    /// A switch the way the page shows it. Its tag has the colour the Mac's window gives it: the
    /// middle of the heat scale for "on", and its lowest colour for any other position.
    private static func romSwitch(_ look: ROMEditor.SwitchLook) -> ROMMapWindow.Switch {
        ROMMapWindow.Switch(description: look.description, state: look.state, openedState: look.openedState,
                            otherState: look.otherState,
                            color: look.state.map { ROMHeatScale.color(at: $0 == "on" ? 0.5 : 0).css })
    }

    /// The ROM warnings say "your Mac" (they are SSMKit's, and the same in the Mac app and the command line tool).
    static func romText(_ text: String) -> String {
        text.replacingOccurrences(of: "your Mac", with: "your \(Bridge.computer)")
    }
}
#endif
