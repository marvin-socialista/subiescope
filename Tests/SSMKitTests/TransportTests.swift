import Foundation
import Testing
@testable import SSMKit

@Suite("Packet and transport")
struct TransportTests {
    @Test func checksumAndRoundTrip() throws {
        let packet = SSMPacket.initRequest()
        let bytes = try packet.encoded()
        #expect(bytes == [0x80, 0x10, 0xF0, 0x01, 0xBF, 0x40])
        #expect(try SSMPacket.decode(bytes) == packet)
    }

    @Test func readAddressesEncoding() throws {
        let bytes = try SSMPacket.readAddressesRequest([0x00000E, 0x00000F]).encoded()
        #expect(bytes == [0x80, 0x10, 0xF0, 0x08, 0xA8, 0x00, 0x00, 0x00, 0x0E, 0x00, 0x00, 0x0F, 0x4D])
    }

    @Test func frameExtractionSkipsGarbageAndEcho() throws {
        let echo = try SSMPacket.initRequest().encoded()
        let reply = try SSMPacket(destination: 0xF0, source: 0x10, data: [0xFF, 1, 2, 3]).encoded()
        var buffer: [UInt8] = [0x00, 0x42] + echo + reply
        var frames: [SSMPacket] = []
        while let (frame, consumed) = SSMTransport.extractFrame(from: buffer) {
            buffer.removeFirst(consumed)
            if let frame { frames.append(frame) }
        }
        #expect(frames.count == 2)
        #expect(frames.last?.data == [0xFF, 1, 2, 3])
    }

    @Test func exchangeOverPseudoTerminalWithEcho() throws {
        let ecu = try VirtualECU(
            identity: .init(systemID: [0xA2, 0x10, 0x11], romID: [0x1B, 0x14, 0x40, 0x05, 0x05],
                            capabilities: [UInt8](repeating: 0xFF, count: 48)),
            memory: { UInt8(truncatingIfNeeded: $0) }
        )
        defer { ecu.stop() }
        let port = SerialPort(path: ecu.devicePath)
        try port.open(baud: 4800)
        defer { port.close() }
        let transport = SSMTransport(port: port)
        var sawEcho = false
        transport.traffic = { dir, _ in if dir == .echo { sawEcho = true } }

        let initReply = try transport.exchange(.initRequest())
        #expect(initReply.data.first == 0xFF)
        #expect(Array(initReply.data[4...8]) == [0x1B, 0x14, 0x40, 0x05, 0x05])
        #expect(sawEcho)

        let values = try transport.exchange(.readAddressesRequest([0x0E, 0x0F, 0x1234]), expectedDataLength: 4)
        #expect(Array(values.payload) == [0x0E, 0x0F, 0x34])
    }

    // A second program on one cable (the app and the command line tool, say) is told why it cannot
    // open the port. Two opens inside one program do not show it, so only the wording is checked here.
    @Test func aPortInUseIsSaidInPlainWords() {
        let text = SerialError.inUse(path: "/dev/cu.usbserial-1").localizedDescription
        #expect(text.contains("Another program is using this port"))
        #expect(text.contains("/dev/cu.usbserial-1"))
        #expect(text.contains("subiescope-cli"))
    }

    @Test func timeoutWhenIgnitionOff() throws {
        let ecu = try VirtualECU(identity: .init(systemID: [0, 0, 0], romID: [0, 0, 0, 0, 0], capabilities: []),
                                 memory: { _ in 0 })
        ecu.isPoweredOn = false
        defer { ecu.stop() }
        let port = SerialPort(path: ecu.devicePath)
        try port.open(baud: 4800)
        let transport = SSMTransport(port: port)
        transport.responseTimeout = 0.2
        #expect(throws: SSMError.timeout(command: 0xBF, receivedBytes: 6, sawEcho: true)) {
            try transport.exchange(.initRequest())
        }
    }
}
