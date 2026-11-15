import Foundation

enum CloudLegacyAIImport {
    struct ServiceRecord: Sendable {
        let service: AIService
        let legacyHash: Int32
        let incomingKey: String?
    }

    static let credentialAliases: [String: CloudCredentialID] = [
        "neko.googleCloudTranslateKey": .translation(.googleCloud),
        "nagram.deepLTranslateKey": .translation(.deepL),
        "nagram.transcribeProviderCfApiToken": .translation(.cloudflareAudio),
        "nagram.transcribeProviderGeminiApiKey": .translation(.geminiAudio),
        "nagram.transcribeProviderOpenAiApiKey": .translation(.openAIAudio),
        "nagram.llmApiKey": .llm(preset: .custom),
        "nagram.llmProviderOpenAIKey": .llm(preset: .openAI),
        "nagram.llmProviderGeminiKey": .llm(preset: .gemini),
        "nagram.llmProviderGroqKey": .llm(preset: .groq),
        "nagram.llmProviderDeepSeekKey": .llm(preset: .deepSeek),
        "nagram.llmProviderXAIKey": .llm(preset: .xAI),
        "nagram.llmProviderCerebrasKey": .llm(preset: .cerebras),
        "nagram.llmProviderOllamaCloudKey": .llm(preset: .ollamaCloud),
        "nagram.llmProviderOpenRouterKey": .llm(preset: .openRouter),
        "nagram.llmProviderVercelAIGatewayKey": .llm(preset: .vercel),
        "nagram.llmProviderVertexKey": .llm(preset: .vertex)
    ]

    static func services(_ value: ClientSettingValue) throws -> [ServiceRecord] {
        guard case let .string(raw) = value,
              case let .array(values) = try CloudLegacyJSON.decodeValue(Data(raw.utf8)),
              values.count <= AIFeatures.maximumServices else { throw CloudLegacySkipReason.malformedServices }
        let allowed: Set<String> = ["id", "name", "url", "model", "key", "reasoningEnabled", "reasoningEffort"]
        var ids = Set<String>()
        return try values.map { value in
            guard case let .object(object) = value, Set(object.keys).isSubset(of: allowed),
                  case let .string(url)? = object["url"], case let .string(model)? = object["model"] else { throw CloudLegacySkipReason.malformedServices }
            func optionalString(_ key: String) throws -> String? {
                guard let value = object[key], value != .null else { return nil }
                guard case let .string(value) = value else { throw CloudLegacySkipReason.malformedServices }
                return value
            }
            let oldId = try optionalString("id")
            let id = oldId.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            try CloudCredentialID.assistant(serviceId: id).validate()
            guard ids.insert(id).inserted else { throw CloudLegacySkipReason.malformedServices }
            let name = try optionalString("name") ?? ""
            let key = try optionalString("key")
            var reasoning = 0
            if let value = object["reasoningEnabled"], value != .null {
                guard case let .bool(enabled) = value else { throw CloudLegacySkipReason.malformedServices }
                reasoning = enabled ? 2 : 0
            }
            if let value = object["reasoningEffort"], value != .null {
                guard case let .integer(effort) = value, Int32(exactly: effort) != nil else { throw CloudLegacySkipReason.malformedServices }
                reasoning = Int(max(0, min(3, effort))) // Service.getReasoningEffort clamps 0...3.
            }
            let normalized = try AIRequestBuilder.normalizedBaseURL(url).absoluteString
            try AIRequestBuilder.validateModel(model)
            guard name.utf8.count <= 256, model.utf8.count <= 256 else { throw CloudLegacySkipReason.malformedServices }
            if let key, !key.isEmpty { _ = try AICredentialBinding.validated(key, multiple: false) }
            // Original AiConfig Service is OpenAI-compatible, not an enum ID or a
            // guessed Vertex endpoint. Vertex belongs to the separate LLM preset.
            let service = AIService(id: id, name: name, url: normalized, model: model, reasoningEffort: reasoning, wireProtocol: .openAI)
            return ServiceRecord(service: service, legacyHash: AISettings.javaServiceHash(url: url, model: model, key: key), incomingKey: key)
        }
    }

    static func selected(_ records: [ServiceRecord], preferences: [String: ClientSettingValue]) throws -> String {
        if let value = preferences["selectedServiceId"], value != .null {
            guard case let .string(id) = value else { throw CloudLegacySkipReason.invalidValue }
            if records.contains(where: { $0.service.id == id }) { return id }
        }
        let hash: Int32
        if let value = preferences["selectedService"], value != .null {
            guard case let .integer(number) = value, let exact = Int32(exactly: number) else { throw CloudLegacySkipReason.invalidValue }
            hash = exact
        } else {
            hash = AISettings.javaServiceHash(url: AIService.default.url, model: AIService.default.model, key: nil)
        }
        return records.first(where: { $0.legacyHash == hash })?.service.id ?? records.first?.service.id ?? AIService.default.id
    }
}
