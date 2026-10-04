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

final class TrafficBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

@Suite("OBD-II extended values (Mode 22)", .serialized)
struct ExtendedValueTests {
    /// A newer Subaru: the engine ECU on 7A2 answers intake VVT (AVCS) left and right, and nothing else.
    static let avcsResponder: @Sendable (String, UInt16) -> [UInt8]? = { header, did in
        guard header == "7A2" else { return nil }
        switch did {
        case 0x10B4: return [0x3C]     // 60 - 50 = +10 degrees
        case 0x10B5: return [0x37]     // 55 - 50 = +5 degrees
        default: return nil
        }
    }

    func makeSession(_ configure: (SimulatedELM) -> Void = { _ in }) -> (OBDSession, SimulatedELM) {
        let sim = SimulatedELM(latency: 0.001, searchDelay: 0.005)
        configure(sim)
        return (OBDSession(channel: sim), sim)
    }

    @Test func theBundledCatalogLoadsWithAVCSAndKnock() throws {
        let catalog = ExtendedParameters.catalog
        #expect(catalog.count >= 100, "the OBDb data must be bundled")
        #expect(Set(catalog.map(\.id)).count == catalog.count, "ids must be unique")
        let vvt = try #require(ExtendedParameters.byID["X7A2_10B4"])
        #expect(vvt.name.contains("Intake VVT advance angle right"))
        #expect(vvt.response == "7AA")
        #expect(ExtendedParameters.byID["X7A2_11D0"]?.name.contains("Knock") == true)
        // Every formula must compile, and the definition must carry its units.
        for pid in catalog {
            for conversion in ExtendedParameters.definition(for: pid).conversions { _ = try Expression(conversion.expression) }
        }
    }

    @Test func rawBytesBecomeValues() throws {
        let vvt = try #require(ExtendedParameters.byID["X7A2_10B4"])
        let conversion = ExtendedParameters.definition(for: vvt).conversions[0]
        let expression = try Expression(conversion.expression)
        #expect(expression.evaluate(x: try #require(vvt.raw(from: [0x3C]))) == 10)
        #expect(expression.evaluate(x: try #require(vvt.raw(from: [0x00]))) == -50)
        #expect(vvt.raw(from: []) == nil)
        // A signed 16 bit value: 0xFFFE is -2.
        let signed = ExtendedPID(header: "7E0", response: "7E8", did: "0001", name: "t", bits: 16, signed: true,
                                 mul: 1, div: 1, add: 0, unit: "scalar", min: nil, max: nil, models: [])
        #expect(signed.raw(from: [0xFF, 0xFE]) == -2)
    }

    @Test func discoveryFindsWhatTheCarAnswers() async throws {
        // A realistic car answers a share of the known values, spread over the list, and not the identification DIDs.
        let known = ExtendedParameters.catalog.filter { $0.header == "7A2" }
        let answered = Set(known.enumerated().filter { $0.offset % 4 == 0 }.map(\.element.didValue))
        #expect(answered.count > 10)
        let (session, _) = makeSession {
            $0.extendedResponder = { header, did in header == "7A2" && answered.contains(did) ? [0x10] : nil }
        }
        defer { session.close() }
        _ = try await session.connect()
        let found = try await session.discoverExtended().ids
        #expect(found == Set(known.filter { answered.contains($0.didValue) }.map(\.id)))
        // The adapter must be back to normal OBD-II afterwards.
        let rpm = try await session.run { try $0.readPID(0x0C) }
        #expect(rpm.count == 2)
    }

    @Test func aCarThatDoesNotSpeakMode22IsGivenUpOnQuickly() async throws {
        // Like the 2008 STI: the ECU stays silent for everything.
        let (session, _) = makeSession()
        defer { session.close() }
        _ = try await session.connect()
        let requests = try await session.run { elm -> Int in
            let before = elm.requestCount
            _ = try elm.probeDIDs(header: "7A2", response: "7AA", dids: (0x0000...0x0100).map(UInt16.init))
            return elm.requestCount - before
        }
        #expect(requests < 20, "it should stop after a few silent requests, used \(requests)")
        let discovered = try await session.discoverExtended()
        #expect(discovered.ids.isEmpty)
        #expect(discovered.romID == nil)
    }

    @Test func aFewScatteredAnswersAreNotMissedByTheEarlyExit() async throws {
        // Only two values answer, far apart in the list. The spread order must still reach one of them
        // within the first requests, or the search would wrongly conclude the ECU is silent.
        let known = ExtendedParameters.catalog.filter { $0.header == "7A2" }.sorted { $0.didValue < $1.didValue }
        let two = Set([known[3].didValue, known[known.count - 5].didValue])
        let (session, _) = makeSession {
            $0.extendedResponder = { header, did in header == "7A2" && two.contains(did) ? [0x10] : nil }
        }
        defer { session.close() }
        _ = try await session.connect()
        let found = try await session.discoverExtended().ids
        #expect(found.count == 2, "found \(found.count) of 2")
    }

    @Test func anEcuThatSaysNotSupportedIsKeptTalkingTo() async throws {
        // 7F 22 31 means "I know Mode 22, not this value": more requests are worth it.
        let (session, _) = makeSession {
            $0.extendedNegativeDIDs = [0xF190, 0xF187, 0xF194]
            $0.extendedResponder = Self.avcsResponder
        }
        defer { session.close() }
        _ = try await session.connect()
        let found = try await session.discoverExtended().ids
        #expect(found.contains("X7A2_10B4"))
    }

    /// An ECU with "supported" lists like the 2014 Forester in the Subaru Diesel Crew data: 1000, 1020 ... up to
    /// 12A0, plus values that answer. `listed` is what the lists claim, `answering` what really answers.
    static func listingResponder(listed: Set<UInt16>, answering: Set<UInt16>, romID: [UInt8]? = nil) -> @Sendable (String, UInt16) -> [UInt8]? {
        { header, did in
            guard header == "7A2" else { return nil }
            if did == 0xF182 { return romID }
            if did % 0x20 == 0, (0x1000...0x12A0).contains(did) { return SimulatedELM.supportList(base: did, of: listed, lastList: 0x12A0) }
            return answering.contains(did) ? [0x10] : nil
        }
    }

    @Test func aSupportListSaysWhichIdentifiersFollow() {
        // The first list of the 2014 Forester: FF C0 00 0D means 1001 to 100A, 101D, 101E and "1020 follows".
        let dids: Set<UInt16> = Set((0x1001...0x100A).map { UInt16($0) }).union([0x101D, 0x101E])
        #expect(SimulatedELM.supportList(base: 0x1000, of: dids, lastList: 0x12A0) == [0xFF, 0xC0, 0x00, 0x0D])
        #expect(SimulatedELM.supportList(base: 0x12A0, of: [0x12A1, 0x12A2], lastList: 0x12A0) == [0xC0, 0x00, 0x00, 0x00])
    }

    @Test func theCarsOwnListsShortenTheSearch() async throws {
        let known = ExtendedParameters.catalog.filter { $0.header == "7A2" }
        let inLists = known.filter { (0x1001...0x12C0).contains($0.didValue) }.sorted { $0.didValue < $1.didValue }
        let outside = known.filter { !(0x1001...0x12C0).contains($0.didValue) }
        #expect(inLists.count > 40 && outside.count > 5)
        let supported = Set(inLists.enumerated().filter { $0.offset % 4 == 0 }.map(\.element.didValue))
        // Two values the car has and SubieScope cannot name, and one outside the lists that answers anyway.
        let unnamed: [UInt16] = [0x1003, 0x12B7]
        #expect(Set(known.map(\.didValue)).isDisjoint(with: unnamed))
        let far = try #require(outside.first { $0.didValue > 0x12C0 }).didValue
        let (session, _) = makeSession {
            $0.extendedResponder = Self.listingResponder(listed: supported.union(unnamed), answering: supported.union([far]),
                                                         romID: [0x5A, 0x04, 0x78, 0x42, 0x07])
        }
        defer { session.close() }
        _ = try await session.connect()
        let before = try await session.run { $0.requestCount }
        let found = try await session.discoverExtended()
        let used = try await session.run { $0.requestCount } - before
        #expect(found.ids == Set(known.filter { supported.contains($0.didValue) || $0.didValue == far }.map(\.id)))
        #expect(found.unnamed == ["7A2": unnamed])
        #expect(found.unnamedCount == 2)
        #expect(found.romID == "5A04784207")
        // 22 lists and the listed values instead of every known value: well under the catalog size for both ECUs.
        #expect(used < ExtendedParameters.catalog.count, "used \(used) requests")
        // The adapter must be back to normal OBD-II afterwards.
        let rpm = try await session.run { try $0.readPID(0x0C) }
        #expect(rpm.count == 2)
    }

    @Test func listsThatLeaveOutAnsweringValuesAreNotTrusted() async throws {
        // The lists claim nothing is supported, yet the values answer: the lists mean something else on this
        // car, so every known value is asked as before and nothing is reported as "listed".
        let known = ExtendedParameters.catalog.filter { $0.header == "7A2" }
        let answering = Set(known.map(\.didValue))
        let (session, _) = makeSession { $0.extendedResponder = Self.listingResponder(listed: [], answering: answering) }
        defer { session.close() }
        _ = try await session.connect()
        let found = try await session.discoverExtended()
        #expect(found.ids == Set(known.map(\.id)))
        #expect(found.unnamed.isEmpty)
    }

    @Test func theDemoCarListsItsExtendedValuesAndReportsItsROMID() async throws {
        let (session, sim) = makeSession()
        sim.enableDemoExtended()
        defer { session.close() }
        _ = try await session.connect()
        let found = try await session.discoverExtended()
        #expect(found.ids == ["X7A2_10B4", "X7A2_10B5", "X7A2_10AC", "X7A2_10BE", "X7A2_11D0"])
        #expect(found.romID == DemoECU.identity.romID.map { String(format: "%02X", $0) }.joined())
        #expect(found.unnamed.isEmpty, "the demo car should not ask people for reports")
    }

    @Test func theVINStaysOutOfTheConsoleInMode22Too() async throws {
        let (session, _) = makeSession {
            $0.extendedResponder = { _, did in did == 0xF190 ? Array("JF1GRBKH38G012345".utf8) : nil }
        }
        defer { session.close() }
        _ = try await session.connect()
        let shown = TrafficBox()
        session.elm.traffic = { direction, text in if direction == .received { shown.add(text) } }
        _ = try await session.discoverExtended()
        #expect(shown.all.contains("(VIN reply hidden)"))
        #expect(!shown.all.contains { $0.contains("4A 46 31") || $0.contains("4A4631") }, "the VIN bytes must not be shown")
    }

    @Test func pollingReadsExtendedValuesNextToTheStandardOnes() async throws {
        let (session, _) = makeSession { $0.extendedResponder = Self.avcsResponder }
        defer { session.close() }
        let info = try await session.connect()
        let base = OBDParameters.parameters(supported: info.supportedPIDs)
        let rpm = try #require(base.first { $0.id == "OBD0C" })
        let right = ExtendedParameters.definition(for: try #require(ExtendedParameters.byID["X7A2_10B4"]))
        let silent = ExtendedParameters.definition(for: try #require(ExtendedParameters.byID["X7A2_10B6"]))
        let all = Dictionary((base + [right, silent]).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let box = SampleBox()
        session.startPolling(items: [rpm, right, silent].map { PollItem(parameter: $0, conversion: $0.conversions[0]) },
                             allParameters: all, onSample: { box.add($0) }, onError: { e, _ in box.fail(e) })
        try await Task.sleep(for: .seconds(2))
        session.stopPolling()
        #expect(box.allErrors.isEmpty, "\(box.allErrors)")
        let last = try #require(box.all.last)
        #expect(last.values["OBD0C"] != nil)
        #expect(last.values["X7A2_10B4"] == 10)
        #expect(last.values["X7A2_10B6"] == nil, "a value the car does not answer must not show up")
        #expect(box.all.count > 5, "standard values must keep flowing while extended ones are read")
        // Header restored: a plain request still works.
        let speed = try await session.run { try $0.readPID(0x0D) }
        #expect(speed.count == 1)
    }
}

@Suite("Pressure units")
struct PressureUnitTests {
    func value(_ pid: UInt8, _ data: [UInt8], _ units: String) throws -> Double {
        let p = try #require(OBDParameters.byPID[pid])
        let conversion = try #require(p.conversions.first { $0.units == units })
        return try Expression(conversion.expression).evaluate(x: try #require(p.raw(from: data)))
    }

    @Test func manifoldPressureInBar() throws {
        #expect(try value(0x0B, [200], "kPa") == 200)
        #expect(try value(0x0B, [200], "bar") == 2.0)
        #expect(abs(try value(0x0B, [101], "bar") - 1.01) < 0.0001)
        #expect(abs(try value(0x0B, [200], "psi") - 29.0076) < 0.001)
    }

    @Test func fuelPressureAndBarometerInBar() throws {
        #expect(abs(try value(0x0A, [100], "bar") - 3.0) < 0.0001)          // 300 kPa
        #expect(abs(try value(0x23, [0x00, 0x64], "bar") - 10.0) < 0.0001)  // 1000 kPa (rail)
        #expect(abs(try value(0x33, [101], "bar") - 1.01) < 0.0001)
    }

    @Test func boostGaugeInBar() throws {
        let boost = OBDParameters.boostDefinition
        let bar = try #require(boost.conversions.first { $0.units == "bar relative" })
        // Manifold 200 kPa, outside 101.3 kPa: 0.987 bar of boost. A vacuum reads negative.
        let expression = try Expression(bar.expression)
        let variable = try #require(expression.variables.first)
        #expect(abs(expression.evaluate([variable: 200]) - 0.987) < 0.0001)
        #expect(expression.evaluate([variable: 30]) < 0)
    }

    @Test func extendedPressuresGetBarToo() throws {
        let pressure = try #require(ExtendedParameters.catalog.first { $0.unit == "kilopascal" })
        let units = ExtendedParameters.definition(for: pressure).conversions.map(\.units)
        #expect(units == ["kPa", "bar", "psi"])
    }

    @Test func theChosenUnitWinsOnlyWherePressureApplies() throws {
        let map = OBDParameters.definition(for: try #require(OBDParameters.byPID[0x0B]))
        let temperature = OBDParameters.definition(for: try #require(OBDParameters.byPID[0x05]))
        #expect(PressureUnit.bar.choose(from: map.conversions)?.units == "bar")
        #expect(PressureUnit.psi.choose(from: map.conversions)?.units == "psi")
        #expect(PressureUnit.kilopascal.choose(from: map.conversions)?.units == "kPa")
        #expect(PressureUnit.automatic.choose(from: map.conversions) == nil)
        // A temperature has no pressure unit, so the normal choice still applies.
        #expect(PressureUnit.bar.choose(from: temperature.conversions) == nil)
        // RomRaider names: "psi relative" and "bar" are found by their prefix.
        let romraider = [Conversion(units: "psi relative", expression: "x"), Conversion(units: "kPa relative", expression: "x"),
                         Conversion(units: "bar relative", expression: "x")]
        #expect(PressureUnit.bar.choose(from: romraider)?.units == "bar relative")
    }

    @Test func everyPressureListsBarAfterKilopascal() {
        for pid in OBDParameters.catalog where pid.conversions.contains(where: { $0.units == "kPa" }) {
            #expect(pid.conversions.contains { $0.units == "bar" }, "\(pid.name) should offer bar")
        }
    }
}
