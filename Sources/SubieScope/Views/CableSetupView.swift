import AppKit
import SSMKit
import SwiftUI

/// The cable checks: find the cable, plug it into the car, test the connection.
/// Used by the Cable Setup sheet and by the first-run wizard.
struct CableSteps: View {
    @Environment(AppModel.self) private var model
    @Binding var outcome: CableTest.Outcome?
    @Binding var selectedPath: String?
    @State private var cables: [USBCable] = []
    @State private var testing = false
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var passed: Bool { if case .ok? = outcome { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SetupStep(number: 1, title: "Plug the cable into your Mac", done: !cables.isEmpty) {
                if cables.isEmpty {
                    Text("Waiting for a USB cable… Use a USB-C adapter if needed. SubieScope keeps looking.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(cables) { cable in
                        CableRow(cable: cable, openPortOn: model.openPortOn)
                    }
                }
            }

            SetupStep(number: 2, title: "Plug it into the car and turn the ignition ON", done: passed) {
                Text("The OBD port is under the dashboard on the driver's side. The engine may be off or running. If your cable has a switch, set it to K-line on pin 7 (often labelled \"VAG\" or \"1\").")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SetupStep(number: 3, title: "Test the connection", done: passed) {
                HStack {
                    Button {
                        runTest()
                    } label: {
                        Label(testing ? "Testing…" : "Test Connection", systemImage: "bolt.horizontal")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(testing || selectedPath == nil || model.connection.isConnected)
                    if testing { ProgressView().controlSize(.small) }
                    if model.connection.isConnected {
                        Text("Already connected.").foregroundStyle(.secondary)
                    }
                }
                if let outcome {
                    let text = CableTest.explanation(outcome)
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(text.title).font(.body.weight(.semibold))
                            Text(text.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(passed ? .green : .orange)
                    }
                    .padding(12)
                    .background((passed ? Color.green : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .onAppear(perform: scan)
        .onReceive(timer) { _ in if !testing { scan() } }
    }

    private func scan() {
        cables = CableScanner.scan()
        if selectedPath == nil || !cables.contains(where: { $0.serialPath == selectedPath }) {
            selectedPath = cables.first(where: { model.canUse($0) })?.serialPath
        }
    }

    private func runTest() {
        guard let path = selectedPath else { return }
        let openPort = cables.first { $0.serialPath == path }?.chip == .openPort2
        testing = true
        outcome = nil
        Task.detached {
            let result = CableTest.run(path: path, openPort: openPort)
            await MainActor.run {
                outcome = result
                testing = false
                if case .ok = result {
                    model.selectedPortID = path
                    UserDefaults.standard.set(true, forKey: "cableSetupDone")
                }
            }
        }
    }
}

/// Cable Setup sheet (Car menu): the same checks, on their own.
struct CableSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPath: String?
    @State private var outcome: CableTest.Outcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "cable.connector.horizontal")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.scopeBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cable Setup").font(.title2.weight(.semibold))
                    Text("Three quick steps to connect to your Subaru.").foregroundStyle(.secondary)
                }
            }

            CableSteps(outcome: $outcome, selectedPath: $selectedPath)

            Spacer(minLength: 0)
            HStack {
                Button("Use the Demo Car Instead") {
                    model.selectedPortID = AppModel.demoPortID
                    finish(connect: true)
                }
                Spacer()
                Button("Close") { finish(connect: false) }
                    .keyboardShortcut(.cancelAction)
                if case .ok? = outcome {
                    Button("Connect") { finish(connect: true) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 600)
    }

    private func finish(connect: Bool) {
        UserDefaults.standard.set(true, forKey: "cableSetupSeen")
        dismiss()
        if connect {
            model.refreshPorts()
            Task { await model.connect() }
        }
    }
}

struct SetupStep<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.2)).frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.callout.weight(.semibold))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content
            }
        }
    }
}

struct CableRow: View {
    let cable: USBCable
    /// Whether the support for a Tactrix OpenPort is turned on in Settings.
    var openPortOn = false

    var body: some View {
        let usable = cable.isUsable(openPortSupport: openPortOn)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: cable.serialPath != nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(usable ? .green : .orange)
                Text(cable.productName ?? "USB cable").font(.body.weight(.medium))
                Text("· \(cable.chip.name)").foregroundStyle(.secondary)
            }
            if let path = cable.serialPath, usable {
                Text("Ready as \((path as NSString).lastPathComponent). \(cable.chip == .ftdi ? "No driver needed." : cable.chip == .openPort2 ? "Experimental: not tested with a real OpenPort yet." : "")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(cable.chip.driverAdvice).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = cable.chip.driverURL {
                    HStack {
                        Link("Get the driver", destination: url)
                        Button("Open Privacy & Security") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Security")!)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            if cable.chip == .ch340 {
                Text("Tip: FTDI-based KKL cables are the most reliable with Subarus.").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
