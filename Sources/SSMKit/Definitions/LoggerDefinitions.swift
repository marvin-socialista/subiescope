import Foundation

/// RomRaider logger definitions (logger_METRIC_EN_v370.xml and compatible),
/// restricted to the SSM protocol.
public final class LoggerDefinitions: @unchecked Sendable {
    public struct ExtendedParameter: Sendable {
        public var base: ParameterDefinition
        /// ECU ID -> addresses for that ECU.
        public var addressesByECU: [String: [UInt32]]
    }

    public let sourceURL: URL
    public let version: String?
    public let standard: [ParameterDefinition]
    public let switches: [ParameterDefinition]
    public let calculated: [ParameterDefinition]
    public let extended: [ExtendedParameter]
    public let codes: [DiagnosticCodeDefinition]

    public var ecuIDCount: Int { Set(extended.flatMap { $0.addressesByECU.keys }).count }

    public enum LoadError: Error, LocalizedError {
        case notFound
        case parse(String)
        case noSSMProtocol

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return "The parameter definitions haven't been downloaded yet. Connect to the internet once, or choose a RomRaider logger XML (logger_METRIC_EN_v370.xml) in Settings."
            case .parse(let reason): return "Could not read the definition file: \(reason)"
            case .noSSMProtocol: return "The file contains no SSM protocol section. Is it a RomRaider logger definition?"
            }
        }
    }

    init(sourceURL: URL, version: String?, standard: [ParameterDefinition], switches: [ParameterDefinition],
         calculated: [ParameterDefinition], extended: [ExtendedParameter], codes: [DiagnosticCodeDefinition]) {
        self.sourceURL = sourceURL
        self.version = version
        self.standard = standard
        self.switches = switches
        self.calculated = calculated
        self.extended = extended
        self.codes = codes
    }

    public static func load(url: URL) throws -> LoggerDefinitions {
        let data = try Data(contentsOf: url)
        let handler = DefinitionsParser(sourceURL: url)
        do {
            try XMLReader.parse(data, handler: handler)
        } catch {
            throw LoadError.parse(error.localizedDescription)
        }
        guard handler.sawSSM else { throw LoadError.noSSMProtocol }
        return handler.result()
    }

    /// The downloaded definitions, or a copy bundled with a development build.
    public static func bundled() throws -> LoggerDefinitions {
        if let installed = DefinitionsStore.installedURL { return try load(url: installed) }
        let files = SSMResources.definitionFiles()
        guard let url = files.last(where: { $0.lastPathComponent.contains("METRIC_EN") }) ?? files.last else {
            throw LoadError.notFound
        }
        return try load(url: url)
    }

    /// Parameters and trouble codes that apply to `identity`, or everything when nil (offline browsing).
    public func parameterSet(for identity: ECUIdentity?) -> ECUParameterSet {
        var result: [ParameterDefinition] = []
        if let identity {
            result += standard.filter { p in
                guard let byte = p.capabilityByte, let bit = p.capabilityBit else { return true }
                return identity.supports(byteIndex: byte, bit: bit)
            }
            result += extended.compactMap { e in
                guard let addresses = e.addressesByECU[identity.ecuID] else { return nil }
                var p = e.base
                p.addresses = addresses
                return p
            }
            result += switches.filter { s in
                guard let byte = s.capabilityByte, let bit = s.capabilityBit else { return true }
                return identity.supports(byteIndex: byte, bit: bit)
            }
        } else {
            result += standard + extended.map(\.base) + switches
        }
        // target 2 means transmission only; SubieScope talks to the engine ECU.
        result.removeAll { $0.target == 2 }
        let available = Set(result.map(\.id))
        // A calculated parameter needs all of its inputs.
        result += calculated.filter { $0.dependencies.allSatisfy(available.contains) }

        var codes = self.codes
        if let identity, identity.initData.count < 104 {
            // RomRaider: ECUs with short init data only know the first 488 codes.
            codes = codes.filter { (Int($0.id.dropFirst()) ?? 0) <= 488 }
        }
        return ECUParameterSet(parameters: result, diagnosticCodes: codes)
    }
}

private final class DefinitionsParser: XMLEventHandler {
    let sourceURL: URL
    var version: String?
    var sawSSM = false

    private var inSSM = false
    private var standard: [ParameterDefinition] = []
    private var switches: [ParameterDefinition] = []
    private var calculated: [ParameterDefinition] = []
    private var extended: [LoggerDefinitions.ExtendedParameter] = []
    private var codes: [DiagnosticCodeDefinition] = []

    // Element being built
    private var current: ParameterDefinition?
    private var currentIsExtended = false
    private var ecuIDs: [String] = []
    private var addressesByECU: [String: [UInt32]] = [:]
    private var addressLength = 1
    private var addressBit: Int?
    private var text = ""
    private var collectingAddress = false

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    func result() -> LoggerDefinitions {
        LoggerDefinitions(sourceURL: sourceURL, version: version, standard: standard, switches: switches,
                          calculated: calculated, extended: extended, codes: codes)
    }

    static func hex(_ s: String?) -> UInt32? {
        guard var s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
        return UInt32(s, radix: 16)
    }

    func startElement(_ name: String, attributes a: [String: String]) {
        if name == "logger" { version = a["version"] }
        if name == "protocol" {
            inSSM = a["id"] == "SSM"
            if inSSM { sawSSM = true }
            return
        }
        guard inSSM else { return }

        switch name {
        case "parameter", "ecuparam":
            currentIsExtended = name == "ecuparam"
            addressesByECU = [:]
            ecuIDs = []
            current = ParameterDefinition(
                id: a["id"] ?? UUID().uuidString,
                name: a["name"] ?? a["id"] ?? "?",
                description: a["desc"] ?? "",
                kind: currentIsExtended ? .extended : .standard,
                capabilityByte: a["ecubyteindex"].flatMap { Int($0) },
                capabilityBit: a["ecubit"].flatMap { Int($0) },
                conversions: [],
                target: a["target"].flatMap { Int($0) } ?? 1
            )
        case "ecu":
            ecuIDs = (a["id"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        case "address":
            addressLength = a["length"].flatMap { Int($0) } ?? 1
            addressBit = a["bit"].flatMap { Int($0) }
            text = ""
            collectingAddress = true
        case "ref":
            if let dep = a["parameter"] { current?.dependencies.append(dep) }
        case "conversion":
            guard current != nil else { return }
            let conversion = Conversion(
                units: a["units"] ?? "",
                expression: a["expr"] ?? "x",
                format: a["format"] ?? "0.00",
                storageType: a["storagetype"].flatMap { StorageType(rawValue: $0.lowercased()) },
                littleEndian: a["endian"]?.lowercased() == "little",
                gaugeMin: a["gauge_min"].flatMap(Double.init),
                gaugeMax: a["gauge_max"].flatMap(Double.init),
                gaugeStep: a["gauge_step"].flatMap(Double.init)
            )
            current?.conversions.append(conversion)
        case "switch":
            guard let address = Self.hex(a["byte"]), let bit = a["bit"].flatMap({ Int($0) }) else { return }
            switches.append(ParameterDefinition(
                id: a["id"] ?? "S?",
                name: a["name"] ?? "Switch",
                description: a["desc"] ?? "",
                kind: .switchBit,
                addresses: [address],
                bit: bit,
                capabilityByte: a["ecubyteindex"].flatMap { Int($0) },
                // RomRaider uses the switch's data bit as its capability bit too.
                capabilityBit: bit,
                conversions: [Conversion(units: "on/off", expression: "x", format: "0")],
                target: a["target"].flatMap { Int($0) } ?? 1
            ))
        case "dtcode":
            guard let tmp = Self.hex(a["tmpaddr"]), let mem = Self.hex(a["memaddr"]),
                  let bit = a["bit"].flatMap({ Int($0) }) else { return }
            codes.append(DiagnosticCodeDefinition(id: a["id"] ?? "D?", name: a["name"] ?? "?",
                                                  currentAddress: tmp, memorizedAddress: mem, bit: bit))
        default:
            break
        }
    }

    /// v370 has 4-byte parameters (e.g. E36 Target Boost) whose first conversion lacks
    /// storagetype="float" while the others have it; reading those as integers gives nonsense.
    static func fixMissingFloat(_ conversions: [Conversion], byteCount: Int) -> [Conversion] {
        guard byteCount == 4, conversions.contains(where: { $0.storageType == .float }) else { return conversions }
        return conversions.map { c in
            var c = c
            if c.storageType == nil { c.storageType = .float }
            return c
        }
    }

    func characters(_ string: String) {
        if collectingAddress { text += string }
    }

    func endElement(_ name: String) {
        if name == "protocol" {
            inSSM = false
            return
        }
        guard inSSM else { return }
        switch name {
        case "address":
            collectingAddress = false
            guard let start = Self.hex(text) else { return }
            let addresses = (0..<max(1, addressLength)).map { start + UInt32($0) }
            if currentIsExtended {
                for id in ecuIDs { addressesByECU[id, default: []].append(contentsOf: addresses) }
            } else {
                current?.addresses.append(contentsOf: addresses)
                if let addressBit { current?.bit = addressBit }
            }
        case "parameter":
            guard var p = current else { return }
            p.conversions = Self.fixMissingFloat(p.conversions, byteCount: p.addresses.count)
            if !p.dependencies.isEmpty {
                p.kind = .calculated
                calculated.append(p)
            } else if !p.addresses.isEmpty {
                standard.append(p)
            }
            current = nil
        case "ecuparam":
            guard var p = current, !addressesByECU.isEmpty else { current = nil; return }
            p.conversions = Self.fixMissingFloat(p.conversions, byteCount: addressesByECU.values.first?.count ?? 0)
            extended.append(.init(base: p, addressesByECU: addressesByECU))
            current = nil
        default:
            break
        }
    }
}
