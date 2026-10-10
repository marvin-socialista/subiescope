import Foundation

/// Engine control unit extras, with addresses and procedures from FreeSSM.
public enum EngineDiagnostics {
    /// Engine type from byte 3 of the SSM system ID (when byte 2 is 0x10).
    public static func engineType(systemID: [UInt8]) -> String? {
        guard systemID.count == 3, systemID[1] == 0x10 else { return nil }
        let table: [UInt8: String] = [
            0x01: "2.5L SOHC", 0x02: "2.5L SOHC", 0x03: "2.2L SOHC", 0x04: "2.2L SOHC",
            0x05: "1.5L SOHC", 0x06: "1.6L SOHC", 0x07: "1.8L SOHC", 0x08: "2.0L SOHC",
            0x09: "2.0L DOHC", 0x0A: "2.5L DOHC", 0x0B: "2.0L DOHC Turbo", 0x0C: "2.0L DOHC Turbo",
            0x0D: "2.0L DOHC Turbo", 0x0E: "3.0L DOHC", 0x0F: "2.0L DOHC Turbo", 0x10: "2.5L DOHC",
            0x11: "2.5L DOHC Turbo", 0x12: "3.0L DOHC", 0x13: "1.5L DOHC", 0x14: "2.0L DOHC Turbo Diesel",
            0x15: "3.6L DOHC",
        ]
        return table[systemID[2]]
    }

    /// The 2008 and 2009 Impreza WRX STI (GRB) by ECU ID, named by hand, from the ECUFlash definitions.
    private static let grbECUs: [String: String] = [
        "5A04784107": "2008 Impreza WRX STI GRB, JDM (AZ1G300F)",
        "5A04784207": "2008 Impreza WRX STI GRB, JDM (AZ1G301F)",
        "6904784007": "2009 Impreza WRX STI GRB, JDM (AZ1G500F)",
        "5A42784107": "2008 Impreza WRX STI, EDM (AZ1G201G)",
        "5A42784207": "2008 Impreza WRX STI, EDM (AZ1G202G)",
        "5A4278A107": "2008 Impreza WRX STI, EDM (Z1G20000)",
        "5A12784107": "2008 Impreza WRX STI, USDM (AZ1G201I)",
        "6912783007": "2008 Impreza WRX STI, USDM (AZ1G202I)",
        "5AA2784007": "2008 Impreza WRX STI, SADM (AZ1G200J)",
    ]

    /// The car behind every ECU ID in `KnownECU.library`, as one line of text.
    public static let knownECUs: [String: String] = {
        KnownECU.library.compactMapValues(KnownECU.description(of:)).merging(grbECUs) { _, byHand in byHand }
    }()

    // MARK: VIN

    /// VIN support flag: flagbyte 37 bit 0 (RomRaider index 8 + 36).
    public static func supportsVIN(_ identity: ECUIdentity) -> Bool {
        identity.supports(byteIndex: 44, bit: 0)
    }

    /// Reads the VIN: 0xDA-0xDC hold a pointer to 17 ASCII characters.
    /// Returns nil when the ECU has no VIN programmed.
    public static func readVIN(with client: SSMClient) throws -> String? {
        let pointerBytes = try client.read(addresses: [0xDA, 0xDB, 0xDC])
        let pointer = UInt32(pointerBytes[0]) << 16 | UInt32(pointerBytes[1]) << 8 | UInt32(pointerBytes[2])
        let bytes = try client.read(addresses: (0..<17).map { pointer + UInt32($0) })
        let vin = String(decoding: bytes, as: UTF8.self)
        let valid = vin.count == 17 && vin.enumerated().allSatisfy { index, c in
            index < 11 ? (c.isASCII && (c.isNumber || c.isUppercase)) : c.isNumber
        }
        return valid ? vin : nil
    }

    // MARK: Status flags

    public struct Status: Equatable, Sendable {
        /// The green test mode connectors are joined.
        public var testMode: Bool?
        /// The ECU's self check ("D-Check") has not completed since the last clear.
        public var dCheckPending: Bool?
        public var ignitionOn: Bool?
    }

    public static func readStatus(with client: SSMClient, identity: ECUIdentity) throws -> Status {
        let bytes = try client.read(addresses: [0x61, 0x62])
        return Status(
            testMode: identity.supports(byteIndex: 8 + 11, bit: 5) ? bytes[0] & 0x20 != 0 : nil,
            dCheckPending: identity.supports(byteIndex: 8 + 11, bit: 7) ? bytes[0] & 0x80 != 0 : nil,
            ignitionOn: identity.supports(byteIndex: 8 + 12, bit: 3) ? bytes[1] & 0x08 != 0 : nil
        )
    }
}

/// "Clear memory" for the engine ECU: erases stored trouble codes and resets
/// learned values (fuel trims, IAM, fine knock learning) to their defaults.
public enum ClearMemory {
    public static let address: UInt32 = 0x000060
    public static let value: UInt8 = 0x40

    public static func perform(with client: SSMClient) throws {
        try client.write(address: address, value: value)
    }
}

/// Result of reading the trouble code flags.
public struct TroubleCodeReport: Sendable {
    public var current: [DiagnosticCodeDefinition]
    public var memorized: [DiagnosticCodeDefinition]

    /// Reads every flag byte used by `definitions` and returns the codes whose bit is set.
    /// Codes whose flag bytes both read 0xFF are treated as unsupported, as RomRaider does.
    public static func read(with client: SSMClient, definitions: [DiagnosticCodeDefinition]) throws -> TroubleCodeReport {
        let addresses = Array(Set(definitions.flatMap { [$0.currentAddress, $0.memorizedAddress] })).sorted()
        let bytes = try client.read(addresses: addresses)
        let memory = Dictionary(uniqueKeysWithValues: zip(addresses, bytes))
        var current: [DiagnosticCodeDefinition] = []
        var memorized: [DiagnosticCodeDefinition] = []
        for d in definitions {
            let tmp = memory[d.currentAddress] ?? 0
            let mem = memory[d.memorizedAddress] ?? 0
            if tmp == 0xFF && mem == 0xFF { continue }
            let mask = UInt8(1) << UInt8(d.bit)
            if tmp & mask != 0 { current.append(d) }
            if mem & mask != 0 { memorized.append(d) }
        }
        return TroubleCodeReport(current: current, memorized: memorized)
    }
}
