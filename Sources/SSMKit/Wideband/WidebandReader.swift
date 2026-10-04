import Foundation

/// Listens to a wideband gauge on its own serial port and keeps its newest reading, so it can be
/// added to every sample that comes from the car. The gauge only talks: nothing is sent to it.
///
/// Experimental: written from RomRaider's AEM plugins and AEM's manual, and tested against the
/// simulated gauge only.
public final class WidebandReader: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        /// The port is open and no reading has arrived yet.
        case listening
        /// Readings arrive, at this speed.
        case reading(baud: UInt32)
        /// Every speed was tried and nothing readable arrived: the gauge is off, or not wired to this port.
        case silent
        /// The port could not be opened, or went away.
        case failed(String)
    }

    public let path: String
    /// Called on the reader's own thread whenever the state changes. Set it before `start()`.
    public var onState: (@Sendable (State) -> Void)?

    private let baudRates: [UInt32]
    private let window: TimeInterval
    private let lock = NSLock()
    private var started = false
    private var running = false
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)
    private var currentState = State.listening
    private var currentBaud: UInt32?
    private var newest: (time: Date, lambda: Double)?
    /// Lines still to be written to the log file about speeds that gave no reading (the first ones say the most).
    private var logBudget = 6

    /// `window` is how long one speed gets to produce a reading before the next one is tried.
    public init(path: String, baudRates: [UInt32] = AEMWideband.baudRates, window: TimeInterval = 1.5) {
        self.path = path
        self.baudRates = baudRates
        self.window = window
    }

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return currentState
    }

    /// The speed being listened at right now.
    var listeningBaud: UInt32? {
        lock.lock(); defer { lock.unlock() }
        return currentBaud
    }

    /// Starts listening. A reader runs once: make a new one to listen again after `stop()`.
    public func start() {
        lock.lock()
        let first = !started
        started = true
        if first { running = true }
        lock.unlock()
        guard first else { return }
        let thread = Thread { [self] in run() }
        thread.name = "WidebandReader"
        lock.lock()
        self.thread = thread
        lock.unlock()
        thread.start()
    }

    /// Stops listening, and waits the moment it takes to close the port. A new listener can open it
    /// straight away: two that share a port take each other's lines and conclude it was unplugged.
    public func stop() {
        lock.lock()
        let wasRunning = running
        let thread = self.thread
        running = false
        newest = nil
        lock.unlock()
        if wasRunning, thread != Thread.current { _ = finished.wait(timeout: .now() + 0.5) }
    }

    /// The newest reading as lambda. nil once the gauge has sent none for `maxAge` seconds before `time`.
    public func lambda(at time: Date = Date(), maxAge: TimeInterval = 1) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let newest, time.timeIntervalSince(newest.time) <= maxAge else { return nil }
        return newest.lambda
    }

    /// Adds the newest reading to a sample from the car, in the units of `conversion`. A gauge that
    /// went quiet leaves the sample alone, so a log shows a gap instead of a number that no longer moves.
    @discardableResult
    public func add(to sample: inout Sample, conversion: Conversion) -> Bool {
        guard let lambda = lambda(at: sample.time) else { return false }
        sample.values[AEMWideband.parameterID] = AEMWideband.value(lambda, in: conversion)
        return true
    }

    // MARK: Listening

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func set(_ state: State) {
        lock.lock()
        let changed = running && state != currentState
        if changed { currentState = state }
        lock.unlock()
        if changed { onState?(state) }
    }

    private func run() {
        let port = SerialPort(path: path)
        defer {
            port.close()
            finished.signal()
        }
        var tried = 0
        var opened = false
        let openDeadline = Date().addingTimeInterval(1.5)
        while isRunning {
            let baud = baudRates[tried % baudRates.count]
            do {
                try port.open(baud: baud)
                opened = true
            } catch {
                // The port may not be free yet: something else is still closing it, or it was only just plugged in.
                if !opened, Date() < openDeadline {
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                set(.failed(error.localizedDescription))
                return
            }
            lock.lock()
            currentBaud = baud
            lock.unlock()
            do {
                try listen(on: port, baud: baud)
            } catch {
                set(.failed(error.localizedDescription))
                return
            }
            tried += 1
            // Once round every speed without a reading.
            if tried % baudRates.count == 0 { set(.silent) }
        }
    }

    /// Reads lines at one speed. Returns when no reading arrived for a whole window, so the next
    /// speed gets a turn: at the wrong speed a gauge looks like noise, or like nothing at all.
    private func listen(on port: SerialPort, baud: UInt32) throws {
        var buffer: [UInt8] = []
        var readings = 0
        var lastReading = Date()
        var received = 0
        var firstBytes: [UInt8] = []
        while isRunning {
            // Short waits, so stop() is noticed quickly.
            let chunk = try port.readAvailable(timeout: 0.05, idle: 0)
            received += chunk.count
            if firstBytes.count < 24 { firstBytes += chunk.prefix(24 - firstBytes.count) }
            buffer += chunk
            while let end = buffer.firstIndex(where: { $0 == 13 || $0 == 10 }) {
                let line = String(decoding: buffer[..<end], as: UTF8.self)
                buffer.removeSubrange(...end)
                guard let lambda = AEMWideband.lambda(fromLine: line) else { continue }
                readings += 1
                lastReading = Date()
                // One line that happens to look like a number can still be noise: wait for a second one.
                guard readings >= 2 else { continue }
                if readings == 2 { DiagnosticLog.shared.info("wideband", "Reading at \(baud) baud, the gauge sent \"\(line)\"") }
                lock.lock()
                if running { newest = (lastReading, lambda) }
                lock.unlock()
                set(.reading(baud: baud))
            }
            // Noise without line ends.
            if buffer.count > 64 { buffer.removeAll() }
            if Date().timeIntervalSince(lastReading) > window {
                if readings >= 2 {
                    DiagnosticLog.shared.warning("wideband", "The gauge stopped sending")
                    set(.silent)
                } else if logBudget > 0 {
                    // What a gauge that is not understood sent, for a report from someone who has one.
                    logBudget -= 1
                    DiagnosticLog.shared.debug("wideband", "\(baud) baud: \(received) bytes, no reading\(firstBytes.isEmpty ? "" : ": " + firstBytes.hexString)")
                }
                return
            }
        }
    }
}
