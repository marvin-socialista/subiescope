import Foundation
import Observation
import SSMKit

/// A recorded log opened for viewing and playback.
@MainActor
@Observable
final class LogPlayback {
    let url: URL
    let log: RecordedLog
    /// One parameter per log column, matched to the definitions by name where possible.
    let parameters: [ParameterDefinition]
    let conversions: [Conversion]
    /// Min/max of each column over the whole log.
    let extremes: [ClosedRange<Double>?]

    /// Current playback position in seconds.
    private(set) var playhead: Double = 0
    /// Time under the mouse pointer, if it is over a chart.
    var hoverTime: Double?
    private(set) var isPlaying = false
    var speed: Double = 1
    private(set) var visibleRange: ClosedRange<Double>
    /// Columns shown as charts, in the order they were added. A column keeps its
    /// color slot for as long as it is charted.
    private(set) var chartColumns: [Int] = []
    private(set) var colorSlots: [Int: Int] = [:]

    @ObservationIgnored var onPlayhead: ((Double) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?

    static let speeds: [Double] = [0.25, 0.5, 1, 2, 4, 8]

    init(url: URL, log: RecordedLog, definitions: [ParameterDefinition]) {
        self.url = url
        self.log = log
        var parameters: [ParameterDefinition] = []
        var conversions: [Conversion] = []
        var used = Set<String>()
        for (i, column) in log.columns.enumerated() {
            let values = log.values[i].filter(\.isFinite)
            let integral = values.allSatisfy { $0 == $0.rounded() }
            let match = definitions.first { $0.name == column.name && !used.contains($0.id) }
            var conversion = match?.conversions.first { $0.units == column.units }
                ?? Conversion(units: column.units, expression: "x", format: integral ? "0" : "0.00")
            conversion.expression = "x"   // values in a log are already converted
            var parameter = match ?? ParameterDefinition(id: "LOG\(i)", name: column.name, kind: .standard,
                                                         conversions: [conversion])
            if used.contains(parameter.id) { parameter.id = "LOG\(i)" }
            used.insert(parameter.id)
            parameter.conversions = [conversion]
            parameters.append(parameter)
            conversions.append(conversion)
        }
        self.parameters = parameters
        self.conversions = conversions
        extremes = log.values.map { column in
            let finite = column.filter(\.isFinite)
            guard let lo = finite.min(), let hi = finite.max() else { return nil }
            return lo...hi
        }
        visibleRange = 0...max(log.duration, 0.001)
        for column in Self.defaultCharts(log) { toggleChart(column) }
    }

    var duration: Double { log.duration }
    var snapshotTime: Double { hoverTime ?? playhead }
    var isZoomed: Bool { visibleRange.lowerBound > 0.0001 || visibleRange.upperBound < duration - 0.0001 }

    func value(_ column: Int, at t: Double) -> Double {
        guard log.rowCount > 0 else { return .nan }
        return log.values[column][log.row(at: t)]
    }

    func values(at t: Double) -> [String: Double] {
        guard log.rowCount > 0 else { return [:] }
        let row = log.row(at: t)
        var out: [String: Double] = [:]
        for (i, p) in parameters.enumerated() { out[p.id] = log.values[i][row] }
        return out
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard log.rowCount > 1 else { return }
        if playhead >= duration { seek(0) }
        isPlaying = true
        task?.cancel()
        task = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, self.isPlaying else { return }
                let now = Date()
                self.advance(by: now.timeIntervalSince(last))
                last = now
            }
        }
    }

    func pause() {
        isPlaying = false
        task?.cancel()
        task = nil
    }

    private func advance(by dt: Double) {
        let t = playhead + dt * speed
        if t >= duration {
            seek(duration)
            pause()
        } else {
            seek(t)
        }
    }

    /// Moves the playhead; the visible window follows when the playhead leaves it.
    func seek(_ t: Double) {
        playhead = min(max(0, t), duration)
        if !visibleRange.contains(playhead) {
            let width = visibleRange.upperBound - visibleRange.lowerBound
            let start = min(max(0, playhead - width * 0.1), max(0, duration - width))
            visibleRange = start...(start + width)
        }
        onPlayhead?(playhead)
    }

    func step(rows: Int) {
        guard log.rowCount > 0 else { return }
        let row = min(max(0, log.row(at: playhead) + rows), log.rowCount - 1)
        seek(log.time[row])
    }

    // MARK: Zoom

    func zoom(to range: ClosedRange<Double>) {
        let lo = max(0, range.lowerBound), hi = min(duration, range.upperBound)
        guard hi - lo >= 0.25 else { return }
        visibleRange = lo...hi
    }

    /// Zooms by `factor` (<1 zooms in) keeping `anchor` in place.
    func zoom(by factor: Double, around anchor: Double) {
        let width = visibleRange.upperBound - visibleRange.lowerBound
        let newWidth = min(duration, max(0.5, width * factor))
        let ratio = width > 0 ? (anchor - visibleRange.lowerBound) / width : 0.5
        var lo = anchor - newWidth * ratio
        lo = min(max(0, lo), max(0, duration - newWidth))
        visibleRange = lo...(lo + newWidth)
    }

    func resetZoom() {
        visibleRange = 0...max(duration, 0.001)
    }

    // MARK: Charts

    func toggleChart(_ column: Int) {
        if let i = chartColumns.firstIndex(of: column) {
            chartColumns.remove(at: i)
            colorSlots[column] = nil
        } else {
            chartColumns.append(column)
            let taken = Set(colorSlots.values)
            colorSlots[column] = (0..<SeriesPalette.count).first { !taken.contains($0) } ?? (colorSlots.count % SeriesPalette.count)
        }
    }

    func moveChart(_ column: Int, up: Bool) {
        guard let i = chartColumns.firstIndex(of: column) else { return }
        let j = up ? i - 1 : i + 1
        guard chartColumns.indices.contains(j) else { return }
        chartColumns.swapAt(i, j)
    }

    static func defaultCharts(_ log: RecordedLog) -> [Int] {
        let wanted = ["engine speed", "manifold relative", "feedback knock", "fine learning knock", "a/f sensor #1", "iam"]
        var picks: [Int] = []
        for w in wanted {
            if let i = log.columns.firstIndex(where: { $0.name.lowercased().hasPrefix(w) }), !picks.contains(i) { picks.append(i) }
        }
        if picks.isEmpty { picks = Array(log.columns.indices.prefix(4)) }
        return picks
    }
}

/// Formats seconds as m:ss.s
func formatLogTime(_ t: Double, decimals: Int = 1) -> String {
    guard t.isFinite else { return "–" }
    let minutes = Int(t) / 60
    let seconds = t - Double(minutes * 60)
    return String(format: "%d:%0\(decimals + 3).\(decimals)f", minutes, seconds)
}
