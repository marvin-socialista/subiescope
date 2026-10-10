import Foundation
import Testing
@testable import SSMKit

@Suite("Cars by ECU ID and for the dyno")
struct KnownECUTests {
    @Test func namesTheCarBehindAnECUID() throws {
        #expect(KnownECU.library.count > 300)
        // The ECU of the 2008 STI this app was first tried on in a real car.
        let ecu = try #require(KnownECU.lookup("6904784007").first)
        #expect(ecu.calID == "AZ1G500F")
        #expect(ecu.carName == "2009 Impreza STi, JDM, manual")
        #expect(ecu.processorDescription == "Renesas SH7058 (32-bit, 1 MB ROM)")
        #expect(ecu.flashMethod == "subarucan")
        #expect(ecu.flashTransport == .can)
        #expect(KnownECU.lookup("0000000000").isEmpty)
    }

    @Test func everyECUHasAProcessorAndAFlashMethodWeKnow() {
        for ecu in KnownECU.library.values.joined() {
            #expect(ecu.flashTransport != nil, "\(ecu.calID): \(ecu.flashMethod ?? "no flash method")")
            #expect(ecu.processorDescription != ecu.processor, "\(ecu.calID): \(ecu.processor ?? "no processor")")
        }
        // Only the newest family goes over CAN.
        let overCAN = KnownECU.library.values.joined().filter { $0.flashTransport == .can }
        #expect(overCAN.allSatisfy { $0.processor == "SH7058" })
    }

    @Test func oneLinePerECUID() {
        // Named by hand, with the chassis code.
        #expect(EngineDiagnostics.knownECUs["6904784007"] == "2009 Impreza WRX STI GRB, JDM (AZ1G500F)")
        #expect(EngineDiagnostics.knownECUs["5A04784207"] == "2008 Impreza WRX STI GRB, JDM (AZ1G301F)")
        // From the table.
        #expect(EngineDiagnostics.knownECUs["1B04400405"] == "2001/02 Impreza WRX, JDM, manual or automatic (A4SD501A)")
        // Two calibrations share this ECU ID.
        #expect(EngineDiagnostics.knownECUs["2E44596105"] == "2003 Impreza STi, EDM, manual (A4RN2000 or A4RN200H)")
        #expect(EngineDiagnostics.knownECUs.count == KnownECU.library.count)
    }

    @Test func aCarFillsInTheDynoSettings() throws {
        #expect(DynoCar.library.count == 93)
        let sti = try #require(DynoCar.library.first { $0.name == "2009 E/USDM STi 6MT" })
        var settings = DynoSettings()
        settings.frontalAreaM2 = 2.5
        settings = settings.applying(sti)
        #expect(settings.massKg == 1540 + 80)
        #expect(settings.gearRatios == [3.636, 2.235, 1.521, 1.137, 0.971, 0.756])
        #expect(settings.finalDrive == 3.9)
        #expect([settings.tireWidthMM, settings.tireAspect, settings.rimInches] == [245, 40, 18])
        #expect(settings.frontalAreaM2 == 2.5)

        // A four-speed automatic has no fifth gear to pull in.
        let forester = try #require(DynoCar.library.first { $0.name == "2008 E/USDM Forester XT 4AT" })
        settings.gear = 5
        settings = settings.applying(forester)
        #expect(settings.gearRatios.count == 4)
        #expect(settings.gear == 4)
        #expect(forester.automatic)
    }
}
