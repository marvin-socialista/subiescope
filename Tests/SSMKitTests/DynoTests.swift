import Foundation
import Testing
@testable import SSMKit

@Suite("Virtual dyno")
struct DynoTests {
    /// A simulated 3rd gear pull written as a RomRaider style log. With `emptyBoostEvery`, every so
    /// many rows have no boost value, as in a log where the car did not answer in time.
    func pullLog(emptyBoostEvery gap: Int? = nil) -> RecordedLog {
        let world = DemoWorld()
        world.setScenario(.wotPull)
        var csv = "Time (msec),Engine Speed (rpm),Throttle Opening Angle (%),Vehicle Speed (km/h),Intake Air Temperature (C),Manifold Relative Pressure (kPa)\n"
        var t = 0.0
        var row = 0
        while t < 40 {
            let v = world.sample(at: t)
            let boost = gap.map { row % $0 == 0 } == true ? "" : "\(v["mrp"]!)"
            csv += "\(Int(t * 1000)),\(v["rpm"]!),\(v["throttle"]!),\(v["speed"]!),\(v["iat"]!),\(boost)\n"
            t += 0.07
            row += 1
        }
        return RecordedLog.parse(csv)
    }

    @Test func findsPullsAndComputesPower() throws {
        let log = pullLog()
        let pulls = VirtualDyno.findPulls(in: log)
        #expect(pulls.count == 2)   // 40 s of the 20 s pull cycle
        var settings = DynoSettings()
        settings.gear = nil
        #expect(VirtualDyno.detectGear(log: log, rows: pulls[0], settings: settings) == 3)
        let run = try #require(VirtualDyno.run(log: log, rows: pulls[0], settings: settings))
        let peak = try #require(run.peakPower)
        // The simulator accelerates steadily from 2,600 to 6,800 rpm in 8 s:
        // about 160 kW at the wheels near the top for a 1,560 kg car.
        #expect(peak.wheelPower > 130_000 && peak.wheelPower < 200_000, "\(peak.wheelPower)")
        #expect(peak.rpm > 6000)
        #expect((run.peakTorque?.torque ?? 0) > 150)
    }

    @Test func emptyBoostCellsDoNotSpoilTheCurve() throws {
        let full = pullLog()
        let gaps = pullLog(emptyBoostEvery: 3)
        let settings = DynoSettings()
        let whole = try #require(VirtualDyno.run(log: full, rows: VirtualDyno.findPulls(in: full)[0], settings: settings))
        let run = try #require(VirtualDyno.run(log: gaps, rows: VirtualDyno.findPulls(in: gaps)[0], settings: settings))
        // Every rpm step still has a boost value, from the rows that did have one.
        let boost = run.points.compactMap(\.boost)
        #expect(boost.allSatisfy { $0.isFinite }, "\(boost)")
        #expect(boost.count >= run.points.count * 3 / 4, "\(boost.count) of \(run.points.count)")
        // And the peak is where it was with every row filled in.
        let peak = try #require(boost.max())
        let wholePeak = try #require(whole.points.compactMap(\.boost).max())
        #expect(abs(peak - wholePeak) < 5, "\(peak) against \(wholePeak)")
    }

    @Test func tireMaths() {
        let s = DynoSettings()
        #expect(abs(s.tireDiameterM - 0.6532) < 0.001)                  // 245/40R18
        #expect(abs(s.speed(rpm: 6000, gear: 3) * 3.6 - 107.6) < 1)      // km/h in 3rd at 6,000 rpm
    }
}
