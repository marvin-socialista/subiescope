import Foundation
import SSMKit

/// A separate AEM wideband gauge, read on its own serial port while the car is connected. Its reading
/// rides along with every sample from the car, so it shows up on the gauges, in the trends and in
/// the recorded log like any other value. Works in both connection modes.
extension AppModel {
    /// The gauge as a parameter to log, when it is turned on.
    var widebandParameters: [ParameterDefinition] { widebandOn ? [AEMWideband.definition] : [] }

    /// The serial port that goes to the car, which the gauge can't share.
    var carPortPath: String? {
        if mode == .obd {
            if case .serial(let path) = selectedLink { return path }
            return nil
        }
        return selectedPortID == Self.demoPortID ? nil : selectedPortID
    }

    /// The ports the gauge can be on.
    var widebandPorts: [SerialPortInfo] { ports.filter { $0.path != carPortPath } }

    func widebandSettingChanged() {
        if !isPlayingBack { applyParameters() }
        if widebandOn { logWidebandByDefault() }
        if connection.isConnected {
            if widebandOn { startWideband() } else { stopWideband() }
        }
        selectionChanged()
    }

    /// Turning the gauge on is all it takes to log it: it is ticked in the Logger for both connection types.
    private func logWidebandByDefault() {
        let id = AEMWideband.parameterID
        if !loggedIDs.contains(id) { loggedIDs.insert(id) }
        let key = "loggedIDs" + (mode == .obd ? ConnectionMode.ssm : .obd).keySuffix
        if var saved = UserDefaults.standard.stringArray(forKey: key), !saved.isEmpty, !saved.contains(id) {
            saved.append(id)
            UserDefaults.standard.set(saved, forKey: key)
        }
    }

    // MARK: Listening

    /// Starts listening to the gauge. Called once the car is connected, and again when the port changes.
    func startWideband() {
        stopWideband()
        guard widebandOn else { return }
        let path: String
        if isDemo {
            // The demo car has a simulated gauge in its exhaust, read through the same serial port code.
            guard let world = demoWorld, let gauge = try? SimulatedWideband(world: world) else { return }
            simulatedWideband = gauge
            path = gauge.devicePath
        } else {
            guard let port = widebandPortID else {
                widebandState = .failed("No port chosen for the gauge yet. Pick one in Settings > Wideband.")
                return
            }
            guard port != carPortPath else {
                widebandState = .failed("The gauge is set to the port that goes to the car. Pick the gauge's own serial adapter in Settings > Wideband.")
                return
            }
            path = port
        }
        let reader = WidebandReader(path: path)
        reader.onState = { [weak self, weak reader] state in
            Task { @MainActor in
                guard let self, let reader, self.widebandReader === reader else { return }
                self.widebandStateChanged(state)
            }
        }
        widebandReader = reader
        widebandState = .listening
        log("Listening for the wideband gauge on \(isDemo ? "the demo car" : path)")
        reader.start()
    }

    func stopWideband() {
        widebandReader?.stop()
        widebandReader = nil
        simulatedWideband?.stop()
        simulatedWideband = nil
        widebandState = nil
        latest[AEMWideband.parameterID] = nil
    }

    private func widebandStateChanged(_ state: WidebandReader.State) {
        widebandState = state
        switch state {
        case .listening: break
        case .reading(let baud): log("Wideband gauge: reading at \(baud) baud")
        case .silent: log("Wideband gauge: nothing readable arrives on its port")
        case .failed(let reason):
            // The serial errors talk about "the cable", which here is the gauge's adapter.
            widebandState = .failed("The gauge's serial adapter can't be read: \(reason) Check that it is still plugged into your Mac.")
            log("Wideband gauge: \(reason)")
        }
    }

    /// Adds the gauge's newest reading to a sample from the car, in the units chosen for it.
    func addWideband(to sample: inout Sample) {
        guard let reader = widebandReader, let parameter = parametersByID[AEMWideband.parameterID],
              let conversion = conversion(for: parameter) else { return }
        // A gauge that went quiet shows as a gap, not as its last number.
        if !reader.add(to: &sample, conversion: conversion) { latest[parameter.id] = nil }
    }

    // MARK: Status

    /// The gauge's state in a sentence, for Settings and the connection panel.
    var widebandStatusText: String {
        guard connection.isConnected, let state = widebandState else {
            return "SubieScope starts listening to the gauge when you connect to the car."
        }
        switch state {
        case .listening:
            return "Listening for the gauge…"
        case .reading:
            let parameter = AEMWideband.definition
            let source = isDemo ? "Simulated gauge on the demo car" : "Reading the gauge"
            guard let value = latest[parameter.id], let conversion = conversion(for: parameter) else { return "\(source)." }
            return "\(source): \(conversion.formatted(value)) \(conversion.displayUnits)"
        case .silent:
            return "Nothing readable comes from the gauge. Check that it is switched on (ignition ON), that its blue wire goes to pin 2 of the serial adapter and its ground to pin 5, and that this is the right port."
        case .failed(let reason):
            return reason
        }
    }

    var widebandHasProblem: Bool {
        guard connection.isConnected else { return false }
        switch widebandState {
        case .silent, .failed: return true
        default: return false
        }
    }
}
