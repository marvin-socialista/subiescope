/// How a value is shown on the dashboard: which kind of gauge, and how many cells of the grid it takes.
enum GaugeStyle: String, Codable, CaseIterable, Identifiable {
    case dial, digital, bar, graph
    var id: String { rawValue }

    var label: String {
        switch self {
        case .dial: return "Dial"
        case .digital: return "Digital"
        case .bar: return "Bar"
        case .graph: return "Graph"
        }
    }

    var symbol: String {
        switch self {
        case .dial: return "gauge.with.dots.needle.33percent"
        case .digital: return "textformat.123"
        case .bar: return "chart.bar.fill"
        case .graph: return "chart.xyaxis.line"
        }
    }
}

enum TileSize: String, Codable, CaseIterable, Identifiable {
    case small, wide, large
    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "Small"
        case .wide: return "Wide"
        case .large: return "Large"
        }
    }

    var span: (columns: Int, rows: Int) {
        switch self {
        case .small: return (1, 1)
        case .wide: return (2, 1)
        case .large: return (2, 2)
        }
    }
}

struct TileConfig: Codable, Equatable {
    var style: GaugeStyle = .dial
    var size: TileSize = .small
}
