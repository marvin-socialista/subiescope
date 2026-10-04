import Foundation

/// How an ELM327 adapter is reached. The same text protocol runs over all three.
public enum OBDAdapterLink: Equatable, Sendable {
    /// Bluetooth LE, by the identifier of the peripheral.
    case bluetooth(String)
    /// A USB ELM327 cable, or any other serial port (a paired Bluetooth Classic adapter shows up as one).
    case serial(path: String)
    /// A Wi-Fi adapter, by address and port.
    case network(host: String, port: UInt16)

    /// What nearly every Wi-Fi ELM327 adapter uses.
    public static let defaultHost = "192.168.0.10"
    public static let defaultPort: UInt16 = 35000

    private static let serialPrefix = "usb:"
    private static let networkPrefix = "wifi:"

    /// Reads the stored form. A bare identifier is Bluetooth, as it was before the other two existed.
    public init(id: String) {
        if id.hasPrefix(Self.serialPrefix) {
            self = .serial(path: String(id.dropFirst(Self.serialPrefix.count)))
        } else if id.hasPrefix(Self.networkPrefix) {
            self = .network(address: String(id.dropFirst(Self.networkPrefix.count)))
        } else {
            self = .bluetooth(id)
        }
    }

    /// The form to store and to tell adapters apart by.
    public var id: String {
        switch self {
        case .bluetooth(let peripheral): return peripheral
        case .serial(let path): return Self.serialPrefix + path
        case .network: return Self.networkPrefix + address
        }
    }

    /// A Wi-Fi adapter from what a person types: "192.168.0.10:35000", or only the address.
    /// Whatever is left out falls back to the usual value.
    public static func network(address: String) -> OBDAdapterLink {
        let text = address.trimmingCharacters(in: .whitespaces)
        var host = text
        var port = defaultPort
        if let colon = text.lastIndex(of: ":"), let number = UInt16(text[text.index(after: colon)...]) {
            host = String(text[..<colon])
            port = number
        }
        return .network(host: host.isEmpty ? defaultHost : host, port: port)
    }

    /// "192.168.0.10:35000" for a Wi-Fi adapter, the device path or identifier otherwise.
    public var address: String {
        switch self {
        case .bluetooth(let peripheral): return peripheral
        case .serial(let path): return path
        case .network(let host, let port): return "\(host):\(port)"
        }
    }
}
