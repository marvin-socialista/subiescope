import Foundation
import Testing
@testable import SSMKit
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The parts SSMKit brings itself for Windows, held against what a Mac has built in.
@Suite("Portable replacements")
struct PlatformTests {
    final class Recorder: XMLEventHandler {
        var events: [String] = []

        func startElement(_ name: String, attributes: [String: String]) {
            events.append("<\(name)" + attributes.sorted { $0.key < $1.key }.map { " \($0.key)=[\($0.value)]" }.joined() + ">")
        }

        /// Text may arrive in pieces: where one piece ends says nothing about the file.
        func characters(_ string: String) {
            if let last = events.last, last.hasPrefix("T:") {
                events[events.count - 1] = last + string
            } else {
                events.append("T:" + string)
            }
        }

        func endElement(_ name: String) {
            events.append("</\(name)>")
        }
    }

    static let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- a comment with <tags> in it -->
    <!DOCTYPE logger [
    <!ELEMENT logger ( protocols ) >
    <!ATTLIST logger version CDATA #IMPLIED >
    <!-- ]> inside a comment -->
    ]>
    <logger version="370">\r
      <protocol id='SSM' name="a &amp; b &lt;c&gt; &quot;d&quot; &apos;e&apos; &#65;&#x42;">
        <empty/>
        <spaced   one = "1"
                  two='line
    break'  />
        <address length="2">0x00000E</address>
        <text>before <![CDATA[<raw> & stuff]]> after &amp; more</text>
        <units>°C, λ and µs</units>
      </protocol>
    </logger>
    <!-- after the end -->

    """

    @Test func portableReaderUnderstandsTheSample() throws {
        let recorder = Recorder()
        try PortableXMLParser.parse(Data(Self.sample.utf8), handler: recorder)
        #expect(recorder.events == [
            "<logger version=[370]>", "T:\n  ",
            "<protocol id=[SSM] name=[a & b <c> \"d\" 'e' AB]>", "T:\n    ",
            "<empty>", "</empty>", "T:\n    ",
            "<spaced one=[1] two=[line break]>", "</spaced>", "T:\n    ",
            "<address length=[2]>", "T:0x00000E", "</address>", "T:\n    ",
            "<text>", "T:before <raw> & stuff after & more", "</text>", "T:\n    ",
            "<units>", "T:°C, λ and µs", "</units>", "T:\n  ",
            "</protocol>", "T:\n",
            "</logger>",
        ])
    }

    @Test func portableReaderRefusesBrokenFiles() {
        for broken in ["", "<a><b></a></b>", "<a>", "<a b=1/>", "<a>&nothing;</a>", "<a/><b/>", "<!-- never ends"] {
            #expect(throws: XMLReader.Failure.self) {
                try PortableXMLParser.parse(Data(broken.utf8), handler: Recorder())
            }
        }
    }

    @Test func portableReaderConvertsOtherEncodings() throws {
        let recorder = Recorder()
        let latin = try #require("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a unit=\"°C\">é</a>".data(using: .isoLatin1))
        try PortableXMLParser.parse(latin, handler: recorder)
        #expect(recorder.events == ["<a unit=[°C]>", "T:é", "</a>"])
    }

    #if canImport(Darwin)
    /// On a Mac both readers are there: they have to tell the same story about the same file.
    @Test func portableReaderMatchesFoundation() throws {
        var files: [(String, Data)] = [("the sample", Data(Self.sample.utf8))]
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["definitions/logger_METRIC_EN_v370.xml", "definitions/ecu_defs.xml"] {
            if let data = try? Data(contentsOf: repository.appendingPathComponent(name)) { files.append((name, data)) }
        }
        for (name, data) in files {
            let foundation = Recorder(), portable = Recorder()
            do {
                try XMLReader.parse(data, handler: foundation)
                try PortableXMLParser.parse(data, handler: portable)
            } catch {
                Issue.record("\(name): \(error.localizedDescription)")
                continue
            }
            #expect(foundation.events.count == portable.events.count, "\(name): number of events")
            if let different = zip(foundation.events, portable.events).first(where: { $0 != $1 }) {
                Issue.record("\(name): Foundation reads \(different.0.debugDescription), the portable reader \(different.1.debugDescription)")
            }
        }
    }
    #endif

    @Test func theTimeZoneIsThePCsOwn() {
        // Every Windows name leads to a zone that exists.
        for (windows, name) in SystemTimeZone.names {
            #expect(TimeZone(identifier: name) != nil, "\(windows) -> \(name)")
        }
        #expect(SystemTimeZone.names["W. Europe Standard Time"] == "Europe/Berlin")
        #if os(Windows)
        SystemTimeZone.apply()
        // Not a proof, but GMT on a PC that is not in GMT is what this is there to prevent.
        var parts = tm()
        var now = time_t(Date().timeIntervalSince1970)
        localtime_s(&parts, &now)
        #expect(Calendar.current.component(.hour, from: Date()) == Int(parts.tm_hour))
        // The text for a person says the same hour as the PC's clock.
        let clock = SystemTimeZone.text(Date(), date: .omitted, time: .standard)
        let hour = Int(clock.prefix { $0.isNumber }) ?? -1
        #expect(hour % 12 == Int(parts.tm_hour) % 12, "\(clock)")
        #endif
        // On every computer: the same moment, the same text as Foundation's own, once the zone is right.
        let moment = Date(timeIntervalSince1970: 1_791_590_000)
        var expected = Date.FormatStyle(date: .abbreviated, time: .shortened)
        expected.timeZone = SystemTimeZone.zone
        #expect(SystemTimeZone.text(moment, date: .abbreviated, time: .shortened) == moment.formatted(expected))
    }

    @Test func sha256MatchesTheStandard() {
        #expect(PortableSHA256.hash(Data()).map { String(format: "%02x", $0) }.joined()
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(PortableSHA256.hash(Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Platform.sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    #if canImport(CryptoKit)
    @Test func sha256MatchesCryptoKit() {
        // Around the block size, where the padding changes shape.
        for length in [1, 54, 55, 56, 57, 63, 64, 65, 119, 120, 128, 1000, 70_000] {
            let data = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            #expect(PortableSHA256.hash(data) == Array(SHA256.hash(data: data)), "length \(length)")
        }
    }
    #endif
}
