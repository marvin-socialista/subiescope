import Foundation
import Testing
@testable import SSMKit

@Suite("OBD-II adapter links")
struct OBDAdapterLinkTests {
    @Test func aBareIdentifierIsStillBluetooth() {
        // What was saved before USB and Wi-Fi adapters existed.
        let saved = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
        #expect(OBDAdapterLink(id: saved) == .bluetooth(saved))
        #expect(OBDAdapterLink.bluetooth(saved).id == saved)
    }

    @Test func linksSurviveBeingStored() {
        let links: [OBDAdapterLink] = [.serial(path: "/dev/cu.usbserial-A50285BI"), .network(host: "192.168.0.10", port: 35000),
                                       .network(host: "obd.local", port: 23)]
        for link in links { #expect(OBDAdapterLink(id: link.id) == link) }
    }

    @Test func aTypedAddressFallsBackToTheUsualValues() {
        #expect(OBDAdapterLink.network(address: "192.168.0.74:23") == .network(host: "192.168.0.74", port: 23))
        #expect(OBDAdapterLink.network(address: " 10.0.0.5 ") == .network(host: "10.0.0.5", port: 35000))
        #expect(OBDAdapterLink.network(address: "") == .network(host: "192.168.0.10", port: 35000))
        #expect(OBDAdapterLink.network(address: ":2000") == .network(host: "192.168.0.10", port: 2000))
        #expect(OBDAdapterLink.network(address: "192.168.0.10:35000").address == "192.168.0.10:35000")
    }
}

/// The USB path: the simulated adapter behind a pseudo terminal, opened through the normal serial port code.
@Suite("OBD-II over a serial port", .serialized)
struct SerialELMChannelTests {
    func makeServer(_ configure: (SimulatedELM) -> Void = { _ in }) throws -> SimulatedELMServer {
        let sim = SimulatedELM(latency: 0.002, searchDelay: 0.01)
        configure(sim)
        return try SimulatedELMServer.serial(adapter: sim)
    }

    @Test func connectsReadsValuesAndCodes() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let channel = try await SerialELMChannel.open(path: try #require(server.devicePath))
        #expect(channel.baud == 38400)
        let session = OBDSession(channel: channel)
        defer { session.close() }
        let info = try await session.connect()
        #expect(info.adapter.contains("ELM327"))
        #expect(info.vin == server.adapter.car.vin)
        #expect(info.supportedPIDs.isSuperset(of: server.adapter.car.supported))
        let rpm = try await session.run { try $0.readPID(0x0C) }
        #expect(rpm.count == 2)
        let codes = try await session.run { try $0.readTroubleCodes() }
        #expect(codes.confirmed == ["P0420"])
        #expect(codes.pending == ["P0171"])
    }

    @Test func triesTheNextSpeedWhenTheAnswerIsNoise() throws {
        let server = try makeServer()
        defer { server.stop() }
        server.garbledReplies = 2
        let channel = try SerialELMChannel(path: try #require(server.devicePath), probeTimeout: 0.15)
        defer { channel.close() }
        #expect(channel.baud == SerialELMChannel.baudRates[2])
        #expect(try channel.exchange("ATI", timeout: 1).contains("ELM327"))
    }

    @Test func saysSoWhenNothingAnswers() throws {
        // A cable that is not an ELM327, or not plugged into the car.
        let server = try makeServer()
        defer { server.stop() }
        server.garbledReplies = .max
        #expect(throws: OBDError.self) {
            _ = try SerialELMChannel(path: try #require(server.devicePath), probeTimeout: 0.05)
        }
    }

    @Test func aMissingPortIsAnAdapterProblem() {
        do {
            _ = try SerialELMChannel(path: "/dev/cu.no-such-adapter")
            Issue.record("opening a missing port should fail")
        } catch {
            guard case OBDError.adapterNotFound = error else { Issue.record("unexpected error \(error)"); return }
        }
    }

    @Test func timesOutWhenTheAdapterGoesQuietAndStopsAfterClose() throws {
        let server = try makeServer()
        defer { server.stop() }
        let channel = try SerialELMChannel(path: try #require(server.devicePath))
        server.garbledReplies = .max   // no prompt any more
        #expect(throws: OBDError.timeout("010C")) { try channel.exchange("010C", timeout: 0.2) }
        channel.close()
        #expect(throws: OBDError.disconnected) { try channel.exchange("010C", timeout: 0.2) }
    }
}

/// The Wi-Fi path: the simulated adapter behind a TCP port on this Mac.
@Suite("OBD-II over Wi-Fi", .serialized)
struct TCPELMChannelTests {
    func makeServer() throws -> SimulatedELMServer {
        try SimulatedELMServer.network(adapter: SimulatedELM(latency: 0.002, searchDelay: 0.01))
    }

    @Test func connectsReadsValuesAndCodes() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let channel = try await TCPELMChannel.open(host: "127.0.0.1", port: try #require(server.port))
        let session = OBDSession(channel: channel)
        defer { session.close() }
        let info = try await session.connect()
        #expect(info.adapter.contains("ELM327"))
        #expect(info.protocolName.contains("CAN"))
        #expect(info.vin == server.adapter.car.vin)
        let rpm = try await session.run { try $0.readPID(0x0C) }
        #expect(rpm.count == 2)
        let codes = try await session.run { try $0.readTroubleCodes() }
        #expect(codes.confirmed == ["P0420"])
    }

    @Test func pollsLiveValues() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let session = OBDSession(channel: try await TCPELMChannel.open(host: "127.0.0.1", port: try #require(server.port)))
        defer { session.close() }
        let info = try await session.connect()
        let parameters = OBDParameters.parameters(supported: info.supportedPIDs)
        let rpm = try #require(parameters.first { $0.id == "OBD0C" })
        let box = SampleBox()
        session.startPolling(items: [PollItem(parameter: rpm, conversion: rpm.conversions[0])],
                             allParameters: Dictionary(parameters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                             onSample: { box.add($0) }, onError: { e, _ in box.fail(e) })
        try await Task.sleep(for: .seconds(1))
        session.stopPolling()
        #expect(box.allErrors.isEmpty, "\(box.allErrors)")
        #expect(box.all.count > 5)
        #expect(box.all.last?.values["OBD0C"] != nil)
    }

    @Test func aClosedPortIsAnAdapterProblem() async throws {
        // Find a free port, then stop listening on it.
        let server = try makeServer()
        let port = try #require(server.port)
        server.stop()
        do {
            _ = try await TCPELMChannel.open(host: "127.0.0.1", port: port, timeout: 3)
            Issue.record("connecting to a closed port should fail")
        } catch {
            guard case OBDError.adapterNotFound = error else { Issue.record("unexpected error \(error)"); return }
        }
    }

    @Test func noticesTheAdapterGoingAway() async throws {
        let server = try makeServer()
        let channel = try await TCPELMChannel.open(host: "127.0.0.1", port: try #require(server.port))
        defer { channel.close() }
        #expect(try channel.exchange("ATI", timeout: 1).contains("ELM327"))
        server.stop()
        #expect(throws: OBDError.disconnected) {
            // The first request after the adapter left may still be sent; the answer never comes.
            for _ in 0..<20 { _ = try channel.exchange("ATI", timeout: 0.3) }
        }
    }
}
