import Foundation

public enum OBDError: Error, LocalizedError, Equatable {
    case timeout(String)
    case adapterNotFound(String)
    case notAnELM327(String)
    case noVehicle(String)
    case noData
    case adapterError(String)
    case unexpectedResponse(String)
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .timeout(let command):
            return "The adapter did not answer (\(command)). Is it plugged into the car with the ignition ON, and in range?"
        case .adapterNotFound(let detail):
            return detail
        case .notAnELM327(let reply):
            return "The device did not answer like an OBD-II (ELM327) adapter: \"\(reply)\"."
        case .noVehicle(let detail):
            return "The adapter is connected, but it can't reach the car: \(detail) Turn the ignition ON (engine off is fine) and try again."
        case .noData:
            return "The car did not answer this request."
        case .adapterError(let detail):
            return "The adapter reported an error: \(detail)."
        case .unexpectedResponse(let detail):
            return "Unexpected response from the adapter: \(detail)"
        case .disconnected:
            return "The adapter was disconnected."
        }
    }
}

/// A line to an ELM327 adapter: Bluetooth LE, or a simulator. Calls block, and are
/// made from one queue only.
public protocol ELMChannel: AnyObject, Sendable {
    /// Sends `command` (the carriage return is added for you) and returns everything
    /// the adapter answered up to, and without, the ">" prompt.
    func exchange(_ command: String, timeout: TimeInterval) throws -> String
    func close()
}

public enum ELMTrafficDirection: Sendable { case sent, received }

/// The OBD-II conversation on top of an ELM327 command interpreter (AT commands and
/// hex requests), as used by cheap Bluetooth and Wi-Fi adapters such as the Vgate iCar Pro.
public final class ELM327 {
    public let channel: ELMChannel
    public var traffic: ((ELMTrafficDirection, String) -> Void)?
    /// Adapter description from ATZ, e.g. "ELM327 v2.3".
    public private(set) var version = ""
    /// Bus protocol the adapter settled on, e.g. "ISO 15765-4 (CAN 11/500)".
    public private(set) var protocolName = ""
    /// Adding the number of expected replies ("010C1") makes the adapter answer sooner.
    public private(set) var usesReplyCount = false
    /// ATAT2: the adapter times out as soon as the car has clearly finished. Fast, but a slow ECU can miss.
    public private(set) var aggressiveTiming = false

    /// Back to the adapter's normal timing after timeouts; slower but forgiving.
    public func relaxTiming() {
        guard aggressiveTiming else { return }
        aggressiveTiming = false
        _ = try? send("ATAT1")
        DiagnosticLog.shared.warning("obd", "Timeouts with fast timing; switched the adapter to normal timing")
    }

    public var requestTimeout: TimeInterval = 2.0

    /// Round trips so far and the time they took, for judging how fast the adapter really is.
    public private(set) var requestCount = 0
    public private(set) var totalRequestTime: TimeInterval = 0
    public var averageRequestMilliseconds: Double { requestCount == 0 ? 0 : totalRequestTime / Double(requestCount) * 1000 }

    public init(channel: ELMChannel) {
        self.channel = channel
    }

    /// Sends one command and returns the reply as trimmed, non-empty lines.
    @discardableResult
    public func send(_ command: String, timeout: TimeInterval? = nil) throws -> [String] {
        traffic?(.sent, command)
        let text: String
        let started = Date()
        do {
            text = try channel.exchange(command, timeout: timeout ?? requestTimeout)
            requestCount += 1
            totalRequestTime += Date().timeIntervalSince(started)
        } catch {
            DiagnosticLog.shared.warning("elm", "\(command): \(error.localizedDescription)")
            throw error
        }
        // The VIN identifies the car, so it stays out of the console and the log.
        let shown = command == "0902" ? "(VIN reply hidden)" : text.replacingOccurrences(of: "\r", with: " ").trimmingCharacters(in: .whitespaces)
        traffic?(.received, shown)
        return Self.lines(of: text, echoOf: command)
    }

    static func lines(of text: String, echoOf command: String) -> [String] {
        text.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != command && $0 != ">" }
    }

    // MARK: Start-up

    /// Resets the adapter and asks it to find the car's protocol. Throws a clear error
    /// when the device is not an ELM327 or the car does not answer.
    public func start() throws {
        // A previous session may have left the adapter in the middle of a request.
        _ = try? channel.exchange("", timeout: 0.5)

        let reset = try send("ATZ", timeout: 4)
        guard let banner = reset.first(where: { $0.uppercased().contains("ELM") || $0.uppercased().contains("OBD") }) else {
            throw OBDError.notAnELM327(reset.joined(separator: " "))
        }
        version = banner
        for setup in ["ATE0", "ATL0", "ATS0", "ATH0", "ATCAF1"] {
            try expectOK(try send(setup))
        }
        // Let the adapter learn how fast the car answers instead of always waiting the long default.
        if let reply = try? send("ATAT2"), reply.contains(where: { $0.uppercased().hasPrefix("OK") }) { aggressiveTiming = true }
        // Automatic protocol search. The first request after it takes a few seconds.
        _ = try? send("ATSP0")
        let probe = try send("0100", timeout: 15)
        let joined = probe.joined(separator: " ").uppercased()
        if joined.contains("UNABLE TO CONNECT") || joined.contains("CAN ERROR") || joined.contains("BUS INIT")
            || (joined.contains("NO DATA") && !joined.contains("41")) {
            throw OBDError.noVehicle(joined.isEmpty ? "no answer." : "the adapter says \"\(joined.capitalized)\".")
        }
        protocolName = (try? send("ATDP").first).flatMap { $0 }?.replacingOccurrences(of: "AUTO, ", with: "") ?? ""
        // Only trust the shorter form if this adapter accepts it (cheap clones sometimes don't).
        if let check = try? send("01001"), Self.payload(from: check, mode: 0x01, pid: 0x00) != nil {
            usesReplyCount = true
        }
    }

    private func expectOK(_ reply: [String]) throws {
        guard reply.contains(where: { $0.uppercased().hasPrefix("OK") }) else {
            throw OBDError.notAnELM327(reply.joined(separator: " "))
        }
    }

    /// Voltage the adapter sees on the car's OBD port (ATRV), e.g. 12.6.
    public func adapterVoltage() -> Double? {
        guard let text = (try? send("ATRV"))?.first else { return nil }
        return Double(text.filter { $0.isNumber || $0 == "." })
    }

    // MARK: Requests

    /// Reads one mode 01 value and returns its data bytes.
    public func readPID(_ pid: UInt8, timeout: TimeInterval? = nil) throws -> [UInt8] {
        let request = String(format: "01%02X", pid) + (usesReplyCount ? "1" : "")
        let lines = try send(request, timeout: timeout)
        if let data = Self.payload(from: lines, mode: 0x01, pid: pid) { return data }
        try Self.throwIfError(lines)
        throw OBDError.unexpectedResponse(lines.joined(separator: " "))
    }

    /// PIDs the car reports as supported (asks 00, 20, 40 ... as long as more follow).
    /// Only the first answer is required: a car that stumbles on a later range still gives what it has.
    public func supportedPIDs() throws -> Set<UInt8> {
        var supported: Set<UInt8> = []
        var base: UInt8 = 0x00
        while true {
            let mask: [UInt8]
            do {
                mask = try readPID(base, timeout: 6)
            } catch {
                if base == 0 { throw error }
                DiagnosticLog.shared.warning("obd", "Support list \(String(format: "%02X", base)) failed (\(error.localizedDescription)); using what we have")
                break
            }
            supported.formUnion(OBDParameters.supportedPIDs(base: base, mask: mask))
            // The last bit of each mask says whether the next range exists.
            guard supported.contains(base &+ 0x20), base < 0xC0 else { break }
            base = base &+ 0x20
        }
        return supported
    }

    /// Asks for each value one by one; for cars that will not give a list of what they support.
    public func probePIDs(_ pids: [UInt8]) -> Set<UInt8> {
        var found: Set<UInt8> = []
        for pid in pids {
            if (try? readPID(pid, timeout: 1.5)) != nil { found.insert(pid) }
        }
        return found
    }

    // MARK: Several values at once

    /// Several PIDs in one request ("010C0D05") cut the number of round trips, which is what
    /// limits the sample rate over Bluetooth. Not every adapter and ECU copes, so after two
    /// failures this falls back to one request per value for the rest of the session.
    public private(set) var batchingWorks = true
    private var batchFailures = 0
    public var maxPIDsPerRequest = 6

    /// Reads the values and returns the data bytes of those that answered. A value that does not
    /// answer is left out; only real communication failures throw.
    public func readPIDs(_ pids: [UInt8]) throws -> [UInt8: [UInt8]] {
        var result: [UInt8: [UInt8]] = [:]
        if batchingWorks && pids.count > 1 && pids.allSatisfy({ OBDParameters.byPID[$0] != nil }) {
            var index = 0
            while index < pids.count && batchingWorks {
                let chunk = Array(pids[index..<min(index + maxPIDsPerRequest, pids.count)])
                index += chunk.count
                let lines = try send("01" + chunk.map { String(format: "%02X", $0) }.joined())
                let answered = Self.parseBatch(lines: lines)
                result.merge(answered) { a, _ in a }
                if answered.isEmpty {
                    // "NO DATA" is a legitimate answer (nothing is available right now); anything else is a batch
                    // problem, and the values are fetched one by one right away so this round is not lost.
                    if !lines.joined().uppercased().filter({ !$0.isWhitespace }).contains("NODATA") {
                        recordBatchFailure(Self.errorText(in: lines) ?? "unreadable answer")
                        try readSingly(chunk, into: &result)
                    }
                } else {
                    batchFailures = 0
                    // A value missing from a partial answer is checked on its own, so an ECU that
                    // cuts a batch short never makes working values look unsupported.
                    for pid in chunk where result[pid] == nil {
                        do {
                            result[pid] = try readPID(pid)
                            recordBatchFailure("the reply was cut short")
                        } catch OBDError.noData {
                            continue
                        }
                    }
                }
            }
            if batchingWorks { return result }
        }
        try readSingly(pids.filter { result[$0] == nil }, into: &result)
        return result
    }

    private func readSingly(_ pids: [UInt8], into result: inout [UInt8: [UInt8]]) throws {
        for pid in pids where result[pid] == nil {
            do {
                result[pid] = try readPID(pid)
            } catch OBDError.noData {
                continue
            }
        }
    }

    private func recordBatchFailure(_ reason: String) {
        batchFailures += 1
        if batchFailures >= 2 && batchingWorks {
            batchingWorks = false
            DiagnosticLog.shared.warning("obd", "Reading several values per request does not work here (\(reason)); reading one at a time")
        }
    }

    /// One reply may carry several values: 41 0C xx xx 0D yy 05 zz. Lengths come from the catalog.
    static func parseBatch(lines: [String]) -> [UInt8: [UInt8]] {
        var result: [UInt8: [UInt8]] = [:]
        for message in messages(from: lines) where message.first == 0x41 {
            var i = 1
            while i < message.count, let known = OBDParameters.byPID[message[i]] {
                let end = i + 1 + known.dataBytes
                guard end <= message.count else { break }
                result[message[i]] = Array(message[(i + 1)..<end])
                i = end
            }
        }
        return result
    }

    // MARK: Raw K-line (experimental: Subaru SSM over a standard ELM327)

    public struct RawKLineSetup: Sendable {
        public var accepted: [String]
        public var rejected: [String]
        public init(accepted: [String], rejected: [String]) { self.accepted = accepted; self.rejected = rejected }
        /// The two commands that decide it: 4800 baud and raw (unformatted) frames.
        public var ok: Bool { accepted.contains("ATIB48") && accepted.contains("ATCAF0") }
    }

    /// Puts the adapter into raw K-line mode at 4800 baud with no OBD framing, which is what
    /// Subaru SSM needs. Genuine ELM327 chips (v1.4+) support this; many clones do not, so the
    /// returned setup lists what the adapter accepted. `ok` is false when SSM is not possible.
    /// `protocolNumber`: 3 = ISO 9141-2, 4 = ISO 14230-4 KWP (5-baud), 5 = ISO 14230-4 KWP (fast).
    /// All three run on the K-line; different Subarus and adapters answer to different ones.
    public func configureRawKLine(protocolNumber: Int = 3) throws -> RawKLineSetup {
        var accepted: [String] = []
        var rejected: [String] = []
        func at(_ cmd: String) {
            let reply = ((try? send(cmd)) ?? []).joined(separator: " ").uppercased()
            (reply.contains("OK") ? { accepted.append(cmd) } : { rejected.append(cmd) })()
        }
        _ = try send("ATZ", timeout: 4)
        for cmd in ["ATE0", "ATL0", "ATS0"] { at(cmd) }
        at("ATSP\(protocolNumber)")    // K-line protocol (ISO 9141-2 or KWP)
        at("ATIB48")   // ISO baud 4800: the Subaru SSM rate, and the capability clones usually lack
        at("ATCAF0")   // automatic formatting off: we supply and receive whole frames, checksum included
        at("ATAL")     // allow long messages: SSM replies exceed the 7-byte ISO 9141 default
        at("ATH1")     // keep the headers in the reply so we see the full SSM frame
        at("ATBI")     // begin the protocol without the normal init handshake (SSM has none)
        _ = try? send("ATSTFF")   // long per-request timeout (~1 s) for slow SSM replies
        _ = try? send("ATAT0")    // do not shorten timing adaptively
        aggressiveTiming = false
        return RawKLineSetup(accepted: accepted, rejected: rejected)
    }

    /// Sends one raw frame (as hex) and returns the bytes that came back. Assumes raw K-line mode.
    public func exchangeRawKLine(_ frame: [UInt8], timeout: TimeInterval = 1.0) throws -> [UInt8] {
        let hex = frame.map { String(format: "%02X", $0) }.joined()
        let lines = try send(hex, timeout: timeout)
        try Self.throwIfError(lines)
        return lines.flatMap { Self.hexBytes(of: $0) }
    }

    public func readVIN() throws -> String? {
        let lines = try send("0902", timeout: 6)
        if lines.joined().uppercased().contains("NODATA") { return nil }
        return Self.parseVIN(lines: lines)
    }

    public struct TroubleCodes: Equatable, Sendable {
        /// Confirmed faults (mode 03): the check engine light is on for these.
        public var confirmed: [String]
        /// Faults seen once, not confirmed yet (mode 07).
        public var pending: [String]
        /// Faults that stay until the car has proven them fixed (mode 0A).
        public var permanent: [String]
    }

    public func readTroubleCodes() throws -> TroubleCodes {
        func codes(_ request: String, response: UInt8) throws -> [String] {
            let lines = try send(request, timeout: 6)
            if lines.joined().uppercased().contains("NODATA") { return [] }
            if let error = Self.errorText(in: lines) { throw OBDError.adapterError(error) }
            return Self.parseTroubleCodes(lines: lines, response: response)
        }
        let confirmed = try codes("03", response: 0x43)
        // Pending codes are a bonus: a car that fumbles them still shows its confirmed codes.
        let pending = (try? codes("07", response: 0x47)) ?? []
        // Many cars answer "NO DATA" here, and older ones don't know the service at all.
        let permanent = (try? codes("0A", response: 0x4A)) ?? []
        return TroubleCodes(confirmed: confirmed, pending: pending, permanent: permanent)
    }

    /// Clears trouble codes and turns the check engine light off (mode 04).
    public func clearTroubleCodes() throws {
        let lines = try send("04", timeout: 6)
        guard lines.contains(where: { Self.hexBytes(of: $0).first == 0x44 }) else {
            try Self.throwIfError(lines)
            throw OBDError.unexpectedResponse(lines.joined(separator: " "))
        }
    }

    /// Check engine light and the number of confirmed codes (PID 01).
    public func monitorStatus() throws -> (milOn: Bool, codeCount: Int) {
        let data = try readPID(0x01)
        guard let a = data.first else { throw OBDError.unexpectedResponse("empty status") }
        return (a & 0x80 != 0, Int(a & 0x7F))
    }

    // MARK: Parsing

    static func hexBytes(of line: String) -> [UInt8] {
        var text = line.filter { !$0.isWhitespace }
        // Multi-frame replies are numbered "0:", "1:" ...
        if text.count >= 2, text[text.index(after: text.startIndex)] == ":" { text = String(text.dropFirst(2)) }
        guard text.count % 2 == 0 else { return [] }
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
            guard next > text.index(after: index), let byte = UInt8(text[index..<next], radix: 16) else { return [] }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// Data bytes of a "41 pid ..." reply. When several control units answer, the first one wins.
    static func payload(from lines: [String], mode: UInt8, pid: UInt8) -> [UInt8]? {
        for line in lines {
            let bytes = hexBytes(of: line)
            if bytes.count >= 2, bytes[0] == mode + 0x40, bytes[1] == pid {
                return Array(bytes.dropFirst(2))
            }
        }
        return nil
    }

    static let errorMarkers = ["UNABLETOCONNECT", "CANERROR", "BUSERROR", "BUSBUSY", "BUFFERFULL", "DATAERROR",
                               "FBERROR", "LVRESET", "STOPPED", "ACTALERT", "?"]

    static func errorText(in lines: [String]) -> String? {
        let text = lines.joined(separator: " ").uppercased()
        let compact = text.filter { !$0.isWhitespace }
        return errorMarkers.first { compact.contains($0) }.map { _ in text.capitalized }
    }

    static func throwIfError(_ lines: [String]) throws {
        let compact = lines.joined().uppercased().filter { !$0.isWhitespace }
        if compact.contains("NODATA") { throw OBDError.noData }
        if let text = errorText(in: lines) { throw OBDError.adapterError(text) }
    }

    /// "P0420" and friends from the two-byte codes in a mode 03/07/0A reply.
    public static func troubleCode(_ high: UInt8, _ low: UInt8) -> String {
        let letter = ["P", "C", "B", "U"][Int(high >> 6)]
        return letter + String(format: "%X%X%02X", (high >> 4) & 0x3, high & 0xF, low)
    }

    /// Splits a reply into messages, one per control unit. A CAN multi-frame message
    /// arrives as a byte count line ("00A") and numbered frames ("0:", "1:" ...) that must be joined.
    static func messages(from lines: [String]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var expected: Int?
        var lengths: [Int?] = []
        for line in lines {
            let compact = line.filter { !$0.isWhitespace }
            if compact.count == 3, compact.allSatisfy(\.isHexDigit) {
                expected = Int(compact, radix: 16)
                continue
            }
            let bytes = hexBytes(of: line)
            guard !bytes.isEmpty else { continue }
            let frame = compact.dropFirst().first == ":" ? compact.first.flatMap { Int(String($0), radix: 16) } : nil
            if let frame, frame > 0, !result.isEmpty {
                result[result.count - 1] += bytes
            } else {
                result.append(bytes)
                lengths.append(expected)
                expected = nil
            }
        }
        // Frames are padded; the byte count line says where the message really ends.
        return result.enumerated().map { index, message in
            if let length = lengths[index], length < message.count { return Array(message.prefix(length)) }
            return message
        }
    }

    static func parseTroubleCodes(lines: [String], response: UInt8) -> [String] {
        // Cars on CAN put a count byte after the service ID; older buses do not.
        // Frames are padded with zeros, so a stray "0000" is not a code.
        var codes: [String] = []
        for var message in messages(from: lines) where message.first == response {
            message.removeFirst()
            if message.count % 2 == 1 { message.removeFirst() }
            var i = 0
            while i + 1 < message.count {
                if message[i] != 0 || message[i + 1] != 0 {
                    let code = troubleCode(message[i], message[i + 1])
                    if !codes.contains(code) { codes.append(code) }
                }
                i += 2
            }
        }
        return codes
    }

    static func parseVIN(lines: [String]) -> String? {
        var data: [UInt8] = []
        for var message in messages(from: lines) {
            if message.starts(with: [0x49, 0x02]) { message.removeFirst(3) }   // service, PID, item counter
            data.append(contentsOf: message)
        }
        let text = String(decoding: data.filter { $0 >= 0x30 && $0 < 0x7F }, as: UTF8.self)
        guard text.count >= 17 else { return nil }
        let vin = String(text.suffix(17))
        return vin.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isUppercase) }) ? vin : nil
    }
}
