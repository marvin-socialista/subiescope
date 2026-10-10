import SSMKit
import SwiftUI

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                if case .failed(let message) = model.codeReadState {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if let message = model.clearState {
                    Label(message, systemImage: "info.circle").foregroundStyle(.secondary)
                }
                if model.mode == .obd {
                    codeSection(title: "Confirmed", subtitle: "Faults the car has confirmed. The check engine light is on for these", codes: model.currentCodes, tint: .red)
                    codeSection(title: "Pending", subtitle: "Seen once, not confirmed yet. They may go away by themselves", codes: model.memorizedCodes, tint: .orange)
                } else {
                    codeSection(title: "Current", subtitle: "Faults the ECU sees right now (temporary)", codes: model.currentCodes, tint: .red)
                    codeSection(title: "Memorized", subtitle: "Stored faults, kept until memory is cleared", codes: model.memorizedCodes, tint: .orange)
                }
                if let frame = model.freezeFrame {
                    freezeFrameSection(frame)
                }
            }
            .listStyle(.inset)
        }
        .confirmationDialog(model.mode == .obd ? "Clear the trouble codes?" : "Clear the ECU memory?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button(model.mode == .obd ? "Clear Codes" : "Clear Memory", role: .destructive) { Task { await model.clearTroubleCodes() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if model.mode == .obd {
                Text("This erases the trouble codes and turns the check engine light off. It also resets what the car has learned (fuel trims) and its readiness for the emissions test, so a test may need a few days of driving before it passes. If a fault is still there, the code comes back.")
            } else {
                Text("This erases all stored trouble codes and also resets what the ECU has learned: fuel trims (A/F learning), IAM and fine knock learning start over. The car may idle and drive slightly differently until it relearns.\n\nAfterwards: switch the ignition OFF, wait 10 seconds, switch it ON again.")
            }
        }
        .alert("Couldn't save the codes", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(stateText).font(.headline)
                if let status = model.engineStatus {
                    HStack(spacing: 10) {
                        if let test = status.testMode {
                            StatusChip(label: test ? "Test mode ON" : "Test mode off", on: test)
                        }
                        if let dcheck = status.dCheckPending {
                            StatusChip(label: dcheck ? "Self check not completed" : "Self check done", on: dcheck)
                        }
                    }
                }
            }
            Spacer()
            if model.codeReadState == .reading { ProgressView().controlSize(.small) }
            Menu {
                Button("Copy Codes") { copyToPasteboard(TroubleCodeExport(model: model).text(withHelp: false)) }
                Button("Copy Codes with Causes and Fixes") { copyToPasteboard(TroubleCodeExport(model: model).text(withHelp: true)) }
                Divider()
                Button("Save as PDF…") { save(pdf: true) }
                Button("Save as Text…") { save(pdf: false) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .help("Copy or save every code with its causes and fixes, e.g. for your mechanic or a forum")
            .disabled(!isRead)
            Button(model.mode == .obd ? "Clear Codes…" : "Clear Memory…") { confirmClear = true }
                .disabled(!model.connection.isConnected)
            Button("Read Codes") { Task { await model.readTroubleCodes() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.connection.isConnected || model.codeReadState == .reading)
        }
        .padding(14)
    }

    private var stateText: String {
        switch model.codeReadState {
        case .idle: return model.connection.isConnected ? "Press Read Codes to check the car" : "Connect to read trouble codes"
        case .reading: return "Reading…"
        case .read(let date):
            let total = model.currentCodes.count + model.memorizedCodes.count
            return "\(total == 0 ? "No trouble codes" : "\(total) code\(total == 1 ? "" : "s") found") · read \(date.formatted(date: .omitted, time: .standard))"
        case .failed: return "Reading failed"
        }
    }

    @ViewBuilder
    private func codeSection(title: String, subtitle: String, codes: [DiagnosticCodeDefinition], tint: Color) -> some View {
        Section {
            if codes.isEmpty {
                Text(isRead ? "None" : "–").foregroundStyle(.secondary)
            }
            ForEach(codes) { code in
                CodeRow(code: code, tint: tint)
            }
        } header: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The engine values the ECU kept with a stored code. Only there when the ECU has a frame.
    private func freezeFrameSection(_ frame: FreezeFrame) -> some View {
        Section {
            ForEach(model.freezeFrameLines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(line.name)
                    Spacer()
                    Text(line.value).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .help(line.description)
            }
        } header: {
            VStack(alignment: .leading, spacing: 1) {
                Text("Freeze frame").font(.headline)
                Text(frame.summary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var isRead: Bool {
        if case .read = model.codeReadState { return true }
        return false
    }

    /// Saves every code with its causes and fixes.
    private func save(pdf: Bool) {
        let report = TroubleCodeExport(model: model)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [pdf ? .pdf : .plainText]
        panel.nameFieldStringValue = report.fileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if pdf {
                try report.writePDF(to: url)
            } else {
                try report.text(withHelp: true).write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// A trouble code in the list; clicking it shows what it means and how to fix it.
private struct CodeRow: View {
    let code: DiagnosticCodeDefinition
    let tint: Color
    @State private var showingHelp = false

    var body: some View {
        Button { showingHelp.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                CodeBadge(code: code.code, tint: tint)
                Text(code.title)
                Spacer()
                Image(systemName: "info.circle")
                    .foregroundStyle(showingHelp ? tint : .secondary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show causes and fixes")
        .contextMenu {
            Button("Copy Code") { copyToPasteboard(code.line) }
            Button("Copy Code with Causes and Fixes") { copyToPasteboard(code.helpText) }
        }
        .popover(isPresented: $showingHelp, arrowEdge: .trailing) {
            TroubleCodeHelpView(code: code, tint: tint)
        }
    }
}

struct TroubleCodeHelpView: View {
    let code: DiagnosticCodeDefinition
    let tint: Color
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    CodeBadge(code: code.code, tint: tint)
                    Text(code.title).font(.headline)
                    Spacer(minLength: 0)
                    Button {
                        copyToPasteboard(code.helpText)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy this explanation")
                }
                if let help = code.help {
                    Text(help.meaning)
                    HelpList(title: "Possible causes", systemImage: "magnifyingglass", items: help.causes, numbered: false)
                    HelpList(title: "How to fix", systemImage: "wrench.and.screwdriver", items: help.fixes, numbered: true)
                    Text(TroubleCodeExport.disclaimer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No extra information for this code yet.").foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(18)
        }
        .frame(width: 460)
        .frame(maxHeight: 560)
    }
}

private struct HelpList: View {
    let title: String
    let systemImage: String
    let items: [String]
    let numbered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold))
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(numbered ? "\(index + 1)." : "•")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .trailing)
                    Text(item)
                }
            }
        }
    }
}

private struct CodeBadge: View {
    let code: String
    let tint: Color

    var body: some View {
        Text(code)
            .font(.system(.body, design: .monospaced).weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(tint)
    }
}

extension DiagnosticCodeDefinition {
    /// "Crankshaft pos. sensor A malfunction", or the raw name when it has no code prefix.
    var title: String { summary.isEmpty ? name : summary.capitalizedSentence }

    /// "P0420 Cat efficiency below threshold"
    var line: String { "\(code) \(title)" }

    /// The code with its meaning, causes and fixes as plain text, as the help popover shows it.
    var helpText: String {
        guard let help else { return line }
        var lines = [line, "", help.meaning, "", "Possible causes:"]
        lines += help.causes.map { "- \($0)" }
        lines += ["", "How to fix:"]
        lines += help.fixes.enumerated().map { "\($0.offset + 1). \($0.element)" }
        return lines.joined(separator: "\n")
    }
}

struct StatusChip: View {
    let label: String
    let on: Bool

    var body: some View {
        Text(label)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background((on ? Color.orange : Color.secondary).opacity(0.15), in: Capsule())
            .foregroundStyle(on ? .orange : .secondary)
    }
}

extension String {
    /// "CRANKSHAFT POS. SENSOR A MALFUNCTION" -> "Crankshaft pos. sensor A malfunction"
    var capitalizedSentence: String {
        guard self == uppercased() else { return self }
        let words = lowercased().split(separator: " ").map(String.init)
        let keepUpper: Set<String> = ["a", "b", "o2", "a/f", "ecm", "tcm", "egr", "ecu", "rpm", "pcv", "tgv", "avcs", "can", "abs", "vdc", "obd", "ac", "a/c", "evap", "dcv", "iat", "ect", "maf", "map"]
        return words.enumerated().map { i, w in
            if keepUpper.contains(w) && (w.count > 1 || i > 0) { return w.uppercased() }
            return i == 0 ? w.prefix(1).uppercased() + w.dropFirst() : w
        }.joined(separator: " ")
    }
}
