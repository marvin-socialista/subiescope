import Foundation

/// A standard OBD-II mode 01 value (SAE J1979). Every car sold since about 2008 has these.
///
/// Parameter names match the SSM ones ("Engine Speed", "Coolant Temperature") so
/// dashboards, CSV logs and the default gauges look the same in both modes.
public struct OBDPID: Sendable {
    public var pid: UInt8
    public var name: String
    public var description: String
    /// Data bytes in the reply. The value is read from the first `valueBytes` of them.
    public var dataBytes: Int
    public var valueBytes: Int
    /// Expressions use `x`: the reply byte A, or 256*A+B for two byte values.
    public var conversions: [Conversion]

    public var id: String { OBDParameters.id(forPID: pid) }

    func raw(from data: [UInt8]) -> Double? {
        guard data.count >= valueBytes else { return nil }
        return data.prefix(valueBytes).reduce(0.0) { $0 * 256 + Double($1) }
    }
}

public enum OBDParameters {
    public static func id(forPID pid: UInt8) -> String { String(format: "OBD%02X", pid) }

    /// Values that change slowly (temperatures, voltage, fuel level). They are read every few
    /// rounds instead of every round, which leaves more time for the ones that move fast.
    public static let slowPIDs: Set<UInt8> = [0x05, 0x0F, 0x42, 0x5C, 0x46, 0x33, 0x2F, 0x1F, 0x3C, 0x0A]

    /// The calculated boost value, and the ID of the parameter it is computed from.
    public static let boostID = "OBDBOOST"

    private static func c(_ units: String, _ expression: String, _ format: String = "0.0",
                          min: Double? = nil, max: Double? = nil) -> Conversion {
        Conversion(units: units, expression: expression, format: format, gaugeMin: min, gaugeMax: max)
    }

    // swiftlint:disable line_length
    public static let catalog: [OBDPID] = [
        OBDPID(pid: 0x04, name: "Calculated Engine Load", description: "How hard the engine is working, as a percentage of its maximum.", dataBytes: 1, valueBytes: 1,
               conversions: [c("%", "x*100/255", min: 0, max: 100)]),
        OBDPID(pid: 0x05, name: "Coolant Temperature", description: "Engine coolant temperature.", dataBytes: 1, valueBytes: 1,
               conversions: [c("C", "x-40", "0", min: -40, max: 130), c("F", "(x-40)*1.8+32", "0", min: -40, max: 266)]),
        OBDPID(pid: 0x06, name: "Short Term Fuel Trim Bank 1", description: "How much fuel the ECU adds or removes right now to keep the mixture right. Near 0 is good.", dataBytes: 1, valueBytes: 1,
               conversions: [c("%", "(x-128)*100/128", min: -25, max: 25)]),
        OBDPID(pid: 0x07, name: "Long Term Fuel Trim Bank 1", description: "What the ECU has learned about the mixture over time. Near 0 is good; beyond 10% points at a leak or a sensor.", dataBytes: 1, valueBytes: 1,
               conversions: [c("%", "(x-128)*100/128", min: -25, max: 25)]),
        OBDPID(pid: 0x08, name: "Short Term Fuel Trim Bank 2", description: "Short term fuel trim for the second cylinder bank.", dataBytes: 1, valueBytes: 1,
               conversions: [c("%", "(x-128)*100/128", min: -25, max: 25)]),
        OBDPID(pid: 0x09, name: "Long Term Fuel Trim Bank 2", description: "Long term fuel trim for the second cylinder bank.", dataBytes: 1, valueBytes: 1,
               conversions: [c("%", "(x-128)*100/128", min: -25, max: 25)]),
        OBDPID(pid: 0x0A, name: "Fuel Pressure", description: "Fuel pressure (gauge).", dataBytes: 1, valueBytes: 1,
               conversions: [c("kPa", "x*3", "0", min: 0, max: 765), c("psi", "x*3*0.145038", "0", min: 0, max: 111)]),
        OBDPID(pid: 0x0B, name: "Manifold Absolute Pressure", description: "Pressure in the intake manifold. About 100 kPa with the engine off, lower at idle, above 100 under boost.", dataBytes: 1, valueBytes: 1,
               conversions: [c("kPa", "x", "0", min: 0, max: 255), c("psi", "x*0.145038", "0.0", min: 0, max: 37)]),
        OBDPID(pid: 0x0C, name: "Engine Speed", description: "Engine speed.", dataBytes: 2, valueBytes: 2,
               conversions: [c("rpm", "x/4", "0", min: 0, max: 8000)]),
        OBDPID(pid: 0x0D, name: "Vehicle Speed", description: "Road speed.", dataBytes: 1, valueBytes: 1,
               conversions: [c("km/h", "x", "0", min: 0, max: 260), c("mph", "x*0.621371", "0", min: 0, max: 160)]),
        OBDPID(pid: 0x0E, name: "Ignition Total Timing", description: "Ignition timing in degrees before top dead centre.", dataBytes: 1, valueBytes: 1,
               conversions: [c("degrees", "x/2-64", min: -64, max: 63)]),
        OBDPID(pid: 0x0F, name: "Intake Air Temperature", description: "Temperature of the air going into the engine.", dataBytes: 1, valueBytes: 1,
               conversions: [c("C", "x-40", "0", min: -40, max: 100), c("F", "(x-40)*1.8+32", "0", min: -40, max: 212)]),
        OBDPID(pid: 0x10, name: "Mass Airflow", description: "Air flowing into the engine, measured by the MAF sensor.", dataBytes: 2, valueBytes: 2,
               conversions: [c("g/s", "x/100", "0.0", min: 0, max: 400), c("lb/min", "x/100*0.132277", "0.00", min: 0, max: 53)]),
        OBDPID(pid: 0x11, name: "Throttle Opening Angle", description: "How far the throttle plate is open.", dataBytes: 1, valueBytes: 1,
               conversions: [c("%", "x*100/255", min: 0, max: 100)]),
        OBDPID(pid: 0x14, name: "Front O2 Sensor Voltage", description: "Upstream oxygen sensor (bank 1) as a voltage. Swings between about 0.1 and 0.9 V on a narrow band sensor.", dataBytes: 2, valueBytes: 1,
               conversions: [c("V", "x/200", "0.00", min: 0, max: 1.3)]),
        OBDPID(pid: 0x15, name: "Rear O2 Sensor", description: "Downstream oxygen sensor (bank 1). It should stay fairly steady when the catalytic converter is healthy.", dataBytes: 2, valueBytes: 1,
               conversions: [c("V", "x/200", "0.00", min: 0, max: 1.3)]),
        OBDPID(pid: 0x1F, name: "Engine Run Time", description: "Seconds since the engine started.", dataBytes: 2, valueBytes: 2,
               conversions: [c("s", "x", "0", min: 0, max: 3600)]),
        OBDPID(pid: 0x22, name: "Fuel Rail Pressure (Relative)", description: "Fuel rail pressure relative to the manifold.", dataBytes: 2, valueBytes: 2,
               conversions: [c("kPa", "x*0.079", "0", min: 0, max: 5177)]),
        OBDPID(pid: 0x23, name: "Fuel Rail Pressure (Direct Injection)", description: "Fuel rail pressure on a direct injection engine.", dataBytes: 2, valueBytes: 2,
               conversions: [c("kPa", "x*10", "0", min: 0, max: 20000), c("psi", "x*10*0.145038", "0", min: 0, max: 2900)]),
        OBDPID(pid: 0x24, name: "A/F Sensor #1", description: "Wideband air/fuel sensor (bank 1) as lambda. 1.00 is a perfect mixture, below 1 is rich, above 1 is lean.", dataBytes: 4, valueBytes: 2,
               conversions: [c("Lambda", "x*2/65536", "0.00", min: 0.6, max: 1.6)]),
        OBDPID(pid: 0x2C, name: "Commanded EGR", description: "How far the ECU has opened the exhaust gas recirculation valve.", dataBytes: 1, valueBytes: 1,
               conversions: [c("%", "x*100/255", min: 0, max: 100)]),
        OBDPID(pid: 0x2E, name: "Commanded Evaporative Purge", description: "How much the ECU is purging the fuel vapour canister.", dataBytes: 1, valueBytes: 1,
               conversions: [c("%", "x*100/255", min: 0, max: 100)]),
        OBDPID(pid: 0x2F, name: "Fuel Level", description: "Fuel tank level.", dataBytes: 1, valueBytes: 1,
               conversions: [c("%", "x*100/255", "0", min: 0, max: 100)]),
        OBDPID(pid: 0x33, name: "Barometric Pressure", description: "Outside air pressure.", dataBytes: 1, valueBytes: 1,
               conversions: [c("kPa", "x", "0", min: 60, max: 110)]),
        OBDPID(pid: 0x3C, name: "Catalyst Temperature", description: "Temperature of the catalytic converter (bank 1, before the second sensor).", dataBytes: 2, valueBytes: 2,
               conversions: [c("C", "x/10-40", "0", min: 0, max: 900), c("F", "(x/10-40)*1.8+32", "0", min: 32, max: 1650)]),
        OBDPID(pid: 0x42, name: "Battery Voltage", description: "Voltage at the engine control unit. About 12.5 V with the engine off and 13.8 to 14.5 V when the alternator charges.", dataBytes: 2, valueBytes: 2,
               conversions: [c("V", "x/1000", "0.0", min: 8, max: 16)]),
        OBDPID(pid: 0x43, name: "Absolute Engine Load", description: "Engine load relative to the air the engine can take in at full throttle.", dataBytes: 2, valueBytes: 2,
               conversions: [c("%", "x*100/255", "0", min: 0, max: 200)]),
        OBDPID(pid: 0x44, name: "Commanded Lambda", description: "The mixture the ECU is aiming for, as lambda.", dataBytes: 2, valueBytes: 2,
               conversions: [c("Lambda", "x*2/65536", "0.00", min: 0.6, max: 1.6)]),
        OBDPID(pid: 0x45, name: "Relative Throttle Position", description: "Throttle opening relative to its idle position.", dataBytes: 1, valueBytes: 1,
               conversions: [c("%", "x*100/255", min: 0, max: 100)]),
        OBDPID(pid: 0x46, name: "Ambient Air Temperature", description: "Outside air temperature.", dataBytes: 1, valueBytes: 1,
               conversions: [c("C", "x-40", "0", min: -40, max: 60), c("F", "(x-40)*1.8+32", "0", min: -40, max: 140)]),
        OBDPID(pid: 0x49, name: "Accelerator Pedal Angle", description: "How far the accelerator pedal is pressed.", dataBytes: 1, valueBytes: 1,
               conversions: [c("%", "x*100/255", min: 0, max: 100)]),
        OBDPID(pid: 0x4C, name: "Commanded Throttle Actuator", description: "Where the ECU wants the electronic throttle to be.", dataBytes: 1, valueBytes: 1,
               conversions: [c("%", "x*100/255", min: 0, max: 100)]),
        OBDPID(pid: 0x5C, name: "Engine Oil Temperature", description: "Engine oil temperature.", dataBytes: 1, valueBytes: 1,
               conversions: [c("C", "x-40", "0", min: -40, max: 150), c("F", "(x-40)*1.8+32", "0", min: -40, max: 302)]),
        OBDPID(pid: 0x5E, name: "Engine Fuel Rate", description: "Fuel the engine is using right now.", dataBytes: 2, valueBytes: 2,
               conversions: [c("L/h", "x/20", "0.0", min: 0, max: 100), c("gal/hr", "x/20*0.264172", "0.0", min: 0, max: 26)]),
    ]
    // swiftlint:enable line_length

    public static let byPID: [UInt8: OBDPID] = Dictionary(uniqueKeysWithValues: catalog.map { ($0.pid, $0) })

    /// Boost is not an OBD-II value, but the manifold pressure minus the outside pressure is what a boost gauge shows.
    static let boostDefinition = ParameterDefinition(
        id: boostID, name: "Manifold Relative Pressure",
        description: "Boost (positive) or vacuum (negative): manifold pressure minus the outside air pressure of 101.3 kPa.",
        kind: .calculated,
        conversions: [
            Conversion(units: "kPa relative", expression: "[\(id(forPID: 0x0B)):kPa]-101.3", format: "0", gaugeMin: -100, gaugeMax: 200),
            Conversion(units: "psi relative", expression: "([\(id(forPID: 0x0B)):kPa]-101.3)*0.145038", format: "0.0", gaugeMin: -15, gaugeMax: 30),
        ],
        dependencies: [id(forPID: 0x0B)])

    public static func definition(for pid: OBDPID) -> ParameterDefinition {
        ParameterDefinition(id: pid.id, name: pid.name, description: pid.description, kind: .standard,
                            conversions: pid.conversions, dependencies: [])
    }

    /// The parameters a car offers, given the PIDs it says it supports.
    public static func parameters(supported: Set<UInt8>) -> [ParameterDefinition] {
        var list = catalog.filter { supported.contains($0.pid) }.map(definition(for:))
        if supported.contains(0x0B) { list.append(boostDefinition) }
        return list
    }

    /// What every OBD-II car can do, for browsing the parameter list while not connected.
    public static var allParameters: [ParameterDefinition] {
        parameters(supported: Set(catalog.map(\.pid)))
    }

    /// Decodes a "supported PIDs" bitmask reply (PIDs 00, 20, 40 ...): the PIDs
    /// `base+1 ... base+32`, most significant bit first.
    public static func supportedPIDs(base: UInt8, mask: [UInt8]) -> Set<UInt8> {
        var result: Set<UInt8> = []
        for (byteIndex, byte) in mask.prefix(4).enumerated() {
            for bit in 0..<8 where byte & (0x80 >> bit) != 0 {
                let pid = Int(base) + byteIndex * 8 + bit + 1
                if pid <= 0xFF { result.insert(UInt8(pid)) }
            }
        }
        return result
    }
}
