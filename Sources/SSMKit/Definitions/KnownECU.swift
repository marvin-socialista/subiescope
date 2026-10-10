import Foundation

/// What an engine ECU's ID says about it: the car it came in, its calibration, and how its ROM is
/// read and written. Loaded from Cars/known_ecus.json, which `scripts/build-car-data.py` makes
/// from the ROM definitions the RomRaider community keeps (collected by Merp in SubaruDefs).
public struct KnownECU: Codable, Sendable, Hashable {
    public var ecuID: String
    /// The calibration ID, the name tuners know a ROM by (for example "AZ1G500F").
    public var calID: String
    /// Model year as text: "2009", or a range such as "2008/09".
    public var year: String?
    /// JDM, USDM, EDM, ADM or SADM.
    public var market: String?
    public var model: String
    /// "manual", "automatic" or "manual or automatic".
    public var transmission: String?
    /// The ECU's processor: 68HC16Y5, SH7055 or SH7058.
    public var processor: String?
    /// The name EcuFlash gives the way this ECU is flashed: wrx02, wrx04, sti04, sti05 or subarucan.
    public var flashMethod: String?

    /// Every known ECU by ECU ID. A few IDs are shared by two calibrations.
    public static let library: [String: [KnownECU]] = {
        guard let url = SSMResources.url(forCars: "known_ecus"),
              let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([KnownECU].self, from: data) else { return [:] }
        return Dictionary(grouping: rows, by: \.ecuID)
    }()

    public static func lookup(_ ecuID: String) -> [KnownECU] {
        library[ecuID.uppercased()] ?? []
    }

    /// "2009 Impreza STi, JDM, manual"
    public var carName: String {
        [[year, model].compactMap { $0 }.joined(separator: " "), market, transmission].compactMap { $0 }.joined(separator: ", ")
    }

    /// One line for everything that shares an ECU ID: "2009 Impreza STi, JDM, manual (AZ1G500F)".
    public static func description(of ecus: [KnownECU]) -> String? {
        guard !ecus.isEmpty else { return nil }
        var cars: [String] = []
        for ecu in ecus where !cars.contains(ecu.carName) { cars.append(ecu.carName) }
        return cars.joined(separator: " or ") + " (" + ecus.map(\.calID).joined(separator: " or ") + ")"
    }

    // MARK: How the ROM is read and written

    /// The wire a ROM travels over when it is read or flashed through the diagnostic plug.
    public enum FlashTransport: Sendable {
        /// The single K-line wire, the one SSM logging uses.
        case kLine
        /// CAN. A KKL cable has no CAN.
        case can
    }

    /// The processor with what FastECU's protocol list says about it.
    public var processorDescription: String? {
        switch processor {
        case "68HC16Y5": return "Motorola 68HC16Y5 (16-bit, 160 KB ROM)"
        case "SH7055": return "Renesas SH7055 (32-bit, 512 KB ROM)"
        case "SH7058": return "Renesas SH7058 (32-bit, 1 MB ROM)"
        default: return processor
        }
    }

    /// EcuFlash's `subarucan` goes over CAN; the four older methods go over the K-line.
    public var flashTransport: FlashTransport? {
        switch flashMethod {
        case "subarucan": return .can
        case "wrx02", "wrx04", "sti04", "sti05": return .kLine
        default: return nil
        }
    }
}
