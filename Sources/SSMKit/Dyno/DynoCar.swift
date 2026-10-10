import Foundation

/// A car's weight, gearing, tyres and drag for the virtual dyno, so an owner does not have to look
/// them up. Loaded from Cars/dyno_cars.json, which `scripts/build-car-data.py` makes from the car
/// list of RomRaider's own dyno (kept by the RomRaider community in Merp's SubaruDefs).
public struct DynoCar: Codable, Sendable, Hashable, Identifiable {
    /// "2009 E/USDM STi 6MT"
    public var name: String
    public var year: Int
    /// The car alone, without a driver.
    public var curbWeightKg: Double
    public var finalDrive: Double
    public var dragCoefficient: Double
    public var gearRatios: [Double]
    public var tireWidthMM: Double
    public var tireAspect: Double
    public var rimInches: Double
    public var automatic: Bool

    public var id: String { name }

    /// Every car, oldest first.
    public static let library: [DynoCar] = {
        guard let url = SSMResources.url(forCars: "dyno_cars"),
              let data = try? Data(contentsOf: url),
              let cars = try? JSONDecoder().decode([DynoCar].self, from: data) else { return [] }
        return cars
    }()
}

extension DynoSettings {
    /// These settings with a car's weight, gearing, tyres and drag filled in. Frontal area, rolling
    /// resistance and drivetrain loss stay as they are: the list has no figures per car for those.
    public func applying(_ car: DynoCar, driverKg: Double = 80) -> DynoSettings {
        var settings = self
        settings.massKg = car.curbWeightKg + driverKg
        settings.gearRatios = car.gearRatios
        settings.finalDrive = car.finalDrive
        settings.tireWidthMM = car.tireWidthMM
        settings.tireAspect = car.tireAspect
        settings.rimInches = car.rimInches
        settings.dragCoefficient = car.dragCoefficient
        // A pull gear this car does not have becomes its top gear.
        if let gear = settings.gear { settings.gear = min(gear, car.gearRatios.count) }
        return settings
    }
}
