import Foundation

/// Bounded, offline counterpart of app.exteraless.math.MathExpression.
/// A suggestion is a draft insertion, never a send-time rewrite.
public enum ChatMathExpression {
    public struct Result: Equatable, Sendable {
        public let value: Double
        public let hasOperation: Bool
        public let decimalSeparator: String
    }

    public struct Suggestion: Equatable, Sendable {
        public let insertionOffset: Int
        public let insertionText: String
        public let value: String

        public init(insertionOffset: Int, insertionText: String, value: String) {
            self.insertionOffset = insertionOffset
            self.insertionText = insertionText
            self.value = value
        }
    }

    public static func evaluate(_ expression: String, decimalSeparator: String = ".") -> Result? {
        guard expression.utf16.count <= 256 else { return nil }
        do {
            var parser = try Parser(expression, decimalSeparator: decimalSeparator)
            let operand = try parser.expression(precedence: 0)
            guard parser.peek == .end, operand.value.isFinite else { return nil }
            return Result(value: operand.value, hasOperation: parser.hasOperation, decimalSeparator: parser.separator)
        } catch {
            return nil
        }
    }

    public static func format(_ value: Double, decimalSeparator: String = ".") -> String? {
        let magnitude = abs(value)
        guard value.isFinite, magnitude < 1e12, magnitude == 0 || magnitude >= 1e-9 else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.usesSignificantDigits = true
        formatter.minimumSignificantDigits = 1
        formatter.maximumSignificantDigits = 12
        formatter.roundingMode = .halfUp
        formatter.decimalSeparator = decimalSeparator.count == 1 ? decimalSeparator : "."
        guard let result = formatter.string(from: NSNumber(value: value == 0 ? 0 : value)), result.count <= 24 else { return nil }
        return result
    }

    /// Offsets are UTF-16, as in UITextInput/ChatInputContent, including text before the expression.
    public static func suggestion(in text: String, caret: Int, decimalSeparator: String = ".") -> Suggestion? {
        let source = text as NSString
        guard caret > 0, caret <= source.length, source.character(at: caret - 1) == 61 else { return nil }
        var after = caret
        while after < source.length && blank(source.character(at: after)) { after += 1 }
        if after < source.length {
            let c = source.character(at: after)
            if digit(c) || c == 46 || c == 44 { return nil }
        }
        let end = caret - 1
        let limit = max(0, end - 64)
        var start = end
        while start > limit && expressionCharacter(source.character(at: start - 1)) { start -= 1 }
        while start < end && blank(source.character(at: start)) { start += 1 }
        if start > 0 {
            let before = source.character(at: start - 1)
            if letter(before) || digit(before) || before == 95 { return nil }
        }
        while start < end {
            let candidate = source.substring(with: NSRange(location: start, length: end - start))
            if !looksLikeDate(candidate), let result = evaluate(candidate, decimalSeparator: decimalSeparator) {
                guard result.hasOperation, let value = format(result.value, decimalSeparator: result.decimalSeparator) else { return nil }
                let prefix = caret >= 2 && blank(source.character(at: caret - 2)) ? " " : ""
                return Suggestion(insertionOffset: caret, insertionText: prefix + value, value: value)
            }
            var next: Int?
            var index = start
            while index < end {
                let c = source.character(at: index)
                index += 1
                if c == 40 { next = index; break }
                if blank(c) {
                    while index < end && blank(source.character(at: index)) { index += 1 }
                    next = index
                    break
                }
            }
            guard let next, next > start else { return nil }
            start = next
        }
        return nil
    }

    private static func digit(_ c: UInt16) -> Bool { return c >= 48 && c <= 57 }
    private static func blank(_ c: UInt16) -> Bool { return c == 32 || c == 9 || c == 160 }
    private static func letter(_ c: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(UInt32(c)) else { return false }
        return CharacterSet.letters.contains(scalar)
    }
    private static func expressionCharacter(_ c: UInt16) -> Bool {
        return digit(c) || letter(c) || blank(c) || [46, 44, 43, 45, 8722, 42, 215, 47, 247, 94, 37, 33, 8730, 40, 41, 59].contains(c)
    }

    private static func looksLikeDate(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespaces)
        for mark in [Character("/"), Character("."), Character("-")] {
            let groups = text.split(separator: mark, omittingEmptySubsequences: false)
            if groups.count != 3 || !groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { continue }
            if mark == "-" { return groups[0].count == 4 && groups[1].count <= 2 && groups[2].count <= 2 }
            return groups[0].count <= 2 && groups[1].count <= 2 && (groups[2].count == 2 || groups[2].count == 4)
        }
        return false
    }

    private enum ParseError: Error { case invalid }
    private enum Token: Equatable {
        case number(Double), symbol(UInt16), identifier(String), open, close, separator, end
    }
    private struct Operand { var value: Double; var percent: Bool = false }

    private struct Parser {
        var tokens: [Token] = []
        var position = 0
        var depth = 0
        var hasOperation = false
        var separator: String
        var peek: Token { return position < tokens.count ? tokens[position] : .end }

        init(_ text: String, decimalSeparator: String) throws {
            self.separator = decimalSeparator.count == 1 ? decimalSeparator : "."
            let source = Array(text.utf16)
            var index = 0
            var foundSeparator = false
            while index < source.count {
                let c = source[index]
                if blank(c) { index += 1; continue }
                if digit(c) || ((c == 46 || c == 44) && index + 1 < source.count && digit(source[index + 1])) {
                    let start = index
                    while index < source.count && digit(source[index]) { index += 1 }
                    let integerDigits = index - start
                    if index + 1 < source.count, (source[index] == 46 || source[index] == 44), digit(source[index + 1]) {
                        let mark = source[index]
                        index += 1
                        let fractionStart = index
                        while index < source.count && digit(source[index]) { index += 1 }
                        if mark == 44 && index - fractionStart == 3 && integerDigits >= 1 && integerDigits <= 3 && source[start] != 48 { throw ParseError.invalid }
                        if !foundSeparator { self.separator = mark == 44 ? "," : "."; foundSeparator = true }
                    }
                    guard let value = Double(String(decoding: source[start ..< index], as: UTF16.self).replacingOccurrences(of: ",", with: ".")), value.isFinite else { throw ParseError.invalid }
                    tokens.append(.number(value))
                } else if letter(c) {
                    let start = index
                    while index < source.count && (letter(source[index]) || digit(source[index])) { index += 1 }
                    tokens.append(.identifier(String(decoding: source[start ..< index], as: UTF16.self).lowercased()))
                } else {
                    index += 1
                    switch c {
                    case 40: tokens.append(.open)
                    case 41: tokens.append(.close)
                    case 59: tokens.append(.separator)
                    case 43, 45, 8722, 42, 215, 47, 247, 94, 37, 33, 8730: tokens.append(.symbol(c))
                    default: throw ParseError.invalid
                    }
                }
                guard tokens.count <= 128 else { throw ParseError.invalid }
            }
            tokens.append(.end)
        }

        mutating func take() throws -> Token {
            guard position < tokens.count else { throw ParseError.invalid }
            defer { position += 1 }
            return tokens[position]
        }

        mutating func expect(_ value: Token) throws {
            guard try take() == value else { throw ParseError.invalid }
        }

        mutating func expression(precedence: Int) throws -> Operand {
            depth += 1
            defer { depth -= 1 }
            guard depth <= 32 else { throw ParseError.invalid }
            var left = try unary()
            while case let .symbol(op) = peek {
                let priority: Int
                switch op {
                case 43, 45, 8722: priority = 10
                case 42, 215, 47, 247: priority = 20
                case 94: priority = 40
                default: return left
                }
                if priority < precedence { return left }
                position += 1
                let right = try expression(precedence: op == 94 ? priority : priority + 1)
                switch op {
                case 43: left.value += right.percent ? right.value * left.value : right.value
                case 45, 8722: left.value -= right.percent ? right.value * left.value : right.value
                case 42, 215: left.value *= right.value
                case 47, 247: left.value /= right.value
                default: left.value = pow(left.value, right.value)
                }
                left.percent = false
                hasOperation = true
                guard left.value.isFinite else { throw ParseError.invalid }
            }
            return left
        }

        mutating func unary() throws -> Operand {
            if case let .symbol(op) = peek, op == 43 || op == 45 || op == 8722 || op == 8730 {
                position += 1
                var operand = try expression(precedence: op == 8730 ? 40 : 30)
                if op == 45 || op == 8722 { operand.value = -operand.value }
                if op == 8730 { operand.value = sqrt(operand.value); hasOperation = true }
                return operand
            }
            var operand = Operand(value: try primary())
            while case let .symbol(op) = peek, op == 37 || op == 33 {
                position += 1
                if op == 37 {
                    operand.value /= 100.0
                } else {
                    operand.value = try factorial(operand.value)
                }
                operand.percent = op == 37
                hasOperation = true
            }
            return operand
        }

        mutating func primary() throws -> Double {
            switch try take() {
            case let .number(value): return value
            case .open:
                let value = try expression(precedence: 0).value
                try expect(.close)
                return value
            case let .identifier(name):
                hasOperation = true
                if name == "pi" || name == "π" { return Double.pi }
                if name == "e" { return exp(1) }
                try expect(.open)
                var args: [Double] = []
                if peek != .close {
                    args.append(try expression(precedence: 0).value)
                    while peek == .separator {
                        position += 1
                        guard args.count < 32 else { throw ParseError.invalid }
                        args.append(try expression(precedence: 0).value)
                    }
                }
                try expect(.close)
                guard let first = args.first else { throw ParseError.invalid }
                if name == "min" { return args.min()! }
                if name == "max" { return args.max()! }
                if name == "atan2", args.count == 2 { return atan2(first, args[1]) }
                guard args.count == 1 else { throw ParseError.invalid }
                switch name {
                case "sqrt": return sqrt(first)
                case "cbrt": return cbrt(first)
                case "abs": return abs(first)
                case "sign": return first == 0 ? 0 : (first < 0 ? -1 : 1)
                case "round": return floor(first + 0.5)
                case "floor": return floor(first)
                case "ceil": return ceil(first)
                case "fact": return try factorial(first)
                case "log", "lg": return log10(first)
                case "ln": return log(first)
                case "exp": return exp(first)
                case "sin": return sin(first)
                case "cos": return cos(first)
                case "tan": return tan(first)
                case "asin": return asin(first)
                case "acos": return acos(first)
                case "atan": return atan(first)
                case "sinh": return sinh(first)
                case "cosh": return cosh(first)
                case "tanh": return tanh(first)
                default:
                    if name.hasPrefix("log"), name.count <= 9, let base = Double(name.dropFirst(3)), base > 0, base != 1 {
                        return log(first) / log(base)
                    }
                    throw ParseError.invalid
                }
            default: throw ParseError.invalid
            }
        }

        func factorial(_ value: Double) throws -> Double {
            guard value.isFinite, value >= 0, value <= 170, value == floor(value) else { throw ParseError.invalid }
            if value < 2 { return 1 }
            return (2 ... Int(value)).reduce(1.0) { $0 * Double($1) }
        }
    }
}
