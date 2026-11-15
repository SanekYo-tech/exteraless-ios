import Foundation

public enum FilteringRegexError: String, Error, Sendable {
    case invalidPattern, unsupportedConstruct, patternLimit, stateLimit
}

public enum FilteringRegexResult: Equatable, Sendable {
    case matched, notMatched, inputLimit, workLimit
}

/// A deterministic work limit shared by every rule/message in one projection.
/// Exhaustion is NOT a negative match (in particular for reversed rules).
public struct FilteringWorkBudget: Sendable {
    public private(set) var remaining: Int
    public init(operations: Int = 200_000) { remaining = max(0, min(operations, 1_000_000)) }
    fileprivate mutating func spend() -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

/// Thompson NFA: no ICU/Java backtracking and no uninterruptible regex work on a
/// UI queue. Find, MULTILINE, ASCII CASE_INSENSITIVE and reversed mode match the
/// original. Backreferences/lookarounds/inline flags are explicitly unsupported.
public struct FilteringRegex: Sendable {
    public static let maximumPatternScalars = 256
    public static let maximumInputScalars = 8_192
    public static let maximumStates = 512

    private enum Assertion: Sendable { case start, end, absoluteStart, absoluteEnd, wordBoundary(Bool) }
    private enum Matcher: Sendable {
        case literal(UInt32), any, ranges([ClosedRange<UInt32>], Bool)

        func accepts(_ value: UInt32, insensitive: Bool, budget: inout FilteringWorkBudget) -> Bool? {
            switch self {
            case let .literal(literal):
                return literal == value || (insensitive && Self.lower(literal) == Self.lower(value))
            case .any: return !FilteringRegex.isLineBreak(value)
            case let .ranges(ranges, negated):
                var found = false
                for range in ranges {
                    guard budget.spend() else { return nil }
                    if range.contains(value) || (insensitive && (range.contains(Self.lower(value)) || range.contains(Self.upper(value)))) {
                        found = true
                        break
                    }
                }
                return found != negated
            }
        }

        static func lower(_ value: UInt32) -> UInt32 { (65 ... 90).contains(value) ? value + 32 : value }
        static func upper(_ value: UInt32) -> UInt32 { (97 ... 122).contains(value) ? value - 32 : value }
    }

    private indirect enum Node: Sendable {
        case empty, atom(Matcher), assertion(Assertion), sequence([Node]), alternatives([Node]), repeatNode(Node, Int, Int?)
    }

    private enum Instruction: Sendable {
        case accept, consume(Matcher, Int), assertPosition(Assertion, Int), split(Int, Int)
    }

    private struct Parser {
        let scalars: [UInt32]
        var index = 0

        mutating func parse(depth: Int = 0) throws -> Node {
            guard depth <= 16 else { throw FilteringRegexError.patternLimit }
            var alternatives: [Node] = []
            var sequence: [Node] = []
            while index < scalars.count, scalars[index] != 41 {
                if take(124) {
                    alternatives.append(.sequence(sequence)); sequence = []
                    continue
                }
                var node = try atom(depth: depth)
                if take(42) { node = .repeatNode(node, 0, nil) }
                else if take(43) { node = .repeatNode(node, 1, nil) }
                else if take(63) { node = .repeatNode(node, 0, 1) }
                else if take(123) {
                    let lower = try number()
                    var upper: Int? = lower
                    if take(44) { upper = peek == 125 ? nil : try number() }
                    guard take(125), upper == nil || upper! >= lower else { throw FilteringRegexError.invalidPattern }
                    node = .repeatNode(node, lower, upper)
                } else {
                    sequence.append(node)
                    continue
                }
                // Reluctance changes which match, not whether find() succeeds.
                _ = take(63)
                if let next = peek, [42, 43, 63, 123].contains(next) { throw FilteringRegexError.unsupportedConstruct }
                sequence.append(node)
            }
            alternatives.append(.sequence(sequence))
            return alternatives.count == 1 ? alternatives[0] : .alternatives(alternatives)
        }

        var peek: UInt32? { index < scalars.count ? scalars[index] : nil }
        mutating func take(_ value: UInt32) -> Bool {
            guard peek == value else { return false }
            index += 1
            return true
        }
        mutating func number() throws -> Int {
            var value = 0
            let start = index
            while let char = peek, (48 ... 57).contains(char) {
                value = value * 10 + Int(char - 48); index += 1
                guard value <= 32 else { throw FilteringRegexError.patternLimit }
            }
            guard index != start else { throw FilteringRegexError.invalidPattern }
            return value
        }
        mutating func atom(depth: Int) throws -> Node {
            guard let char = peek else { throw FilteringRegexError.invalidPattern }
            index += 1
            switch char {
            case 40:
                if take(63), !take(58) { throw FilteringRegexError.unsupportedConstruct }
                let result = try parse(depth: depth + 1)
                guard take(41) else { throw FilteringRegexError.invalidPattern }
                return result
            case 46: return .atom(.any)
            case 94: return .assertion(.start)
            case 36: return .assertion(.end)
            case 91: return .atom(try characterClass())
            case 92:
                if take(65) { return .assertion(.absoluteStart) }
                if take(122) { return .assertion(.absoluteEnd) }
                if take(98) { return .assertion(.wordBoundary(true)) }
                if take(66) { return .assertion(.wordBoundary(false)) }
                return .atom(try escape())
            case 42, 43, 63, 123, 125, 93: throw FilteringRegexError.invalidPattern
            default: return .atom(.literal(char))
            }
        }

        mutating func escape() throws -> Matcher {
            guard let char = peek else { throw FilteringRegexError.invalidPattern }
            index += 1
            switch char {
            case 100, 68: return .ranges([48 ... 57], char == 68)
            case 119, 87: return .ranges([48 ... 57, 65 ... 90, 95 ... 95, 97 ... 122], char == 87)
            case 115, 83: return .ranges([9 ... 13, 32 ... 32], char == 83)
            case 110: return .literal(10)
            case 114: return .literal(13)
            case 116: return .literal(9)
            case 102: return .literal(12)
            case 117, 120:
                let length = char == 117 ? 4 : 2
                var value: UInt32 = 0
                for _ in 0 ..< length {
                    guard let digit = peek else { throw FilteringRegexError.invalidPattern }
                    let number: UInt32
                    switch digit {
                    case 48 ... 57: number = digit - 48
                    case 65 ... 70: number = digit - 55
                    case 97 ... 102: number = digit - 87
                    default: throw FilteringRegexError.invalidPattern
                    }
                    value = value * 16 + number; index += 1
                }
                guard Unicode.Scalar(value) != nil else { throw FilteringRegexError.unsupportedConstruct }
                return .literal(value)
            case 48 ... 57, 65 ... 90, 97 ... 122: throw FilteringRegexError.unsupportedConstruct
            default: return .literal(char)
            }
        }

        mutating func classAtom() throws -> Matcher {
            if take(92) { return try escape() }
            guard let char = peek, char != 91 else { throw FilteringRegexError.unsupportedConstruct }
            index += 1
            if char == 38, peek == 38 { throw FilteringRegexError.unsupportedConstruct }
            return .literal(char)
        }

        mutating func characterClass() throws -> Matcher {
            let negated = take(94)
            var ranges: [ClosedRange<UInt32>] = []
            while let char = peek, char != 93 {
                let item = try classAtom()
                if case let .literal(start) = item, take(45) {
                    if peek == 93 { ranges += [start ... start, 45 ... 45]; continue }
                    guard case let .literal(end) = try classAtom(), end >= start else { throw FilteringRegexError.invalidPattern }
                    ranges.append(start ... end)
                } else {
                    switch item {
                    case let .literal(value): ranges.append(value ... value)
                    case let .ranges(values, false): ranges.append(contentsOf: values)
                    default: throw FilteringRegexError.unsupportedConstruct
                    }
                }
            }
            guard take(93), !ranges.isEmpty else { throw FilteringRegexError.invalidPattern }
            return .ranges(ranges, negated)
        }
    }

    private let instructions: [Instruction]
    private let start: Int
    private let caseInsensitive: Bool

    public init(_ pattern: String, caseInsensitive: Bool = false) throws {
        let scalars = Array(pattern.unicodeScalars.prefix(Self.maximumPatternScalars + 1)).map(\.value)
        guard scalars.count <= Self.maximumPatternScalars else { throw FilteringRegexError.patternLimit }
        var parser = Parser(scalars: scalars)
        let tree = try parser.parse()
        guard parser.index == scalars.count else { throw FilteringRegexError.invalidPattern }
        var instructions: [Instruction] = [.accept]
        func emit(_ instruction: Instruction) throws -> Int {
            guard instructions.count < Self.maximumStates else { throw FilteringRegexError.stateLimit }
            instructions.append(instruction)
            return instructions.count - 1
        }
        func compile(_ node: Node, next: Int) throws -> Int {
            switch node {
            case .empty: return next
            case let .atom(matcher): return try emit(.consume(matcher, next))
            case let .assertion(assertion): return try emit(.assertPosition(assertion, next))
            case let .sequence(nodes):
                var result = next
                for node in nodes.reversed() { result = try compile(node, next: result) }
                return result
            case let .alternatives(nodes):
                var result = try compile(nodes[0], next: next)
                for node in nodes.dropFirst() { result = try emit(.split(result, compile(node, next: next))) }
                return result
            case let .repeatNode(child, lower, upper):
                var result = next
                if let upper {
                    for _ in lower ..< upper { result = try emit(.split(compile(child, next: result), result)) }
                } else {
                    let loop = try emit(.accept)
                    let childStart = try compile(child, next: loop)
                    instructions[loop] = .split(childStart, next)
                    result = loop
                }
                for _ in 0 ..< lower { result = try compile(child, next: result) }
                return result
            }
        }
        self.start = try compile(tree, next: 0)
        self.instructions = instructions
        self.caseInsensitive = caseInsensitive
    }

    private static func isLineBreak(_ value: UInt32) -> Bool { [10, 13, 133, 8232, 8233].contains(value) }
    private static func isWord(_ value: UInt32?) -> Bool {
        guard let value else { return false }
        // Java's default boundary is Unicode aware even when \w is ASCII.
        guard let scalar = Unicode.Scalar(value) else { return false }
        return value == 95 || CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
    }

    public func find(in text: String, budget: inout FilteringWorkBudget) -> FilteringRegexResult {
        let input = Array(text.unicodeScalars.prefix(Self.maximumInputScalars + 1)).map(\.value)
        guard input.count <= Self.maximumInputScalars else { return .inputLimit }
        var active: [Int] = []
        for position in 0 ... input.count {
            var pending = active
            pending.append(start) // find(), not matches(): admit a start at each position.
            var visited = Set<Int>()
            var consuming: [(Matcher, Int)] = []
            while let state = pending.popLast() {
                guard budget.spend() else { return .workLimit }
                guard visited.insert(state).inserted else { continue }
                switch instructions[state] {
                case .accept: return .matched
                case let .consume(matcher, next): consuming.append((matcher, next))
                case let .split(a, b): pending.append(a); pending.append(b)
                case let .assertPosition(assertion, next):
                    let before = position > 0 ? input[position - 1] : nil
                    let after = position < input.count ? input[position] : nil
                    let betweenCRLF = before == 13 && after == 10
                    let succeeds: Bool
                    switch assertion {
                    case .start: succeeds = position == 0 || (before.map(Self.isLineBreak) == true && !betweenCRLF)
                    case .end: succeeds = position == input.count || (after.map(Self.isLineBreak) == true && !betweenCRLF)
                    case .absoluteStart: succeeds = position == 0
                    case .absoluteEnd: succeeds = position == input.count
                    case let .wordBoundary(positive): succeeds = (Self.isWord(before) != Self.isWord(after)) == positive
                    }
                    if succeeds { pending.append(next) }
                }
            }
            active = []
            if position < input.count {
                for (matcher, next) in consuming {
                    guard budget.spend() else { return .workLimit }
                    guard let matches = matcher.accepts(input[position], insensitive: caseInsensitive, budget: &budget) else { return .workLimit }
                    if matches { active.append(next) }
                }
            }
        }
        return .notMatched
    }
}
