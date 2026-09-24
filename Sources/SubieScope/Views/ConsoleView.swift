import AppKit
import SSMKit
import SwiftUI

struct ConsoleView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Toggle("Show raw traffic", isOn: $model.consoleCapturesTraffic)
                    .toggleStyle(.checkbox)
                Text("→ sent · ↩ echo from the cable · ← ECU reply")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.consoleLines.map(format).joined(separator: "\n"), forType: .string)
                }
                Button("Clear") { model.clearConsole() }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                List(model.consoleLines) { line in
                    Text(format(line))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(line.kind))
                        .textSelection(.enabled)
                        .id(line.id)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 14)
                .onChange(of: model.consoleLines.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private func format(_ line: ConsoleLine) -> String {
        let time = line.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))
        let arrow: String
        switch line.kind {
        case .sent?: arrow = "→"
        case .echo?: arrow = "↩"
        case .received?: arrow = "←"
        case .garbage?: arrow = "?"
        case nil: arrow = "•"
        }
        return "\(time)  \(arrow) \(line.text)"
    }

    private func color(_ kind: SSMTrafficDirection?) -> Color {
        switch kind {
        case .sent?: return .blue
        case .echo?: return .secondary
        case .received?: return .green
        case .garbage?: return .orange
        case nil: return .primary
        }
    }
}
