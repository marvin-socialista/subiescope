import Foundation

/// Writes a ROM image to a Denso SH7058 "subarucan" engine ECU (the 2008 STI's ECU) over OBD-II CAN.
///
/// SWITCHED OFF. `isEnabled` is false, so `write()` refuses before it sends anything to the car, and
/// nothing in the app or the command line offers a write. It is here so the code exists, is tested
/// against a simulated ECU, and can be turned on once a test write has run on a real car.
///
/// What it does, in order:
/// 1. Checks the file before it touches the car: 1 MB, and every checksum in its table right.
/// 2. Starts the kernel exactly as a read does (`DensoSH7058CANReader.startKernel`), then reads the
///    calibration ID out of the ECU's flash. A file for another calibration is refused unless
///    `allowOtherCalibration` is set.
/// 3. Asks the kernel for a CRC of each of the 16 flash blocks and compares them with the file, so
///    only the blocks that differ are touched.
/// 4. Per block that differs: reads the voltage, erases the block, sends it in 512-byte pieces into
///    the kernel's 4 KB buffer, and has the kernel commit every 4 KB once its CRC matches.
/// 5. Compares every block's CRC again. They must all match now.
///
/// A test write (`Mode.testWrite`) holds the same conversation with the kernel's flash writing
/// switched off, and has the kernel check each 4 KB instead of committing it. Nothing in the flash
/// changes: in the bundled kernel, the erase and the write routines both return straight away while
/// that switch (one byte at 0xFFFF5654, set by command 0x20 and cleared by 0x21) is off.
///
/// What the kernel does was checked in the bundled kernel itself (`ssmk_can_tp_sh7058.bin`, from
/// rimwall's fork of fenugrec's npkern, GPLv3), not only taken from FastECU:
/// - Every answer is `BE EF <length> <command + 0x40> <data>`, a refusal `BE EF 00 03 7F <command> <code>`.
/// - Its CRC is `DensoCAN.kernelCRC`, with 0x5AA5A55A as the polynomial.
/// - Its erase looks the block up by its exact start address. An address that is not a block start
///   falls through to block 0, which holds the ECU's start-up code, so only starts from
///   `flashBlocks` are ever sent.
/// - Its write buffer is 4 KB, which is why each commit covers 4 KB.
///
/// Ported from the write path of FastECU's `flash_ecu_subaru_denso_sh7058_can.cpp` (GPLv3):
/// `write_mem`, `get_changed_blocks`, `check_romcrc`, `init_flash_write`, `reflash_block` and
/// `flash_block`. Added here: the checks on the file, the calibration and the voltage before any
/// erase, stopping only between blocks, and messages that say whether the flash was touched.
///
/// NEVER RUN ON A CAR, not even as a test write. The read half of the conversation (unlock, kernel
/// upload, kernel answers) has run on a 2009 JDM STI through a Tactrix OpenPort; the commands that
/// erase and write have only met the simulated ECU in the tests.
public final class DensoSH7058CANWriter {

    /// The one switch for writing. While it is false, `write()` throws `WriterError.switchedOff`
    /// before it sends a single byte, for a test write as much as for a real one.
    public static let isEnabled = false

    public enum Mode: Sendable, Equatable {
        /// The whole write with the kernel's flash writing switched off: it erases nothing, writes
        /// nothing, and only checks that every 4 KB arrived intact. The car is left as it was.
        case testWrite
        /// Erases and writes the blocks that differ from the file.
        case write
    }

    public enum Phase: Sendable, Equatable {
        case checking
        case connecting
        case comparing
        case writing
        case verifying
        case done
    }

    public struct Progress: Sendable, Equatable {
        public let phase: Phase
        /// 0...1 across the whole job.
        public let fraction: Double
        public let message: String
    }

    public struct WriteResult: Sendable, Equatable {
        public let mode: Mode
        /// The flash blocks (0...15) that differed from the file before the write.
        public let changedBlocks: [Int]
        /// How many bytes of the file went to the kernel.
        public let bytesSent: Int
        /// The lowest voltage the kernel measured before a block, in volts. Nil when nothing needed writing.
        public let lowestVoltage: Double?
        /// The calibration ID that was in the ECU's flash before the write.
        public let ecuCalibrationID: String?
    }

    public enum WriterError: Error, LocalizedError, Equatable {
        case switchedOff
        case cancelled(flashChanged: Bool)
        case wrongSize(Int)
        case checksumsUnreadable
        case checksumsWrong(Int)
        case otherCalibration(ecu: String, file: String)
        case lowVoltage(Double, minimum: Double, flashChanged: Bool)
        case kernelRefused(step: String, code: UInt8, flashChanged: Bool)
        case failed(step: String, detail: String, flashChanged: Bool)
        case verifyFailed(blocks: [Int])

        public var errorDescription: String? {
            switch self {
            case .switchedOff:
                return "Writing a ROM to the car is switched off in this version of SubieScope."
            case .cancelled(let flashChanged):
                return flashChanged
                    ? "The write was stopped between two blocks. Part of the new ROM is in the ECU and part is not, so the car may not run like this."
                        + Self.partlyWritten
                    : "The write was stopped before anything in the ECU changed. Turn the ignition OFF and ON again before you reconnect."
            case .wrongSize(let bytes):
                return "This file is \(bytes) bytes. This ECU takes a ROM of exactly 1 MB (1,048,576 bytes)."
            case .checksumsUnreadable:
                return "The checksum table in this file could not be read, so it is not a ROM for this ECU."
            case .checksumsWrong(let count):
                return "\(count) checksum\(count == 1 ? " is" : "s are") wrong in this file, and the ECU would not accept the ROM. Correct the checksums first."
            case .otherCalibration(let ecu, let file):
                return "The ECU holds calibration \(ecu), but this file is \(file). A ROM made for another ECU can leave the car unable to start."
            case .lowVoltage(let volts, let minimum, let flashChanged):
                return String(format: "The ECU measures %.1f V, below the %.1f V needed to write safely. Put a charger on the battery and try again.", volts, minimum)
                    + (flashChanged ? Self.partlyWritten : Self.untouched)
            case .kernelRefused(let step, let code, let flashChanged):
                return "The helper program in the ECU refused \(step): \(Self.kernelErrorText(code))."
                    + (flashChanged ? Self.partlyWritten : Self.untouched)
            case .failed(let step, let detail, let flashChanged):
                return "Something went wrong while \(step): \(detail)"
                    + (flashChanged ? Self.partlyWritten : Self.untouched)
            case .verifyFailed(let blocks):
                let list = blocks.map(String.init).joined(separator: ", ")
                return "After writing, block\(blocks.count == 1 ? "" : "s") \(list) still differ\(blocks.count == 1 ? "s" : "") from the file."
                    + Self.partlyWritten
            }
        }

        static let partlyWritten = " Do NOT turn the ignition off: the ECU's flash is only partly written, and the helper program that can finish the job is still running in it. Check the cable and the battery and start the write again. It carries on with the blocks that still differ."
        static let untouched = " Nothing in the ECU's flash has changed. Turn the ignition OFF and ON again before you reconnect."

        /// What the kernel's error codes mean (its flash routines, read from the bundled kernel).
        static func kernelErrorText(_ code: UInt8) -> String {
            switch code {
            case 0x88: return "the address is outside the flash (code 88)"
            case 0x89: return "the address is not on a 128-byte boundary (code 89)"
            case 0x8A: return "the length is not a multiple of 128 bytes (code 8A)"
            case 0x8B: return "what was written reads back differently (code 8B)"
            case 0x8C: return "that is not a flash block (code 8C)"
            case 0x80...0x87: return String(format: "the flash itself reported an error (code %02X)", code)
            default: return String(format: "code %02X", code)
            }
        }
    }

    // SH7058 flash blocks, the same table FastECU's kernelmemorymodels.h and the bundled kernel use.
    public static let flashBlocks: [Range<Int>] = [
        0x00000..<0x01000, 0x01000..<0x02000, 0x02000..<0x03000, 0x03000..<0x04000,
        0x04000..<0x05000, 0x05000..<0x06000, 0x06000..<0x07000, 0x07000..<0x08000,
        0x08000..<0x20000, 0x20000..<0x40000, 0x40000..<0x60000, 0x60000..<0x80000,
        0x80000..<0xA0000, 0xA0000..<0xC0000, 0xC0000..<0xE0000, 0xE0000..<0x100000,
    ]
    /// The kernel's write buffer, and so the size of each commit.
    static let commitSize = 0x1000
    /// How much of the file goes to the kernel per message.
    static let chunkSize = 0x200
    /// Where the 8-character calibration ID sits in a subarucan ROM.
    static let calibrationIDOffset = 0x2004

    // Kernel commands (FastECU kernelcomms.h).
    static let commandCRC: UInt8 = 0x02
    static let commandVoltage: UInt8 = 0x04
    static let commandMaxMessageSize: UInt8 = 0x05
    static let commandMaxBlockSize: UInt8 = 0x06
    static let commandFlashOn: UInt8 = 0x20
    static let commandFlashOff: UInt8 = 0x21
    static let commandWriteBuffer: UInt8 = 0x22
    static let commandCheckBuffer: UInt8 = 0x23
    static let commandCommitBuffer: UInt8 = 0x24
    static let commandEraseBlock: UInt8 = 0x25

    /// No block is started below this. A battery under 12 V with the engine off is flat enough to
    /// charge first; a write that browns out halfway can leave the ECU unable to start.
    public var minimumVoltage = 12.0

    private let transport: SH7058Transport
    private let kernel: [UInt8]
    private let image: ROMImage
    private let mode: Mode
    private let allowOtherCalibration: Bool
    private let allowWhileSwitchedOff: Bool
    private let isCancelled: () -> Bool
    private let onProgress: (Progress) -> Void

    /// Set from the first erase of a real write: from then on the ECU's flash may differ from what
    /// was in it, and every message says so.
    private var flashChanged = false

    // Slices of the progress bar.
    private let setupFraction = 0.05
    private let compareFraction = 0.05
    private let verifyFraction = 0.05

    public convenience init(transport: SH7058Transport,
                            kernel: [UInt8],
                            image: ROMImage,
                            mode: Mode,
                            allowOtherCalibration: Bool = false,
                            isCancelled: @escaping () -> Bool = { false },
                            onProgress: @escaping (Progress) -> Void = { _ in }) {
        self.init(transport: transport, kernel: kernel, image: image, mode: mode,
                  allowOtherCalibration: allowOtherCalibration, allowWhileSwitchedOff: false,
                  isCancelled: isCancelled, onProgress: onProgress)
    }

    /// `allowWhileSwitchedOff` is for the tests, which write to a simulated ECU.
    init(transport: SH7058Transport,
         kernel: [UInt8],
         image: ROMImage,
         mode: Mode,
         allowOtherCalibration: Bool = false,
         allowWhileSwitchedOff: Bool,
         isCancelled: @escaping () -> Bool = { false },
         onProgress: @escaping (Progress) -> Void = { _ in }) {
        self.transport = transport
        self.kernel = kernel
        self.image = image
        self.mode = mode
        self.allowOtherCalibration = allowOtherCalibration
        self.allowWhileSwitchedOff = allowWhileSwitchedOff
        self.isCancelled = isCancelled
        self.onProgress = onProgress
    }

    // MARK: Checking the file

    /// Throws when a file cannot go into this ECU: the wrong size, or checksums the ECU would reject.
    /// Needs no car, so a screen can run it before it offers a write.
    public static func check(_ image: ROMImage) throws {
        guard image.byteCount == DensoSH7058CANReader.romSize else { throw WriterError.wrongSize(image.byteCount) }
        guard let report = try? SubaruChecksum.verifyPetrol(image) else { throw WriterError.checksumsUnreadable }
        guard report.ok else { throw WriterError.checksumsWrong(report.mismatchCount) }
    }

    // MARK: Top level

    public func write() throws -> WriteResult {
        guard Self.isEnabled || allowWhileSwitchedOff else { throw WriterError.switchedOff }
        flashChanged = false

        report(.checking, 0, "Checking the file")
        try Self.check(image)

        let reader = DensoSH7058CANReader(transport: transport, kernel: kernel, isCancelled: isCancelled,
                                          onProgress: { [weak self] progress in
                                              self?.report(.connecting, progress.fraction, progress.message)
                                          })
        let identity: DensoSH7058CANReader.Identity
        do {
            identity = try reader.startKernel()
        } catch DensoSH7058CANReader.ReaderError.cancelled {
            throw WriterError.cancelled(flashChanged: false)
        }

        try checkCancel()
        let ecuCalibration = try checkCalibration(reader, kernelWasRunning: identity.kernelAlreadyRunning)

        report(.comparing, setupFraction, "Comparing the ECU's flash with the file")
        let changed = try changedBlocks(from: setupFraction, span: compareFraction)
        guard !changed.isEmpty else {
            report(.done, 1, "The ECU already holds this ROM. Nothing needed writing.")
            return WriteResult(mode: mode, changedBlocks: [], bytesSent: 0, lowestVoltage: nil,
                               ecuCalibrationID: ecuCalibration)
        }

        try checkCancel()
        try prepareFlash()

        let writeStart = setupFraction + compareFraction
        let writeSpan = 1 - writeStart - (mode == .write ? verifyFraction : 0)
        let total = changed.reduce(0) { $0 + Self.flashBlocks[$1].count }
        var sent = 0
        var lowestVoltage: Double?
        for block in changed {
            // Stopping is only allowed here, between blocks: never with a block half written.
            try checkCancel()
            let volts = try voltage()
            lowestVoltage = min(lowestVoltage ?? volts, volts)
            guard volts >= minimumVoltage else {
                throw WriterError.lowVoltage(volts, minimum: minimumVoltage, flashChanged: flashChanged)
            }
            try erase(block)
            try writeBlock(block) { bytes in
                sent += bytes
                let verb = self.mode == .write ? "Writing" : "Test writing"
                self.report(.writing, writeStart + writeSpan * Double(sent) / Double(total),
                            "\(verb) block \(block) (\(sent / 1024) of \(total / 1024) KB)")
            }
        }

        if mode == .write {
            report(.verifying, 1 - verifyFraction, "Checking what was written")
            let stillDifferent = try changedBlocks(from: 1 - verifyFraction, span: verifyFraction)
            guard stillDifferent.isEmpty else { throw WriterError.verifyFailed(blocks: stillDifferent) }
        }

        report(.done, 1, mode == .write
               ? "Done. Turn the ignition OFF, wait 10 seconds and turn it ON again."
               : "Test write done. Nothing in the ECU changed. Turn the ignition OFF and ON again before you reconnect.")
        return WriteResult(mode: mode, changedBlocks: changed, bytesSent: sent, lowestVoltage: lowestVoltage,
                           ecuCalibrationID: ecuCalibration)
    }

    // MARK: Steps

    /// Reads the calibration ID out of the ECU's flash and refuses a file for another one. When the
    /// kernel was still running from an earlier write that stopped halfway, the ID may already be
    /// erased (all FF): that is the write being finished, not another ECU.
    private func checkCalibration(_ reader: DensoSH7058CANReader, kernelWasRunning: Bool) throws -> String? {
        let pageStart = Self.calibrationIDOffset & ~(DensoSH7058CANReader.pageSize - 1)
        let page: [UInt8]
        do {
            page = try reader.readPage(at: UInt32(pageStart))
        } catch {
            throw WriterError.failed(step: "reading the calibration ID", detail: error.localizedDescription, flashChanged: false)
        }
        let offset = Self.calibrationIDOffset - pageStart
        let inECU = Array(page[offset..<(offset + 8)])
        let inFile = image.bytes(at: Self.calibrationIDOffset, length: 8) ?? []
        let ecuText = DensoSH7058CANReader.ascii(inECU)
        if inECU == inFile || allowOtherCalibration { return ecuText }
        if kernelWasRunning, inECU.allSatisfy({ $0 == 0xFF }) { return nil }
        throw WriterError.otherCalibration(ecu: ecuText ?? "unknown", file: DensoSH7058CANReader.ascii(inFile) ?? "unknown")
    }

    /// The blocks whose CRC in the ECU differs from the file's.
    private func changedBlocks(from start: Double, span: Double) throws -> [Int] {
        var changed: [Int] = []
        for (block, range) in Self.flashBlocks.enumerated() {
            let address = UInt32(range.lowerBound)
            let length = UInt32(range.count)
            let data = try kernelCommand(Self.commandCRC, Self.bytes(address) + [0x00] + Self.bytes(length).suffix(3),
                                         step: "comparing block \(block)", timeout: 5)
            guard data.count >= 4 else {
                throw WriterError.failed(step: "comparing block \(block)", detail: "the answer was too short", flashChanged: flashChanged)
            }
            if Self.word(data) != DensoCAN.kernelCRC(image.data[range]) { changed.append(block) }
            report(.comparing, start + span * Double(block + 1) / Double(Self.flashBlocks.count),
                   "Comparing the ECU's flash with the file (block \(block + 1) of \(Self.flashBlocks.count))")
        }
        return changed
    }

    /// What FastECU's `init_flash_write` does: ask the kernel its limits, then switch its flash
    /// writing on for a write, or off for a test write. The switch is sent every time, because the
    /// kernel keeps it from an earlier run.
    private func prepareFlash() throws {
        _ = try kernelCommand(Self.commandMaxMessageSize, step: "asking the helper program's limits", timeout: 2)
        _ = try kernelCommand(Self.commandMaxBlockSize, step: "asking the helper program's limits", timeout: 2)
        _ = try kernelCommand(mode == .write ? Self.commandFlashOn : Self.commandFlashOff,
                              step: mode == .write ? "switching flash writing on" : "switching flash writing off",
                              timeout: 2)
    }

    /// The voltage the kernel measures, in volts (it answers in fiftieths of a volt).
    private func voltage() throws -> Double {
        let data = try kernelCommand(Self.commandVoltage, step: "reading the voltage", timeout: 2)
        guard data.count >= 2 else {
            throw WriterError.failed(step: "reading the voltage", detail: "the answer was too short", flashChanged: flashChanged)
        }
        return Double(Int(data[0]) << 8 | Int(data[1])) / 50
    }

    private func erase(_ block: Int) throws {
        let start = Self.flashBlocks[block].lowerBound
        // The kernel erases block 0 for any address that is not a block start: see the type's notes.
        precondition(Self.flashBlocks.contains { $0.lowerBound == start }, "erase address must be a block start")
        // Counted as changed before the answer: an erase that is not answered may still have happened.
        if mode == .write { flashChanged = true }
        _ = try kernelCommand(Self.commandEraseBlock, Self.bytes(UInt32(start)),
                              step: "erasing block \(block)", timeout: 15)
    }

    /// Sends one block 512 bytes at a time, and commits (or, for a test write, checks) each 4 KB
    /// with the CRC of what should be in the kernel's buffer.
    private func writeBlock(_ block: Int, sent: (Int) -> Void) throws {
        let range = Self.flashBlocks[block]
        var commitStart = range.lowerBound
        while commitStart < range.upperBound {
            for chunk in stride(from: commitStart, to: commitStart + Self.commitSize, by: Self.chunkSize) {
                _ = try kernelCommand(Self.commandWriteBuffer,
                                      Self.bytes(UInt32(chunk)) + Array(image.data[chunk..<(chunk + Self.chunkSize)]),
                                      step: "sending block \(block)", timeout: 3)
                sent(Self.chunkSize)
            }
            let crc = DensoCAN.kernelCRC(image.data[commitStart..<(commitStart + Self.commitSize)])
            let command = mode == .write ? Self.commandCommitBuffer : Self.commandCheckBuffer
            _ = try kernelCommand(command,
                                  Self.bytes(UInt32(commitStart)) + [UInt8(Self.commitSize >> 8), UInt8(Self.commitSize & 0xFF)] + Self.bytes(crc),
                                  step: "\(mode == .write ? "writing" : "checking") 0x\(String(format: "%05X", commitStart)) in block \(block)",
                                  timeout: 5)
            commitStart += Self.commitSize
        }
    }

    // MARK: Talking to the kernel

    /// Sends one kernel command and returns the data after the echoed command byte.
    private func kernelCommand(_ command: UInt8, _ data: [UInt8] = [], step: String, timeout: TimeInterval) throws -> [UInt8] {
        let length = data.count + 1
        let payload: [UInt8] = [UInt8(DensoSH7058CANReader.kernelStartComm >> 8), UInt8(DensoSH7058CANReader.kernelStartComm & 0xFF),
                                UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF), command] + data
        let reply: [UInt8]
        do {
            reply = try transport.request(payload, timeout: timeout)
        } catch {
            throw WriterError.failed(step: step, detail: error.localizedDescription, flashChanged: flashChanged)
        }
        guard reply.count >= 5, reply[0] == payload[0], reply[1] == payload[1] else {
            throw WriterError.failed(step: step, detail: "unexpected answer (\(DensoSH7058CANReader.hex(reply)))", flashChanged: flashChanged)
        }
        if reply[4] == 0x7F {
            throw WriterError.kernelRefused(step: step, code: reply.count > 6 ? reply[6] : 0, flashChanged: flashChanged)
        }
        guard reply[4] == command | DensoSH7058CANReader.kernelReplyFlag else {
            throw WriterError.failed(step: step, detail: "unexpected answer (\(DensoSH7058CANReader.hex(reply)))", flashChanged: flashChanged)
        }
        return Array(reply.dropFirst(5))
    }

    // MARK: Small helpers

    private func checkCancel() throws {
        if isCancelled() { throw WriterError.cancelled(flashChanged: flashChanged) }
    }

    private func report(_ phase: Phase, _ fraction: Double, _ message: String) {
        onProgress(Progress(phase: phase, fraction: min(max(fraction, 0), 1), message: message))
    }

    static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func word(_ bytes: [UInt8]) -> UInt32 {
        UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }
}
