#if os(Windows) || DEBUG
import Foundation
import SSMKit

/// The dashboard: its tiles, the live numbers on them, and the list to choose a new gauge from.
extension Bridge {
    struct DashboardState: Encodable {
        struct Tile: Encodable {
            struct Unit: Encodable {
                let units: String
                let label: String
            }

            let id: String
            let name: String
            /// The full name and what it means, for the tooltip.
            let help: String
            let isSwitch: Bool
            /// dial, digital, bar or graph
            let style: String
            /// small, wide or large
            let size: String
            let units: String
            /// The units to choose from, when there is more than one.
            let unitChoices: [Unit]
        }

        let tiles: [Tile]
        let mode: String
        let connected: Bool
        let connecting: Bool
        let playingBack: Bool
        /// SSM only: RomRaider's definitions are not there yet.
        let definitionsMissing: Bool
        let downloadingDefinitions: Bool
        let definitionsError: String?
        let pollError: String?
        let notice: String?
        /// Gauges that are left out because this car does not report them.
        let hiddenNotice: String?
    }

    struct DashboardLive: Encodable {
        struct Gauge: Encodable {
            let value: Double?
            /// The value as the gauge shows it ("4906"), and the lowest and highest seen.
            let text: String
            let min: String
            let max: String
            /// The ends of the scale, as text for the bar gauge and as numbers for drawing.
            let lowText: String
            let highText: String
            let low: Double
            let high: Double
            let peakLow: Double?
            let peakHigh: Double?
            /// accent, orange, red or green
            let tint: String
            /// Graph tiles only: the last minute as pairs of (seconds ago, value).
            let history: [Double]?
        }

        let gauges: [String: Gauge]
    }

    struct ParameterChoice: Encodable {
        let id: String
        let name: String
        let kind: String
    }

    struct PlaybackState: Encodable {
        let file: String
        let playhead: Double
        let duration: Double
        let isPlaying: Bool
        let speed: Double
        let speeds: [Double]
    }

    func registerDashboard() {
        slice("dashboard") { [model] in
            let tiles = model.visibleDashboardIDs.compactMap { id -> DashboardState.Tile? in
                guard let parameter = model.parametersByID[id] else { return nil }
                let config = model.tileConfig(for: id)
                return DashboardState.Tile(
                    id: id, name: parameter.displayName,
                    help: parameter.name + (parameter.description.isEmpty ? "" : "\n" + parameter.description),
                    isSwitch: parameter.kind == .switchBit, style: config.style.rawValue, size: config.size.rawValue,
                    units: model.conversion(for: parameter)?.displayUnits ?? "",
                    unitChoices: parameter.conversions.count > 1 ? parameter.conversions.map { .init(units: $0.units, label: $0.displayUnits) } : [])
            }
            let connected = model.connection.isConnected
            var hiddenNotice: String?
            if model.mode == .obd, connected, model.obdInfo != nil {
                let hidden = model.dashboardIDs.count - model.visibleDashboardIDs.count
                if hidden > 0 {
                    hiddenNotice = "\(hidden) gauge\(hidden == 1 ? " is" : "s are") hidden because this car does not report \(hidden == 1 ? "it" : "them"). Add others with the + tile."
                }
            }
            return DashboardState(
                tiles: tiles, mode: model.mode.rawValue, connected: connected, connecting: model.connection == .connecting,
                playingBack: model.isPlayingBack,
                definitionsMissing: model.definitions == nil && model.mode == .ssm,
                downloadingDefinitions: model.downloadingDefinitions, definitionsError: model.definitionsError,
                pollError: connected ? model.pollError : nil, notice: connected ? model.obdNotice : nil, hiddenNotice: hiddenNotice)
        }

        slice("dashboard.live", atMost: 30) { [model] in
            var gauges: [String: DashboardLive.Gauge] = [:]
            for id in model.visibleDashboardIDs {
                guard let parameter = model.parametersByID[id] else { continue }
                let conversion = model.conversion(for: parameter)
                let value = model.latest[id]?.finite
                let extremes = model.extremes[id]
                let range = Bridge.gaugeRange(parameter: parameter, conversion: conversion, extremes: extremes)
                func text(_ number: Double?) -> String {
                    guard let number, number.isFinite else { return "–" }
                    return conversion?.formatted(number) ?? String(format: "%.2f", number)
                }
                var history: [Double]?
                if model.tileConfig(for: id).style == .graph, parameter.kind != .switchBit {
                    let points = model.history[id] ?? []
                    let newest = points.last?.t ?? 0
                    history = points.flatMap { [newest - $0.t, $0.value.finite ?? 0] }
                }
                gauges[id] = DashboardLive.Gauge(
                    value: value, text: text(value), min: text(extremes?.lowerBound), max: text(extremes?.upperBound),
                    lowText: text(range.lowerBound), highText: text(range.upperBound),
                    low: range.lowerBound.finite ?? 0, high: range.upperBound.finite ?? 100,
                    peakLow: extremes?.lowerBound.finite, peakHigh: extremes?.upperBound.finite,
                    tint: Bridge.gaugeTint(parameter: parameter, value: value), history: history)
            }
            return DashboardLive(gauges: gauges)
        }

        // Every value there is to show, for the lists a gauge or a logged value is picked from.
        slice("parameters") { [model] in
            model.parameters.map { ParameterChoice(id: $0.id, name: $0.name, kind: Bridge.label(of: $0.kind)) }
        }

        // The log that plays on the gauges while the car is not connected.
        slice("playback", atMost: 15) { [model] () -> PlaybackState? in
            guard model.isPlayingBack, let playback = model.playback else { return nil }
            return PlaybackState(file: playback.url.lastPathComponent, playhead: playback.playhead.finite ?? 0,
                                 duration: playback.duration.finite ?? 0, isPlaying: playback.isPlaying,
                                 speed: playback.speed, speeds: LogPlayback.speeds)
        }

        action("dashboard.add") { [model] arguments in
            guard let id = arguments.string("id"), model.parametersByID[id] != nil, !model.dashboardIDs.contains(id) else { return }
            model.dashboardIDs.append(id)
        }
        action("dashboard.remove") { [model] arguments in
            guard let id = arguments.string("id") else { return }
            // The tile may stand for a saved gauge of the same kind under another id.
            model.dashboardIDs.removeAll { $0 == id || model.equivalentID(for: $0) == id }
        }
        action("dashboard.move") { [model] arguments in
            guard let id = arguments.string("id") else { return }
            model.moveTile(id, before: arguments.string("before") ?? model.dashboardIDs.first ?? id)
        }
        action("dashboard.style") { [model] arguments in
            guard let id = arguments.string("id"), let style = arguments.string("style").flatMap(GaugeStyle.init(rawValue:)) else { return }
            model.setTileStyle(id, style)
        }
        action("dashboard.size") { [model] arguments in
            guard let id = arguments.string("id"), let size = arguments.string("size").flatMap(TileSize.init(rawValue:)) else { return }
            model.setTileSize(id, size)
        }
        action("dashboard.units") { [model] arguments in
            guard let id = arguments.string("id"), let units = arguments.string("units") else { return }
            model.unitChoice[id] = units
        }
        // Without an id: the min and max of every gauge.
        action("dashboard.resetPeaks") { [model] arguments in
            if let id = arguments.string("id") { model.resetExtremes(for: id) } else { model.resetExtremes() }
        }
        action("dashboard.downloadDefinitions") { [model] _ in
            Task { await model.downloadDefinitions() }
        }

        action("playback.toggle") { [model] _ in model.playback?.togglePlay() }
        action("playback.seek") { [model] arguments in
            guard let time = arguments.double("time") else { return }
            model.playback?.seek(time)
        }
        action("playback.speed") { [model] arguments in
            guard let speed = arguments.double("speed"), LogPlayback.speeds.contains(speed) else { return }
            model.playback?.speed = speed
        }
        action("playback.close") { [model] _ in model.closePlayback() }
    }

    static func label(of kind: ParameterKind) -> String {
        switch kind {
        case .standard: return "Standard"
        case .extended: return "Extended (ECU specific)"
        case .switchBit: return "Switch"
        case .calculated: return "Calculated"
        case .external: return "Wideband gauge"
        }
    }

    /// The scale of a gauge: the definition's own, or one that fits what was seen. (The Mac app's `GaugeRange`.)
    static func gaugeRange(parameter: ParameterDefinition, conversion: Conversion?, extremes: ClosedRange<Double>?) -> ClosedRange<Double> {
        let key = parameter.displayName.lowercased()
        var range: ClosedRange<Double>
        if let lo = conversion?.gaugeMin, let hi = conversion?.gaugeMax, hi > lo {
            range = lo...hi
        } else if key == "iam" {
            range = 0...1
        } else if conversion?.units.lowercased() == "lambda" {
            range = 0.6...1.4
        } else if let extremes, extremes.upperBound > extremes.lowerBound {
            let pad = (extremes.upperBound - extremes.lowerBound) * 0.1
            return (extremes.lowerBound - pad)...(extremes.upperBound + pad)
        } else if let v = extremes?.upperBound {
            range = v >= 0 ? 0...max(1, v * 2) : (v * 2)...0
        } else {
            range = 0...100
        }
        // Never let the needle pin against the end of a too-narrow factory range.
        if let extremes {
            range = min(range.lowerBound, extremes.lowerBound)...max(range.upperBound, extremes.upperBound)
        }
        return range
    }

    /// Knock correction below zero and a dropped IAM are the things to watch.
    static func gaugeTint(parameter: ParameterDefinition, value: Double?) -> String {
        guard let value else { return "accent" }
        let name = parameter.name.lowercased()
        if name.contains("knock") && !name.contains("sum") && value < 0 {
            return value <= -2 ? "red" : "orange"
        }
        if name.hasPrefix("iam") {
            return value < 1 && value >= 0 ? (value < 0.75 ? "red" : "orange") : "green"
        }
        return "accent"
    }
}
#endif
