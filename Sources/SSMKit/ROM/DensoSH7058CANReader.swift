import Foundation

/// Reads a ROM image off a Denso SH7058 "subarucan" engine ECU (the 2008 STI's ECU) over OBD-II CAN.
///
/// It loads a small helper program (a "kernel") into the ECU's RAM and asks that kernel to copy the
/// flash out, a page at a time. It never writes to flash: there is no erase, no flash write, no
/// checksum written back to the car. The worst this does to the car is leave the kernel running in
/// RAM, which is gone the moment the ignition is cycled.
///
/// Ported from the READ path of FastECU's `flash_ecu_subaru_denso_sh7058_can.cpp` (GPLv3):
/// `connect_bootloader`, `upload_kernel` and `read_mem`. The write path was deliberately not ported.
///
/// It has read one real car: a 2009 JDM Impreza WRX STI (ECU ID 6904784007, AZ1G500F) through a
/// Tactrix OpenPort on 10 October 2026, 1 MB in 55 seconds, with every checksum in the ROM right.
/// Through an OBDLink (STN) adapter it has never run on a car. The pure pieces it relies on
/// (seed-key, kernel cipher and framing, page maths) are unit-tested, and the request/response
/// sequence runs end to end against a simulated ECU. Treat it as experimental.
public final class DensoSH7058CANReader {
    public enum Phase: Sendable, Equatable {
        case connecting
        case uploadingKernel
        case reading
        case done
    }

    /// Where the read has got to, for a progress bar and a status line.
    public struct Progress: Sendable, Equatable {
        public let phase: Phase
        public let bytesRead: Int
        public let totalBytes: Int
        /// 0...1 across the whole job (connect and upload count as a small slice before reading).
        public let fraction: Double
        public let message: String
    }

    /// What a finished read produced.
    public struct ReadResult: Sendable, Equatable {
        public let rom: ROMImage
        public let ecuID: String?
        public let calibrationID: String?
        public let vin: String?
    }

    public enum ReaderError: Error, LocalizedError, Equatable {
        case cancelled
        case noKernel
        case connectFailed(String)
        case kernelUploadFailed(String)
        case readFailed(String)
        case shortPage(expected: Int, got: Int)

        public var errorDescription: String? {
            switch self {
            case .cancelled: return "The read was stopped."
            case .noKernel: return "The helper program (kernel) for this ECU could not be found in the app."
            case .connectFailed(let detail): return "Could not start talking to the ECU: \(detail)"
            case .kernelUploadFailed(let detail): return "Could not load the helper program into the ECU: \(detail)"
            case .readFailed(let detail): return "The ROM read stopped early: \(detail)"
            case .shortPage(let expected, let got): return "The ECU returned \(got) bytes for a page instead of \(expected)."
            }
        }
    }

    // SH7058 1 MB petrol ECU facts (FastECU protocols.cfg "subarucan" and kernelmemorymodels.h).
    public static let kernelStartAddress: UInt32 = 0xFFFF3000
    public static let romSize = 0x100000          // 1 MB
    static let pageSize = 0x400                    // 1 KB per kernel read
    static let kernelName = "ssmk_can_tp_sh7058"

    // Kernel protocol constants (FastECU kernelcomms.h).
    static let kernelStartComm: UInt16 = 0xBEEF
    static let kernelIDCommand: UInt8 = 0x01
    static let kernelReadArea: UInt8 = 0x03
    static let kernelReplyFlag: UInt8 = 0x40

    private let transport: SH7058Transport
    private let kernel: [UInt8]
    private let isCancelled: () -> Bool
    private let onProgress: (Progress) -> Void

    /// Reading connect/upload counts as this slice of the bar; the rest is the page read.
    private let setupFraction = 0.05

    public init(transport: SH7058Transport,
                kernel: [UInt8],
                isCancelled: @escaping () -> Bool = { false },
                onProgress: @escaping (Progress) -> Void = { _ in }) {
        self.transport = transport
        self.kernel = kernel
        self.isCancelled = isCancelled
        self.onProgress = onProgress
    }

    /// The kernel binary bundled with the app, or nil if it is missing.
    public static func bundledKernel() -> [UInt8]? {
        guard let url = SSMResources.url(forKernel: kernelName), let data = try? Data(contentsOf: url) else { return nil }
        return [UInt8](data)
    }

    // MARK: Top level

    public func read() throws -> ReadResult {
        try checkCancel()
        report(.connecting, bytesRead: 0, "Waking the ECU and unlocking it")
        let identity = try connectBootloader()

        if !identity.kernelAlreadyRunning {
            try checkCancel()
            report(.uploadingKernel, bytesRead: 0, "Loading the helper program into the ECU")
            try uploadKernel()
        }

        try checkCancel()
        report(.reading, bytesRead: 0, "Reading the ROM")
        let data = try readMemory()

        report(.done, bytesRead: data.count, "Done")
        return ReadResult(rom: ROMImage(data: data), ecuID: identity.ecuID,
                          calibrationID: identity.calibrationID, vin: identity.vin)
    }

    // MARK: Connect / unlock

    private struct Identity {
        var ecuID: String?
        var calibrationID: String?
        var vin: String?
        var kernelAlreadyRunning = false
    }

    private func connectBootloader() throws -> Identity {
        var identity = Identity()

        // If a kernel is already live (a previous run left it there), skip straight past the unlock.
        if let reply = try? transport.request(requestKernelIDPayload(), timeout: 1.5), isKernelIDReply(reply) {
            identity.kernelAlreadyRunning = true
            return identity
        }

        // ECU identification, VIN and calibration ID. These are informational; a car that will not
        // answer one of them should not stop the read, so they are best-effort.
        if let reply = try? transport.request([0xAA], timeout: 2), reply.count >= 9, reply[0] == 0xEA {
            identity.ecuID = reply[4..<9].map { String(format: "%02X", $0) }.joined()
        }
        if let reply = try? transport.request([0x09, 0x02], timeout: 2), reply.count > 3, reply[0] == 0x49, reply[1] == 0x02 {
            identity.vin = Self.ascii(Array(reply.dropFirst(3)))
        }
        if let reply = try? transport.request([0x09, 0x04], timeout: 2), reply.count > 3, reply[0] == 0x49, reply[1] == 0x04 {
            identity.calibrationID = Self.ascii(Array(reply.dropFirst(3)))
        }

        // Diagnostic sessions. The ECU answers one or both; which one decides the programming session later.
        let has1003 = (try? transport.request([0x10, 0x03], timeout: 2)).map { $0.count >= 2 && $0[0] == 0x50 && $0[1] == 0x03 } ?? false
        let has1043 = (try? transport.request([0x10, 0x43], timeout: 2)).map { $0.count >= 2 && $0[0] == 0x50 && $0[1] == 0x43 } ?? false

        // Security access: ask for the seed, answer with the stock key.
        let seedReply = try transport.request([0x27, 0x01], timeout: 2)
        guard seedReply.count >= 6, seedReply[0] == 0x67, seedReply[1] == 0x01 else {
            throw ReaderError.connectFailed(Self.securityRefusal(seedReply)
                ?? "the ECU did not give a security seed (\(Self.hex(seedReply)))")
        }
        let seed = Array(seedReply[2..<6])
        let key = DensoCAN.stockKey(fromSeed: seed)
        let keyReply = try transport.request([0x27, 0x02] + key, timeout: 2)
        guard keyReply.count >= 2, keyReply[0] == 0x67, keyReply[1] == 0x02 else {
            throw ReaderError.connectFailed(Self.securityRefusal(keyReply)
                ?? "the ECU rejected the security key (\(Self.hex(keyReply)))")
        }

        // Enter the programming session that matches the diagnostic session it accepted.
        var sub: [UInt8] = []
        if has1003 { sub.append(0x02) }
        if has1043 { sub.append(0x42) }
        if sub.isEmpty { sub = [0x02] }   // default to the standard programming session
        let sessionReply = try transport.request([0x10] + sub, timeout: 2)
        guard sessionReply.count >= 2, sessionReply[0] == 0x50, sessionReply[1] == 0x02 || sessionReply[1] == 0x42 else {
            throw ReaderError.connectFailed("the ECU would not enter the programming session (\(Self.hex(sessionReply)))")
        }

        return identity
    }

    // MARK: Kernel upload

    private func uploadKernel() throws {
        guard !kernel.isEmpty else { throw ReaderError.noKernel }
        let prepared = DensoCAN.prepareKernel(kernel, startAddress: Self.kernelStartAddress)
        let start = prepared.startAddress

        // Request download: tell the ECU where the kernel goes and how big it is (24-bit fields).
        let initReply = try transport.request([0x34, 0x04, 0x33,
                                               UInt8(start >> 16 & 0xFF), UInt8(start >> 8 & 0xFF), UInt8(start & 0xFF),
                                               UInt8(prepared.dataLength >> 16 & 0xFF), UInt8(prepared.dataLength >> 8 & 0xFF), UInt8(prepared.dataLength & 0xFF)],
                                              timeout: 3)
        guard initReply.count >= 2, initReply[0] == 0x74, initReply[1] == 0x20 else {
            throw ReaderError.kernelUploadFailed("the ECU refused the download request (\(Self.hex(initReply)))")
        }

        // Send the payload in 128-byte blocks, then one final empty block, exactly as FastECU does.
        let payload = prepared.encryptedPayload
        for block in 0...prepared.blockCount {
            try checkCancel()
            let blockAddress = start &+ UInt32(block * 128)
            var message: [UInt8] = [0xB6, UInt8(blockAddress >> 16 & 0xFF), UInt8(blockAddress >> 8 & 0xFF), UInt8(blockAddress & 0xFF)]
            if block < prepared.blockCount {
                message.append(contentsOf: payload[(block * 128)..<(block * 128 + 128)])
            }
            // The ECU acks each block; FastECU does not inspect the ack, so neither do we. On a real
            // ECU (a 2009 STI) every block of data is answered with F6, and the final empty one with
            // 7F B6 13: it does not take that one, and the read goes through all the same.
            _ = try transport.request(message, timeout: 2)
            report(.uploadingKernel, bytesRead: 0,
                   "Loading the helper program into the ECU (\(Int(Double(block) / Double(prepared.blockCount) * 100))%)",
                   fraction: setupFraction * Double(block) / Double(prepared.blockCount) * 0.9)
        }

        // Transfer exit.
        let exitReply = try transport.request([0x37], timeout: 2)
        guard exitReply.count >= 1, exitReply[0] == 0x77 else {
            throw ReaderError.kernelUploadFailed("the ECU refused transfer exit (\(Self.hex(exitReply)))")
        }

        // Start routine: jump to the kernel.
        let startReply = try transport.request([0x31, 0x01, 0x02, 0x02, 0x02], timeout: 3)
        guard startReply.count >= 1, startReply[0] == 0x71 else {
            throw ReaderError.kernelUploadFailed("the ECU would not start the helper program (\(Self.hex(startReply)))")
        }

        // Confirm the kernel is alive and answering.
        let idReply = try transport.request(requestKernelIDPayload(), timeout: 2)
        guard isKernelIDReply(idReply) else {
            throw ReaderError.kernelUploadFailed("the helper program did not report in (\(Self.hex(idReply)))")
        }
    }

    // MARK: Reading

    private func readMemory() throws -> [UInt8] {
        var data: [UInt8] = []
        data.reserveCapacity(Self.romSize)
        var address = 0
        while address < Self.romSize {
            try checkCancel()
            let page = try readPage(at: UInt32(address))
            data.append(contentsOf: page)
            address += Self.pageSize
            let fraction = setupFraction + (1 - setupFraction) * Double(address) / Double(Self.romSize)
            report(.reading, bytesRead: data.count,
                   "Reading the ROM (\(data.count / 1024) of \(Self.romSize / 1024) KB)", fraction: fraction)
        }
        return data
    }

    private func readPage(at address: UInt32) throws -> [UInt8] {
        let size = Self.pageSize
        let payload: [UInt8] = [
            UInt8(Self.kernelStartComm >> 8), UInt8(Self.kernelStartComm & 0xFF),
            0x00, 0x07,                                    // kernel data length (command + 6 bytes)
            Self.kernelReadArea,
            0x00,                                          // address high byte (ROM is under 0x1000000)
            UInt8(address >> 16 & 0xFF), UInt8(address >> 8 & 0xFF), UInt8(address & 0xFF),
            UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF),
        ]
        let reply = try transport.request(payload, timeout: 3)
        guard reply.count >= 5,
              reply[0] == UInt8(Self.kernelStartComm >> 8), reply[1] == UInt8(Self.kernelStartComm & 0xFF),
              reply[4] == (Self.kernelReadArea | Self.kernelReplyFlag) else {
            throw ReaderError.readFailed("unexpected answer at 0x\(String(address, radix: 16)) (\(Self.hex(reply)))")
        }
        let pageBytes = Array(reply.dropFirst(5))
        guard pageBytes.count >= size else { throw ReaderError.shortPage(expected: size, got: pageBytes.count) }
        return Array(pageBytes.prefix(size))
    }

    // MARK: Kernel ID helper

    private func requestKernelIDPayload() -> [UInt8] {
        [UInt8(Self.kernelStartComm >> 8), UInt8(Self.kernelStartComm & 0xFF), 0x00, 0x01, Self.kernelIDCommand, 0x00, 0x00, 0x00]
    }

    private func isKernelIDReply(_ reply: [UInt8]) -> Bool {
        reply.count > 4
            && reply[0] == UInt8(Self.kernelStartComm >> 8)
            && reply[1] == UInt8(Self.kernelStartComm & 0xFF)
            && reply[4] == (Self.kernelIDCommand | Self.kernelReplyFlag)
    }

    // MARK: Small helpers

    private func checkCancel() throws {
        if isCancelled() { throw ReaderError.cancelled }
    }

    private func report(_ phase: Phase, bytesRead: Int, _ message: String, fraction: Double? = nil) {
        let f = fraction ?? (phase == .reading ? setupFraction : (phase == .done ? 1 : 0))
        onProgress(Progress(phase: phase, bytesRead: bytesRead, totalBytes: Self.romSize,
                            fraction: min(max(f, 0), 1), message: message))
    }

    static func ascii(_ bytes: [UInt8]) -> String? {
        let text = String(decoding: bytes.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.isEmpty ? "no reply" : bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// What the ECU means when it refuses the unlock (`7F 27` and a reason), in words a person can act
    /// on. After wrong keys an ECU refuses every new try for a short while: about ten seconds on the
    /// 2007 Forester XT that tuneforge's author measured (https://github.com/firefighter-19/tuneforge).
    static func securityRefusal(_ reply: [UInt8]) -> String? {
        guard reply.count >= 3, reply[0] == 0x7F, reply[1] == 0x27 else { return nil }
        switch reply[2] {
        case 0x35:
            return "the ECU did not accept the key. This only works on an ECU with its original software: one tuned with EcuTek, Cobb or similar has a key of its own. Trying again will not help, and after a second wrong key the ECU refuses every try for about 10 seconds."
        case 0x36, 0x37:
            return "the ECU has locked itself for a moment after a wrong key. Leave the ignition on, wait 10 seconds and try again."
        default:
            return nil
        }
    }
}
