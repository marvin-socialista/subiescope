import Foundation

/// What a reader of RomRaider's XML files wants to hear about, in the order of the file.
protocol XMLEventHandler: AnyObject {
    func startElement(_ name: String, attributes: [String: String])
    func characters(_ string: String)
    func endElement(_ name: String)
}

/// Reads an XML file and tells a handler about its elements and text.
///
/// On a Mac this is Foundation's `XMLParser`. Foundation's parser crashes on Windows, so there
/// `PortableXMLParser` below does the reading. The tests hold the two against each other.
enum XMLReader {
    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func parse(_ data: Data, handler: XMLEventHandler) throws {
        #if canImport(Darwin)
        let adapter = FoundationAdapter(handler: handler)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = adapter
        guard parser.parse() else {
            throw Failure(reason: parser.parserError?.localizedDescription ?? "unknown XML error")
        }
        #else
        try PortableXMLParser.parse(data, handler: handler)
        #endif
    }
}

#if canImport(Darwin)
private final class FoundationAdapter: NSObject, XMLParserDelegate {
    let handler: XMLEventHandler

    init(handler: XMLEventHandler) {
        self.handler = handler
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        handler.startElement(name, attributes: attributes)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        handler.characters(string)
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        handler.characters(String(decoding: block, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        handler.endElement(name)
    }
}
#endif

/// A small XML reader in plain Swift: elements, attributes, text, the five named entities and
/// numbered ones, comments, CDATA, and a document type with its declarations (which it skips).
/// Enough for RomRaider's logger and ECU definitions; it knows nothing of namespaces or of
/// entities a file declares itself.
enum PortableXMLParser {
    static func parse(_ data: Data, handler: XMLEventHandler) throws {
        var bytes = [UInt8](decoded(data))
        // A byte order mark is not part of the text.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        var reader = Reader(bytes: bytes, handler: handler)
        try reader.run()
    }

    /// The file as UTF-8. A file that names another encoding in its first line is converted.
    private static func decoded(_ data: Data) -> Data {
        let head = String(decoding: data.prefix(200), as: UTF8.self).lowercased()
        guard head.hasPrefix("<?xml"), let end = head.range(of: "?>"),
              let marker = head.range(of: "encoding", range: head.startIndex..<end.lowerBound) else { return data }
        let name = head[marker.upperBound..<end.lowerBound].drop { $0 != "\"" && $0 != "'" }.dropFirst().prefix { $0 != "\"" && $0 != "'" }
        let encoding: String.Encoding?
        switch name {
        case "iso-8859-1", "latin1", "latin-1": encoding = .isoLatin1
        case "windows-1252", "cp1252": encoding = .windowsCP1252
        case "utf-16": encoding = .utf16
        default: encoding = nil
        }
        guard let encoding, let text = String(data: data, encoding: encoding) else { return data }
        return Data(text.utf8)
    }

    private struct Reader {
        let bytes: [UInt8]
        let handler: XMLEventHandler
        var position = 0
        var open: [String] = []

        init(bytes: [UInt8], handler: XMLEventHandler) {
            self.bytes = bytes
            self.handler = handler
        }

        private static let lessThan = UInt8(ascii: "<"), greaterThan = UInt8(ascii: ">"), slash = UInt8(ascii: "/")
        private static let ampersand = UInt8(ascii: "&"), bang = UInt8(ascii: "!"), question = UInt8(ascii: "?")

        mutating func run() throws {
            var sawRoot = false
            while position < bytes.count {
                if bytes[position] != Self.lessThan {
                    try text()
                } else if starts("<!--") {
                    try skip(past: "-->", what: "A comment")
                } else if starts("<![CDATA[") {
                    position += 9
                    let start = position
                    try skip(past: "]]>", what: "A CDATA section")
                    if !open.isEmpty { handler.characters(string(start, position - 3)) }
                } else if starts("<?") {
                    try skip(past: "?>", what: "A processing instruction")
                } else if starts("<!") {
                    try documentType()
                } else if starts("</") {
                    try endTag()
                } else {
                    if open.isEmpty && sawRoot { throw failure("There is more than one top element") }
                    sawRoot = true
                    try startTag()
                }
            }
            if let name = open.last { throw failure("The file ends before </\(name)>") }
            if !sawRoot { throw failure("The file has no elements") }
        }

        // MARK: Pieces of the file

        private mutating func text() throws {
            let start = position
            while position < bytes.count, bytes[position] != Self.lessThan { position += 1 }
            // Text outside the top element is only the spacing between declarations.
            guard !open.isEmpty else { return }
            handler.characters(try unescaped(start, position, attribute: false))
        }

        private mutating func startTag() throws {
            position += 1
            let name = try self.name()
            var attributes: [String: String] = [:]
            while true {
                skipSpace()
                guard position < bytes.count else { throw failure("The file ends inside <\(name)>") }
                if bytes[position] == Self.greaterThan {
                    position += 1
                    open.append(name)
                    handler.startElement(name, attributes: attributes)
                    return
                }
                if bytes[position] == Self.slash {
                    guard position + 1 < bytes.count, bytes[position + 1] == Self.greaterThan else { throw failure("A stray / in <\(name)>") }
                    position += 2
                    handler.startElement(name, attributes: attributes)
                    handler.endElement(name)
                    return
                }
                let key = try self.name()
                skipSpace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: "=") else { throw failure("The attribute \(key) of <\(name)> has no value") }
                position += 1
                skipSpace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") || bytes[position] == UInt8(ascii: "'") else {
                    throw failure("The value of \(key) in <\(name)> is not in quotes")
                }
                let quote = bytes[position]
                position += 1
                let start = position
                while position < bytes.count, bytes[position] != quote { position += 1 }
                guard position < bytes.count else { throw failure("The value of \(key) in <\(name)> never ends") }
                attributes[key] = try unescaped(start, position, attribute: true)
                position += 1
            }
        }

        private mutating func endTag() throws {
            position += 2
            let name = try self.name()
            skipSpace()
            guard position < bytes.count, bytes[position] == Self.greaterThan else { throw failure("</\(name) is not closed") }
            position += 1
            guard let expected = open.popLast() else { throw failure("</\(name)> closes nothing") }
            guard expected == name else { throw failure("<\(expected)> is closed by </\(name)>") }
            handler.endElement(name)
        }

        /// <!DOCTYPE name [ declarations ]>: skipped, with the quoted texts and comments inside it.
        private mutating func documentType() throws {
            var depth = 0
            while position < bytes.count {
                let byte = bytes[position]
                if starts("<!--") {
                    try skip(past: "-->", what: "A comment")
                    continue
                }
                if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                    position += 1
                    while position < bytes.count, bytes[position] != byte { position += 1 }
                } else if byte == UInt8(ascii: "[") {
                    depth += 1
                } else if byte == UInt8(ascii: "]") {
                    depth -= 1
                } else if byte == Self.greaterThan, depth <= 0 {
                    position += 1
                    return
                }
                position += 1
            }
            throw failure("The document type declaration never ends")
        }

        // MARK: Small steps

        private func starts(_ text: StaticString) -> Bool {
            let count = text.utf8CodeUnitCount
            guard position + count <= bytes.count else { return false }
            return text.withUTF8Buffer { marker in
                for i in 0..<count where bytes[position + i] != marker[i] { return false }
                return true
            }
        }

        private mutating func skip(past end: StaticString, what: String) throws {
            let count = end.utf8CodeUnitCount
            let found: Int? = end.withUTF8Buffer { marker in
                var at = position
                while at + count <= bytes.count {
                    var same = true
                    for i in 0..<count where bytes[at + i] != marker[i] { same = false; break }
                    if same { return at }
                    at += 1
                }
                return nil
            }
            guard let found else { throw failure("\(what) never ends") }
            position = found + count
        }

        private static func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        private mutating func skipSpace() {
            while position < bytes.count, Self.isSpace(bytes[position]) { position += 1 }
        }

        private mutating func name() throws -> String {
            let start = position
            while position < bytes.count {
                let byte = bytes[position]
                if Self.isSpace(byte) || byte == Self.greaterThan || byte == Self.slash || byte == UInt8(ascii: "=") || byte == Self.lessThan { break }
                position += 1
            }
            guard position > start else { throw failure("A name is missing") }
            return string(start, position)
        }

        private func string(_ start: Int, _ end: Int) -> String {
            bytes.withUnsafeBufferPointer { String(decoding: UnsafeBufferPointer(rebasing: $0[start..<end]), as: UTF8.self) }
        }

        /// Text as it is meant: entities replaced, line ends as one line feed, and in an attribute
        /// every kind of white space as a space.
        private func unescaped(_ start: Int, _ end: Int, attribute: Bool) throws -> String {
            var plain = true
            for i in start..<end {
                let byte = bytes[i]
                if byte == Self.ampersand || byte == 0x0D || (attribute && (byte == 0x09 || byte == 0x0A)) {
                    plain = false
                    break
                }
            }
            if plain { return string(start, end) }

            var out: [UInt8] = []
            out.reserveCapacity(end - start)
            var i = start
            while i < end {
                let byte = bytes[i]
                if byte == 0x0D {
                    out.append(attribute ? 0x20 : 0x0A)
                    i += i + 1 < end && bytes[i + 1] == 0x0A ? 2 : 1
                } else if attribute && (byte == 0x09 || byte == 0x0A) {
                    out.append(0x20)
                    i += 1
                } else if byte == Self.ampersand {
                    guard let semicolon = bytes[i..<min(end, i + 12)].firstIndex(of: UInt8(ascii: ";")) else {
                        throw failure("An & that is not the start of an entity")
                    }
                    let entity = string(i + 1, semicolon)
                    switch entity {
                    case "amp": out.append(UInt8(ascii: "&"))
                    case "lt": out.append(UInt8(ascii: "<"))
                    case "gt": out.append(UInt8(ascii: ">"))
                    case "quot": out.append(UInt8(ascii: "\""))
                    case "apos": out.append(UInt8(ascii: "'"))
                    default:
                        var number: UInt32?
                        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                            number = UInt32(entity.dropFirst(2), radix: 16)
                        } else if entity.hasPrefix("#") {
                            number = UInt32(entity.dropFirst())
                        }
                        guard let number, let scalar = Unicode.Scalar(number) else { throw failure("The entity &\(entity); is not known") }
                        out.append(contentsOf: Array(String(Character(scalar)).utf8))
                    }
                    i = semicolon + 1
                } else {
                    out.append(byte)
                    i += 1
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        private func failure(_ reason: String) -> XMLReader.Failure {
            var line = 1
            for i in 0..<min(position, bytes.count) where bytes[i] == 0x0A { line += 1 }
            return XMLReader.Failure(reason: "\(reason) (line \(line)).")
        }
    }
}
