#if DEBUG && canImport(Network) && canImport(AppKit)
import AppKit
import Foundation
import Network
import SSMKit

/// For working on the Windows app's page on a Mac. Debug builds only.
///
///     .build/debug/SubieScope -webDev 8787 -webRoot "$PWD/Sources/SubieScope/Windows/Web" -selectedPort demo -autoConnect YES
///
/// serves the page at http://127.0.0.1:8787/ and connects it to this app's own model, through the
/// same Bridge the Windows app uses. The Mac window stays out of sight. Only this Mac can reach it.
@MainActor
enum WebDevServer {
    private static var listener: NWListener?
    private static var bridge: Bridge?
    private static var root = URL(fileURLWithPath: "/")
    private static var streams: [NWConnection] = []

    static var isAskedFor: Bool { UserDefaults.standard.string(forKey: "webDev") != nil }

    static func startIfAskedFor() {
        let defaults = UserDefaults.standard
        guard let port = defaults.string(forKey: "webDev").flatMap({ UInt16($0) }), let endpoint = NWEndpoint.Port(rawValue: port) else { return }
        guard let folder = defaults.string(forKey: "webRoot") else {
            print("-webDev needs -webRoot <the folder with index.html>")
            return
        }
        root = URL(fileURLWithPath: folder, isDirectory: true)
        let bridge = Bridge(model: .shared)
        bridge.transmit = { json in
            let event = Data("data: \(json)\n\n".utf8)
            for stream in streams { stream.send(content: event, completion: .contentProcessed { _ in }) }
        }
        self.bridge = bridge

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpoint)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            print("Could not listen on port \(port)")
            return
        }
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated {
                connection.start(queue: .main)
                read(connection, Data())
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        print("The page is at http://127.0.0.1:\(port)/")

        // This run is for the page: the Mac window stays out of sight (the app delegate has seen to
        // that before the window was made) and takes no focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.windows.forEach { $0.orderOut(nil) } }
        // Ending it with Ctrl-C or `kill` counts as a normal quit, so no crash prompt follows.
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private static var signalSources: [DispatchSourceSignal] = []

    /// Collects one request (the head, and the body a POST says it has), then answers it.
    private static func read(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            MainActor.assumeIsolated {
                var all = received
                if let data { all.append(data) }
                guard let headEnd = all.range(of: Data("\r\n\r\n".utf8)) else {
                    if isComplete || error != nil { connection.cancel() } else { read(connection, all) }
                    return
                }
                let head = String(decoding: all[all.startIndex..<headEnd.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                let length = lines.first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = all[headEnd.upperBound...]
                if body.count < length, !isComplete, error == nil {
                    read(connection, all)
                    return
                }
                let request = lines[0].split(separator: " ")
                guard request.count >= 2 else { connection.cancel(); return }
                answer(connection, method: String(request[0]), path: String(request[1]), body: Data(body.prefix(length)))
            }
        }
    }

    private static func answer(_ connection: NWConnection, method: String, path: String, body: Data) {
        let route = path.split(separator: "?").first.map(String.init) ?? "/"
        if route == "/bridge/events" {
            // The app's messages to the page, one event each, for as long as the page is open.
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            streams.append(connection)
            connection.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    switch state {
                    case .failed, .cancelled: streams.removeAll { $0 === connection }
                    default: break
                    }
                }
            }
            return
        }
        if route == "/bridge/send", method == "POST" {
            bridge?.receive(String(decoding: body, as: UTF8.self))
            send(connection, status: "204 No Content", type: "text/plain", Data())
            return
        }
        let name = route == "/" ? "index.html" : String(route.dropFirst()).removingPercentEncoding ?? ""
        let file = root.appendingPathComponent(name).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            send(connection, status: "404 Not Found", type: "text/plain", Data("Not found".utf8))
            return
        }
        let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
                     "css": "text/css; charset=utf-8", "json": "application/json", "svg": "image/svg+xml", "png": "image/png",
                     "woff2": "font/woff2", "ico": "image/x-icon"]
        send(connection, status: "200 OK", type: types[file.pathExtension.lowercased()] ?? "application/octet-stream", data)
    }

    private static func send(_ connection: NWConnection, status: String, type: String, _ body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
