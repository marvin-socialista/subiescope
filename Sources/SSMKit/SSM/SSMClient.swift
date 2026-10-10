import Foundation

/// What the ECU reports in its reply to the 0xBF init request.
public struct ECUIdentity: Equatable, Sendable {
    /// 3 byte SSM system ID (identifies the kind of control unit).
    public var systemID: [UInt8]
    /// 5 byte ROM ID, the "ECU ID" RomRaider uses to pick extended parameters.
    public var romID: [UInt8]
    /// Capability ("flag") bytes: bit flags telling which standard parameters,
    /// switches and features this ECU supports.
    public var capabilities: [UInt8]

    public init(systemID: [UInt8], romID: [UInt8], capabilities: [UInt8]) {
        self.systemID = systemID
        self.romID = romID
        self.capabilities = capabilities
    }

    /// e.g. "4B12785207"
    public var ecuID: String { romID.map { String(format: "%02X", $0) }.joined() }
    public var systemIDString: String { systemID.map { String(format: "%02X", $0) }.joined() }

    /// Everything after the 0xFF in the init reply: system ID, ROM ID, capabilities.
    public var initData: [UInt8] { systemID + romID + capabilities }

    /// `byteIndex` counts from the first byte after 0xFF (RomRaider's `ecubyteindex`),
    /// so index 8 is the first capability byte.
    public func supports(byteIndex: Int, bit: Int) -> Bool {
        let data = initData
        guard byteIndex >= 0, byteIndex < data.count, (0...7).contains(bit) else { return false }
        return data[byteIndex] & (1 << bit) != 0
    }

    static func parse(initReply: SSMPacket) throws -> ECUIdentity {
        let d = initReply.data
        guard d.count >= 9, d[0] == 0xFF else {
            throw SSMError.unexpectedResponse("init reply too short: \(d.hexString)")
        }
        return ECUIdentity(systemID: Array(d[1...3]), romID: Array(d[4...8]), capabilities: Array(d.dropFirst(9)))
    }
}

/// High level SSM2 operations against one control unit.
public final class SSMClient {
    public let transport: SSMTransport
    public let device: SSMDevice
    /// Largest number of addresses sent in one 0xA8 request. A packet has room for 84
    /// (2 + 3 * 84 = 254 data bytes), but a real ECU does not answer a request that long:
    /// a 2008 STI answered 37 addresses and stayed silent on 84. FreeSSM asks for at most 33
    /// at a time and notes that control units have different, lower limits, so this follows it.
    public var maxAddressesPerRequest = 33

    /// The most addresses a fast poll request is tried with. RomRaider's protocol notes give
    /// about 250 bytes as the largest packet, the echoed request and the answer together:
    /// (7 + 3 * 59) + (6 + 59) = 249.
    public static let maxAddressesPerStream = 59

    public init(transport: SSMTransport, device: SSMDevice = .engine) {
        self.transport = transport
        self.device = device
    }

    public func identify() throws -> ECUIdentity {
        try ECUIdentity.parse(initReply: transport.exchange(.initRequest(to: device)))
    }

    /// Reads one byte per address, splitting into several requests if needed.
    public func read(addresses: [UInt32]) throws -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(addresses.count)
        var index = 0
        while index < addresses.count {
            let chunk = Array(addresses[index..<min(index + maxAddressesPerRequest, addresses.count)])
            let reply = try transport.exchange(.readAddressesRequest(chunk, to: device), expectedDataLength: chunk.count + 1)
            let values = Array(reply.payload)
            guard values.count == chunk.count else {
                throw SSMError.unexpectedResponse("asked for \(chunk.count) addresses, got \(values.count) values")
            }
            result.append(contentsOf: values)
            index += chunk.count
        }
        return result
    }

    /// Reads `count` consecutive bytes with 0xA0 block reads (max 128 per request).
    public func readBlock(at address: UInt32, count: Int) throws -> [UInt8] {
        var result: [UInt8] = []
        var offset = 0
        while offset < count {
            let n = min(128, count - offset)
            let reply = try transport.exchange(.readBlockRequest(address + UInt32(offset), count: n, to: device),
                                               expectedDataLength: n + 1)
            let values = Array(reply.payload)
            guard values.count == n else {
                throw SSMError.unexpectedResponse("block read returned \(values.count) of \(n) bytes")
            }
            result.append(contentsOf: values)
            offset += n
        }
        return result
    }

    /// Writes one byte and verifies the value the ECU reports back.
    @discardableResult
    public func write(address: UInt32, value: UInt8) throws -> UInt8 {
        let reply = try transport.exchange(.writeAddressRequest(address, value: value, to: device), expectedDataLength: 2)
        guard let echoed = reply.payload.first else {
            throw SSMError.unexpectedResponse("empty write reply")
        }
        guard echoed == value else {
            throw SSMError.writeRejected(address: address, wrote: value, got: echoed)
        }
        return echoed
    }
}

// Only ever used from SSMSession's serial I/O queue.
extension SSMClient: @unchecked Sendable {}
