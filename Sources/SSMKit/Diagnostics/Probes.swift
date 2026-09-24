import Foundation

/// Every value the recipes use, with the parameter name it maps to and its
/// canonical units. The demo ECU uses the same table to fill parameters.
public enum Probes {
    public static let rpm = Probe("rpm", "Engine Speed", units: "rpm", label: "Engine speed")
    public static let coolant = Probe("coolant", "Coolant Temperature", units: "C", label: "Coolant")
    public static let iat = Probe("iat", "Intake Air Temperature", units: "C", label: "Intake air")
    public static let lambda = Probe("lambda", "A/F Sensor #1", units: "Lambda", label: "Front A/F sensor")
    public static let afc = Probe("afc", "A/F Correction #1", units: "%", label: "A/F correction (short term)")
    public static let afl = Probe("afl", "A/F Learning #1", units: "%", label: "A/F learning (long term)")
    public static let rearO2 = Probe("rearO2", "Rear O2 Sensor", units: "V", label: "Rear O2 sensor")
    public static let rearHeater = Probe("rearHeater", "Rear O2 Heater Current", units: "A", label: "Rear O2 heater")
    public static let afHeater = Probe("afHeater", "A/F Sensor #1 Heater Current", units: "A", label: "A/F sensor heater")
    public static let maf = Probe("maf", "Mass Airflow", units: "g/s", label: "Mass airflow")
    public static let mafV = Probe("mafV", "Mass Airflow Sensor Voltage", units: "V", label: "MAF signal voltage")
    public static let map = Probe("map", "Manifold Absolute Pressure", units: "kPa", label: "Manifold pressure (absolute)")
    public static let mrp = Probe("mrp", "Manifold Relative Pressure", units: "kPa", label: "Boost")
    public static let target = Probe("target", "Target Boost", units: "kPa relative", label: "Target boost")
    public static let wgdc = Probe("wgdc", "Primary Wastegate Duty Cycle", units: "%", label: "Wastegate duty")
    public static let throttle = Probe("throttle", "Throttle Opening Angle", units: "%", label: "Throttle")
    public static let pedal = Probe("pedal", "Accelerator Pedal Angle", units: "%", label: "Accelerator pedal")
    public static let battery = Probe("battery", "Battery Voltage", units: "V", label: "Battery voltage")
    public static let speed = Probe("speed", "Vehicle Speed", units: "km/h", label: "Speed")
    public static let fbkc = Probe("fbkc", "Feedback Knock Correction", units: "degrees", label: "Feedback knock correction")
    public static let flkc = Probe("flkc", "Fine Learning Knock Correction", units: "degrees", label: "Fine learning knock")
    public static let iam = Probe("iam", "IAM", units: "multiplier", label: "IAM")
    public static let timing = Probe("timing", "Ignition Total Timing", units: "degrees", label: "Ignition timing")
    public static let ipw = Probe("ipw", "Fuel Injector #1 Pulse Width", units: "ms", label: "Injector pulse width")
    public static let load = Probe("load", "Engine Load (Relative)", units: "%", label: "Engine load")
    public static let rough1 = Probe("rough1", "Roughness Monitor Cylinder #1", units: "misfire count", label: "Misfires cyl. 1")
    public static let rough2 = Probe("rough2", "Roughness Monitor Cylinder #2", units: "misfire count", label: "Misfires cyl. 2")
    public static let rough3 = Probe("rough3", "Roughness Monitor Cylinder #3", units: "misfire count", label: "Misfires cyl. 3")
    public static let rough4 = Probe("rough4", "Roughness Monitor Cylinder #4", units: "misfire count", label: "Misfires cyl. 4")
    public static let isc = Probe("isc", "Idle Speed Control Valve Duty Ratio", units: "%", label: "Idle control duty")
    public static let avcsInR = Probe("avcsInR", "Intake VVT Advance Angle Right", units: "degrees", label: "Intake AVCS right")
    public static let avcsInL = Probe("avcsInL", "Intake VVT Advance Angle Left", units: "degrees", label: "Intake AVCS left")
    public static let avcsExR = Probe("avcsExR", "Exhaust VVT Advance Angle Right", units: "degrees", label: "Exhaust AVCS right")
    public static let avcsExL = Probe("avcsExL", "Exhaust VVT Advance Angle Left", units: "degrees", label: "Exhaust AVCS left")
    public static let ocvR = Probe("ocvR", "Intake OCV Duty Right", units: "%", label: "Intake OCV duty right")
    public static let ocvL = Probe("ocvL", "Intake OCV Duty Left", units: "%", label: "Intake OCV duty left")
    public static let fan1 = Probe("fan1", "Radiator Fan Relay #1", units: "on/off", label: "Radiator fan relay 1")
    public static let fan2 = Probe("fan2", "Radiator Fan Relay #2", units: "on/off", label: "Radiator fan relay 2")
    public static let fanDuty = Probe("fanDuty", "Radiator Fan Control", units: "%", label: "Radiator fan control")
    public static let ac = Probe("ac", "Air Conditioning Switch", units: "on/off", label: "A/C switch")

    public static let all: [Probe] = [
        rpm, coolant, iat, lambda, afc, afl, rearO2, rearHeater, afHeater, maf, mafV, map, mrp, target, wgdc,
        throttle, pedal, battery, speed, fbkc, flkc, iam, timing, ipw, load, rough1, rough2, rough3, rough4, isc,
        avcsInR, avcsInL, avcsExR, avcsExL, ocvR, ocvL, fan1, fan2, fanDuty, ac,
    ]

    /// Same probe, but the recipe still runs without it.
    public static func optional(_ p: Probe) -> Probe {
        var q = p
        q.required = false
        return q
    }
}
