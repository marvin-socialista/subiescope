import Foundation
import Testing
@testable import SSMKit

@Suite("Virtual dyno")
struct DynoTests {
    /// A simulated 3rd gear pull written as a RomRaider style log.
    func pullLog() -> RecordedLog {
        let world = DemoWorld()
        world.setScenario(.wotPull)
        var csv = "Time (msec),Engine Speed (rpm),Throttle Opening Angle (%),Vehicle Speed (km/h),Intake Air Temperature (C),Manifold Relative Pressure (kPa)\n"
        var t = 0.0
        while t < 40 {
            let v = world.sample(at: t)
            csv += "\(Int(t * 1000)),\(v["rpm"]!),\(v["throttle"]!),\(v["speed"]!),\(v["iat"]!),\(v["mrp"]!)\n"
            t += 0.07
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

    @Test func tireMaths() {
        let s = DynoSettings()
        #expect(abs(s.tireDiameterM - 0.6532) < 0.001)                  // 245/40R18
        #expect(abs(s.speed(rpm: 6000, gear: 3) * 3.6 - 107.6) < 1)      // km/h in 3rd at 6,000 rpm
    }
}
