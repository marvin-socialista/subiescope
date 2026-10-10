#if os(Windows) || DEBUG
import Foundation
import Observation
import SSMKit

/// Connects the app model to a page that shows it.
///
/// SubieScope for Windows has no SwiftUI: its window is a web page (Sources/SubieScope/Windows/Web).
/// The page knows nothing by itself. This class tells it what to show, as named pieces of state
/// ("slices") that are sent again whenever the model changes, and does what the page asks for
/// ("actions" and "requests"). The pieces for each part of the app are in the Bridge+... files.
///
/// On a Mac the same code runs in debug builds only, behind `-webDev` (see WebDevServer), so the
/// page can be worked on without a Windows PC.
@MainActor
final class Bridge {
    let model: AppModel

    /// Where a message for the page goes, as one line of JSON text. Set by whoever hosts the page.
    var transmit: (String) -> Void = { _ in }

    private var slices: [Slice] = []
    private var actions: [String: (Arguments) -> Void] = [:]
    private var requests: [String: (Arguments) async -> String] = [:]
    private var pageIsReady = false
    private var flushScheduled = false

    init(model: AppModel) {
        self.model = model
        registerAll()
        action("page.ready") { [weak self] _ in self?.pageReady() }
    }

    // MARK: Saying what the page shows

    /// A named piece of state. `state` runs once the page is there, and again every time something it
    /// read from the model has changed; the result goes to the page when it differs from the last one.
    ///
    /// Read only what the page shows for this piece: a slice that reads the live values is sent with
    /// every sample. `atMost` holds a busy slice back to that many sends a second.
    func slice<State: Encodable>(_ name: String, atMost perSecond: Double? = nil, _ state: @escaping @MainActor () -> State) {
        slices.append(Slice(name: name, minInterval: perSecond.map { 1 / $0 } ?? 0) { Bridge.json(state()) })
    }

    /// For state the model cannot announce itself (a file on disk, a setting outside the model):
    /// has the slice worked out again.
    func invalidate(_ name: String) {
        guard let slice = slices.first(where: { $0.name == name }) else { return }
        slice.dirty = true
        scheduleFlush()
    }

    /// Something that happens once, not a state: a line for the console, a file that was saved.
    func emit<Event: Encodable>(_ name: String, _ event: Event) {
        guard pageIsReady, let json = Bridge.json(event) else { return }
        transmit("{\"event\":\(Bridge.quoted(name)),\"data\":\(json)}")
    }

    /// The same, for data that is already JSON text (large tables of numbers are faster to write by hand).
    func emit(_ name: String, json: String) {
        guard pageIsReady else { return }
        transmit("{\"event\":\(Bridge.quoted(name)),\"data\":\(json)}")
    }

    // MARK: Doing what the page asks

    /// Something the page asks the app to do: `send('name', {…})` in the page.
    func action(_ name: String, _ handler: @escaping @MainActor (Arguments) -> Void) {
        actions[name] = handler
    }

    /// Something the page asks and waits for: `await request('name', {…})` in the page.
    func request<Reply: Encodable>(_ name: String, _ handler: @escaping @MainActor (Arguments) async -> Reply) {
        requests[name] = { arguments in Bridge.json(await handler(arguments)) ?? "null" }
    }

    /// A message from the page, as JSON text.
    func receive(_ text: String) {
        guard let data = text.data(using: .utf8),
              case .object(let message)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            DiagnosticLog.shared.warning("bridge", "A message from the page that is not JSON")
            return
        }
        let arguments = Arguments(values: message)
        if let name = arguments.string("action") {
            guard let handler = actions[name] else {
                DiagnosticLog.shared.warning("bridge", "The page asked for an unknown action: \(name)")
                return
            }
            handler(arguments)
        } else if let name = arguments.string("request"), let id = arguments.int("id") {
            guard let handler = requests[name] else {
                DiagnosticLog.shared.warning("bridge", "The page made an unknown request: \(name)")
                transmit("{\"reply\":\(id),\"value\":null}")
                return
            }
            Task { @MainActor in
                let value = await handler(arguments)
                self.transmit("{\"reply\":\(id),\"value\":\(value)}")
            }
        }
    }

    // MARK: Keeping the page up to date

    /// The page has loaded (or loaded again): it gets everything.
    func pageReady() {
        pageIsReady = true
        for slice in slices {
            slice.dirty = true
            slice.lastJSON = nil
            slice.lastSent = .distantPast
        }
        flush()
    }

    private func scheduleFlush() {
        guard pageIsReady, !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in
            self.flushScheduled = false
            self.flush()
        }
    }

    private func flush() {
        guard pageIsReady else { return }
        let now = Date()
        for slice in slices where slice.dirty {
            let wait = slice.minInterval - now.timeIntervalSince(slice.lastSent)
            if wait > 0.001 {
                // Too soon after the last one: come back when its time is up.
                guard !slice.waiting else { continue }
                slice.waiting = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    slice.waiting = false
                    self.flush()
                }
                continue
            }
            refresh(slice, at: now)
        }
    }

    private func refresh(_ slice: Slice, at now: Date) {
        slice.dirty = false
        // Whatever the slice reads from the model while it is worked out is watched: the first change
        // to any of it marks the slice as out of date.
        let json = withObservationTracking {
            slice.encode()
        } onChange: { [weak self, weak slice] in
            Task { @MainActor in
                slice?.dirty = true
                self?.scheduleFlush()
            }
        }
        guard let json, json != slice.lastJSON else { return }
        slice.lastJSON = json
        slice.lastSent = now
        transmit("{\"slice\":\(Bridge.quoted(slice.name)),\"state\":\(json)}")
    }

    private final class Slice: @unchecked Sendable {
        let name: String
        let minInterval: TimeInterval
        let encode: @MainActor () -> String?
        var dirty = true
        var waiting = false
        var lastJSON: String?
        var lastSent = Date.distantPast

        init(name: String, minInterval: TimeInterval, encode: @escaping @MainActor () -> String?) {
            self.name = name
            self.minInterval = minInterval
            self.encode = encode
        }
    }

    // MARK: JSON

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // A date travels as seconds since 1970, which is what the page's Date takes (times 1000).
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    /// A number that is not a number has no place in JSON: where one slips through, it is sent as text
    /// rather than losing the whole slice. Use `finite` on values that can be one.
    private static let forgivingEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }()

    static func json<Value: Encodable>(_ value: Value) -> String? {
        if let data = try? encoder.encode(value) { return String(decoding: data, as: UTF8.self) }
        guard let data = try? forgivingEncoder.encode(value) else {
            DiagnosticLog.shared.warning("bridge", "State that cannot be written as JSON: \(Value.self)")
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func quoted(_ text: String) -> String {
        json(text) ?? "\"\""
    }
}

/// What came with an action or a request from the page.
struct Arguments {
    let values: [String: JSONValue]

    func string(_ key: String) -> String? {
        if case .string(let text)? = values[key] { return text }
        return nil
    }

    func bool(_ key: String) -> Bool {
        if case .bool(let flag)? = values[key] { return flag }
        return false
    }

    func double(_ key: String) -> Double? {
        if case .number(let number)? = values[key] { return number }
        return nil
    }

    func int(_ key: String) -> Int? {
        double(key).flatMap { Int(exactly: $0.rounded()) }
    }

    func strings(_ key: String) -> [String] {
        guard case .array(let items)? = values[key] else { return [] }
        return items.compactMap { if case .string(let text) = $0 { return text } else { return nil } }
    }

    func doubles(_ key: String) -> [Double] {
        guard case .array(let items)? = values[key] else { return [] }
        return items.compactMap { if case .number(let number) = $0 { return number } else { return nil } }
    }

    /// A value of a type of its own, for arguments with more shape than a text or a number.
    func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let value = values[key], let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Any JSON, read without knowing its shape.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let items = try? container.decode([JSONValue].self) {
            self = .array(items)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let flag): try container.encode(flag)
        case .number(let number): try container.encode(number)
        case .string(let text): try container.encode(text)
        case .array(let items): try container.encode(items)
        case .object(let members): try container.encode(members)
        }
    }
}

extension Double {
    /// Nil for a value that JSON cannot hold (not a number, or infinite).
    var finite: Double? { isFinite ? self : nil }
}
#endif
