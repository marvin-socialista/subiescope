import CSerial
import Foundation

/// A software AEM wideband gauge on a pseudo terminal. Like the real one it only talks: a reading
/// ten times a second, whether anyone listens or not. `WidebandReader` opens `devicePath` through
/// the normal serial port code, so the gauge can be tested, and shown on the demo car, without the
/// hardware.
public final class SimulatedWideband: @unchecked Sendable {
    /// What the gauge sends.
    public enum Output: Sendable {
        /// Petrol AFR, "14.7\r\n": a UEGO or X-Series gauge as it comes out of the box (9600 baud).
        case afr
        /// The same gauge with its display set to lambda, "1.00\r\n".
        case lambda
        /// The lambda output with status words, "1.000\tReady\tNo-errors\r" (19200 baud).
        case lambdaWithStatus
    }

    /// The device to open, e.g. /dev/ttys012.
    public let devicePath: String

    public var output: Output {
        get { lock.lock(); defer { lock.unlock() }; return _output }
        set { lock.lock(); _output = newValue; lock.unlock() }
    }
    /// Sends noise instead of readings, as a gauge looks when it is listened to at the wrong speed.
    public var garbled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _garbled }
        set { lock.lock(); _garbled = newValue; lock.unlock() }
    }
    /// Sends nothing, like a gauge without power.
    public var silent: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _silent }
        set { lock.lock(); _silent = newValue; lock.unlock() }
    }

    private let mixture: @Sendable () -> Double
    private let interval: TimeInterval
    private let lock = NSLock()
    private var _output: Output
    private var _garbled = false
    private var _silent = false
    private var running = true

    /// `mixture` is what the sensor sees, as lambda. It is called on the gauge's own thread, every `interval` seconds.
    public init(output: Output = .afr, interval: TimeInterval = 0.1, mixture: @escaping @Sendable () -> Double) throws {
        var controller: Int32 = -1
        var device: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        guard cserial_openpty(&controller, &device, &name, Int32(name.count)) == 0 else {
            throw SerialError.openFailed(path: "pty", reason: String(cString: strerror(errno)))
        }
        // The gauge does not care whether anyone listens: with nobody reading, readings are dropped
        // once the buffer is full instead of holding up the thread.
        _ = fcntl(controller, F_SETFL, fcntl(controller, F_GETFL) | O_NONBLOCK)
        devicePath = String(cString: name)
        _output = output
        self.interval = interval
        self.mixture = mixture
        // The device side stays open here, so the pair survives a listener opening and closing it. Both
        // ends are closed by the thread itself, never while it could still be writing to them.
        let thread = Thread { [weak self, interval] in
            while let bytes = self?.next() {
                if !bytes.isEmpty { _ = bytes.withUnsafeBytes { write(controller, $0.baseAddress, $0.count) } }
                Thread.sleep(forTimeInterval: interval)
            }
            close(controller)
            close(device)
        }
        thread.name = "SimulatedWideband"
        thread.start()
    }

    /// A gauge in the exhaust of a demo car. It follows the car as long as something reads the car's values.
    public convenience init(world: DemoWorld, output: Output = .afr, interval: TimeInterval = 0.1) throws {
        try self.init(output: output, interval: interval) { world.exhaustLambda }
    }

    deinit {
        stop()
    }

    /// Unplugs the gauge: the device goes away within one interval.
    public func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    /// The bytes to send now: nothing while silent, and nil once stopped.
    private func next() -> [UInt8]? {
        lock.lock()
        let (active, output, garbled, silent) = (running, _output, _garbled, _silent)
        lock.unlock()
        guard active else { return nil }
        if silent { return [] }
        if garbled { return [0xF8, 0x00, 0x7E, 0xFC, 0xE0] }
        let lambda = mixture()
        let line: String
        switch output {
        case .afr: line = String(format: "%.1f\r\n", min(20, max(8, lambda * AEMWideband.stoich)))
        case .lambda: line = String(format: "%.2f\r\n", min(2, max(0.55, lambda)))
        case .lambdaWithStatus: line = String(format: "%.3f\tReady\tNo-errors\r", min(2, max(0.55, lambda)))
        }
        return Array(line.utf8)
    }
}
