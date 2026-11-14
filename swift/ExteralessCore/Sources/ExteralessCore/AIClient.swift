import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AIToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let parameters: ClientSettingValue

    public init(name: String, description: String, parameters: ClientSettingValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// The caller supplies an explicit allowlist and real implementations. No tool is
/// synthesized from a model-supplied name, and cancellation is checked per call.
public struct AIToolHandler: Sendable {
    public let definitions: [AIToolDefinition]
    public let call: @Sendable (String, ClientSettingValue) async throws -> String
    public let fallback: [AIMessage]?

    public init(definitions: [AIToolDefinition], fallback: [AIMessage]? = nil, call: @escaping @Sendable (String, ClientSettingValue) async throws -> String) {
        self.definitions = definitions
        self.fallback = fallback
        self.call = call
    }
}

public final class AIClient: Sendable {
    public let transport: any AIHTTPTransport

    public init(transport: any AIHTTPTransport = AIURLSessionTransport()) { self.transport = transport }

    public func generate(service: AIService, apiKey: String, request: AIGenerationRequest, tools: AIToolHandler? = nil, onEvent: @escaping @Sendable (AIGenerationEvent) async -> Void = { _ in }) async throws -> AIResponse {
        do {
            try Task.checkCancellation()
            if let tools, !request.disableTools {
                return try await generateWithTools(service: service, apiKey: apiKey, input: request, tools: tools, onEvent: onEvent)
            }
            let built = try AIRequestBuilder.generation(service: service, apiKey: apiKey, request: request)
            do { return try await receive(built, streaming: request.streaming && service.wireProtocol == .openAI, wire: service.wireProtocol, onEvent: onEvent) }
            catch AIError.http(400) where service.wireProtocol == .openAI {
                // LlmTransport.executeWithOptionalParameters: one retry only,
                // after a rejected request, never replay a partially generated response.
                try Task.checkCancellation()
                let retry = try AIRequestBuilder.generation(service: service, apiKey: apiKey, request: request, optionalParameters: false)
                return try await receive(retry, streaming: request.streaming, wire: service.wireProtocol, onEvent: onEvent)
            }
        } catch { throw AIError.sanitized(error) }
    }

    public func listModels(service: AIService, apiKey: String) async throws -> [String] {
        try Task.checkCancellation()
        if service.wireProtocol == .vertex { return AILLMPreset.vertexModels }
        let request = try AIRequestBuilder.models(service: service, apiKey: apiKey)
        let data = try await transport.data(for: request, timeout: 30)
        return try AIResponseParser.models(data, stripModelsPrefix: request.url?.host == "generativelanguage.googleapis.com")
    }

    public func loadCatalog() async throws -> [String: AIModelInfo] {
        let request = URLRequest(url: URL(string: "https://models.dev/api.json")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let data = try await transport.data(for: request, maximumBytes: 16 * 1024 * 1024, timeout: 30)
        return try AIResponseParser.catalog(data)
    }

    private func receive(_ request: URLRequest, streaming: Bool, wire: AIWireProtocol, onEvent: @escaping @Sendable (AIGenerationEvent) async -> Void) async throws -> AIResponse {
        if !streaming {
            let data = try await transport.data(for: request)
            let response = try AIResponseParser.single(data, wireProtocol: wire)
            try Task.checkCancellation()
            if !response.reasoning.isEmpty { await onEvent(.thinking); await onEvent(.reasoning(response.reasoning)) }
            await onEvent(.text(response.text))
            return response
        }
        var parser = AISSEDecoder()
        var accumulator = AIStreamAccumulator()
        var receivedResponse = false
        var jsonFallback = false
        var json = Data()
        for try await event in transport.events(for: request, maximumBytes: AILimits.responseBytes, timeout: AILimits.resourceTimeout) {
            try Task.checkCancellation()
            switch event {
            case let .response(status, headers):
                guard (200 ..< 300).contains(status) else { throw AIError.http(status) }
                receivedResponse = true
                jsonFallback = headers["content-type"]?.lowercased().contains("application/json") == true
            case let .data(data):
                guard receivedResponse else { throw AIError.invalidResponse }
                if jsonFallback {
                    guard json.count + data.count <= AILimits.responseBytes else { throw AIError.responseTooLarge }
                    json.append(data)
                } else {
                    for frame in try parser.append(data) {
                        for update in try accumulator.consume(frame) { await onEvent(update) }
                    }
                }
            }
            if accumulator.done { break }
        }
        try Task.checkCancellation()
        guard receivedResponse else { throw AIError.invalidResponse }
        if jsonFallback {
            let response = try AIResponseParser.single(json)
            if !response.reasoning.isEmpty { await onEvent(.thinking); await onEvent(.reasoning(response.reasoning)) }
            await onEvent(.text(response.text))
            return response
        }
        for frame in try parser.finish() { for update in try accumulator.consume(frame) { await onEvent(update) } }
        let (events, response) = try accumulator.finish()
        for event in events { await onEvent(event) }
        return response
    }

    private func generateWithTools(service: AIService, apiKey: String, input: AIGenerationRequest, tools: AIToolHandler, onEvent: @escaping @Sendable (AIGenerationEvent) async -> Void) async throws -> AIResponse {
        guard service.wireProtocol == .openAI, !tools.definitions.isEmpty, tools.definitions.count <= AILimits.toolCallsPerRound else { throw AIError.unsupportedTools }
        let fallbackStreaming = input.streaming
        var input = input
        input.streaming = false // Android runTools uses non-streaming tool rounds too.
        var request = try AIRequestBuilder.generation(service: service, apiKey: apiKey, request: input)
        guard let data = request.httpBody, var body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], var messages = body["messages"] as? [[String: Any]] else { throw AIError.configuration }
        let allowed = Set(tools.definitions.map(\.name))
        guard allowed.count == tools.definitions.count else { throw AIError.configuration }
        body["tools"] = try tools.definitions.map { definition -> [String: Any] in
            guard !definition.name.isEmpty, definition.name.utf8.count <= 64, case .object = definition.parameters else { throw AIError.configuration }
            let parameters = try JSONSerialization.jsonObject(with: JSONEncoder().encode(definition.parameters))
            return ["type": "function", "function": ["name": definition.name, "description": definition.description, "parameters": parameters]]
        }
        var allReasoning = ""
        for round in 0 ..< AILimits.toolRounds {
            try Task.checkCancellation()
            body["messages"] = messages
            body["tool_choice"] = round == AILimits.toolRounds - 1 ? "none" : "auto"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            guard (request.httpBody?.count ?? 0) <= AILimits.responseBytes else { throw AIError.inputTooLarge }
            let data: Data
            do { data = try await transport.data(for: request) }
            catch let AIError.http(code) where round == 0 && (400 ..< 500).contains(code) && ![401, 403, 429].contains(code) {
                guard let fallback = tools.fallback, !fallback.isEmpty else { throw AIError.http(code) }
                input.messages = fallback
                input.streaming = fallbackStreaming
                return try await generate(service: service, apiKey: apiKey, request: input, onEvent: onEvent)
            }
            let root = try AIResponseParser.object(data)
            guard let choice = (root["choices"] as? [[String: Any]])?.first, let message = choice["message"] as? [String: Any] else { throw AIError.emptyResponse }
            guard let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty else {
                let response = try AIResponseParser.single(data)
                guard allReasoning.utf16.count + response.reasoning.utf16.count <= AILimits.responseUTF16 else { throw AIError.responseTooLarge }
                allReasoning += response.reasoning
                if !response.reasoning.isEmpty { await onEvent(.reasoning(response.reasoning)) }
                await onEvent(.text(response.text))
                return AIResponse(text: response.text, reasoning: allReasoning, finishReason: response.finishReason)
            }
            guard calls.count <= AILimits.toolCallsPerRound else { throw AIError.toolLimit }
            await onEvent(.thinking)
            let reasoning = AIResponseParser.reasoning(message)
            guard allReasoning.utf16.count + reasoning.utf16.count <= AILimits.responseUTF16 else { throw AIError.responseTooLarge }
            allReasoning += reasoning
            if !reasoning.isEmpty { await onEvent(.reasoning(reasoning)) }
            messages.append(["role": "assistant", "content": message["content"] ?? NSNull(), "tool_calls": calls])
            for call in calls {
                try Task.checkCancellation()
                guard let id = call["id"] as? String, !id.isEmpty,
                      let function = call["function"] as? [String: Any], let name = function["name"] as? String, allowed.contains(name),
                      let raw = function["arguments"] as? String, raw.utf8.count <= AILimits.eventBytes,
                      let arguments = try? JSONDecoder().decode(ClientSettingValue.self, from: Data(raw.utf8)), case .object = arguments else { throw AIError.unsupportedTools }
                await onEvent(.tool(name))
                let result: String
                do { result = try await tools.call(name, arguments) }
                catch { if Task.isCancelled { throw AIError.cancelled }; throw AIError.toolFailed }
                try Task.checkCancellation()
                guard result.utf16.count <= AIPluginReviewTools.maximumResultUTF16 else { throw AIError.inputTooLarge }
                messages.append(["role": "tool", "tool_call_id": id, "content": result])
            }
        }
        throw AIError.toolLimit
    }
}
