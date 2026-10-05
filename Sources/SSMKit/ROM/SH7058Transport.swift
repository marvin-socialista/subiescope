import Foundation

/// Sends one ISO-TP request to the engine ECU (0x7E0) and returns the ECU's reply as the plain
/// response bytes, without the CAN ID. The reader talks only through this, so a real adapter and a
/// simulated ECU can both stand behind it.
public protocol SH7058Transport: AnyObject {
    /// `payload` is the service bytes (e.g. `27 01`), no CAN ID. `responseCount` is how many reply
    /// messages to wait for (almost always 1). Returns the reply's data bytes.
    func request(_ payload: [UInt8], responseCount: Int, timeout: TimeInterval) throws -> [UInt8]
}

public extension SH7058Transport {
    func request(_ payload: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
        try request(payload, responseCount: 1, timeout: timeout)
    }
}

/// An ISO-TP transport built on an STN-based ELM327 adapter (OBDLink EX and friends). It asks the
/// adapter to do the ISO-TP segmentation and reassembly (`STCSEGR`/`STCSEGT`) so a 1 KB page comes
/// back as one message, and sends each request with the STN `STPX` command.
///
/// IMPORTANT: a plain ELM327 clone cannot do this reliably; only an STN chip can. `detectSTN()` must
/// say yes before this is used.
///
/// UNTESTED ON HARDWARE. The exact AT/ST command set and the way an STN adapter formats a long
/// reassembled reply could not be checked against a real OBDLink EX and a real car here. The response
/// parser is deliberately forgiving, and the pure pieces it feeds (framing, seed-key, cipher, read
/// orchestration) are what the unit tests cover. See the project notes before trusting this on a car.
public final class ISOTPELMTransport: SH7058Transport, @unchecked Sendable {
    private let channel: ELMChannel
    /// Called with every line sent to and received from the adapter, for the console.
    public var traffic: ((ELMTrafficDirection, String) -> Void)?

    /// What `STI` reported, once `detectSTN()` has run.
    public private(set) var adapterDescription = ""

    private let tester = "7E0"
    private let ecu = "7E8"
    /// Requests up to this many bytes go inline in `STPX D:`. Longer ones use the `L:` length prompt.
    /// This ECU's biggest request is a 132-byte kernel block, so the inline path is what runs; the
    /// `L:` path is here for completeness.
    public var inlineLimit = 200
    public var defaultTimeout: TimeInterval = 5

    public init(channel: ELMChannel) {
        self.channel = channel
    }

    // MARK: Adapter type

    /// Returns the adapter's STN description (e.g. "STN2230 v5.6.4") if it is an STN chip, else nil.
    /// Reading a ROM is only offered when this is not nil.
    @discardableResult
    public func detectSTN() -> String? {
        for probe in ["STI", "STDI"] {
            if let reply = try? command(probe, timeout: 2), reply.uppercased().contains("STN") {
                adapterDescription = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                return adapterDescription
            }
        }
        return nil
    }

    // MARK: Set-up

    /// Puts the adapter into raw 11-bit 500 kbit/s CAN with ISO-TP handled for us. Safe to call once
    /// before a read; it leaves the adapter in a state the normal OBD code resets on reconnect.
    public func configure(protocolTimeoutMs: Int = 2000) throws {
        // Echo off, line feeds off, spaces off (compact hex), headers off (we filter on 7E8 instead).
        for setup in ["ATE0", "ATL0", "ATS0", "ATH0", "ATAL"] {
            _ = try? command(setup, timeout: 2)
        }
        // Protocol 6: ISO 15765-4, 11-bit IDs, 500 kbit/s.
        _ = try command("ATSP6", timeout: 2)
        _ = try command("ATSH\(tester)", timeout: 2)        // our requests go out on 7E0
        _ = try command("ATCRA\(ecu)", timeout: 2)          // only accept replies from 7E8
        // Let the STN assemble and disassemble ISO-TP for us, with the right flow-control pair.
        _ = try? command("STCFCPA \(tester), \(ecu)", timeout: 2)
        _ = try? command("STCSEGR1", timeout: 2)            // reassemble multi-frame replies
        _ = try? command("STCSEGT1", timeout: 2)            // segment multi-frame requests
        _ = try? command("STPTO \(protocolTimeoutMs)", timeout: 2)
    }

    // MARK: Requests

    public func request(_ payload: [UInt8], responseCount: Int = 1, timeout: TimeInterval) throws -> [UInt8] {
        let hex = payload.map { String(format: "%02X", $0) }.joined()
        let reply: String
        if payload.count <= inlineLimit {
            reply = try command("STPX H:\(tester), D:\(hex), R:\(responseCount)", timeout: timeout)
        } else {
            // Announce the length, wait for the adapter's "DATA>" prompt, then send the payload. The
            // channel returns everything up to ">", so "DATA>" comes back as "DATA".
            let prompt = try command("STPX H:\(tester), L:\(payload.count), R:\(responseCount)", timeout: timeout)
            guard prompt.uppercased().contains("DATA") else {
                throw OBDError.unexpectedResponse("adapter did not ask for the payload (\(prompt))")
            }
            reply = try command(hex, timeout: timeout)
        }
        return try Self.parseResponse(reply)
    }

    // MARK: Parsing

    static let errorMarkers = ["UNABLETOCONNECT", "CANERROR", "BUSERROR", "BUSBUSY", "BUFFERFULL",
                               "DATAERROR", "FBERROR", "RXERROR", "STOPPED", "ERR", "ACTALERT", "?"]

    /// Pulls the response bytes out of whatever the adapter printed. Tolerant on purpose: it drops
    /// blank lines, the `OK`/`DATA`/`SEARCHING` chatter, ELM frame-number prefixes ("0:", "1:" …) and
    /// a leading byte-count line, then reads the rest as hex. Throws on an adapter error or no data.
    static func parseResponse(_ reply: String) throws -> [UInt8] {
        let lines = reply
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let compact = lines.joined().uppercased().filter { !$0.isWhitespace }
        if compact.contains("NODATA") { throw OBDError.noData }
        for marker in errorMarkers where compact.contains(marker) {
            throw OBDError.adapterError(lines.joined(separator: " "))
        }

        var bytes: [UInt8] = []
        for line in lines {
            var text = line.filter { !$0.isWhitespace }
            let upper = text.uppercased()
            if upper == "OK" || upper == "DATA" || upper == "SEARCHING" { continue }
            // ELM multi-frame lines are numbered "0:", "1:" …; drop the prefix.
            if text.count >= 2, text[text.index(after: text.startIndex)] == ":" {
                text = String(text.dropFirst(2))
            } else if text.count == 3, text.allSatisfy(\.isHexDigit) {
                // A lone 3-hex-digit line is the total byte count that precedes numbered frames.
                continue
            }
            bytes.append(contentsOf: Self.hexBytes(text))
        }
        return bytes
    }

    static func hexBytes(_ text: String) -> [UInt8] {
        let clean = text.filter { $0.isHexDigit }
        guard clean.count >= 2 else { return [] }
        var bytes: [UInt8] = []
        var index = clean.startIndex
        while let next = clean.index(index, offsetBy: 2, limitedBy: clean.endIndex), next > index {
            if let byte = UInt8(clean[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        return bytes
    }

    // MARK: Channel

    @discardableResult
    private func command(_ text: String, timeout: TimeInterval) throws -> String {
        traffic?(.sent, text)
        let reply = try channel.exchange(text, timeout: timeout)
        traffic?(.received, reply.replacingOccurrences(of: "\r", with: " ").trimmingCharacters(in: .whitespaces))
        return reply
    }
}
