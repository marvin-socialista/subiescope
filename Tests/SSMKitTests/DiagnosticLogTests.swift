import Foundation
import Testing
@testable import SSMKit

@Suite("Diagnostic log", .serialized)
struct DiagnosticLogTests {
    func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("subiescope-log-test-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func writesLinesWithLevelAndCategory() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        log.info("app", "hello")
        log.error("ble", "it broke")
        log.flush()
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        #expect(text.contains("INFO  [app] hello"))
        #expect(text.contains("ERROR [ble] it broke"))
    }

    @Test func removesTheHomeFolderAndVINsFromWhatIsWritten() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        log.info("app", "Saved to \(NSHomeDirectory())/Documents/log.csv for JF1VA1A6XG9800001")
        log.flush()
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        #expect(!text.contains(NSHomeDirectory()))
        #expect(text.contains("~/Documents/log.csv"))
        #expect(!text.contains("JF1VA1A6XG9800001"))
        #expect(text.contains("<VIN>"))
    }

    @Test func removesAVINThatTravelsAsBytes() {
        // An SSM car answers its VIN as seventeen bytes; the traffic kept for a report shows them as hex.
        let log = DiagnosticLog(directory: tempDirectory())
        let vin = Array("JF1GH7LA58G012345".utf8).map { String(format: "%02X", $0) }.joined(separator: " ")
        let line = log.scrub("received 80 F0 10 12 E8 \(vin) 5C")
        #expect(line == "received 80 F0 10 12 E8 <VIN> 5C")
        // Ordinary traffic stays as it is: these bytes are no characters of a VIN.
        let traffic = "received 80 F0 10 27 E8 44 84 7D 83 2B 20 C4 47 0A C0 2C B0 0F 5B 27 00 7F 04 3F 80 00 00"
        #expect(log.scrub(traffic) == traffic)
    }

    @Test func rotatesAndKeepsAFewFiles() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        let line = String(repeating: "x", count: 900)
        for _ in 0..<(DiagnosticLog.maxBytes / 900 * 4) { log.info("fill", line) }
        log.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".log") }.sorted()
        #expect(names.contains("subiescope.log") && names.contains("subiescope.1.log"))
        #expect(names.count <= DiagnosticLog.keptFiles + 1)
        let size = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.size] as? Int ?? 0
        #expect(size <= DiagnosticLog.maxBytes + 2000)
    }

    @Test func noticesARunThatNeverQuitCleanly() throws {
        let directory = tempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A marker of a process that is long gone, and one of this (living) process.
        try "1\n".write(to: directory.appendingPathComponent("running-99999999.marker"), atomically: true, encoding: .utf8)
        try "1\n".write(to: directory.appendingPathComponent("running-\(getpid()).marker"), atomically: true, encoding: .utf8)
        #expect(DiagnosticLog.removeStaleMarkers(in: directory))
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left == ["running-\(getpid()).marker"])
        #expect(!DiagnosticLog.removeStaleMarkers(in: directory))
    }

    @Test func keepsWorkingWhenTheFolderCannotBeWritten() {
        // A folder inside a file can never be created; logging must quietly do nothing, not crash.
        let log = DiagnosticLog(directory: URL(fileURLWithPath: "/dev/null/nope"))
        log.info("app", "this goes nowhere")
        log.flush()
        #expect(log.recentLines().isEmpty)
    }

    @Test func buildsAReportWithLogSystemInfoAndCrashReports() throws {
        let directory = tempDirectory()
        let crashes = tempDirectory()
        try FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: crashes) }
        try "crash of \(NSHomeDirectory())/x".write(to: crashes.appendingPathComponent("SubieScope-2026-09-30.ips"), atomically: true, encoding: .utf8)
        try "other".write(to: crashes.appendingPathComponent("Safari-2026.ips"), atomically: true, encoding: .utf8)
        let log = DiagnosticLog(directory: directory)
        log.info("app", "something happened")
        let zip = try DiagnosticReport.build(log: log, context: ["Connection type: OBD-II"], appVersion: "9.9", crashReports: crashes)
        defer { try? FileManager.default.removeItem(at: zip) }
        #expect(zip.pathExtension == "zip")

        let unpacked = tempDirectory()
        defer { try? FileManager.default.removeItem(at: unpacked) }
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, unpacked.path]
        try unzip.run(); unzip.waitUntilExit()
        let root = try #require(try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).first)
        let report = try String(contentsOf: root.appendingPathComponent("report.txt"), encoding: .utf8)
        #expect(report.contains("Connection type: OBD-II"))
        #expect(report.contains("App version 9.9"))
        #expect(report.contains("something happened"))
        #expect(report.contains("macOS"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("logs/subiescope.log").path))
        let crashCopy = try String(contentsOf: root.appendingPathComponent("crash-reports/SubieScope-2026-09-30.ips"), encoding: .utf8)
        #expect(!crashCopy.contains(NSHomeDirectory()))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("crash-reports/Safari-2026.ips").path))
    }
}
