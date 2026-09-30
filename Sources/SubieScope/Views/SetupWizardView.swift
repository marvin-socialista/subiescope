import SSMKit
import SwiftUI

/// First-run wizard: what car do you have, which connection fits it, connect and test it,
/// and a word about supporting the app. Also available from Car > Setup Wizard.
struct SetupWizardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    enum Step: Int, CaseIterable { case welcome, car, connect, done }
    enum CarChoice { case olderSubaru, newerSubaru, otherBrand, notSure }

    @State private var step: Step
    @State private var carChoice: CarChoice?
    @State private var chosen: ConnectionMode?
    @State private var comparing = false
    @State private var usedDemo = false
    @State private var cableOutcome: CableTest.Outcome?
    @State private var cablePath: String?

    /// Screenshot automation: -wizardStep 0...3 and -wizardMode ssm|obd start on that step.
    init() {
        let defaults = UserDefaults.standard
        _step = State(initialValue: Step(rawValue: defaults.integer(forKey: "wizardStep")) ?? .welcome)
        let preset = ConnectionMode(rawValue: defaults.string(forKey: "wizardMode") ?? "")
        _chosen = State(initialValue: preset)
        _carChoice = State(initialValue: preset.map { $0 == .ssm ? .olderSubaru : .newerSubaru })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 640)
        .interactiveDismissDisabled()
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "gauge.open.with.lines.needle.33percent")
                .font(.system(size: 26))
                .foregroundStyle(Color.scopeBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                Text("Step \(step.rawValue + 1) of \(Step.allCases.count)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Color.scopeBlue : Color.secondary.opacity(0.25))
                        .frame(width: s == step ? 26 : 12, height: 6)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var title: String {
        switch step {
        case .welcome: return "Welcome to SubieScope"
        case .car: return comparing ? "Compare the two ways to connect" : "What car do you have?"
        case .connect: return chosen == .obd ? "Connect the Bluetooth adapter" : "Connect the cable"
        case .done: return usedDemo ? "You're all set" : (model.connection.isConnected ? "You're connected" : "You're all set")
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { goBack() }
            }
            if step != .done {
                Button("Skip setup") { finish() }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch step {
            case .welcome:
                Button("Let's go") { step = .car }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .car:
                if !comparing {
                    Button("Continue") { continueFromCar() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(chosen == nil)
                }
            case .connect:
                if model.connection.isConnected {
                    Button("Continue") { step = .done }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue without testing") { step = .done }
                        .keyboardShortcut(.defaultAction)
                }
            case .done:
                Button("Start using SubieScope") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .car: comparing ? AnyView(comparison) : AnyView(carQuestion)
        case .connect: connectStep
        case .done: doneStep
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Live data, diagnostics and a virtual dyno for your car, on your Mac.")
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("SubieScope needs a small piece of hardware between your Mac and the car's diagnostic port, under the dashboard. This short setup helps you pick the right one and checks that it works. It takes about two minutes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                point("car.side", "Tell us which car you have", "so we can recommend the right connection.")
                point("cable.connector", "Plug in and test", "with clear steps, and help if something doesn't work.")
                point("play.circle", "No hardware yet?", "You can try everything with a simulated demo car.")
            }
            .padding(.top, 4)
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        Label {
            (Text(title).fontWeight(.medium) + Text(" \(detail)").foregroundStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.scopeBlue).frame(width: 24)
        }
    }

    private var carQuestion: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This decides which connection you need. Both plug into the same port under the dashboard.")
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                carButton(.olderSubaru, "A Subaru up to about 2014",
                          "Impreza, WRX, STI, Legacy, Outback, Forester, Baja, Tribeca")
                carButton(.newerSubaru, "A newer Subaru (about 2015 and up)",
                          "WRX or STI (VA), Levorg, XV / Crosstrek, Forester (SJ and newer), BRZ / GR86 and others")
                carButton(.otherBrand, "Another brand", "Any car built since about 2008")
                carButton(.notSure, "I'm not sure", "We'll help you find out")
            }

            if carChoice == .notSure {
                Label {
                    Text("Check the year on the registration papers, or the sticker in the driver's door frame. The older WRX and STI (hatchback or sedan with a 2.0 or 2.5 litre boxer, up to 2014) are in the first group. The sedan that came in 2015 (the VA) is in the second.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lightbulb").foregroundStyle(.yellow)
                }
                .font(.callout)
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            if let mode = chosen {
                recommendation(mode)
            }

            Button("Compare both options in detail") { comparing = true }
                .buttonStyle(.link)
        }
    }

    private func carButton(_ choice: CarChoice, _ title: String, _ detail: String) -> some View {
        let selected = carChoice == choice
        return Button {
            carChoice = choice
            switch choice {
            case .olderSubaru: chosen = .ssm
            case .newerSubaru, .otherBrand: chosen = .obd
            case .notSure: chosen = nil
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.scopeBlue : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(selected ? Color.scopeBlue.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.scopeBlue : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private func recommendation(_ mode: ConnectionMode) -> some View {
        let other: ConnectionMode = mode == .ssm ? .obd : .ssm
        return VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("We recommend \(mode.title)").font(.headline)
            } icon: {
                Image(systemName: mode.symbol).foregroundStyle(Color.scopeBlue)
            }
            Text(mode == .ssm
                 ? "Subaru's own protocol gives you everything the ECU knows: knock, IAM, boost target and hundreds more values, plus all the troubleshooting tests. You need a VAG KKL 409.1 USB cable with an FTDI chip (about €10 to 15). No driver needed."
                 : "The standard protocol works on newer Subarus and on other brands, wirelessly. You get the basics (rpm, speed, temperatures, load, fuel trims, boost, trouble codes) but not Subaru-only values such as knock and IAM. You need an ELM327 adapter with Bluetooth 4.0 (BLE), such as the Vgate iCar Pro BLE 4.0.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("I have \(other.title == "OBD-II" ? "an OBD-II Bluetooth adapter" : "the SSM USB cable") instead") { chosen = other }
                .buttonStyle(.link)
                .font(.callout)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.scopeBlue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private var comparison: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                comparing = false
            } label: {
                Label("Back to the question", systemImage: "chevron.left")
            }
            .buttonStyle(.link)
            ModeComparison { mode in
                chosen = mode
                carChoice = mode == .ssm ? .olderSubaru : .newerSubaru
                comparing = false
                continueFromCar()
            }
        }
    }

    @ViewBuilder
    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            if chosen == .obd {
                AdapterSteps()
            } else {
                CableSteps(outcome: $cableOutcome, selectedPath: $cablePath)
            }
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "play.circle").foregroundStyle(.secondary)
                Text("No \(chosen == .obd ? "adapter" : "cable") yet?").foregroundStyle(.secondary)
                Button("Try the demo car") { startDemo() }
                    .buttonStyle(.link)
            }
            .font(.callout)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(doneTitle).font(.headline)
                    Text(doneDetail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: model.connection.isConnected ? "checkmark.circle.fill" : "info.circle.fill")
                    .foregroundStyle(model.connection.isConnected ? .green : Color.scopeBlue)
                    .font(.title2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((model.connection.isConnected ? Color.green : Color.scopeBlue).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "cup.and.saucer.fill").font(.title2).foregroundStyle(.orange)
                    Text("SubieScope is free").font(.headline)
                }
                Text("I develop SubieScope for free, in my own time, and I'm happy to keep it that way. If it helps you understand your car, or saves you a trip to the garage, a coffee is always welcome and really appreciated. No pressure at all: the app works exactly the same either way.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button {
                        openURL(About.coffeeURL)
                    } label: {
                        Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    Text("You can also find this later in the Help menu.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

            Label {
                (Text("Something not working on your car? ") + Text("Please tell me").foregroundStyle(Color.scopeBlue) + Text(". Reports of which cars work are very welcome."))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(.secondary)
            }
            .font(.callout)
            .onTapGesture { openURL(Links.issues) }
        }
    }

    private var doneTitle: String {
        if usedDemo { return "You're looking at a simulated car" }
        return model.connection.isConnected ? "Connected to your car" : "Setup is done"
    }

    private var doneDetail: String {
        if usedDemo { return "Everything works as it would on a real car. When your \(chosen == .obd ? "adapter" : "cable") arrives, choose it in the toolbar and press Connect." }
        if model.connection.isConnected { return "Live data is running. Open the Dashboard to watch your gauges." }
        return "Choose your \(chosen == .obd ? "adapter" : "cable") in the sidebar and press Connect when you are in the car with the ignition ON. Change the connection type any time in the Car menu."
    }

    // MARK: Actions

    private func goBack() {
        switch step {
        case .car: if comparing { comparing = false } else { step = .welcome }
        case .connect: step = .car
        default: break
        }
    }

    private func continueFromCar() {
        guard let mode = chosen else { return }
        model.applyChosenMode(mode)
        step = .connect
    }

    private func startDemo() {
        usedDemo = true
        if chosen == .obd { model.selectedAdapterID = AppModel.demoOBDID } else { model.selectedPortID = AppModel.demoPortID }
        Task {
            await model.connect()
            step = .done
        }
    }

    private func finish() {
        model.finishSetupWizard()
    }
}

/// The two cards side by side, as in the "Connection Type" sheet.
struct ModeComparison: View {
    let choose: (ConnectionMode) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ModeCard(mode: .ssm, choose: choose)
            ModeCard(mode: .obd, choose: choose)
        }
    }
}

/// The Bluetooth adapter checks: plug in, allow Bluetooth, pick the adapter, test.
struct AdapterSteps: View {
    @Environment(AppModel.self) private var model
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SetupStep(number: 1, title: "Plug the adapter into the car and turn the ignition ON", done: model.connection.isConnected || !model.bleAdapters.isEmpty) {
                Text("The OBD port is under the dashboard on the driver's side. The engine may be off or running. The adapter's light comes on. Close other apps that use the adapter (also on your phone): it accepts one connection at a time.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SetupStep(number: 2, title: "Look for your adapter", done: model.connection.isConnected || model.selectedAdapterID != nil && model.selectedAdapterID != AppModel.demoOBDID) {
                if !searching && model.bleStatus == .idle {
                    Text("The first time, macOS asks whether SubieScope may use Bluetooth. Please say yes: it is only used to talk to your adapter.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Look for adapters") {
                        searching = true
                        model.startBLEScan()
                    }
                    .buttonStyle(.borderedProminent)
                } else if let problem = model.bleStatus.message {
                    Label {
                        Text(problem).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    Button("Try again") { model.restartBLEScan() }
                } else if model.bleAdapters.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for adapters nearby…").foregroundStyle(.secondary)
                    }
                    Text("An adapter only shows up while it is plugged into a car with the ignition ON. Vgate iCar Pro adapters often appear as \"IOS-Vlink\" or \"vLinker\".")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.bleAdapters.prefix(8)) { adapter in
                        Button {
                            model.selectedAdapterID = adapter.id
                        } label: {
                            HStack {
                                Image(systemName: model.selectedAdapterID == adapter.id ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(model.selectedAdapterID == adapter.id ? Color.scopeBlue : .secondary)
                                Text(adapter.name).font(.body.weight(adapter.looksLikeOBD ? .medium : .regular))
                                Spacer()
                                if adapter.looksLikeOBD { Text("Looks like an OBD-II adapter").font(.caption).foregroundStyle(.secondary) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.connection.isConnected || model.connection == .connecting)
                    }
                }
            }

            SetupStep(number: 3, title: "Test the connection", done: model.connection.isConnected) {
                HStack {
                    Button {
                        Task { await model.connect() }
                    } label: {
                        Label(model.connection == .connecting ? "Connecting…" : "Test Connection", systemImage: "bolt.horizontal")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.connection == .connecting || model.connection.isConnected
                              || model.selectedAdapterID == nil || model.selectedAdapterID == AppModel.demoOBDID)
                    if model.connection == .connecting { ProgressView().controlSize(.small) }
                }
                switch model.connection {
                case .connected:
                    result(true, "Connected", "The adapter found your car. Finding the car the first time can take a few seconds.")
                case .failed(let message):
                    result(false, "That didn't work", message)
                default:
                    EmptyView()
                }
            }
        }
        .onAppear {
            // Already asked for Bluetooth before: no need to explain it again.
            if model.bleStatus != .idle { searching = true } else if model.selectedAdapterID != nil { searching = true; model.startBLEScan() }
        }
    }

    private func result(_ ok: Bool, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? .green : .orange)
        }
        .padding(12)
        .background((ok ? Color.green : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}
