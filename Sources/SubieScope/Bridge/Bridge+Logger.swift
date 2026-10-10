#if os(Windows) || DEBUG
import Foundation
import SSMKit

/// The logger: on the left every value the car can report, with a tick for the ones that are logged;
/// on the right the last minute of each logged value as a small graph, under the Record button.
extension Bridge {
    /// The list on the left, without what changes with a tick or with every sample. It is sent again
    /// only when the car, the definitions or the units change.
    struct LoggerParameters: Encodable {
        struct Unit: Encodable {
            let units: String
            let label: String
        }

        struct Row: Encodable {
            /// The page also searches in this: "P8" finds Engine Speed.
            let id: String
            let name: String
            /// The small line under the name, when the definition says more than its own id.
            let detail: String?
            /// The whole description, for the tooltip.
            let help: String?
            /// A switch says ON or OFF and has no units.
            let isSwitch: Bool
            /// The units the value is shown in ("°C").
            let units: String
            /// The units to choose from, when there is more than one.
            let unitChoices: [Unit]
        }

        struct Group: Encodable {
            /// "Standard", "Switches": the heading. The page adds how many of its rows it shows.
            let title: String
            let rows: [Row]
        }

        /// The groups that have something in them, in the order of the list.
        let groups: [Group]
        /// How many values there are in all, for "Search 126 parameters".
        let count: Int
    }

    /// What is ticked, what has a graph, and the state of the recording.
    struct LoggerState: Encodable {
        struct Trend: Encodable {
            let id: String
            let name: String
            let units: String
        }

        /// The ids of the values that are logged, and of the ones with a gauge on the dashboard.
        let logged: [String]
        let onDashboard: [String]
        /// How many values of the list are logged, for "Logged (21)".
        let loggedCount: Int
        /// Said above the list while it shows more than this car has.
        let offlineNote: String?
        /// The values that get a graph, in the order of the list.
        let trends: [Trend]
        /// What the right side says when there is nothing to graph.
        let emptyText: String
        /// How many seconds the width of a graph stands for.
        let window: Double

        let isRecording: Bool
        /// "Recording subiescope_….csv", while a log is being written.
        let recordingTitle: String?
        /// What the bar says otherwise: how to start a recording, or that there is no car.
        let recordHint: String
        let canRecord: Bool
    }

    /// What changes with every sample from the car.
    struct LoggerLive: Encodable {
        /// The newest value of everything the car reports, as the list and the graphs show it ("93.73", "ON").
        let values: [String: String]
        /// The line under the list: how much is asked from the car and how fast it answers.
        let speedHint: String
        /// While recording: "412 rows · 10.8 samples/s".
        let recordingDetail: String?
        /// The number of the newest point of the graphs. A new one means there is something to ask
        /// `logger.points` for.
        let newest: Int?
    }

    /// The answer to `logger.points`: what the graphs got since the page last asked.
    ///
    /// The page keeps the last minute of every graph itself and asks only for what is new. Sending
    /// the whole minute of twenty values with every sample would be some 25,000 numbers each time.
    struct LoggerPoints: Encodable {
        struct Series: Encodable {
            /// False when the page has to forget what it had of this value: the app started it again
            /// (new units, a new connection), or `points` is all there is.
            let keep: Bool
            /// The points as "time,value,time,value…", oldest first. Time in thousandths of a second
            /// on the clock of the graphs; only the distance between two of them means something.
            let points: String
        }

        /// Where the points come from: the car, or a log that is played back. The page hands it back
        /// with its next question, so points of two sources never end up in one graph.
        let source: String
        /// The number of the newest point there is: what to ask after the next time.
        let newest: Int
        /// One for every value that has a graph. A value that is missing here has none any more.
        let series: [String: Series]
    }

    func registerLogger() {
        slice("logger.parameters") { [model] in
            // (The Mac app's `ParameterBrowser.sections`.)
            let titles: [(String, ParameterKind)] = [
                ("Wideband Gauge", .external), ("Standard", .standard), ("ECU Specific (Extended)", .extended),
                ("Calculated", .calculated), ("Switches", .switchBit),
            ]
            let groups = titles.compactMap { title, kind -> LoggerParameters.Group? in
                let rows = model.parameters.filter { $0.kind == kind }.map { parameter -> LoggerParameters.Row in
                    let described = !parameter.description.isEmpty && parameter.description != parameter.id
                    return LoggerParameters.Row(
                        id: parameter.id, name: parameter.name,
                        detail: described ? parameter.description.replacingOccurrences(of: "\(parameter.id)-", with: "") : nil,
                        help: parameter.description.isEmpty ? nil : parameter.description,
                        isSwitch: kind == .switchBit,
                        units: kind == .switchBit ? "" : model.conversion(for: parameter)?.displayUnits ?? "",
                        unitChoices: kind != .switchBit && parameter.conversions.count > 1
                            ? parameter.conversions.map { .init(units: $0.units, label: $0.displayUnits) } : [])
                }
                return rows.isEmpty ? nil : LoggerParameters.Group(title: title, rows: rows)
            }
            return LoggerParameters(groups: groups, count: model.parameters.count)
        }

        slice("logger") { [model] in
            let connected = model.connection.isConnected
            let trends = Bridge.loggerTrends(model).map { parameter in
                LoggerState.Trend(id: parameter.id, name: parameter.displayName,
                                  units: model.conversion(for: parameter)?.displayUnits ?? "")
            }
            let recording = model.isRecording ? model.recordingURL : nil
            return LoggerState(
                // Sorted, so the same choice is the same text and is not sent twice.
                logged: model.loggedIDs.sorted(), onDashboard: model.dashboardIDs,
                loggedCount: model.parameters.filter { model.loggedIDs.contains($0.id) }.count,
                offlineNote: connected ? nil
                    : "Offline: showing every parameter in the definitions. After connecting, only the ones your ECU supports remain.",
                trends: trends,
                emptyText: connected ? "Tick parameters on the left to log them." : "Connect to the car to see live values.",
                window: AppModel.historySeconds,
                isRecording: recording != nil,
                recordingTitle: recording.map { "Recording \($0.lastPathComponent)" },
                recordHint: connected ? "Press Record (\(Bridge.onWindows ? "Ctrl+R" : "⌘R")) to save the ticked parameters to a CSV file."
                    : "Not connected",
                canRecord: connected && !model.loggedIDs.isEmpty)
        }

        slice("logger.live", atMost: 20) { [model] in
            var values: [String: String] = [:]
            for (id, value) in model.latest {
                guard let parameter = model.parametersByID[id] else { continue }
                if parameter.kind == .switchBit {
                    values[id] = value != 0 ? "ON" : "OFF"
                } else {
                    values[id] = model.conversion(for: parameter)?.formatted(value) ?? ""
                }
            }
            // (The Mac app's `ParameterBrowser.speedHint`.)
            let polled = model.loggedIDs.union(model.dashboardIDs)
            let addresses = model.parameters.filter { $0.kind != .external && polled.contains($0.id) }
                .reduce(0) { $0 + max(1, $1.addresses.count) }
            let rate = model.samplesPerSecond > 0 ? String(format: " · %.1f samples/s", model.samplesPerSecond) : ""
            var newest: Int?
            for parameter in Bridge.loggerTrends(model) {
                if let last = model.history[parameter.id]?.last { newest = max(newest ?? last.id, last.id) }
            }
            return LoggerLive(
                values: values,
                speedHint: "\(addresses) addresses polled\(rate). Fewer parameters log faster.",
                recordingDetail: model.isRecording
                    ? "\(model.recordedRows) rows · \(String(format: "%.1f", model.samplesPerSecond)) samples/s" : nil,
                newest: newest)
        }

        // What the graphs got since the page last asked. `after` is the `newest` of the last answer
        // (nothing the first time), `source` its source, `known` the values the page has points of.
        request("logger.points") { [model] arguments -> LoggerPoints in
            let source = model.isPlayingBack ? "log:" + (model.playback?.url.path ?? "") : "live"
            let trended = Bridge.loggerTrends(model)
            var newest = -1
            for parameter in trended {
                if let last = model.history[parameter.id]?.last { newest = max(newest, last.id) }
            }
            let after = arguments.int("after") ?? -1
            // Another source, or numbers that went back (a log that was wound back): nothing the page has is of use.
            let startOver = after < 0 || after > newest || arguments.string("source") != source
            let known = startOver ? [] : Set(arguments.strings("known"))
            var series: [String: LoggerPoints.Series] = [:]
            for parameter in trended {
                let points = model.history[parameter.id] ?? []
                // The page's points still count when the app has one of them left. After new units or a
                // new connection all of the app's points are newer than anything the page was sent.
                let keep = known.contains(parameter.id) && (points.first.map { $0.id <= after } ?? false)
                var start = keep ? points.count : 0
                while keep, start > 0, points[start - 1].id > after { start -= 1 }
                series[parameter.id] = .init(keep: keep, points: Bridge.loggerPointsText(points[start...]))
            }
            return LoggerPoints(source: source, newest: newest, series: series)
        }

        action("logger.log") { [model] arguments in
            guard let id = arguments.string("id") else { return }
            if arguments.bool("on") {
                guard model.parametersByID[id] != nil else { return }
                model.loggedIDs.insert(id)
            } else {
                model.loggedIDs.remove(id)
            }
        }
        action("logger.logNothing") { [model] _ in model.loggedIDs = [] }
        action("logger.logDashboard") { [model] _ in model.loggedIDs = Set(model.dashboardIDs) }
        action("logger.units") { [model] arguments in
            guard let id = arguments.string("id"), let units = arguments.string("units"),
                  model.parametersByID[id]?.conversions.contains(where: { $0.units == units }) == true else { return }
            model.unitChoice[id] = units
        }
        // The gauge button of a row: puts the value on the dashboard, or takes it off.
        action("logger.dashboard") { [model] arguments in
            guard let id = arguments.string("id") else { return }
            if !arguments.bool("on") {
                model.dashboardIDs.removeAll { $0 == id }
            } else if model.parametersByID[id] != nil, !model.dashboardIDs.contains(id) {
                model.dashboardIDs.append(id)
            }
        }
    }

    /// The values that get a graph: the logged ones, or everything in a log that is played back.
    /// A switch has no graph. (The Mac app's `LiveTrends.trended`.)
    static func loggerTrends(_ model: AppModel) -> [ParameterDefinition] {
        if model.isPlayingBack { return model.parameters.filter { $0.kind != .switchBit } }
        return model.parameters.filter { model.loggedIDs.contains($0.id) && $0.kind != .switchBit }
    }

    /// Points as "time,value,time,value…": written by hand, because a minute of every graph is too
    /// many numbers for the JSON encoder to be quick with. A graph does not need more digits than
    /// a Float has.
    static func loggerPointsText(_ points: ArraySlice<ChartPoint>) -> String {
        var text = ""
        text.reserveCapacity(points.count * 18)
        for point in points {
            let value = Float(point.value)
            guard point.t.isFinite, abs(point.t) < 1e12, value.isFinite else { continue }
            if !text.isEmpty { text.append(",") }
            text.append(String(Int((point.t * 1000).rounded())))
            text.append(",")
            text.append(value.description)
        }
        return text
    }
}
#endif
