import Foundation

/// SSM2 addresses on the diagnostic bus.
public enum SSMDevice: UInt8, Sendable {
    case engine = 0x10
    case transmission = 0x18
    case tester = 0xF0
}

/// SSM2 command and response codes.
public enum SSMCommand {
    public static let readBlock: UInt8 = 0xA0
    public static let readAddresses: UInt8 = 0xA8
    public static let writeBlock: UInt8 = 0xB0
    public static let writeAddress: UInt8 = 0xB8
    public static let initECU: UInt8 = 0xBF

    /// A response echoes the request command plus 0x40 (0xA8 -> 0xE8, 0xBF -> 0xFF).
    public static func response(to command: UInt8) -> UInt8 { command &+ 0x40 }
}

public enum SSMPacketError: Error, LocalizedError, Equatable {
    case tooShort
    case badHeader(UInt8)
    case lengthMismatch(expected: Int, actual: Int)
    case badChecksum(expected: UInt8, actual: UInt8)
    case payloadTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .tooShort: return "SSM packet too short."
        case .badHeader(let b): return String(format: "SSM packet has invalid header byte 0x%02X.", b)
        case .lengthMismatch(let e, let a): return "SSM packet length mismatch (expected \(e), got \(a))."
        case .badChecksum(let e, let a): return String(format: "SSM checksum error (expected 0x%02X, got 0x%02X).", e, a)
        case .payloadTooLarge(let n): return "SSM payload of \(n) bytes exceeds the 255 byte limit."
        }
    }
}

/// One SSM2 frame: 0x80, destination, source, data length, data..., checksum.
public struct SSMPacket: Equatable, Sendable {
    public static let header: UInt8 = 0x80

    public var destination: UInt8
    public var source: UInt8
    /// Command byte followed by its parameters.
    public var data: [UInt8]

    public init(destination: UInt8, source: UInt8, data: [UInt8]) {
        self.destination = destination
        self.source = source
        self.data = data
    }

    public var command: UInt8? { data.first }
    public var payload: ArraySlice<UInt8> { data.dropFirst() }

    public func encoded() throws -> [UInt8] {
        guard data.count <= 0xFF else { throw SSMPacketError.payloadTooLarge(data.count) }
        var bytes: [UInt8] = [Self.header, destination, source, UInt8(data.count)]
        bytes.append(contentsOf: data)
        bytes.append(Self.checksum(bytes))
        return bytes
    }

    public static func checksum<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        bytes.reduce(UInt8(0)) { $0 &+ $1 }
    }

    /// Parses exactly one complete frame.
    public static func decode(_ bytes: [UInt8]) throws -> SSMPacket {
        guard bytes.count >= 5 else { throw SSMPacketError.tooShort }
        guard bytes[0] == header else { throw SSMPacketError.badHeader(bytes[0]) }
        let length = Int(bytes[3])
        guard bytes.count == length + 5 else {
            throw SSMPacketError.lengthMismatch(expected: length + 5, actual: bytes.count)
        }
        let expected = checksum(bytes[0..<(bytes.count - 1)])
        guard expected == bytes[bytes.count - 1] else {
            throw SSMPacketError.badChecksum(expected: expected, actual: bytes[bytes.count - 1])
        }
        return SSMPacket(destination: bytes[1], source: bytes[2], data: Array(bytes[4..<(4 + length)]))
    }

    // MARK: Request builders

    public static func initRequest(to device: SSMDevice = .engine) -> SSMPacket {
        SSMPacket(destination: device.rawValue, source: SSMDevice.tester.rawValue, data: [SSMCommand.initECU])
    }

    /// 0xA8 request. `continuous` asks the ECU to keep answering without new requests.
    public static func readAddressesRequest(_ addresses: [UInt32], to device: SSMDevice = .engine,
                                            continuous: Bool = false) -> SSMPacket {
        var data: [UInt8] = [SSMCommand.readAddresses, continuous ? 0x01 : 0x00]
        for address in addresses {
            data.append(contentsOf: address.ssmAddressBytes)
        }
        return SSMPacket(destination: device.rawValue, source: SSMDevice.tester.rawValue, data: data)
    }

    /// 0xA0 request for `count` consecutive bytes (1...256) starting at `address`.
    public static func readBlockRequest(_ address: UInt32, count: Int, to device: SSMDevice = .engine) -> SSMPacket {
        var data: [UInt8] = [SSMCommand.readBlock, 0x00]
        data.append(contentsOf: address.ssmAddressBytes)
        data.append(UInt8(clamping: count - 1))
        return SSMPacket(destination: device.rawValue, source: SSMDevice.tester.rawValue, data: data)
    }

    /// 0xB8 request writing one byte.
    public static func writeAddressRequest(_ address: UInt32, value: UInt8, to device: SSMDevice = .engine) -> SSMPacket {
        var data: [UInt8] = [SSMCommand.writeAddress]
        data.append(contentsOf: address.ssmAddressBytes)
        data.append(value)
        return SSMPacket(destination: device.rawValue, source: SSMDevice.tester.rawValue, data: data)
    }
}

extension UInt32 {
    /// 24 bit big-endian address as used on the wire.
    var ssmAddressBytes: [UInt8] {
        [UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
    }
}

extension Array where Element == UInt8 {
    public var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

extension ArraySlice where Element == UInt8 {
    public var hexString: String { Array(self).hexString }
}
