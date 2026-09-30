import SSMKit
import SwiftUI

/// Result of "Try Subaru SSM over this adapter": whether a standard ELM327 Bluetooth adapter can
/// speak Subaru's own protocol, so you could get the full data set wirelessly with no extra hardware.
struct SSMProbeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.scopeBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Subaru SSM over this adapter").font(.title2.weight(.semibold))
                    Text("Experimental: can this standard Bluetooth adapter speak Subaru's own protocol?")
                        .foregroundStyle(.secondary)
                }
            }

            if model.ssmProbeRunning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Setting the adapter to raw 4800 baud K-line and asking the ECU to identify itself…")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 20)
            } else if let result = model.ssmProbeResult {
                resultBody(result)
            }

            Spacer(minLength: 0)
            HStack {
                if !model.ssmProbeRunning, model.ssmProbeResult?.worked == false {
                    Button("Send Diagnostic Report…") { DiagnosticReporter.send(model: model) }
                }
                Spacer()
                if !model.ssmProbeRunning {
                    Button("Try Again") { model.probeSSMOverAdapter() }
                        .disabled(model.selectedAdapterID == nil)
                }
                Button("Done") { model.showSSMProbe = false }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540, height: 420)
    }

    @ViewBuilder
    private func resultBody(_ result: SSMOverELM.ProbeResult) -> some View {
        let ok = result.worked
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(ok ? "It works" : "Not this adapter").font(.headline)
                Text(result.reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(ok ? .green : .orange)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((ok ? Color.green : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

        if ok, let id = result.identity {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("ECU ID", value: id.ecuID).font(.callout.monospaced())
                if let engine = EngineDiagnostics.engineType(systemID: id.systemID) {
                    LabeledContent("Engine", value: engine).font(.callout)
                }
                Text("Full SSM logging over Bluetooth can be built on this. For now, SSM mode still uses the USB cable.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Setup commands the adapter accepted:").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(result.setup.accepted.isEmpty ? "none" : result.setup.accepted.joined(separator: ", "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                if !result.setup.rejected.isEmpty {
                    Text("Rejected: \(result.setup.rejected.joined(separator: ", "))")
                        .font(.caption.monospaced()).foregroundStyle(.orange)
                }
                if !result.rawReply.isEmpty {
                    Text("ECU replied: \(result.rawReply.hexString)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(3)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
