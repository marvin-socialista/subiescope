import Foundation

/// An AEM wideband air/fuel gauge, read through its serial output next to the car's own values.
///
/// The gauge sends what its display shows as plain text, about ten times a second, and listens to
/// nothing. The formats are the ones RomRaider's AEM plugins read (GPLv2); AEM's X-Series manual
/// describes the first:
/// - UEGO gauges (30-4100, 30-4110) and the X-Series (30-0300): 9600 baud, "14.7\r\n". AFR or
///   lambda, whichever the display is set to.
/// - UEGO controllers with a lambda output: 19200 baud, "1.000\tReady\tNo-errors\r".
public enum AEMWideband {
    public static let parameterID = "AEMWB"

    /// Speeds to listen at, the common one first.
    public static let baudRates: [UInt32] = [9600, 19200]

    /// RomRaider's petrol ratio, the same one behind the "AFR" unit of the car's own A/F sensor. The
    /// X-Series itself uses 14.65: that only shows in the third decimal of lambda, and the AFR shown
    /// here stays exactly what the gauge shows.
    public static let stoich = 14.7

    /// The gauge as a parameter to log. Its values are lambda before conversion.
    public static let definition = ParameterDefinition(
        id: parameterID, name: "AEM Wideband A/F",
        description: "The mixture measured by your AEM wideband gauge. 14.7 AFR (lambda 1.00) is a perfect mixture, lower is rich, higher is lean.",
        kind: .external,
        conversions: [
            Conversion(units: "AFR", expression: "x*14.7", format: "0.00", gaugeMin: 10, gaugeMax: 20),
            Conversion(units: "Lambda", expression: "x", format: "0.00", gaugeMin: 0.68, gaugeMax: 1.36),
        ])

    /// The reading on one line of the gauge's output, as lambda. nil for anything that is not a
    /// reading: an empty line, noise, or the dashes the gauge shows when the mixture is out of range.
    public static func lambda(fromLine line: String) -> Double? {
        // The reading comes first; the lambda output adds status words after a tab.
        guard let field = line.split(separator: "\t", omittingEmptySubsequences: false).first else { return nil }
        let text = field.trimmingCharacters(in: .whitespaces)
        // Digits and a decimal point only: Double() would also take "nan", "inf" and hex numbers.
        guard !text.isEmpty, text.allSatisfy({ ("0"..."9").contains($0) || $0 == "." }), let value = Double(text) else { return nil }
        switch value {
        case 0.3...2.5: return value             // lambda: the gauge shows 0.55 to 2.00
        case 5...30: return value / stoich       // petrol AFR: the gauge shows 8.0 to 20.0
        default: return nil
        }
    }

    /// A lambda reading in the units of one of the definition's conversions.
    public static func value(_ lambda: Double, in conversion: Conversion) -> Double {
        conversion.units == "Lambda" ? lambda : lambda * stoich
    }
}
