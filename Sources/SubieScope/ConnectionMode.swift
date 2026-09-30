import Foundation

/// How SubieScope talks to the car. Both plug into the same OBD port under the dashboard.
enum ConnectionMode: String, CaseIterable, Identifiable {
    /// Subaru's own protocol over a VAG KKL USB cable: the full Subaru data set.
    case ssm
    /// Standard OBD-II over a Bluetooth LE ELM327 adapter: any car, basic data.
    case obd

    var id: String { rawValue }

    /// Stored under this key when a person picks a mode, so first launch can ask.
    static var hasChosen: Bool { UserDefaults.standard.string(forKey: "connectionMode") != nil }

    static var saved: ConnectionMode {
        ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "connectionMode") ?? "") ?? .ssm
    }

    /// Gauges and logged parameters are remembered separately for each mode.
    var keySuffix: String { self == .obd ? ".obd" : "" }

    var title: String {
        switch self {
        case .ssm: return "Subaru SSM"
        case .obd: return "OBD-II"
        }
    }

    var hardware: String {
        switch self {
        case .ssm: return "USB cable (VAG KKL, FTDI chip)"
        case .obd: return "Bluetooth adapter (ELM327, Bluetooth 4.0 / LE)"
        }
    }

    var symbol: String {
        switch self {
        case .ssm: return "cable.connector"
        case .obd: return "wave.3.right"
        }
    }

    var deviceNoun: String { self == .ssm ? "cable" : "adapter" }
}

/// The plain-language explanation shown when choosing a mode.
enum ModeGuide {
    struct Row: Identifiable {
        var id: String { model }
        var model: String
        var years: String
        var note: String
    }

    static let ssmBestFor = "Subarus up to about 2014, when you want everything the ECU knows."
    static let obdBestFor = "Newer Subarus (about 2015 and up) and any other car built since 2008, for the basics."

    static let ssmGets = [
        "Every Subaru value: knock correction, IAM, boost target, wastegate duty, AVCS, A/F sensor and hundreds more",
        "All the troubleshooting tests and the virtual dyno at full quality",
        "Fast: roughly 10 to 25 samples per second",
        "Subaru trouble codes with explanations, and clearing the ECU memory",
    ]
    static let ssmNeeds = "A VAG KKL 409.1 USB cable with an FTDI chip (about €10 to 15). No driver needed."

    static let obdGets = [
        "Standard values every car reports: rpm, speed, coolant and air temperature, load, throttle, fuel trims, timing, manifold pressure (with a boost gauge), battery voltage and wideband air/fuel on cars that have it",
        "Trouble codes (confirmed and pending) with explanations, clearing them, and the VIN",
        "Logging to CSV, and the tests that only need standard values",
        "Works on cars the KKL cable cannot read, and wirelessly",
    ]
    static let obdMissing = [
        "No Subaru-only values (knock correction, IAM, AVCS, wastegate duty)",
        "Slower: roughly 3 to 10 samples per second, depending on your adapter and how many gauges you show, so the dyno is only a rough indication",
    ]
    static let obdNeeds = "An ELM327 adapter with Bluetooth 4.0 (BLE), such as the Vgate iCar Pro BLE 4.0. Older Bluetooth Classic and Wi-Fi adapters are not supported yet."

    static let ssmModels: [Row] = [
        Row(model: "Impreza, WRX, WRX STI (GC/GF, GD/GG, GE/GH/GR/GV)", years: "1999 to 2014", note: "Best choice"),
        Row(model: "Legacy, Liberty, Outback (BE/BH, BL/BP)", years: "1999 to 2009", note: "Best choice"),
        Row(model: "Legacy, Liberty, Outback (BM/BR)", years: "2010 to 2014", note: "Most models"),
        Row(model: "Forester (SF, SG, SH), Baja, Tribeca", years: "1999 to 2014", note: "Best choice"),
    ]
    static let obdModels: [Row] = [
        Row(model: "WRX / WRX STI (VA)", years: "2014 and newer", note: "OBD-II only: these cars have no SSM on the K-line"),
        Row(model: "Levorg, XV / Crosstrek, Forester (SJ and newer), Impreza (GJ/GK, GT)", years: "2012 and newer", note: "OBD-II only"),
        Row(model: "Outback, Legacy (BN/BS and newer), Ascent", years: "2015 and newer", note: "OBD-II only"),
        Row(model: "BRZ, GR86 (Toyota-built ECU)", years: "All years", note: "OBD-II only"),
        Row(model: "Older Subarus and other brands", years: "2008 and newer", note: "Works, but Subarus up to 2014 do more with SSM"),
    ]

    static let notSure = "Not sure? Cars up to about 2014 (older shape of the WRX and STI): pick Subaru SSM. Anything newer: pick OBD-II. Both connect to the same port under the dashboard, so you can switch any time in the Car menu."
}
