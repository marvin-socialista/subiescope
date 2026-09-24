import Foundation
import IOKit
import IOKit.usb

/// A USB device that looks like a diagnostic cable, whether or not a driver has
/// created a serial port for it.
public struct USBCable: Identifiable, Hashable, Sendable {
    public var id: String { "\(vendorID):\(productID):\(serialNumber ?? locationID.description)" }
    public let vendorID: Int
    public let productID: Int
    public let productName: String?
    public let vendorName: String?
    public let serialNumber: String?
    public let locationID: Int
    /// Serial device created for it, if a driver is attached.
    public var serialPath: String?

    public var chip: CableChip { CableChip(vendorID: vendorID, productID: productID) }
}

public enum CableChip: Sendable, Hashable {
    case ftdi, ch340, pl2303, cp210x, openPort2, unknown

    init(vendorID: Int, productID: Int) {
        switch (vendorID, productID) {
        case (0x0403, 0xCC4C), (0x0403, 0xCC4D): self = .openPort2
        case (0x0403, _): self = .ftdi
        case (0x1A86, _): self = .ch340
        case (0x067B, _): self = .pl2303
        case (0x10C4, _): self = .cp210x
        default: self = .unknown
        }
    }

    public var name: String {
        switch self {
        case .ftdi: return "FTDI (FT232R)"
        case .ch340: return "WCH CH340/CH341"
        case .pl2303: return "Prolific PL2303"
        case .cp210x: return "Silicon Labs CP210x"
        case .openPort2: return "Tactrix OpenPort 2.0"
        case .unknown: return "Unknown chip"
        }
    }

    /// Plain-language driver situation on macOS.
    public var driverAdvice: String {
        switch self {
        case .ftdi:
            return "macOS has a built-in driver for FTDI chips. Nothing to install. Don't install FTDI's own driver: it can conflict with Apple's."
        case .ch340:
            return "Recent macOS versions include a CH340 driver. If no port appears, install WCH's driver and allow it in System Settings › Privacy & Security. Note: CH340 cables are known to be unreliable with Subarus; an FTDI-based cable is recommended."
        case .pl2303:
            return "Prolific cables need Prolific's driver (\"PL2303 Serial\" from the Mac App Store). Allow it in System Settings › Privacy & Security after installing."
        case .cp210x:
            return "Silicon Labs cables need the CP210x VCP driver from silabs.com. Allow it in System Settings › Privacy & Security after installing."
        case .openPort2:
            return "The OpenPort 2.0 is a J2534 interface, not a serial KKL cable. SubieScope doesn't support it yet; use a VAG KKL (FTDI) cable."
        case .unknown:
            return "SubieScope doesn't recognise this chip. KKL cables with an FTDI chip work best."
        }
    }

    public var driverURL: URL? {
        switch self {
        case .ch340: return URL(string: "https://www.wch-ic.com/downloads/CH34XSER_MAC_ZIP.html")
        case .pl2303: return URL(string: "https://apps.apple.com/app/pl2303-serial/id1624835354")
        case .cp210x: return URL(string: "https://www.silabs.com/developers/usb-to-uart-bridge-vcp-drivers")
        default: return nil
        }
    }

    /// Chips that commonly show up in KKL / OBD cables.
    public var isLikelyCable: Bool { self != .unknown }
}

public enum CableScanner {
    /// USB devices with a known cable chip, matched to their serial ports.
    public static func scan() -> [USBCable] {
        var cables: [USBCable] = []
        for className in ["IOUSBHostDevice", "IOUSBDevice"] {
            guard let matching = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                func prop(_ key: String) -> Any? {
                    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                }
                guard let vid = (prop("idVendor") as? NSNumber)?.intValue, let pid = (prop("idProduct") as? NSNumber)?.intValue else { continue }
                let chip = CableChip(vendorID: vid, productID: pid)
                guard chip.isLikelyCable else { continue }
                let cable = USBCable(
                    vendorID: vid, productID: pid,
                    productName: (prop("USB Product Name") ?? prop("kUSBProductString")) as? String,
                    vendorName: (prop("USB Vendor Name") ?? prop("kUSBVendorString")) as? String,
                    serialNumber: (prop("USB Serial Number") ?? prop("kUSBSerialNumberString")) as? String,
                    locationID: (prop("locationID") as? NSNumber)?.intValue ?? 0,
                    serialPath: nil)
                if !cables.contains(where: { $0.id == cable.id }) { cables.append(cable) }
            }
        }
        let ports = SerialPortList.available()
        return cables.map { cable in
            var c = cable
            c.serialPath = ports.first {
                $0.vendorID == cable.vendorID && $0.productID == cable.productID
                    && (cable.serialNumber == nil || $0.serialNumber == nil || $0.serialNumber == cable.serialNumber)
            }?.path
            return c
        }
    }
}

/// Step-by-step connection test with explanations a non-expert understands.
public enum CableTest {
    public enum Outcome: Sendable, Equatable {
        /// The ECU answered.
        case ok(ECUIdentity)
        /// The port could not be opened (busy, permissions, unplugged).
        case portFailed(String)
        /// Nothing came back: the cable's car side has no power.
        case noEcho
        /// The cable works but the ECU stayed silent.
        case noAnswer
        /// Bytes came back that make no sense (wrong baud, wrong line, faulty cable).
        case garbage(Int)
    }

    public static func run(path: String) -> Outcome {
        let port = SerialPort(path: path)
        do {
            try port.open(baud: 4800)
        } catch {
            return .portFailed(error.localizedDescription)
        }
        defer { port.close() }
        Thread.sleep(forTimeInterval: 0.15)
        let transport = SSMTransport(port: port)
        transport.responseTimeout = 0.8
        let client = SSMClient(transport: transport)
        var lastError: Error?
        for _ in 0..<3 {
            do {
                return .ok(try client.identify())
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        if case SSMError.timeout(_, let received, let sawEcho)? = lastError {
            if received == 0 { return .noEcho }
            return sawEcho ? .noAnswer : .garbage(received)
        }
        if let serial = lastError as? SerialError { return .portFailed(serial.localizedDescription) }
        return .noAnswer
    }

    public static func explanation(_ outcome: Outcome) -> (title: String, detail: String) {
        switch outcome {
        case .ok(let id):
            return ("Connected", "The ECU answered with ECU ID \(id.ecuID). Everything works.")
        case .portFailed(let reason):
            return ("The cable's port can't be opened",
                    "Close other apps that may use the cable (RomRaider, a terminal, another SubieScope window), unplug the cable and plug it back in. Details: \(reason)")
        case .noEcho:
            return ("The cable gets no power from the car",
                    "A KKL cable's car side is powered by the OBD port. Plug the cable firmly into the OBD port under the dashboard and turn the ignition ON. If your cable has a switch, set it to the position that uses pin 7 (K-line).")
        case .noAnswer:
            return ("The cable works, but the ECU doesn't answer",
                    "SubieScope hears its own messages, so the cable is fine. Turn the ignition ON (engine running is fine too). If it still fails: your car may use CAN instead of K-line (most Subarus from about 2014), or the cable's switch is in the wrong position.")
        case .garbage(let n):
            return ("Unexpected data from the cable",
                    "Received \(n) bytes that aren't SSM messages. Check the switch position on the cable, try another USB port, or try a different cable (cheap clones sometimes misbehave).")
        }
    }
}
