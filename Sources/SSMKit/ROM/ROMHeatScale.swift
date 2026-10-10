import Foundation

/// The colour a number of a map is shown in: RomRaider's rainbow, from blue for the lowest value of
/// the map through green and yellow to red for the highest. Both fronts colour their cells with this
/// one scale, so a map looks the same in the Mac app and in the Windows app.
///
/// The colours are the ones of the approved design: the hue runs from 250 degrees down to 0, at 84 %
/// saturation and 70 % lightness, which keeps near-black numbers readable on every one of them.
public struct ROMHeatScale: Sendable, Equatable {
    /// One colour of the scale, as hue, saturation and lightness and as red, green and blue.
    public struct Color: Sendable, Equatable {
        /// In degrees, 0 to 360.
        public let hue: Double
        /// From 0 to 1.
        public let saturation: Double
        public let lightness: Double

        public init(hue: Double, saturation: Double, lightness: Double) {
            self.hue = hue
            self.saturation = saturation
            self.lightness = lightness
        }

        /// The same colour as sRGB red, green and blue, each from 0 to 1.
        public var rgb: (red: Double, green: Double, blue: Double) {
            let chroma = (1 - abs(2 * lightness - 1)) * saturation
            let sector = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
            let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
            let base = lightness - chroma / 2
            let (r, g, b): (Double, Double, Double)
            switch sector {
            case ..<1: (r, g, b) = (chroma, second, 0)
            case ..<2: (r, g, b) = (second, chroma, 0)
            case ..<3: (r, g, b) = (0, chroma, second)
            case ..<4: (r, g, b) = (0, second, chroma)
            case ..<5: (r, g, b) = (second, 0, chroma)
            default: (r, g, b) = (chroma, 0, second)
            }
            return (r + base, g + base, b + base)
        }

        /// The colour the way a style sheet writes it: "hsl(250, 84%, 70%)".
        public var css: String {
            "hsl(\(Int(hue.rounded())), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%)"
        }
    }

    /// The hue of the lowest value (blue) and of the highest (red), in degrees.
    public static let lowHue = 250.0
    public static let highHue = 0.0
    public static let saturation = 0.84
    public static let lightness = 0.70

    /// The lowest and the highest value of the map.
    public let low: Double
    public let high: Double

    public init(low: Double, high: Double) {
        self.low = Swift.min(low, high)
        self.high = Swift.max(low, high)
    }

    /// The scale of a map's own numbers. A number that is not one (a float map can hold such bytes)
    /// does not count. A map without any number is flat at 0.
    public init(values: [[Double]]) {
        var low = Double.infinity, high = -Double.infinity
        for row in values {
            for value in row where value.isFinite {
                low = Swift.min(low, value)
                high = Swift.max(high, value)
            }
        }
        if low > high { (low, high) = (0, 0) }
        self.low = low
        self.high = high
    }

    /// Every value is the same, so there is no lowest and highest to tell apart.
    public var isFlat: Bool { high <= low }

    /// Where a value lies between the lowest (0) and the highest (1). A flat map is 0 all over, and
    /// so is a value that is not a number.
    public func place(of value: Double) -> Double {
        guard !isFlat, value.isFinite else { return 0 }
        return Swift.min(Swift.max((value - low) / (high - low), 0), 1)
    }

    /// The colour of a value of this map. A flat map is one colour, the blue of the lowest value.
    public func color(for value: Double) -> Color {
        Self.color(at: place(of: value))
    }

    /// The colour at a place on the scale, from 0 (lowest) to 1 (highest). The hue is a whole number
    /// of degrees, so both fronts come to exactly the same colour.
    public static func color(at place: Double) -> Color {
        let t = place.isFinite ? Swift.min(Swift.max(place, 0), 1) : 0
        return Color(hue: (lowHue + (highHue - lowHue) * t).rounded(), saturation: saturation, lightness: lightness)
    }
}
