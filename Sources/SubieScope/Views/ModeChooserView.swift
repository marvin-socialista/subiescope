import SwiftUI

/// "How do you connect to your car?": what each mode gives you, what it needs and which cars it fits.
struct ModeChooserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "car.side")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.scopeBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("How do you connect to your car?").font(.title2.weight(.semibold))
                    Text("Pick the one that fits your car and your hardware. You can change it any time in the Car menu.")
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                ModeComparison { model.chooseMode($0) }
                    .padding(.bottom, 2)
            }

            Label {
                Text(ModeGuide.notSure).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                if ConnectionMode.hasChosen {
                    Button("Close") { model.showModeChooser = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(22)
        .frame(width: 820, height: 700)
        .interactiveDismissDisabled(!ConnectionMode.hasChosen)
    }
}

struct ModeCard: View {
    @Environment(AppModel.self) private var model
    let mode: ConnectionMode
    let choose: (ConnectionMode) -> Void

    private var isCurrent: Bool { ConnectionMode.hasChosen && model.mode == mode }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: mode.symbol)
                    .font(.title2)
                    .foregroundStyle(Color.scopeBlue)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(mode.title).font(.title3.weight(.semibold))
                        if mode == .obd { Text("NEW").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.scopeBlue.opacity(0.2), in: Capsule()).foregroundStyle(Color.scopeBlue) }
                    }
                    Text(mode.hardware).font(.caption).foregroundStyle(.secondary)
                }
            }

            Group {
                Text("Best for").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(mode == .ssm ? ModeGuide.ssmBestFor : ModeGuide.obdBestFor)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }

            bullets("You get", mode == .ssm ? ModeGuide.ssmGets : ModeGuide.obdGets, symbol: "checkmark.circle.fill", color: .green)
            if mode == .obd {
                bullets("What you don't get", ModeGuide.obdMissing, symbol: "minus.circle.fill", color: .orange)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("You need").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(mode == .ssm ? ModeGuide.ssmNeeds : ModeGuide.obdNeeds)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Which cars").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(mode == .ssm ? ModeGuide.ssmModels : ModeGuide.obdModels) { row in
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(row.model), \(row.years)").font(.caption.weight(.medium))
                        Text(row.note).font(.caption).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if mode == .obd {
                Text("OBD-II mode is new and tested with a simulated car. Please tell me how it works on yours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)
            Button {
                choose(mode)
            } label: {
                Text(isCurrent ? "Keep using \(mode.title)" : "Use \(mode.title)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isCurrent ? Color.scopeBlue : .clear, lineWidth: 2))
    }

    private func bullets(_ title: String, _ items: [String], symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(items, id: \.self) { item in
                Label {
                    Text(item).font(.callout).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(color).font(.callout)
                }
            }
        }
    }
}
