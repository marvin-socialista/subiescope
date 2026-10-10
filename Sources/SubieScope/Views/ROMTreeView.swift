import SSMKit
import SwiftUI

/// The left side of the ROM editor: the ROM itself as a card, and under it every map of the ROM by
/// category, the way RomRaider lists them. A map that changed since the ROM was opened carries the
/// number of its changed cells in orange, and the list can be cut down to only those.
struct ROMTreeView: View {
    @Bindable var editor: ROMEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerCard
            if editor.mapCount > 0 {
                filterField
                listingSwitch
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let tree = editor.tree
                        ForEach(tree) { category in
                            categoryRow(category)
                            if category.isExpanded {
                                ForEach(category.maps) { map in mapRow(map) }
                            }
                        }
                        if tree.isEmpty, editor.listing == .all {
                            Text("No map has \"\(editor.filterText)\" in its name.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .padding(6)
                        }
                    }
                }
                if let note = editor.treeNote { noteBox(note) }
            } else {
                noteBox(editor.definitionsState == .matched ? "The definitions have no map for this ROM that can be shown."
                        : "\(editor.definitionsText) The card above says more.")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ROMStyle.panel.color)
    }

    /// The ROM itself. A click shows its overview in the workspace.
    private var headerCard: some View {
        let isSelected = editor.focus == .overview
        let needsSaving = editor.isEdited
        let tint: Color = isSelected ? ROMStyle.selectionRing : (needsSaving ? ROMStyle.orange : .primary)
        return Button { editor.showOverview() } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(editor.fileName).fontWeight(.bold).multilineTextAlignment(.leading)
                Text(editor.identityText).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if needsSaving { Circle().fill(ROMStyle.orange).frame(width: 7, height: 7) }
                    Text(editor.savedText)
                }
                .font(.system(size: 12))
                .foregroundStyle(needsSaving ? AnyShapeStyle(ROMStyle.orangeText.color) : AnyShapeStyle(.secondary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(isSelected ? 0.22 : (needsSaving ? 0.14 : 0.06))))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(isSelected ? 1 : (needsSaving ? 0.4 : 0.14)), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show what this ROM is: its file, definitions, checksums and bytes")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var filterField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Filter maps", text: $editor.filterText)
                .textFieldStyle(.plain)
                .accessibilityLabel("Filter maps")
            if !editor.filterText.isEmpty {
                Button { editor.filterText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear the filter")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(ROMStyle.field.color))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(ROMStyle.hairline, lineWidth: 1))
    }

    /// All, or only the maps that changed. While another ROM is compared, only the ones that differ from it.
    private var listingSwitch: some View {
        let narrowed: ROMSegments<ROMEditor.Listing>.Option = editor.isComparing
            ? .init(value: .different, title: "Different \(editor.differentMapCount)", dot: ROMStyle.purple)
            : .init(value: .changed, title: "Changed \(editor.changedMapCount)", dot: ROMStyle.orange)
        return ROMSegments(options: [.init(value: .all, title: "All \(editor.mapCount)"), narrowed],
                         selection: editor.listing, fills: true, height: 24) { editor.list($0) }
    }

    private func categoryRow(_ category: ROMEditor.TreeCategory) -> some View {
        Button { editor.toggleCategory(category.name) } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(category.isExpanded ? 90 : 0))
                    .frame(width: 11)
                Image(systemName: "folder.fill").font(.system(size: 12)).foregroundStyle(ROMStyle.folder)
                Text(category.name).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if category.hasChanges, editor.listing == .all, !editor.isComparing {
                    Circle().fill(ROMStyle.orange).frame(width: 7, height: 7)
                        .accessibilityLabel("has changed maps")
                }
                Text(category.countText).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .frame(height: 23)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(category.name)
    }

    private func mapRow(_ map: ROMEditor.TreeMap) -> some View {
        Button { editor.openMap(map.id) } label: {
            HStack(spacing: 7) {
                Text(map.dimension)
                    .font(ROMStyle.mono(9.5, .bold)).foregroundStyle(ROMStyle.chipText)
                    .frame(width: 22, height: 15)
                    .background(RoundedRectangle(cornerRadius: 3).fill(ROMStyle.chip))
                Text(map.title).fontWeight(map.isOpen ? .semibold : .regular).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if editor.isComparing {
                    if map.different > 0 { ROMBadge(text: "\(map.different)", isCompare: true) }
                } else if map.changed > 0 {
                    ROMBadge(text: "\(map.changed)")
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(map.isSelected ? ROMStyle.selectionRing.opacity(0.3) : (map.isOpen ? Color.primary.opacity(0.07) : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 20)
        .help(map.title)
        .accessibilityAddTraits(map.isSelected ? .isSelected : [])
    }

    private func noteBox(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(ROMStyle.inset.color))
    }
}

/// Everything that is different from the ROM as it was opened, map by map, with the old number
/// first. A click on a line goes to that cell. Under the list are the two things to do about it:
/// correct the checksums, or put everything back.
struct ROMChangesPanel: View {
    let editor: ROMEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Changes").font(.system(size: 14, weight: .bold))
                    Text("Everything that is different from this ROM as it was opened. The old number comes first.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button { editor.showsChanges = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Hide the changes")
                .accessibilityLabel("Hide the changes")
            }
            if editor.hasChanges {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(editor.changeGroups) { group in groupView(group) }
                        if editor.changeGroupsMore > 0 {
                            Text("and \(ROMEditor.counted(editor.changeGroupsMore, "more map")). Choose Changed above the map list to see them all.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let otherBytes = editor.changesOtherBytesText {
                            Text(otherBytes).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                actions
            } else {
                Text("Nothing has changed since this ROM was opened.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 9).fill(ROMStyle.window.color))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ROMStyle.hairline, lineWidth: 1))
    }

    private func groupView(_ group: ROMEditor.ChangeGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(group.title) { editor.openMap(group.id) }
                    .buttonStyle(.plain).fontWeight(.semibold).lineLimit(1)
                    .help("Open \(group.title)")
                Spacer(minLength: 4)
                Text(group.units).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(spacing: 1) {
                ForEach(group.lines) { line in
                    Button {
                        if let cell = line.cell { editor.openMap(group.id, at: cell) } else { editor.openMap(group.id) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: line.raised ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(line.raised ? ROMStyle.raisedArrow.color : ROMStyle.loweredArrow.color)
                                .accessibilityLabel(line.raised ? "raised" : "lowered")
                            Text(line.place).lineLimit(1)
                            Spacer(minLength: 4)
                            (Text("\(line.was) → ") + Text(line.now).fontWeight(.bold))
                                .font(ROMStyle.mono(12, .regular)).lineLimit(1)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(ROMStyle.inset.color)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            if group.more > 0 {
                Text("and \(group.more) more").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    /// With checksums that no longer add up, the warning comes with the button that corrects them.
    private var actions: some View {
        let mismatch = editor.checksumState == .mismatch
        return VStack(alignment: .leading, spacing: 8) {
            if mismatch {
                Text("An ECU rejects a ROM whose checksums are wrong. Correct them before you use this file.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            ROMFlow(spacing: 6, lineSpacing: 6) {
                if mismatch {
                    Button("Correct Checksums") { editor.correctChecksums() }
                        .buttonStyle(ROMButtonStyle(kind: .filled(ROMStyle.primaryButton), height: 26))
                }
                Button("Put Everything Back") { editor.putEverythingBack() }
                    .buttonStyle(ROMButtonStyle(kind: .quiet, height: 26))
                    .help("Make the whole ROM what it was when it was opened. Undo brings your changes back.")
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, mismatch ? 10 : 0).padding(.vertical, mismatch ? 9 : 0)
        .background(RoundedRectangle(cornerRadius: 8).fill(mismatch ? ROMStyle.orange.opacity(0.14) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(mismatch ? ROMStyle.orange.opacity(0.4) : Color.clear, lineWidth: 1))
    }
}
