import AppKit
import SSMKit
import SwiftUI
import UniformTypeIdentifiers

/// Opens a ROM file (a copy of an ECU tune already on the Mac), shows what it is, lets you edit bytes
/// and correct the checksums, and saves to a new file. All of that is file work, which is why it is
/// safe to do without any hardware. The one part that talks to the car is the "Read from car" card,
/// which copies the ROM out of the ECU (see `AppModel+ROM`); nothing here ever writes to the car.
struct ROMView: View {
    @Environment(AppModel.self) private var model
    @State private var rom: ROMImage?
    @State private var fileName = ""
    @State private var sourceURL: URL?
    @State private var dirty = false
    @State private var report: SubaruChecksum.Report?
    @State private var noLayout = false
    @State private var status: String?
    @State private var showFullDisclaimer = false

    // Byte editor
    @State private var gotoOffsetText = "0"
    @State private var viewOffset = 0
    @State private var editOffsetText = ""
    @State private var editBytesText = ""
    @State private var editError: String?

    // Maps (RomRaider definitions)
    @State private var defs: ROMDefinitionSet?
    @State private var matched: ROMDefinition?
    @State private var tableDefs: [ROMTableDef] = []
    @State private var selectedTableName: String?
    @State private var currentTable: ROMTable?
    @State private var mapError: String?
    @State private var recommendations: [ROMDefinition] = []
    @State private var loadingDefs = false
    @State private var defsSource = ""

    private let rowBytes = 16
    private let dumpRows = 16

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                disclaimerCard
                readFromCarCard
                if let rom {
                    identityCard(rom)
                    checksumCard(rom)
                    mapsCard(rom)
                    byteEditorCard(rom)
                } else {
                    emptyState
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { openROM() } label: { Label("Open ROM…", systemImage: "folder") }
                Button { saveAs() } label: { Label("Save As…", systemImage: "square.and.arrow.down") }
                    .disabled(rom == nil)
            }
        }
        .task(id: model.connection) { await model.checkROMReadCapability() }
    }

    // MARK: Read from car

    private var readFromCarCard: some View {
        card("Read from car") {
            Text("Read the ROM straight off the car's engine ECU, then edit it here. It needs an OBDLink (or other STN-based) adapter in OBD-II mode, or a Tactrix OpenPort 2.0. This loads a small helper program into the ECU and copies the flash out. It reads only, and never writes anything back to the car. For the 2008 and later Subarus with a Denso SH7058 ECU, such as the 2008+ STI. This is new and has not been tested on a real car yet.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.romReadInProgress {
                ProgressView(value: model.romReadProgress)
                HStack {
                    Text(model.romReadStatus ?? "Reading…").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .cancel) { model.cancelROMRead() } label: { Text("Stop") }
                }
                Text("This takes several minutes. Keep the ignition ON, leave the engine off, and do not touch the car or unplug the adapter until it finishes.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Before you start: ignition ON, engine OFF, a healthy battery, and do not disturb the car until the read finishes.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { readFromCar() } label: { Label("Read ROM from car", systemImage: "arrow.down.to.line") }
                        .buttonStyle(.borderedProminent)
                        .tint(.scopeBlue)
                        .disabled(!model.canReadROMFromCar)
                    if model.checkingAdapterType { ProgressView().controlSize(.small) }
                    Spacer()
                }
                Text(model.romReadAvailability).font(.callout).foregroundStyle(.secondary)
                if let status = model.romReadStatus {
                    Text(status).font(.callout).foregroundStyle(model.romReadError == nil ? Color.secondary : Color.red)
                }
            }
        }
    }

    private func readFromCar() {
        Task {
            if let loaded = await model.readROMFromCar() {
                loadReadROM(loaded)
            }
        }
    }

    /// Loads a ROM read from the car straight into the editor, as if it had been opened from a file
    /// (but not yet saved to disk, so Save As is encouraged).
    private func loadReadROM(_ loaded: ROMImage) {
        rom = loaded
        let id = loaded.calibrationID() ?? "car"
        fileName = "\(id)-read.bin"
        sourceURL = nil
        dirty = true
        status = "Read from the car. Use Save As… to keep this file before you edit it."
        editError = nil
        viewOffset = 0
        gotoOffsetText = "0"
        selectedTableName = nil
        currentTable = nil
        refreshChecksum()
        if defs == nil {
            Task { await autoLoadDefinitions() }
        } else {
            matchDefinitions()
        }
    }

    // MARK: Disclaimer

    private var disclaimerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(ROMDisclaimer.short, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(ROMDisclaimer.noWriteToCar)
                .font(.subheadline.weight(.medium))
            DisclosureGroup("What you should know before editing a ROM", isExpanded: $showFullDisclaimer) {
                Text(ROMDisclaimer.full)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .tint(.scopeBlue)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35), lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "memorychip")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Open a ROM file to inspect and edit it.")
                .foregroundStyle(.secondary)
            Text("A ROM is a .bin file, for example one read with FastECU or EcuFlash. You can also read it from the car with the card above.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { openROM() } label: { Label("Open ROM…", systemImage: "folder") }
                .buttonStyle(.borderedProminent)
                .tint(.scopeBlue)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: Identity

    private func identityCard(_ rom: ROMImage) -> some View {
        card("File") {
            row("Name", fileName + (dirty ? " (edited, not saved)" : ""))
            row("Size", "\(rom.byteCount) bytes" + (rom.size.map { " · \($0.label)" } ?? " · not a standard Subaru ROM size"))
            row("Calibration ID", rom.calibrationID() ?? "unknown (may not be a Subaru 32-bit ROM)")
            row("Fingerprint", rom.quickFingerprint)
        }
    }

    // MARK: Checksum

    private func checksumCard(_ rom: ROMImage) -> some View {
        card("Checksums") {
            if noLayout {
                Label("No checksum layout is known for this ROM size, so SubieScope can't check or correct it.",
                      systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else if let report {
                if report.allDisabled {
                    Label("This ROM has its checksums disabled.", systemImage: "minus.circle")
                        .foregroundStyle(.secondary)
                } else if report.ok {
                    Label("All checksums match.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("\(report.mismatchCount) of \(activeCount(report)) checksum regions do not match.",
                          systemImage: "xmark.seal.fill")
                        .foregroundStyle(.orange)
                    Text("After editing a map, the checksums no longer add up. Correct them before a ROM is of any use.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button { correctChecksums() } label: {
                        Label("Correct Checksums", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.scopeBlue)
                }
            }
            if let status {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func activeCount(_ report: SubaruChecksum.Report) -> Int {
        report.records.filter { !$0.isBlank }.count
    }

    // MARK: Maps

    private func mapsCard(_ rom: ROMImage) -> some View {
        card("Maps") {
            HStack(spacing: 10) {
                if loadingDefs { ProgressView().controlSize(.small) }
                Button { Task { await autoLoadDefinitions() } } label: { Label("Get Definitions", systemImage: "arrow.down.circle") }
                    .disabled(loadingDefs)
                Button { openDefinitions() } label: { Label("Open Definitions…", systemImage: "doc.badge.gearshape") }
                if !defsSource.isEmpty {
                    Text(defsSource).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text("The definitions let SubieScope show this ROM's maps by name. It downloads RomRaider's ecu_defs.xml from the SubieScope repository (credited to RomRaider), or you can choose your own copy.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let mapError {
                Label(mapError, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }

            if defs != nil {
                if let matched {
                    Text("Matched: \(matched.identity.xmlID)" + (matched.identity.ecuID.map { " · ECU \($0)" } ?? ""))
                        .font(.callout).foregroundStyle(.green)
                    tablePicker
                    if let currentTable {
                        ROMTableGrid(table: currentTable) { r, c, value in editCell(r, c, value) }
                    }
                } else if !recommendations.isEmpty {
                    Text("No exact match for this ROM's internal ID. Closest definitions, pick one only if you are sure it is right:")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(recommendations, id: \.identity.xmlID) { rec in
                        Button {
                            applyRecommendation(rec)
                        } label: {
                            Label("\(rec.identity.xmlID)" + (rec.identity.ecuID.map { " · ECU \($0)" } ?? ""), systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(.link)
                    }
                } else {
                    Label("These definitions have no entry matching this ROM's internal ID.", systemImage: "questionmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var tablePicker: some View {
        let categories = Dictionary(grouping: tableDefs.filter { $0.isEditable }, by: { $0.category.isEmpty ? "Other" : $0.category })
        return HStack {
            Text("Map")
            Picker("Map", selection: Binding(get: { selectedTableName ?? "" }, set: { selectTable($0) })) {
                Text("Choose a map…").tag("")
                ForEach(categories.keys.sorted(), id: \.self) { category in
                    Section(category) {
                        ForEach(categories[category]!.sorted { $0.name < $1.name }, id: \.name) { t in
                            Text(t.name).tag(t.name)
                        }
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 360)
            Spacer()
        }
    }

    // MARK: Byte editor

    private func byteEditorCard(_ rom: ROMImage) -> some View {
        card("Bytes") {
            Text("Edit raw bytes directly. Named map editing (fuel, boost, timing by name) needs the ROM definitions and is the next step.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Go to offset (hex)")
                TextField("0", text: $gotoOffsetText)
                    .frame(width: 100)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyGoto)
                Button("Show", action: applyGoto)
                Spacer()
            }

            hexDump(rom)

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Write bytes").font(.subheadline.weight(.medium))
                HStack {
                    Text("Offset (hex)")
                    TextField("2004", text: $editOffsetText)
                        .frame(width: 90)
                        .textFieldStyle(.roundedBorder)
                    Text("Bytes (hex)")
                    TextField("e.g. 41 42 43", text: $editBytesText)
                        .frame(maxWidth: 220)
                        .textFieldStyle(.roundedBorder)
                    Button("Apply", action: applyEdit)
                }
                if let editError {
                    Text(editError).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func hexDump(_ rom: ROMImage) -> some View {
        let start = max(0, min(viewOffset - (viewOffset % rowBytes), max(0, rom.byteCount - rowBytes)))
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<dumpRows, id: \.self) { r in
                let base = start + r * rowBytes
                if base < rom.byteCount, let bytes = rom.bytes(at: base, length: min(rowBytes, rom.byteCount - base)) {
                    HStack(spacing: 10) {
                        Text(String(format: "%06X", base))
                            .foregroundStyle(.secondary)
                        Text(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
                        Text(String(decoding: bytes.map { (0x20...0x7E).contains($0) ? $0 : UInt8(ascii: ".") }, as: UTF8.self))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    // MARK: Card helpers

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }

    // MARK: Actions

    private func openROM() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose an ECU ROM file (.bin)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try ROMImage(contentsOf: url)
            rom = loaded
            fileName = url.lastPathComponent
            sourceURL = url
            dirty = false
            status = nil
            editError = nil
            viewOffset = 0
            gotoOffsetText = "0"
            selectedTableName = nil
            currentTable = nil
            refreshChecksum()
            if defs == nil {
                Task { await autoLoadDefinitions() }
            } else {
                matchDefinitions()
            }
        } catch {
            status = "Could not open the file: \(error.localizedDescription)"
        }
    }

    /// Downloads (or uses the cached) RomRaider ecu_defs.xml from the SubieScope repo and matches it.
    private func autoLoadDefinitions() async {
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

    private func openDefinitions() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.message = "Choose a RomRaider ecu_defs.xml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
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
        // Auto-apply only on an exact internal-ID match. Otherwise recommend, and let the user confirm.
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
    }

    private func applyRecommendation(_ def: ROMDefinition) {
        guard let defs else { return }
        matched = def
        tableDefs = defs.resolvedTables(forXmlID: def.identity.xmlID)
        recommendations = []
        selectedTableName = nil
        currentTable = nil
        status = "Using definition \(def.identity.xmlID). You chose this; it is not an exact match for the ROM."
    }

    private func selectTable(_ name: String) {
        selectedTableName = name.isEmpty ? nil : name
        refreshTable()
    }

    private func refreshTable() {
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

    private func editCell(_ row: Int, _ column: Int, _ value: Double) {
        guard let rom, let table = currentTable else { return }
        do {
            let edited = try table.write(rom, row: row, column: column, realValue: value)
            self.rom = edited
            dirty = true
            refreshChecksum()
            refreshTable()
            status = "Edited \(table.def.name) at row \(row + 1), column \(column + 1). Correct the checksums before using this ROM."
        } catch {
            mapError = error.localizedDescription
        }
    }

    private func refreshChecksum() {
        guard let rom else { return }
        do {
            if let r = try SubaruChecksum.verifyPetrol(rom) {
                report = r
                noLayout = false
            } else {
                report = nil
                noLayout = true
            }
        } catch {
            report = nil
            noLayout = true
        }
    }

    private func correctChecksums() {
        guard let rom else { return }
        do {
            if let (fixed, r) = try SubaruChecksum.correctPetrol(rom) {
                self.rom = fixed
                report = r
                dirty = true
                status = "Checksums corrected. Save As… to write the new ROM."
            }
        } catch {
            status = "Could not correct the checksums: \(error.localizedDescription)"
        }
    }

    private func applyGoto() {
        if let value = parseHex(gotoOffsetText) {
            viewOffset = value
            editError = nil
        } else {
            editError = "Not a valid hex offset."
        }
    }

    private func applyEdit() {
        guard var rom else { return }
        guard let offset = parseHex(editOffsetText) else { editError = "Offset is not valid hex."; return }
        let hex = editBytesText.filter { !$0.isWhitespace }
        guard !hex.isEmpty, hex.count % 2 == 0 else { editError = "Enter whole bytes, e.g. 41 42 43."; return }
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<next], radix: 16) else { editError = "\(hex[i..<next]) is not a hex byte."; return }
            bytes.append(byte)
            i = next
        }
        guard rom.replace(at: offset, with: bytes) else {
            editError = "Those \(bytes.count) bytes would run past the end of the ROM."
            return
        }
        self.rom = rom
        dirty = true
        editError = nil
        viewOffset = offset
        status = "Wrote \(bytes.count) byte(s) at 0x\(String(offset, radix: 16, uppercase: true)). Checksums need correcting."
        refreshChecksum()
    }

    private func parseHex(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "0x", with: "")
        guard !t.isEmpty else { return nil }
        return Int(t, radix: 16)
    }

    private func saveAs() {
        guard let rom else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        let base = (fileName as NSString).deletingPathExtension
        panel.nameFieldStringValue = base.isEmpty ? "edited.bin" : "\(base)-edited.bin"
        panel.message = "Save the edited ROM to a NEW file; keep the original."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try rom.write(to: url)
            dirty = false
            status = "Saved to \(url.lastPathComponent)."
        } catch {
            status = "Could not save: \(error.localizedDescription)"
        }
    }
}

/// Shows a ROM table as a grid with its axis labels, each cell editable. Commit a cell (Return or
/// click away) to write it back through the scaling. Writing is a file edit; it never touches the car.
struct ROMTableGrid: View {
    let table: ROMTable
    let onEdit: (_ row: Int, _ column: Int, _ value: Double) -> Void

    private var decimals: Int {
        // Derive decimal places from a RomRaider format like "0.00".
        if let dot = table.format.firstIndex(of: ".") {
            return table.format.distance(from: table.format.index(after: dot), to: table.format.endIndex)
        }
        return 0
    }

    private func text(_ v: Double) -> String { String(format: "%.\(decimals)f", v) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(table.def.name).font(.headline)
                if !table.units.isEmpty { Text("(\(table.units))").foregroundStyle(.secondary) }
                if !table.scaling.isWritable {
                    Label("read-only", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !table.def.description.isEmpty {
                Text(table.def.description).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .trailing, horizontalSpacing: 1, verticalSpacing: 1) {
                    if table.def.dimension == .threeD || !table.xLabels.isEmpty {
                        GridRow {
                            Color.clear.frame(width: 54, height: 1).gridCellUnsizedAxes([.horizontal, .vertical])
                            ForEach(Array(table.xLabels.prefix(table.columns).enumerated()), id: \.offset) { _, x in
                                Text(text(x)).font(.caption2).foregroundStyle(.secondary).frame(minWidth: 52)
                            }
                        }
                    }
                    ForEach(0..<table.rows, id: \.self) { r in
                        GridRow {
                            if table.def.dimension == .threeD, r < table.yLabels.count {
                                Text(text(table.yLabels[r])).font(.caption2).foregroundStyle(.secondary).frame(width: 54, alignment: .trailing)
                            } else {
                                Color.clear.frame(width: 54, height: 1).gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                            ForEach(0..<table.columns, id: \.self) { c in
                                ROMCell(value: table.values[r][c], text: text(table.values[r][c]),
                                        editable: table.scaling.isWritable) { newValue in
                                    onEdit(r, c, newValue)
                                }
                            }
                        }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 360)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
        .padding(.top, 4)
    }
}

/// One editable table cell. Keeps its own text while editing; commits on Return or focus loss.
private struct ROMCell: View {
    let value: Double
    let text: String
    let editable: Bool
    let onCommit: (Double) -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .font(.system(.caption, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .frame(minWidth: 52)
            .textFieldStyle(.plain)
            .padding(.vertical, 3).padding(.horizontal, 4)
            .background(focused ? Color.scopeBlue.opacity(0.18) : Color.primary.opacity(0.06))
            .disabled(!editable)
            .focused($focused)
            .onAppear { draft = text }
            .onChange(of: text) { _, newText in if !focused { draft = newText } }
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if let v = Double(trimmed), v != value {
            onCommit(v)
        } else {
            draft = text   // revert bad or unchanged input
        }
    }
}
