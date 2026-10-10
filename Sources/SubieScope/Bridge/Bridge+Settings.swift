#if os(Windows) || DEBUG
import Foundation
import SSMKit

/// Settings, and what comes with it: the About tab (which on Windows is also the home of what the Mac
/// app keeps in its SubieScope and Help menus), the "new version" sheet and the question after a crash.
extension Bridge {
    /// The General tab. Its sentences are in the page, apart from the ones that differ on a PC.
    struct SettingsState: Encodable {
        struct Choice: Encodable {
            let value: String
            let label: String
        }

        /// "ssm" or "obd": some settings belong to one connection type only.
        let mode: String
        /// What the connection type row says: "Subaru SSM: USB cable (VAG KKL, FTDI chip)".
        let connectionType: String
        let connected: Bool
        let connecting: Bool
        /// "metric" or "imperial"
        let unitSystem: String
        let pressureUnit: String
        let pressureUnits: [Choice]
        /// The folder for recorded logs, as this computer writes a path.
        let logsFolder: String
        let autoConnect: Bool
        let autoUpdateCheck: Bool
        /// OBD-II only: the manufacturer specific values (Mode 22).
        let extendedValues: Bool
        /// Turning this on goes through the warning sheet (the action `rom.showDisclaimer`), never straight to true.
        let advancedMode: Bool
        let remoteControl: Bool
        /// SSM only. Whether the OpenPort is a setting at all: on a Mac it is simply used.
        let openPortIsSetting: Bool
        let openPort: Bool
        /// SSM only, and only shown with the OpenPort on: talk to the ECU over CAN.
        let openPortCAN: Bool
        let openPortCANNote: String
        let fastPoll: Bool
        /// The sentence under the OpenPort setting. A PC needs a driver for that cable, a Mac does not.
        let openPortNote: String
        /// A sheet the app asks for is up (the connection type, the setup wizard, the warning before
        /// Advanced mode, a new version, …). The Mac shows those on the main window, next to the Settings
        /// window. The page has one window, so Settings steps aside until the sheet is answered.
        let steppedAside: Bool
    }

    /// The Wideband tab.
    struct WidebandSettings: Encodable {
        struct Port: Encodable {
            let id: String
            let label: String
        }

        let on: Bool
        /// The ports the gauge can be on. A saved port that is not plugged in right now is the first one.
        let ports: [Port]
        let selectedPort: String?
        /// The demo car has a gauge of its own: there is nothing to choose while it is connected.
        let portLocked: Bool
        /// What the gauge's listener is doing, in a sentence. Orange when `hasProblem`.
        let status: String
        let hasProblem: Bool
    }

    /// The Definitions tab.
    struct DefinitionsSettings: Encodable {
        struct Loaded: Encodable {
            /// The file's name.
            let file: String
            let version: String
            /// "120 standard, 300 ECU specific, 80 switches, 400 trouble codes"
            let contents: String
        }

        /// Nil while there are no definitions (not downloaded yet, or a file that could not be read).
        let loaded: Loaded?
        let error: String?
        let downloading: Bool
    }

    /// The About tab, with the Mac app's menu commands about the app itself.
    struct AboutState: Encodable {
        /// "Version 0.6.0", or "Development build".
        let version: String
        let checkingForUpdates: Bool
        /// "Show Log in File Explorer"
        let showLogLabel: String
        /// What sending a report does here: a PC cannot put a file into a new email.
        let sendReportHelp: String
        let coffeeLink: String
        let repositoryLink: String
        let issuesLink: String
    }

    /// A newer release to tell the person about.
    struct UpdateState: Encodable {
        /// "0.7.0"
        let version: String
        /// "You have version 0.6.0."
        let current: String
        /// The list of changes, as Markdown: paragraphs, "- " lists and "#" headings. Empty when the release says nothing.
        let whatsNew: String
        /// What the main button does and what to do after it.
        let instructions: String
        /// "Download", or "Open Download Page" on a PC as long as a release has no file for Windows.
        let downloadLabel: String
    }

    /// The question after a run that did not end well.
    struct CrashQuestion: Encodable {
        let title: String
        let message: String
    }

    func registerSettings() {
        slice("settings") { [model] in
            // The Mac's words for an OBD-II adapter recommend Bluetooth LE, which the PC cannot use yet.
            let hardware = model.mode == .obd && !Bridge.bluetoothWorks
                ? "ELM327 adapter (USB, Wi-Fi or Bluetooth paired in Windows)" : model.mode.hardware
            let driver = Bridge.onWindows
                ? "An original cable needs Tactrix's own driver, which comes with EcuFlash: install that first, then plug the cable in and press Connect. Is yours a replica? Then do NOT install Tactrix's driver or EcuFlash, and do not plug it into a PC that has them: they update the cable's firmware, and that breaks a replica for good. Plug a replica in as it is: Windows 10 and 11 should give it a COM port by themselves, though that has not been tried yet."
                : "It needs no driver: plug it in and press Connect."
            // On a Mac the cable has been on a car. On a PC it never has.
            let tested = Bridge.onWindows
                ? "It works in the Mac version, but it has not been tried on a PC yet, so it may not work here."
                : "It has been tested on one car so far, a 2009 WRX STI, so it may not work on yours."
            return SettingsState(
                mode: model.mode.rawValue,
                connectionType: "\(model.mode.title): \(hardware)",
                connected: model.connection.isConnected,
                connecting: model.connection == .connecting,
                unitSystem: model.unitSystem.rawValue,
                pressureUnit: model.pressureUnit.rawValue,
                pressureUnits: PressureUnit.allCases.map { .init(value: $0.rawValue, label: $0.title) },
                logsFolder: Bridge.shownPath(model.logsFolder),
                autoConnect: model.autoConnect,
                autoUpdateCheck: model.autoUpdateCheck,
                extendedValues: model.extendedValuesOn,
                advancedMode: model.advancedMode,
                remoteControl: model.remoteControlOn,
                openPortIsSetting: !AppModel.openPortIsBuiltIn,
                openPort: model.openPortOn,
                openPortCAN: model.openPortCAN,
                openPortCANNote: AppModel.openPortCANNote,
                fastPoll: model.fastPoll,
                openPortNote: "Lets you connect with a Tactrix OpenPort 2.0 instead of a KKL cable. \(driver) Take the microSD card out of the cable first. \(tested) With Advanced mode on, it can also read the ROM from the car.",
                steppedAside: model.showModeChooser || model.showWizard || model.showCableSetup || model.showAdvancedDisclaimer
                    || model.updateOffer != nil || model.showCrashPrompt)
        }

        // The status reads the gauge's newest value, which comes with every sample: held back to a few a second.
        slice("settings.wideband", atMost: 5) { [model] in
            var ports: [WidebandSettings.Port] = []
            var status = ""
            if model.widebandOn {
                // A saved port that is not plugged in right now still needs its row.
                if let saved = model.widebandPortID, !model.widebandPorts.contains(where: { $0.path == saved }) {
                    ports.append(.init(id: saved, label: "\((saved as NSString).lastPathComponent) (not plugged in)"))
                }
                ports += model.widebandPorts.map { .init(id: $0.path, label: $0.displayName) }
                // The model's own sentence about a lost adapter says "your Mac".
                status = model.widebandStatusText.replacingOccurrences(of: "your Mac", with: "your \(Bridge.computer)")
            }
            return WidebandSettings(
                on: model.widebandOn, ports: ports, selectedPort: model.widebandPortID,
                portLocked: model.isDemo && model.connection.isConnected,
                status: status, hasProblem: model.widebandHasProblem)
        }

        slice("settings.definitions") { [model] in
            let loaded = model.definitions.map { definitions in
                DefinitionsSettings.Loaded(
                    file: definitions.sourceURL.lastPathComponent, version: definitions.version ?? "?",
                    contents: "\(definitions.standard.count) standard, \(definitions.extended.count) ECU specific, \(definitions.switches.count) switches, \(definitions.codes.count) trouble codes")
            }
            return DefinitionsSettings(loaded: loaded, error: model.definitionsError, downloading: model.downloadingDefinitions)
        }

        slice("settings.about") { [model] in
            AboutState(
                version: About.version.map { "Version \($0)" } ?? "Development build",
                checkingForUpdates: model.checkingForUpdates,
                showLogLabel: "Show Log in \(Bridge.fileBrowser)",
                sendReportHelp: Bridge.onWindows
                    ? "Makes a report file (the log and a few facts about your PC) and shows it in File Explorer, ready to email to the developer"
                    : "Opens a new email to the developer with the report (the log and your Mac model) attached",
                coffeeLink: About.coffeeURL.absoluteString,
                repositoryLink: Links.repository.absoluteString,
                issuesLink: Links.issues.absoluteString)
        }

        slice("settings.update") { [model] () -> UpdateState? in
            guard let release = model.updateOffer else { return nil }
            let instructions: String
            var label = "Download"
            if !Bridge.onWindows {
                instructions = "Download fetches the new version with your browser. Then quit SubieScope, open the downloaded file and drag SubieScope to Applications, replacing the old one. Your settings and logs stay as they are."
            } else if Bridge.fileForThisComputer(release) != nil {
                instructions = "Download fetches the new version with your browser. Then quit SubieScope and open the downloaded file to put the new version in the place of the old one. Your settings and logs stay as they are."
            } else {
                label = "Open Download Page"
                instructions = "Open Download Page shows the new version in your browser. Download the Windows version there, quit SubieScope and put the new version in the place of the old one. Your settings and logs stay as they are."
            }
            return UpdateState(
                version: release.version,
                current: About.version.map { "You have version \($0)." } ?? "You are running a development build.",
                whatsNew: release.whatsNew,
                instructions: instructions,
                downloadLabel: label)
        }

        slice("settings.crash") { [model] () -> CrashQuestion? in
            guard model.showCrashPrompt else { return nil }
            let holds = Bridge.onWindows ? "the log of what happened and a few facts about your PC (its processor and Windows version)"
                : "the log of what happened and your Mac model"
            return CrashQuestion(
                title: "SubieScope quit unexpectedly last time",
                message: "Sorry about that. A report helps to find out why. It holds \(holds), and nothing else. To be safe, SubieScope did not connect automatically this time: press Connect when you are ready.")
        }

        // MARK: The settings themselves

        // One setting by its name: `on` for a switch, `value` for a choice from a list.
        action("settings.set") { [model] arguments in
            let on = arguments.bool("on")
            let value = arguments.string("value")
            switch arguments.string("name") {
            case "unitSystem":
                if let units = value.flatMap(UnitSystem.init(rawValue:)) { model.unitSystem = units }
            case "pressureUnit":
                if let unit = value.flatMap(PressureUnit.init(rawValue:)) { model.pressureUnit = unit }
            case "autoConnect": model.autoConnect = on
            case "autoUpdateCheck": model.autoUpdateCheck = on
            case "extendedValues": model.extendedValuesOn = on
            // Only off: on is for the warning sheet to do, once the person has accepted it.
            case "advancedMode": if !on { model.advancedMode = false }
            case "remoteControl": model.remoteControlOn = on
            // Not under a connection that is using the cable.
            case "openPort": if !model.connection.isConnected { model.openPortOn = on }
            case "openPortCAN": if model.connection != .connecting { model.openPortCAN = on }
            case "fastPoll": model.fastPoll = on
            case "wideband": model.widebandOn = on
            // Without a value: no port chosen.
            case "widebandPort":
                guard !(model.isDemo && model.connection.isConnected) else { return }
                model.widebandPortID = value.flatMap { $0.isEmpty ? nil : $0 }
            default: break
            }
        }
        // The Wideband tab opens: a gauge's adapter that was just plugged in should be in the list.
        action("settings.refreshPorts") { [model] _ in model.refreshPorts() }

        // A dialog of the computer's own has a message loop of its own. It is opened after this
        // action has returned (the Task), not in the middle of the page's message to the app.
        action("settings.chooseLogsFolder") { [model] _ in
            Task { @MainActor in
                guard let folder = Desktop.chooseFolder(title: "Choose the folder for your recorded logs") else { return }
                model.logsFolder = folder
            }
        }
        action("settings.chooseDefinitions") { [model] _ in
            Task { @MainActor in
                guard let file = Desktop.chooseFileToOpen(filter: ["RomRaider logger definitions", "*.xml"]) else { return }
                model.loadDefinitions(from: file)
            }
        }
        action("settings.useDownloadedDefinitions") { [model] _ in model.useBundledDefinitions() }
        action("settings.downloadDefinitions") { [model] _ in
            Task { await model.downloadDefinitions() }
        }

        // MARK: What the Mac app has in its SubieScope and Help menus

        // Always answers: with the new version's sheet, with "up to date", or with what went wrong.
        action("settings.checkForUpdates") { [model] _ in
            Task { await model.checkForUpdates(manual: true) }
        }
        action("settings.sendReport") { [model] _ in
            Task { @MainActor in DiagnosticReporter.send(model: model) }
        }
        action("settings.saveReport") { [model] _ in
            Task { @MainActor in DiagnosticReporter.save(model: model) }
        }
        action("settings.showLog") { _ in DiagnosticReporter.revealLog() }

        // MARK: The new version's sheet

        action("settings.downloadUpdate") { [model] _ in
            guard let release = model.updateOffer else { return }
            if Bridge.onWindows {
                Desktop.open(Bridge.fileForThisComputer(release) ?? release.page)
                model.updateOffer = nil
            } else {
                model.downloadUpdate(release)
            }
        }
        action("settings.skipUpdate") { [model] _ in
            guard let release = model.updateOffer else { return }
            model.skipUpdate(release)
        }
        action("settings.postponeUpdate") { [model] _ in model.updateOffer = nil }

        // MARK: The question after a crash

        // `send` is the answer "Send Report…"; without it the question just goes away.
        action("settings.answerCrash") { [model] arguments in
            guard model.showCrashPrompt else { return }
            model.showCrashPrompt = false
            if arguments.bool("send") {
                Task { @MainActor in DiagnosticReporter.send(model: model) }
            }
        }
    }

    /// The file of a release that this computer can use. A release's file is the Mac's disk image so
    /// far, which is of no use to a PC: until a release has a file for Windows (and SSMKit's UpdateCheck
    /// picks that one there), a PC is shown the release's page instead.
    private static func fileForThisComputer(_ release: UpdateRelease) -> URL? {
        guard let file = release.download else { return nil }
        return Bridge.onWindows && file.pathExtension.lowercased() == "dmg" ? nil : file
    }

    /// A file or folder the way this computer writes it: C:\Users\… on a PC.
    private static func shownPath(_ url: URL) -> String {
        #if os(Windows)
        return Desktop.path(url)
        #else
        return url.path
        #endif
    }
}
#endif
