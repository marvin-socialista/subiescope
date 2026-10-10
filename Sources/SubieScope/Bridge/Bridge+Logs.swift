#if os(Windows) || DEBUG
import Foundation
import SSMKit

/// Recorded logs: the list of files in the recordings folder, and the viewer for the log that is
/// open (its charts, the playback, the values under the pointer).
///
/// The viewer's state comes in three pieces, by how often they change: `logs.viewer` once per log,
/// `logs.view` with every click (which charts, which stretch of time, playing or not), and
/// `logs.cursor` with every sample that plays and every move of the pointer. The numbers of the log
/// themselves are far too many for a slice: the page asks for them once per log with `logs.load`
/// and gets them as the event `logs.data`. It draws the charts from them; every text comes from here.
extension Bridge {
    struct LogsState: Encodable {
        struct File: Encodable {
            /// The file's name. The page also names the file by it in its actions.
            let name: String
            /// "24 Sep 2026 at 22:57 · 64 KB"
            let detail: String
            /// What to ask before the file is deleted: "Move … to the Trash?"
            let deleteQuestion: String
        }

        /// The CSV files in the recordings folder, newest first.
        let files: [File]
        /// The file of the list that is open, or being opened.
        let selected: String?
        /// Where recordings are saved, for the text of an empty list.
        let folder: String
        /// A log is open: the viewer is shown.
        let isOpen: Bool
        /// Why the last file could not be opened. Shown while no log is open.
        let error: String?
        /// "Show in Finder" or "Show in File Explorer".
        let revealLabel: String
        /// "Move to Trash" or "Delete", and what the question about it adds, if anything.
        let deleteLabel: String
        let deleteDetail: String?
    }

    /// The log that is open. Nothing in it changes while it is open.
    struct LogViewerState: Encodable {
        struct Column: Encodable {
            /// The name as it is shown ("IAM"), and as the log has it, which is what the filter looks in.
            let name: String
            let logName: String
            /// The whole column heading of the file, for the tooltip.
            let header: String
            let units: String
            /// How many decimals a value of this column is written with, for the numbers along a chart.
            let decimals: Int
        }

        /// Another number for every log that is opened. The page asks for this log's numbers with it.
        let id: Int
        let file: String
        /// "842 rows · 14 values · 16.8 samples/s"
        let info: String
        /// Seconds from the first row to the last.
        let duration: Double
        /// Where the small chart of the whole log has its lines: the marks of a time axis over all of it.
        let overviewTicks: [Double]
        let columns: [Column]
    }

    /// What is shown of the open log, and what the playback is doing.
    struct LogViewState: Encodable {
        struct Chart: Encodable {
            /// Which column, counted from 0.
            let column: Int
            /// Which of the eight series colours (`--series-0` and on) it keeps while it is charted.
            let color: Int
        }

        struct Tick: Encodable {
            let time: Double
            let label: String
        }

        /// The charts from top to bottom.
        let charts: [Chart]
        /// The stretch of the log the charts show, in seconds.
        let from: Double
        let to: Double
        let zoomed: Bool
        /// Where the time axis has its marks, and what they say.
        let ticks: [Tick]
        let playing: Bool
        let speed: Double
        let speeds: [Double]
        /// The Gauges button: the dashboard plays the log only while the car is not connected.
        let gaugesEnabled: Bool
        let gaugesHelp: String
    }

    /// The playhead and the values next to it. Sent with every sample that plays.
    struct LogCursorState: Encodable {
        /// Seconds into the log.
        let playhead: Double
        /// "0:12.4 / 0:50.0"
        let time: String
        /// The moment the values are of: under the pointer when it is over a chart, else the playhead.
        let snapshotTime: String
        let hovering: Bool
        /// One value per column, as text.
        let values: [String]
    }

    /// What this part remembers between two messages from the page.
    @MainActor
    private final class LogsMemory {
        /// The files of the list as it was last sent, by name.
        var listed: [String: URL] = [:]
        /// The file of the list that is being opened, and the one that could not be.
        var opening: String?
        var failed: String?
        /// The log the page was last told about, and the number it got. The numbers start at the
        /// clock, so a page that outlives the app (in development) does not take a new log for the one it has.
        weak var playback: LogPlayback?
        var serial = Int(Date().timeIntervalSince1970) % 1_000_000 * 1000

        func id(of playback: LogPlayback) -> Int {
            if self.playback !== playback {
                self.playback = playback
                serial += 1
            }
            return serial
        }
    }

    func registerLogs() {
        let memory = LogsMemory()

        slice("logs") { [model] in
            // Read so the list is made again when a recording starts or ends, as the Mac's list does.
            _ = model.isRecording
            let files = Bridge.logFiles(in: model.logsFolder)
            memory.listed = Dictionary(files.map { ($0.url.lastPathComponent, $0.url) }, uniquingKeysWith: { first, _ in first })
            let open = model.playback?.url
            var selected = memory.opening
            if selected == nil, let open {
                selected = files.first { $0.url == open || $0.url.standardizedFileURL.path == open.standardizedFileURL.path }?.url.lastPathComponent
            }
            if selected == nil, open == nil, model.playbackError != nil { selected = memory.failed }
            return LogsState(
                files: files.map { file -> LogsState.File in
                    let name = file.url.lastPathComponent
                    let size = Bridge.logSizeText(file.size)
                    return LogsState.File(name: name, detail: "\(SystemTimeZone.text(file.date, date: .abbreviated, time: .shortened)) · \(size)",
                                 deleteQuestion: Bridge.onWindows ? "Move \(name) to the Recycle Bin?" : "Move \(name) to the Trash?")
                },
                selected: selected,
                folder: Bridge.logsFolderText(model.logsFolder),
                isOpen: open != nil,
                error: open == nil ? model.playbackError : nil,
                revealLabel: "Show in \(Bridge.fileBrowser)",
                deleteLabel: Bridge.onWindows ? "Move to Recycle Bin" : "Move to Trash",
                deleteDetail: nil)
        }

        slice("logs.viewer") { [model] () -> LogViewerState? in
            guard let playback = model.playback else { return nil }
            let log = playback.log
            var info = "\(log.rowCount) rows · \(log.columns.count) values"
            if playback.duration > 0 {
                info += String(format: " · %.1f samples/s", Double(log.rowCount - 1) / playback.duration)
            }
            return LogViewerState(
                id: memory.id(of: playback), file: playback.url.lastPathComponent, info: info,
                duration: playback.duration.finite ?? 0,
                overviewTicks: Bridge.logTimeTicks(0...max(playback.duration, 0.001)),
                columns: log.columns.indices.map { i in
                    .init(name: playback.parameters[i].displayName, logName: log.columns[i].name, header: log.columns[i].header,
                          units: playback.conversions[i].displayUnits, decimals: playback.conversions[i].decimals)
                })
        }

        slice("logs.view") { [model] () -> LogViewState? in
            guard let playback = model.playback else { return nil }
            let range = playback.visibleRange
            let span = range.upperBound - range.lowerBound
            // (The Mac's TimeAxis: finer numbers the closer the charts are zoomed in.)
            let decimals = span < 5 ? 2 : (span < 60 ? 1 : 0)
            let connected = model.connection.isConnected
            return LogViewState(
                charts: playback.chartColumns.map { .init(column: $0, color: playback.colorSlots[$0] ?? 0) },
                from: range.lowerBound.finite ?? 0, to: range.upperBound.finite ?? 0, zoomed: playback.isZoomed,
                ticks: Bridge.logTimeTicks(range).map { .init(time: $0, label: formatLogTime($0, decimals: decimals)) },
                playing: playback.isPlaying, speed: playback.speed, speeds: LogPlayback.speeds,
                gaugesEnabled: !connected,
                gaugesHelp: connected ? "The dashboard shows live data while connected" : "Watch the playback on the dashboard gauges")
        }

        slice("logs.cursor", atMost: 30) { [model] () -> LogCursorState? in
            guard let playback = model.playback else { return nil }
            let log = playback.log
            let moment = playback.snapshotTime
            let row = log.row(at: moment)
            return LogCursorState(
                playhead: playback.playhead.finite ?? 0,
                time: "\(formatLogTime(playback.playhead)) / \(formatLogTime(playback.duration))",
                snapshotTime: formatLogTime(moment, decimals: 2),
                hovering: playback.hoverTime != nil,
                values: log.columns.indices.map { playback.conversions[$0].formatted(log.rowCount > 0 ? log.values[$0][row] : .nan) })
        }

        // MARK: The list

        // The files are on disk, where the model does not see them change.
        action("logs.reload") { [weak self] _ in self?.invalidate("logs") }

        action("logs.select") { [weak self, model] arguments in
            guard let name = arguments.string("name"), let url = memory.listed[name] else { return }
            memory.opening = name
            memory.failed = nil
            self?.invalidate("logs")
            Task { @MainActor in
                await model.openLog(url)
                if memory.opening == name { memory.opening = nil }
                if model.playback == nil { memory.failed = name }
                self?.invalidate("logs")
            }
        }

        // Any SubieScope or RomRaider log, from wherever it is.
        action("logs.open") { [model] _ in
            guard let url = Desktop.chooseFileToOpen(filter: ["Logs", "*.csv;*.txt"]) else { return }
            memory.failed = nil
            model.section = .logs
            Task { await model.openLog(url) }
        }

        #if DEBUG
        // The same without the question, for trying the page where nobody can answer a file dialog.
        action("logs.openPath") { [model] arguments in
            guard let path = arguments.string("path") else { return }
            memory.failed = nil
            model.section = .logs
            Task { await model.openLog(URL(fileURLWithPath: path)) }
        }
        #endif

        action("logs.openFolder") { [model] _ in
            try? FileManager.default.createDirectory(at: model.logsFolder, withIntermediateDirectories: true)
            Desktop.open(model.logsFolder)
        }
        action("logs.reveal") { arguments in
            guard let url = arguments.string("name").flatMap({ memory.listed[$0] }) else { return }
            Desktop.reveal(url)
        }
        action("logs.openExternally") { arguments in
            guard let url = arguments.string("name").flatMap({ memory.listed[$0] }) else { return }
            Desktop.open(url)
        }
        // The page has asked the person first. A log that is open stays open: it was read whole.
        action("logs.delete") { [weak self] arguments in
            guard let name = arguments.string("name"), let url = memory.listed[name] else { return }
            Bridge.discardLog(url)
            if memory.failed == name { memory.failed = nil }
            self?.invalidate("logs")
        }

        // MARK: The viewer

        // The numbers of the open log, once. `id` says which log the page means: an answer for a log
        // that has been closed in the meantime would only be thrown away.
        action("logs.load") { [weak self, model] arguments in
            guard let playback = model.playback, arguments.int("id") == memory.id(of: playback) else { return }
            self?.emit("logs.data", json: Bridge.json(of: playback.log, id: memory.id(of: playback)))
        }

        // Where the pointer is over the charts, in seconds, or nothing when it has left them.
        action("logs.hover") { [model] arguments in
            guard let playback = model.playback else { return }
            let time = arguments.double("time")
            if playback.hoverTime != time { playback.hoverTime = time }
        }
        action("logs.step") { [model] arguments in
            guard let rows = arguments.int("rows") else { return }
            model.playback?.step(rows: rows)
        }
        action("logs.zoom") { [model] arguments in
            guard let from = arguments.double("from"), let to = arguments.double("to"), from < to else { return }
            model.playback?.zoom(to: from...to)
        }
        // `factor` below 1 zooms in. `anchor` is the moment that stays where it is.
        action("logs.zoomBy") { [model] arguments in
            guard let factor = arguments.double("factor"), factor > 0, let anchor = arguments.double("anchor") else { return }
            model.playback?.zoom(by: factor, around: anchor)
        }
        action("logs.resetZoom") { [model] _ in model.playback?.resetZoom() }
        // A drag over the small chart of the whole log: the playhead goes there, and so does the
        // stretch that is zoomed in on. (The Mac's OverviewStrip.)
        action("logs.scrub") { [model] arguments in
            guard let playback = model.playback, let time = arguments.double("time") else { return }
            if playback.isZoomed {
                let width = playback.visibleRange.upperBound - playback.visibleRange.lowerBound
                let start = min(max(0, time - width / 2), playback.duration - width)
                playback.zoom(to: start...(start + width))
            }
            playback.seek(time)
        }
        action("logs.toggleChart") { [model] arguments in
            guard let playback = model.playback, let column = arguments.int("column"), playback.log.columns.indices.contains(column) else { return }
            playback.toggleChart(column)
        }
        action("logs.moveChart") { [model] arguments in
            guard let column = arguments.int("column") else { return }
            model.playback?.moveChart(column, up: arguments.bool("up"))
        }
    }

    // MARK: Files

    /// The CSV files of a folder, newest first. (The Mac's LogsView.reload.)
    static func logFiles(in folder: URL) -> [(url: URL, date: Date, size: Int)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "csv" }.map { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
            return (url, date, size)
        }
        .sorted { $0.date > $1.date }
    }

    /// A file's size the way a file browser writes it: "512 bytes", "64 KB", "1.2 MB".
    /// (The Mac's list uses ByteCountFormatter's file style, which counts in thousands.)
    static func logSizeText(_ bytes: Int) -> String {
        if bytes < 1000 { return bytes == 0 ? "Zero KB" : "\(bytes) byte\(bytes == 1 ? "" : "s")" }
        let size = Double(bytes)
        if size < 999_500 { return String(format: "%.0f KB", size / 1000) }
        if size < 999_950_000 { return String(format: "%.1f MB", size / 1_000_000) }
        return String(format: "%.2f GB", size / 1_000_000_000)
    }

    /// A folder's path as a person reads it on this computer.
    static func logsFolderText(_ url: URL) -> String {
        #if os(Windows)
        return Desktop.path(url)
        #else
        return url.path
        #endif
    }

    /// Takes a log out of the list: into the Trash on a Mac, into the Recycle Bin on Windows.
    static func discardLog(_ file: URL) {
        Desktop.trash(file)
    }

    // MARK: Numbers

    /// Where the time axis has its marks: about eight, on round numbers. (The Mac's TimeAxis.ticks.)
    static func logTimeTicks(_ range: ClosedRange<Double>, targetCount: Double = 8) -> [Double] {
        let span = range.upperBound - range.lowerBound
        guard span > 0, span.isFinite else { return [] }
        let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200]
        let step = steps.first { span / $0 <= targetCount } ?? 1800
        var time = (range.lowerBound / step).rounded(.up) * step
        var ticks: [Double] = []
        // The count is a guard only: a log of days would otherwise make thousands of marks.
        while time <= range.upperBound + 1e-9, ticks.count < 200 {
            ticks.append(time)
            time += step
        }
        return ticks
    }

    /// A whole log as JSON: {"id": 3, "time": [seconds…], "values": [[one column…], …]}, with null
    /// where a cell was empty. Written by hand: a log is easily a million numbers.
    static func json(of log: RecordedLog, id: Int) -> String {
        var json = "{\"id\":\(id),\"time\":["
        json.reserveCapacity((log.columns.count + 1) * log.rowCount * 8 + 64)
        append(log.time, to: &json)
        json += "],\"values\":["
        for (index, column) in log.values.enumerated() {
            json += index == 0 ? "[" : ",["
            append(column, to: &json)
            json += "]"
        }
        json += "]}"
        return json
    }

    private static func append(_ numbers: [Double], to json: inout String) {
        var first = true
        for number in numbers {
            if first { first = false } else { json += "," }
            // A whole number without its ".0": most of a log is whole numbers, and it is a third shorter.
            if !number.isFinite {
                json += "null"
            } else if number == number.rounded(), abs(number) < 1e15 {
                json += String(Int64(number))
            } else {
                json += "\(number)"
            }
        }
    }
}
#endif
