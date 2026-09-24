import Foundation
import Testing
@testable import SSMKit

@Suite("Trouble code help")
struct TroubleCodeHelpTests {
    @Test func everyDefinedCodeHasHelp() throws {
        let defs = try #require(try? LoggerDefinitions.bundled())
        let missing = Set(defs.codes.map(\.code)).filter { TroubleCodeHelp.lookup($0) == nil }
        #expect(missing.isEmpty, "\(missing.sorted())")
    }

    @Test func entriesAreComplete() throws {
        let library = TroubleCodeHelp.library
        #expect(library.count > 500)
        for (code, help) in library {
            #expect(code.range(of: #"^[PBCU][0-9A-F]{4}$"#, options: .regularExpression) != nil, "\(code)")
            #expect(!help.meaning.isEmpty, "\(code)")
            #expect(help.causes.count >= 3, "\(code)")
            #expect(help.fixes.count >= 3, "\(code)")
        }
    }

    @Test func lookupIgnoresCase() {
        #expect(TroubleCodeHelp.lookup("p0420") != nil)
        #expect(TroubleCodeHelp.lookup("P9999") == nil)
    }
}
