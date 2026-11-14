import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AIGenerationRequest: Sendable {
    public enum Parameters: Sendable { case assistant, translation }
    public var messages: [AIMessage]
    public var systemPrompt: String
    public var streaming: Bool
    public var temperature: Double
    public var parameters: Parameters
    public var modelSupportsReasoning: Bool
    public var disableTools: Bool

    public init(messages: [AIMessage], systemPrompt: String = "", streaming: Bool = true, temperature: Double = 1, parameters: Parameters = .assistant, modelSupportsReasoning: Bool = false, disableTools: Bool = false) {
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.streaming = streaming
        self.temperature = temperature
        self.parameters = parameters
        self.modelSupportsReasoning = modelSupportsReasoning
        self.disableTools = disableTools
    }
}

public enum AIRequestBuilder {
    public static func normalizedBaseURL(_ input: String) throws -> URL {
        var input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw AIError.configuration }
        if !input.contains("://") { input = "https://" + input }
        guard var components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw AIError.invalidURL }
        // HTTP is only useful for a user-run loopback server / local fixtures. ATS
        // remains authoritative on iOS; no global ATS exception is installed.
        guard scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else { throw AIError.invalidURL }
        components.scheme = scheme
        while components.path.hasSuffix("/") { components.path.removeLast() }
        if components.path.hasSuffix("/chat/completions") { components.path.removeLast("/chat/completions".count) }
        guard let url = components.url else { throw AIError.invalidURL }
        return url
    }

    public static func validateModel(_ model: String) throws {
        guard !model.isEmpty, model.utf8.count <= 256,
              model.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-._/:@".unicodeScalars.contains($0) }),
              !model.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty }) else { throw AIError.invalidModel }
    }

    public static func validatedKey(_ key: String) throws -> String {
        guard !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw AIError.invalidKey }
        let key = key.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { throw AIError.missingKey }
        guard key.utf8.count <= 16_384 else { throw AIError.invalidKey }
        return key
    }

    public static func generation(service: AIService, apiKey: String, request: AIGenerationRequest, optionalParameters: Bool = true) throws -> URLRequest {
        try validateModel(service.model)
        guard request.temperature.isFinite, (0 ... 2).contains(request.temperature),
              request.messages.count <= AILimits.historyMessages + 4 else { throw AIError.configuration }
        let size = request.systemPrompt.utf16.count + request.messages.reduce(0) { $0 + $1.content.utf16.count }
        guard size <= AILimits.inputUTF16 else { throw AIError.inputTooLarge }
        let base = try normalizedBaseURL(service.url)
        let key = try validatedKey(apiKey)
        var messages = request.messages
        if !request.systemPrompt.isEmpty { messages.insert(.init(role: .system, content: request.systemPrompt), at: 0) }
        if service.wireProtocol == .vertex {
            return try vertex(base: base, model: service.model, key: key, messages: messages)
        }
        var body: [String: Any] = ["model": service.model, "messages": try messages.map(encode), "stream": request.streaming]
        if optionalParameters {
            switch request.parameters {
            case .assistant:
                // Client.requestBody: assistant temperature is stored in tenths.
                body["temperature"] = request.temperature
                if service.reasoningEffort > 0 {
                    body["reasoning_effort"] = ["none", "low", "medium", "high"][max(0, min(3, service.reasoningEffort))]
                } else if request.modelSupportsReasoning { body["reasoning_effort"] = "none" }
            case .translation:
                if AIModelParameters.supportsTemperature(service.model) { body["temperature"] = request.temperature }
                AIModelParameters.apply(to: &body, baseURL: base.absoluteString, model: service.model)
            }
        }
        var result = try json(url: base.appendingPathComponent("chat/completions"), body: body)
        result.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        result.setValue("https://github.com/exteraless/exteraless", forHTTPHeaderField: "HTTP-Referer")
        result.setValue("exteraless", forHTTPHeaderField: "X-Title")
        result.setValue(request.streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        return result
    }

    public static func models(service: AIService, apiKey: String) throws -> URLRequest {
        let base = try normalizedBaseURL(service.url)
        var request = URLRequest(url: base.appendingPathComponent("models"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: AILimits.requestTimeout)
        if !apiKey.isEmpty { request.setValue("Bearer " + (try validatedKey(apiKey)), forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func json(url: URL, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: AILimits.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) }
        catch { throw AIError.configuration }
        return request
    }

    static func encode(_ message: AIMessage) throws -> [String: Any] {
        guard let image = message.image else { return ["role": message.role.rawValue, "content": message.content] }
        guard !image.isEmpty, image.count <= AILimits.imageBytes, let mime = message.imageMIMEType,
              ["image/png", "image/jpeg", "image/webp", "image/heic"].contains(mime) else { throw AIError.inputTooLarge }
        var parts: [[String: Any]] = []
        if !message.content.isEmpty { parts.append(["type": "text", "text": message.content]) }
        parts.append(["type": "image_url", "image_url": ["url": "data:\(mime);base64," + image.base64EncodedString()]])
        return ["role": message.role.rawValue, "content": parts]
    }

    private static func vertex(base: URL, model: String, key: String, messages: [AIMessage]) throws -> URLRequest {
        var modelPath = model
        if modelPath.hasPrefix("google/") { modelPath = String(modelPath.dropFirst(7)) }
        if !modelPath.hasPrefix("publishers/") {
            modelPath = "publishers/google/" + (modelPath.hasPrefix("models/") ? modelPath : "models/" + modelPath)
        }
        var system: [[String: String]] = []
        var contents: [[String: Any]] = []
        for message in messages {
            guard message.image == nil else { throw AIError.configuration }
            if message.content.isEmpty { continue }
            if message.role == .system { system.append(["text": message.content]); continue }
            let role = message.role == .assistant ? "model" : "user"
            let part = ["text": message.content]
            if let last = contents.indices.last, contents[last]["role"] as? String == role {
                var parts = contents[last]["parts"] as? [[String: String]] ?? []
                parts.append(part)
                contents[last]["parts"] = parts
            } else { contents.append(["role": role, "parts": [part]]) }
        }
        var body: [String: Any] = ["contents": contents]
        if !system.isEmpty { body["systemInstruction"] = ["parts": system] }
        AIModelParameters.apply(to: &body, baseURL: base.absoluteString, model: model)
        var request = try json(url: base.appendingPathComponent(modelPath + ":generateContent"), body: body)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        return request
    }
}

/// Literal port of nekogram/llm/utils/ModelUtil parameter rules.
public enum AIModelParameters {
    public static func isTextGenerationModel(_ model: String) -> Bool {
        let keywords = ["-live-", "-research", "-search", "antigravity-", "aqa", "asr-", "audio", "bge-", "chirp-", "computer-use", "csm-", "deepgram", "e5-", "embed", "embedding", "flux", "gemini-omni", "gte-", "hailuo", "happyhorse", "i2v", "image", "imagen", "imagine", "kling-v", "kokoro-", "krea-", "lyria", "minilm-", "minimax-h3", "moderation", "nano-banana", "orpheus-", "parakeet-", "perplexity", "quiverai", "r2v", "realtime", "recraft", "rerank", "riverflow", "robotics", "runway", "seedance", "seedream", "sentence-transformers", "sora", "speech", "stt", "t2v", "transcri", "tts", "veo-", "video", "voice", "voyage", "wan-", "whisper", "zonos"]
        let name = model.lowercased()
        return !keywords.contains { name.contains($0) }
    }
    private static func base(_ model: String) -> String { String(model.split(separator: "/").last ?? "").lowercased() }
    private static func legacyGemini(_ name: String) -> Bool { name.hasPrefix("gemini-2") || name.hasPrefix("gemini-3-") || name.hasPrefix("gemini-3.1") }
    public static func supportsTemperature(_ model: String) -> Bool {
        let name = base(model)
        return !name.hasPrefix("gpt-5") && (!name.hasPrefix("gemini") || legacyGemini(name))
    }
    public static func reasoningEffort(_ model: String) -> String {
        let name = base(model)
        if name.hasPrefix("gpt-oss") { return "low" }
        if name.hasPrefix("gpt-5.") { return "none" }
        if name.hasPrefix("gpt-5") { return "minimal" }
        if name.hasPrefix("gemini") && name.contains("pro") { return "low" }
        if name.hasPrefix("gemini") && name.contains("flash-lite") && !legacyGemini(name) { return "minimal" }
        if name.hasPrefix("gemini") && (name.hasSuffix("latest") || !legacyGemini(name)) { return "low" }
        if name.contains("gemma4") || name.contains("gemma-4") { return "minimal" }
        if name.hasPrefix("grok-4") || name.hasPrefix("glm-5.3") { return "low" }
        if name.hasPrefix("muse-spark") { return "minimal" }
        return "none"
    }
    static func apply(to body: inout [String: Any], baseURL: String, model: String) {
        let name = base(model)
        if (name.hasPrefix("gpt-5") && (name.contains("instant") || name.contains("chat"))) || name.contains("non-reasoning") { return }
        if baseURL == AILLMPreset.vertex.baseURL {
            let config: [String: Any]
            if name.hasPrefix("gemini-2") { config = ["thinkingBudget": name.contains("pro") ? 128 : 0] }
            else {
                let low = name.contains("flash-latest") || (name.hasPrefix("gemini-3") && (name.contains("pro") || name.hasPrefix("gemini-3.7")))
                let minimal = name.hasPrefix("gemini-3") || name.contains("gemma4") || name.contains("gemma-4")
                config = ["thinkingLevel": low || !minimal ? "LOW" : "MINIMAL"]
            }
            body["generationConfig"] = ["thinkingConfig": config]
        } else if model.contains("/") && (baseURL == AILLMPreset.openRouter.baseURL || baseURL == AILLMPreset.vercel.baseURL) {
            if baseURL == AILLMPreset.vercel.baseURL {
                var options: [String: Any] = ["gateway": ["sort": "ttft"]]
                if model.lowercased().hasPrefix("deepseek/") && name.hasPrefix("deepseek-v4") {
                    options["deepseek"] = ["thinking": ["type": "disabled"]]
                    body["providerOptions"] = options
                    return
                }
                body["providerOptions"] = options
            }
            body["reasoning"] = ["effort": reasoningEffort(model)]
        } else if name.hasPrefix("deepseek-v4") { body["thinking"] = ["type": "disabled"] }
        else { body["reasoning_effort"] = reasoningEffort(model) }
    }
}
