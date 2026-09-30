import CoreBluetooth
import Foundation

/// A Bluetooth LE device seen while scanning.
public struct BLEAdapter: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var rssi: Int
    /// The name looks like an OBD-II adapter (Vgate iCar / vLinker, OBDLink, Veepeak ...).
    public var looksLikeOBD: Bool
}

public enum BLEStatus: Equatable, Sendable {
    case idle, scanning, poweredOff, unauthorized, unsupported
    case unavailable(String)

    public var message: String? {
        switch self {
        case .idle, .scanning: return nil
        case .poweredOff: return "Bluetooth is turned off. Turn it on in the menu bar or System Settings."
        case .unauthorized: return "SubieScope is not allowed to use Bluetooth. Allow it in System Settings > Privacy & Security > Bluetooth."
        case .unsupported: return "This Mac has no Bluetooth Low Energy."
        case .unavailable(let reason): return reason
        }
    }
}

private func bluetoothUsageDescriptionMissing() -> Bool {
    Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") == nil
}

private let bluetoothMissingText = "Bluetooth only works in the SubieScope app itself, not in a command line build."

/// Looks for Bluetooth LE devices nearby. Nothing is created (and macOS does not ask for
/// permission) until `start()` is called.
public final class BLEScanner: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    public var onChange: (@Sendable (BLEStatus, [BLEAdapter]) -> Void)?

    private let queue = DispatchQueue(label: "subiescope.ble.scan")
    private var central: CBCentralManager?
    private var seen: [String: (adapter: BLEAdapter, last: Date)] = [:]
    private var status: BLEStatus = .idle
    private var wantsScan = false
    private var timer: DispatchSourceTimer?

    static let namePatterns = ["vlink", "vgate", "icar", "obd", "elm", "veepeak", "carista", "viecar", "kw", "vlinker",
                               "tonwon", "fixd", "bluedriver", "carly", "scan", "konnwei"]

    public override init() { super.init() }

    public func start() {
        queue.async { [self] in
            if bluetoothUsageDescriptionMissing() {
                publish(.unavailable(bluetoothMissingText))
                return
            }
            wantsScan = true
            if central == nil {
                central = CBCentralManager(delegate: self, queue: queue)   // asks for permission the first time
            } else {
                beginScanning()
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in self?.prune() }
            timer.resume()
            self.timer?.cancel()
            self.timer = timer
        }
    }

    public func stop() {
        queue.async { [self] in
            wantsScan = false
            timer?.cancel()
            timer = nil
            central?.stopScan()
            if status == .scanning { status = .idle }
        }
    }

    private func publish(_ new: BLEStatus? = nil) {
        if let new { status = new }
        let list = seen.values.map(\.adapter).sorted {
            ($0.looksLikeOBD ? 0 : 1, -$0.rssi) < ($1.looksLikeOBD ? 0 : 1, -$1.rssi)
        }
        onChange?(status, list)
    }

    private func prune() {
        let before = seen.count
        seen = seen.filter { Date().timeIntervalSince($0.value.last) < 12 }
        if seen.count != before { publish() }
    }

    private func beginScanning() {
        guard let central, central.state == .poweredOn, wantsScan else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        publish(.scanning)
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DiagnosticLog.shared.info("ble", "Scanner: Bluetooth state \(central.state.rawValue)")
        switch central.state {
        case .poweredOn: beginScanning()
        case .poweredOff: publish(.poweredOff)
        case .unauthorized: publish(.unauthorized)
        case .unsupported: publish(.unsupported)
        default: break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard !name.isEmpty else { return }
        let lower = name.lowercased()
        let adapter = BLEAdapter(id: peripheral.identifier.uuidString, name: name, rssi: RSSI.intValue,
                                 looksLikeOBD: Self.namePatterns.contains { lower.contains($0) })
        let isNew = seen[adapter.id] == nil
        seen[adapter.id] = (adapter, Date())
        if isNew {
            DiagnosticLog.shared.info("ble", "Found \"\(adapter.name)\" rssi \(adapter.rssi)\(adapter.looksLikeOBD ? " (looks like OBD-II)" : "")")
            publish()
        }
    }
}

/// An ELM327 adapter over Bluetooth LE. Cheap adapters such as the Vgate iCar Pro use a
/// serial-over-BLE service; the vendors do not agree on its UUID, so the notify and
/// write characteristics are found by their properties rather than by a fixed ID.
public final class BLEChannel: NSObject, ELMChannel, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    /// Services adapters are known to use, tried first.
    static let knownServices = ["FFF0", "FFE0", "18F0", "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2", "49535343-FE7D-4AE5-8FA9-9FAFD205E455"]

    private let targetID: UUID
    private let queue = DispatchQueue(label: "subiescope.ble.channel")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withoutResponse
    private var pendingServices = 0
    private var opening: CheckedContinuation<Void, Error>?

    private let cond = NSCondition()
    private var buffer = Data()
    private var disconnected = false

    private init(id: UUID) {
        targetID = id
        super.init()
    }

    /// Connects to the adapter and gets it ready to talk.
    public static func open(id: String, timeout: TimeInterval = 15) async throws -> BLEChannel {
        guard let uuid = UUID(uuidString: id) else { throw OBDError.adapterNotFound("Unknown Bluetooth device.") }
        if bluetoothUsageDescriptionMissing() { throw OBDError.adapterNotFound(bluetoothMissingText) }
        let channel = BLEChannel(id: uuid)
        try await channel.openConnection(timeout: timeout)
        return channel
    }

    private func openConnection(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                opening = continuation
                central = CBCentralManager(delegate: self, queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    finishOpening(.failure(OBDError.adapterNotFound(
                        "Could not connect to the adapter. Is it plugged into the car with the ignition ON, and close to your Mac? Another app (or your phone) may be connected to it: adapters like this accept only one connection.")))
                }
            }
        }
    }

    private func finishOpening(_ result: Result<Void, Error>) {
        guard let continuation = opening else { return }
        opening = nil
        if case .failure = result { central?.stopScan(); if let p = peripheral { central?.cancelPeripheralConnection(p) } }
        continuation.resume(with: result)
    }

    // MARK: ELMChannel

    public func exchange(_ command: String, timeout: TimeInterval) throws -> String {
        cond.lock()
        buffer.removeAll()
        cond.unlock()
        try write(Data((command + "\r").utf8))

        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        defer { cond.unlock() }
        while true {
            if disconnected { throw OBDError.disconnected }
            if let end = buffer.firstIndex(of: UInt8(ascii: ">")) {
                let text = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...end)
                return text
            }
            if !cond.wait(until: deadline) { throw OBDError.timeout(command) }
        }
    }

    private func write(_ data: Data) throws {
        var peripheral: CBPeripheral?
        var characteristic: CBCharacteristic?
        var type = CBCharacteristicWriteType.withoutResponse
        queue.sync { peripheral = self.peripheral; characteristic = writeCharacteristic; type = writeType }
        guard let peripheral, let characteristic, peripheral.state == .connected else { throw OBDError.disconnected }
        let size = max(20, peripheral.maximumWriteValueLength(for: type))
        var offset = 0
        while offset < data.count {
            let chunk = data.subdata(in: offset..<min(offset + size, data.count))
            peripheral.writeValue(chunk, for: characteristic, type: type)
            offset += size
            if offset < data.count { Thread.sleep(forTimeInterval: 0.01) }
        }
    }

    public func close() {
        queue.async { [self] in
            if let peripheral, let notify = notifyCharacteristic, peripheral.state == .connected {
                peripheral.setNotifyValue(false, for: notify)
            }
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            peripheral = nil
        }
        cond.lock(); disconnected = true; cond.broadcast(); cond.unlock()
    }

    // MARK: CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DiagnosticLog.shared.info("ble", "Channel: Bluetooth state \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            if let known = central.retrievePeripherals(withIdentifiers: [targetID]).first {
                connect(known)
            } else {
                central.scanForPeripherals(withServices: nil, options: nil)
            }
        case .poweredOff: finishOpening(.failure(OBDError.adapterNotFound(BLEStatus.poweredOff.message ?? "")))
        case .unauthorized: finishOpening(.failure(OBDError.adapterNotFound(BLEStatus.unauthorized.message ?? "")))
        case .unsupported: finishOpening(.failure(OBDError.adapterNotFound(BLEStatus.unsupported.message ?? "")))
        default: break
        }
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        central.stopScan()
        central.connect(p, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if peripheral.identifier == targetID { connect(peripheral) }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DiagnosticLog.shared.info("ble", "Connected to \(peripheral.name ?? "adapter"), discovering services")
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        DiagnosticLog.shared.error("ble", "Connect failed: \(error?.localizedDescription ?? "unknown")")
        finishOpening(.failure(OBDError.adapterNotFound("Could not connect to the adapter: \(error?.localizedDescription ?? "unknown error").")))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DiagnosticLog.shared.warning("ble", "Disconnected: \(error?.localizedDescription ?? "no error")")
        cond.lock(); disconnected = true; cond.broadcast(); cond.unlock()
        finishOpening(.failure(OBDError.disconnected))
    }

    // MARK: CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        guard error == nil, !services.isEmpty else {
            finishOpening(.failure(OBDError.adapterNotFound("The device has no Bluetooth services, so it is probably not an OBD-II adapter.")))
            return
        }
        pendingServices = services.count
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        pendingServices -= 1
        guard pendingServices <= 0 else { return }
        choose(from: peripheral.services ?? [])
        for service in peripheral.services ?? [] {
            let props = (service.characteristics ?? []).map { "\($0.uuid.uuidString)[\($0.properties.rawValue)]" }.joined(separator: " ")
            DiagnosticLog.shared.info("ble", "Service \(service.uuid.uuidString): \(props)")
        }
        DiagnosticLog.shared.info("ble", "Using notify \(notifyCharacteristic?.uuid.uuidString ?? "none"), write \(writeCharacteristic?.uuid.uuidString ?? "none")")
        guard let notify = notifyCharacteristic, writeCharacteristic != nil else {
            finishOpening(.failure(OBDError.adapterNotFound("Could not find the serial channel of this device, so it is probably not an OBD-II adapter.")))
            return
        }
        peripheral.setNotifyValue(true, for: notify)
    }

    /// Prefers a known adapter service, and one characteristic that both writes and notifies
    /// (the usual "serial" characteristic) over two separate ones.
    private func choose(from services: [CBService]) {
        let ordered = services.sorted { rank($0) < rank($1) }
        for service in ordered {
            let characteristics = service.characteristics ?? []
            let notify = characteristics.filter { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
            let write = characteristics.filter { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }
            guard let n = notify.first(where: { c in write.contains { $0.uuid == c.uuid } }) ?? notify.first,
                  let w = write.first(where: { $0.uuid == n.uuid }) ?? write.first else { continue }
            notifyCharacteristic = n
            writeCharacteristic = w
            writeType = w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            return
        }
    }

    private func rank(_ service: CBService) -> Int {
        let id = service.uuid.uuidString.uppercased()
        return Self.knownServices.firstIndex { id == $0 || id.hasPrefix("0000" + $0) } ?? 99
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            finishOpening(.failure(OBDError.adapterNotFound("Could not listen to the adapter: \(error.localizedDescription).")))
        } else if characteristic.isNotifying {
            finishOpening(.success(()))
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        cond.lock()
        buffer.append(data)
        cond.broadcast()
        cond.unlock()
    }
}
