#if os(Windows)
import CSerial
import Foundation

/// What Windows knows about the devices that are plugged in, as the C shim reports it.
enum WindowsDevices {
    /// The lines of one of the shim's lists, each split into its fields.
    static func lines(_ list: (UnsafeMutablePointer<CChar>?, Int32) -> Int32) -> [[String]] {
        var size = 16384
        while true {
            var buffer = [CChar](repeating: 0, count: size)
            let needed = Int(list(&buffer, Int32(size)))
            if needed < size {
                return String(cString: buffer).split(separator: "\n")
                    .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            }
            size = needed + 1024
        }
    }

    /// The USB numbers in a device id: "USB\VID_0403&PID_6001\A50285BI", or the port an FTDI
    /// cable's driver makes, "FTDIBUS\VID_0403+PID_6001+A50285BIA\0000". Nil for anything else.
    static func usbIdentity(_ id: String) -> (vendorID: Int, productID: Int, serialNumber: String?)? {
        let upper = id.uppercased()
        guard let vendor = hex(after: "VID_", in: upper), let product = hex(after: "PID_", in: upper) else { return nil }
        let parts = id.split(separator: "\\")
        var serial: String?
        if upper.hasPrefix("USB\\"), parts.count >= 3 {
            serial = String(parts[2])
        } else if upper.hasPrefix("FTDIBUS\\"), parts.count >= 2 {
            // The last letter is the port of the chip (A for the only one a cable has).
            let pieces = parts[1].split(separator: "+")
            if pieces.count >= 3 { serial = String(pieces[2].dropLast()) }
        }
        // Windows makes up an id with "&" in it for a device that has no serial number.
        if let found = serial, found.contains("&") || found.isEmpty { serial = nil }
        return (vendor, product, serial)
    }

    private static func hex(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        return Int(text[range.upperBound...].prefix(4), radix: 16)
    }

    /// The name of the paired Bluetooth device behind a "Standard Serial over Bluetooth link" port.
    /// Its address is the twelve hex digits before "_C" in the port's device id.
    static func bluetoothName(forPort id: String) -> String? {
        let upper = id.uppercased()
        guard upper.hasPrefix("BTHENUM\\"), let end = upper.range(of: "_C", options: .backwards) else { return nil }
        let address = String(upper[..<end.lowerBound].suffix(12))
        guard address.count == 12, address.allSatisfy(\.isHexDigit), address != "000000000000" else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        guard cserial_bluetooth_name(address, &buffer, Int32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
#endif
