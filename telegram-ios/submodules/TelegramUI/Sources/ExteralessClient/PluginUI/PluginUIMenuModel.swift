import Foundation

public enum PluginUIMenuPlacement: String, Sendable {
    case message = "MESSAGE_CONTEXT_MENU"
    case drawer = "DRAWER_MENU"
    case main = "MAIN_MENU"
    case chat = "CHAT_ACTION_MENU"
    case profile = "PROFILE_ACTION_MENU"
}

struct PluginUIMenuModel: Equatable, Sendable {
    let placement: PluginUIMenuPlacement
    let itemId: String?
    let text: String
    let subtext: String?
    let icon: String?
    let priority: Int32
    let condition: PluginUIMenuCondition

    init(_ raw: PluginUIJSON) throws {
        guard let object = raw.object,
              let name = try object.uiString("menu_type", limit: 64), let placement = PluginUIMenuPlacement(rawValue: name),
              let text = try object.uiString("text", limit: 4096), !text.isEmpty else {
            throw PluginUIFailure.malformed("menuRegister requires a supported menu_type and nonempty text")
        }
        try object.uiFields(["menu_type", "item_id", "text", "subtext", "icon", "priority", "condition"], name: "menuRegister")
        let priority = object["priority"] ?? .integer(0)
        guard let number = priority.integer, let integer = Int32(exactly: number) else {
            throw PluginUIFailure.malformed("Menu priority must fit Int32")
        }
        self.placement = placement
        let requestedId = try object.uiString("item_id", limit: 256)
        self.itemId = requestedId?.isEmpty == false ? requestedId : nil
        self.text = text
        self.subtext = try object.uiString("subtext", limit: 4096)
        self.icon = try object.uiString("icon", limit: 256)
        if let icon = self.icon { _ = try PluginUIImages.reference(icon) }
        self.priority = integer
        self.condition = try PluginUIMenuCondition(object.uiString("condition", limit: 2048))
    }
}

/// The common read-only MVEL subset has native value semantics. No eval,
/// reflection, arbitrary function calls, or Python execution during menu layout.
/// Anything outside this grammar fails at registration, not on the user's tap.
struct PluginUIMenuCondition: Equatable, Sendable {
    indirect enum Expression: Equatable, Sendable {
        case literal(PluginUIJSON)
        case field(String)
        case not(Expression)
        case and(Expression, Expression)
        case or(Expression, Expression)
        case compare(String, Expression, Expression)

        func value(in context: [String: PluginUIJSON]) -> PluginUIJSON {
            switch self {
            case let .literal(value): return value
            case let .field(name):
                var value = PluginUIJSON.object(context)
                for component in name.split(separator: ".") { value = value.object?[String(component)] ?? .null }
                return value
            case let .not(value): return .bool(!Self.truth(value.value(in: context)))
            case let .and(left, right): return .bool(Self.truth(left.value(in: context)) && Self.truth(right.value(in: context)))
            case let .or(left, right): return .bool(Self.truth(left.value(in: context)) || Self.truth(right.value(in: context)))
            case let .compare(op, left, right):
                let lhs = left.value(in: context)
                let rhs = right.value(in: context)
                let equal: Bool
                if let l = lhs.integer, let r = rhs.integer { equal = l == r }
                else if let l = lhs.number, let r = rhs.number { equal = l == r }
                else { equal = lhs == rhs }
                switch op {
                case "==": return .bool(equal)
                case "!=": return .bool(!equal)
                case "contains":
                    if let l = lhs.string, let r = rhs.string { return .bool(l.contains(r)) }
                    if let l = lhs.array { return .bool(l.contains(rhs)) }
                    return .bool(false)
                default:
                    if let l = lhs.integer, let r = rhs.integer {
                        switch op {
                        case "<": return .bool(l < r)
                        case "<=": return .bool(l <= r)
                        case ">": return .bool(l > r)
                        case ">=": return .bool(l >= r)
                        default: return .bool(false)
                        }
                    }
                    if let l = lhs.number, let r = rhs.number {
                        switch op {
                        case "<": return .bool(l < r)
                        case "<=": return .bool(l <= r)
                        case ">": return .bool(l > r)
                        case ">=": return .bool(l >= r)
                        default: return .bool(false)
                        }
                    }
                    return .bool(false)
                }
            }
        }

        static func truth(_ value: PluginUIJSON) -> Bool {
            switch value {
            case .null: return false
            case let .bool(value): return value
            case let .integer(value): return value != 0
            case let .number(value): return value != 0
            case let .string(value): return !value.isEmpty
            case .object, .array: return true
            }
        }
    }

    let expression: Expression

    init(_ text: String?) throws {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.expression = .literal(.bool(true))
            return
        }
        var parser = try Parser(text)
        self.expression = try parser.parse()
    }

    func matches(_ context: [String: PluginUIJSON]) -> Bool { return Expression.truth(self.expression.value(in: context)) }

    private struct Parser {
        enum Token: Equatable { case word(String), value(PluginUIJSON), op(String), left, right }
        let tokens: [Token]
        var index = 0

        // These fields are populated from EnginePeer/EngineMessage at the actual
        // call site. Do not add a path without adding its native snapshot value.
        static let fields: Set<String> = [
            "account", "dialog_id", "chatId", "userId", "message", "chat", "user", "encryptedChat", "fragment", "context",
            "message.id", "message.text", "message.messageText", "message.out", "message.isOutOwner", "message.isPhoto", "message.isVideo", "message.isVoice", "message.isMusic", "message.isDocument", "message.isSticker", "message.getId", "message.getDialogId",
            "message.isRoundVideo", "message.isGif", "message.isAnimatedSticker",
            "user.id", "user.bot", "user.first_name", "user.last_name", "user.username", "user.is_self",
            "chat.id", "chat.title", "chat.username", "chat.megagroup", "chat.broadcast", "chat.forum",
            "fragment.kind", "fragment.title"
        ]
        static let methods: Set<String> = ["message.isOutOwner", "message.isPhoto", "message.isVideo", "message.isVoice", "message.isMusic", "message.isDocument", "message.isSticker", "message.isRoundVideo", "message.isGif", "message.isAnimatedSticker", "message.getId", "message.getDialogId"]

        init(_ text: String) throws {
            guard text.utf8.count <= 2048 else { throw PluginUIFailure.malformed("Menu condition exceeds 2 KiB") }
            let characters = Array(text)
            var result: [Token] = []
            var i = 0
            while i < characters.count {
                let c = characters[i]
                if c.isWhitespace { i += 1; continue }
                guard result.count < 128 else { throw PluginUIFailure.malformed("Menu condition exceeds 128 tokens") }
                if c == "(" { result.append(.left); i += 1; continue }
                if c == ")" { result.append(.right); i += 1; continue }
                if c == "\"" || c == "'" {
                    let quote = c
                    i += 1
                    var value = ""
                    var closed = false
                    while i < characters.count {
                        let char = characters[i]
                        i += 1
                        if char == quote { closed = true; break }
                        if char == "\\" {
                            guard i < characters.count else { throw PluginUIFailure.malformed("Unterminated menu string escape") }
                            let escaped = characters[i]
                            i += 1
                            if escaped == "n" { value.append("\n") }
                            else if escaped == "t" { value.append("\t") }
                            else if escaped == "\\" || escaped == quote { value.append(escaped) }
                            else { throw PluginUIFailure.unsupported("Unsupported escape in menu condition") }
                        } else { value.append(char) }
                    }
                    guard closed else { throw PluginUIFailure.malformed("Unterminated menu condition string") }
                    result.append(.value(.string(value)))
                    continue
                }
                if c.isNumber || c == "-" {
                    let start = i
                    i += 1
                    while i < characters.count && (characters[i].isNumber || characters[i] == ".") { i += 1 }
                    let number = String(characters[start..<i])
                    if let integer = Int64(number) { result.append(.value(.integer(integer))) }
                    else if let value = Double(number), value.isFinite { result.append(.value(.number(value))) }
                    else { throw PluginUIFailure.malformed("Invalid menu condition number") }
                    continue
                }
                if c.isLetter || c == "_" {
                    let start = i
                    i += 1
                    while i < characters.count && (characters[i].isLetter || characters[i].isNumber || characters[i] == "_" || characters[i] == ".") { i += 1 }
                    let word = String(characters[start..<i])
                    switch word {
                    case "true": result.append(.value(.bool(true)))
                    case "false": result.append(.value(.bool(false)))
                    case "null", "nil": result.append(.value(.null))
                    case "contains": result.append(.op(word))
                    default: result.append(.word(word))
                    }
                    continue
                }
                let pair = i + 1 < characters.count ? String(characters[i...i + 1]) : ""
                if ["&&", "||", "==", "!=", "<=", ">="].contains(pair) { result.append(.op(pair)); i += 2; continue }
                if ["!", "<", ">"].contains(String(c)) { result.append(.op(String(c))); i += 1; continue }
                throw PluginUIFailure.unsupported("Menu condition contains unsupported MVEL syntax")
            }
            self.tokens = result
        }

        mutating func parse() throws -> Expression {
            let result = try self.parseOr(depth: 0)
            guard self.index == self.tokens.count else { throw PluginUIFailure.unsupported("Unsupported expression at end of menu condition") }
            return result
        }

        mutating func take(_ token: Token) -> Bool {
            guard self.index < self.tokens.count, self.tokens[self.index] == token else { return false }
            self.index += 1
            return true
        }

        mutating func parseOr(depth: Int) throws -> Expression {
            guard depth <= 16 else { throw PluginUIFailure.malformed("Menu condition exceeds 16 levels") }
            var value = try self.parseAnd(depth: depth)
            while self.take(.op("||")) { value = .or(value, try self.parseAnd(depth: depth)) }
            return value
        }

        mutating func parseAnd(depth: Int) throws -> Expression {
            var value = try self.parseComparison(depth: depth)
            while self.take(.op("&&")) { value = .and(value, try self.parseComparison(depth: depth)) }
            return value
        }

        mutating func parseComparison(depth: Int) throws -> Expression {
            let left = try self.parseAtom(depth: depth)
            if self.index < self.tokens.count, case let .op(op) = self.tokens[self.index], ["==", "!=", "<", "<=", ">", ">=", "contains"].contains(op) {
                self.index += 1
                return .compare(op, left, try self.parseAtom(depth: depth))
            }
            return left
        }

        mutating func parseAtom(depth: Int) throws -> Expression {
            guard depth <= 16, self.index < self.tokens.count else { throw PluginUIFailure.malformed("Incomplete or deeply nested menu condition") }
            if self.take(.op("!")) { return .not(try self.parseAtom(depth: depth + 1)) }
            if self.take(.left) {
                let value = try self.parseOr(depth: depth + 1)
                guard self.take(.right) else { throw PluginUIFailure.malformed("Unbalanced menu condition") }
                return value
            }
            let token = self.tokens[self.index]
            self.index += 1
            switch token {
            case let .value(value): return .literal(value)
            case let .word(name):
                guard Self.fields.contains(name) else { throw PluginUIFailure.unsupported("Unsupported menu context field: \(name)") }
                if self.take(.left) {
                    guard Self.methods.contains(name), self.take(.right) else { throw PluginUIFailure.unsupported("Menu conditions support only documented read-only zero-argument message accessors") }
                }
                return .field(name)
            default: throw PluginUIFailure.malformed("Expected a menu condition value")
            }
        }
    }
}
