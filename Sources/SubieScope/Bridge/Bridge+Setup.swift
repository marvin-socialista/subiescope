#if os(Windows) || DEBUG
import Foundation
import Observation
import SSMKit

/// What the screens for getting connected remember between two clicks: where the wizard is, which
/// cables were found, how the cable test went. In the Mac app this is the `@State` of
/// SetupWizardView, CableSteps and AdapterSteps. The page keeps no state of its own, so it lives here.
@MainActor
@Observable
final class SetupFlow {
    enum Step: Int, CaseIterable {
        case welcome, car, connect, done

        /// What the page calls the step.
        var name: String {
            switch self {
            case .welcome: return "welcome"
            case .car: return "car"
            case .connect: return "connect"
            case .done: return "done"
            }
        }
    }
    enum CarChoice: String { case olderSubaru, newerSubaru, otherBrand, notSure }

    // The wizard (SetupWizardView).
    var step = Step.welcome
    var carChoice: CarChoice?
    var chosen: ConnectionMode?
    var comparing = false
    var usedDemo = false

    // The cable checks (CableSteps), in the wizard and in the Cable Setup sheet.
    var cables: [USBCable] = []
    var cablePath: String?
    var testing = false
    var outcome: CableTest.Outcome?
    /// Counts the tests, so the answer of one that was left behind (the sheet was closed) is dropped.
    var testRun = 0

    // The adapter checks (AdapterSteps).
    /// Bluetooth was asked for before: no need to explain the permission again.
    var searching = false

    init() {
        restartWizard()
    }

    /// The wizard as it is when it opens. Screenshot automation: -wizardStep 0...3 and
    /// -wizardMode ssm|obd start on that step, as in the Mac app.
    func restartWizard() {
        let defaults = UserDefaults.standard
        step = Step(rawValue: defaults.integer(forKey: "wizardStep")) ?? .welcome
        let preset = ConnectionMode(rawValue: defaults.string(forKey: "wizardMode") ?? "")
        chosen = preset
        carChoice = preset.map { $0 == .ssm ? .olderSubaru : .newerSubaru }
        comparing = false
        usedDemo = false
        searching = false
        restartCableTest()
    }

    func restartCableTest() {
        testRun += 1
        cablePath = nil
        testing = false
        outcome = nil
    }

    var passed: Bool {
        if case .ok? = outcome { return true }
        return false
    }
}

/// Getting connected, apart from the connection card itself: the panel that opens from the card
/// (ConnectionPanel), the wizard of the first start (SetupWizardView), the Cable Setup sheet
/// (CableSetupView) and the sheet that helps choose the connection type (ModeChooserView).
extension Bridge {
    // MARK: What the page gets

    /// Which sheets are asked for, and the two connection types side by side.
    struct SetupState: Encodable {
        struct ModeCard: Encodable {
            struct Car: Encodable {
                /// "Legacy, Liberty, Outback (BM/BR), 2010 to 2014"
                let name: String
                let note: String
            }

            /// "ssm" or "obd"
            let mode: String
            let title: String
            /// The "NEW" label next to the title.
            let isNew: Bool
            let hardware: String
            let bestFor: String
            let gets: [String]
            /// What this type cannot do. Empty for SSM.
            let missing: [String]
            let needs: String
            let cars: [Car]
            /// "Use OBD-II", or "Keep using OBD-II" for the type that is in use.
            let button: String
            let isCurrent: Bool
        }

        let showWizard: Bool
        let showCableSetup: Bool
        let showModeChooser: Bool
        /// A type was chosen before, so the sheet can be closed without choosing.
        let canCloseModeChooser: Bool
        let chooserSubtitle: String
        let notSure: String
        let cards: [ModeCard]
        /// Where the buttons of the last step of the wizard lead.
        let coffeeURL: String
        let issuesURL: String
    }

    /// The wizard: where it is, and the texts that depend on the choices made in it.
    struct SetupWizardState: Encodable {
        struct Recommendation: Encodable {
            /// "ssm" or "obd"
            let mode: String
            /// "We recommend Subaru SSM"
            let title: String
            let text: String
            /// "I have an OBD-II adapter instead": chooses the other type.
            let otherLabel: String
            let otherMode: String
        }

        struct Button: Encodable {
            let label: String
            /// The step is ready for it: it is drawn as the main button.
            let prominent: Bool
            let enabled: Bool
        }

        /// welcome, car, compare, connect or done
        let step: String
        let title: String
        /// Which of the steps this is, counted from 0, and how many there are.
        let index: Int
        let count: Int
        let canGoBack: Bool
        let canSkip: Bool
        /// The button that goes on. None while the two types are compared.
        let next: Button?

        let welcomeTitle: String
        let welcomeText: String
        /// olderSubaru, newerSubaru, otherBrand or notSure. Nil until one is picked.
        let carChoice: String?
        let recommendation: Recommendation?
        /// The type the connect step is for: "ssm" (the cable checks) or "obd" (the adapter checks).
        let connectMode: String
        /// "No cable yet?"
        let demoQuestion: String
        /// The last step: whether the car is connected, and what to say about it.
        let doneConnected: Bool
        let doneTitle: String
        let doneDetail: String
        let coffeeNote: String
    }

    /// The cable checks: find the cable, plug it into the car, test the connection.
    struct SetupCableState: Encodable {
        struct Cable: Encodable {
            let id: String
            /// "FT232R USB UART"
            let name: String
            /// "FTDI (FT232R)"
            let chip: String
            /// A driver has made a serial port for it.
            let hasPort: Bool
            /// SubieScope can connect through it right now.
            let usable: Bool
            /// "Ready as COM4.", or what to do about the driver.
            let text: String
            /// Where to get the driver, when there is one to get.
            let driverURL: String?
            /// The button next to that link: "Open Device Manager".
            let settingsButton: String?
            let tip: String?
        }

        struct Result: Encodable {
            let ok: Bool
            let title: String
            let detail: String
        }

        /// "Plug the cable into your PC"
        let plugTitle: String
        let cables: [Cable]
        /// The ECU answered the test.
        let passed: Bool
        let testing: Bool
        let canTest: Bool
        let connected: Bool
        let result: Result?
    }

    /// The adapters to choose from in OBD-II mode, for the panel and for the wizard's adapter checks.
    struct SetupAdapterState: Encodable {
        struct Row: Encodable {
            let id: String
            let name: String
            let selected: Bool
            /// Bluetooth only: the name looks like an OBD-II adapter.
            let looksLikeOBD: Bool
        }

        struct Result: Encodable {
            let ok: Bool
            let title: String
            let detail: String
        }

        /// Bluetooth LE adapters can be used on this computer. False on Windows: there the page
        /// shows `pcNote` and the other adapters, and never looks for Bluetooth.
        let bluetooth: Bool
        /// Why Bluetooth cannot be used right now.
        let bluetoothProblem: String?
        /// The wizard has not asked for Bluetooth yet: it explains the permission first.
        let bluetoothNotAsked: Bool
        let bluetoothAdapters: [Row]
        /// Serial ports as adapters: USB ones, and Bluetooth adapters that are paired with the computer.
        let ports: [Row]
        /// The Wi-Fi adapter at the address in `wifiAddress`.
        let wifi: Row
        let wifiAddress: String
        /// Connected or connecting: nothing can be chosen.
        let locked: Bool
        /// Whether the other adapters are shown from the start (one of them is chosen).
        let othersOpen: Bool

        /// Windows only: which adapters work on a PC, and how a Bluetooth one is used there.
        let pcNote: String?
        /// Windows only: what the list says while it has no serial port to offer.
        let noPortsNote: String?
        let experimentalNote: String
        let wifiNote: String

        /// The wizard's three steps: what is done, and how the test went.
        let pluggedIn: Bool
        let chosen: Bool
        let canTest: Bool
        let connecting: Bool
        let connected: Bool
        let result: Result?
    }

    /// The inside of the panel that opens from the connection card. Its title and status are in `app`.
    struct SetupPanelState: Encodable {
        struct Cable: Encodable {
            let id: String
            /// "FT232R USB UART · FTDI (FT232R)"
            let title: String
            let text: String
            /// The text is advice about a missing driver.
            let needsDriver: Bool
            /// A Tactrix OpenPort whose (experimental) support is off: offer to turn it on.
            let offerOpenPort: Bool
        }

        struct Fact: Encodable {
            let label: String
            let value: String
            let mono: Bool
        }

        struct Check: Encodable {
            let done: Bool
            let text: String
            let detail: String
        }

        /// The summary at the top: the connection card's own (`status` in `app`), except on a PC,
        /// where the card can name Bluetooth as the problem while Bluetooth is not used there at all.
        let status: AppState.Status
        /// "Subaru SSM: USB cable"
        let modeLine: String
        let canChangeMode: Bool
        /// SSM only (nil in OBD-II mode): the cables that were found.
        let cables: [Cable]?
        /// SSM only: what the Cable section says when there is no cable at all.
        let noCable: String?
        /// SSM only: the ports to choose from when there is more than one. Empty otherwise.
        let portChoices: [AppState.Device]
        /// What is known about the connected car. Empty while not connected.
        let facts: [Fact]
        /// How to connect, while not connected.
        let checklist: [Check]
        let widebandOn: Bool
    }

    /// The parts of the panel that change with every sample.
    struct SetupPanelLive: Encodable {
        /// "12.4 samples/s"
        let speed: String
        /// The wideband gauge's state in a sentence. Nil while the gauge is turned off.
        let wideband: String?
        let widebandProblem: Bool
    }

    // MARK: Registering

    func registerSetup() {
        let flow = SetupFlow()

        slice("setup") { [model] in Bridge.setupState(model) }
        slice("setup.wizard") { [model] in Bridge.setupWizardState(model, flow) }
        slice("setup.cable") { [model] in Bridge.setupCableState(model, flow) }
        slice("setup.adapter") { [model] in Bridge.setupAdapterState(model, flow) }
        slice("setup.panel") { [model] in Bridge.setupPanelState(model) }
        slice("setup.panel.live", atMost: 4) { [model] in
            SetupPanelLive(
                speed: String(format: "%.1f samples/s", model.samplesPerSecond),
                // The model's own sentence names the Mac in one place (AppModel+Wideband.swift).
                wideband: model.widebandOn ? model.widebandStatusText.replacingOccurrences(of: "your Mac", with: "your \(Bridge.computer)") : nil,
                widebandProblem: model.widebandHasProblem)
        }

        // The connection type sheet.
        action("setup.showModeChooser") { [model] _ in model.showModeChooser = true }
        action("setup.closeModeChooser") { [model] _ in
            guard ConnectionMode.hasChosen else { return }
            model.showModeChooser = false
        }
        action("setup.chooseMode") { [model, weak self] arguments in
            guard let mode = arguments.string("mode").flatMap(ConnectionMode.init(rawValue:)) else { return }
            // Choosing the cable for the first time brings up Cable Setup next: it starts clean.
            flow.restartCableTest()
            model.chooseMode(mode)
            // Whether a type was ever chosen is a saved setting, which the model does not announce.
            self?.invalidate("setup")
        }

        // The Cable Setup sheet.
        action("setup.showCableSetup") { [model] _ in
            flow.restartCableTest()
            model.showCableSetup = true
        }
        // `connect` for the Connect button, `demo` for "Use the Demo Car Instead", neither for Close.
        action("setup.closeCableSetup") { [model] arguments in
            let demo = arguments.bool("demo")
            let connect = demo || (arguments.bool("connect") && flow.passed)
            if demo { model.selectedPortID = AppModel.demoPortID }
            UserDefaults.standard.set(true, forKey: "cableSetupSeen")
            model.showCableSetup = false
            flow.restartCableTest()
            if connect {
                model.refreshPorts()
                Task { await model.connect() }
            }
        }

        // The cable checks. The page asks for a new look every second and a half while they are shown.
        action("setup.scanCables") { [model] _ in
            guard !flow.testing else { return }
            let cables = CableScanner.scan()
            if cables != flow.cables { flow.cables = cables }
            var path = flow.cablePath
            if path == nil || !cables.contains(where: { $0.serialPath == path }) {
                path = cables.first(where: { model.canUse($0) })?.serialPath
            }
            #if DEBUG
            // For trying the test without a cable: -setupCablePort <device> stands in for one
            // (the port that `subiescope-cli demo` prints).
            if let stand = Bridge.standInCablePort { path = stand }
            #endif
            if path != flow.cablePath { flow.cablePath = path }
        }
        action("setup.testCable") { [model] _ in
            guard let path = flow.cablePath, !flow.testing, !model.connection.isConnected else { return }
            let openPort = flow.cables.first { $0.serialPath == path }?.chip == .openPort2
            flow.testRun += 1
            let run = flow.testRun
            flow.testing = true
            flow.outcome = nil
            // The test waits for the cable and the car, so it runs next to the app, not in it.
            Task.detached {
                let result = CableTest.run(path: path, openPort: openPort)
                Task { @MainActor in
                    guard run == flow.testRun else { return }
                    flow.outcome = result
                    flow.testing = false
                    if case .ok = result {
                        model.selectedPortID = path
                        UserDefaults.standard.set(true, forKey: "cableSetupDone")
                    }
                }
            }
        }
        // The button next to "Get the driver": where this computer shows what it made of the cable.
        action("setup.openDriverSettings") { _ in
            #if os(Windows)
            // Device Manager. Not a web address: Windows finds the program by its name.
            if let deviceManager = URL(string: "devmgmt.msc") { Desktop.open(deviceManager) }
            #else
            guard !Bridge.onWindows, let privacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Security") else { return }
            Desktop.open(privacy)
            #endif
        }
        action("setup.openPortOn") { [model] _ in
            guard !model.connection.isConnected else { return }
            model.openPortOn = true
        }

        // The adapter checks.
        // They come on the page: with Bluetooth asked for before, there is no need to explain it again.
        action("setup.adapterSteps") { [model] _ in
            guard Bridge.bluetoothWorks else { return }
            if model.bleStatus != .idle {
                flow.searching = true
            } else if model.selectedAdapterID != nil {
                flow.searching = true
                model.startBLEScan()
            }
        }
        action("setup.lookForAdapters") { [model] _ in
            guard Bridge.bluetoothWorks else { return }
            flow.searching = true
            model.startBLEScan()
        }
        action("setup.retryBluetooth") { [model] _ in
            guard Bridge.bluetoothWorks else { return }
            model.restartBLEScan()
        }
        action("setup.wifiAddress") { [model] arguments in
            guard let address = arguments.string("address"), !model.connection.isConnected, model.connection != .connecting else { return }
            model.wifiAddress = address
        }

        // The panel of the connection card.
        action("setup.panelOpened") { [model] _ in model.refreshPorts() }
        action("setup.useDemoCar") { [model] _ in
            guard !model.connection.isConnected, model.connection != .connecting else { return }
            if model.mode == .obd { model.selectedAdapterID = AppModel.demoOBDID } else { model.selectedPortID = AppModel.demoPortID }
            Task { await model.connect() }
        }

        // The wizard.
        action("setup.showWizard") { [model] _ in
            guard model.connection != .connecting, !model.showWizard else { return }
            flow.restartWizard()
            model.showWizard = true
        }
        let finish: @MainActor () -> Void = { [model, weak self] in
            model.finishSetupWizard()
            flow.restartWizard()
            self?.invalidate("setup")
        }
        // To the car question, with the chosen type on to connecting, and from there to the end.
        let goOn: @MainActor () -> Void = { [model, weak self] in
            switch flow.step {
            case .welcome:
                flow.step = .car
            case .car:
                guard let mode = flow.chosen else { return }
                flow.comparing = false
                model.applyChosenMode(mode)
                flow.step = .connect
                self?.invalidate("setup")
            case .connect:
                flow.step = .done
            case .done:
                finish()
            }
        }
        action("setup.wizardNext") { _ in
            // While the two types are compared there is no button to go on: a type is picked from a card.
            guard !(flow.step == .car && flow.comparing) else { return }
            goOn()
        }
        action("setup.wizardBack") { _ in
            switch flow.step {
            case .car: if flow.comparing { flow.comparing = false } else { flow.step = .welcome }
            case .connect: flow.step = .car
            default: break
            }
        }
        action("setup.wizardSkip") { _ in finish() }
        action("setup.wizardCar") { arguments in
            guard let choice = arguments.string("choice").flatMap(SetupFlow.CarChoice.init(rawValue:)) else { return }
            flow.carChoice = choice
            switch choice {
            case .olderSubaru: flow.chosen = .ssm
            case .newerSubaru, .otherBrand: flow.chosen = .obd
            case .notSure: flow.chosen = nil
            }
        }
        // "I have an OBD-II adapter instead", under the recommendation.
        action("setup.wizardPrefer") { arguments in
            guard let mode = arguments.string("mode").flatMap(ConnectionMode.init(rawValue:)) else { return }
            flow.chosen = mode
        }
        action("setup.wizardCompare") { arguments in
            guard flow.step == .car else { return }
            flow.comparing = arguments.bool("on")
        }
        // A type picked from the comparison: the wizard goes straight on with it.
        action("setup.wizardChoose") { arguments in
            guard flow.step == .car, let mode = arguments.string("mode").flatMap(ConnectionMode.init(rawValue:)) else { return }
            flow.chosen = mode
            flow.carChoice = mode == .ssm ? .olderSubaru : .newerSubaru
            goOn()
        }
        action("setup.wizardDemo") { [model] _ in
            guard flow.step == .connect, model.connection != .connecting else { return }
            flow.usedDemo = true
            if flow.chosen == .obd { model.selectedAdapterID = AppModel.demoOBDID } else { model.selectedPortID = AppModel.demoPortID }
            Task {
                await model.connect()
                flow.step = .done
            }
        }
    }

    // MARK: Wording for this computer

    /// The Windows app has no menu bar. What the Mac app has in its Car and Help menus is in Settings there.
    private static var inTheCarMenu: String { onWindows ? "in Settings" : "in the Car menu" }
    private static var inTheHelpMenu: String { onWindows ? "in Settings" : "in the Help menu" }

    /// The last part of a device's name: "cu.usbserial-A50285BI" on a Mac. On Windows a port has no folder: "COM4".
    private static func portName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    #if DEBUG
    static var standInCablePort: String? { UserDefaults.standard.string(forKey: "setupCablePort") }
    #endif

    // MARK: The sheets and the two connection types

    static func setupState(_ model: AppModel) -> SetupState {
        let hasChosen = ConnectionMode.hasChosen
        func card(_ mode: ConnectionMode) -> SetupState.ModeCard {
            let ssm = mode == .ssm
            let isCurrent = hasChosen && model.mode == mode
            var hardware = mode.hardware
            var needs = ssm ? ModeGuide.ssmNeeds : ModeGuide.obdNeeds
            if ssm && onWindows {
                // A PC gets the cable's driver from Windows Update.
                needs = needs.replacingOccurrences(of: "No driver needed.", with: "Windows installs its driver by itself.")
            }
            if !ssm && !bluetoothWorks {
                // The Mac app recommends a Bluetooth LE adapter here, which is the one kind a PC cannot use yet.
                hardware = "ELM327 adapter (USB, Wi-Fi, or Bluetooth paired in Windows)"
                needs = "An ELM327 adapter with USB or Wi-Fi, or a Bluetooth one that you pair in Windows Settings (it then shows up as a COM port). All three are new and experimental. An adapter that only has Bluetooth LE (BLE) cannot be used on a PC yet."
            }
            return SetupState.ModeCard(
                mode: mode.rawValue, title: mode.title, isNew: !ssm, hardware: hardware,
                bestFor: ssm ? ModeGuide.ssmBestFor : ModeGuide.obdBestFor,
                gets: ssm ? ModeGuide.ssmGets : ModeGuide.obdGets,
                missing: ssm ? [] : ModeGuide.obdMissing,
                needs: needs,
                cars: (ssm ? ModeGuide.ssmModels : ModeGuide.obdModels).map { .init(name: "\($0.model), \($0.years)", note: $0.note) },
                button: isCurrent ? "Keep using \(mode.title)" : "Use \(mode.title)",
                isCurrent: isCurrent)
        }
        return SetupState(
            showWizard: model.showWizard, showCableSetup: model.showCableSetup, showModeChooser: model.showModeChooser,
            canCloseModeChooser: hasChosen,
            chooserSubtitle: "Pick the one that fits your car and your hardware. You can change it any time \(inTheCarMenu).",
            notSure: ModeGuide.notSure.replacingOccurrences(of: "in the Car menu", with: inTheCarMenu),
            cards: [card(.ssm), card(.obd)],
            coffeeURL: About.coffeeURL.absoluteString, issuesURL: Links.issues.absoluteString)
    }

    // MARK: The wizard

    static func setupWizardState(_ model: AppModel, _ flow: SetupFlow) -> SetupWizardState {
        let computer = Bridge.computer
        let connected = model.connection.isConnected
        let obd = flow.chosen == .obd
        let device = obd ? "adapter" : "cable"

        let title: String
        var next: SetupWizardState.Button?
        switch flow.step {
        case .welcome:
            title = "Welcome to SubieScope"
            next = .init(label: "Let's go", prominent: true, enabled: true)
        case .car:
            title = flow.comparing ? "Compare the two ways to connect" : "What car do you have?"
            if !flow.comparing { next = .init(label: "Continue", prominent: true, enabled: flow.chosen != nil) }
        case .connect:
            title = obd ? "Connect the adapter" : "Connect the cable"
            next = connected ? .init(label: "Continue", prominent: true, enabled: true)
                : .init(label: "Continue without testing", prominent: false, enabled: true)
        case .done:
            title = flow.usedDemo ? "You're all set" : (connected ? "You're connected" : "You're all set")
            next = .init(label: "Start using SubieScope", prominent: true, enabled: true)
        }

        var recommendation: SetupWizardState.Recommendation?
        if let mode = flow.chosen {
            let other: ConnectionMode = mode == .ssm ? .obd : .ssm
            let text: String
            if mode == .ssm {
                text = "Subaru's own protocol gives you everything the ECU knows: knock, IAM, boost target and hundreds more values, plus all the troubleshooting tests. You need a VAG KKL 409.1 USB cable with an FTDI chip (about €10 to 15). "
                    + (onWindows ? "Windows installs its driver by itself." : "No driver needed.")
            } else if bluetoothWorks {
                text = "The standard protocol works on newer Subarus and on other brands, wirelessly. You get the basics (rpm, speed, temperatures, load, fuel trims, boost, trouble codes) but not Subaru-only values such as knock and IAM. You need an ELM327 adapter with Bluetooth 4.0 (BLE), such as the Vgate iCar Pro BLE 4.0."
            } else {
                text = "The standard protocol works on newer Subarus and on other brands. You get the basics (rpm, speed, temperatures, load, fuel trims, boost, trouble codes) but not Subaru-only values such as knock and IAM. You need an ELM327 adapter with USB or Wi-Fi, or a Bluetooth one that you pair in Windows Settings. An adapter that only has Bluetooth LE (BLE) cannot be used on a PC yet."
            }
            recommendation = .init(mode: mode.rawValue, title: "We recommend \(mode.title)", text: text,
                                   otherLabel: "I have \(other == .obd ? "an OBD-II adapter" : "the SSM USB cable") instead",
                                   otherMode: other.rawValue)
        }

        let doneTitle: String
        let doneDetail: String
        if flow.usedDemo {
            doneTitle = "You're looking at a simulated car"
            doneDetail = "Everything works as it would on a real car. When your \(device) arrives, choose it in the toolbar and press Connect."
        } else if connected {
            doneTitle = "Connected to your car"
            doneDetail = "Live data is running. Open the Dashboard to watch your gauges."
        } else {
            doneTitle = "Setup is done"
            doneDetail = "Choose your \(device) in the sidebar and press Connect when you are in the car with the ignition ON. Change the connection type any time \(inTheCarMenu)."
        }

        return SetupWizardState(
            step: flow.step == .car && flow.comparing ? "compare" : flow.step.name,
            title: title, index: flow.step.rawValue, count: SetupFlow.Step.allCases.count,
            canGoBack: flow.step != .welcome && flow.step != .done, canSkip: flow.step != .done, next: next,
            welcomeTitle: "Live data, diagnostics and a virtual dyno for your car, on your \(computer).",
            welcomeText: "SubieScope needs a small piece of hardware between your \(computer) and the car's diagnostic port, under the dashboard. This short setup helps you pick the right one and checks that it works. It takes about two minutes.",
            carChoice: flow.carChoice?.rawValue, recommendation: recommendation,
            connectMode: obd ? "obd" : "ssm", demoQuestion: "No \(device) yet?",
            doneConnected: connected, doneTitle: doneTitle, doneDetail: doneDetail,
            coffeeNote: "You can also find this later \(inTheHelpMenu).")
    }

    // MARK: The cable checks

    static func setupCableState(_ model: AppModel, _ flow: SetupFlow) -> SetupCableState {
        var cables = flow.cables.map { cable -> SetupCableState.Cable in
            let usable = model.canUse(cable)
            var text: String
            var driver: URL?
            if let path = cable.serialPath, usable {
                text = "Ready as \(portName(path))."
                // On a PC the port is there because Windows has installed the driver.
                if cable.chip == .ftdi && !onWindows { text += " No driver needed." }
                if cable.chip == .openPort2 { text += " Experimental: not tested with a real OpenPort yet." }
            } else {
                text = cable.chip.driverAdvice
                // With a port the driver is there, and what is missing is the setting the advice names.
                if cable.serialPath == nil { driver = cable.chip.driverURL }
            }
            var tip = cable.chip == .ch340 ? "Tip: FTDI-based KKL cables are the most reliable with Subarus." : nil
            // Windows only: the FTDI driver's own delay, which slows logging down until it is set to 1 ms.
            if cable.chip == .ftdi, let path = cable.serialPath, let latency = SerialPortList.driverLatency(ofPort: path), latency > 2 {
                tip = "Tip for faster logging: the cable's driver waits \(latency) ms before it passes on each answer from the car. In Device Manager, open Ports (COM & LPT), double-click the cable's \(portName(path)) port, and under Port Settings > Advanced set Latency Timer to 1. Then plug the cable in again."
            }
            return SetupCableState.Cable(
                id: cable.id, name: cable.productName ?? "USB cable", chip: cable.chip.name,
                hasPort: cable.serialPath != nil, usable: usable, text: text,
                driverURL: driver?.absoluteString,
                settingsButton: driver == nil ? nil : (onWindows ? "Open Device Manager" : "Open Privacy & Security"),
                tip: tip)
        }
        #if DEBUG
        if let stand = standInCablePort {
            cables.append(.init(id: "stand-in", name: "Stand-in cable", chip: "for testing", hasPort: true, usable: true,
                                text: "Ready as \(portName(stand)).", driverURL: nil, settingsButton: nil, tip: nil))
        }
        #endif
        var result: SetupCableState.Result?
        if let outcome = flow.outcome {
            let text = CableTest.explanation(outcome)
            result = .init(ok: flow.passed, title: text.title, detail: text.detail)
        }
        return SetupCableState(
            plugTitle: "Plug the cable into your \(computer)", cables: cables, passed: flow.passed, testing: flow.testing,
            canTest: !flow.testing && flow.cablePath != nil && !model.connection.isConnected,
            connected: model.connection.isConnected, result: result)
    }

    // MARK: The adapters

    static func setupAdapterState(_ model: AppModel, _ flow: SetupFlow) -> SetupAdapterState {
        let computer = Bridge.computer
        let selected = model.selectedAdapterID
        let connected = model.connection.isConnected
        let connecting = model.connection == .connecting
        let bluetooth = bluetoothWorks

        var result: SetupAdapterState.Result?
        switch model.connection {
        case .connected:
            result = .init(ok: true, title: "Connected", detail: "The adapter found your car. Finding the car the first time can take a few seconds.")
        case .failed(let message):
            result = .init(ok: false, title: "That didn't work", detail: message)
        default:
            break
        }

        return SetupAdapterState(
            bluetooth: bluetooth,
            bluetoothProblem: bluetooth ? model.bleStatus.message : nil,
            bluetoothNotAsked: bluetooth && !flow.searching && model.bleStatus == .idle,
            bluetoothAdapters: bluetooth ? model.bleAdapters.prefix(8).map {
                .init(id: $0.id, name: $0.name, selected: $0.id == selected, looksLikeOBD: $0.looksLikeOBD)
            } : [],
            ports: model.ports.map {
                let id = AppModel.usbAdapterID($0)
                return .init(id: id, name: AppModel.usbAdapterLabel($0), selected: id == selected, looksLikeOBD: false)
            },
            wifi: .init(id: model.wifiAdapterID, name: "Wi-Fi adapter at", selected: model.wifiAdapterID == selected, looksLikeOBD: false),
            wifiAddress: model.wifiAddress,
            locked: connected || connecting,
            othersOpen: model.selectedAdapterKind != .bluetooth,
            pcNote: bluetooth ? nil : "SubieScope for Windows works with a USB adapter, a Wi-Fi adapter, or a Bluetooth adapter that you pair in Windows Settings > Bluetooth & devices. A paired adapter shows up in this list as a COM port. An adapter that only has Bluetooth LE (BLE) cannot be used on a PC yet.",
            // Only while it is true: the list is not looked at again once the car is connected.
            noPortsNote: bluetooth || !model.ports.isEmpty || connected || connecting ? nil
                : "No USB or paired Bluetooth adapter found yet. SubieScope keeps looking.",
            experimentalNote: "New, and tested with a simulated adapter only. If yours does not work, please send a report from \(onWindows ? "Settings" : "the Help menu").",
            wifiNote: "Wi-Fi: join the adapter's own Wi-Fi network on your \(computer) first.",
            // Without Bluetooth nothing shows that the adapter has power, until the car answers.
            pluggedIn: connected || (bluetooth && !model.bleAdapters.isEmpty),
            chosen: connected || (selected != nil && selected != AppModel.demoOBDID),
            canTest: !connecting && !connected && selected != nil && selected != AppModel.demoOBDID,
            connecting: connecting, connected: connected, result: result)
    }

    // MARK: The panel

    static func setupPanelState(_ model: AppModel) -> SetupPanelState {
        let computer = Bridge.computer
        let connected = model.connection.isConnected
        let obd = model.mode == .obd

        var cables: [SetupPanelState.Cable]?
        var noCable: String?
        var portChoices: [AppState.Device] = []
        if !obd {
            if model.cables.isEmpty && model.ports.isEmpty {
                noCable = "No USB cable found. Plug the KKL cable into your \(computer) (use a USB-C adapter if needed)."
            } else {
                cables = model.cables.map { cable in
                    let title = "\(cable.productName ?? "USB cable") · \(cable.chip.name)"
                    if cable.chip == .openPort2, cable.serialPath != nil, !model.openPortOn {
                        return .init(id: cable.id, title: title,
                                     text: "SubieScope's support for the OpenPort is new and experimental. It has not been tested with a real one yet.",
                                     needsDriver: false, offerOpenPort: true)
                    } else if let path = cable.serialPath {
                        // On a PC the port is there because Windows has installed the driver.
                        let extra = cable.chip == .ftdi ? (onWindows ? "" : ", no driver needed") : cable.chip == .openPort2 ? " (experimental)" : ""
                        return .init(id: cable.id, title: title, text: "Ready as \(portName(path))\(extra)", needsDriver: false, offerOpenPort: false)
                    }
                    return .init(id: cable.id, title: title, text: cable.chip.driverAdvice, needsDriver: true, offerOpenPort: false)
                }
                if model.ports.count > 1 && !connected {
                    portChoices = model.ports.map { .init(id: $0.path, label: $0.displayName) }
                    portChoices.append(.init(id: AppModel.demoPortID, label: "Demo ECU (simulated)"))
                }
            }
        }

        var facts: [SetupPanelState.Fact] = []
        var checklist: [SetupPanelState.Check] = []
        if obd {
            if connected, let info = model.obdInfo {
                facts.append(.init(label: "Adapter", value: info.adapter, mono: false))
                if !info.protocolName.isEmpty { facts.append(.init(label: "Protocol", value: info.protocolName, mono: false)) }
                if let vin = info.vin { facts.append(.init(label: "VIN", value: vin, mono: true)) }
                facts.append(.init(label: "Values", value: "\(model.parameters.count) available", mono: false))
            } else {
                checklist = adapterChecklist(model)
            }
        } else if connected, let identity = model.identity {
            facts.append(.init(label: "ECU ID", value: identity.ecuID, mono: true))
            if let car = model.knownECUDescription { facts.append(.init(label: "Car", value: car, mono: false)) }
            if let engine = EngineDiagnostics.engineType(systemID: identity.systemID) { facts.append(.init(label: "Engine", value: engine, mono: false)) }
        } else {
            let found = model.cables.contains { model.canUse($0) }
            checklist = [
                .init(done: found, text: "Plug the cable into your \(computer)",
                      detail: onWindows
                        ? "Windows installs the driver for a VAG KKL cable with an FTDI chip by itself, the first time you plug it in. Use a USB-C adapter if needed."
                        : "A VAG KKL cable with an FTDI chip needs no driver. Use a USB-C adapter if needed."),
                .init(done: false, text: "Plug it into the car and turn the ignition ON",
                      detail: "The OBD port is under the dashboard on the driver's side. The engine may be off or running. Cable with a switch: use the K-line (pin 7) position."),
                .init(done: false, text: "Press Connect",
                      detail: "SubieScope finds the ECU and remembers the cable. Not working? Cable Setup tests each step and tells you what's wrong."),
            ]
        }

        var hardware = obd ? model.adapterKindLabel : "USB cable"
        if obd && onWindows {
            // The model calls every serial port a USB adapter, and no choice at all a Bluetooth one.
            if pairedPort(model) != nil { hardware = "Bluetooth adapter" }
            if !bluetoothWorks && model.selectedAdapterKind == .bluetooth { hardware = "ELM327 adapter" }
        }

        return SetupPanelState(
            status: setupPanelStatus(model),
            modeLine: "\(model.mode.title): \(hardware)",
            canChangeMode: !connected && model.connection != .connecting,
            cables: cables, noCable: noCable, portChoices: portChoices,
            facts: facts, checklist: checklist, widebandOn: model.widebandOn)
    }

    /// The connection card's summary. The card takes "no adapter chosen" for a Bluetooth adapter and
    /// then reports what is wrong with Bluetooth. Where Bluetooth LE cannot be used, that is not the
    /// problem: no adapter that works here has been chosen yet.
    private static func setupPanelStatus(_ model: AppModel) -> AppState.Status {
        let playingLog = model.isPlayingBack && model.playback != nil
        if !bluetoothWorks, model.mode == .obd, model.connection == .disconnected, !playingLog,
           model.selectedAdapterID != AppModel.demoOBDID, model.selectedAdapterKind == .bluetooth {
            return .init(badge: "Not connected", title: "No adapter chosen",
                         detail: "Pick a USB, Wi-Fi or paired Bluetooth adapter below, then press Connect.", color: "gray")
        }
        return status(model)
    }

    /// The chosen adapter when it is a serial port without USB behind it: on a PC that is a
    /// Bluetooth adapter that Windows is paired with.
    private static func pairedPort(_ model: AppModel) -> SerialPortInfo? {
        guard let port = model.ports.first(where: { AppModel.usbAdapterID($0) == model.selectedAdapterID }), !port.isUSB else { return nil }
        return port
    }

    /// How to connect in OBD-II mode, for the kind of adapter that is chosen.
    private static func adapterChecklist(_ model: AppModel) -> [SetupPanelState.Check] {
        let computer = Bridge.computer
        let obdPort = "The OBD port is under the dashboard on the driver's side."
        switch model.selectedAdapterKind {
        case .bluetooth where bluetoothWorks:
            return [
                .init(done: model.bleStatus.message == nil, text: "Plug the adapter into the car",
                      detail: "\(obdPort) Use an ELM327 adapter with Bluetooth 4.0 (BLE), such as the Vgate iCar Pro."),
                .init(done: !model.bleAdapters.isEmpty, text: "Turn the ignition ON",
                      detail: "The engine may be off or running. The adapter switches on and appears in the list. Close other apps that use it: it accepts one connection at a time."),
                .init(done: model.selectedAdapterID != nil, text: "Pick it and press Connect",
                      detail: "The first time, macOS asks whether SubieScope may use Bluetooth. Say yes. Finding the car can take up to 10 seconds."),
            ]
        case .bluetooth:
            // On a PC nothing is chosen yet: the three kinds that work there, in one list.
            return [
                .init(done: false, text: "Plug the adapter into the car and turn the ignition ON",
                      detail: "\(obdPort) The engine may be off or running. Close other apps that use the adapter: it accepts one connection at a time."),
                .init(done: !model.ports.isEmpty, text: "Connect the adapter to your PC",
                      detail: "USB: plug it into your PC. Wi-Fi: join the adapter's own Wi-Fi network. Bluetooth: pair it in Windows Settings > Bluetooth & devices, and it shows up above as a COM port."),
                .init(done: false, text: "Pick it and press Connect",
                      detail: "Finding the car can take up to 10 seconds. An adapter that only has Bluetooth LE (BLE) cannot be used on a PC yet."),
            ]
        case .usb:
            let port = model.ports.first { AppModel.usbAdapterID($0) == model.selectedAdapterID }
            if onWindows, pairedPort(model) != nil {
                return [
                    .init(done: true, text: "Pair the adapter with your PC",
                          detail: "It has to be an ELM327 type adapter. Windows gives a paired adapter a COM port, which is the one you picked."),
                    .init(done: false, text: "Plug it into the car and turn the ignition ON",
                          detail: "\(obdPort) The engine may be off or running."),
                    .init(done: false, text: "Press Connect",
                          detail: "SubieScope tries the speeds these adapters use, which takes a few seconds, and then looks for the car."),
                ]
            }
            return [
                .init(done: port != nil, text: "Plug the adapter into your \(computer) and into the car",
                      detail: "It has to be an ELM327 type adapter. \(obdPort)"),
                .init(done: false, text: "Turn the ignition ON", detail: "The engine may be off or running."),
                .init(done: false, text: "Press Connect",
                      detail: "SubieScope tries the speeds these adapters use, which takes a few seconds, and then looks for the car."),
            ]
        case .wifi:
            return [
                .init(done: false, text: "Plug the adapter into the car and turn the ignition ON",
                      detail: "\(obdPort) The engine may be off or running."),
                .init(done: false, text: "Join the adapter's Wi-Fi network on your \(computer)",
                      detail: onWindows
                        ? "It shows up in the list of Wi-Fi networks, often as WiFi_OBDII or V-LINK. Your PC has no internet while it is on that network."
                        : "It shows up in the Wi-Fi menu, often as WiFi_OBDII or V-LINK. Your Mac has no internet while it is on that network."),
                .init(done: false, text: "Press Connect",
                      detail: onWindows
                        ? "Most adapters use the address 192.168.0.10:35000. If yours has another one, type it in the field above."
                        : "macOS may ask whether SubieScope may find devices on your local network. Say yes. Most adapters use the address 192.168.0.10:35000."),
            ]
        }
    }
}
#endif
