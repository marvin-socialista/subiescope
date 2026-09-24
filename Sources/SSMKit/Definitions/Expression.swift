import Foundation

/// Compiled arithmetic expression as used in RomRaider conversion formulas,
/// for example `x*0.0078125` or `(x-128)/2`. Supports + - * / % ^, unary minus,
/// parentheses, comparison operators, variables and common math functions.
public final class Expression: @unchecked Sendable {
    public let source: String
    private let root: Node

    public enum ParseError: Error, LocalizedError {
        case unexpected(String, position: Int)
        case unknownFunction(String)

        public var errorDescription: String? {
            switch self {
            case .unexpected(let token, let pos): return "Unexpected '\(token)' at position \(pos) in expression."
            case .unknownFunction(let name): return "Unknown function '\(name)' in expression."
            }
        }
    }

    public init(_ source: String) throws {
        self.source = source
        var parser = Parser(tokens: try Tokenizer.tokenize(source))
        self.root = try parser.parseExpression()
        if let extra = parser.peek {
            throw ParseError.unexpected(extra.text, position: extra.position)
        }
    }

    /// Variable names referenced by the expression.
    public var variables: Set<String> { root.variables }

    public func evaluate(_ variables: [String: Double]) -> Double {
        root.evaluate(variables)
    }

    public func evaluate(x: Double) -> Double {
        root.evaluate(["x": x])
    }

    // MARK: AST

    private indirect enum Node {
        case number(Double)
        case variable(String)
        case unary(Character, Node)
        case binary(String, Node, Node)
        case call(String, [Node])

        var variables: Set<String> {
            switch self {
            case .number: return []
            case .variable(let name): return [name]
            case .unary(_, let n): return n.variables
            case .binary(_, let l, let r): return l.variables.union(r.variables)
            case .call(_, let args): return args.reduce(into: Set<String>()) { $0.formUnion($1.variables) }
            }
        }

        func evaluate(_ vars: [String: Double]) -> Double {
            switch self {
            case .number(let v):
                return v
            case .variable(let name):
                return vars[name] ?? vars[name.lowercased()] ?? .nan
            case .unary(let op, let n):
                let v = n.evaluate(vars)
                return op == "-" ? -v : v
            case .binary(let op, let l, let r):
                let a = l.evaluate(vars)
                let b = r.evaluate(vars)
                switch op {
                case "+": return a + b
                case "-": return a - b
                case "*": return a * b
                case "/": return a / b
                case "%": return a.truncatingRemainder(dividingBy: b)
                case "^": return pow(a, b)
                case "<": return a < b ? 1 : 0
                case ">": return a > b ? 1 : 0
                case "<=": return a <= b ? 1 : 0
                case ">=": return a >= b ? 1 : 0
                case "==": return a == b ? 1 : 0
                case "!=": return a != b ? 1 : 0
                case "&&": return (a != 0 && b != 0) ? 1 : 0
                case "||": return (a != 0 || b != 0) ? 1 : 0
                case "&": return Double(Int64(a) & Int64(b))
                case "|": return Double(Int64(a) | Int64(b))
                default: return .nan
                }
            case .call(let name, let args):
                let v = args.map { $0.evaluate(vars) }
                return Expression.call(name, v)
            }
        }
    }

    static let functionNames: Set<String> = [
        "abs", "sqrt", "exp", "log", "ln", "log10", "pow", "min", "max", "floor", "ceil", "round",
        "sin", "cos", "tan", "atan", "if", "int", "sign", "bitwise",
    ]

    private static func call(_ name: String, _ v: [Double]) -> Double {
        func arg(_ i: Int) -> Double { i < v.count ? v[i] : .nan }
        switch name.lowercased() {
        case "abs": return Swift.abs(arg(0))
        case "sqrt": return arg(0).squareRoot()
        case "exp": return Foundation.exp(arg(0))
        case "log", "ln": return Foundation.log(arg(0))
        case "log10": return Foundation.log10(arg(0))
        case "pow": return Foundation.pow(arg(0), arg(1))
        case "min": return v.min() ?? .nan
        case "max": return v.max() ?? .nan
        case "floor": return Foundation.floor(arg(0))
        case "ceil": return Foundation.ceil(arg(0))
        case "round": return arg(0).rounded()
        case "int": return arg(0).rounded(.towardZero)
        case "sign": return arg(0) > 0 ? 1 : (arg(0) < 0 ? -1 : 0)
        case "sin": return Foundation.sin(arg(0))
        case "cos": return Foundation.cos(arg(0))
        case "tan": return Foundation.tan(arg(0))
        case "atan": return Foundation.atan(arg(0))
        case "if": return arg(0) != 0 ? arg(1) : arg(2)
        // RomRaider: BitWise(operator, value, mask) where operator 0 = AND
        case "bitwise":
            let a = Int64(arg(1)), b = Int64(arg(2))
            switch Int(arg(0)) {
            case 0: return Double(a & b)
            case 1: return Double(a | b)
            case 2: return Double(a ^ b)
            case 3: return Double(a << b)
            case 4: return Double(a >> b)
            default: return .nan
            }
        default: return .nan
        }
    }

    // MARK: Tokenizer

    private struct Token {
        enum Kind { case number(Double), identifier(String), op(String), lparen, rparen, comma }
        let kind: Kind
        let text: String
        let position: Int
    }

    private enum Tokenizer {
        static func tokenize(_ s: String) throws -> [Token] {
            var tokens: [Token] = []
            let chars = Array(s)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c.isWhitespace { i += 1; continue }
                let start = i
                if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                    var j = i
                    if c == "0", j + 1 < chars.count, chars[j + 1] == "x" || chars[j + 1] == "X" {
                        j += 2
                        while j < chars.count, chars[j].isHexDigit { j += 1 }
                        let text = String(chars[i..<j])
                        tokens.append(Token(kind: .number(Double(UInt64(text.dropFirst(2), radix: 16) ?? 0)), text: text, position: start))
                        i = j
                        continue
                    }
                    while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                    if j < chars.count, chars[j] == "e" || chars[j] == "E" {
                        var k = j + 1
                        if k < chars.count, chars[k] == "+" || chars[k] == "-" { k += 1 }
                        if k < chars.count, chars[k].isNumber {
                            j = k
                            while j < chars.count, chars[j].isNumber { j += 1 }
                        }
                    }
                    let text = String(chars[i..<j])
                    guard let value = Double(text) else { throw ParseError.unexpected(text, position: start) }
                    tokens.append(Token(kind: .number(value), text: text, position: start))
                    i = j
                } else if c.isLetter || c == "_" || c == "[" {
                    // Identifiers; RomRaider calculated params use names like P8 or [P8:rpm].
                    var j = i
                    if c == "[" {
                        while j < chars.count, chars[j] != "]" { j += 1 }
                        j = min(j + 1, chars.count)
                    } else {
                        while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                    }
                    let text = String(chars[i..<j])
                    tokens.append(Token(kind: .identifier(text), text: text, position: start))
                    i = j
                } else if c == "(" {
                    tokens.append(Token(kind: .lparen, text: "(", position: start)); i += 1
                } else if c == ")" {
                    tokens.append(Token(kind: .rparen, text: ")", position: start)); i += 1
                } else if c == "," {
                    tokens.append(Token(kind: .comma, text: ",", position: start)); i += 1
                } else {
                    let two = i + 1 < chars.count ? String(chars[i...i + 1]) : ""
                    if ["<=", ">=", "==", "!=", "&&", "||"].contains(two) {
                        tokens.append(Token(kind: .op(two), text: two, position: start)); i += 2
                    } else if "+-*/%^<>&|".contains(c) {
                        tokens.append(Token(kind: .op(String(c)), text: String(c), position: start)); i += 1
                    } else {
                        throw ParseError.unexpected(String(c), position: start)
                    }
                }
            }
            return tokens
        }
    }

    // MARK: Parser (precedence climbing)

    private struct Parser {
        var tokens: [Token]
        var index = 0

        var peek: Token? { index < tokens.count ? tokens[index] : nil }

        mutating func next() -> Token? {
            defer { index += 1 }
            return peek
        }

        static let precedence: [String: Int] = [
            "||": 1, "&&": 2, "|": 3, "&": 4,
            "==": 5, "!=": 5, "<": 6, ">": 6, "<=": 6, ">=": 6,
            "+": 7, "-": 7, "*": 8, "/": 8, "%": 8, "^": 10,
        ]

        mutating func parseExpression(_ minPrec: Int = 0) throws -> Node {
            var lhs = try parseUnary()
            while let tok = peek, case .op(let op) = tok.kind, let prec = Self.precedence[op], prec >= minPrec {
                index += 1
                // ^ is right associative
                let rhs = try parseExpression(op == "^" ? prec : prec + 1)
                lhs = .binary(op, lhs, rhs)
            }
            return lhs
        }

        mutating func parseUnary() throws -> Node {
            if let tok = peek, case .op(let op) = tok.kind, op == "-" || op == "+" {
                index += 1
                // Unary minus binds weaker than ^ so -x^2 == -(x^2).
                return .unary(Character(op), try parseExpression(9))
            }
            return try parsePrimary()
        }

        mutating func parsePrimary() throws -> Node {
            guard let tok = next() else { throw ParseError.unexpected("end of expression", position: -1) }
            switch tok.kind {
            case .number(let v):
                return .number(v)
            case .identifier(let name):
                if let p = peek, case .lparen = p.kind {
                    index += 1
                    var args: [Node] = []
                    if let q = peek, case .rparen = q.kind {
                        index += 1
                    } else {
                        while true {
                            args.append(try parseExpression())
                            guard let sep = next() else { throw ParseError.unexpected("end of expression", position: -1) }
                            if case .rparen = sep.kind { break }
                            guard case .comma = sep.kind else { throw ParseError.unexpected(sep.text, position: sep.position) }
                        }
                    }
                    guard Expression.functionNames.contains(name.lowercased()) else {
                        throw ParseError.unknownFunction(name)
                    }
                    return .call(name, args)
                }
                return .variable(name)
            case .lparen:
                let inner = try parseExpression()
                guard let close = next(), case .rparen = close.kind else {
                    throw ParseError.unexpected("missing )", position: tok.position)
                }
                return inner
            default:
                throw ParseError.unexpected(tok.text, position: tok.position)
            }
        }
    }
}
