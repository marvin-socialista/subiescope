import Foundation
import SSMKit

/// Reading a ROM image off the car's engine ECU over OBD-II CAN. This is the one place in the app that
/// loads a helper program into the ECU and dumps its flash; it never writes to flash. It is gated
/// behind Advanced mode, and needs either an OBD-II connection with an STN-based adapter (OBDLink EX)
/// or a connection through a Tactrix OpenPort 2.0, which reaches the CAN bus too.
///
/// UNTESTED ON A CAR. The read sequence has only ever run against a simulated ECU here. See the
/// reader (`DensoSH7058CANReader`) and the transports (`ISOTPELMTransport`, `OpenPortISOTPTransport`).
extension AppModel {

    /// Whether the "Read ROM from car" button should be enabled right now.
    var canReadROMFromCar: Bool {
        guard advancedMode, connection.isConnected, !romReadInProgress else { return false }
        return mode == .obd ? obdAdapterIsSTN == true : openPortSession != nil
    }

    /// A sentence explaining why reading is or is not available, for the ROM screen.
    var romReadAvailability: String {
        if !advancedMode { return "Turn on Advanced mode to read a ROM from the car." }
        if mode != .obd {
            // With the SSM cable only a Tactrix OpenPort reaches the ECU's CAN side.
            if openPortSession != nil, connection.isConnected {
                return "Ready, through the Tactrix OpenPort. Make sure the ignition is ON and the engine is OFF before you start."
            }
            if openPortOn, !connection.isConnected { return "Connect to the car with the Tactrix OpenPort first." }
            return "Reading a ROM from the car needs an OBD-II (ELM327/STN) connection or a Tactrix OpenPort 2.0, not a KKL cable."
        }
        if !connection.isConnected { return "Connect to the car in OBD-II mode first." }
        if checkingAdapterType { return "Checking the adapter…" }
        switch obdAdapterIsSTN {
        case .none: return "Checking the adapter…"
        case .some(false): return "This adapter cannot read a ROM. You need an OBDLink or other STN-based adapter."
        case .some(true): return "Ready. Make sure the ignition is ON and the engine is OFF before you start."
        }
    }

    /// Probes whether the connected adapter is an STN chip. Cheap (one `STI` command); safe to call
    /// whenever the ROM screen appears or the connection changes. Does nothing during a read.
    func checkROMReadCapability() async {
        guard !romReadInProgress else { return }
        guard mode == .obd, connection.isConnected, let session = obdSession else {
            obdAdapterIsSTN = nil
            return
        }
        guard !checkingAdapterType else { return }
        checkingAdapterType = true
        defer { checkingAdapterType = false }
        let isSTN = (try? await session.run { elm in
            ISOTPELMTransport(channel: elm.channel).detectSTN() != nil
        }) ?? false
        obdAdapterIsSTN = isSTN
        log(isSTN
            ? "OBD adapter is STN-based; reading a ROM from the car is available"
            : "OBD adapter is not STN-based; reading a ROM needs an OBDLink/STN adapter")
    }

    /// Reads the whole ROM from the connected car and returns it, or nil on failure or cancel. Updates
    /// `romReadProgress` and `romReadStatus` as it goes. Live polling is paused for the duration and the
    /// adapter is put back to normal OBD when it finishes.
    func readROMFromCar() async -> ROMImage? {
        if mode == .ssm { return await readROMThroughOpenPort() }
        guard let session = obdSession, mode == .obd, connection.isConnected else {
            romReadStatus = "Connect to the car in OBD-II mode first."
            return nil
        }
        guard let kernel = DensoSH7058CANReader.bundledKernel() else {
            romReadStatus = "The helper program for this ECU is missing from the app."
            romReadError = romReadStatus
            return nil
        }

        romReadInProgress = true
        romReadProgress = 0
        romReadError = nil
        romReadStatus = "Getting ready…"
        romReadCancel.reset()
        log("Starting ROM read from the car (advanced). Reads flash only; never writes to the ECU.")

        // The read takes over the adapter, so stop live polling first.
        session.stopPolling()

        let cancel = romReadCancel
        do {
            let result = try await session.run { [weak self] elm -> DensoSH7058CANReader.ReadResult in
                let transport = ISOTPELMTransport(channel: elm.channel)
                guard transport.detectSTN() != nil else {
                    throw DensoSH7058CANReader.ReaderError.connectFailed(
                        "this is not an OBDLink/STN adapter, which reading a ROM needs.")
                }
                try transport.configure()
                let reader = DensoSH7058CANReader(
                    transport: transport,
                    kernel: kernel,
                    isCancelled: { cancel.isCancelled },
                    onProgress: { progress in Task { @MainActor in self?.romReadProgressUpdated(progress) } })
                return try reader.read()
            }
            romReadProgress = 1
            romReadInProgress = false
            romReadStatus = "Read complete: \(result.rom.byteCount / 1024) KB loaded into the editor."
            log("ROM read complete (\(result.rom.byteCount) bytes)"
                + (result.calibrationID.map { ", CAL ID \($0)" } ?? "")
                + (result.ecuID.map { ", ECU \($0)" } ?? ""))
            await returnToNormalOBD()
            return result.rom
        } catch {
            romReadInProgress = false
            let cancelled: Bool
            if case DensoSH7058CANReader.ReaderError.cancelled = error { cancelled = true } else { cancelled = false }
            let message = cancelled ? "ROM read stopped." : error.localizedDescription
            romReadStatus = message
            romReadError = cancelled ? nil : message
            log("ROM read \(cancelled ? "stopped" : "failed"): \(message)")
            await returnToNormalOBD()
            return nil
        }
    }

    /// The same read through a Tactrix OpenPort 2.0, which reaches the ECU's CAN side while the app
    /// is connected over the K-line. The same transport and reader read a 2009 JDM STI on 10 October
    /// 2026; this function itself, with its progress in the window, has not been run on a car yet.
    private func readROMThroughOpenPort() async -> ROMImage? {
        guard let session = openPortSession, let cable = session.openPort, connection.isConnected else {
            romReadStatus = "Connect to the car with a Tactrix OpenPort first."
            return nil
        }
        guard let kernel = DensoSH7058CANReader.bundledKernel() else {
            romReadStatus = "The helper program for this ECU is missing from the app."
            romReadError = romReadStatus
            return nil
        }

        romReadInProgress = true
        romReadProgress = 0
        romReadError = nil
        romReadStatus = "Getting ready…"
        romReadCancel.reset()
        log("Starting ROM read from the car through the Tactrix OpenPort (advanced). Reads flash only; never writes to the ECU.")

        // The read takes over the cable, so stop live polling first.
        session.stopPolling()

        let cancel = romReadCancel
        do {
            let result = try await session.run { [weak self] _ -> DensoSH7058CANReader.ReadResult in
                let transport = OpenPortISOTPTransport(device: cable)
                try transport.open()
                defer { transport.close() }
                let reader = DensoSH7058CANReader(
                    transport: transport,
                    kernel: kernel,
                    isCancelled: { cancel.isCancelled },
                    onProgress: { progress in Task { @MainActor in self?.romReadProgressUpdated(progress) } })
                return try reader.read()
            }
            romReadProgress = 1
            romReadInProgress = false
            log("ROM read complete (\(result.rom.byteCount) bytes)"
                + (result.calibrationID.map { ", CAL ID \($0)" } ?? "")
                + (result.ecuID.map { ", ECU \($0)" } ?? ""))
            // The helper program is still running in the ECU, which keeps it from answering normally.
            disconnect()
            romReadStatus = "Read complete: \(result.rom.byteCount / 1024) KB loaded into the editor. Turn the ignition OFF and ON again before you reconnect."
            return result.rom
        } catch {
            romReadInProgress = false
            let cancelled: Bool
            if case DensoSH7058CANReader.ReaderError.cancelled = error { cancelled = true } else { cancelled = false }
            let message = cancelled ? "ROM read stopped." : error.localizedDescription
            romReadStatus = message + " If live data does not come back, turn the ignition OFF and ON again and reconnect."
            romReadError = cancelled ? nil : romReadStatus
            log("ROM read \(cancelled ? "stopped" : "failed"): \(message)")
            startPolling()
            return nil
        }
    }

    func cancelROMRead() {
        guard romReadInProgress else { return }
        romReadCancel.cancel()
        romReadStatus = "Stopping after the current page…"
    }

    private func romReadProgressUpdated(_ progress: DensoSH7058CANReader.Progress) {
        romReadProgress = progress.fraction
        romReadStatus = progress.message
    }

    /// Puts the adapter back into normal OBD-II mode and resumes live polling after a read. The read
    /// leaves the adapter configured for raw CAN, so the protocol has to be set up again.
    private func returnToNormalOBD() async {
        guard let session = obdSession, connection.isConnected else { return }
        do {
            try await session.run { try $0.start() }
            startPolling()
            log("Adapter returned to normal OBD-II mode after the read")
        } catch {
            log("Could not return to normal OBD-II mode after the read: \(error.localizedDescription). Reconnect to resume live data.")
            connection = .failed("The adapter needs reconnecting after the ROM read: \(error.localizedDescription)")
        }
    }
}

/// A thread-safe cancel flag shared between the UI (which sets it) and the read running on the
/// adapter's I/O queue (which checks it between pages).
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func reset() { lock.lock(); cancelled = false; lock.unlock() }
}
