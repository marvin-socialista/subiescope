#if os(Windows) || DEBUG
import Foundation
import Observation
import SSMKit

/// The console: what the app did and, when that is asked for, every message to and from the car.
///
/// Lines come in all the time while connected, so the list is not a slice: that would send all of
/// it again with every line. The page asks for the list once (the request `console.lines`). From
/// then on it gets what is new a few times a second (the event `console.lines`), until it says
/// `console.stop`.
extension Bridge {
    struct ConsoleState: Encodable {
        /// "Show raw traffic" is ticked: every message to and from the car gets a line.
        let capturesTraffic: Bool
    }

    /// Some lines of the console: all of them as the answer to the request, the new ones in an event.
    struct ConsoleBatch: Encodable {
        struct Line: Encodable {
            /// Counts up with every line, and goes on counting after the console is cleared.
            let id: Int
            /// Who said it, for the colour: "sent", "echo", "received" or "garbage". Left out for a line of the app itself.
            let kind: String?
            /// The line as it is shown: the time, an arrow for who said it, and the text.
            let text: String
        }

        /// The oldest line the app still holds. The page drops what is older: the console was
        /// cleared, or it has more lines than the app keeps. Left out when there are no lines at all.
        let first: Int?
        /// The lines the page does not have yet, oldest first.
        let lines: [Line]
    }

    func registerConsole() {
        let feed = ConsoleFeed(bridge: self)

        slice("console") { [model] in
            ConsoleState(capturesTraffic: model.consoleCapturesTraffic)
        }

        // Every line there is now, and the start of the events with what comes after.
        request("console.lines") { _ in feed.start() }
        // The page no longer shows the console.
        action("console.stop") { _ in feed.stop() }

        action("console.captureTraffic") { [model] arguments in
            model.consoleCapturesTraffic = arguments.bool("on")
        }
        action("console.clear") { [model] _ in model.clearConsole() }
        action("console.copyAll") { [model] _ in
            Desktop.copy(model.consoleLines.map { Bridge.consoleText($0) }.joined(separator: "\n"))
        }
    }

    static func consoleLine(_ line: ConsoleLine) -> ConsoleBatch.Line {
        let kind: String?
        switch line.kind {
        case .sent?: kind = "sent"
        case .echo?: kind = "echo"
        case .received?: kind = "received"
        case .garbage?: kind = "garbage"
        case nil: kind = nil
        }
        return ConsoleBatch.Line(id: line.id, kind: kind, text: consoleText(line))
    }

    /// A line as the console shows and copies it. (The Mac app's `ConsoleView.format`.)
    static func consoleText(_ line: ConsoleLine) -> String {
        let arrow: String
        switch line.kind {
        case .sent?: arrow = "→"
        case .echo?: arrow = "↩"
        case .received?: arrow = "←"
        case .garbage?: arrow = "?"
        case nil: arrow = "•"
        }
        return "\(consoleClock.string(from: line.time))  \(arrow) \(line.text)"
    }

    /// The time of day to the millisecond: "14:03:22.512".
    private static let consoleClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

/// Follows the model's console for the page, for as long as the page shows it.
@MainActor
private final class ConsoleFeed {
    private weak var bridge: Bridge?
    private var watching = false
    /// The model's list is being watched for its next change.
    private var armed = false
    private var flushScheduled = false
    /// The newest line the page has, and the oldest one it was told to keep.
    private var newestSent = 0
    private var firstSent: Int?

    /// New lines wait this long (in nanoseconds) for more of them, so the page gets a handful at a
    /// time instead of a message for every line.
    private static let pause: UInt64 = 80_000_000

    init(bridge: Bridge) {
        self.bridge = bridge
    }

    /// Every line there is now. What comes after follows as events.
    func start() -> Bridge.ConsoleBatch {
        guard let bridge else { return Bridge.ConsoleBatch(first: nil, lines: []) }
        let lines = bridge.model.consoleLines
        watching = true
        newestSent = lines.last?.id ?? newestSent
        firstSent = lines.first?.id
        arm()
        return Bridge.ConsoleBatch(first: firstSent, lines: lines.map { Bridge.consoleLine($0) })
    }

    func stop() {
        watching = false
    }

    /// Asks to be told once when the list changes. Nothing is sent from here: a change only starts the pause.
    private func arm() {
        guard watching, !armed, let model = bridge?.model else { return }
        armed = true
        withObservationTracking {
            _ = model.consoleLines.count
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.armed = false
                self.scheduleFlush()
            }
        }
    }

    private func scheduleFlush() {
        guard watching, !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: ConsoleFeed.pause)
            self.flushScheduled = false
            self.flush()
        }
    }

    /// Sends the lines the page does not have yet, and what it can drop.
    private func flush() {
        guard watching, let bridge else { return }
        let lines = bridge.model.consoleLines
        // New lines are at the end, so that is where to look for them.
        var start = lines.count
        while start > 0, lines[start - 1].id > newestSent { start -= 1 }
        let first = lines.first?.id
        if start < lines.count || first != firstSent {
            bridge.emit("console.lines", Bridge.ConsoleBatch(first: first, lines: lines[start...].map { Bridge.consoleLine($0) }))
            newestSent = lines.last?.id ?? newestSent
            firstSent = first
        }
        arm()
    }
}
#endif
