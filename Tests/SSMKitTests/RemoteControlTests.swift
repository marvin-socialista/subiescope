import Foundation
import Testing
@testable import SSMKit

@Suite("Remote control", .serialized)
struct RemoteControlTests {
    func tempSocket() -> String { "/tmp/subiescope-test-\(UUID().uuidString.prefix(8)).sock" }

    @Test func onlyReadOnlyRequestsAreAllowed() {
        // Reading data and codes is fine.
        for ok in ["010C", "01 0C", "0100", "22 10B4", "22F190", "03", "07", "0902", "19 02 FF", "010C1", "ATZ", "ATSH7E0", "AT DP", "atcra7aa",
                   "AA", "A800000008", "a8 00 00 00 08"] {   // Subaru SSM over CAN: identify, read an address
            #expect(CommandPolicy.check(ok) == nil, "\(ok) should be allowed")
        }
        // Anything that changes the car or the adapter is refused.
        let refused: [(String, String)] = [
            ("04", "clear"),            // clear trouble codes
            ("08 01", "actuat"),        // control on-board system
            ("2E F1 90 01", "not read-only"),   // write data by identifier
            ("27 01", "not read-only"),         // security access
            ("31 01 FF 00", "not read-only"),   // routine control
            ("11 01", "not read-only"),         // ECU reset
            ("14 FF FF FF", "not read-only"),   // clear DTC (UDS)
            ("34 00 44", "not read-only"),      // request download (flashing)
            ("10 02", "not read-only"),         // session control
            ("B8 00 00 08 00", "not read-only"),    // SSM write to an address
            ("B0 00 00 08 00", "not read-only"),    // SSM write a block
            ("ATPP FF SV 00", "permanently"),   // programmable parameters
            ("ATBRD 23", "permanently"),        // change the adapter baud rate
            ("", "Empty"), ("hello", "hex"), ("0G", "hex"),
        ]
        for (command, _) in refused {
            #expect(CommandPolicy.check(command) != nil, "\(command.isEmpty ? "(empty)" : command) should be refused")
        }
    }

    @Test func requestsTravelOverTheSocket() throws {
        let path = tempSocket()
        let server = RemoteServer(path: path) { line in
            line == "boom" ? [] : ["you said: \(line)", "second line"]
        }
        try server.start()
        defer { server.stop() }
        let reply = try RemoteClient.send("send 010C", path: path, timeout: 5)
        #expect(reply == ["you said: send 010C", "second line"])
        #expect(try RemoteClient.send("boom", path: path, timeout: 5).isEmpty)
    }

    @Test func theSocketIsOnlyOpenToTheCurrentUser() throws {
        let path = tempSocket()
        let server = RemoteServer(path: path) { _ in ["ok"] }
        try server.start()
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func stoppingRemovesTheSocketAndClientsGetAClearMessage() throws {
        let path = tempSocket()
        let server = RemoteServer(path: path) { _ in ["ok"] }
        try server.start()
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        do {
            _ = try RemoteClient.send("status", path: path, timeout: 2)
            Issue.record("expected an error")
        } catch let error as RemoteError {
            #expect(error.localizedDescription.contains("not listening"))
            #expect(error.localizedDescription.contains("remoteControl"))
        }
    }

    @Test func manyRequestsInARowAreAllAnswered() throws {
        let path = tempSocket()
        let server = RemoteServer(path: path) { line in [line.uppercased()] }
        try server.start()
        defer { server.stop() }
        for i in 0..<30 {
            #expect(try RemoteClient.send("req \(i)", path: path, timeout: 5) == ["REQ \(i)"])
        }
    }
}
