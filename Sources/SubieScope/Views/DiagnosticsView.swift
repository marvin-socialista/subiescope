import SSMKit
import SwiftUI

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false

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
                codeSection(title: "Current", subtitle: "Faults the ECU sees right now (temporary)", codes: model.currentCodes, tint: .red)
                codeSection(title: "Memorized", subtitle: "Stored faults, kept until memory is cleared", codes: model.memorizedCodes, tint: .orange)
            }
            .listStyle(.inset)
        }
        .confirmationDialog("Clear the ECU memory?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Memory", role: .destructive) { Task { await model.clearTroubleCodes() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases all stored trouble codes and also resets what the ECU has learned: fuel trims (A/F learning), IAM and fine knock learning start over. The car may idle and drive slightly differently until it relearns.\n\nAfterwards: switch the ignition OFF, wait 10 seconds, switch it ON again.")
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
            Button("Clear Memory…") { confirmClear = true }
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
        case .idle: return model.connection.isConnected ? "Press Read Codes to check the ECU" : "Connect to read trouble codes"
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

    private var isRead: Bool {
        if case .read = model.codeReadState { return true }
        return false
    }
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
        .popover(isPresented: $showingHelp, arrowEdge: .trailing) {
            TroubleCodeHelpView(code: code, tint: tint)
        }
    }
}

struct TroubleCodeHelpView: View {
    let code: DiagnosticCodeDefinition
    let tint: Color

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    CodeBadge(code: code.code, tint: tint)
                    Text(code.title).font(.headline)
                }
                if let help = code.help {
                    Text(help.meaning)
                    HelpList(title: "Possible causes", systemImage: "magnifyingglass", items: help.causes, numbered: false)
                    HelpList(title: "How to fix", systemImage: "wrench.and.screwdriver", items: help.fixes, numbered: true)
                    Text("General guidance for Subaru engines. Check the service manual for your model's exact values and wiring.")
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
