import Foundation

/// Wire contracts are from app/exteraless/ai and nekogram/llm, not provider SDKs.
public enum AIWireProtocol: String, Codable, Sendable {
    case openAI
    case vertex
}

public struct AIProviderPreset: Equatable, Sendable {
    public let id: String
    public let title: String
    public let baseURL: String
    public let defaultModel: String
    public let keyURL: String?
    public let wireProtocol: AIWireProtocol

    public static let assistant: [AIProviderPreset] = [
        .init(id: "gemini", title: "Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", defaultModel: "gemini-3.5-flash", keyURL: "https://aistudio.google.com/apikey", wireProtocol: .openAI),
        .init(id: "openai", title: "OpenAI", baseURL: "https://api.openai.com/v1", defaultModel: "gpt-5-mini", keyURL: "https://platform.openai.com/api-keys", wireProtocol: .openAI),
        .init(id: "openrouter", title: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", defaultModel: "openai/gpt-5-mini", keyURL: "https://openrouter.ai/keys", wireProtocol: .openAI),
        .init(id: "deepseek", title: "DeepSeek", baseURL: "https://api.deepseek.com/v1", defaultModel: "deepseek-chat", keyURL: "https://platform.deepseek.com/api_keys", wireProtocol: .openAI)
    ]
}

public enum AILLMPreset: Int, CaseIterable, Codable, Sendable {
    case custom = 0, openAI, gemini, groq, deepSeek, xAI, cerebras, ollamaCloud, openRouter, vercel, vertex

    public var title: String {
        switch self {
        case .custom: return "Custom (OpenAI compatible)"
        case .openAI: return "OpenAI"
        case .gemini: return "Google AI Studio"
        case .groq: return "Groq"
        case .deepSeek: return "DeepSeek"
        case .xAI: return "xAI"
        case .cerebras: return "Cerebras"
        case .ollamaCloud: return "Ollama Cloud"
        case .openRouter: return "OpenRouter"
        case .vercel: return "Vercel AI Gateway"
        case .vertex: return "Google Agent Platform (Vertex)"
        }
    }

    public var baseURL: String {
        switch self {
        case .custom: return ""
        case .openAI: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .groq: return "https://api.groq.com/openai/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .xAI: return "https://api.x.ai/v1"
        case .cerebras: return "https://api.cerebras.ai/v1"
        case .ollamaCloud: return "https://ollama.com/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .vercel: return "https://ai-gateway.vercel.sh/v1"
        case .vertex: return "https://aiplatform.googleapis.com/v1"
        }
    }

    private var field: String {
        switch self {
        case .custom: return ""
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .groq: return "Groq"
        case .deepSeek: return "DeepSeek"
        case .xAI: return "XAI"
        case .cerebras: return "Cerebras"
        case .ollamaCloud: return "OllamaCloud"
        case .openRouter: return "OpenRouter"
        case .vercel: return "VercelAIGateway"
        case .vertex: return "Vertex"
        }
    }

    public var keySetting: String { self == .custom ? "ai.llmApiKey" : "ai.llmProvider\(field)Key" }
    public var modelSetting: String { self == .custom ? "ai.llmModelName" : "ai.llmProvider\(field)Model" }

    // The source snapshot does not contain Android's LlmProvider*Model string
    // resources. Never guess their contents. The model picker discovers IDs.
    public var defaultModel: String { self == .vertex ? Self.vertexModels[0] : "" }

    public static let vertexModels = [
        "gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-2.5-flash-lite",
        "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.5-flash", "gemini-2.5-flash"
    ]
}

/// Credentials deliberately are not part of the Codable service record.
public struct AIService: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var url: String
    public var model: String
    public var reasoningEffort: Int
    public var wireProtocol: AIWireProtocol

    public init(id: String = UUID().uuidString, name: String = "", url: String, model: String, reasoningEffort: Int = 0, wireProtocol: AIWireProtocol = .openAI) {
        self.id = id
        self.name = name
        self.url = url
        self.model = model
        self.reasoningEffort = max(0, min(3, reasoningEffort))
        self.wireProtocol = wireProtocol
    }

    public init(preset: AIProviderPreset) {
        self.init(name: preset.title, url: preset.baseURL, model: preset.defaultModel, wireProtocol: preset.wireProtocol)
    }

    public static var `default`: AIService {
        var service = AIService(preset: AIProviderPreset.assistant[0])
        service.id = "default"
        return service
    }

    public var displayName: String {
        if !name.isEmpty { return name }
        return AIProviderPreset.assistant.first { $0.baseURL.lowercased() == url.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() }?.title ?? model
    }

    public var keySetting: String { "ai.serviceKey.\(id)" }
}

public struct AIRole: Codable, Equatable, Sendable {
    public var name: String
    public var prompt: String

    public init(name: String, prompt: String) {
        self.name = name
        self.prompt = prompt
    }

    public static let suggestions: [AIRole] = [
        .init(name: "Assistant", prompt: "You are a helpful personal assistant inside a chat app.\nAdapt to the user's tone, language, and context. Keep answers practical, concise, and easy to act on.\nAsk a clarifying question only when the request is ambiguous enough that answering directly would likely be wrong."),
        .init(name: "Summarizer", prompt: "Summarize the provided message or conversation without replying to it.\nPreserve the important facts, decisions, requests, names, dates, and next steps. Omit filler and repeated details.\nKeep the summary under 3 short sentences and under 60 words."),
        .init(name: "Proofreader", prompt: "Proofread and improve the user's text while preserving its meaning, language, and intent.\nFix grammar, spelling, punctuation, awkward phrasing, and clarity issues. Keep the original tone unless a cleaner wording is clearly better.\nReturn only the revised text unless the user explicitly asks for explanations.")
    ]
}

public struct AIMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public var role: Role
    public var content: String
    public var image: Data?
    public var imageMIMEType: String?

    public init(role: Role, content: String, image: Data? = nil, imageMIMEType: String? = nil) {
        self.role = role
        self.content = content
        self.image = image
        self.imageMIMEType = imageMIMEType
    }
}

public struct AIImageAttachment: Sendable, Equatable {
    public let id: UUID
    public let data: Data
    public let mimeType: String
    public init(id: UUID = UUID(), data: Data, mimeType: String) {
        self.id = id; self.data = data; self.mimeType = mimeType
    }
}

public enum AILimits {
    public static let responseUTF16 = 16_384
    public static let historyMessages = 32
    public static let historyUTF16 = 24_000
    public static let inputUTF16 = 64_000
    public static let imageBytes = 4 * 1024 * 1024
    public static let imageSide = 2048
    public static let audioBytes = 20 * 1024 * 1024
    public static let toolRounds = 24
    public static let toolCallsPerRound = 32
    public static let eventBytes = 256 * 1024
    public static let responseBytes = 4 * 1024 * 1024
    public static let requestTimeout: TimeInterval = 30
    public static let resourceTimeout: TimeInterval = 300

    public static func trimHistory(_ history: [AIMessage]) -> [AIMessage] {
        var output: [AIMessage] = []
        var length = 0
        for message in history.reversed() where message.role != .system && !message.content.isEmpty {
            let size = message.content.utf16.count
            if output.count >= historyMessages || length + size > historyUTF16 { break }
            length += size
            output.insert(AIMessage(role: message.role, content: message.content), at: 0)
        }
        while output.first?.role == .assistant { output.removeFirst() }
        return output
    }
}

/// No associated string is taken from a server, URLSession error, prompt or key.
public enum AIError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case configuration, missingKey, invalidURL, invalidKey, invalidModel
    case cancelled, timeout, network, invalidResponse, emptyResponse, incompleteStream
    case responseTooLarge, inputTooLarge, invalidAudio, unsupportedLanguage, formattingLost
    case http(Int), blocked, unsupportedTools, toolLimit, toolFailed, nativeServiceRequired

    public var errorDescription: String? { description }
    public var description: String {
        switch self {
        case .configuration: return "Configure the provider, endpoint and model in AI settings."
        case .missingKey: return "This provider requires your API key in AI settings."
        case .invalidURL: return "Use an HTTPS base URL without credentials, query parameters or a fragment."
        case .invalidKey: return "The API key contains invalid characters."
        case .invalidModel: return "Select or enter a valid model ID supplied by this provider."
        case .cancelled: return "Cancelled."
        case .timeout: return "The request timed out. Try again."
        case .network: return "The provider could not be reached. Check your connection."
        case .invalidResponse: return "The provider returned an invalid response."
        case .emptyResponse: return "The provider returned no text."
        case .incompleteStream: return "The connection ended before the response was complete."
        case .responseTooLarge: return "The response exceeded the local size limit. The displayed text is incomplete."
        case .inputTooLarge: return "The selected text or attachment exceeds the local size limit."
        case .invalidAudio: return "This audio format cannot be decoded. Choose a supported audio file."
        case .unsupportedLanguage: return "This provider does not support the selected language."
        case .formattingLost: return "The provider changed protected formatting or links. The original text was preserved."
        case let .http(code):
            switch code {
            case 401, 403: return "The provider rejected the API credentials (HTTP \(code))."
            case 429: return "The provider's rate or quota limit was reached (HTTP 429)."
            default: return "The provider request failed (HTTP \(code))."
            }
        case .blocked: return "The provider did not return this response."
        case .unsupportedTools: return "The model requested a tool that is not available for this action."
        case .toolLimit: return "The tool-call limit was reached without a final answer."
        case .toolFailed: return "The requested tool could not complete."
        case .nativeServiceRequired: return "This action requires the native service described in its settings."
        }
    }

    public static func sanitized(_ error: Error) -> AIError {
        if let error = error as? AIError { return error }
        if error is CancellationError { return .cancelled }
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            if error.code == NSURLErrorCancelled { return .cancelled }
            if error.code == NSURLErrorTimedOut { return .timeout }
        }
        return .network
    }
}

public struct AIResponse: Equatable, Sendable {
    public let text: String
    public let reasoning: String
    public let finishReason: String?

    public init(text: String, reasoning: String = "", finishReason: String? = nil) {
        self.text = text
        self.reasoning = reasoning
        self.finishReason = finishReason
    }
}

public enum AIGenerationEvent: Equatable, Sendable {
    case text(String)
    case replaceText(String)
    case reasoning(String)
    case thinking
    case tool(String)
}

public struct AIModelInfo: Equatable, Sendable {
    public let id: String
    public let name: String
    public let reasoning: Bool
    public let context: Int
}
