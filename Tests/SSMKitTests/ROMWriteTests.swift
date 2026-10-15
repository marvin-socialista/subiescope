import Foundation
import Testing
@testable import SSMKit

// The ROM writer (switched off in the app) against a simulated ECU whose kernel handles the flash
// commands the way the bundled kernel does: read from its code, not only from FastECU.

/// The simulated ECU from the read tests, with the kernel's flash commands added: CRC, voltage, the
/// flash on/off switch, the 4 KB write buffer, check, commit and erase. Erasing and committing do
/// nothing while flash writing is off, an erase address that is not a block start erases block 0,
/// and a commit can only clear bits, as with real flash that was not erased first.
final class SimulatedSH7058Flash: SimulatedSH7058ECU, @unchecked Sendable {
    var volts = 12.6
    private(set) var flashOn = false
    private(set) var requestCount = 0
    private(set) var erased: [UInt32] = []
    private(set) var committed: [UInt32] = []
    private(set) var checked: [UInt32] = []
    private(set) var flashSwitches: [UInt8] = []
    /// Makes the commit at this address fail once, as a flash error would.
    var failCommitOnceAt: UInt32?
    private var buffer = [UInt8](repeating: 0xFF, count: 0x1000)

    override func request(_ payload: [UInt8], responseCount: Int, timeout: TimeInterval) throws -> [UInt8] {
        requestCount += 1
        guard kernelRunning, payload.count >= 5, payload[0] == 0xBE, payload[1] == 0xEF else {
            return try super.request(payload, responseCount: responseCount, timeout: timeout)
        }
        let command = payload[4]
        let data = Array(payload.dropFirst(5))
        func word(_ at: Int) -> Int { Int(data[at]) << 24 | Int(data[at + 1]) << 16 | Int(data[at + 2]) << 8 | Int(data[at + 3]) }
        func ok(_ answer: [UInt8] = []) -> [UInt8] {
            let length = answer.count + 1
            return [0xBE, 0xEF, UInt8(length >> 8), UInt8(length & 0xFF), command | 0x40] + answer
        }
        func refuse(_ code: UInt8) -> [UInt8] { [0xBE, 0xEF, 0x00, 0x03, 0x7F, command, code] }

        switch command {
        case 0x02:   // CRC: address, 00, 24-bit length
            let start = word(0)
            let length = Int(data[5]) << 16 | Int(data[6]) << 8 | Int(data[7])
            return ok(DensoSH7058CANWriter.bytes(DensoCAN.kernelCRC(rom[start..<(start + length)])))
        case 0x04:
            let fiftieths = Int((volts * 50).rounded())
            return ok([UInt8(fiftieths >> 8), UInt8(fiftieths & 0xFF)])
        case 0x05: return ok([0x00, 0x00, 0x02, 0x05])
        case 0x06: return ok([0x00, 0x00, 0x10, 0x00])
        case 0x20, 0x21:
            flashOn = command == 0x20
            flashSwitches.append(command)
            return ok()
        case 0x22:   // write buffer: address, 512 bytes
            guard data.count == 4 + 0x200 else { return refuse(0x30) }
            let offset = word(0) & 0xFFF
            buffer.replaceSubrange(offset..<(offset + 0x200), with: data[4...])
            return ok()
        case 0x23, 0x24:   // check / commit: address, 16-bit length, CRC
            let start = word(0)
            let length = Int(data[4]) << 8 | Int(data[5])
            guard DensoCAN.kernelCRC(buffer[0..<length]) == UInt32(word(6)) else { return refuse(0x31) }
            if command == 0x23 { checked.append(UInt32(start)); return ok() }
            if failCommitOnceAt == UInt32(start) {
                failCommitOnceAt = nil
                return refuse(0x86)
            }
            if flashOn {
                for i in 0..<length { rom[start + i] &= buffer[i] }
                guard Array(rom[start..<(start + length)]) == Array(buffer[0..<length]) else { return refuse(0x8B) }
            }
            committed.append(UInt32(start))
            return ok()
        case 0x25:   // erase: the block that starts at this address, or block 0
            let address = word(0)
            erased.append(UInt32(address))
            let block = DensoSH7058CANWriter.flashBlocks.firstIndex { $0.lowerBound == address } ?? 0
            if flashOn {
                let range = DensoSH7058CANWriter.flashBlocks[block]
                rom.replaceSubrange(range, with: repeatElement(0xFF, count: range.count))
            }
            return ok()
        default:
            return try super.request(payload, responseCount: responseCount, timeout: timeout)
        }
    }
}

@Suite("SH7058 CAN writer (simulated ECU)")
struct DensoWriterTests {
    static let kernel = DensoSH7058CANReader.bundledKernel() ?? []

    /// A 1 MB ROM like the car's: the calibration ID at 0x2004 and a checksum table at 0xFFB80 with
    /// two regions, both correct.
    static func makeROM(calibration: String = "AZ1G500F") -> [UInt8] {
        var rom = (0..<0x100000).map { UInt8(($0 &* 2_654_435_761) >> 13 & 0xFF) }
        for (i, byte) in calibration.utf8.enumerated() { rom[0x2004 + i] = byte }
        let table = 0x0FFB80
        for i in 0..<(17 * 12) { rom[table + i] = 0 }
        for (index, region) in [(0x0, 0x8000), (0x8000, 0xFFB80)].enumerated() {
            let record = table + index * 12
            rom.replaceSubrange(record..<(record + 4), with: DensoSH7058CANWriter.bytes(UInt32(region.0)))
            rom.replaceSubrange((record + 4)..<(record + 8), with: DensoSH7058CANWriter.bytes(UInt32(region.1)))
        }
        return try! SubaruChecksum.correctPetrol(ROMImage(data: rom))!.rom.data
    }

    /// The ROM with a map changed in block 2 and one in block 14 (its target boost map), checksums corrected (in block 15).
    static func editedROM(from original: [UInt8]) -> ROMImage {
        var rom = original
        rom[0x2800] ^= 0x5A
        rom[0xC0E5C] = 0x42
        return try! SubaruChecksum.correctPetrol(ROMImage(data: rom))!.rom
    }

    func writer(_ ecu: SH7058Transport, _ image: ROMImage, _ mode: DensoSH7058CANWriter.Mode = .write,
                allowOtherCalibration: Bool = false, isCancelled: @escaping () -> Bool = { false }) -> DensoSH7058CANWriter {
        DensoSH7058CANWriter(transport: ecu, kernel: Self.kernel, image: image, mode: mode,
                             allowOtherCalibration: allowOtherCalibration, allowWhileSwitchedOff: true,
                             isCancelled: isCancelled)
    }

    // MARK: Switched off

    @Test func isSwitchedOffAndSendsNothing() {
        #expect(DensoSH7058CANWriter.isEnabled == false)
        let original = Self.makeROM()
        let ecu = SimulatedSH7058Flash(rom: original)
        for mode in [DensoSH7058CANWriter.Mode.write, .testWrite] {
            let writer = DensoSH7058CANWriter(transport: ecu, kernel: Self.kernel, image: Self.editedROM(from: original), mode: mode)
            #expect(throws: DensoSH7058CANWriter.WriterError.switchedOff) { _ = try writer.write() }
        }
        #expect(ecu.requestCount == 0)
        #expect(ecu.rom == original)
    }

    // MARK: Pure pieces

    @Test func kernelCRCMatchesABitByBitReference() {
        // The plain shift-register form of the same CRC, to pin the table down independently.
        func reference(_ bytes: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0x5AA5A55A : crc >> 1 }
            }
            return ~crc
        }
        let samples: [[UInt8]] = [[], Array("123456789".utf8), [0x00], [0xFF, 0xFF, 0xFF, 0xFF],
                                  (0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }]
        for sample in samples { #expect(DensoCAN.kernelCRC(sample) == reference(sample)) }
        #expect(DensoCAN.kernelCRC([UInt8]()) == 0)
        // It is not the everyday CRC-32 (which gives CBF43926 for "123456789").
        #expect(DensoCAN.kernelCRC(Array("123456789".utf8)) != 0xCBF4_3926)
    }

    @Test func flashBlocksAreTheKernelsOwnTable() throws {
        // The bundled kernel keeps the block starts (and the end, 0x100000) at 0xFFFF48D8.
        let kernel = try #require(DensoSH7058CANReader.bundledKernel())
        let at = 0xFFFF48D8 - Int(DensoSH7058CANReader.kernelStartAddress)
        let table = (0...16).map { Int(DensoSH7058CANWriter.word(Array(kernel[(at + $0 * 4)..<(at + $0 * 4 + 4)]))) }
        #expect(table == DensoSH7058CANWriter.flashBlocks.map(\.lowerBound) + [0x100000])
        // Back to back over the whole megabyte, every block a whole number of 4 KB commits.
        for (a, b) in zip(DensoSH7058CANWriter.flashBlocks, DensoSH7058CANWriter.flashBlocks.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
        #expect(DensoSH7058CANWriter.flashBlocks.allSatisfy { $0.count % DensoSH7058CANWriter.commitSize == 0 })
    }

    // MARK: The file

    @Test func refusesABadFileBeforeTouchingTheCar() {
        let original = Self.makeROM()
        let ecu = SimulatedSH7058Flash(rom: original)

        var broken = original
        broken[0x40000] ^= 0xFF   // a changed map without corrected checksums
        #expect(throws: DensoSH7058CANWriter.WriterError.checksumsWrong(1)) {
            _ = try writer(ecu, ROMImage(data: broken)).write()
        }
        #expect(throws: DensoSH7058CANWriter.WriterError.wrongSize(512 * 1024)) {
            _ = try writer(ecu, ROMImage(data: Array(original.prefix(512 * 1024)))).write()
        }
        #expect(ecu.requestCount == 0)
    }

    // MARK: Writing

    @Test func writesOnlyTheBlocksThatDiffer() throws {
        let original = Self.makeROM()
        let image = Self.editedROM(from: original)
        let ecu = SimulatedSH7058Flash(rom: original)

        var phases: [DensoSH7058CANWriter.Phase] = []
        var lastFraction = 0.0
        let writer = DensoSH7058CANWriter(transport: ecu, kernel: Self.kernel, image: image, mode: .write,
                                          allowWhileSwitchedOff: true,
                                          onProgress: { phases.append($0.phase); lastFraction = $0.fraction })
        let result = try writer.write()

        #expect(result.changedBlocks == [2, 14, 15])
        #expect(ecu.rom == image.data)
        #expect(ecu.erased == [0x2000, 0xC0000, 0xE0000])
        #expect(ecu.flashSwitches == [0x20])
        #expect(result.bytesSent == 0x1000 + 0x20000 + 0x20000)
        #expect(result.lowestVoltage == 12.6)
        #expect(result.ecuCalibrationID == "AZ1G500F")
        #expect(phases.contains(.verifying))
        #expect(phases.last == .done)
        #expect(lastFraction == 1)
    }

    @Test func aTestWriteLeavesTheFlashAlone() throws {
        let original = Self.makeROM()
        let edited = Self.editedROM(from: original)
        let ecu = SimulatedSH7058Flash(rom: original)
        // A real write first, which leaves flash writing switched on in the kernel.
        _ = try writer(ecu, edited).write()
        #expect(ecu.flashOn)
        let committedBefore = ecu.committed.count

        // A test write back to the original goes through every step and changes nothing.
        let result = try writer(ecu, ROMImage(data: original), .testWrite).write()

        #expect(result.mode == .testWrite)
        #expect(result.changedBlocks == [2, 14, 15])
        #expect(ecu.rom == edited.data)
        #expect(ecu.flashSwitches == [0x20, 0x21])
        #expect(ecu.committed.count == committedBefore)
        #expect(ecu.checked.count == 1 + 32 + 32)
        #expect(ecu.erased.suffix(3) == [0x2000, 0xC0000, 0xE0000])   // sent, and ignored by the kernel
    }

    @Test func writesNothingWhenTheECUAlreadyHasTheROM() throws {
        let original = Self.makeROM()
        let ecu = SimulatedSH7058Flash(rom: original)
        let result = try writer(ecu, ROMImage(data: original)).write()
        #expect(result.changedBlocks.isEmpty)
        #expect(result.bytesSent == 0)
        #expect(ecu.erased.isEmpty)
        #expect(ecu.flashSwitches.isEmpty)
    }

    // MARK: Refusals

    @Test func refusesAFileForAnotherCalibration() throws {
        let original = Self.makeROM()
        let other = ROMImage(data: Self.makeROM(calibration: "AZ1G202I"))
        let ecu = SimulatedSH7058Flash(rom: original)

        #expect(throws: DensoSH7058CANWriter.WriterError.otherCalibration(ecu: "AZ1G500F", file: "AZ1G202I")) {
            _ = try writer(ecu, other).write()
        }
        #expect(ecu.erased.isEmpty)
        #expect(ecu.rom == original)

        // Said out loud, it goes ahead.
        _ = try writer(ecu, other, allowOtherCalibration: true).write()
        #expect(ecu.rom == other.data)
    }

    @Test func refusesALowBattery() {
        let original = Self.makeROM()
        let ecu = SimulatedSH7058Flash(rom: original)
        ecu.volts = 11.4
        #expect(throws: DensoSH7058CANWriter.WriterError.lowVoltage(11.4, minimum: 12, flashChanged: false)) {
            _ = try writer(ecu, Self.editedROM(from: original)).write()
        }
        #expect(ecu.erased.isEmpty)
        #expect(ecu.rom == original)
    }

    // MARK: When it goes wrong halfway

    @Test func aFailedWriteIsFinishedByRunningItAgain() throws {
        let original = Self.makeROM()
        let image = Self.editedROM(from: original)
        let ecu = SimulatedSH7058Flash(rom: original)
        // Block 2 holds the calibration ID; it is erased and then its only commit fails.
        ecu.failCommitOnceAt = 0x2000

        do {
            _ = try writer(ecu, image).write()
            Issue.record("the failed commit must stop the write")
        } catch let error as DensoSH7058CANWriter.WriterError {
            #expect(error == .kernelRefused(step: "writing 0x02000 in block 2", code: 0x86, flashChanged: true))
            #expect(error.localizedDescription.contains("Do NOT turn the ignition off"))
        }
        #expect(ecu.rom[0x2000..<0x3000].allSatisfy { $0 == 0xFF })
        let uploaded = ecu.uploadedBlocks.count

        // The kernel is still running: no new upload, and the erased calibration ID does not stop it.
        let result = try writer(ecu, image).write()
        #expect(ecu.uploadedBlocks.count == uploaded)
        #expect(result.changedBlocks == [2, 14, 15])
        #expect(ecu.rom == image.data)
    }

    @Test func stopsOnlyBetweenBlocks() throws {
        let original = Self.makeROM()
        let image = Self.editedROM(from: original)
        let ecu = SimulatedSH7058Flash(rom: original)

        // Asked to stop in the middle of block 14: it finishes block 14 and stops before block 15.
        let stop = { ecu.committed.count >= 3 }
        #expect(throws: DensoSH7058CANWriter.WriterError.cancelled(flashChanged: true)) {
            _ = try writer(ecu, image, isCancelled: stop).write()
        }
        #expect(ecu.erased == [0x2000, 0xC0000])
        #expect(Array(ecu.rom[0xC0000..<0xE0000]) == Array(image.data[0xC0000..<0xE0000]))
        #expect(Array(ecu.rom[0xE0000..<0x100000]) == Array(original[0xE0000..<0x100000]))
    }

    @Test func stoppedBeforeTheFirstEraseSaysNothingChanged() {
        let original = Self.makeROM()
        let ecu = SimulatedSH7058Flash(rom: original)
        let stop = { ecu.flashSwitches.count >= 1 }
        #expect(throws: DensoSH7058CANWriter.WriterError.cancelled(flashChanged: false)) {
            _ = try writer(ecu, Self.editedROM(from: original), isCancelled: stop).write()
        }
        #expect(ecu.erased.isEmpty)
        #expect(DensoSH7058CANWriter.WriterError.cancelled(flashChanged: false).localizedDescription.contains("before anything in the ECU changed"))
    }
}

@Suite("SH7058 CAN writer through the OpenPort (simulated cable)", .serialized)
struct DensoWriterOpenPortTests {
    @Test func writesThroughTheCable() throws {
        let original = DensoWriterTests.makeROM()
        // Two bytes at the same place in two words of block 3 swapped: every sum stays the same, so
        // only block 3 differs and the test stays quick through a pseudo terminal.
        var edited = original
        let other = try #require((0x3207..<0x4000).first { $0 % 4 == 3 && original[$0] != original[0x3103] })
        edited.swapAt(0x3103, other)
        let image = ROMImage(data: edited)
        try DensoSH7058CANWriter.check(image)

        let ecu = SimulatedSH7058Flash(rom: original)
        let cable = try SimulatedOpenPort()
        defer { cable.stop() }
        cable.canECU = { request in try? ecu.request(request, responseCount: 1, timeout: 1) }
        let device = OpenPort(path: cable.devicePath)
        let transport = OpenPortISOTPTransport(device: device)
        try transport.open()
        defer { device.close() }

        let kernel = try #require(DensoSH7058CANReader.bundledKernel())
        let result = try DensoSH7058CANWriter(transport: transport, kernel: kernel, image: image, mode: .write,
                                              allowWhileSwitchedOff: true).write()
        #expect(result.changedBlocks == [3])
        #expect(ecu.rom == edited)
        // Each 512-byte piece went out as one 521-byte message (plus the CAN identifier).
        #expect(cable.commands.contains { $0.hasPrefix("att6 525 ") })
    }
}
