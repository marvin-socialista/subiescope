import Foundation

/// The wire `SSMTransport` talks over. A KKL cable is a plain serial port; a Tactrix OpenPort 2.0
/// carries the same bytes on its K-line channel (`OpenPortKLine`).
public protocol SSMLine: AnyObject {
    var isOpen: Bool { get }
    func open(baud: UInt32) throws
    func close()
    func write(_ bytes: [UInt8]) throws
    /// Reads until `count` bytes arrived or `timeout` elapsed; may return fewer bytes on timeout.
    func read(count: Int, timeout: TimeInterval) throws -> [UInt8]
    /// Returns whatever arrives within `timeout`, stopping early once the line has been quiet for
    /// `idle` seconds after the first byte.
    func readAvailable(timeout: TimeInterval, idle: TimeInterval) throws -> [UInt8]
    func discardInput()
    /// Interrupts the ECU while it streams answers in continuous (fast poll) mode.
    func interrupt(for duration: TimeInterval)
}

extension SerialPort: SSMLine {
    public func open(baud: UInt32) throws {
        try open(baud: baud, parity: "N", stopBits: 1)
    }

    /// A BREAK: the line is held low for `duration`.
    public func interrupt(for duration: TimeInterval) {
        try? setBreak(true)
        Thread.sleep(forTimeInterval: duration)
        try? setBreak(false)
    }
}
