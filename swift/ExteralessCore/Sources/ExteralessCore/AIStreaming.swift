import Foundation

/// Incremental SSE framing. UTF-8 is decoded only after complete byte-delimited
/// lines, so splitting a Cyrillic character or emoji between packets is lossless.
public struct AISSEDecoder: Sendable {
    private var line = Data()
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var previousWasCR = false
    private var firstLine = true

    public init() {}

    public mutating func append(_ data: Data) throws -> [String] {
        var events: [String] = []
        for byte in data {
            if previousWasCR {
                previousWasCR = false
                if byte == 10 { continue }
            }
            if byte == 10 || byte == 13 {
                if let event = try endLine() { events.append(event) }
                previousWasCR = byte == 13
            } else {
                line.append(byte)
                guard line.count + eventBytes <= AILimits.eventBytes else { throw AIError.responseTooLarge }
            }
        }
        return events
    }

    public mutating func finish() throws -> [String] {
        var events: [String] = []
        if !line.isEmpty, let event = try endLine() { events.append(event) }
        if !dataLines.isEmpty {
            events.append(dataLines.joined(separator: "\n"))
            dataLines = []
            eventBytes = 0
        }
        return events
    }

    private mutating func endLine() throws -> String? {
        guard var text = String(data: line, encoding: .utf8) else { throw AIError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if text.hasPrefix("\u{feff}") { text.removeFirst() }
        }
        if text.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            let event = dataLines.joined(separator: "\n")
            dataLines = []
            eventBytes = 0
            return event
        }
        if text.hasPrefix("data:") || text == "data" {
            var value = text == "data" ? "" : String(text.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            eventBytes += value.utf8.count + 1
            guard eventBytes <= AILimits.eventBytes else { throw AIError.responseTooLarge }
            dataLines.append(value)
        }
        return nil
    }
}

public struct AIReasoningFilter: Sendable {
    public struct Output: Equatable, Sendable {
        public let text: String
        public let reasoning: String
        public let thinking: Bool
    }
    private var pending = ""
    private var inReasoning = false

    public init() {}

    public mutating func append(_ chunk: String) -> Output {
        pending += chunk
        var visible = ""
        var reasoning = ""
        var thinking = false
        while !pending.isEmpty {
            let tag = inReasoning ? "</think>" : "<think>"
            if let range = pending.range(of: tag) {
                let prefix = String(pending[..<range.lowerBound])
                if inReasoning { reasoning += prefix } else { visible += prefix }
                pending = String(pending[range.upperBound...])
                inReasoning.toggle()
                thinking = thinking || inReasoning
            } else {
                var keep = 0
                for length in (1 ..< tag.count).reversed() where pending.count >= length {
                    if tag.hasPrefix(String(pending.suffix(length))) { keep = length; break }
                }
                let ready = String(pending.dropLast(keep))
                if inReasoning { reasoning += ready } else { visible += ready }
                pending = String(pending.suffix(keep))
                break
            }
        }
        return Output(text: visible, reasoning: reasoning, thinking: thinking)
    }

    public mutating func finish() -> Output {
        let output = Output(text: inReasoning ? "" : pending, reasoning: inReasoning ? pending : "", thinking: false)
        pending = ""
        inReasoning = false
        return output
    }
}

public enum AIResponseParser {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.invalidResponse }
        if object["error"] != nil { throw AIError.invalidResponse }
        return object
    }

    public static func single(_ data: Data, wireProtocol: AIWireProtocol = .openAI) throws -> AIResponse {
        let object = try object(data)
        if wireProtocol == .vertex {
            if let feedback = object["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil { throw AIError.blocked }
            guard let candidates = object["candidates"] as? [[String: Any]], let first = candidates.first,
                  let content = first["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] else { throw AIError.emptyResponse }
            let reason = first["finishReason"] as? String
            try checkFinishReason(reason)
            let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
            let reasoning = parts.filter { $0["thought"] as? Bool == true }.compactMap { $0["text"] as? String }.joined()
            return try validated(text: text, reasoning: reasoning, finishReason: reason)
        }
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any] else { throw AIError.emptyResponse }
        if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty { throw AIError.unsupportedTools }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw AIError.blocked }
        let reason = first["finish_reason"] as? String
        try checkFinishReason(reason)
        guard let content = textContent(message["content"]) else { throw AIError.emptyResponse }
        var filter = AIReasoningFilter()
        let output = filter.append(content)
        let tail = filter.finish()
        return try validated(text: output.text + tail.text, reasoning: reasoning(message) + output.reasoning + tail.reasoning, finishReason: reason)
    }

    static func textContent(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let parts = value as? [[String: Any]] {
            return parts.filter { $0["type"] as? String == "text" || $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }

    static func reasoning(_ message: [String: Any]) -> String {
        for field in ["reasoning_content", "reasoning", "reasoning_details", "thinking"] {
            if let text = message[field] as? String, !text.isEmpty { return text }
            if let object = message[field] as? [String: Any], let text = object["content"] as? String, !text.isEmpty { return text }
            if let array = message[field] as? [[String: Any]] {
                let text = array.compactMap { ($0["text"] as? String) ?? ($0["summary"] as? String) }.joined()
                if !text.isEmpty { return text }
            }
        }
        return ""
    }

    static func checkFinishReason(_ reason: String?) throws {
        if ["content_filter", "SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST"].contains(reason ?? "") { throw AIError.blocked }
        if ["length", "MAX_TOKENS"].contains(reason ?? "") { throw AIError.responseTooLarge }
        if ["tool_calls", "function_call"].contains(reason ?? "") { throw AIError.unsupportedTools }
    }

    static func validated(text: String, reasoning: String, finishReason: String?) throws -> AIResponse {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.emptyResponse }
        guard text.utf16.count <= AILimits.responseUTF16, reasoning.utf16.count <= AILimits.responseUTF16 else { throw AIError.responseTooLarge }
        return AIResponse(text: text, reasoning: reasoning, finishReason: finishReason)
    }

    public static func models(_ data: Data, stripModelsPrefix: Bool = false) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { throw AIError.invalidResponse }
        let entries: [Any]
        if let array = root as? [Any] { entries = array }
        else if let object = root as? [String: Any] {
            if object["error"] != nil { throw AIError.invalidResponse }
            if let array = (object["data"] ?? object["models"]) as? [Any] { entries = array }
            else if let model = object["data"] as? [String: Any] { entries = [model] }
            else { throw AIError.invalidResponse }
        } else { throw AIError.invalidResponse }
        var models: [String] = []
        var seen = Set<String>()
        for entry in entries {
            guard var id = ((entry as? String) ?? (entry as? [String: Any])?["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            if stripModelsPrefix && id.hasPrefix("models/") { id = String(id.dropFirst(7)) }
            if (try? AIRequestBuilder.validateModel(id)) != nil, seen.insert(id).inserted { models.append(id) }
        }
        guard !models.isEmpty else { throw AIError.emptyResponse }
        return models
    }

    public static func catalog(_ data: Data) throws -> [String: AIModelInfo] {
        let root = try object(data)
        var result: [String: AIModelInfo] = [:]
        for provider in root.values {
            guard let models = (provider as? [String: Any])?["models"] as? [String: [String: Any]] else { continue }
            for (id, model) in models {
                result[id.lowercased()] = AIModelInfo(id: id, name: model["name"] as? String ?? id, reasoning: model["reasoning"] as? Bool ?? false, context: (model["limit"] as? [String: Any])?["context"] as? Int ?? 0)
            }
        }
        guard !result.isEmpty else { throw AIError.invalidResponse }
        return result
    }
}

struct AIStreamAccumulator {
    var text = ""
    var reasoning = ""
    var finishReason: String?
    var done = false
    private var filter = AIReasoningFilter()
    private var thinkingReported = false
    private var textLength = 0
    private var reasoningLength = 0

    mutating func consume(_ event: String) throws -> [AIGenerationEvent] {
        guard !done else { return [] }
        if event.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { done = true; return [] }
        if event.isEmpty { return [] }
        let root = try AIResponseParser.object(Data(event.utf8))
        guard let choices = root["choices"] as? [[String: Any]] else { throw AIError.invalidResponse }
        guard let first = choices.first(where: { ($0["index"] as? Int ?? 0) == 0 }) else { return [] } // usage-only event
        if let reason = first["finish_reason"] as? String {
            try AIResponseParser.checkFinishReason(reason)
            finishReason = reason
        }
        guard let delta = first["delta"] as? [String: Any] else { return [] }
        if delta["tool_calls"] != nil || delta["function_call"] != nil { throw AIError.unsupportedTools }
        if let refusal = delta["refusal"] as? String, !refusal.isEmpty { throw AIError.blocked }
        // Some servers emit content AND reasoning in the same event.
        let output = filter.append(AIResponseParser.textContent(delta["content"]) ?? "")
        return try append(text: output.text, reasoning: AIResponseParser.reasoning(delta) + output.reasoning, thinking: output.thinking)
    }

    private mutating func append(text: String, reasoning: String, thinking: Bool) throws -> [AIGenerationEvent] {
        let addedText = text.utf16.count
        let addedReasoning = reasoning.utf16.count
        guard textLength + addedText <= AILimits.responseUTF16,
              reasoningLength + addedReasoning <= AILimits.responseUTF16 else { throw AIError.responseTooLarge }
        textLength += addedText
        reasoningLength += addedReasoning
        var events: [AIGenerationEvent] = []
        if (!reasoning.isEmpty || thinking) && !thinkingReported { thinkingReported = true; events.append(.thinking) }
        if !reasoning.isEmpty { self.reasoning += reasoning; events.append(.reasoning(reasoning)) }
        if !text.isEmpty { self.text += text; events.append(.text(text)) }
        return events
    }

    mutating func finish() throws -> ([AIGenerationEvent], AIResponse) {
        guard done || finishReason != nil else { throw AIError.incompleteStream }
        let tail = filter.finish()
        let events = try append(text: tail.text, reasoning: tail.reasoning, thinking: false)
        return (events, try AIResponseParser.validated(text: text, reasoning: reasoning, finishReason: finishReason))
    }
}
