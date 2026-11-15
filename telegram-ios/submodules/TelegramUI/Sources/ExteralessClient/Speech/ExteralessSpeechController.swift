import AccountContext
import AVFoundation
import Display
import ExteralessCore
import Foundation
import Speech
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ExteralessSpeechController: PluginListController, UIDocumentPickerDelegate {
    private let integration: ExteralessAIIntegration
    private var previewText = "Hello! This is the selected speech voice."
    private var picking = false

    init(context: AccountContext, integration: ExteralessAIIntegration) {
        self.integration = integration
        super.init(context: context)
        allowsRefresh = false
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func render() {
        title = "Speech and Transcription"
        let settings = integration.settings
        do { try AISettingsRecovery(settings: settings).prepare(accountId: integration.accountId(context)) }
        catch {
            setSections([PluginListSection(rows: [PluginListRow(id: "speech-settings-error", title: "Speech settings unavailable", detail: "Return and retry after secure storage is available.")])])
            return
        }
        let config = AITranscriptionConfiguration(settings: settings)
        var sections = operationSections()
        let fileProvider: AITranscriptionProvider
        if case let .provider(provider) = AINativeSpeechPolicy.route(configuration: config, isPremium: false) { fileProvider = provider }
        else { fileProvider = config.provider }
        var file = PluginListRow(id: "audio", title: "Transcribe an audio or video file", detail: "Selected provider: " + fileProvider.title)
        file.style = .accent
        file.enabled = !picking
        file.action = { [weak self] in self?.pickFile() }
        sections.append(PluginListSection(footer: "Apple: on-device recognition, supported language and Speech permission, up to 60 s. Cloud: user credentials, up to 180 s and 20 MiB decoded WAV. OGG/Opus, audio and video are decoded using Telegram's media decoder; local processing is limited to 30 s.", rows: [file]))
        let providers = AITranscriptionProvider.allCases.map { provider -> PluginListRow in
            var row = PluginListRow(id: "provider.\(provider.rawValue)", title: provider.title)
            row.accessory = config.provider == provider ? .checkmark : .none
            row.action = { [weak self] in
                self?.perform(title: "Selecting provider…", operation: { try await ExteralessAIPersistence.run { try settings.store.set(.integer(Int64(provider.rawValue)), for: "ai.transcribeProvider") } }, completion: { _ in })
            }
            return row
        }
        sections.append(PluginListSection(title: "Transcription", footer: "For voice messages, Auto uses Telegram on Premium accounts; otherwise Gemini, configured compatible audio, then Workers AI. Explicit providers also apply to the inline transcription button.", rows: providers))
        let keys: [(String, String, Bool)]
        switch fileProvider {
        case .workersAI: keys = [("ai.transcribeProviderCfAccountID", "Cloudflare account ID", false), ("ai.transcribeProviderCfApiToken", "Cloudflare API token", true)]
        case .gemini: keys = [("ai.transcribeProviderGeminiApiKey", "Gemini API key", true), ("ai.transcribeProviderGeminiModel", "Gemini audio model", false), ("ai.transcribeProviderGeminiPrompt", "Transcription prompt", false)]
        case .openAI: keys = [("ai.transcribeProviderOpenAiApiBase", "Audio-compatible base URL", false), ("ai.transcribeProviderOpenAiModel", "Audio-compatible model", false), ("ai.transcribeProviderOpenAiApiKey", "API key", true), ("ai.transcribeProviderOpenAiPrompt", "Transcription prompt", false)]
        case .auto, .apple: keys = []
        }
        if !keys.isEmpty { sections.append(PluginListSection(title: "Credentials and request", rows: keys.map { settingRow($0.0, title: $0.1, secret: $0.2, audioBaseURL: config.openAIBaseURL) })) }
        var language = settingRow("ai.OEVoskLanguage", title: "Speech language (BCP-47)", secret: false)
        let storedLanguage = settings.store.string("ai.OEVoskLanguage")
        let locale = storedLanguage.isEmpty ? Locale.current.identifier : storedLanguage
        let available = SFSpeechRecognizer(locale: Locale(identifier: locale))?.supportsOnDeviceRecognition == true
        language.detail = locale + (available ? " · on-device support" : " · on-device support unavailable")
        var voices = PluginListRow(id: "voices", title: "Choose speech voice", detail: settings.store.string("ai.speechVoiceIdentifier").isEmpty ? "Default for language" : AVSpeechSynthesisVoice(identifier: settings.store.string("ai.speechVoiceIdentifier"))?.name ?? "Voice not installed")
        voices.accessory = .disclosure
        voices.action = { [weak self] in
            guard let self else { return }
            self.push(ExteralessSpeechVoicesController(context: self.context, integration: self.integration))
        }
        let preview = exteralessAIInputRow(id: "preview", title: "Preview text", text: previewText, multiline: true, updated: { [weak self] in self?.previewText = $0 })
        var speak = PluginListRow(id: "speak", title: "Read preview aloud")
        speak.action = { [weak self] in
            guard let self else { return }
            self.view.endEditing(true)
            ExteralessAIEntry.speak?(self.context, self, .init(text: self.previewText))
        }
        sections.append(PluginListSection(title: "Native speech", footer: "Installed Apple voices are used. A voice/language may need to be downloaded in iOS Settings. No Vosk model archive is installed by this adaptation.", rows: [language, voices, preview, speak]))
        setSections(sections)
    }

    private func settingRow(_ key: String, title: String, secret: Bool, audioBaseURL: String? = nil) -> PluginListRow {
        let settings = integration.settings
        let store = integration.settings.store
        let displayedAudioURL = audioBaseURL ?? store.string("ai.transcribeProviderOpenAiApiBase")
        let displayedValue = key == "ai.transcribeProviderOpenAiApiBase" ? displayedAudioURL : store.string(key)
        let secretValue = key == "ai.transcribeProviderOpenAiApiKey" ? settings.openAITranscriptionAPIKey(baseURL: displayedAudioURL) : displayedValue
        let prompt = key.hasSuffix("Prompt")
        var row = PluginListRow(id: key, title: title, detail: secret ? (secretValue.isEmpty ? "Not set" : "Stored securely") : (prompt ? (displayedValue.isEmpty ? "Original default" : "Custom") : displayedValue))
        row.accessory = .disclosure
        row.action = { [weak self] in
            guard let self else { return }
            if secret {
                exteralessAIEditSecret(from: self, title: title, save: { [weak self] value in
                    self?.perform(title: "Saving credential…", operation: {
                        try await ExteralessAIPersistence.run {
                            if key == "ai.transcribeProviderOpenAiApiKey" {
                                try settings.saveOpenAITranscription(baseURL: displayedAudioURL, credential: value.isEmpty ? .remove : .replace(value), authorizeDestinationChange: true)
                            } else { try store.set(.string(value), for: key) }
                        }
                    }, completion: { _ in })
                })
            } else {
                self.push(ExteralessAITextSettingController(context: self.context, title: title, text: displayedValue, multiline: prompt, save: { value in
                    try await ExteralessAIPersistence.run {
                        if key == "ai.transcribeProviderOpenAiApiBase" {
                            try settings.saveOpenAITranscription(baseURL: value, credential: .unchanged, authorizeDestinationChange: true)
                        } else { try store.set(.string(value), for: key) }
                    }
                }))
            }
        }
        return row
    }

    private func pickFile() {
        guard !picking else { return }
        picking = true
        view.endEditing(true)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio, .movie], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        present(picker, animated: true)
        render()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { picking = false; render() }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        picking = false
        render()
        guard let url = urls.first else { return }
        // The picker owns its dismissal. Pushing on the next main-queue turn
        // avoids presenting a result while UIKit is invoking this delegate.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.integration.presentAudio(context: self.context, from: self, url: url)
        }
    }
}

@MainActor
private final class ExteralessSpeechVoicesController: PluginListController {
    private let integration: ExteralessAIIntegration
    init(context: AccountContext, integration: ExteralessAIIntegration) { self.integration = integration; super.init(context: context) }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func render() {
        title = "Speech Voices"
        let store = integration.settings.store
        let selected = store.string("ai.speechVoiceIdentifier")
        let voices = AVSpeechSynthesisVoice.speechVoices().sorted { $0.language == $1.language ? $0.name < $1.name : $0.language < $1.language }
        var rows = [voiceRow(id: "", name: "Default for selected language", language: "", selected: selected)]
        rows += voices.map { voiceRow(id: $0.identifier, name: $0.name, language: $0.language, selected: selected) }
        setSections(operationSections() + [PluginListSection(footer: "Only voices reported by AVSpeechSynthesisVoice are shown.", rows: rows)])
    }
    private func voiceRow(id: String, name: String, language: String, selected: String) -> PluginListRow {
        let store = integration.settings.store
        var row = PluginListRow(id: id, title: name, detail: language)
        row.accessory = selected == id ? .checkmark : .none
        row.action = { [weak self] in
            self?.perform(title: "Selecting voice…", operation: { try await ExteralessAIPersistence.run { try store.set(.string(id), for: "ai.speechVoiceIdentifier") } }, completion: { [weak self] _ in self?.dismiss(animated: true) })
        }
        return row
    }
}
