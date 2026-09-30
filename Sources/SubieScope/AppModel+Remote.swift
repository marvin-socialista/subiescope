import Foundation
import SSMKit

/// The app side of the command line remote control: turns the text commands of `subiescope-cli remote`
/// into actions on the connected OBD-II adapter. Every command is written to the diagnostic log.
extension AppModel {
    static let remoteHelp = [
        "Commands (subiescope-cli remote <command>):",
        "  status                 connection state, adapter, protocol, speed",
        "  adapters               Bluetooth adapters in range",
        "  select <name>          choose an adapter by (part of) its name, or 'demo'",
        "  connect / disconnect   connect the selected adapter, or let go",
        "  send <request>         send one raw request and print the reply, e.g. send 010C or send 22 10B4",
        "                         AT commands too (ATSH7A2). Read-only services only.",
        "  release                put the adapter back to normal (header, filters) and resume live polling",
        "  values                 the latest live values",
        "  codes                  read trouble codes",
    ]

    /// Starts or stops the control socket to match the setting.
    func applyRemoteControl() {
        remoteServer?.stop()
        remoteServer = nil
        guard UserDefaults.standard.bool(forKey: "remoteControl") else { return }
        let server = RemoteServer { [weak self] line in
            guard let self else { return ["The app is closing."] }
            return Self.onMain { await self.handleRemote(line) }
        }
        do {
            try server.start()
            remoteServer = server
            log("Command line control is on")
        } catch {
            log("Command line control could not start: \(error.localizedDescription)")
        }
    }

    /// Runs async work on the main actor from the socket's background thread and waits for the answer.
    private nonisolated static func onMain(_ work: @escaping @MainActor @Sendable () async -> [String]) -> [String] {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: [String] = []
        Task { @MainActor in
            result = await work()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 90) == .timedOut { return ["Timed out waiting for the app."] }
        return result
    }

    func handleRemote(_ line: String) async -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let command = trimmed.split(separator: " ", maxSplits: 1).first.map { String($0).lowercased() } ?? ""
        let argument = trimmed.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        DiagnosticLog.shared.info("remote", "> \(trimmed)")
        switch command {
        case "", "help": return Self.remoteHelp
        case "status": return remoteStatus()
        case "adapters":
            // A scan may not be running (for instance after a crash, when the app starts without scanning): start one.
            if bleStatus == .idle {
                startBLEScan()
                try? await Task.sleep(for: .seconds(6))
            }
            if bleAdapters.isEmpty { return ["No adapters in range. \(bleStatus.message ?? "Is it plugged in with the ignition ON?")"] }
            return bleAdapters.map { "\($0.name)\($0.id == selectedAdapterID ? "  (selected)" : "")  rssi \($0.rssi)" }
        case "select":
            if argument.lowercased() == "demo" { selectedAdapterID = Self.demoOBDID; return ["Selected the demo adapter."] }
            guard let match = bleAdapters.first(where: { $0.name.lowercased().contains(argument.lowercased()) }) else {
                return ["No adapter matching \"\(argument)\". Try: adapters"]
            }
            selectedAdapterID = match.id
            return ["Selected \(match.name)."]
        case "connect":
            if mode != .obd { setMode(.obd) }
            await connect()
            return remoteStatus()
        case "disconnect":
            disconnect()
            return ["Disconnected."]
        case "send": return await remoteSend(argument)
        case "release": return await remoteRelease()
        case "values":
            if latest.isEmpty { return ["No live values yet."] }
            return parameters.compactMap { p in
                latest[p.id].map { "\(p.displayName): \($0)" + (conversion(for: p).map { " \($0.displayUnits)" } ?? "") }
            }
        case "codes":
            await readTroubleCodes()
            return ["Confirmed: \(currentCodes.map(\.code).joined(separator: " ").nonEmpty ?? "none")",
                    "Pending: \(memorizedCodes.map(\.code).joined(separator: " ").nonEmpty ?? "none")"]
        default: return ["Unknown command \"\(command)\".", ""] + Self.remoteHelp
        }
    }

    private func remoteStatus() -> [String] {
        var lines = ["Mode: \(mode.title)", "Connection: \(connection)", "Adapter: \(selectedAdapterLabel)"]
        if let info = obdInfo {
            lines.append("Adapter version: \(info.adapter)")
            lines.append("Protocol: \(info.protocolName.isEmpty ? "unknown" : info.protocolName)")
            lines.append("Supported values: \(info.supportedPIDs.count)")
        }
        if connection.isConnected { lines.append(String(format: "Speed: %.1f samples/s", samplesPerSecond)) }
        if remoteHold { lines.append("Live polling is paused for your raw requests. Use: release") }
        return lines
    }

    private func remoteSend(_ request: String) async -> [String] {
        if let reason = CommandPolicy.check(request) {
            DiagnosticLog.shared.warning("remote", "Refused: \(request) (\(reason))")
            return ["Refused: \(reason)"]
        }
        guard connection.isConnected, let session = obdSession else { return ["Not connected. Use: connect"] }
        // Raw requests change the adapter's state (headers, filters), so live polling waits until 'release'.
        if !remoteHold {
            remoteHold = true
            session.stopPolling()
        }
        let text = request.filter { !$0.isWhitespace }
        do {
            let lines = try await session.run { elm in try elm.send(text, timeout: 3) }
            return lines.isEmpty ? ["(no reply)"] : lines
        } catch {
            return ["Error: \(error.localizedDescription)"]
        }
    }

    private func remoteRelease() async -> [String] {
        guard remoteHold, let session = obdSession else { return ["Nothing to release."] }
        _ = try? await session.run { elm in
            _ = try? elm.send("ATSH7DF")
            _ = try? elm.send("ATAR")
            _ = try? elm.send("ATCAF1")
            return true
        }
        remoteHold = false
        startPolling()
        return ["Released: header and filters reset, live polling resumed."]
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
