import Foundation

/// Runs Subaru SSM over a standard ELM327 adapter in raw K-line mode.
///
/// Experimental. SSM is not OBD-II: it is Subaru's own protocol on the same K-line wire, at
/// 4800 baud with its own frame format. An ELM327 can carry it only if the chip honours ATIB48
/// (4800 baud) and ATCAF0 (raw, unformatted frames). Genuine ELM327 v1.4+ chips do; many cheap
/// clones do not. `probe` finds out which kind you have, without any firmware change to the adapter.
public final class SSMOverELM {
    public let elm: ELM327

    public init(elm: ELM327) {
        self.elm = elm
    }

    public struct ProbeResult: Sendable {
        public var setup: ELM327.RawKLineSetup
        public var identity: ECUIdentity?
        /// What actually came back, for the console and diagnostic report.
        public var rawReply: [UInt8]
        /// A plain-language explanation to show the user.
        public var reason: String
        public var worked: Bool { identity != nil }
        public init(setup: ELM327.RawKLineSetup, identity: ECUIdentity?, rawReply: [UInt8], reason: String) {
            self.setup = setup; self.identity = identity; self.rawReply = rawReply; self.reason = reason
        }
    }

    /// Sets the adapter to raw mode and asks the ECU to identify itself. Never throws: the result
    /// says whether it worked and, if not, whether the adapter or the car is the reason.
    /// K-line protocols to try, in order: ISO 9141-2, then KWP (5-baud), then KWP (fast).
    static let kLineProtocols: [(number: Int, name: String)] = [(3, "ISO 9141-2"), (4, "KWP 5-baud"), (5, "KWP fast")]

    public func probe(device: SSMDevice = .engine) -> ProbeResult {
        var firstSetup: ELM327.RawKLineSetup?
        var lastReply: [UInt8] = []
        let request = (try? SSMPacket.initRequest(to: device).encoded()) ?? []

        for proto in Self.kLineProtocols {
            let setup: ELM327.RawKLineSetup
            do {
                setup = try elm.configureRawKLine(protocolNumber: proto.number)
            } catch {
                DiagnosticLog.shared.warning("ssm-elm", "\(proto.name): setup failed: \(error.localizedDescription)")
                continue
            }
            if firstSetup == nil { firstSetup = setup }
            DiagnosticLog.shared.info("ssm-elm", "\(proto.name): accepted \(setup.accepted.joined(separator: " ")), rejected \(setup.rejected.joined(separator: " "))")
            guard setup.ok else { continue }   // clone chip: no point trying this protocol

            // The first SSM request after the bus wakes is often lost, so try a few times.
            for attempt in 1...4 {
                let reply = (try? elm.exchangeRawKLine(request, timeout: 2.0)) ?? []
                DiagnosticLog.shared.info("ssm-elm", "\(proto.name) init attempt \(attempt): \(reply.isEmpty ? "no answer" : reply.hexString)")
                if !reply.isEmpty { lastReply = reply }
                if let frame = Self.firstSSMFrame(in: reply, from: device.rawValue),
                   let identity = try? ECUIdentity.parse(initReply: SSMPacket.decode(frame)) {
                    return ProbeResult(setup: setup, identity: identity, rawReply: reply,
                                       reason: "Success on \(proto.name). The ECU answered over SSM (ECU ID \(identity.ecuID)). This adapter can read your Subaru with SSM, wirelessly. Full SSM logging over Bluetooth can be built on this.")
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }

        guard let setup = firstSetup else {
            return ProbeResult(setup: .init(accepted: [], rejected: ["ATZ"]), identity: nil, rawReply: [],
                               reason: "The adapter did not respond to the setup commands.")
        }
        guard setup.ok else {
            let missing = ["ATIB48": "4800 baud", "ATCAF0": "raw frames"].filter { setup.rejected.contains($0.key) }.values.joined(separator: " and ")
            return ProbeResult(setup: setup, identity: nil, rawReply: [],
                               reason: "This adapter can't do Subaru SSM. Its ELM327 chip did not accept \(missing.isEmpty ? "the raw 4800 baud K-line commands" : missing), which SSM needs. That is normal for clone chips. A genuine ELM327 (v1.4 or newer), a KKL cable in SSM mode, or a small dedicated adapter would work.")
        }
        let reason = lastReply.isEmpty
            ? "The chip can do raw K-line, but the car did not answer on any K-line protocol (ISO 9141 or KWP). On this car SSM runs on K-line pin 7; many Bluetooth adapters only wire up the CAN pins, so the K-line never reaches the ECU. OBD-II over CAN still works. For real SSM, use the KKL cable or a dedicated K-line adapter."
            : "The chip can do raw K-line and the car sent \(lastReply.count) bytes, but not a valid SSM reply. The bytes are in the log."
        return ProbeResult(setup: setup, identity: nil, rawReply: lastReply, reason: reason)
    }

    /// One SSM request and its reply, once raw mode is set up. Used by a full SSM-over-Bluetooth session.
    public func exchange(_ packet: SSMPacket, timeout: TimeInterval = 1.0) throws -> SSMPacket {
        let reply = try elm.exchangeRawKLine(try packet.encoded(), timeout: timeout)
        guard let frame = Self.firstSSMFrame(in: reply, from: packet.destination) else {
            throw OBDError.noData
        }
        return try SSMPacket.decode(frame)
    }

    /// Finds the first valid SSM frame in a run of bytes, ignoring our own echoed request
    /// (a frame addressed to `requestDestination`, i.e. sent by the tester).
    static func firstSSMFrame(in bytes: [UInt8], from requestDestination: UInt8) -> [UInt8]? {
        var i = 0
        while i + 5 <= bytes.count {
            if bytes[i] == SSMPacket.header {
                let length = Int(bytes[i + 3])
                let end = i + 5 + length
                if end <= bytes.count {
                    let frame = Array(bytes[i..<end])
                    if let packet = try? SSMPacket.decode(frame), packet.destination != requestDestination {
                        return frame
                    }
                }
            }
            i += 1
        }
        return nil
    }
}
