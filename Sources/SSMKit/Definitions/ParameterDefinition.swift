import Foundation

public enum StorageType: String, Sendable {
    case uint8, int8, uint16, int16, uint32, int32, float

    static func defaultStorage(forLength length: Int) -> StorageType {
        switch length {
        case 2: return .uint16
        case 4: return .uint32
        default: return .uint8
        }
    }

    var signed: StorageType {
        switch self {
        case .uint8: return .int8
        case .uint16: return .int16
        case .uint32: return .int32
        default: return self
        }
    }

    public var byteCount: Int {
        switch self {
        case .uint8, .int8: return 1
        case .uint16, .int16: return 2
        case .uint32, .int32, .float: return 4
        }
    }

    /// Interprets big-endian (or little-endian) bytes as a number.
    public func decode(_ bytes: ArraySlice<UInt8>, littleEndian: Bool = false) -> Double {
        let ordered = littleEndian ? Array(bytes.reversed()) : Array(bytes)
        var raw: UInt32 = 0
        for b in ordered.prefix(byteCount) { raw = raw << 8 | UInt32(b) }
        switch self {
        case .uint8: return Double(UInt8(truncatingIfNeeded: raw))
        case .int8: return Double(Int8(bitPattern: UInt8(truncatingIfNeeded: raw)))
        case .uint16: return Double(UInt16(truncatingIfNeeded: raw))
        case .int16: return Double(Int16(bitPattern: UInt16(truncatingIfNeeded: raw)))
        case .uint32: return Double(raw)
        case .int32: return Double(Int32(bitPattern: raw))
        case .float: return Double(Float(bitPattern: raw))
        }
    }
}

public struct Conversion: Sendable, Hashable {
    public var units: String
    public var expression: String
    /// Java DecimalFormat pattern from the definition, e.g. "0.00".
    public var format: String
    public var storageType: StorageType?
    public var littleEndian: Bool
    public var gaugeMin: Double?
    public var gaugeMax: Double?
    public var gaugeStep: Double?

    public init(units: String, expression: String, format: String = "0.00", storageType: StorageType? = nil,
                littleEndian: Bool = false, gaugeMin: Double? = nil, gaugeMax: Double? = nil, gaugeStep: Double? = nil) {
        self.units = units
        self.expression = expression
        self.format = format
        self.storageType = storageType
        self.littleEndian = littleEndian
        self.gaugeMin = gaugeMin
        self.gaugeMax = gaugeMax
        self.gaugeStep = gaugeStep
    }

    /// Number of decimals implied by the DecimalFormat pattern.
    public var decimals: Int {
        guard let dot = format.firstIndex(of: ".") else { return 0 }
        return format[format.index(after: dot)...].prefix { $0 == "0" || $0 == "#" }.count
    }

    public func formatted(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        return String(format: "%.\(decimals)f", value)
    }
}

public enum ParameterKind: String, Sendable, CaseIterable {
    /// Standard SSM parameter, supported when a capability bit is set.
    case standard
    /// ECU specific RAM address (RomRaider "extended" parameter).
    case extended
    /// On/off state read from one bit.
    case switchBit
    /// Computed from other parameters.
    case calculated
    /// Not read from the car: a separate gauge with its own connection (a wideband).
    case external
}

/// A loggable value, independent of where the definition came from.
public struct ParameterDefinition: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var description: String
    public var kind: ParameterKind
    /// Addresses to read, in byte order. Empty for calculated parameters.
    public var addresses: [UInt32]
    /// Bit number for switches.
    public var bit: Int?
    /// Capability flag that must be set for standard parameters and switches.
    public var capabilityByte: Int?
    public var capabilityBit: Int?
    public var conversions: [Conversion]
    /// For calculated parameters: IDs this one is computed from.
    public var dependencies: [String]
    /// Which control unit the parameter lives in (engine or transmission).
    public var target: Int

    public init(id: String, name: String, description: String = "", kind: ParameterKind, addresses: [UInt32] = [],
                bit: Int? = nil, capabilityByte: Int? = nil, capabilityBit: Int? = nil,
                conversions: [Conversion], dependencies: [String] = [], target: Int = 1) {
        self.id = id
        self.name = name
        self.description = description
        self.kind = kind
        self.addresses = addresses
        self.bit = bit
        self.capabilityByte = capabilityByte
        self.capabilityBit = capabilityBit
        self.conversions = conversions
        self.dependencies = dependencies
        self.target = target
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Raw numeric value from the bytes read at `addresses`.
    public func rawValue(from bytes: ArraySlice<UInt8>, conversion: Conversion) -> Double {
        if let bit {
            // Switches, and parameters whose <address> carries a bit attribute.
            let storage = StorageType.defaultStorage(forLength: bytes.count)
            let word = UInt32(storage.decode(bytes))
            return (word >> UInt32(bit)) & 1 == 1 ? 1 : 0
        }
        // RomRaider: the storage type only picks signed/unsigned/float; width comes from the byte count.
        let width = StorageType.defaultStorage(forLength: bytes.count)
        let storage: StorageType
        switch conversion.storageType {
        case .float? where bytes.count == 4: storage = .float
        case .int8?, .int16?, .int32?: storage = width.signed
        default: storage = width
        }
        return storage.decode(bytes, littleEndian: conversion.littleEndian)
    }
}

/// The subset of a definition file that applies to one connected ECU.
public struct ECUParameterSet: Sendable {
    public var parameters: [ParameterDefinition]
    public var diagnosticCodes: [DiagnosticCodeDefinition]
}

/// One bit-mapped trouble code as described in the logger definitions.
public struct DiagnosticCodeDefinition: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    /// Address of the "current" (temporary) flag byte.
    public var currentAddress: UInt32
    /// Address of the "memorized" (stored) flag byte.
    public var memorizedAddress: UInt32
    public var bit: Int

    public init(id: String, name: String, currentAddress: UInt32, memorizedAddress: UInt32, bit: Int) {
        self.id = id
        self.name = name
        self.currentAddress = currentAddress
        self.memorizedAddress = memorizedAddress
        self.bit = bit
    }

    /// "P0420" from names such as "P0420 CATALYST SYSTEM EFFICIENCY BELOW THRESHOLD".
    public var code: String {
        let first = name.split(separator: " ", maxSplits: 1).first.map(String.init) ?? name
        return first.range(of: #"^[PBCU][0-9A-F]{4}$"#, options: .regularExpression) != nil ? first : name
    }

    public var summary: String {
        guard code != name else { return "" }
        var rest = String(name.dropFirst(code.count)).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("-") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return rest
    }
}
