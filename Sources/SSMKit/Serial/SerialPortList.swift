import Foundation
import IOKit
import IOKit.serial

public struct SerialPortInfo: Identifiable, Hashable, Sendable {
    public var id: String { path }
    /// Callout device, e.g. /dev/cu.usbserial-A50285BI
    public let path: String
    public let productName: String?
    public let vendorName: String?
    public let vendorID: Int?
    public let productID: Int?
    public let serialNumber: String?

    public init(path: String, productName: String? = nil, vendorName: String? = nil,
                vendorID: Int? = nil, productID: Int? = nil, serialNumber: String? = nil) {
        self.path = path
        self.productName = productName
        self.vendorName = vendorName
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
    }

    /// A Tactrix OpenPort 2.0. It carries FTDI's vendor number but is not an FTDI serial cable.
    public var isOpenPort: Bool {
        guard let vendorID, let productID else { return false }
        return CableChip(vendorID: vendorID, productID: productID) == .openPort2
    }
    public var isFTDI: Bool { vendorID == 0x0403 && !isOpenPort }
    public var isUSB: Bool { vendorID != nil }

    /// Ports macOS always has that are never a diagnostic cable.
    public var isSystemPort: Bool {
        let name = (path as NSString).lastPathComponent
        return name.contains("Bluetooth-Incoming-Port") || name.contains("debug-console")
            || name.hasPrefix("cu.wlan") || name.contains("MALS") || name.contains("SOC")
    }

    public var displayName: String {
        let device = (path as NSString).lastPathComponent
        if let productName, !productName.isEmpty {
            var label = productName
            if let vendorName, !vendorName.isEmpty, !productName.localizedCaseInsensitiveContains(vendorName) {
                label = "\(vendorName) \(productName)"
            }
            return "\(label) (\(device))"
        }
        return device
    }
}

public enum SerialPortList {
    /// Lists serial callout devices, USB adapters first.
    public static func available(includeSystemPorts: Bool = false) -> [SerialPortInfo] {
        var ports: [SerialPortInfo] = []
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary? else {
            return fallbackScan(includeSystemPorts: includeSystemPorts)
        }
        matching[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return fallbackScan(includeSystemPorts: includeSystemPorts)
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = property(service, kIOCalloutDeviceKey) as? String else { continue }
            let info = SerialPortInfo(
                path: path,
                productName: usbProperty(service, "USB Product Name") as? String
                    ?? usbProperty(service, "kUSBProductString") as? String,
                vendorName: usbProperty(service, "USB Vendor Name") as? String
                    ?? usbProperty(service, "kUSBVendorString") as? String,
                vendorID: (usbProperty(service, "idVendor") as? NSNumber)?.intValue,
                productID: (usbProperty(service, "idProduct") as? NSNumber)?.intValue,
                serialNumber: usbProperty(service, "USB Serial Number") as? String
                    ?? usbProperty(service, "kUSBSerialNumberString") as? String
            )
            if includeSystemPorts || !info.isSystemPort {
                ports.append(info)
            }
        }
        return ports.sorted { lhs, rhs in
            if lhs.isFTDI != rhs.isFTDI { return lhs.isFTDI }
            if lhs.isUSB != rhs.isUSB { return lhs.isUSB }
            return lhs.path < rhs.path
        }
    }

    private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Looks the key up on the service and its USB ancestors.
    private static func usbProperty(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
    }

    private static func fallbackScan(includeSystemPorts: Bool) -> [SerialPortInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.") }.sorted().map { SerialPortInfo(path: "/dev/\($0)") }
            .filter { includeSystemPorts || !$0.isSystemPort }
    }
}
