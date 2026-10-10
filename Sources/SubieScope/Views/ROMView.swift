import SSMKit
import SwiftUI

/// The ROM editor, laid out the way RomRaider is and in SubieScope's own look: a tree of the ROM's
/// maps on the left, a toolbar over it, and a workspace of the maps that are open, each a table of
/// coloured cells. A cell that is not what it was when the ROM was opened is ringed, so a change is
/// never out of sight.
///
/// The views only draw and pass on what a person does. What is open, selected and changed is all in
/// `ROMEditor`, which the Windows app shows too. Everything here is work on a file: the one part
/// that talks to the car is reading a ROM out of it (see `AppModel+ROM`), and nothing writes to it.
struct ROMView: View {
    @Environment(AppModel.self) private var model
    @State private var editor = ROMEditor.shared
    /// The workspace has the keyboard: the arrow keys move the selected cell, and digits type into it.
    @FocusState private var workspaceFocused: Bool
    /// The number being typed into the selected cells, until Return writes it or Escape drops it.
    @State private var typed = ""

    static let treeWidth: CGFloat = 290
    static let changesWidth: CGFloat = 270

    var body: some View {
        VStack(spacing: 0) {
            ROMToolbar(editor: editor)
            Divider()
            if editor.isOpen {
                if editor.isComparing {
                    ROMCompareBar(editor: editor)
                    Divider()
                }
                HStack(spacing: 0) {
                    ROMTreeView(editor: editor).frame(width: Self.treeWidth)
                    Divider()
                    workspace
                }
                Divider()
                ROMStatusBar(editor: editor)
            } else {
                ROMStartView(editor: editor)
            }
        }
        .task(id: model.connection) { await model.checkROMReadCapability() }
        .onChange(of: editor.selectedMap) { _, _ in typed = "" }
    }

    // MARK: Workspace

    private var workspace: some View {
        HStack(alignment: .top, spacing: 0) {
            if editor.focus == .overview {
                ScrollView { ROMOverview(editor: editor).padding(12) }
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(editor.openMaps, id: \.self) { name in
                                ROMMapWindow(editor: editor, name: name, typed: typed) { cell, extending in
                                    commitTyped()
                                    workspaceFocused = true
                                    editor.selectCell(cell, in: name, extending: extending)
                                }
                                .id(name)
                            }
                        }
                        .padding(12)
                    }
                    // A map that was opened from the tree or the Changes panel comes into view.
                    .onChange(of: editor.revealCount) { _, _ in
                        guard let name = editor.selectedMap else { return }
                        withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo(name, anchor: .top) }
                    }
                }
            }
            if editor.showsChanges, !editor.isComparing {
                ROMChangesPanel(editor: editor)
                    .frame(width: Self.changesWidth)
                    .padding([.vertical, .trailing], 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ROMStyle.workspace.color)
        .focusable()
        .focused($workspaceFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { handle($0) }
    }

    // MARK: Keyboard

    /// The arrow keys move the selected cell (with Shift they select a block), digits type a number
    /// for the selected cells, Return writes it and Escape drops it. Command-A selects the whole map
    /// and Command-C copies the selected cells.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard editor.selectedMap != nil else { return .ignored }
        if press.modifiers.contains(.command) {
            switch press.characters {
            case "a": editor.selectAllCells(); return .handled
            case "c": editor.copySelection(); return .handled
            default: return .ignored
            }
        }
        let extending = press.modifiers.contains(.shift)
        switch press.key {
        case .upArrow: return move(rows: -1, columns: 0, extending)
        case .downArrow: return move(rows: 1, columns: 0, extending)
        case .leftArrow: return move(rows: 0, columns: -1, extending)
        case .rightArrow: return move(rows: 0, columns: 1, extending)
        case .return:
            guard !typed.isEmpty else { return .ignored }
            commitTyped()
            return .handled
        case .escape:
            guard !typed.isEmpty else { return .ignored }
            typed = ""
            return .handled
        case .delete:
            guard !typed.isEmpty else { return .ignored }
            typed.removeLast()
            return .handled
        default:
            // A number is being typed. A comma is taken for the decimal point.
            guard press.characters.count == 1, let character = press.characters.first, "0123456789.,-".contains(character),
                  editor.canEditCells, !editor.selection.isEmpty, typed.count < 12 else { return .ignored }
            typed.append(character)
            return .handled
        }
    }

    private func move(rows: Int, columns: Int, _ extending: Bool) -> KeyPress.Result {
        commitTyped()
        editor.moveSelection(rows: rows, columns: columns, extending: extending)
        return .handled
    }

    /// Writes the number that was typed into the selected cells.
    private func commitTyped() {
        guard !typed.isEmpty else { return }
        let text = typed
        typed = ""
        editor.setSelection(to: text)
    }
}

/// The editor's toolbar: the file, Undo and Redo, RomRaider's ways to change the selected cells
/// (a fine and a coarse step down or up, set to a value, multiply by one), the 3D view, comparing
/// with another ROM, and how the checksums stand.
struct ROMToolbar: View {
    @Environment(AppModel.self) private var model
    @Bindable var editor: ROMEditor

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ROMFlow(spacing: 14, lineSpacing: 8) {
                fileGroup
                if editor.isOpen {
                    if !editor.isComparing {
                        separator
                        undoGroup
                    }
                    if showsEditTools {
                        separator
                        stepGroup("Fine", .fine, ROMStyle.fineButton, down: "chevron.down", up: "chevron.up", text: $editor.fineStepText, width: 52)
                        stepGroup("Coarse", .coarse, ROMStyle.coarseButton, down: "chevron.down.2", up: "chevron.up.2", text: $editor.coarseStepText, width: 46)
                        valueGroup
                    }
                    separator
                    viewGroup
                }
            }
            // The row is the flow's but for the checksums' corner: a spacer here would take half of it.
            .frame(maxWidth: .infinity, alignment: .leading)
            if editor.isOpen { checksumGroup.layoutPriority(1) }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(ROMStyle.panel.color)
    }

    /// The tools that change cells are there while the selected map shows the ROM as it is now.
    /// They have nothing to work on in a view of the past, a view of differences, or another ROM.
    private var showsEditTools: Bool {
        // A switch is selected like a map, and has no cells.
        guard let name = editor.selectedMap, editor.tables[name] != nil, !editor.isComparing else { return false }
        let view = editor.view(of: name)
        return view.surface || view.shows == .now
    }

    private var canChangeCells: Bool { editor.canEditCells && !editor.selection.isEmpty }

    private var separator: some View {
        Rectangle().fill(Color.primary.opacity(0.16)).frame(width: 1, height: 22)
    }

    private var fileGroup: some View {
        HStack(spacing: 6) {
            Button { editor.openROM() } label: { Label("Open", systemImage: "folder") }
                .help("Open a ROM file (.bin)")
            if editor.isOpen {
                Button { editor.saveAs() } label: { Label("Save As", systemImage: "square.and.arrow.down") }
                    .help("Save this ROM as a new file. Keep the original.")
            }
            Button { editor.askToReadFromCar(model) } label: { Label("Read from Car", systemImage: "cpu") }
                .disabled(model.romReadInProgress)
                .help(model.romReadAvailability)
        }
        .buttonStyle(ROMButtonStyle())
    }

    private var undoGroup: some View {
        HStack(spacing: 4) {
            // The shortcuts are only there while there is an edit to take back or put back. Without
            // one, Command-Z stays what it is everywhere else: undo for the text in a field.
            Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 10) }
                .keyboardShortcut(editor.canUndo ? KeyboardShortcut("z", modifiers: [.command]) : nil)
                .disabled(!editor.canUndo)
                .help(editor.history.undoLabel.map { "Undo \($0)" } ?? "Nothing to undo")
                .accessibilityLabel(editor.history.undoLabel.map { "Undo \($0)" } ?? "Undo")
            Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 10) }
                .keyboardShortcut(editor.canRedo ? KeyboardShortcut("z", modifiers: [.command, .shift]) : nil)
                .disabled(!editor.canRedo)
                .help(editor.history.redoLabel.map { "Redo \($0)" } ?? "Nothing to redo")
                .accessibilityLabel(editor.history.redoLabel.map { "Redo \($0)" } ?? "Redo")
        }
        .buttonStyle(ROMButtonStyle())
    }

    private func stepGroup(_ title: String, _ size: ROMEditor.StepSize, _ color: Color, down: String, up: String,
                           text: Binding<String>, width: CGFloat) -> some View {
        let word = title.lowercased()
        return HStack(spacing: 5) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Button { editor.step(size, up: false) } label: { Image(systemName: down).font(.system(size: 11, weight: .bold)).frame(width: 12) }
                .help("Lower the selected cells by the \(word) step")
                .accessibilityLabel("Lower the selected cells by the \(word) step")
            Button { editor.step(size, up: true) } label: { Image(systemName: up).font(.system(size: 11, weight: .bold)).frame(width: 12) }
                .help("Raise the selected cells by the \(word) step")
                .accessibilityLabel("Raise the selected cells by the \(word) step")
            field(text, width: width).accessibilityLabel("\(title) step")
        }
        .buttonStyle(ROMButtonStyle(kind: .filled(color), height: 28, horizontalPadding: 8))
        .disabled(!canChangeCells)
        .help(canChangeCells ? "" : (editor.editingNote ?? "Select the cells to change first."))
    }

    private var valueGroup: some View {
        HStack(spacing: 5) {
            Text("Value").font(.system(size: 12)).foregroundStyle(.secondary)
            field($editor.valueText, width: 64)
                .onSubmit { editor.setSelection() }
                .accessibilityLabel("Value")
            Button("Set") { editor.setSelection() }
                .help("Give the selected cells this value")
            Button("Mul") { editor.multiplySelection() }
                .help("Multiply the selected cells by this value")
        }
        .buttonStyle(ROMButtonStyle(kind: .quiet, height: 28))
        .disabled(!canChangeCells)
    }

    private func field(_ text: Binding<String>, width: CGFloat) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .font(ROMStyle.mono(12, .regular))
            .padding(.horizontal, 8)
            .frame(width: width, height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(ROMStyle.field.color))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.16), lineWidth: 1))
    }

    private var viewGroup: some View {
        HStack(spacing: 6) {
            if let name = editor.selectedMap {
                let isOn = editor.view(of: name).surface
                Button { editor.toggleSurface() } label: { Label("3D", systemImage: "cube") }
                    .buttonStyle(ROMButtonStyle(kind: isOn ? .filled(ROMStyle.primaryButton) : .toolbar))
                    .disabled(!editor.canShowSurface(name))
                    .help(editor.canShowSurface(name) ? "Show the selected map in 3D, or as a table again" : "Only a map with rows and columns has a 3D view")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
            }
            Button { editor.toggleComparing() } label: { Label("Compare", systemImage: "arrow.left.arrow.right") }
                .buttonStyle(ROMButtonStyle(kind: editor.isComparing ? .filled(ROMStyle.purpleButton) : .toolbar))
                .help(editor.isComparing ? "Stop comparing" : "Compare this ROM with another ROM file. Comparing changes neither file.")
                .accessibilityAddTraits(editor.isComparing ? .isSelected : [])
        }
    }

    private var checksumGroup: some View {
        let state = editor.checksumState
        return HStack(spacing: 8) {
            Label(editor.checksumShortText, systemImage: ROMChecksumLabel.symbol(state))
                .font(.system(size: 12))
                .foregroundStyle(ROMChecksumLabel.style(state))
                .lineLimit(1)
                .help(editor.checksumText)
            if state == .mismatch, !editor.isComparing {
                Button("Correct") { editor.correctChecksums() }
                    .buttonStyle(ROMButtonStyle(kind: .filled(ROMStyle.primaryButton), horizontalPadding: 12))
                    .help("Correct the checksums. An ECU rejects a ROM whose checksums are wrong.")
            }
        }
        .fixedSize()
    }
}

/// The bar that says which two files are being compared, with the ways out of it.
struct ROMCompareBar: View {
    let editor: ROMEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                (Text("Comparing").fontWeight(.bold) + Text("  this ROM, ") + Text(editor.fileName).fontWeight(.bold)
                    + Text("  with  ").foregroundStyle(.secondary) + Text(editor.otherName).fontWeight(.bold)
                    + Text(" · \(editor.compareCalibrationText)"))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Choose Another File") { editor.compareWithROM() }
                Button("Stop Comparing") { editor.stopComparing() }
            }
            .buttonStyle(ROMButtonStyle(kind: .quiet, height: 24))
            if let warning = editor.compareWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(ROMStyle.orangeText.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ROMStyle.purpleBar.color)
    }
}

/// The line along the bottom: how much changed since the ROM was opened (or differs from the other
/// ROM), what happened last, and which definitions and what kind of ROM this is.
struct ROMStatusBar: View {
    @Environment(AppModel.self) private var model
    let editor: ROMEditor

    var body: some View {
        HStack(spacing: 18) {
            if editor.isComparing {
                summary(editor.compareSummary, dot: ROMStyle.purple, color: ROMStyle.purpleText.color)
            } else if editor.hasChanges {
                summary(editor.changesSummary, dot: ROMStyle.orange, color: ROMStyle.orangeText.color)
                Button(editor.showsChanges ? "Hide changes" : "Show changes") { editor.showsChanges.toggle() }
                    .buttonStyle(ROMButtonStyle(kind: .quiet, height: 20, horizontalPadding: 8))
                    .help("List every change since this ROM was opened, with the old number first")
            } else {
                Text(editor.changesSummary)
            }
            if model.romReadInProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.romReadStatus ?? "Reading the ROM from the car…")
                }
            } else if let status = editor.status {
                Text(status)
                    .foregroundStyle(editor.statusIsProblem ? AnyShapeStyle(ROMStyle.orangeText.color) : AnyShapeStyle(.secondary))
                    .truncationMode(.tail)
                    .help(status)
            }
            Spacer(minLength: 8)
            Text(editor.definitionsSummary).layoutPriority(1)
            Text(editor.sizeText).layoutPriority(1)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ROMStyle.panel.color)
    }

    private func summary(_ text: String, dot: Color, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(text)
        }
        .foregroundStyle(color)
        .layoutPriority(2)
    }
}
