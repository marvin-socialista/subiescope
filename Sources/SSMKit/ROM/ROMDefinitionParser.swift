import Foundation

/// Reads a RomRaider `ecu_defs.xml` into a `ROMDefinitionSet`. SAX-based, like the logger-definition
/// parser, so even a large file streams without loading a DOM. It keeps only what the ROM editor needs:
/// shared scalings, each ROM's identity and base, and its tables with their axes.
public enum ROMDefinitionParser {
    public enum LoadError: Error, LocalizedError {
        case notReadable
        case parse(String)
        case noDefinitions
        public var errorDescription: String? {
            switch self {
            case .notReadable: return "Could not read the definition file."
            case .parse(let r): return "Could not read the ROM definitions: \(r)"
            case .noDefinitions: return "No ROM definitions were found. Is this a RomRaider ecu_defs.xml?"
            }
        }
    }

    public static func load(url: URL) throws -> ROMDefinitionSet {
        guard let data = try? Data(contentsOf: url) else { throw LoadError.notReadable }
        return try load(data: data)
    }

    public static func load(data: Data) throws -> ROMDefinitionSet {
        let handler = Handler()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = handler
        guard parser.parse() else {
            throw LoadError.parse(parser.parserError?.localizedDescription ?? "unknown XML error")
        }
        guard !handler.set.definitions.isEmpty else { throw LoadError.noDefinitions }
        return handler.set
    }

    static func parseHexAddress(_ text: String?) -> Int? {
        guard let text else { return nil }
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "0x", with: "")
        return t.isEmpty ? nil : Int(t, radix: 16)
    }

    static func parseInt(_ text: String?, default def: Int) -> Int {
        guard let text, let v = Int(text.trimmingCharacters(in: .whitespaces)) else { return def }
        return v
    }

    static func bigEndian(_ text: String?) -> Bool {
        (text ?? "big").trimmingCharacters(in: .whitespaces).lowercased() != "little"
    }

    /// A `<scaling>` element: a shared definition, an inline definition, or a reference by name.
    static func scaling(from attrs: [String: String]) -> (scaling: ROMScaling?, referenceName: String?) {
        let name = attrs["name"]
        let hasFormula = attrs["expression"] != nil || attrs["to_byte"] != nil || attrs["units"] != nil
            || attrs["format"] != nil
        guard hasFormula else { return (nil, name) }   // reference only
        let scaling = ROMScaling(
            name: name,
            units: attrs["units"] ?? "",
            expression: attrs["expression"] ?? "x",
            toByte: attrs["to_byte"] ?? "x",
            format: attrs["format"] ?? "0.00",
            min: attrs["min"].flatMap(Double.init) ?? attrs["minvalue"].flatMap(Double.init),
            max: attrs["max"].flatMap(Double.init) ?? attrs["maxvalue"].flatMap(Double.init))
        return (scaling, name)
    }

    // MARK: SAX handler

    final class Handler: NSObject, XMLParserDelegate {
        var set = ROMDefinitionSet()

        private var currentDef: ROMDefinition?
        private var tableStack: [ROMTableDef] = []
        private var axisStack: [(axis: ROMAxis, type: String)] = []
        /// Whether the innermost open element is an axis (true) or a main table (false), per table depth.
        private var frameIsAxis: [Bool] = []
        private var text = ""
        private var capturing = false
        private var staticValues: [Double] = []
        private var collectingStatic = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attrs: [String: String]) {
            switch name {
            case "rom":
                currentDef = ROMDefinition(identity: ROMIdentity(xmlID: "", base: attrs["base"]))
            case "xmlid", "internalidaddress", "internalidstring", "ecuid", "make", "market",
                 "flashmethod", "memmodel":
                text = ""; capturing = true
            case "table":
                let isAxis = !tableStack.isEmpty
                if isAxis {
                    let axis = ROMAxis(
                        name: attrs["name"] ?? "",
                        storageType: attrs["storagetype"].flatMap(ROMStorageType.init(romRaider:)),
                        bigEndian: ROMDefinitionParser.bigEndian(attrs["endian"]),
                        address: ROMDefinitionParser.parseHexAddress(attrs["storageaddress"] ?? attrs["address"]),
                        size: max(ROMDefinitionParser.parseInt(attrs["sizex"], default: ROMDefinitionParser.parseInt(attrs["sizey"], default: 1)), 1))
                    axisStack.append((axis, attrs["type"] ?? ""))
                    staticValues = []
                    collectingStatic = (attrs["type"] ?? "").lowercased().contains("static")
                } else {
                    let table = ROMTableDef(
                        name: attrs["name"] ?? "",
                        category: attrs["category"] ?? "",
                        dimension: ROMTableDef.Dimension(rawValue: (attrs["type"] ?? "").replacingOccurrences(of: " ", with: "")) ?? .other,
                        storageType: attrs["storagetype"].flatMap(ROMStorageType.init(romRaider:)),
                        bigEndian: ROMDefinitionParser.bigEndian(attrs["endian"]),
                        address: ROMDefinitionParser.parseHexAddress(attrs["storageaddress"] ?? attrs["address"]),
                        sizeX: ROMDefinitionParser.parseInt(attrs["sizex"], default: 1),
                        sizeY: ROMDefinitionParser.parseInt(attrs["sizey"], default: 1))
                    tableStack.append(table)
                }
                frameIsAxis.append(isAxis)
            case "scaling":
                let (scaling, reference) = ROMDefinitionParser.scaling(from: attrs)
                if !axisStack.isEmpty {
                    if let scaling { axisStack[axisStack.count - 1].axis.scaling = scaling }
                    else { axisStack[axisStack.count - 1].axis.scalingName = reference }
                } else if !tableStack.isEmpty {
                    if let scaling { tableStack[tableStack.count - 1].scaling = scaling }
                    else { tableStack[tableStack.count - 1].scalingName = reference }
                } else if let scaling, let n = scaling.name {
                    set.scalings[n] = scaling   // shared, top-level
                }
            case "data" where collectingStatic:
                text = ""; capturing = true
            case "description":
                text = ""; capturing = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturing { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "rom":
                if let def = currentDef, !def.identity.xmlID.isEmpty {
                    set.definitions[def.identity.xmlID] = def
                }
                currentDef = nil
            case "xmlid": currentDef?.identity.xmlID = value; capturing = false
            case "internalidaddress": currentDef?.identity.internalIDAddress = ROMDefinitionParser.parseHexAddress(value); capturing = false
            case "internalidstring": currentDef?.identity.internalIDString = value; capturing = false
            case "ecuid": currentDef?.identity.ecuID = value; capturing = false
            case "make": currentDef?.identity.make = value; capturing = false
            case "market": currentDef?.identity.market = value; capturing = false
            case "flashmethod": currentDef?.identity.flashMethod = value; capturing = false
            case "memmodel": currentDef?.identity.memModel = value; capturing = false
            case "description":
                if !tableStack.isEmpty { tableStack[tableStack.count - 1].description = value }
                capturing = false
            case "data" where capturing:
                if let v = Double(value) { staticValues.append(v) }
                capturing = false
            case "table":
                let wasAxis = frameIsAxis.popLast() ?? false
                if wasAxis, var frame = axisStack.popLast() {
                    if collectingStatic, !staticValues.isEmpty { frame.axis.staticValues = staticValues }
                    collectingStatic = false
                    attach(axis: frame.axis, type: frame.type)
                } else if let table = tableStack.popLast() {
                    if currentDef != nil, !table.name.isEmpty { currentDef!.tables[table.name] = table }
                }
            default:
                break
            }
        }

        /// Attaches a finished axis to the table it belongs to.
        private func attach(axis: ROMAxis, type: String) {
            guard !tableStack.isEmpty else { return }
            let t = type.lowercased()
            if t.contains("y axis") {
                tableStack[tableStack.count - 1].yAxis = axis
            } else {
                tableStack[tableStack.count - 1].xAxis = axis   // X axis, static axis, or unspecified
            }
        }
    }
}
