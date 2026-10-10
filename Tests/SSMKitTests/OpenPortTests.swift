import Foundation
import Testing
@testable import SSMKit

// There is no Tactrix OpenPort 2.0 to test with, so these tests cover the wire format on its own and
// everything else against a simulated cable on a pseudo terminal, with the demo car on its K-line
// and a simulated engine ECU on its CAN channel.

@Suite("OpenPort wire format")
struct OpenPortWireTests {
    @Test func textRepliesCarryTheCommandNumber() throws {
        let done = try #require(OpenPortWire.parse(Array("aro 5\r\nar".utf8)))
        #expect(done.consumed == 7)
        guard case .text(let ok) = done.reply else { Issue.record("not a text reply"); return }
        #expect(ok.verb == "o")
        #expect(ok.sequence == 5)
        #expect(ok.line == "aro 5")

        guard case .text(let failed)? = OpenPortWire.parse(Array("are 9 12\r\n".utf8))?.reply else { Issue.record("not a text reply"); return }
        #expect(failed.verb == "e")
        #expect(failed.numbers == [9, 12])
        #expect(failed.sequence == 12)

        guard case .text(let pin)? = OpenPortWire.parse(Array("arr 16 12150 3\r\n".utf8))?.reply else { Issue.record("not a text reply"); return }
        #expect(pin.numbers == [16, 12150, 3])

        // The version reply is the one that carries no number.
        guard case .text(let version)? = OpenPortWire.parse(Array("ari main code version : 1.17.4877\r\n".utf8))?.reply else {
            Issue.record("not a text reply"); return
        }
        #expect(version.verb == "i")
        #expect(version.sequence == nil)
    }

    @Test func canFramesDropTheirTimestamp() throws {
        // A transmit indication measured on a real cable: channel 6, status 0x10, timestamp, CAN id 7E0.
        let bytes: [UInt8] = [0x61, 0x72, 0x36, 0x09, 0x10, 0x19, 0x50, 0xB8, 0x0C, 0x00, 0x00, 0x07, 0xE0]
        let parsed = try #require(OpenPortWire.parse(bytes))
        #expect(parsed.consumed == bytes.count)
        #expect(parsed.reply == .frame(.init(channel: 6, status: .transmitDone, data: [0x00, 0x00, 0x07, 0xE0])))
    }

    @Test func kLineDataFramesHaveNoTimestamp() throws {
        // Measured on a real cable: the echo of 68 6A F1 01 00 between a start and an end frame.
        let start: [UInt8] = [0x61, 0x72, 0x33, 0x05, 0xA0, 0x22, 0xA6, 0xCB, 0x63]
        let data: [UInt8] = [0x61, 0x72, 0x33, 0x06, 0x20, 0x68, 0x6A, 0xF1, 0x01, 0x00]
        let end: [UInt8] = [0x61, 0x72, 0x33, 0x05, 0x60, 0x22, 0xA7, 0x28, 0xB2]
        #expect(OpenPortWire.parse(start)?.reply == .frame(.init(channel: 3, status: [.start, .loopback], data: [])))
        #expect(OpenPortWire.parse(data)?.reply == .frame(.init(channel: 3, status: .loopback, data: [0x68, 0x6A, 0xF1, 0x01, 0x00])))
        #expect(OpenPortWire.parse(end)?.reply == .frame(.init(channel: 3, status: [.end, .loopback], data: [])))
    }

    @Test func waitsForTheRestAndSkipsNoise() {
        #expect(OpenPortWire.parse([]) == nil)
        #expect(OpenPortWire.parse(Array("ar".utf8)) == nil)
        #expect(OpenPortWire.parse(Array("aro 5\r".utf8)) == nil)                    // line not finished
        #expect(OpenPortWire.parse([0x61, 0x72, 0x36, 0x09, 0x10, 0x19]) == nil)      // frame not finished
        #expect(OpenPortWire.parse([0x00, 0x61, 0x72])?.reply == .junk)
        #expect(OpenPortWire.parse([0x00, 0x61, 0x72])?.consumed == 1)
        // A frame may be as long as its length byte says, up to 255 bytes.
        let long: [UInt8] = [0x61, 0x72, 0x33, 0xFF, 0x00] + [UInt8](repeating: 0x55, count: 254)
        #expect(OpenPortWire.parse(long)?.reply == .frame(.init(channel: 3, status: [], data: [UInt8](repeating: 0x55, count: 254))))
    }
}

@Suite("OpenPort against a simulated cable", .serialized)
struct OpenPortDeviceTests {
    static let defs = try! LoggerDefinitions.bundled()

    @Test func opensAndReadsTheBattery() throws {
        let cable = try SimulatedOpenPort()
        defer { cable.stop() }
        let device = OpenPort(path: cable.devicePath)
        try device.open()
        defer { device.close() }
        #expect(device.firmware == SimulatedOpenPort.firmware)
        #expect(try device.batteryVoltage() == 12.15)
        // Every command after the version request carries a number.
        #expect(cable.commands.contains("ati"))
        #expect(cable.commands.contains { $0.hasPrefix("ata ") })
    }

    @Test func aPortThatIsNotAnOpenPortIsReportedAsSuch() throws {
        let cable = try SimulatedOpenPort()
        defer { cable.stop() }
        cable.answers = false
        let device = OpenPort(path: cable.devicePath)
        #expect(throws: OpenPortError.notAnOpenPort) { try device.open() }
        #expect(!device.isOpen)
    }

    @Test func aLateReplyIsNotTakenForTheNextCommands() throws {
        let cable = try SimulatedOpenPort()
        defer { cable.stop() }
        let device = OpenPort(path: cable.devicePath)
        try device.open()
        defer { device.close() }
        // Nothing acknowledges on CAN: the cable takes its time to say so, longer than this command waits.
        cable.canBusAlive = false
        try device.openChannel(OpenPortWire.Channel.isoTP, flags: 0, baud: 500_000)
        #expect(throws: OpenPortError.noReply(command: "att6 6 64 1000000")) {
            try device.command("att6 6 64 1000000", payload: [0, 0, 7, 0xE0, 0x01, 0x00], timeout: 0.05)
        }
        // The late "are 9" must be dropped, not handed to the battery reading.
        Thread.sleep(forTimeInterval: 0.3)
        #expect(try device.batteryVoltage() == 12.15)
    }

    @Test func ssmOverTheKLine() throws {
        let ecu = try VirtualECU(
            identity: .init(systemID: [0xA2, 0x10, 0x11], romID: [0x1B, 0x14, 0x40, 0x05, 0x05],
                            capabilities: [UInt8](repeating: 0xFF, count: 48)),
            memory: { UInt8(truncatingIfNeeded: $0) })
        defer { ecu.stop() }
        let cable = try SimulatedOpenPort(ecu: ecu)
        defer { cable.stop() }
        let line = OpenPortKLine(device: OpenPort(path: cable.devicePath))
        try line.open(baud: 4800)
        defer { line.close() }
        // The channel is opened the way RomRaider and FastECU do for SSM: ISO 9141, no checksum, 4800 baud.
        #expect(cable.commands.contains { $0.hasPrefix("ato3 512 4800 0 ") })
        #expect(cable.commands.contains { $0.hasPrefix("atf3 1 0 1 ") })

        let transport = SSMTransport(line: line)
        let initReply = try transport.exchange(.initRequest())
        #expect(initReply.data.first == 0xFF)
        #expect(Array(initReply.data[4...8]) == [0x1B, 0x14, 0x40, 0x05, 0x05])
        let values = try transport.exchange(.readAddressesRequest([0x0E, 0x0F, 0x1234]), expectedDataLength: 4)
        #expect(Array(values.payload) == [0x0E, 0x0F, 0x34])
    }

    @Test func sessionPollsAndRunsDiagnostics() async throws {
        for fastPoll in [false, true] {
            let demo = try DemoECU.make(definitions: Self.defs)
            defer { demo.stop() }
            let cable = try SimulatedOpenPort(ecu: demo.ecu)
            defer { cable.stop() }
            let session = SSMSession(portPath: cable.devicePath, openPort: true)
            session.fastPoll = fastPoll
            let identity = try await session.connect()
            #expect(identity.ecuID == "5A04784207")
            #expect(session.openPort?.firmware == SimulatedOpenPort.firmware)

            let set = Self.defs.parameterSet(for: identity)
            let wanted = ["Engine Speed", "Manifold Relative Pressure", "Coolant Temperature", "IAM (4-byte)*"]
            let poll = wanted.compactMap { name in
                set.parameters.first { $0.name == name }.map { PollItem(parameter: $0, conversion: $0.conversions[0]) }
            }
            #expect(poll.count == wanted.count)
            let box = SampleBox()
            let all = Dictionary(set.parameters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            session.startPolling(items: poll, allParameters: all, onSample: { box.add($0) }, onError: { e, _ in box.fail(e) })
            try await Task.sleep(for: .seconds(2))

            // A one-off job in the middle of (fast) polling stops the stream the OpenPort way: no
            // BREAK, twenty zero bytes.
            let codes = try await session.run { client in try TroubleCodeReport.read(with: client, definitions: set.diagnosticCodes) }
            #expect(codes.memorized.map(\.code) == ["P0420"])
            if fastPoll {
                #expect(cable.commands.contains { $0.hasPrefix("att3 20 0 ") })
            }
            try await Task.sleep(for: .seconds(1))
            session.stopPolling()
            session.close()

            #expect(box.allErrors.isEmpty, "fast poll \(fastPoll): \(box.allErrors)")
            #expect(box.all.count > 5, "fast poll \(fastPoll): \(box.all.count) samples")
            let rpm = try #require(box.all.last?.values["P8"])
            #expect(rpm > 600 && rpm < 7500)
        }
    }

    @Test func aCableThatIsNotInTheCarSaysSo() async throws {
        let demo = try DemoECU.make(definitions: Self.defs)
        defer { demo.stop() }
        demo.ecu.isPoweredOn = false
        let cable = try SimulatedOpenPort(ecu: demo.ecu)
        defer { cable.stop() }

        // Plugged into the car, ignition off: the ECU is silent but the battery is there.
        var session = SSMSession(portPath: cable.devicePath, openPort: true)
        session.transport.responseTimeout = 0.2
        await #expect(throws: SSMError.self) { _ = try await session.connect(attempts: 1) }
        session.close()

        // On USB power alone the cable measures no battery.
        cable.batteryMillivolts = 140
        session = SSMSession(portPath: cable.devicePath, openPort: true)
        session.transport.responseTimeout = 0.2
        await #expect(throws: OpenPortError.noCarPower(volts: 0.14)) { _ = try await session.connect(attempts: 1) }
        session.close()
    }
}

@Suite("OpenPort ISO-TP transport (simulated cable)", .serialized)
struct OpenPortISOTPTests {
    func makeTransport(_ cable: SimulatedOpenPort) throws -> (OpenPort, OpenPortISOTPTransport) {
        let device = OpenPort(path: cable.devicePath)
        let transport = OpenPortISOTPTransport(device: device)
        try transport.open()
        return (device, transport)
    }

    @Test func setsUpTheChannelLikeFastECU() throws {
        let cable = try SimulatedOpenPort()
        defer { cable.stop() }
        let (device, _) = try makeTransport(cable)
        defer { device.close() }
        #expect(cable.commands.contains { $0.hasPrefix("ato6 0 500000 0 ") })
        // A flow control filter with padded frames; mask, the ECU's id and ours follow as payload.
        #expect(cable.commands.contains { $0.hasPrefix("atf6 3 64 4 ") })
    }

    @Test func shortAndLongMessagesBothWays() throws {
        let cable = try SimulatedOpenPort()
        defer { cable.stop() }
        // An ECU that answers with the request's first byte + 0x40 and then a reply of the asked length.
        cable.canECU = { request in
            let length = request.count >= 3 ? Int(request[1]) << 8 | Int(request[2]) : 0
            return [request[0] + 0x40] + (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ request.count) }
        }
        let (device, transport) = try makeTransport(cable)
        defer { device.close() }

        func expected(_ length: Int, requestCount: Int) -> [UInt8] {
            [0x61] + (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ requestCount) }
        }
        // One CAN frame each way. The answer is taken as soon as it is in, not when the wait runs out.
        let started = Date()
        #expect(try transport.request([0x21, 0x00, 0x03], timeout: 3) == expected(3, requestCount: 3))
        #expect(Date().timeIntervalSince(started) < 1)
        // Replies that need pieces: one, exactly 69 bytes, just over, and a whole 1 KB page with its header.
        for length in [7, 68, 69, 70, 200, 1029] {
            #expect(try transport.request([0x21, UInt8(length >> 8), UInt8(length & 0xFF)], timeout: 2) == expected(length, requestCount: 3))
        }
        // A request as long as a kernel block (132 bytes).
        let block: [UInt8] = [0x21, 0x00, 0x10] + [UInt8](repeating: 0xAB, count: 129)
        #expect(try transport.request(block, timeout: 2) == expected(16, requestCount: 132))
        // Requests go out padded to full frames, as ECUs demand.
        #expect(cable.commands.contains { $0.hasPrefix("att6 7 64 ") })
    }

    @Test func waitsThroughStillBusyAnswers() throws {
        let cable = try SimulatedOpenPort()
        defer { cable.stop() }
        let (device, transport) = try makeTransport(cable)
        defer { device.close() }
        // "Still busy" (7F xx 78) is not the answer: the transport must keep waiting. The simulated
        // ECU can only send one message per request, so the busy answer here is all there is.
        cable.canECU = { request in [0x7F, request[0], 0x78] }
        transport.busyTimeout = 0.8
        let started = Date()
        #expect(throws: OpenPortError.noAnswer) { _ = try transport.request([0x31, 0x01], timeout: 0.2) }
        #expect(Date().timeIntervalSince(started) > 0.7)   // it extended its wait after the busy answer
    }

    @Test func reportsASilentBusAndASilentECU() throws {
        let cable = try SimulatedOpenPort()
        defer { cable.stop() }
        let (device, transport) = try makeTransport(cable)
        defer { device.close() }
        // The ECU does not know the request: no answer.
        #expect(throws: OpenPortError.noAnswer) { _ = try transport.request([0x10, 0x43], timeout: 0.2) }
        // Ignition off: nothing acknowledges the frame at all.
        cable.canBusAlive = false
        #expect(throws: OpenPortError.busSilent) { _ = try transport.request([0x10, 0x03], timeout: 0.5) }
    }

    /// Passes requests on and keeps the page data that came back, to compare with the ROM.
    final class PageRecorder: SH7058Transport, @unchecked Sendable {
        let inner: SH7058Transport
        var pages: [UInt8] = []
        init(_ inner: SH7058Transport) { self.inner = inner }

        func request(_ payload: [UInt8], responseCount: Int, timeout: TimeInterval) throws -> [UInt8] {
            let reply = try inner.request(payload, responseCount: responseCount, timeout: timeout)
            if payload.count == 11, payload[4] == 0x03 { pages.append(contentsOf: reply.dropFirst(5)) }
            return reply
        }
    }

    @Test func unlocksUploadsTheKernelAndReadsPagesThroughTheCable() throws {
        let rom = DensoReaderEndToEndTests.makeROM()
        let ecu = SimulatedSH7058ECU(rom: rom)
        let cable = try SimulatedOpenPort()
        defer { cable.stop() }
        cable.canECU = { request in try? ecu.request(request, responseCount: 1, timeout: 1) }
        let (device, transport) = try makeTransport(cable)
        defer { device.close() }
        let kernel = try #require(DensoSH7058CANReader.bundledKernel())

        // The whole megabyte is slow through a pseudo terminal, so the read is stopped after 128
        // pages. By then the unlock, the kernel upload in 132-byte requests and 128 KB of pages have
        // gone through the cable's framing, and every byte has to be in place.
        let recorder = PageRecorder(transport)
        let reader = DensoSH7058CANReader(transport: recorder, kernel: kernel,
                                          isCancelled: { recorder.pages.count >= 128 * 1024 })
        #expect(throws: DensoSH7058CANReader.ReaderError.cancelled) { _ = try reader.read() }
        #expect(ecu.kernelRunning)
        let prepared = DensoCAN.prepareKernel(kernel, startAddress: DensoSH7058CANReader.kernelStartAddress)
        #expect(ecu.uploadedBlocks == prepared.encryptedPayload)
        #expect(recorder.pages.count == 128 * 1024)
        #expect(recorder.pages == Array(rom[0..<(128 * 1024)]))
    }
}

@Suite("SSM over CAN through the OpenPort (simulated cable)", .serialized)
struct OpenPortCANTests {
    static let defs = try! LoggerDefinitions.bundled()

    func items(_ names: [String], set: ECUParameterSet) -> [PollItem] {
        names.compactMap { name in
            set.parameters.first { $0.name == name }.map { PollItem(parameter: $0, conversion: $0.conversions[0]) }
        }
    }

    @Test func theVirtualECUAnswersTheSameCommandsOnCAN() throws {
        let ecu = try VirtualECU(
            identity: .init(systemID: [0xA2, 0x10, 0x11], romID: [0x1B, 0x14, 0x40, 0x05, 0x05], capabilities: [0xF3, 0xFE]),
            memory: { UInt8(truncatingIfNeeded: $0) })
        defer { ecu.stop() }
        // AA identifies, as tuneforge's author recorded on a 2007 Forester XT: EA, then what BF gives.
        #expect(ecu.answerOverCAN([0xAA]) == [0xEA, 0xA2, 0x10, 0x11, 0x1B, 0x14, 0x40, 0x05, 0x05, 0xF3, 0xFE])
        #expect(ecu.answerOverCAN([0xA8, 0x00, 0x00, 0x00, 0x0E, 0x00, 0x12, 0x34]) == [0xE8, 0x0E, 0x34])
        // The K-line's own identify command is not known here, and a refusal is spoken.
        #expect(ecu.answerOverCAN([0xBF]) == [0x7F, 0xBF, 0x11])
        ecu.refusedOverCAN = [0xFF7664]
        #expect(ecu.answerOverCAN([0xA8, 0x00, 0x00, 0x00, 0x0E, 0xFF, 0x76, 0x64]) == [0x7F, 0xA8, 0x12])
        ecu.isPoweredOn = false
        #expect(ecu.answerOverCAN([0xAA]) == nil)
    }

    @Test func identifiesAndReadsOnCAN() throws {
        let ecu = try VirtualECU(
            identity: .init(systemID: [0xA2, 0x10, 0x11], romID: [0x1B, 0x14, 0x40, 0x05, 0x05],
                            capabilities: [UInt8](repeating: 0xFF, count: 48)),
            memory: { UInt8(truncatingIfNeeded: $0) })
        defer { ecu.stop() }
        let cable = try SimulatedOpenPort(ecu: ecu)
        defer { cable.stop() }
        cable.canECU = { ecu.answerOverCAN($0) }
        let line = OpenPortCANLine(device: OpenPort(path: cable.devicePath))
        try line.open(baud: 4800)
        defer { line.close() }
        // ISO 15765 at 500 kbit/s with one flow control filter, for the engine: as for reading a ROM.
        #expect(cable.commands.contains { $0.hasPrefix("ato6 0 500000 0 ") })
        #expect(cable.commands.filter { $0.hasPrefix("atf6 3 64 4 ") }.count == 1)
        #expect(!cable.commands.contains { $0.hasPrefix("ato3") })

        // Everything above the line is the K-line's: the same requests, the same replies.
        let transport = SSMTransport(line: line)
        let initReply = try transport.exchange(.initRequest())
        #expect(initReply.data.first == 0xFF)
        #expect(Array(initReply.data[4...8]) == [0x1B, 0x14, 0x40, 0x05, 0x05])
        #expect(initReply.data.count == 57)   // longer than one CAN frame: it came in pieces
        let values = try transport.exchange(.readAddressesRequest([0x0E, 0x0F, 0x1234]), expectedDataLength: 4)
        #expect(Array(values.payload) == [0x0E, 0x0F, 0x34])
        // A full request of 33 addresses is 101 bytes: many CAN frames out, the cable's job.
        let many = (0..<33).map { UInt32($0 * 3) }
        #expect(try SSMClient(transport: transport).read(addresses: many) == many.map { UInt8(truncatingIfNeeded: $0) })
        // "Keep answering" is not passed on: there is no stream on CAN to stop again.
        _ = try transport.exchange(.readAddressesRequest([0x0E], continuous: true), expectedDataLength: 2)
        #expect(try line.readAvailable(timeout: 0.2, idle: 0.05).isEmpty)
    }

    @Test func aRefusalIsToldApartFromSilence() throws {
        let ecu = try VirtualECU(identity: .init(systemID: [0xA2, 0x10, 0x11], romID: [1, 2, 3, 4, 5], capabilities: []),
                                 memory: { UInt8(truncatingIfNeeded: $0) })
        defer { ecu.stop() }
        ecu.refusedOverCAN = [0xFF7664]
        let cable = try SimulatedOpenPort(ecu: ecu)
        defer { cable.stop() }
        cable.canECU = { ecu.answerOverCAN($0) }
        let line = OpenPortCANLine(device: OpenPort(path: cable.devicePath))
        try line.open(baud: 4800)
        defer { line.close() }
        let client = SSMClient(transport: SSMTransport(line: line))
        #expect(throws: SSMError.refused(command: 0xA8, answer: [0x7F, 0xA8, 0x12])) { _ = try client.read(addresses: [0x0E, 0xFF7664]) }
        #expect(try client.read(addresses: [0x0E]) == [0x0E])
    }

    @Test func sessionPollsReadsCodesAndTheFreezeFrame() async throws {
        let demo = try DemoECU.make(definitions: Self.defs)
        defer { demo.stop() }
        let cable = try SimulatedOpenPort(ecu: demo.ecu)
        defer { cable.stop() }
        cable.canECU = { demo.answerOverCAN($0) }
        let session = SSMSession(portPath: cable.devicePath, openPort: true, overCAN: true)
        session.fastPoll = true   // asked for, but there is no such thing on CAN
        let identity = try await session.connect()
        #expect(identity.ecuID == "5A04784207")
        #expect(session.overCAN)

        let set = Self.defs.parameterSet(for: identity)
        let poll = items(["Engine Speed", "Manifold Relative Pressure", "Coolant Temperature", "IAM (4-byte)*"], set: set)
        #expect(poll.count == 4)
        let box = SampleBox()
        let all = Dictionary(set.parameters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        session.startPolling(items: poll, allParameters: all, onSample: { box.add($0) }, onError: { e, _ in box.fail(e) })
        try await Task.sleep(for: .seconds(1))

        let codes = try await session.run { client in try TroubleCodeReport.read(with: client, definitions: set.diagnosticCodes) }
        #expect(codes.memorized.map(\.code) == ["P0420"])
        // The freeze frame goes over the channel SSM already has open.
        let frame = try #require(try await session.readFreezeFrame())
        #expect(frame.code == "P0420")
        #expect(frame.lines().first?.name == "Engine Speed")
        #expect(frame.lines().first?.value == "2350 rpm")
        try await Task.sleep(for: .milliseconds(300))
        session.stopPolling()
        session.close()

        #expect(box.allErrors.isEmpty, "\(box.allErrors)")
        // Far more than the K-line's handful a second.
        #expect(box.all.count > 40, "\(box.all.count) samples")
        let rpm = try #require(box.all.last?.values["P8"])
        #expect(rpm > 600 && rpm < 7500)
        // The K-line was never touched, and the channel was opened once.
        #expect(!cable.commands.contains { $0.hasPrefix("ato3") || $0.hasPrefix("att3") })
        #expect(cable.commands.filter { $0.hasPrefix("ato6") }.count == 1)
    }

    @Test func valuesTheECURefusesAreLeftOutAndNamed() async throws {
        let demo = try DemoECU.make(definitions: Self.defs)
        defer { demo.stop() }
        let cable = try SimulatedOpenPort(ecu: demo.ecu)
        defer { cable.stop() }
        cable.canECU = { demo.answerOverCAN($0) }
        let session = SSMSession(portPath: cable.devicePath, openPort: true, overCAN: true)
        let identity = try await session.connect()
        let set = Self.defs.parameterSet(for: identity)
        let poll = items(["Engine Speed", "IAM (4-byte)*", "Coolant Temperature"], set: set)
        let iam = try #require(poll.first { $0.parameter.name.hasPrefix("IAM") }?.parameter)
        // Like the 2007 Forester XT in tuneforge's notes: values kept in RAM are refused over CAN.
        demo.ecu.refusedOverCAN = Set(iam.addresses)

        let box = SampleBox()
        let named = NameBox()
        session.onRefused = { named.set($0) }
        let all = Dictionary(set.parameters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        session.startPolling(items: poll, allParameters: all, onSample: { box.add($0) }, onError: { e, _ in box.fail(e) })
        try await Task.sleep(for: .seconds(1))
        session.stopPolling()
        session.close()

        #expect(box.allErrors.isEmpty, "\(box.allErrors)")
        // Named once, however many rounds follow.
        #expect(named.value == [iam.id])
        #expect(named.calls == 1)
        let last = try #require(box.all.last)
        #expect(last.values["P8"] != nil)
        #expect(last.values["P2"] != nil)
        #expect(last.values[iam.id] == nil)
        #expect(box.all.count > 20)
    }

    @Test func aCarWithoutCANOnItsPlugSaysSo() async throws {
        let demo = try DemoECU.make(definitions: Self.defs)
        defer { demo.stop() }
        let cable = try SimulatedOpenPort(ecu: demo.ecu)
        defer { cable.stop() }
        cable.canECU = { demo.answerOverCAN($0) }
        cable.canBusAlive = false

        // Nothing acknowledges on CAN: an older car, or the ignition is off.
        var session = SSMSession(portPath: cable.devicePath, openPort: true, overCAN: true)
        await #expect(throws: OpenPortError.noSSMOnCAN) { _ = try await session.connect(attempts: 1) }
        session.close()

        // The same silence with no battery on the plug is a cable that is not in the car.
        cable.batteryMillivolts = 140
        session = SSMSession(portPath: cable.devicePath, openPort: true, overCAN: true)
        await #expect(throws: OpenPortError.noCarPower(volts: 0.14)) { _ = try await session.connect(attempts: 1) }
        session.close()

        // An ECU that is on the bus and says no to SSM is not the same as silence.
        cable.batteryMillivolts = 12_150
        cable.canBusAlive = true
        cable.canECU = { [0x7F, $0.first ?? 0, 0x11] }
        session = SSMSession(portPath: cable.devicePath, openPort: true, overCAN: true)
        await #expect(throws: OpenPortError.ssmRefusedOnCAN) { _ = try await session.connect(attempts: 1) }
        session.close()
        cable.canBusAlive = false

        // On the K-line the same car connects, and has no freeze frame to give over CAN.
        cable.batteryMillivolts = 12_150
        session = SSMSession(portPath: cable.devicePath, openPort: true)
        _ = try await session.connect()
        await #expect(throws: OpenPortError.busSilent) { _ = try await session.readFreezeFrame() }
        // The K-line carries on afterwards.
        #expect(try await session.run { try $0.read(addresses: [0x08]) }.count == 1)
        session.close()
    }

    @Test func theFreezeFrameIsReadNextToSSMOnTheKLine() async throws {
        let demo = try DemoECU.make(definitions: Self.defs)
        defer { demo.stop() }
        let cable = try SimulatedOpenPort(ecu: demo.ecu)
        defer { cable.stop() }
        cable.canECU = { demo.answerOverCAN($0) }
        let session = SSMSession(portPath: cable.devicePath, openPort: true)
        _ = try await session.connect()

        let frame = try #require(try await session.readFreezeFrame())
        #expect(frame.code == "P0420")
        #expect(frame.readings.count == 12)
        // The CAN channel was opened for this and closed again; the K-line stays as it was.
        #expect(cable.commands.contains { $0.hasPrefix("ato6 0 500000 0 ") })
        #expect(cable.commands.contains { $0.hasPrefix("atc6") })
        #expect(try await session.run { try $0.read(addresses: [0x08]) }.count == 1)

        // Clearing the ECU's memory takes the frame with it.
        try await session.run { try ClearMemory.perform(with: $0) }
        #expect(try await session.readFreezeFrame() == nil)
        session.close()
    }

    @Test func aROMReadMayBorrowTheChannel() async throws {
        let demo = try DemoECU.make(definitions: Self.defs)
        defer { demo.stop() }
        let cable = try SimulatedOpenPort(ecu: demo.ecu)
        defer { cable.stop() }
        cable.canECU = { demo.answerOverCAN($0) }
        let session = SSMSession(portPath: cable.devicePath, openPort: true, overCAN: true)
        _ = try await session.connect()
        let device = try #require(session.openPort)
        // What reading a ROM does: open the channel for itself, use it, close it.
        try await session.run { _ in
            let transport = OpenPortISOTPTransport(device: device)
            try transport.open()
            _ = try transport.request([0xAA], timeout: 1)
            transport.close()
        }
        // SSM finds its channel closed and opens it again.
        #expect(try await session.run { try $0.identify() }.ecuID == "5A04784207")
        session.close()
    }
}

final class NameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    private var count = 0
    func set(_ new: [String]) { lock.lock(); names = new; count += 1; lock.unlock() }
    var value: [String] { lock.lock(); defer { lock.unlock() }; return names }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}
