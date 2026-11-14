import Foundation

public enum AIFeatures {
    public static let definitions: [ClientSettingDefinition] = {
        let ai = "AI"
        let translation = "Translation"
        let speech = "Speech"
        func boolean(_ field: String, _ title: String, _ value: Bool, _ section: String = "AI", _ explanation: String? = nil) -> ClientSettingDefinition {
            .init(key: "ai." + field, title: title, section: section, defaultValue: .bool(value), explanation: explanation, androidSymbols: [field])
        }
        func string(_ field: String, _ title: String, _ section: String, _ value: String = "", secret: Bool = false, explanation: String? = nil) -> ClientSettingDefinition {
            .init(key: "ai." + field, title: title, section: section, defaultValue: .string(value), isSecret: secret, explanation: explanation, androidSymbols: [field])
        }
        var result: [ClientSettingDefinition] = [
            boolean("saveHistory", "Save assistant history", true, ai, "Private, account-scoped history. Used only for Assistant, not text editing or translation."),
            boolean("responseStreaming", "Stream responses", true),
            .init(key: "ai.temperature", title: "Temperature (tenths)", section: ai, defaultValue: .integer(10), minimum: 0, maximum: 20, step: 1, androidSymbols: ["AiConfig.getTemperature"]),
            boolean("showResponseOnly", "Show response only", false),
            boolean("insertAsQuote", "Insert assistant result as a quote", true),
            .init(key: "ai.replaceTelegramEditor", title: "Replace Telegram AI editor", section: ai, defaultValue: .null, options: [.init(value: .null, title: "Automatic (non-Premium accounts)"), .init(value: .bool(true), title: "Enabled"), .init(value: .bool(false), title: "Disabled")], explanation: "Automatic matches Android's !isPremium default. Requires a configured AI service.", androidSymbols: ["AiConfig.getReplaceTelegramEditor"]),
            .init(key: "ai.replaceTelegramSummaries", title: "Replace Telegram summaries", section: ai, defaultValue: .null, options: [.init(value: .null, title: "Automatic (non-Premium accounts)"), .init(value: .bool(true), title: "Enabled"), .init(value: .bool(false), title: "Disabled")], explanation: "Automatic matches Android's !isPremium default. Requires a configured AI service.", androidSymbols: ["AiConfig.getReplaceTelegramSummaries"]),
            .init(key: "ai.services", title: "Services", section: ai, defaultValue: .array([]), androidSymbols: ["AiConfig.KEY_SERVICES"]),
            string("selectedServiceId", "Selected service", ai, "default"),
            .init(key: "ai.roles", title: "Custom roles", section: ai, defaultValue: .string(""), isSecret: true, androidSymbols: ["AiConfig.KEY_ROLES"]),
            string("selectedRole", "Selected role", ai, "Assistant"),
            .init(key: "ai.translationProvider", title: "Translation provider", section: translation, defaultValue: .integer(1), options: AITranslationProvider.allCases.map { .init(value: .integer(Int64($0.rawValue)), title: $0.title) }, androidSymbols: ["NekoConfig.translationProvider"]),
            string("translateToLang", "Translate messages to", translation, explanation: "Language code. Empty uses the app language."),
            string("translateInputLang", "Translate drafts to", translation, "en"),
            boolean("showTranslate", "Show message translation", false, translation),
            boolean("showTextTranslate", "Show selected-text translation", true, translation),
            boolean("showTranslateMessageLLM", "Show separate LLM translation action", false, translation),
            .init(key: "ai.translatorMode", title: "Keep original with translation", section: translation, defaultValue: .integer(0), options: [.init(value: .integer(0), title: "Never"), .init(value: .integer(1), title: "Manual translations"), .init(value: .integer(2), title: "Manual and automatic")], androidSymbols: ["NaConfig.translatorMode", "MessageHelper.shouldKeepOriginalForDisplay"]),
            boolean("translatorModeWithOriginalMigrated", "Translation-mode migration completed", false, "AI state"),
            .init(key: "ai.translatorModeMigrationTarget", title: "Translation-mode migration journal", section: "AI state", defaultValue: .null),
            string("preferredTranslateTargetLang", "Preferred translation languages", translation, explanation: "Comma-separated language codes. Shown after the default language, in your order."),
            boolean("keepTranslatorPreferences", "Keep ignored languages on app-language change", false, translation),
            boolean("telegramUIAutoTranslate", "Enable automatic chat translation", true, translation),
            boolean("enableSeparateArticleTranslator", "Separate article translation provider", false, translation),
            .init(key: "ai.articleTranslationProvider", title: "Article translation provider", section: translation, defaultValue: .integer(1), options: AITranslationProvider.allCases.map { .init(value: .integer(Int64($0.rawValue)), title: $0.title) }, androidSymbols: ["NaConfig.articleTranslationProvider"]),
            boolean("translatorKeepMarkdown", "Preserve translation formatting", true, translation),
            boolean("googleTranslateExp", "Experimental Google translation", true, translation, "Uses your experimental API key when configured, otherwise the original Google app endpoint."),
            string("googleCloudTranslateKey", "Google Cloud Translate key", translation, secret: true),
            string("googleTranslateExperimentalKey", "Google experimental API key", translation, secret: true, explanation: "iOS adaptation: a user key replaces the Android built-in key."),
            string("lingoApiKey", "Lingo API token", translation, secret: true, explanation: "iOS adaptation: requires your Caiyun token. The bundled Android token is not reused."),
            string("deepLTranslateKey", "DeepL API key", translation, secret: true, explanation: "Free keys ending in :fx use api-free.deepl.com."),
            .init(key: "ai.deepLFormality", title: "DeepL formality", section: translation, defaultValue: .integer(0), options: [.init(value: .integer(0), title: "Default"), .init(value: .integer(1), title: "Informal"), .init(value: .integer(2), title: "Formal")], androidSymbols: ["NaConfig.deepLFormality"]),
            .init(key: "ai.llmProviderPreset", title: "LLM translation provider", section: translation, defaultValue: .integer(0), options: AILLMPreset.allCases.map { .init(value: .integer(Int64($0.rawValue)), title: $0.title) }, androidSymbols: ["NaConfig.llmProviderPreset"]),
            string("llmApiUrl", "Custom LLM base URL", translation),
            string("llmSystemPrompt", "Translation system prompt", translation, secret: true, explanation: "Empty uses the original embedded translation prompt."),
            string("llmUserPrompt", "Translation user prompt", translation, secret: true, explanation: "Optional template: @text and @toLang."),
            .init(key: "ai.llmTemperature", title: "Translation temperature", section: translation, defaultValue: .number(0.7), minimum: 0, maximum: 2, step: 0.1, androidSymbols: ["NaConfig.llmTemperature"]),
            boolean("llmUseContext", "Use supplied conversation context", false, translation),
            boolean("llmUseContextInAutoTranslate", "Use LLM context in automatic translation", false, translation),
            .init(key: "ai.llmContextSize", title: "Translation context messages", section: translation, defaultValue: .integer(2), options: [1, 3, 5, 7, 10].enumerated().map { .init(value: .integer(Int64($0.offset)), title: String($0.element)) }, androidSymbols: ["NaConfig.llmContextSize"]),
            .init(key: "ai.transcribeProvider", title: "Transcription provider", section: speech, defaultValue: .integer(0), options: AITranscriptionProvider.allCases.map { .init(value: .integer(Int64($0.rawValue)), title: $0.title) }, explanation: "Auto selects configured Gemini, OpenAI-compatible or Workers AI; otherwise Apple on-device Speech. Apple Speech requires a supported downloaded language and permission.", androidSymbols: ["NaConfig.transcribeProvider"]),
            string("transcribeProviderCfAccountID", "Cloudflare account ID", speech),
            string("transcribeProviderCfApiToken", "Cloudflare API token", speech, secret: true),
            string("transcribeProviderGeminiApiKey", "Gemini transcription key", speech, secret: true),
            string("transcribeProviderGeminiModel", "Gemini transcription model", speech, "gemini-3.5-flash", explanation: "iOS default from Provider.PRESETS; Android's resource-defined model is absent from the source snapshot."),
            string("transcribeProviderGeminiPrompt", "Gemini transcription prompt", speech, secret: true),
            string("transcribeProviderOpenAiApiBase", "Audio-compatible base URL", speech),
            string("transcribeProviderOpenAiModel", "Audio-compatible model", speech),
            string("transcribeProviderOpenAiApiKey", "Audio-compatible API key", speech, secret: true),
            string("transcribeProviderOpenAiPrompt", "Audio-compatible transcription prompt", speech, secret: true),
            string("OEVoskLanguage", "Speech language", speech, explanation: "iOS adaptation: Apple Speech locale, for example en-US. Empty uses the device language. No Vosk archive is downloaded."),
            string("speechVoiceIdentifier", "Speech voice", speech, explanation: "iOS AVSpeech voice identifier. Empty uses the selected language's default voice."),
            string("bingSession", "Private Bing session cache", "AI state", secret: true),
            .init(key: "ai.speechRate", title: "Speech rate", section: speech, defaultValue: .number(0.5), minimum: 0.1, maximum: 0.6, step: 0.05, explanation: "iOS AVSpeechUtterance rate; 0.5 is the system default.")
        ]
        for preset in AILLMPreset.allCases {
            result.append(.init(key: preset.keySetting, title: preset.title + " API key(s)", section: translation, defaultValue: .string(""), isSecret: true, explanation: "Comma-separated keys rotate between translation requests.", androidSymbols: ["NaConfig." + String(preset.keySetting.dropFirst(3))]))
            result.append(.init(key: preset.modelSetting, title: preset.title + " model", section: translation, defaultValue: .string(""), explanation: "Choose a model returned by the provider. No model ID is guessed.", androidSymbols: ["NaConfig." + String(preset.modelSetting.dropFirst(3))]))
        }
        return result + toolDefinitions
    }()

    /// Registered only when a native caller actually installs a tool handler.
    public static let toolDefinitions: [ClientSettingDefinition] = [
        .init(key: "ai.disableTools", title: "Disable AI tools", section: "AI", defaultValue: .bool(false), androidSymbols: ["AiConfig.getDisableTools"])
    ]
}
