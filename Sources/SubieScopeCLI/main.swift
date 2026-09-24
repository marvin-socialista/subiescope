import Foundation
import SSMKit

// subiescope-cli: command line access to the same SSM code the app uses.
// Handy for a first test at the car, and for pasting output when asking for help.

let usage = """
usage: subiescope-cli <command> [options]

commands:
  ports                      List serial ports (the FTDI cable shows as cu.usbserial-…)
  probe                      Connect, show raw traffic and identify the ECU
  params                     List the parameters this ECU supports
  log                        Print live values (and optionally write a CSV)
  codes                      Read trouble codes
  demo                       Run the demo ECU on a pseudo terminal for testing

options:
  --port PATH                Serial device (default: first FTDI/USB port)
  --demo                     Use the built-in demo ECU instead of a cable
  --scenario NAME            Demo only: what the demo car does (idle, cruise, wotPull, …)
  --fault NAME               Demo only: simulate a fault (dirtyMAF, vacuumLeak, knock, …)
  --defs FILE                RomRaider logger definition XML (default: built-in)
  --params "A,B,…"           Parameter names or IDs for `log` (default: a useful STI set)
  --csv FILE                 Also write the log to FILE
  --seconds N                Stop `log` after N seconds
  --no-fast                  Disable fast poll (continuous mode)
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(1)
}
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains(name) }
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func loadDefinitions() -> LoggerDefinitions {
    do {
        if let path = option("--defs") { return try LoggerDefinitions.load(url: URL(fileURLWithPath: path)) }
        return try LoggerDefinitions.bundled()
    } catch {
        fail(error.localizedDescription)
    }
}

var demoECU: DemoECU?

func resolvePort(_ defs: LoggerDefinitions?) -> String {
    if flag("--demo") {
        do {
            demoECU = try DemoECU.make(definitions: defs)
            if let name = option("--scenario"), let scenario = DemoScenario(rawValue: name) {
                demoECU!.setScenario(scenario)
            }
            if let name = option("--fault"), let fault = DemoFault(rawValue: name) {
                demoECU!.setFault(fault)
            }
            return demoECU!.ecu.devicePath
        } catch {
            fail("could not start demo ECU: \(error.localizedDescription)")
        }
    }
    if let port = option("--port") { return port }
    let ports = SerialPortList.available()
    guard let port = ports.first(where: \.isFTDI) ?? ports.first(where: \.isUSB) else {
        fail("no USB serial cable found. Plug in the cable, or pass --port /dev/cu.… (see `subiescope-cli ports`)")
    }
    return port.path
}

func makeSession(_ defs: LoggerDefinitions?, verbose: Bool) -> SSMSession {
    let path = resolvePort(defs)
    let session = SSMSession(portPath: path)
    session.fastPoll = !flag("--no-fast")
    if let demoECU { session.transport.onBreak = { demoECU.ecu.simulateBreak() } }
    if verbose {
        session.transport.traffic = { direction, bytes in
            let arrow: String
            switch direction {
            case .sent: arrow = "→ sent    "
            case .echo: arrow = "↩ echo    "
            case .received: arrow = "← ECU     "
            case .garbage: arrow = "? unparsed"
            }
            print("  \(arrow) \(bytes.hexString)")
        }
    }
    print("Port: \(path)\(demoECU != nil ? " (demo ECU)" : "")")
    return session
}

/// Runs async work from top-level code and waits for it.
func blocking<T>(_ work: @escaping () async throws -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>!
    Task {
        do { result = .success(try await work()) } catch { result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    switch result! {
    case .success(let v): return v
    case .failure(let e): fail(e.localizedDescription)
    }
}

switch command {
case "ports":
    let ports = SerialPortList.available(includeSystemPorts: true)
    if ports.isEmpty { print("No serial ports found.") }
    for p in ports {
        var tags: [String] = []
        if p.isFTDI { tags.append("FTDI") }
        if let v = p.vendorID, let pid = p.productID { tags.append(String(format: "USB %04X:%04X", v, pid)) }
        if let s = p.serialNumber { tags.append("serial \(s)") }
        print("\(p.path)\t\(p.productName ?? "")\t\(tags.joined(separator: ", "))")
    }

case "probe":
    let defs = try? LoggerDefinitions.bundled()
    let session = makeSession(defs, verbose: true)
    print("Sending init request (0xBF) at 4800 baud…")
    let identity = blocking { try await session.connect() }
    print("")
    print("ECU ID:        \(identity.ecuID)")
    print("Car:           \(EngineDiagnostics.knownECUs[identity.ecuID] ?? "not in the 2008 STI list")")
    print("System ID:     \(identity.systemIDString) (\(EngineDiagnostics.engineType(systemID: identity.systemID) ?? "unknown engine"))")
    print("Capabilities:  \(identity.capabilities.count) bytes: \(identity.capabilities.hexString)")
    if let defs {
        let set = defs.parameterSet(for: identity)
        let count = { (k: ParameterKind) in set.parameters.filter { $0.kind == k }.count }
        print("Supported:     \(count(.standard)) standard, \(count(.extended)) ECU specific, \(count(.calculated)) calculated, \(count(.switchBit)) switches")
        if count(.extended) == 0 {
            print("               (ECU ID not in the definitions: no IAM/knock learning parameters)")
        }
    }
    session.close()

case "params":
    let defs = loadDefinitions()
    let session = makeSession(defs, verbose: false)
    let identity = blocking { try await session.connect() }
    for p in defs.parameterSet(for: identity).parameters {
        let units = p.conversions.map(\.units).joined(separator: ", ")
        print("\(p.id)\t\(p.name)\t[\(units)]")
    }
    session.close()

case "codes":
    let defs = loadDefinitions()
    let session = makeSession(defs, verbose: false)
    let identity = blocking { try await session.connect() }
    let set = defs.parameterSet(for: identity)
    let report = blocking { try await session.run { try TroubleCodeReport.read(with: $0, definitions: set.diagnosticCodes) } }
    print("Current codes:   \(report.current.isEmpty ? "none" : "")")
    for c in report.current { print("  \(c.name)") }
    print("Memorized codes: \(report.memorized.isEmpty ? "none" : "")")
    for c in report.memorized { print("  \(c.name)") }
    session.close()

case "log":
    let defs = loadDefinitions()
    let session = makeSession(defs, verbose: false)
    let identity = blocking { try await session.connect() }
    let set = defs.parameterSet(for: identity)
    let wanted = option("--params")?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        ?? ["Engine Speed", "Manifold Relative Pressure", "A/F Sensor #1", "Ignition Total Timing",
            "Feedback Knock Correction", "Fine Learning Knock Correction", "IAM", "Coolant Temperature"]
    var items: [PollItem] = []
    for name in wanted {
        let lower = name.lowercased()
        let match = set.parameters.first { $0.id.lowercased() == lower || $0.name.lowercased() == lower }
            ?? set.parameters.first { $0.name.lowercased().hasPrefix(lower) }
        guard let p = match, let c = p.conversions.first else {
            print("skipping \"\(name)\": not supported by this ECU")
            continue
        }
        items.append(PollItem(parameter: p, conversion: c))
    }
    guard !items.isEmpty else { fail("nothing to log") }
    let polled = items
    let writer = option("--csv").flatMap { path in
        try? CSVLogWriter(url: URL(fileURLWithPath: path), columns: items.map {
            .init(id: $0.parameter.id, title: $0.parameter.name, conversion: $0.conversion)
        })
    }
    print(items.map { "\($0.parameter.name) (\($0.conversion.units))" }.joined(separator: " | "))
    let all = Dictionary(set.parameters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let lock = NSLock()
    session.startPolling(items: items, allParameters: all, onSample: { sample in
        lock.lock(); defer { lock.unlock() }
        let line = polled.map { item in
            sample.values[item.parameter.id].map { item.conversion.formatted($0) } ?? "-"
        }.joined(separator: " | ")
        print(line)
        writer?.append(time: sample.time, values: sample.values)
    }, onError: { error, fatal in
        print("! \(error.localizedDescription)")
        if fatal { writer?.close(); exit(2) }
    })
    signal(SIGINT) { _ in exit(0) }
    let seconds = option("--seconds").flatMap(Double.init) ?? .infinity
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { Thread.sleep(forTimeInterval: 0.2) }
    session.stopPolling()
    lock.lock()
    writer?.close()
    lock.unlock()
    if let path = option("--csv") { print("Saved \(path)") }

case "demo":
    let defs = try? LoggerDefinitions.bundled()
    guard let demo = try? DemoECU.make(definitions: defs) else { fail("could not start demo ECU") }
    print("Demo ECU (JDM GRB STI) listening on \(demo.ecu.devicePath). Ctrl-C to stop.")
    print("Try: subiescope-cli probe --port \(demo.ecu.devicePath)")
    withExtendedLifetime(demo) { while true { Thread.sleep(forTimeInterval: 1) } }

default:
    print(usage)
    exit(1)
}
