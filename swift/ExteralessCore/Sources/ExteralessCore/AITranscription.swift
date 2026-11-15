import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AITranscriptionProvider: Int, CaseIterable, Sendable {
    case auto = 0, workersAI = 2, gemini = 3, openAI = 4, apple = 5
    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .workersAI: return "Cloudflare Workers AI"
        case .gemini: return "Gemini"
        case .openAI: return "OpenAI-compatible audio"
        case .apple: return "Apple on-device Speech (Vosk adaptation)"
        }
    }
}

public struct AIAudioData: Sendable {
    public enum Format: String, Sendable {
        case wav, mp3, m4a, ogg
        public var mimeType: String {
            switch self {
            case .wav: return "audio/wav"
            case .mp3: return "audio/mpeg"
            case .m4a: return "audio/mp4"
            case .ogg: return "audio/ogg"
            }
        }
    }
    public let data: Data
    public let format: Format

    public init(data: Data, format: Format) { self.data = data; self.format = format }

    public func validate() throws {
        guard !data.isEmpty, data.count <= AILimits.audioBytes else { throw AIError.inputTooLarge }
        let bytes = Array(data.prefix(12))
        let valid: Bool
        switch format {
        case .wav: valid = bytes.count >= 12 && Array(bytes[0 ..< 4]) == Array("RIFF".utf8) && Array(bytes[8 ..< 12]) == Array("WAVE".utf8)
        case .mp3: valid = bytes.starts(with: Array("ID3".utf8)) || (bytes.count >= 2 && bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0)
        case .m4a: valid = bytes.count >= 8 && Array(bytes[4 ..< 8]) == Array("ftyp".utf8)
        case .ogg: valid = bytes.starts(with: Array("OggS".utf8))
        }
        guard valid else { throw AIError.invalidAudio }
    }
}

public struct AITranscriptionConfiguration: Sendable {
    public var provider: AITranscriptionProvider
    public var cloudflareAccountId: String
    public var cloudflareToken: String
    public var geminiKey: String
    public var geminiModel: String
    public var geminiPrompt: String
    public var openAIBaseURL: String
    public var openAIModel: String
    public var openAIKey: String
    public var openAIPrompt: String

    public init(settings: AISettings = AISettings()) {
        let store = settings.store
        provider = AITranscriptionProvider(rawValue: store.integer("ai.transcribeProvider")) ?? .auto
        cloudflareAccountId = store.string("ai.transcribeProviderCfAccountID")
        cloudflareToken = store.string("ai.transcribeProviderCfApiToken")
        let key = store.string("ai.transcribeProviderGeminiApiKey")
        geminiKey = key.isEmpty ? store.string("ai.llmProviderGeminiKey").components(separatedBy: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : key
        geminiModel = store.string("ai.transcribeProviderGeminiModel", default: "gemini-3.5-flash")
        geminiPrompt = store.string("ai.transcribeProviderGeminiPrompt")
        openAIBaseURL = store.string("ai.transcribeProviderOpenAiApiBase")
        openAIModel = store.string("ai.transcribeProviderOpenAiModel")
        openAIKey = settings.openAITranscriptionAPIKey(baseURL: openAIBaseURL)
        openAIPrompt = store.string("ai.transcribeProviderOpenAiPrompt")
    }

    public var effectiveProvider: AITranscriptionProvider {
        if provider != .auto { return provider }
        if !geminiKey.isEmpty { return .gemini }
        if !openAIBaseURL.isEmpty && !openAIModel.isEmpty && !openAIKey.isEmpty { return .openAI }
        if !cloudflareAccountId.isEmpty && !cloudflareToken.isEmpty { return .workersAI }
        return .apple
    }
}

public enum AITranscriptionRequest {
    public static let defaultPrompt = """
    Your task is to create a detailed, verbatim transcription of the provided audio, formatted like closed captions for the hard of hearing. Follow these instructions strictly:

    1.  **Transcribe Speech:** Transcribe all spoken dialogue verbatim. Do NOT include speaker names or labels (like "Speaker 1:", "Person A:", etc.).
    2.  **Include Sounds:** Include relevant non-speech sounds, actions, and descriptions in square brackets `[]`.
    3.  **Format Sounds:** Place bracketed sound descriptions on their own line when they occur between dialogue segments, or inline within the dialogue when appropriate.
    4.  **Output Only:** Output ONLY the formatted transcription. Do not include any introductory text, explanations, or anything other than the transcription.

    **Example Output Format:**
    [footsteps approaching]
    Did you hear that?
    [distant siren wailing]
    Hear what? I didn't hear anything except that siren.
    No, before that. A kind of scraping sound. [chair creaks]
    [sighs] You're probably just imagining things again.
    [knocking on door]
    See! I told you!
    """

    public static func build(audio: AIAudioData, configuration config: AITranscriptionConfiguration) throws -> URLRequest {
        try audio.validate()
        switch config.effectiveProvider {
        case .workersAI:
            guard config.cloudflareAccountId.count == 32, config.cloudflareAccountId.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 70).contains($0) || (97 ... 102).contains($0) }) else { throw AIError.configuration }
            let key = try AIRequestBuilder.validatedKey(config.cloudflareToken)
            let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(config.cloudflareAccountId)/ai/run/@cf/openai/whisper-large-v3-turbo")!
            var request = try AIRequestBuilder.json(url: url, body: ["audio": audio.data.base64EncodedString()])
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            return request
        case .gemini:
            try AIRequestBuilder.validateModel(config.geminiModel)
            guard !config.geminiModel.contains("/") else { throw AIError.invalidModel }
            let key = try AIRequestBuilder.validatedKey(config.geminiKey)
            let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(config.geminiModel):generateContent")!
            let prompt = config.geminiPrompt.isEmpty ? defaultPrompt : config.geminiPrompt
            var request = try AIRequestBuilder.json(url: url, body: ["contents": [["parts": [["text": prompt], ["inlineData": ["mimeType": audio.format.mimeType, "data": audio.data.base64EncodedString()]]]]]])
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            return request
        case .openAI:
            // TranscribeHelper labelled every Android file "wav". iOS converts
            // actual samples to WAV first; never send an OGG/M4A under a WAV label.
            guard audio.format == .wav || audio.format == .mp3 else { throw AIError.invalidAudio }
            try AIRequestBuilder.validateModel(config.openAIModel)
            let base = try AIRequestBuilder.normalizedBaseURL(config.openAIBaseURL)
            let key = try AIRequestBuilder.validatedKey(config.openAIKey)
            let prompt = config.openAIPrompt.isEmpty ? defaultPrompt : config.openAIPrompt
            var body: [String: Any] = ["model": config.openAIModel, "messages": [["role": "user", "content": [["type": "text", "text": prompt], ["type": "input_audio", "input_audio": ["data": audio.data.base64EncodedString(), "format": audio.format.rawValue]]]]]]
            if config.openAIModel.lowercased().hasPrefix("gpt") { body["modalities"] = ["text"] }
            var request = try AIRequestBuilder.json(url: base.appendingPathComponent("chat/completions"), body: body)
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            return request
        case .auto, .apple: throw AIError.nativeServiceRequired
        }
    }

    public static func parse(_ data: Data, provider: AITranscriptionProvider) throws -> String {
        switch provider {
        case .workersAI:
            let json = try AIResponseParser.object(data)
            guard json["success"] as? Bool == true else { throw AIError.invalidResponse }
            guard let text = (json["result"] as? [String: Any])?["text"] as? String else { throw AIError.emptyResponse }
            return try AIResponseParser.validated(text: text, reasoning: "", finishReason: nil).text
        case .gemini: return try AIResponseParser.single(data, wireProtocol: .vertex).text
        case .openAI: return try AIResponseParser.single(data).text
        case .auto, .apple: throw AIError.nativeServiceRequired
        }
    }
}

public struct AISpeechHTTPClient: Sendable {
    private let transport: any AIHTTPTransport
    public init(transport: any AIHTTPTransport = AIURLSessionTransport()) { self.transport = transport }

    public func transcribe(audio: AIAudioData, configuration: AITranscriptionConfiguration) async throws -> String {
        try Task.checkCancellation()
        let request = try AITranscriptionRequest.build(audio: audio, configuration: configuration)
        let data = try await transport.data(for: request)
        try Task.checkCancellation()
        return try AITranscriptionRequest.parse(data, provider: configuration.effectiveProvider)
    }
}

public enum AIWaveFile {
    /// PCM output from Telegram's SoftwareAudioSource is signed 16-bit mono LE.
    public static func encode(pcm: Data, sampleRate: UInt32) throws -> AIAudioData {
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count + 44 <= AILimits.audioBytes,
              (8_000 ... 192_000).contains(sampleRate) else { throw AIError.invalidAudio }
        var data = Data()
        func word(_ value: UInt32, count: Int) {
            for shift in 0 ..< count { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
        }
        data.append(contentsOf: "RIFF".utf8)
        word(UInt32(pcm.count) + 36, count: 4)
        data.append(contentsOf: "WAVEfmt ".utf8)
        word(16, count: 4)
        word(1, count: 2)
        word(1, count: 2)
        word(sampleRate, count: 4)
        word(sampleRate * 2, count: 4)
        word(2, count: 2)
        word(16, count: 2)
        data.append(contentsOf: "data".utf8)
        word(UInt32(pcm.count), count: 4)
        data.append(pcm)
        return AIAudioData(data: data, format: .wav)
    }
}
