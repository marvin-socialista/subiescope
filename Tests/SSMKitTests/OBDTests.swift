import Foundation
import Testing
@testable import SSMKit

@Suite("OBD-II parsing")
struct OBDParsingTests {
    @Test func decodesTroubleCodes() {
        #expect(ELM327.troubleCode(0x01, 0x33) == "P0133")
        #expect(ELM327.troubleCode(0x04, 0x20) == "P0420")
        #expect(ELM327.troubleCode(0x21, 0x71) == "P2171")
        #expect(ELM327.troubleCode(0x41, 0x01) == "C0101")
        #expect(ELM327.troubleCode(0x81, 0x23) == "B0123")
        #expect(ELM327.troubleCode(0xC1, 0x23) == "U0123")
    }

    @Test func decodesSupportedPIDMasks() {
        // BE1FA813 is the classic answer: 01, 03..07, 0C..10, 11, 13, 15, 1C, 1F and 20 follows.
        let pids = OBDParameters.supportedPIDs(base: 0x00, mask: [0xBE, 0x1F, 0xA8, 0x13])
        #expect(pids.isSuperset(of: [0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x13, 0x15, 0x1C, 0x1F, 0x20]))
        #expect(!pids.contains(0x02) && !pids.contains(0x08) && !pids.contains(0x09) && !pids.contains(0x12))
        #expect(OBDParameters.supportedPIDs(base: 0x20, mask: [0x80, 0, 0, 0x01]) == [0x21, 0x40])
    }

    @Test func troubleCodesOnCAN() {
        // Count byte after the service, padded with zero pairs.
        #expect(ELM327.parseTroubleCodes(lines: ["4302 0133 0420"], response: 0x43) == ["P0133", "P0420"])
        #expect(ELM327.parseTroubleCodes(lines: ["43 01 04 20 00 00"], response: 0x43) == ["P0420"])
        #expect(ELM327.parseTroubleCodes(lines: ["430000000000"], response: 0x43).isEmpty)
        #expect(ELM327.parseTroubleCodes(lines: ["4300"], response: 0x43).isEmpty)
    }

    @Test func troubleCodesOnOlderBuses() {
        // No count byte; three codes per line; two control units may answer.
        let lines = ["43 01 33 04 20 00 00", "43 01 71 00 00 00 00"]
        #expect(ELM327.parseTroubleCodes(lines: lines, response: 0x43) == ["P0133", "P0420", "P0171"])
    }

    @Test func multiFrameTroubleCodesAreJoinedBeforePairing() {
        // 43 03 + three codes = 8 bytes: the second frame starts in the middle of nothing
        // and the last code is split over the frame boundary if joined wrongly.
        let lines = ["008", "0: 43 03 01 33 04 20", "1: 01 71 00 00 00 00 00"]
        #expect(ELM327.parseTroubleCodes(lines: lines, response: 0x43) == ["P0133", "P0420", "P0171"])
    }

    @Test func readsVIN() {
        let vin = "JF1VA1A6XG9800001"
        let bytes = [0x49, 0x02, 0x01] + Array(vin.utf8)
        var lines = ["014"]
        lines.append("0: " + bytes[0..<6].map { String(format: "%02X", $0) }.joined(separator: " "))
        var index = 6
        var n = 1
        while index < bytes.count {
            var slice = Array(bytes[index..<min(index + 7, bytes.count)])
            slice += [UInt8](repeating: 0, count: 7 - slice.count)
            lines.append("\(n): " + slice.map { String(format: "%02X", $0) }.joined(separator: " "))
            index += 7
            n += 1
        }
        #expect(ELM327.parseVIN(lines: lines) == vin)

        // Older buses: one line per four characters, each with its own header, the first one padded.
        let old = ["49 02 01 00 00 00 4A", "49 02 02 46 31 56 41", "49 02 03 31 41 36 58",
                   "49 02 04 47 39 38 30", "49 02 05 30 30 30 31"]
        #expect(ELM327.parseVIN(lines: old) == vin)
        #expect(ELM327.parseVIN(lines: ["NO DATA"]) == nil)
    }

    @Test func catalogIsConsistent() throws {
        #expect(Set(OBDParameters.catalog.map(\.pid)).count == OBDParameters.catalog.count)
        for pid in OBDParameters.catalog {
            #expect(!pid.conversions.isEmpty, "\(pid.name)")
            for conversion in pid.conversions { _ = try Expression(conversion.expression) }
            #expect(pid.valueBytes <= pid.dataBytes)
        }
        // Spot checks against the J1979 formulas.
        func value(_ pid: UInt8, _ data: [UInt8], _ units: String? = nil) -> Double {
            let p = OBDParameters.byPID[pid]!
            let conversion = units.flatMap { u in p.conversions.first { $0.units == u } } ?? p.conversions[0]
            return try! Expression(conversion.expression).evaluate(x: p.raw(from: data)!)
        }
        #expect(value(0x0C, [0x1A, 0xF8]) == 1726)
        #expect(value(0x05, [0x7B]) == 83)
        #expect(value(0x05, [0x7B], "F") == 181.4)
        #expect(abs(value(0x06, [0x80])) < 0.001)
        #expect(abs(value(0x07, [0x90]) - 12.5) < 0.001)
        #expect(value(0x0E, [0x80]) == 0)
        #expect(abs(value(0x24, [0x80, 0x00, 0x00, 0x00]) - 1.0) < 0.001)
        #expect(value(0x42, [0x38, 0x18]) == 14.36)
    }
}

@Suite("OBD-II session against the simulated adapter", .serialized)
struct OBDSessionTests {
    func makeSession(_ configure: (SimulatedELM) -> Void = { _ in }) -> (OBDSession, SimulatedELM) {
        let sim = SimulatedELM(latency: 0.002, searchDelay: 0.01)
        configure(sim)
        return (OBDSession(channel: sim), sim)
    }

    @Test func connectsAndIdentifiesTheCar() async throws {
        let (session, sim) = makeSession()
        defer { session.close() }
        let info = try await session.connect()
        #expect(info.adapter.contains("ELM327"))
        #expect(info.protocolName.contains("CAN"))
        #expect(info.vin == sim.car.vin)
        #expect(info.supportedPIDs.isSuperset(of: sim.car.supported))
        #expect(info.voltage == 12.6)
        #expect(session.elm.usesReplyCount)
    }

    @Test func workWithAdaptersThatRejectReplyCounts() async throws {
        let (session, _) = makeSession { $0.acceptsReplyCount = false }
        defer { session.close() }
        _ = try await session.connect()
        #expect(!session.elm.usesReplyCount)
        let rpm = try await session.run { try $0.readPID(0x0C) }
        #expect(rpm.count == 2)
    }

    @Test func pollsParameters() async throws {
        let (session, _) = makeSession()
        defer { session.close() }
        let info = try await session.connect()
        let parameters = OBDParameters.parameters(supported: info.supportedPIDs)
        let names = ["Engine Speed", "Coolant Temperature", "Vehicle Speed", "Manifold Relative Pressure", "A/F Sensor #1"]
        let chosen = names.compactMap { name in parameters.first { $0.name == name } }
        #expect(chosen.count == names.count)
        let box = SampleBox()
        let all = Dictionary(parameters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        session.startPolling(items: chosen.map { PollItem(parameter: $0, conversion: $0.conversions[0]) }, allParameters: all,
                             onSample: { box.add($0) }, onError: { e, _ in box.fail(e) })
        try await Task.sleep(for: .seconds(1.5))
        session.stopPolling()
        let samples = box.all
        #expect(box.allErrors.isEmpty, "\(box.allErrors)")
        #expect(samples.count > 5)
        let last = try #require(samples.last)
        let rpm = try #require(last.values["OBD0C"])
        #expect(rpm > 500 && rpm < 8000)
        #expect((60...110).contains(last.values["OBD05"] ?? 0))
        // Boost is manifold pressure minus 101.3 kPa, and reads the pressure PID by itself.
        let boost = try #require(last.values[OBDParameters.boostID])
        #expect(boost > -90 && boost < 200)
        #expect((0.5...2.0).contains(last.values["OBD24"] ?? 0))
    }

    @Test func readsAndClearsTroubleCodes() async throws {
        let (session, sim) = makeSession()
        defer { session.close() }
        _ = try await session.connect()
        let codes = try await session.run { try $0.readTroubleCodes() }
        #expect(codes.confirmed == ["P0420"])
        #expect(codes.pending == ["P0171"])
        #expect(codes.permanent.isEmpty)

        var car = sim.car
        car.confirmedCodes = ["P0133", "P0420", "P0301", "P2101"]
        sim.car = car
        let many = try await session.run { try $0.readTroubleCodes() }
        #expect(many.confirmed == ["P0133", "P0420", "P0301", "P2101"])   // multi-frame

        try await session.run { try $0.clearTroubleCodes() }
        let after = try await session.run { try $0.readTroubleCodes() }
        #expect(after.confirmed.isEmpty && after.pending.isEmpty)
    }

    @Test func olderBusesWithoutCAN() async throws {
        let (session, _) = makeSession { sim in
            var car = sim.car
            car.usesCAN = false
            car.confirmedCodes = ["P0133", "P0420", "P0301", "P2101"]
            sim.car = car
        }
        defer { session.close() }
        let info = try await session.connect()
        #expect(info.protocolName.contains("9141"))
        let codes = try await session.run { try $0.readTroubleCodes() }
        #expect(codes.confirmed == ["P0133", "P0420", "P0301", "P2101"])
    }

    @Test func explainsWhenTheCarDoesNotAnswer() async throws {
        let (session, _) = makeSession { $0.ignitionOn = false }
        defer { session.close() }
        do {
            _ = try await session.connect()
            Issue.record("connect should have failed with the ignition off")
        } catch let error as OBDError {
            guard case .noVehicle = error else { Issue.record("wrong error: \(error)"); return }
            #expect(error.localizedDescription.contains("ignition"))
        }
    }

    @Test func rejectsDevicesThatAreNotAnELM327() async throws {
        final class Silent: ELMChannel, @unchecked Sendable {
            func exchange(_ command: String, timeout: TimeInterval) throws -> String { "WHAT?\r" }
            func close() {}
        }
        let session = OBDSession(channel: Silent())
        do {
            _ = try await session.connect()
            Issue.record("connect should have failed")
        } catch let error as OBDError {
            guard case .notAnELM327 = error else { Issue.record("wrong error: \(error)"); return }
        }
    }

    @Test func reportsALostAdapterAsFatal() async throws {
        let (session, sim) = makeSession()
        let info = try await session.connect()
        let parameters = OBDParameters.parameters(supported: info.supportedPIDs)
        let rpm = try #require(parameters.first { $0.id == "OBD0C" })
        let fatal = FatalBox()
        session.startPolling(items: [PollItem(parameter: rpm, conversion: rpm.conversions[0])],
                             allParameters: [:], onSample: { _ in },
                             onError: { _, isFatal in if isFatal { fatal.set() } })
        try await Task.sleep(for: .milliseconds(200))
        sim.close()
        try await Task.sleep(for: .seconds(1.0))
        #expect(fatal.value)
        session.close()
    }
}

@Suite("OBD-II resilience", .serialized)
struct OBDResilienceTests {
    func makeSession(_ configure: (SimulatedELM) -> Void = { _ in }) -> (OBDSession, SimulatedELM) {
        let sim = SimulatedELM(latency: 0.002, searchDelay: 0.01)
        configure(sim)
        return (OBDSession(channel: sim), sim)
    }

    @Test func readsManyValuesInOneRequest() async throws {
        let (session, _) = makeSession()
        defer { session.close() }
        _ = try await session.connect()
        let (values, requests) = try await session.run { elm -> ([UInt8: [UInt8]], Int) in
            let before = elm.requestCount
            let values = try elm.readPIDs([0x0C, 0x0D, 0x05, 0x11, 0x0B, 0x0F])
            return (values, elm.requestCount - before)
        }
        #expect(Set(values.keys) == [0x0C, 0x0D, 0x05, 0x11, 0x0B, 0x0F])
        #expect(requests == 1)
        #expect(values[0x0C]?.count == 2)   // rpm is two bytes
    }

    @Test func splitsLongListsIntoSeveralRequests() async throws {
        let (session, _) = makeSession()
        defer { session.close() }
        _ = try await session.connect()
        let pids: [UInt8] = [0x0C, 0x0D, 0x05, 0x11, 0x0B, 0x0F, 0x10, 0x04, 0x06, 0x07, 0x0E, 0x42, 0x43]
        let (values, requests) = try await session.run { elm -> ([UInt8: [UInt8]], Int) in
            let before = elm.requestCount
            return (try elm.readPIDs(pids), elm.requestCount - before)
        }
        #expect(Set(values.keys) == Set(pids))
        #expect(requests == 3)   // 6 + 6 + 1
    }

    @Test func fallsBackToOneAtATimeWhenTheAdapterRejectsBatches() async throws {
        let (session, _) = makeSession { $0.batchBehavior = .rejected }
        defer { session.close() }
        _ = try await session.connect()
        let pids: [UInt8] = [0x0C, 0x0D, 0x05, 0x11]
        for _ in 0..<3 {
            let values = try await session.run { try $0.readPIDs(pids) }
            #expect(Set(values.keys) == Set(pids), "every value must still arrive")
        }
        let works = try await session.run { $0.batchingWorks }
        #expect(!works)
    }

    @Test func aReplyCutShortDoesNotMakeWorkingValuesLookMissing() async throws {
        // An ECU that answers only the first value of a batch: the rest must be fetched individually.
        let (session, _) = makeSession { $0.batchBehavior = .firstOnly }
        defer { session.close() }
        _ = try await session.connect()
        let pids: [UInt8] = [0x0C, 0x0D, 0x05, 0x11]
        for _ in 0..<3 {
            let values = try await session.run { try $0.readPIDs(pids) }
            #expect(Set(values.keys) == Set(pids))
        }
        let works = try await session.run { $0.batchingWorks }
        #expect(!works, "after repeated cut-short replies it should stop batching")
    }

    @Test func pollingSkipsAValueThatStaysSilentAndKeepsTheRest() async throws {
        let (session, _) = makeSession { $0.silentPIDs = [0x5C] }   // oil temperature is listed but never answers
        defer { session.close() }
        let info = try await session.connect()
        #expect(info.supportedPIDs.contains(0x5C))
        let parameters = OBDParameters.parameters(supported: info.supportedPIDs)
        let chosen = ["Engine Speed", "Vehicle Speed", "Engine Oil Temperature"].compactMap { name in parameters.first { $0.name == name } }
        #expect(chosen.count == 3)
        let box = SampleBox()
        let skipped = SkipBox()
        session.onSkip = { skipped.set($0) }
        session.startPolling(items: chosen.map { PollItem(parameter: $0, conversion: $0.conversions[0]) },
                             allParameters: Dictionary(parameters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                             onSample: { box.add($0) }, onError: { e, fatal in box.fail(e); if fatal { skipped.fatal() } })
        try await Task.sleep(for: .seconds(1.5))
        session.stopPolling()
        #expect(skipped.pids.contains(0x5C))
        #expect(!skipped.wasFatal)
        let last = try #require(box.all.last)
        #expect(last.values["OBD0C"] != nil)
        #expect(last.values["OBD5C"] == nil)
        #expect(box.all.count > 5)
    }

    @Test func aFailedSecondSupportListStillConnects() async throws {
        let (session, sim) = makeSession { $0.failsSecondSupportRange = true }
        defer { session.close() }
        let info = try await session.connect()
        #expect(info.supportedPIDs.contains(0x0C) && info.supportedPIDs.contains(0x05))
        #expect(!info.supportedPIDs.contains(0x42), "values beyond the failed list are unknown")
        _ = sim
    }
}

final class SkipBox: @unchecked Sendable {
    private let lock = NSLock()
    private var set_: Set<UInt8> = []
    private var fatal_ = false
    func set(_ v: Set<UInt8>) { lock.lock(); set_ = v; lock.unlock() }
    func fatal() { lock.lock(); fatal_ = true; lock.unlock() }
    var pids: Set<UInt8> { lock.lock(); defer { lock.unlock() }; return set_ }
    var wasFatal: Bool { lock.lock(); defer { lock.unlock() }; return fatal_ }
}

final class FatalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

@Suite("Subaru SSM over an ELM327 adapter", .serialized)
struct SSMOverELMTests {
    /// A round of the raw exchange runs on whatever thread `run` uses; keep it simple and synchronous.
    func makeELM(_ configure: (SimulatedELM) -> Void = { _ in }) -> (ELM327, SimulatedELM) {
        let sim = SimulatedELM(latency: 0.001, searchDelay: 0.005)
        sim.ssmResponder = SimulatedELM.demoSSMResponder()
        configure(sim)
        return (ELM327(channel: sim), sim)
    }

    @Test func aCapableAdapterReadsTheEcuIdentityOverSSM() throws {
        let (elm, _) = makeELM()
        let probe = SSMOverELM(elm: elm).probe()
        #expect(probe.setup.ok)
        #expect(probe.worked)
        #expect(probe.identity?.ecuID == DemoECU.identity.ecuID)
        #expect(probe.reason.contains("Success"))
    }

    @Test func aCloneChipIsReportedAsUnableWithoutBlamingTheCar() throws {
        let (elm, _) = makeELM { $0.supportsRawKLine = false }
        let probe = SSMOverELM(elm: elm).probe()
        #expect(!probe.setup.ok)
        #expect(!probe.worked)
        #expect(probe.setup.rejected.contains("ATIB48"))
        #expect(probe.reason.contains("can't do Subaru SSM"))
        #expect(!probe.reason.lowercased().contains("ignition"))   // the adapter is at fault, not the car
    }

    @Test func aCapableAdapterOnACarThatIsSilentBlamesTheCarNotTheAdapter() throws {
        let (elm, _) = makeELM { $0.ssmResponder = nil }   // adapter fine, car does not speak SSM / ignition off
        let probe = SSMOverELM(elm: elm).probe()
        #expect(probe.setup.ok)
        #expect(!probe.worked)
        #expect(probe.reason.contains("did not answer"))
    }

    @Test func fullExchangeReadsAddressesOverSSM() throws {
        let (elm, _) = makeELM()
        let ssm = SSMOverELM(elm: elm)
        _ = ssm.probe()
        let reply = try ssm.exchange(SSMPacket.readAddressesRequest([0x000008, 0x00000A]))
        #expect(reply.command == SSMCommand.response(to: SSMCommand.readAddresses))
        #expect(reply.payload.count == 2)
    }

    @Test func ourOwnEchoedRequestIsNotMistakenForTheReply() throws {
        // A single-wire K-line adapter may echo our request first; the parser must skip it.
        let request = try SSMPacket.initRequest().encoded()
        let reply = try SSMPacket(destination: SSMDevice.tester.rawValue, source: SSMDevice.engine.rawValue,
                                  data: [0xFF] + DemoECU.identity.initData).encoded()
        let stream = request + reply   // echo, then the real answer
        let frame = SSMOverELM.firstSSMFrame(in: stream, from: SSMDevice.engine.rawValue)
        #expect(frame == reply)
    }
}
