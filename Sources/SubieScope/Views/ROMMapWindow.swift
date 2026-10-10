import SSMKit
import SwiftUI

/// One open map in the workspace, as a window of its own: a title bar with the map's menus and the
/// switch for what its cells show, the table (or the 3D view) with its axes, what the rings mean,
/// and, for the selected map, a strip that describes the selected cell.
struct ROMMapWindow: View {
    let editor: ROMEditor
    let name: String
    /// The number being typed into the selected cells.
    let typed: String
    /// A cell was clicked, or a drag reached it. The second value says whether that extends the selection.
    let onCell: (ROMTable.Cell, Bool) -> Void

    /// The table is wider than the window and scrolls sideways. The table finds that out when it
    /// is laid out, and the line under it that says so needs to know.
    @State private var tableScrolls = false

    private var isSelected: Bool { editor.selectedMap == name }

    var body: some View {
        let look = editor.look(of: name)
        let view = editor.view(of: name)
        VStack(spacing: 0) {
            titleBar(look, view)
            if let look {
                if view.surface {
                    ROMSurfaceView(editor: editor, name: name, look: look, selection: isSelected ? editor.selection : []) { onCell($0, false) }
                } else {
                    table(look)
                }
            } else if let look = editor.switchLook(of: name) {
                switchBody(look)
            } else {
                Label(editor.tableErrors[name] ?? "This map could not be read from the ROM.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(ROMStyle.orangeText.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .background(ROMStyle.window.color)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(isSelected ? ROMStyle.selectionRing.opacity(0.75) : ROMStyle.hairline, lineWidth: isSelected ? 1.5 : 1))
    }

    // MARK: Title bar

    /// The title bar is one row where there is room for it. Next to the Changes panel, or in a
    /// narrow window, the switches go on a row of their own, so that nothing in it is cut short.
    private func titleBar(_ look: ROMEditor.MapLook?, _ view: ROMEditor.MapView) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                titleItems(look, view)
                Spacer(minLength: 8)
                switches(look, view)
                closeButton(look)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    titleItems(look, view)
                    Spacer(minLength: 8)
                    closeButton(look)
                }
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    switches(look, view)
                }
            }
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 6)
        .background(ROMStyle.titleBar.color)
        .contentShape(Rectangle())
        .onTapGesture { editor.selectMap(name) }
    }

    @ViewBuilder
    private func titleItems(_ look: ROMEditor.MapLook?, _ view: ROMEditor.MapView) -> some View {
        Text(look?.title ?? name.trimmingCharacters(in: .whitespaces))
            .font(.system(size: 13, weight: .bold))
            .lineLimit(1)
            .help(look?.description ?? "")
        if let badge = look?.badge { ROMBadge(text: badge, isCompare: editor.isComparing) }
        if look?.readOnly == true {
            Label("read-only", systemImage: "lock.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
                .help("This map's definition has no way back from a value to bytes, so its cells cannot be changed.")
        }
        if look != nil {
            HStack(spacing: 2) {
                tableMenu(view)
                editMenu
                viewMenu(view)
            }
        }
    }

    /// Table or 3D, and what the cells of the table show.
    @ViewBuilder
    private func switches(_ look: ROMEditor.MapLook?, _ view: ROMEditor.MapView) -> some View {
        if look != nil {
            if editor.canShowSurface(name) {
                ROMSegments(options: [.init(value: false, title: "Table"), .init(value: true, title: "3D")], selection: view.surface) {
                    editor.setSurface($0, for: name)
                }
                .help("Show this map as a table or in 3D")
            }
            if !view.surface {
                if editor.isComparing {
                    ROMSegments(options: ROMEditor.CompareShows.allCases.map { .init(value: $0, title: $0.title) }, selection: view.compareShows) {
                        editor.show($0, in: name)
                    }
                } else {
                    ROMSegments(options: ROMEditor.Shows.allCases.map { .init(value: $0, title: $0.title) }, selection: view.shows) {
                        editor.show($0, in: name)
                    }
                }
            }
        }
    }

    private func closeButton(_ look: ROMEditor.MapLook?) -> some View {
        let title = look?.title ?? name.trimmingCharacters(in: .whitespaces)
        return Button { editor.closeMap(name) } label: {
            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Close \(title)")
        .accessibilityLabel("Close \(title)")
    }

    private func menu<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        Menu(content: content) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 7).frame(height: 22).contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func tableMenu(_ view: ROMEditor.MapView) -> some View {
        menu("Table") {
            Button("Show as a Table") { editor.setSurface(false, for: name) }.disabled(!view.surface)
            Button("Show in 3D") { editor.setSurface(true, for: name) }.disabled(view.surface || !editor.canShowSurface(name))
            Divider()
            Button("Put This Map Back as Opened") { editor.putBackMap(name) }
                .disabled(editor.isComparing || editor.changedCounts[name] == nil)
            Divider()
            Button("Close") { editor.closeMap(name) }
        }
    }

    /// The Edit menu works on the selected cells, which are in the selected map: in another map's
    /// window there is nothing for it to work on until a cell there is clicked.
    private var editMenu: some View {
        let ready = isSelected && editor.canEditCells && !editor.selection.isEmpty
        return menu("Edit") {
            Button(editor.history.undoLabel.map { "Undo \($0)" } ?? "Undo") { editor.undo() }.disabled(!editor.canUndo)
            Button(editor.history.redoLabel.map { "Redo \($0)" } ?? "Redo") { editor.redo() }.disabled(!editor.canRedo)
            Divider()
            Button("Select All Cells") { editor.selectMap(name); editor.selectAllCells() }
            Button("Copy the Selected Cells") { editor.copySelection() }.disabled(!isSelected || editor.selection.isEmpty)
            Divider()
            Button("Raise by the Fine Step") { editor.step(.fine, up: true) }.disabled(!ready)
            Button("Lower by the Fine Step") { editor.step(.fine, up: false) }.disabled(!ready)
            Button("Raise by the Coarse Step") { editor.step(.coarse, up: true) }.disabled(!ready)
            Button("Lower by the Coarse Step") { editor.step(.coarse, up: false) }.disabled(!ready)
            Button("Set to the Value") { editor.setSelection() }.disabled(!ready)
            Button("Multiply by the Value") { editor.multiplySelection() }.disabled(!ready)
            Divider()
            Button("Put the Selected Cells Back as Opened") { editor.putBackSelection() }
                .disabled(!isSelected || editor.cellDetail?.canPutBack != true)
        }
    }

    private func viewMenu(_ view: ROMEditor.MapView) -> some View {
        menu("View") {
            if editor.isComparing {
                ForEach(ROMEditor.CompareShows.allCases, id: \.self) { shows in
                    Toggle(shows.title, isOn: Binding(get: { view.compareShows == shows }, set: { _ in editor.show(shows, in: name) }))
                }
            } else {
                ForEach(ROMEditor.Shows.allCases, id: \.self) { shows in
                    Toggle(shows.title, isOn: Binding(get: { view.shows == shows }, set: { _ in editor.show(shows, in: name) }))
                }
                Divider()
                Button(editor.showsChanges ? "Hide the Changes Panel" : "Show the Changes Panel") { editor.showsChanges.toggle() }
            }
        }
    }

    // MARK: A switch

    /// A RomRaider switch is no table: the ROM is in one of its positions. The window says which,
    /// and that it cannot be changed here.
    private func switchBody(_ look: ROMEditor.SwitchLook) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(look.state?.uppercased() ?? "NEITHER")
                    .font(ROMStyle.mono(12, .bold)).foregroundStyle(ROMStyle.cellText)
                    .padding(.horizontal, 10).frame(height: 23)
                    .background(RoundedRectangle(cornerRadius: 5).fill(look.state == nil ? ROMStyle.legendFill : Color(ROMHeatScale.color(at: look.state == "on" ? 0.5 : 0))))
                Text(look.state.map { "This switch is \($0) in this ROM." }
                     ?? "This ROM is in neither of this switch's positions: the bytes it holds here are something else.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let opened = look.openedState {
                Text("It was \(opened) when this ROM was opened.").foregroundStyle(ROMStyle.orangeText.color)
            }
            if let other = look.otherState {
                Text("In the other ROM it is \(other).").foregroundStyle(ROMStyle.purpleText.color)
            }
            if !look.description.isEmpty {
                Text(look.description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("A switch is not a table of numbers: the ROM holds one of a few fixed sets of bytes for it. SubieScope shows which one, and cannot change a switch yet.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
    }

    // MARK: The table

    private func table(_ look: ROMEditor.MapLook) -> some View {
        let height = ROMGridMetrics.height(of: look)
        // The axis name beside the rows takes room on the left. The rest is kept clear of it.
        let indent: CGFloat = look.rowTitle == nil ? 0 : 22
        return VStack(alignment: .leading, spacing: 6) {
            if isSelected, !look.description.isEmpty {
                Text(look.description)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let title = look.columnTitle {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, indent)
            }
            HStack(spacing: 6) {
                if let title = look.rowTitle {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: height)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 16, height: height)
                }
                GeometryReader { geometry in
                    grid(look, ROMGridMetrics(look: look, available: geometry.size.width), width: geometry.size.width)
                }
                .frame(height: height)
            }
            if tableScrolls {
                Label("This map is wider than the window. Scroll sideways to see the rest of it.", systemImage: "arrow.left.and.right")
                    .font(.system(size: 11.5)).foregroundStyle(ROMStyle.orangeText.color)
                    .lineLimit(1)
                    .padding(.leading, indent)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    valueTitle(look)
                    Spacer(minLength: 8)
                    legend(look.legend)
                }
                VStack(alignment: .leading, spacing: 4) {
                    valueTitle(look)
                    legend(look.legend)
                }
            }
            .padding(.leading, indent)
            if isSelected, let detail = editor.cellDetail {
                strip(detail).padding(.leading, indent)
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
    }

    /// The table itself. One that is wider than the window scrolls sideways: the labels in front
    /// of its rows stay where they are, it says so under it, and it keeps the selected cell in view.
    /// A changed cell must not sit unseen past the edge.
    @ViewBuilder
    private func grid(_ look: ROMEditor.MapLook, _ metrics: ROMGridMetrics, width: CGFloat) -> some View {
        let cursor = isSelected ? editor.cursor : nil
        Group {
            if metrics.scrolls {
                HStack(spacing: 0) {
                    if look.rowLabels != nil { part(.rowLabels, look, metrics) }
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 0) {
                                part(.cells, look, metrics)
                                // A marker under each column, for the scroll view to bring one into view by.
                                HStack(spacing: 0) {
                                    ForEach(0..<look.columns, id: \.self) { column in
                                        Color.clear.frame(width: metrics.cellWidth + ROMGridMetrics.gap, height: 0).id(column)
                                    }
                                }
                                .padding(.leading, look.rowLabels == nil ? metrics.left : ROMGridMetrics.inset)
                            }
                        }
                        .onChange(of: cursor) { _, cursor in
                            guard let cursor else { return }
                            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(cursor.column) }
                        }
                        .onAppear {
                            guard let cursor else { return }
                            proxy.scrollTo(cursor.column)
                        }
                    }
                }
            } else {
                // A table that is narrower than the window stands in the middle of it.
                part(.whole, look, metrics).frame(width: width)
            }
        }
        .onChange(of: metrics.scrolls, initial: true) { _, scrolls in tableScrolls = scrolls }
    }

    private func part(_ part: ROMMapGrid.Part, _ look: ROMEditor.MapLook, _ metrics: ROMGridMetrics) -> some View {
        // A map without labels in front of its rows has nothing to keep still: its cells are the whole of it.
        ROMMapGrid(look: look, metrics: metrics, part: part == .cells && look.rowLabels == nil ? .whole : part,
                   selection: isSelected ? editor.selection : [], cursor: isSelected ? editor.cursor : nil,
                   typed: isSelected ? typed : "", onCell: onCell)
    }

    private func valueTitle(_ look: ROMEditor.MapLook) -> some View {
        Text(look.valueTitle).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
    }

    @ViewBuilder
    private func legend(_ legend: ROMEditor.MapLook.Legend) -> some View {
        HStack(spacing: 12) {
            switch legend {
            case .none:
                EmptyView()
            case .changes:
                legendItem(ROMLegendSample(mark: .raised), "raised")
                legendItem(ROMLegendSample(mark: .lowered), "lowered since this ROM was opened")
            case .difference:
                legendItem(ROMLegendSample(mark: .raised, fill: ROMStyle.raisedFill, triangle: false), "raised")
                legendItem(ROMLegendSample(mark: .lowered, fill: ROMStyle.loweredFill, triangle: false), "lowered")
                legendItem(ROMLegendSample(mark: .none, fill: ROMStyle.plainCell.color), "as opened")
            case .compare:
                legendItem(ROMLegendSample(mark: .different), "A cell that is different: this ROM on top, the other ROM below it")
            case .compareDifference:
                legendItem(ROMLegendSample(mark: .raised, fill: ROMStyle.raisedFill, triangle: false), "higher in this ROM")
                legendItem(ROMLegendSample(mark: .lowered, fill: ROMStyle.loweredFill, triangle: false), "lower in this ROM")
                legendItem(ROMLegendSample(mark: .none, fill: ROMStyle.plainCell.color), "the same")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    private func legendItem(_ sample: ROMLegendSample, _ text: String) -> some View {
        HStack(spacing: 4) {
            sample
            Text(text)
        }
    }

    /// The strip under the selected map: where the selected cell is, what it holds now and held when
    /// the ROM was opened, where the ROM keeps it, and the way back. It takes a second line where
    /// one is not enough.
    private func strip(_ detail: ROMEditor.CellDetail) -> some View {
        ROMFlow(spacing: 18, lineSpacing: 5) {
            Text(detail.place).fontWeight(.bold)
            ROMCellNumbers(detail: detail)
            if !detail.stored.isEmpty { Text(detail.stored).foregroundStyle(.secondary) }
            if detail.count > 1 { Text("\(detail.count) cells selected").foregroundStyle(.secondary) }
            if let note = editor.editingNote { Text(note).foregroundStyle(.secondary) }
            if !editor.isComparing {
                Button(detail.count > 1 ? "Put back as opened (\(detail.count))" : "Put back as opened") { editor.putBackSelection() }
                    .buttonStyle(ROMButtonStyle(kind: .quiet, height: 22, horizontalPadding: 9))
                    .disabled(!detail.canPutBack)
                    .help("Give the selected cells the numbers they had when this ROM was opened")
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(ROMStyle.inset.color))
    }
}
