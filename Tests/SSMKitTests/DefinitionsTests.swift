import Foundation
import Testing
@testable import SSMKit

@Suite("RomRaider definitions")
struct DefinitionsTests {
    static let defs: LoggerDefinitions? = try? LoggerDefinitions.bundled()

    @Test func loadsSSMSection() throws {
        let defs = try #require(Self.defs)
        #expect(defs.version == "370")
        #expect(defs.standard.count > 200)
        #expect(defs.switches.count > 150)
        #expect(defs.codes.count > 500)
        #expect(defs.extended.count > 150)
        #expect(defs.calculated.count >= 8)
        let rpm = try #require(defs.standard.first { $0.id == "P8" })
        #expect(rpm.addresses == [0x0E, 0x0F])
        #expect(rpm.capabilityByte == 8 && rpm.capabilityBit == 0)
        #expect(rpm.conversions.first?.expression == "x/4")
    }

    @Test func resolvesExtendedParametersForEDMSTI() throws {
        let defs = try #require(Self.defs)
        let identity = ECUIdentity(systemID: [0xA2, 0x10, 0x11], romID: [0x5A, 0x42, 0x78, 0x42, 0x07],
                                   capabilities: [UInt8](repeating: 0xFF, count: 96))
        let set = defs.parameterSet(for: identity)
        let fbkc = try #require(set.parameters.first { $0.id == "E39" })
        #expect(fbkc.addresses == [0xFF7C40, 0xFF7C41, 0xFF7C42, 0xFF7C43])
        #expect(fbkc.conversions.first?.storageType == .float)
        #expect(set.parameters.contains { $0.id == "P201" }) // injector duty, calculated
    }

    @Test func capabilityBitsFilterStandardParameters() throws {
        let defs = try #require(Self.defs)
        // Only byte index 8 bit 0 (engine speed) set.
        var caps = [UInt8](repeating: 0, count: 48)
        caps[0] = 0x01
        let identity = ECUIdentity(systemID: [0, 0, 0], romID: [0, 0, 0, 0, 0], capabilities: caps)
        let standard = defs.parameterSet(for: identity).parameters.filter { $0.kind == .standard }
        #expect(standard.map(\.id).contains("P8"))
        #expect(!standard.map(\.id).contains("P2"))
    }

    @Test func everyExpressionParses() throws {
        let defs = try #require(Self.defs)
        let all = defs.standard + defs.switches + defs.calculated + defs.extended.map(\.base)
        var failures: [String] = []
        for p in all {
            for c in p.conversions where (try? Expression(c.expression)) == nil {
                failures.append("\(p.id) \(c.expression)")
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func expressionEvaluation() throws {
        #expect(try Expression("x/4").evaluate(x: 3000) == 750)
        #expect(try Expression("32+9*(x-40)/5").evaluate(x: 140) == 212)
        #expect(try Expression("0-x").evaluate(x: 5) == -5)
        #expect(try Expression("x*.0625").evaluate(x: 16) == 1)
        #expect(try Expression("(P8*[P21:ms])/1200").evaluate(["P8": 6000, "[P21:ms]": 10]) == 50)
        #expect(try Expression("2^3^2").evaluate([:]) == 512)
        #expect(try Expression("-x^2").evaluate(x: 3) == -9)
    }

    @Test func storageDecoding() {
        #expect(StorageType.float.decode([0x3F, 0x80, 0x00, 0x00]) == 1.0)
        #expect(StorageType.int16.decode([0xFF, 0xFE]) == -2)
        #expect(StorageType.uint16.decode([0x2E, 0xE0]) == 12000)
    }
}
