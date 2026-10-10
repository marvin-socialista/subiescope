import SSMKit
import SwiftUI

/// What the workspace shows while the ROM itself is selected in the tree: the risk notice, and a
/// card each for the file, the definitions, the checksums and reading from the car, with the raw
/// bytes under them.
struct ROMOverview: View {
    let editor: ROMEditor

    /// The narrowest a card is next to another one. Below that the cards go under each other.
    private static let cardWidth: CGFloat = 330

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ROMNotice()
            // Two cards beside each other where there is room, each row as tall as its taller card.
            ViewThatFits(in: .horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        beside(fileCard)
                        beside(definitionsCard)
                    }
                    GridRow {
                        beside(checksumCard)
                        beside(ROMReadCard(editor: editor))
                    }
                }
                VStack(spacing: 12) {
                    fileCard
                    definitionsCard
                    checksumCard
                    ROMReadCard(editor: editor)
                }
            }
            ROMBytesCard(editor: editor)
        }
    }

    /// A card in the row of two. Its text wraps, so the width it asks for is said here: left to
    /// itself a card would ask for the length of its longest sentence.
    private func beside<Card: View>(_ card: Card) -> some View {
        card.frame(minWidth: Self.cardWidth, idealWidth: Self.cardWidth, maxWidth: .infinity)
    }

    private var fileCard: some View {
        ROMCard(title: "File") {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(editor.fileRows) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                        Text(row.value)
                            .font(row.isCode ? ROMStyle.mono(12.5, .regular) : .system(size: 12.5))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    Text("Saved").foregroundStyle(.secondary)
                    Text(editor.savedText)
                        .foregroundStyle(editor.isEdited ? AnyShapeStyle(ROMStyle.orangeText.color) : AnyShapeStyle(.primary))
                }
            }
            .font(.system(size: 12.5))
        }
    }

    private var definitionsCard: some View {
        ROMCard(title: "Definitions") {
            let state = editor.definitionsState
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if editor.loadingDefs {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: state == .matched ? "checkmark.circle.fill" : "questionmark.circle")
                }
                Text(editor.definitionsText).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(state == .matched ? AnyShapeStyle(ROMStyle.ok.color) : AnyShapeStyle(ROMStyle.orangeText.color))
            if state == .suggestions {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(editor.recommendations, id: \.identity.xmlID) { definition in
                        Button { editor.applyRecommendation(definition.identity.xmlID) } label: {
                            Label(ROMEditor.label(of: definition), systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            if let error = editor.definitionsError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(ROMStyle.orangeText.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("The definitions say where each map sits in this ROM and how its numbers are scaled. \(sourceText)")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Get Definitions") { Task { await editor.autoLoadDefinitions() } }
                    .disabled(editor.loadingDefs)
                Button("Open Definitions…") { editor.openDefinitions() }
            }
            .buttonStyle(ROMButtonStyle(kind: .quiet, height: 26))
        }
    }

    /// Where the definitions in use came from: the repository, or a file the person chose.
    private var sourceText: String {
        if editor.defs == nil {
            return "SubieScope downloads RomRaider's ecu_defs.xml from its repository, or you can choose your own copy."
        }
        if editor.defsSource.hasPrefix("from ") {
            return "They are RomRaider's ecu_defs.xml, downloaded \(editor.defsSource)."
        }
        return "They are RomRaider's definitions, read from the file \(editor.defsSource)."
    }

    private var checksumCard: some View {
        ROMCard(title: "Checksums") {
            let state = editor.checksumState
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: ROMChecksumLabel.symbol(state))
                Text(editor.checksumText).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(ROMChecksumLabel.style(state))
            Text("An ECU rejects a ROM whose checksums are wrong. After you edit a map they no longer add up, and SubieScope corrects them for you.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Correct Checksums") { editor.correctChecksums() }
                .buttonStyle(ROMButtonStyle(kind: state == .mismatch ? .filled(ROMStyle.primaryButton) : .quiet, height: 26))
                .disabled(state != .mismatch || editor.isComparing)
        }
    }
}

/// How the checksums stand, as an icon and a colour: used by the toolbar and by the Checksums card.
enum ROMChecksumLabel {
    static func symbol(_ state: ROMEditor.ChecksumState) -> String {
        switch state {
        case .ok: return "checkmark.seal.fill"
        case .mismatch: return "exclamationmark.triangle.fill"
        case .disabled: return "minus.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    static func style(_ state: ROMEditor.ChecksumState) -> AnyShapeStyle {
        switch state {
        case .ok: return AnyShapeStyle(ROMStyle.ok.color)
        case .mismatch: return AnyShapeStyle(ROMStyle.orangeText.color)
        case .disabled, .unknown: return AnyShapeStyle(.secondary)
        }
    }
}

/// The warning that stands over everything to do with a ROM: it is at your own risk, and nothing
/// here writes to the car. The whole text is behind "What you should know".
struct ROMNotice: View {
    @State private var showsAll = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ROMStyle.orange).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(ROMDisclaimer.short).fontWeight(.bold).foregroundStyle(ROMStyle.orangeText.color)
                Text(ROMDisclaimer.noWriteToCar).font(.system(size: 12))
                DisclosureGroup("What you should know before editing a ROM", isExpanded: $showsAll) {
                    Text(ROMDisclaimer.full)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
                .font(.system(size: 12))
                .tint(.scopeBlue)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(ROMStyle.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ROMStyle.orange.opacity(0.4), lineWidth: 1))
    }
}

/// Reading the ROM out of the car's engine ECU. This is the one thing in the editor that talks to
/// the car (see `AppModel+ROM`), and it only reads.
struct ROMReadCard: View {
    @Environment(AppModel.self) private var model
    let editor: ROMEditor

    var body: some View {
        ROMCard(title: "Read from car") {
            Text("Copies the ROM out of the engine ECU and opens it here. It needs a Tactrix OpenPort 2.0, or an OBDLink (or other STN-based) adapter in OBD-II mode. It loads a small helper program into the ECU and copies the flash out. It reads only, and never writes anything back to the car. For the 2008 and later Subarus with a Denso SH7058 ECU, such as the 2008+ STI. This is new: it has worked on one car so far, a 2009 WRX STI through a Tactrix OpenPort.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.romReadInProgress {
                ProgressView(value: model.romReadProgress)
                HStack {
                    Text(model.romReadStatus ?? "Reading…").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop", role: .cancel) { model.cancelROMRead() }
                        .buttonStyle(ROMButtonStyle(kind: .quiet, height: 26))
                }
                Text("This takes several minutes. Keep the ignition ON, leave the engine off, and do not touch the car or unplug the adapter until it finishes.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Ignition ON, engine OFF, a healthy battery, and leave the car alone until it finishes.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                .foregroundStyle(ROMStyle.orangeText.color)
                HStack(spacing: 12) {
                    Button { Task { await editor.readFromCar(model) } } label: {
                        Label("Read ROM from Car", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(ROMButtonStyle(kind: .filled(ROMStyle.primaryButton), height: 28, horizontalPadding: 12))
                    .disabled(!model.canReadROMFromCar)
                    if model.checkingAdapterType { ProgressView().controlSize(.small) }
                    Text(model.romReadAvailability).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let status = model.romReadStatus {
                    Text(status).font(.system(size: 12))
                        .foregroundStyle(model.romReadError == nil ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The raw file, for what the definitions have no map for: sixteen lines of bytes from an offset,
/// and a way to write bytes at one.
struct ROMBytesCard: View {
    let editor: ROMEditor
    @State private var gotoText = "0"
    @State private var writeAtText = ""
    @State private var writeBytesText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text("Bytes").font(.system(size: 14, weight: .bold))
                Text("The raw file, for what the definitions have no map for.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Text("Go to offset (hex)")
                    field("0", $gotoText, width: 84).onSubmit { editor.applyGoto(gotoText) }
                    Button("Show") { editor.applyGoto(gotoText) }.buttonStyle(ROMButtonStyle(kind: .quiet, height: 26))
                }
                .font(.system(size: 12))
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(editor.byteLines()) { line in
                        HStack(spacing: 12) {
                            Text(line.offset).foregroundStyle(.secondary)
                            Text(line.hex)
                            Text(line.text).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(ROMStyle.mono(12, .regular))
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: 7).fill(ROMStyle.field.color))
            HStack(spacing: 8) {
                Text("Write at (hex)")
                field("offset", $writeAtText, width: 84)
                Text("Bytes")
                field("41 42 43", $writeBytesText, width: 260)
                Button("Apply") { editor.applyEdit(offset: writeAtText, bytes: writeBytesText) }
                    .buttonStyle(ROMButtonStyle(kind: .quiet, height: 26))
                    .disabled(editor.isComparing)
                if let error = editor.bytesError {
                    Text(error).foregroundStyle(.red)
                }
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(ROMStyle.window.color))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ROMStyle.hairline, lineWidth: 1))
        // Another ROM starts at its beginning again.
        .onChange(of: editor.session) { _, _ in
            gotoText = "0"
            writeAtText = ""
            writeBytesText = ""
        }
    }

    private func field(_ prompt: String, _ text: Binding<String>, width: CGFloat) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(ROMStyle.mono(12, .regular))
            .padding(.horizontal, 8)
            .frame(width: width, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(ROMStyle.field.color))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.16), lineWidth: 1))
    }
}

/// The ROM editor without a ROM in it: the risk notice, reading one from the car, and opening a file.
struct ROMStartView: View {
    let editor: ROMEditor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ROMNotice()
                ROMReadCard(editor: editor)
                VStack(spacing: 12) {
                    Image(systemName: "memorychip").font(.system(size: 42)).foregroundStyle(.secondary)
                    Text("Open a ROM file to inspect and edit it.").foregroundStyle(.secondary)
                    Text("A ROM is a .bin file, for example one read with FastECU or EcuFlash. You can also read it from the car with the card above.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { editor.openROM() } label: { Label("Open ROM…", systemImage: "folder") }
                        .buttonStyle(.borderedProminent)
                        .tint(.scopeBlue)
                        .padding(.top, 4)
                    if let status = editor.status {
                        Text(status).font(.callout)
                            .foregroundStyle(editor.statusIsProblem ? AnyShapeStyle(ROMStyle.orangeText.color) : AnyShapeStyle(.secondary))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ROMStyle.workspace.color)
    }
}
