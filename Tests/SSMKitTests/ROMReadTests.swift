import Foundation
import Testing
@testable import SSMKit

// Reading a ROM off the car cannot be tested against real hardware here, so these tests cover the
// pure, testable pieces (ISO-TP framing, the stock seed-to-key answer, the kernel cipher and its
// framing, and the STN transport's command building and parsing) plus the whole read orchestration
// against a simulated ECU.

// MARK: - ISO-TP framing

@Suite("ISO-TP segmentation and reassembly")
struct ISOTPTests {
    @Test func singleFrameHoldsShortMessages() throws {
        for length in 0...7 {
            let payload = (0..<length).map { UInt8($0 + 1) }
            let frames = ISOTP.segment(payload)
            #expect(frames.count == 1)
            #expect(frames[0].count == 8)                 // padded to a full CAN frame
            #expect(frames[0][0] == UInt8(length))        // single-frame PCI is just the length
            #expect(Array(frames[0][1..<(1 + length)]) == payload)
            #expect(try ISOTP.reassemble(frames) == payload)
        }
    }

    @Test func multiFrameRoundTrips() throws {
        for length in [8, 9, 13, 14, 100, 0x400, 1029, 4095] {
            let payload = (0..<length).map { UInt8(($0 * 7 + 3) & 0xFF) }
            let frames = ISOTP.segment(payload)
            #expect(frames.count > 1)
            // First frame carries the length and six data bytes.
            #expect(frames[0][0] == UInt8(0x10 | (length >> 8)))
            #expect(frames[0][1] == UInt8(length & 0xFF))
            // Consecutive frames are numbered 1, 2, … wrapping at 16.
            for (offset, frame) in frames.dropFirst().enumerated() {
                #expect(frame[0] == UInt8(0x20 | ((offset + 1) & 0x0F)))
            }
            #expect(try ISOTP.reassemble(frames) == payload)
        }
    }

    @Test func outOfOrderConsecutiveFrameIsRejected() {
        var frames = ISOTP.segment((0..<20).map { UInt8($0) })
        frames[2][0] = 0x25   // should be 0x22
        #expect(throws: ISOTP.FrameError.self) { try ISOTP.reassemble(frames) }
    }

    @Test func flowControlFramesAreIgnored() throws {
        var frames = ISOTP.segment((0..<20).map { UInt8($0) })
        frames.insert([0x30, 0x00, 0x00, 0, 0, 0, 0, 0], at: 1)   // ECU-style flow control, not our data
        #expect(try ISOTP.reassemble(frames) == (0..<20).map { UInt8($0) })
    }
}

// MARK: - Seed to key

@Suite("Denso CAN stock seed-to-key")
struct DensoSeedKeyTests {
    // Vectors produced by an independent transcription of FastECU's calculate_seed_key (stock table).
    @Test func matchesKnownVectors() {
        #expect(DensoCAN.stockKey(fromSeed: [0x00, 0x00, 0x00, 0x00]) == [0x96, 0x71, 0x2F, 0xA4])
        #expect(DensoCAN.stockKey(fromSeed: [0x12, 0x34, 0x56, 0x78]) == [0x59, 0xA0, 0x49, 0x67])
        #expect(DensoCAN.stockKey(fromSeed: [0xDE, 0xAD, 0xBE, 0xEF]) == [0xB6, 0xF5, 0x24, 0x21])
        #expect(DensoCAN.stockKey(fromSeed: [0xFF, 0xFF, 0xFF, 0xFF]) == [0x26, 0xE6, 0xDB, 0x59])
    }

    // Seeds a real ECU gave and the keys it accepted: a 2007 USDM Forester XT (ECU ID 4E42504007) being
    // unlocked by EcuFlash, recorded and published in the tests of tuneforge
    // (https://github.com/firefighter-19/tuneforge). The only check of this table against a car.
    @Test func answersTheSeedsARealECUGave() {
        let recorded: [(seed: [UInt8], key: [UInt8])] = [
            ([0xDD, 0xEE, 0xAB, 0x05], [0x74, 0x15, 0x7C, 0x7D]),
            ([0x0D, 0x13, 0x32, 0x08], [0xFD, 0xB2, 0x52, 0x38]),
            ([0x0F, 0xCE, 0x53, 0xBB], [0x3F, 0x97, 0xAD, 0x93]),
            ([0xA0, 0xE6, 0xDF, 0xD5], [0x5E, 0xB8, 0xE0, 0x6A]),
            ([0x25, 0xA4, 0xF1, 0x81], [0xE7, 0x6B, 0x34, 0x34]),
            ([0xAB, 0x2C, 0xEB, 0xA1], [0x8D, 0x36, 0x6E, 0x24]),
            ([0x7D, 0xAF, 0x7C, 0xBB], [0xE4, 0x3B, 0x52, 0xE2]),
            ([0xBF, 0x78, 0xFD, 0x02], [0x9A, 0x25, 0x62, 0x16]),
            // And SubieScope's own first read of a ROM from a car, on 10 October 2026: a 2009 JDM
            // Impreza WRX STI (ECU ID 6904784007, AZ1G500F) gave this seed and accepted this key.
            ([0xF0, 0xCE, 0x4B, 0x23], [0x3E, 0xA0, 0xB3, 0x40]),
        ]
        for pair in recorded {
            #expect(DensoCAN.stockKey(fromSeed: pair.seed) == pair.key)
        }
    }

    @Test func keyGenerationIsReversible() {
        // Self-consistency: the key schedule is a Feistel network, so the derived key maps back to the
        // seed. This proves the port of the (reversible) algorithm is internally consistent.
        for seed: UInt32 in [0, 1, 0x12345678, 0xDEADBEEF, 0xFFFFFFFF, 0xA5A5A5A5, 0x0000FFFF] {
            let key = DensoCAN.stockKey(fromSeed: seed)
            #expect(DensoCAN.stockSeed(fromKey: key) == seed)
        }
    }

    @Test func isDeterministic() {
        #expect(DensoCAN.stockKey(fromSeed: 0x1122_3344) == DensoCAN.stockKey(fromSeed: 0x1122_3344))
    }
}

// MARK: - Kernel cipher and framing

@Suite("Denso CAN kernel cipher and framing")
struct DensoKernelTests {
    @Test func encryptThenDecryptIsIdentity() {
        let sample = (0..<256).map { UInt8(($0 * 11 + 1) & 0xFF) }   // whole number of 32-bit words
        #expect(DensoCAN.decryptPayload(DensoCAN.encryptPayload(sample)) == sample)
    }

    @Test func encryptMatchesKnownVector() {
        #expect(DensoCAN.encryptPayload([0x11, 0x22, 0x33, 0x44]) == [0xF0, 0x38, 0x34, 0xFD])
    }

    // Eleven words of a kernel as EcuFlash sent it to a real ECU, which loaded and ran it (the same
    // 2007 Forester XT; the recording is in tuneforge, https://github.com/firefighter-19/tuneforge).
    // They are where that kernel keeps its name, so the cipher's table is right when the name comes out.
    @Test func decryptsWhatARealECUAccepted() {
        let sent: [UInt8] = [
            0x6C, 0x9E, 0x90, 0xD0, 0xE3, 0x79, 0xC7, 0x72, 0xDD, 0x25, 0xA0, 0x25, 0x00, 0xCB, 0x98, 0x74,
            0x70, 0xBD, 0xD0, 0x32, 0xA9, 0xDC, 0xEB, 0x00, 0xAE, 0xF5, 0x23, 0xE9, 0x32, 0xFC, 0x00, 0x56,
            0x84, 0x13, 0xF7, 0x59, 0xB6, 0x0C, 0x2D, 0x1D, 0xA1, 0xA6, 0xD1, 0xF8,
        ]
        let name = Array("OpenECU Subaru SH7058 OCP CAN Kernel V1.07".utf8) + [0, 0]
        #expect(DensoCAN.decryptPayload(sent) == name)
        #expect(DensoCAN.encryptPayload(name) == sent)
    }

    @Test func cipherWorksOnWholeWordsOnly() {
        // Trailing bytes that do not fill a 32-bit word are dropped, like FastECU's `len &= ~3`.
        #expect(DensoCAN.encryptPayload([0x11, 0x22, 0x33]).isEmpty)
        #expect(DensoCAN.encryptPayload([0x11, 0x22, 0x33, 0x44, 0x55]).count == 4)
    }

    @Test func bundledKernelFramesIntoBlocksThatSumToTheMagic() throws {
        let kernel = try #require(DensoSH7058CANReader.bundledKernel(), "the SH7058 kernel resource should be bundled")
        #expect(kernel.count == 6428)
        let prepared = DensoCAN.prepareKernel(kernel, startAddress: DensoSH7058CANReader.kernelStartAddress)
        #expect(prepared.blockCount == 51)
        #expect(prepared.dataLength == 6528)
        #expect(prepared.encryptedPayload.count == 6528)
        #expect(prepared.startAddress == 0xFFFF3000)

        // The encrypted payload must decrypt back to the padded, checksummed image whose 32-bit words
        // sum to the magic, with the checksum in the final word.
        let decrypted = DensoCAN.decryptPayload(prepared.encryptedPayload)
        #expect(decrypted.count == 6528)
        var sum: UInt32 = 0
        var i = 0
        while i + 4 <= decrypted.count {
            sum = sum &+ (UInt32(decrypted[i]) << 24 | UInt32(decrypted[i + 1]) << 16 | UInt32(decrypted[i + 2]) << 8 | UInt32(decrypted[i + 3]))
            i += 4
        }
        #expect(sum == DensoCAN.kernelMagic)
        #expect(Array(decrypted.suffix(4)) == [0x50, 0x07, 0x79, 0xAD])   // the checksum word
    }

    @Test func framingPadsAnExactMultipleToOneMoreBlock() {
        // A 256-byte image (exactly two blocks) still rounds the same way FastECU does.
        let image = [UInt8](repeating: 0xAB, count: 256)
        let prepared = DensoCAN.prepareKernel(image, startAddress: 0xFFFF3000)
        #expect(prepared.blockCount == 2)
        #expect(prepared.dataLength == 256)
        #expect(prepared.encryptedPayload.count == 256)
    }
}

// MARK: - STN transport command building and parsing

/// Records commands and answers them from a handler, so the transport can be tested without hardware.
final class MockELMChannel: ELMChannel, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sent: [String] = []
    var handler: (String) -> String

    init(handler: @escaping (String) -> String) { self.handler = handler }

    func exchange(_ command: String, timeout: TimeInterval) throws -> String {
        lock.lock(); sent.append(command); lock.unlock()
        return handler(command)
    }
    func close() {}
}

@Suite("ISO-TP transport over an STN adapter")
struct ISOTPTransportTests {
    @Test func detectsAnStnAdapter() {
        let stn = MockELMChannel { $0 == "STI" ? "STN2230 v5.6.4\r\r" : "?\r" }
        #expect(ISOTPELMTransport(channel: stn).detectSTN() == "STN2230 v5.6.4")

        let plain = MockELMChannel { _ in "ELM327 v1.5\r\r" }
        #expect(ISOTPELMTransport(channel: plain).detectSTN() == nil)
    }

    @Test func configureSetsUpRawCANWithSegmentation() throws {
        let channel = MockELMChannel { _ in "OK\r" }
        try ISOTPELMTransport(channel: channel).configure()
        let joined = channel.sent.joined(separator: "|")
        for expected in ["ATSP6", "ATSH7E0", "ATCRA7E8", "STCFCPA 7E0, 7E8", "STCSEGR1", "STCSEGT1"] {
            #expect(joined.contains(expected), "missing \(expected) in \(joined)")
        }
    }

    @Test func shortRequestUsesInlineDataAndParsesTheReply() throws {
        let channel = MockELMChannel { command in
            #expect(command == "STPX H:7E0, D:2701, R:1")
            return "6701ABCDEF12\r"
        }
        let reply = try ISOTPELMTransport(channel: channel).request([0x27, 0x01], timeout: 1)
        #expect(reply == [0x67, 0x01, 0xAB, 0xCD, 0xEF, 0x12])
    }

    @Test func longRequestUsesTheLengthPromptThenSendsThePayload() throws {
        let payload = (0..<220).map { UInt8($0 & 0xFF) }
        var step = 0
        let channel = MockELMChannel { command in
            step += 1
            if step == 1 {
                #expect(command == "STPX H:7E0, L:220, R:1")
                return "DATA"                     // channel returns everything up to the ">" of "DATA>"
            }
            #expect(command == payload.map { String(format: "%02X", $0) }.joined())
            return "77\r"
        }
        let transport = ISOTPELMTransport(channel: channel)
        let reply = try transport.request(payload, timeout: 1)
        #expect(reply == [0x77])
        #expect(step == 2)
    }

    @Test func parsesMultiFrameAndReportsErrors() throws {
        // Numbered ELM frames with a leading byte-count line.
        let multi = "00A\r0: 43 00 11 22 33 44 55\r1: 66 77\r"
        #expect(try ISOTPELMTransport.parseResponse(multi) == [0x43, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77])
        #expect(throws: OBDError.self) { try ISOTPELMTransport.parseResponse("NO DATA\r") }
        #expect(throws: OBDError.self) { try ISOTPELMTransport.parseResponse("CAN ERROR\r") }
    }
}

// MARK: - End-to-end read against a simulated ECU

/// A stand-in Denso SH7058 ECU that answers the connect/unlock, kernel upload and page-read sequence
/// at the payload level, so the reader can be driven end to end without a car or an adapter.
class SimulatedSH7058ECU: SH7058Transport, @unchecked Sendable {
    let rom: [UInt8]
    let seed: [UInt8] = [0x12, 0x34, 0x56, 0x78]
    private(set) var kernelRunning = false
    private(set) var uploadedBlocks: [UInt8] = []
    private var unlocked = false

    init(rom: [UInt8]) { self.rom = rom }

    func request(_ payload: [UInt8], responseCount: Int, timeout: TimeInterval) throws -> [UInt8] {
        // Kernel protocol messages are framed BE EF <len> <cmd> ...
        if payload.count >= 5, payload[0] == 0xBE, payload[1] == 0xEF {
            let cmd = payload[4]
            if cmd == 0x01 {   // request kernel id
                return kernelRunning ? [0xBE, 0xEF, 0x00, 0x05, 0x41, 0x53, 0x53, 0x4D, 0x4B] : []
            }
            if cmd == 0x03 {   // read area: 00 <addr(3)> <size(2)>
                guard kernelRunning else { return [] }
                let addr = Int(payload[6]) << 16 | Int(payload[7]) << 8 | Int(payload[8])
                let size = Int(payload[9]) << 8 | Int(payload[10])
                let page = Array(rom[addr..<(addr + size)])
                return [0xBE, 0xEF, 0x04, 0x01, 0x43] + page
            }
            return []
        }

        switch payload.first {
        case 0xAA:                       // ECU identification
            return [0xEA, 0x00, 0x00, 0x00, 0x7A, 0x12, 0x34, 0x56, 0x78]
        case 0x09 where payload.count >= 2 && payload[1] == 0x04:   // CAL ID
            return [0x49, 0x04, 0x00] + Array("AF28A000".utf8)
        case 0x10:                       // diagnostic / programming session
            let sub = payload[1]
            if sub == 0x03 { return [0x50, 0x03] }
            if sub == 0x43 { return [0x7F, 0x10, 0x11] }            // this ECU does not do 10 43
            if sub == 0x02 || sub == 0x42 { return [0x50, sub] }
            return [0x7F, 0x10, 0x12]
        case 0x27 where payload.count == 2 && payload[1] == 0x01:   // seed request
            return [0x67, 0x01] + seed
        case 0x27 where payload.count >= 2 && payload[1] == 0x02:   // key
            let key = Array(payload.dropFirst(2))
            guard key == DensoCAN.stockKey(fromSeed: seed) else { return [0x7F, 0x27, 0x35] }
            unlocked = true
            return [0x67, 0x02]
        case 0x34:                       // request download
            guard unlocked else { return [0x7F, 0x34, 0x22] }
            return [0x74, 0x20]
        case 0xB6:                       // transfer data block
            uploadedBlocks.append(contentsOf: payload.dropFirst(4))
            return [0xF6]                // what a real ECU answers (recorded by tuneforge's author), not 76
        case 0x37:                       // transfer exit
            return [0x77]
        case 0x31:                       // start routine (jump to kernel)
            kernelRunning = true
            return [0x71, 0x01, 0x02, 0x02]
        default:
            return []
        }
    }
}

@Suite("SH7058 CAN reader (simulated ECU)")
struct DensoReaderEndToEndTests {
    /// A 1 MB synthetic ROM with a recognisable pattern and a calibration ID at the CAN offset.
    static func makeROM() -> [UInt8] {
        var rom = (0..<DensoSH7058CANReader.romSize).map { UInt8(($0 &* 2_654_435_761) >> 13 & 0xFF) }
        for (i, byte) in "AF28A000".utf8.enumerated() { rom[0x2004 + i] = byte }
        return rom
    }

    @Test func readsTheWholeROMThroughTheKernel() throws {
        let expected = Self.makeROM()
        let ecu = SimulatedSH7058ECU(rom: expected)
        let kernel = try #require(DensoSH7058CANReader.bundledKernel())

        var lastFraction = 0.0
        let reader = DensoSH7058CANReader(transport: ecu, kernel: kernel,
                                          onProgress: { lastFraction = $0.fraction })
        let result = try reader.read()

        #expect(result.rom.data == expected)
        #expect(result.rom.byteCount == DensoSH7058CANReader.romSize)
        #expect(result.calibrationID == "AF28A000")
        #expect(lastFraction == 1.0)
        #expect(ecu.kernelRunning)
        // The blocks the ECU received are exactly the prepared, encrypted kernel payload.
        let prepared = DensoCAN.prepareKernel(kernel, startAddress: DensoSH7058CANReader.kernelStartAddress)
        #expect(ecu.uploadedBlocks == prepared.encryptedPayload)
    }

    @Test func stopsWhenCancelled() {
        let ecu = SimulatedSH7058ECU(rom: Self.makeROM())
        let kernel = DensoSH7058CANReader.bundledKernel() ?? [UInt8](repeating: 0, count: 256)
        let cancelled = { true }   // already cancelled before the first page
        let reader = DensoSH7058CANReader(transport: ecu, kernel: kernel, isCancelled: cancelled)
        #expect(throws: DensoSH7058CANReader.ReaderError.cancelled) { _ = try reader.read() }
    }

    @Test func reportsAWrongKeyAsAConnectFailure() {
        // An ECU that never accepts the key fails at the unlock step, not silently.
        final class BadKeyECU: SimulatedSH7058ECU, @unchecked Sendable {
            override func request(_ payload: [UInt8], responseCount: Int, timeout: TimeInterval) throws -> [UInt8] {
                if payload.first == 0x27, payload.count >= 2, payload[1] == 0x02 { return [0x7F, 0x27, 0x35] }
                return try super.request(payload, responseCount: responseCount, timeout: timeout)
            }
        }
        let ecu = BadKeyECU(rom: Self.makeROM())
        let reader = DensoSH7058CANReader(transport: ecu, kernel: [UInt8](repeating: 0, count: 256))
        #expect(throws: DensoSH7058CANReader.ReaderError.self) { _ = try reader.read() }
    }

    @Test func saysToWaitWhenTheECUHasLockedItself() {
        // After wrong keys the ECU refuses even to give a seed for a while (7F 27 37).
        final class LockedECU: SimulatedSH7058ECU, @unchecked Sendable {
            override func request(_ payload: [UInt8], responseCount: Int, timeout: TimeInterval) throws -> [UInt8] {
                if payload.first == 0x27 { return [0x7F, 0x27, 0x37] }
                return try super.request(payload, responseCount: responseCount, timeout: timeout)
            }
        }
        let reader = DensoSH7058CANReader(transport: LockedECU(rom: Self.makeROM()), kernel: [UInt8](repeating: 0, count: 256))
        do {
            _ = try reader.read()
            Issue.record("a locked ECU must stop the read")
        } catch {
            #expect(error.localizedDescription.contains("wait 10 seconds"))
        }
    }

    @Test func explainsAKeyTheECUDoesNotAccept() {
        #expect(DensoSH7058CANReader.securityRefusal([0x7F, 0x27, 0x35])?.contains("original software") == true)
        #expect(DensoSH7058CANReader.securityRefusal([0x7F, 0x27, 0x36])?.contains("wait 10 seconds") == true)
        // Anything else keeps the reader's own wording.
        #expect(DensoSH7058CANReader.securityRefusal([0x7F, 0x27, 0x12]) == nil)
        #expect(DensoSH7058CANReader.securityRefusal([0x67, 0x02]) == nil)
        #expect(DensoSH7058CANReader.securityRefusal([]) == nil)
    }
}
