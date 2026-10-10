#if os(Windows) || DEBUG
import Foundation
import SSMKit

/// ECU Info: what the car's control unit says about itself, what SubieScope knows about it, and how
/// the two are connected. Over OBD-II the same place shows the car, the adapter and the search for
/// extended values.
extension Bridge {
    struct ECUInfoState: Encodable {
        struct Item: Encodable {
            /// "row": a name with its value. "note": a sentence in gray. "callout": a smaller sentence
            /// in gray, which explains the row above it. "warning": a small sentence in orange behind a
            /// warning sign. "error": a sentence in red.
            let kind: String
            /// The name of a row. Empty for the other kinds.
            let label: String
            /// The value of a row, or the sentence.
            let value: String
            /// The value is an ID: it is shown in a fixed-width font.
            let mono: Bool

            static func row(_ label: String, _ value: String, mono: Bool = false) -> Item {
                Item(kind: "row", label: label, value: value, mono: mono)
            }

            static func sentence(_ kind: String, _ text: String) -> Item {
                Item(kind: kind, label: "", value: text, mono: false)
            }
        }

        struct Section: Encodable {
            let title: String
            let items: [Item]
            /// The rows of `ecuinfo.live` (sample rate, last poll) come at the end of this section.
            var endsWithLiveRows = false
        }

        /// OBD-II only: the search for extended (Mode 22) values.
        struct Extended: Encodable {
            let title: String
            let toggle: String
            let on: Bool
            /// How the search went. Nil before there was one: then `help` says what it is for.
            let state: String?
            let searching: Bool
            let canLookAgain: Bool
            let help: String
        }

        /// OBD-II only: what this mode can and cannot do, with the way to the other one.
        struct About: Encodable {
            let title: String
            let text: String
            let canChangeConnectionType: Bool
        }

        /// SSM only: the Copy Info button in the toolbar.
        struct CopyButton: Encodable {
            let help: String
            let enabled: Bool
        }

        /// "ssm" or "obd"
        let mode: String
        let sections: [Section]
        let extended: Extended?
        let about: About?
        let copy: CopyButton?
    }

    struct ECUInfoLive: Encodable {
        /// How fast the car answers right now. Empty while not connected.
        let rows: [ECUInfoState.Item]
    }

    func registerECUInfo() {
        slice("ecuinfo") { [model] in
            model.mode == .obd ? Bridge.ecuInfoOBD(model) : Bridge.ecuInfoSSM(model)
        }

        // These two change with every sample, so they have a slice of their own.
        slice("ecuinfo.live", atMost: 4) { [model] in
            guard model.connection.isConnected else { return ECUInfoLive(rows: []) }
            return ECUInfoLive(rows: [.row("Sample rate", String(format: "%.1f samples/s", model.samplesPerSecond)),
                                      .row("Last poll", String(format: "%.0f ms", model.lastRoundTrip * 1000))])
        }

        // The ECU details on the clipboard, for a question on a forum. (The Mac app's `ECUInfoView.summary`.)
        action("ecuinfo.copy") { [model] _ in
            guard let id = model.identity else { return }
            let known = Bridge.knownECUs(model)
            let rom = known.first.map { ecu in
                "\nROM: \(known.map(\.calID).joined(separator: " or ")), \(ecu.processor ?? "?"), flash method \(ecu.flashMethod ?? "?")"
            } ?? ""
            Desktop.copy("""
            ECU ID: \(id.ecuID)
            SSM system ID: \(id.systemIDString) (\(EngineDiagnostics.engineType(systemID: id.systemID) ?? "unknown engine"))
            Car: \(model.knownECUDescription ?? "unknown")\(rom)
            Capabilities (\(id.capabilities.count) bytes): \(id.capabilities.hexString)
            Definitions: \(model.definitions?.sourceURL.lastPathComponent ?? "-") v\(model.definitions?.version ?? "?")
            Extended parameters available: \(model.extendedCount)
            """)
        }
        action("ecuinfo.extendedValues") { [model] arguments in
            model.extendedValuesOn = arguments.bool("on")
        }
        action("ecuinfo.lookAgain") { [model] _ in
            guard model.connection.isConnected, !model.extendedSearching else { return }
            Task { await model.discoverExtendedValues() }
        }
    }

    /// With an SSM cable: the control unit, its ROM, its status, what is known about it. (The Mac app's `ECUInfoView.ssmBody`.)
    static func ecuInfoSSM(_ model: AppModel) -> ECUInfoState {
        typealias Item = ECUInfoState.Item
        var sections: [ECUInfoState.Section] = []

        if let id = model.identity {
            sections.append(.init(title: "Control unit", items: [
                .row("ECU ID", id.ecuID, mono: true),
                .row("Car", model.knownECUDescription ?? "Not in SubieScope's list of known ECUs"),
                .row("Engine", EngineDiagnostics.engineType(systemID: id.systemID) ?? "Unknown"),
                .row("SSM system ID", id.systemIDString, mono: true),
                .row("Capability bytes", "\(id.capabilities.count)"),
                .row("VIN", model.vinState),
            ]))
        } else {
            sections.append(.init(title: "Control unit", items: [.sentence("note", "Connect to read the ECU's identification.")]))
        }

        // What the ECU ID says about the ROM inside. An ECU that is not in the list has no such section.
        let known = Bridge.knownECUs(model)
        if let ecu = known.first {
            var rom: [Item] = [.row("Calibration ID", known.map(\.calID).joined(separator: " or "), mono: true)]
            if let processor = ecu.processorDescription { rom.append(.row("Processor", processor)) }
            if let transport = ecu.flashTransport, let method = ecu.flashMethod {
                rom.append(.row("Read and written over", "\(transport == .can ? "CAN" : "K-line") (EcuFlash calls it \(method))"))
                rom.append(.sentence("callout", Bridge.ecuInfoROMNote(transport)))
            }
            sections.append(.init(title: "ROM", items: rom))
        }

        if let status = model.engineStatus {
            var items: [Item] = []
            if let on = status.ignitionOn { items.append(.row("Ignition", on ? "On" : "Off")) }
            if let on = status.testMode { items.append(.row("Test mode connector", on ? "Connected (test mode)" : "Not connected")) }
            if let pending = status.dCheckPending { items.append(.row("Self check (D-Check)", pending ? "Not yet completed" : "Completed")) }
            sections.append(.init(title: "Status", items: items))
        }

        let kinds: [(String, ParameterKind)] = [("Standard", .standard), ("ECU specific (extended)", .extended),
                                                ("Calculated", .calculated), ("Switches", .switchBit)]
        var parameters: [Item] = kinds.map { title, kind in
            .row(title, "\(model.parameters.filter { $0.kind == kind }.count)")
        }
        parameters.append(.row("Trouble codes known", "\(model.codeDefinitions.count)"))
        if model.identity != nil && model.extendedCount == 0 {
            parameters.append(.sentence("warning", "This ECU ID is not in the definitions, so knock learning, IAM and other ECU-specific values are unavailable. Standard parameters still work."))
        }
        sections.append(.init(title: "Parameters for this ECU", items: parameters))

        if let definitions = model.definitions {
            sections.append(.init(title: "Definitions", items: [
                .row("File", definitions.sourceURL.lastPathComponent),
                .row("Version", definitions.version ?? "?"),
                .row("ECU IDs with extended parameters", "\(definitions.ecuIDCount)"),
            ]))
        } else {
            sections.append(.init(title: "Definitions", items: [.sentence("error", model.definitionsError ?? "No definitions loaded")]))
        }

        sections.append(.init(title: "Connection", items: [
            .row("Cable", model.selectedPortLabel),
            .row("Protocol", "SSM2 over K-line (ISO 9141), 4800 baud 8N1"),
            .row("Fast poll", model.fastPoll ? "On" : "Off"),
        ], endsWithLiveRows: true))

        return ECUInfoState(
            mode: "ssm", sections: sections, extended: nil, about: nil,
            copy: .init(help: "Copy the ECU details, e.g. to ask for help on a forum", enabled: model.identity != nil))
    }

    /// Over OBD-II: the car, the adapter, and the search for extended values. (The Mac app's `ECUInfoView.obdBody`.)
    static func ecuInfoOBD(_ model: AppModel) -> ECUInfoState {
        typealias Item = ECUInfoState.Item
        let connected = model.connection.isConnected

        var car: [Item] = []
        if let info = model.obdInfo {
            car.append(.row("VIN", info.vin ?? "Not reported by this car", mono: info.vin != nil))
            if let rom = model.extendedDiscovery?.romID { car.append(.row("ECU ID", rom, mono: true)) }
            car.append(.row("Standard values supported", "\(info.supportedPIDs.filter { $0 % 0x20 != 0 }.count)"))
            if let volts = info.voltage { car.append(.row("Battery voltage at the port", String(format: "%.1f V", volts))) }
        } else {
            car = [.sentence("note", "Connect to read the car's identification.")]
        }

        let protocolName = model.obdInfo?.protocolName ?? ""
        let adapter: [Item] = [
            .row("Adapter", connected ? (model.obdInfo?.adapter ?? "?") : model.selectedAdapterLabel),
            .row("Bus protocol", protocolName.isEmpty ? "Found when connecting" : protocolName),
        ]

        let extended = ECUInfoState.Extended(
            title: "Extended values (experimental)",
            toggle: "Look for extended values (Mode 22)",
            on: model.extendedValuesOn,
            state: model.extendedState.map { Bridge.reportPlaceReworded($0) },
            searching: model.extendedSearching,
            canLookAgain: connected && !model.extendedSearching,
            help: "Newer Subarus can report AVCS (VVT) angles, knock and boost control this way. Turn this on and connect: SubieScope checks which values your car answers and offers those in the Logger. It might work on Subarus from about 2015, including cars with the FA20 or FA24 engine, but it has not been tested on a real one yet. If you try it, \(Bridge.reportPlace) shows the developer what your car answered.")

        let about = ECUInfoState.About(
            title: "About OBD-II mode",
            text: "OBD-II mode reads the values every car reports by law. Subaru-only values such as knock correction, IAM and AVCS are only available with a KKL cable in Subaru SSM mode, on cars that support it.",
            canChangeConnectionType: !connected)

        return ECUInfoState(
            mode: "obd",
            sections: [.init(title: "Car", items: car), .init(title: "Adapter", items: adapter, endsWithLiveRows: true)],
            extended: extended, about: about, copy: nil)
    }

    /// What the ECU ID says about the ROM inside. Empty for an ECU that is not in the list, and
    /// while there is no ECU. (The Mac app's `ECUInfoView.knownECUs`.)
    static func knownECUs(_ model: AppModel) -> [KnownECU] {
        model.identity.map { KnownECU.lookup($0.ecuID) } ?? []
    }

    /// What the way a ROM travels means for the owner's cable and for this app. (The Mac app's `ECUInfoView.romNote`.)
    static func ecuInfoROMNote(_ transport: KnownECU.FlashTransport) -> String {
        switch transport {
        case .can:
            return "A KKL cable has no CAN, so it cannot read or write this ROM. That takes a Tactrix OpenPort 2.0 or an OBDLink adapter. With one of those SubieScope can read the ROM (ROM Editor, after you turn on Advanced mode in Settings; still experimental). It never writes to the car: putting a ROM on the ECU needs another tool, such as EcuFlash or FastECU."
        case .kLine:
            return "That is the wire SubieScope logs on, but SubieScope cannot read or write the ROM of this kind of ECU. That takes another tool, such as EcuFlash."
        }
    }

    /// Where a person finds "Send Diagnostic Report…". On a Mac that is the Help menu. The Windows
    /// app has no menu bar: there it is in Settings.
    static var reportPlace: String {
        onWindows ? "Settings > About > Diagnostic report > Send…" : "Help > Send Diagnostic Report…"
    }

    /// A text of the model that points at the Mac's Help menu, pointing at the right place here.
    static func reportPlaceReworded(_ text: String) -> String {
        text.replacingOccurrences(of: "Help > Send Diagnostic Report…", with: reportPlace)
    }
}
#endif
