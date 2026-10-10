import Foundation
import SSMKit

// subiescope-cli: command line access to the same SSM code the app uses.
// Handy for a first test at the car, and for pasting output when asking for help.

let usage = """
usage: subiescope-cli <command> [options]

commands:
  ports                      List serial ports (the FTDI cable shows as cu.usbserial-…, on Windows as COM3 or another number)
  probe                      Connect, show raw traffic and identify the ECU
  params                     List the parameters this ECU supports
  log                        Print live values (and optionally write a CSV)
  codes                      Read trouble codes
  freeze                     Read the freeze frame: what the engine was doing when a trouble code was
                             stored (through a Tactrix OpenPort, over CAN)
  demo                       Run the demo ECU on a pseudo terminal for testing
  demo --openport            Run the demo ECU behind a simulated Tactrix OpenPort 2.0 instead
  demo --obd                 Run a simulated OBD-II adapter instead, as a USB cable and as a Wi-Fi adapter,
                             with a simulated AEM wideband gauge next to it
  remote <command>           Talk to a running SubieScope and its OBD-II adapter (see `remote help`)
  rom <file>                 Inspect a ROM file: size, calibration ID and checksum state
  rom fix <file> [out]       Correct the checksums in a ROM file and save (never touches the car)
  rom maps <file> <defs.xml> List the maps this ROM has, using a RomRaider ecu_defs.xml
  rom read <file> <defs.xml> "<map name>"   Print one map's values

options:
  --port PATH                Serial device, on Windows a COM port (default: first FTDI/USB port)
  --demo                     Use the built-in demo ECU instead of a cable
  --openport                 The port is a Tactrix OpenPort 2.0 (a real one is recognised
                             by itself). With --demo: put a simulated OpenPort in front of the demo ECU
  --can                      With an OpenPort: talk to the ECU over CAN instead of the K-line
                             (experimental; Subarus from about 2008 on)
  --scenario NAME            Demo only: what the demo car does (idle, cruise, wotPull, …)
  --fault NAME               Demo only: simulate a fault (dirtyMAF, vacuumLeak, knock, …)
  --defs FILE                RomRaider logger definition XML (default: built-in)
  --params "A,B,…"           Parameter names or IDs for `log` (default: a useful STI set)
  --csv FILE                 Also write the log to FILE
  --seconds N                Stop `log` after N seconds
  --no-fast                  Disable fast poll (continuous mode)
  --verbose                  Also print the raw traffic for params, log, codes and freeze (probe always does)
  --tcp PORT                 demo --obd only: the port of the simulated Wi-Fi adapter (default 35000)
"""

SystemTimeZone.apply()

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
var demoOpenPort: SimulatedOpenPort?
/// The chosen port is a Tactrix OpenPort 2.0, not a KKL cable.
var throughOpenPort = false

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
            if flag("--openport") {
                demoOpenPort = try SimulatedOpenPort(ecu: demoECU!.ecu)
                let car = demoECU!
                demoOpenPort!.canECU = { car.answerOverCAN($0) }
                throughOpenPort = true
                return demoOpenPort!.devicePath
            }
            return demoECU!.ecu.devicePath
        } catch {
            fail("could not start demo ECU: \(error.localizedDescription)")
        }
    }
    let ports = SerialPortList.available()
    if let port = option("--port") {
        throughOpenPort = flag("--openport") || ports.contains { $0.path == port && $0.isOpenPort }
        return port
    }
    guard let port = ports.first(where: \.isFTDI) ?? ports.first(where: \.isOpenPort) ?? ports.first(where: \.isUSB) else {
        fail("no USB serial cable found. Plug in the cable, or pass --port /dev/cu.… (see `subiescope-cli ports`)")
    }
    throughOpenPort = flag("--openport") || port.isOpenPort
    return port.path
}

func makeSession(_ defs: LoggerDefinitions?, verbose: Bool) -> SSMSession {
    let path = resolvePort(defs)
    let overCAN = throughOpenPort && flag("--can")
    if flag("--can") && !throughOpenPort { fail("--can needs a Tactrix OpenPort 2.0: a KKL cable only has the K-line") }
    let session = SSMSession(portPath: path, openPort: throughOpenPort, overCAN: overCAN)
    session.fastPoll = !flag("--no-fast")
    if let demoECU { session.transport.onBreak = { demoECU.ecu.simulateBreak() } }
    if verbose {
        session.openPort?.log = { print("  cable      \($0)") }
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
    print("Port: \(path)\(demoECU != nil ? " (demo ECU)" : "")\(throughOpenPort ? " (Tactrix OpenPort 2.0\(overCAN ? ", over CAN, experimental" : ""))" : "")")
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
        if p.isOpenPort { tags.append("Tactrix OpenPort 2.0") }
        if let v = p.vendorID, let pid = p.productID { tags.append(String(format: "USB %04X:%04X", v, pid)) }
        if let s = p.serialNumber { tags.append("serial \(s)") }
        print("\(p.path)\t\(p.productName ?? "")\t\(tags.joined(separator: ", "))")
    }

case "probe":
    let defs = try? LoggerDefinitions.bundled()
    let session = makeSession(defs, verbose: true)
    print(session.overCAN ? "Sending init request (0xAA) over CAN…" : "Sending init request (0xBF) at 4800 baud…")
    let identity = blocking { try await session.connect() }
    print("")
    print("ECU ID:        \(identity.ecuID)")
    print("Car:           \(EngineDiagnostics.knownECUs[identity.ecuID] ?? "not in the list of known ECUs")")
    if let ecu = KnownECU.lookup(identity.ecuID).first, let transport = ecu.flashTransport {
        print("ROM:           \(ecu.processorDescription ?? "?"), read and written over \(transport == .can ? "CAN" : "the K-line") (EcuFlash calls it \(ecu.flashMethod ?? "?"))")
    }
    print("System ID:     \(identity.systemIDString) (\(EngineDiagnostics.engineType(systemID: identity.systemID) ?? "unknown engine"))")
    print("Capabilities:  \(identity.capabilities.count) bytes: \(identity.capabilities.hexString)")
    if let cable = session.openPort {
        let volts = blocking { try await session.run { _ in try cable.batteryVoltage() } }
        print("Cable:         Tactrix OpenPort 2.0, firmware \(cable.firmware ?? "?"), car battery \(String(format: "%.1f", volts)) V")
    }
    // A second and a third exchange: an ECU that identifies itself does not always go on to give values.
    // Coolant temperature (0x08) and engine speed (0x0E, 0x0F) are in every SSM2 engine ECU.
    let readTest: (bytes: [UInt8], first: Double, second: Double, error: String?) = blocking {
        let started = Date()
        do {
            let bytes = try await session.run { try $0.read(addresses: [0x08, 0x0E, 0x0F]) }
            let first = Date().timeIntervalSince(started)
            let again = Date()
            _ = try await session.run { try $0.read(addresses: [0x08, 0x0E, 0x0F]) }
            return (bytes, first, Date().timeIntervalSince(again), nil)
        } catch {
            return ([], 0, 0, error.localizedDescription)
        }
    }
    if let error = readTest.error {
        print("Read test:     FAILED. The ECU identified itself but did not give values: \(error)")
    } else {
        let rpm = (Int(readTest.bytes[1]) << 8 | Int(readTest.bytes[2])) / 4
        print("Read test:     coolant \(Int(readTest.bytes[0]) - 40) °C, engine speed \(rpm) rpm (\(Int(readTest.first * 1000)) ms, then \(Int(readTest.second * 1000)) ms)")
    }
    if let defs {
        let set = defs.parameterSet(for: identity)
        let count = { (k: ParameterKind) in set.parameters.filter { $0.kind == k }.count }
        print("Supported:     \(count(.standard)) standard, \(count(.extended)) ECU specific, \(count(.calculated)) calculated, \(count(.switchBit)) switches")
        if count(.extended) == 0 {
            print("               (ECU ID not in the definitions: no IAM/knock learning parameters)")
        }
    }
    session.closeAndWait()

case "params":
    let defs = loadDefinitions()
    let session = makeSession(defs, verbose: flag("--verbose"))
    let identity = blocking { try await session.connect() }
    for p in defs.parameterSet(for: identity).parameters {
        let units = p.conversions.map(\.units).joined(separator: ", ")
        print("\(p.id)\t\(p.name)\t[\(units)]")
    }
    session.closeAndWait()

case "codes":
    let defs = loadDefinitions()
    let session = makeSession(defs, verbose: flag("--verbose"))
    let identity = blocking { try await session.connect() }
    let set = defs.parameterSet(for: identity)
    let report = blocking { try await session.run { try TroubleCodeReport.read(with: $0, definitions: set.diagnosticCodes) } }
    print("Current codes:   \(report.current.isEmpty ? "none" : "")")
    for c in report.current { print("  \(c.name)") }
    print("Memorized codes: \(report.memorized.isEmpty ? "none" : "")")
    for c in report.memorized { print("  \(c.name)") }
    session.closeAndWait()

case "freeze":
    let session = makeSession(try? LoggerDefinitions.bundled(), verbose: flag("--verbose"))
    guard session.openPort != nil else {
        fail("the freeze frame is read over CAN, which needs a Tactrix OpenPort 2.0 (in the app, an OBD-II adapter reads it too)")
    }
    _ = blocking { try await session.connect() }
    if let frame = blocking({ try await session.readFreezeFrame() }) {
        print("Freeze frame: \(frame.summary)")
        for line in frame.lines() { print("  \(line.name): \(line.value)") }
    } else {
        print("Freeze frame: the ECU has none stored (normal without stored trouble codes)")
    }
    session.closeAndWait()

case "log":
    let defs = loadDefinitions()
    let session = makeSession(defs, verbose: flag("--verbose"))
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
    session.onRefused = { ids in
        print("! the ECU refuses these over CAN, they are left out: \(ids.compactMap { all[$0]?.name }.joined(separator: ", "))")
    }
    nonisolated(unsafe) var rows = 0
    let logStart = Date()
    session.startPolling(items: items, allParameters: all, onSample: { sample in
        lock.lock(); defer { lock.unlock() }
        rows += 1
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
    // Ends the ECU's stream and lets go of the cable before the program ends.
    session.closeAndWait()
    lock.lock()
    writer?.close()
    let elapsed = Date().timeIntervalSince(logStart)
    print(String(format: "%d samples in %.1f s: %.1f per second", rows, elapsed, Double(rows) / max(elapsed, 0.001)))
    lock.unlock()
    if let path = option("--csv") { print("Saved \(path)") }

case "remote":
    // Live control of the running app: raw requests to the connected adapter, without rebuilding anything.
    // Needs Settings > General > "Let the command line tool control the app" (or -remoteControl YES).
    func remoteSend(_ line: String, timeout: TimeInterval = 30) -> [String] {
        do { return try RemoteClient.send(line, timeout: timeout) } catch { fail(error.localizedDescription) }
    }
    if args.first == "scan22" {
        // remote scan22 <request header> <response header> <first DID> <last DID>, e.g. 7E0 7E8 0000 00FF
        guard args.count >= 5, let first = UInt16(args[3], radix: 16), let last = UInt16(args[4], radix: 16), first <= last else {
            fail("usage: subiescope-cli remote scan22 <request header> <response header> <first DID> <last DID>   e.g. 7E0 7E8 0000 00FF")
        }
        _ = remoteSend("send ATSH\(args[1])"); _ = remoteSend("send ATCRA\(args[2])")
        print("Scanning Mode 22 on \(args[1]) -> \(args[2]), \(String(format: "%04X", first)) to \(String(format: "%04X", last)). Only answers are shown.")
        var found = 0
        for did in first...last {
            let request = String(format: "22%04X", did)
            let reply = remoteSend("send \(request)").joined(separator: " ")
            let noAnswer = reply.uppercased().contains("NO DATA") || reply.contains("(no reply)") || reply.isEmpty
            if !noAnswer { print("\(request) -> \(reply)"); found += 1 }
        }
        print("\(found) DIDs answered.")
        _ = remoteSend("release")
    } else {
        let reply = remoteSend(args.isEmpty ? "help" : args.joined(separator: " "))
        reply.forEach { print($0) }
    }

case "demo" where flag("--obd"):
    // Stands in for the adapters nobody has on the desk: the app talks to these over its real USB and Wi-Fi code.
    let wifiPort = option("--tcp").flatMap { UInt16($0) } ?? OBDAdapterLink.defaultPort
    // One simulated car behind both adapters, so the wideband gauge in its exhaust follows whichever is used.
    let world = DemoWorld()
    guard let usb = try? SimulatedELMServer.serial(adapter: SimulatedELM(world: world)), let path = usb.devicePath else { fail("could not start the simulated USB adapter") }
    guard let wifi = try? SimulatedELMServer.network(adapter: SimulatedELM(world: world), port: wifiPort) else { fail("could not listen on port \(wifiPort): is it in use? Try --tcp with another port.") }
    guard let gauge = try? SimulatedWideband(world: world) else { fail("could not start the simulated wideband gauge") }
    usb.adapter.enableDemoExtended()
    wifi.adapter.enableDemoExtended()
    print("Simulated OBD-II adapter with a demo car. Ctrl-C to stop.")
    #if os(Windows)
    // Windows has no pseudo terminals: only the Wi-Fi adapter can be reached from another program.
    print("  As a Wi-Fi adapter:  127.0.0.1:\(wifiPort)")
    print("In SubieScope: type the Wi-Fi address in the connection panel, or start the app with")
    print("  -connectionMode obd -selectedAdapter wifi:127.0.0.1:\(wifiPort)")
    #else
    print("  As a USB adapter:    \(path)")
    print("  As a Wi-Fi adapter:  127.0.0.1:\(wifiPort)")
    print("  AEM wideband gauge:  \(gauge.devicePath)")
    print("In SubieScope: type the Wi-Fi address in the connection panel, or start the app with")
    print("  -connectionMode obd -selectedAdapter usb:\(path)")
    print("and add the gauge with")
    print("  -widebandOn YES -widebandPort \(gauge.devicePath)")
    #endif
    fflush(stdout)   // so the path shows up when the output goes to a file or a pipe
    withExtendedLifetime((usb, wifi, gauge)) { while true { Thread.sleep(forTimeInterval: 1) } }

case "rom":
    // Works on a file only. It never opens a serial port or talks to a car.
    func describe(_ rom: ROMImage, path: String) {
        print("File:          \(path)")
        print("Size:          \(rom.byteCount) bytes" + (rom.size.map { " (\($0.label))" } ?? " (not a standard Subaru ROM size)"))
        print("Calibration:   \(rom.calibrationID() ?? "unknown (may not be a Subaru 32-bit ROM)")")
        print("Fingerprint:   \(rom.quickFingerprint)")
        if let report = try? SubaruChecksum.verifyPetrol(rom) {
            if report.allDisabled {
                print("Checksums:     all disabled in this ROM")
            } else if report.ok {
                print("Checksums:     OK (\(report.records.filter { !$0.isBlank }.count) active regions)")
            } else {
                print("Checksums:     \(report.mismatchCount) of \(report.records.filter { !$0.isBlank }.count) regions do NOT match. Run `rom fix` after editing.")
            }
        } else {
            print("Checksums:     no checksum layout known for this size")
        }
    }

    func loadDefs(_ path: String, _ rom: ROMImage) -> (ROMDefinitionSet, ROMDefinition) {
        guard let set = try? ROMDefinitionParser.load(url: URL(fileURLWithPath: path)) else {
            fail("could not read the definitions \(path)")
        }
        guard let def = set.definition(matching: rom) else {
            fail("no definition in \(path) matches this ROM's internal ID (calibration \(rom.calibrationID() ?? "unknown"))")
        }
        return (set, def)
    }

    let sub = args.first
    if sub == "defcheck" {
        // Parses a RomRaider ecu_defs.xml and reports what came out, for checking against the real file.
        guard args.count >= 2 else { fail("usage: subiescope-cli rom defcheck <defs.xml> [xmlid]") }
        guard let set = try? ROMDefinitionParser.load(url: URL(fileURLWithPath: args[1])) else { fail("could not parse \(args[1])") }
        print("Definitions: \(set.definitions.count)   Shared scalings: \(set.scalings.count)")
        let withID = set.definitions.values.filter { $0.identity.internalIDString != nil }.count
        print("With an internal ID (matchable): \(withID)")
        if args.count >= 3 {
            let tables = set.resolvedTables(forXmlID: args[2])
            let editable = tables.filter { $0.isEditable }
            print("\(args[2]): \(tables.count) tables, \(editable.count) editable")
            for t in editable.prefix(12) {
                let dims = t.dimension == .threeD ? "\(t.sizeX)x\(t.sizeY)" : (t.dimension == .twoD ? "\(t.sizeX)" : "1")
                print("  [\(t.category)] \(t.name) (\(dims)) @0x\(String(t.address ?? 0, radix: 16))")
            }
        } else {
            // Show a few example ROM IDs to try.
            for def in set.definitions.values.filter({ $0.identity.internalIDString != nil }).prefix(6) {
                print("  e.g. \(def.identity.xmlID)  base=\(def.identity.base ?? "-")")
            }
        }
    } else if sub == "maps" {
        guard args.count >= 3 else { fail("usage: subiescope-cli rom maps <file> <defs.xml>") }
        guard let rom = try? ROMImage(contentsOf: URL(fileURLWithPath: args[1])) else { fail("could not read \(args[1])") }
        let (set, def) = loadDefs(args[2], rom)
        let tables = set.resolvedTables(forXmlID: def.identity.xmlID).filter { $0.isEditable }
        print("Matched \(def.identity.xmlID); \(tables.count) maps:")
        var lastCategory = ""
        for t in tables {
            let category = t.category.isEmpty ? "Other" : t.category
            if category != lastCategory { print("  [\(category)]"); lastCategory = category }
            let dims = t.dimension == .threeD ? "\(t.sizeX)x\(t.sizeY)" : (t.dimension == .twoD ? "\(t.sizeX)" : "1")
            print("    \(t.name)  (\(dims))")
        }
    } else if sub == "read" {
        guard args.count >= 4 else { fail("usage: subiescope-cli rom read <file> <defs.xml> \"<map name>\"") }
        guard let rom = try? ROMImage(contentsOf: URL(fileURLWithPath: args[1])) else { fail("could not read \(args[1])") }
        let (set, def) = loadDefs(args[2], rom)
        let name = args[3]
        guard let tableDef = set.resolvedTables(forXmlID: def.identity.xmlID).first(where: { $0.name == name }) else {
            fail("no map named \"\(name)\" in this ROM")
        }
        guard let table = try? ROMTable.read(rom, def: tableDef, scalings: set.scalings) else {
            fail("could not read the map \"\(name)\"")
        }
        print("\(table.def.name)  [\(table.units)]  format \(table.format)")
        for r in 0..<table.rows {
            let prefix = (table.def.dimension == .threeD && r < table.yLabels.count) ? String(format: "%8.2f | ", table.yLabels[r]) : ""
            print(prefix + table.values[r].map { String(format: "%8.2f", $0) }.joined(separator: " "))
        }
    } else if sub == "fix" {
        guard args.count >= 2 else { fail("usage: subiescope-cli rom fix <file> [output file]") }
        let inPath = args[1]
        let outPath = args.count >= 3 ? args[2] : inPath.replacingOccurrences(of: ".bin", with: "") + "-fixed.bin"
        guard let rom = try? ROMImage(contentsOf: URL(fileURLWithPath: inPath)) else { fail("could not read \(inPath)") }
        print(ROMDisclaimer.short)
        print("")
        guard let (fixed, report) = try? SubaruChecksum.correctPetrol(rom) else {
            fail("no checksum layout for this ROM size (\(rom.byteCount) bytes)")
        }
        if report.allDisabled {
            print("This ROM has its checksums disabled; nothing to correct.")
        } else if report.ok && fixed == rom {
            print("Checksums were already correct; wrote an identical copy.")
        } else {
            print("Corrected \(rom.quickFingerprint) → \(fixed.quickFingerprint); checksums now OK.")
        }
        do {
            try fixed.write(to: URL(fileURLWithPath: outPath))
            print("Saved to \(outPath)")
        } catch { fail("could not write \(outPath): \(error.localizedDescription)") }
    } else {
        guard let path = sub else { fail("usage: subiescope-cli rom <file>   (or: rom fix <file> [out])") }
        guard let rom = try? ROMImage(contentsOf: URL(fileURLWithPath: path)) else { fail("could not read \(path)") }
        describe(rom, path: path)
    }

case "demo" where flag("--openport"):
    // Stands in for the Tactrix OpenPort nobody has on the desk, with the demo car on its K-line.
    #if os(Windows)
    fail("On Windows the simulated cable can only be reached from inside one program. Use: subiescope-cli probe --demo --openport, or the app with -selectedPort demo -demoCable openport")
    #endif
    let defs = try? LoggerDefinitions.bundled()
    guard let demo = try? DemoECU.make(definitions: defs), let cable = try? SimulatedOpenPort(ecu: demo.ecu) else {
        fail("could not start the simulated OpenPort")
    }
    print("Simulated Tactrix OpenPort 2.0 with the demo ECU (JDM GRB STI) on \(cable.devicePath). Ctrl-C to stop.")
    print("Try: subiescope-cli probe --openport --port \(cable.devicePath)")
    fflush(stdout)
    withExtendedLifetime((demo, cable)) { while true { Thread.sleep(forTimeInterval: 1) } }

case "demo":
    #if os(Windows)
    fail("On Windows the demo ECU can only be reached from inside one program. Use --demo with probe, params, log or codes, or pick the demo car in the app. (demo --obd does work: it also listens on a network port.)")
    #endif
    let defs = try? LoggerDefinitions.bundled()
    guard let demo = try? DemoECU.make(definitions: defs) else { fail("could not start demo ECU") }
    print("Demo ECU (JDM GRB STI) listening on \(demo.ecu.devicePath). Ctrl-C to stop.")
    print("Try: subiescope-cli probe --port \(demo.ecu.devicePath)")
    withExtendedLifetime(demo) { while true { Thread.sleep(forTimeInterval: 1) } }

default:
    print(usage)
    exit(1)
}
