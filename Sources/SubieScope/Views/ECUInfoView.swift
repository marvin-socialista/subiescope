import AppKit
import SSMKit
import SwiftUI

struct ECUInfoView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.mode == .obd {
            obdBody
        } else {
            ssmBody
        }
    }

    private var obdBody: some View {
        @Bindable var model = model
        return Form {
            Section("Car") {
                if let info = model.obdInfo {
                    row("VIN", info.vin ?? "Not reported by this car", mono: info.vin != nil)
                    if let rom = model.extendedDiscovery?.romID { row("ECU ID", rom, mono: true) }
                    row("Standard values supported", "\(info.supportedPIDs.filter { $0 % 0x20 != 0 }.count)")
                    if let volts = info.voltage { row("Battery voltage at the port", String(format: "%.1f V", volts)) }
                } else {
                    Text("Connect to read the car's identification.").foregroundStyle(.secondary)
                }
            }
            Section("Adapter") {
                row("Adapter", model.connection.isConnected ? (model.obdInfo?.adapter ?? "?") : model.selectedAdapterLabel)
                row("Bus protocol", model.obdInfo?.protocolName.isEmpty == false ? model.obdInfo!.protocolName : "Found when connecting")
                if model.connection.isConnected {
                    row("Sample rate", String(format: "%.1f samples/s", model.samplesPerSecond))
                    row("Last poll", String(format: "%.0f ms", model.lastRoundTrip * 1000))
                }
            }
            Section("Extended values (experimental)") {
                Toggle("Look for extended values (Mode 22)", isOn: $model.extendedValuesOn)
                if let state = model.extendedState {
                    HStack(spacing: 8) {
                        if model.extendedSearching { ProgressView().controlSize(.small) }
                        Text(state).font(.callout).foregroundStyle(.secondary)
                    }
                    if model.connection.isConnected && !model.extendedSearching {
                        Button("Look Again") { Task { await model.discoverExtendedValues() } }
                    }
                } else {
                    Text("Newer Subarus can report AVCS (VVT) angles, knock and boost control this way. Turn this on and connect: SubieScope checks which values your car answers and offers those in the Logger. It might work on Subarus from about 2015, including cars with the FA20 or FA24 engine, but it has not been tested on a real one yet. If you try it, Help > Send Diagnostic Report… shows the developer what your car answered.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("About OBD-II mode") {
                Text("OBD-II mode reads the values every car reports by law. Subaru-only values such as knock correction, IAM and AVCS are only available with a KKL cable in Subaru SSM mode, on cars that support it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Connection Type…") { model.showModeChooser = true }
                    .disabled(model.connection.isConnected)
            }
        }
        .formStyle(.grouped)
    }

    private var ssmBody: some View {
        Form {
            Section("Control unit") {
                if let id = model.identity {
                    row("ECU ID", id.ecuID, mono: true)
                    row("Car", model.knownECUDescription ?? "Not in SubieScope's list of known ECUs")
                    row("Engine", EngineDiagnostics.engineType(systemID: id.systemID) ?? "Unknown")
                    row("SSM system ID", id.systemIDString, mono: true)
                    row("Capability bytes", "\(id.capabilities.count)")
                    row("VIN", model.vinState)
                } else {
                    Text("Connect to read the ECU's identification.").foregroundStyle(.secondary)
                }
            }
            if let ecu = knownECUs.first {
                Section("ROM") {
                    row("Calibration ID", knownECUs.map(\.calID).joined(separator: " or "), mono: true)
                    if let processor = ecu.processorDescription { row("Processor", processor) }
                    if let transport = ecu.flashTransport, let method = ecu.flashMethod {
                        row("Read and written over", "\(transport == .can ? "CAN" : "K-line") (EcuFlash calls it \(method))")
                        Text(Self.romNote(transport))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let status = model.engineStatus {
                Section("Status") {
                    if let v = status.ignitionOn { row("Ignition", v ? "On" : "Off") }
                    if let v = status.testMode { row("Test mode connector", v ? "Connected (test mode)" : "Not connected") }
                    if let v = status.dCheckPending { row("Self check (D-Check)", v ? "Not yet completed" : "Completed") }
                }
            }
            Section("Parameters for this ECU") {
                let kinds: [(String, ParameterKind)] = [("Standard", .standard), ("ECU specific (extended)", .extended),
                                                        ("Calculated", .calculated), ("Switches", .switchBit)]
                ForEach(kinds, id: \.0) { title, kind in
                    row(title, "\(model.parameters.filter { $0.kind == kind }.count)")
                }
                row("Trouble codes known", "\(model.codeDefinitions.count)")
                if model.identity != nil && model.extendedCount == 0 {
                    Label("This ECU ID is not in the definitions, so knock learning, IAM and other ECU-specific values are unavailable. Standard parameters still work.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
            Section("Definitions") {
                if let defs = model.definitions {
                    row("File", defs.sourceURL.lastPathComponent)
                    row("Version", defs.version ?? "?")
                    row("ECU IDs with extended parameters", "\(defs.ecuIDCount)")
                } else {
                    Text(model.definitionsError ?? "No definitions loaded").foregroundStyle(.red)
                }
            }
            Section("Connection") {
                row("Cable", model.selectedPortLabel)
                row("Protocol", model.ssmProtocolText)
                row("Fast poll", model.fastPollText)
                if model.connection.isConnected {
                    row("Sample rate", String(format: "%.1f samples/s", model.samplesPerSecond))
                    row("Last poll", String(format: "%.0f ms", model.lastRoundTrip * 1000))
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary, forType: .string)
                } label: {
                    Label("Copy Info", systemImage: "doc.on.doc")
                }
                .help("Copy the ECU details, e.g. to ask for help on a forum")
                .disabled(model.identity == nil)
            }
        }
    }

    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(mono ? .body.monospaced() : .body)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }

    /// What the ECU ID says about the ROM inside; empty for an ECU that is not in the list.
    private var knownECUs: [KnownECU] {
        model.identity.map { KnownECU.lookup($0.ecuID) } ?? []
    }

    /// What the way a ROM travels means for the owner's cable and for this app.
    private static func romNote(_ transport: KnownECU.FlashTransport) -> String {
        switch transport {
        case .can:
            return "A KKL cable has no CAN, so it cannot read or write this ROM. That takes a Tactrix OpenPort 2.0 or an OBDLink adapter. With one of those SubieScope can read the ROM (ROM Editor, after you turn on Advanced mode in Settings; still experimental). It never writes to the car: putting a ROM on the ECU needs another tool, such as EcuFlash or FastECU."
        case .kLine:
            return "That is the wire SubieScope logs on, but SubieScope cannot read or write the ROM of this kind of ECU. That takes another tool, such as EcuFlash."
        }
    }

    private var summary: String {
        guard let id = model.identity else { return "" }
        let rom = knownECUs.first.map { ecu in
            "\nROM: \(knownECUs.map(\.calID).joined(separator: " or ")), \(ecu.processor ?? "?"), flash method \(ecu.flashMethod ?? "?")"
        } ?? ""
        return """
        ECU ID: \(id.ecuID)
        SSM system ID: \(id.systemIDString) (\(EngineDiagnostics.engineType(systemID: id.systemID) ?? "unknown engine"))
        Car: \(model.knownECUDescription ?? "unknown")\(rom)
        Capabilities (\(id.capabilities.count) bytes): \(id.capabilities.hexString)
        Definitions: \(model.definitions?.sourceURL.lastPathComponent ?? "-") v\(model.definitions?.version ?? "?")
        Extended parameters available: \(model.extendedCount)
        """
    }
}
