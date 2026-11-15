import Foundation

/// Ephemeral wire state for compatible chat-completion tool rounds. This is kept
/// separately from AIResponse.reasoning (display text), and never enters history.
/// DeepSeek uses reasoning_content; compatible gateways can require structured
/// reasoning_details, including opaque encrypted data/signatures, unchanged.
struct AIReasoningContinuation {
    private let fields: [String: ClientSettingValue]

    init(message: [String: Any]) throws {
        var fields: [String: ClientSettingValue] = [:]
        var remainingBytes = AILimits.eventBytes
        func stringValue(_ value: Any) throws -> ClientSettingValue {
            if value is NSNull { return .null }
            guard let text = value as? String else { throw AIError.invalidResponse }
            guard text.utf8.count <= remainingBytes else { throw AIError.responseTooLarge }
            remainingBytes -= text.utf8.count
            return .string(text)
        }
        for key in ["reasoning_content", "reasoning", "thinking"] {
            guard let value = message[key] else { continue }
            if key != "reasoning_content", let object = value as? [String: Any] {
                var preserved: [String: ClientSettingValue] = [:]
                for field in ["content", "signature", "id", "format", "type"] {
                    if let value = object[field] { preserved[field] = try stringValue(value) }
                }
                if !preserved.isEmpty { fields[key] = .object(preserved) }
            } else { fields[key] = try stringValue(value) }
        }
        if let raw = message["reasoning_details"], !(raw is NSNull) {
            guard let details = raw as? [[String: Any]] else { throw AIError.invalidResponse }
            guard details.count <= 64 else { throw AIError.responseTooLarge }
            var preserved: [ClientSettingValue] = []
            for detail in details {
                guard let type = detail["type"] as? String,
                      ["reasoning.text", "reasoning.summary", "reasoning.encrypted"].contains(type) else { continue }
                var entry: [String: ClientSettingValue] = ["type": .string(type)]
                for key in ["id", "format", "text", "summary", "data", "signature"] {
                    guard let value = detail[key] else { continue }
                    entry[key] = try stringValue(value)
                }
                if let index = detail["index"] {
                    let data = try JSONSerialization.data(withJSONObject: index, options: [.fragmentsAllowed])
                    guard case let .integer(value) = try JSONDecoder().decode(ClientSettingValue.self, from: data), value >= 0 else { throw AIError.invalidResponse }
                    entry["index"] = .integer(value)
                }
                preserved.append(.object(entry))
            }
            fields["reasoning_details"] = .array(preserved)
        }
        guard try JSONEncoder().encode(fields).count <= AILimits.eventBytes else { throw AIError.responseTooLarge }
        self.fields = fields
    }

    func apply(to message: inout [String: Any]) throws {
        let data = try JSONEncoder().encode(fields)
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.invalidResponse }
        for (key, value) in values { message[key] = value }
    }
}
