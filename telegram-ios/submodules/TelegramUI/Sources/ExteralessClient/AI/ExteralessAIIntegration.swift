import AccountContext
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import TextFormat
import TranslateUI
import UIKit

/// All fields describe an explicit selection. No ambient chat/history singleton
/// is read by the AI client. applyResult edits a draft; it must never send it.
public struct ExteralessAITextInput {
    public let text: String
    public let entities: [MessageTextEntity]
    public let selectedRange: NSRange?
    public let messageId: EngineMessage.Id?
    public let chatId: EnginePeer.Id?
    public let contextMessageIds: [EngineMessage.Id]
    public let image: AIImageAttachment?
    public let capability: ExteralessAIProcessingCapability
    public let wholeMessage: Bool
    public let automaticLanguage: String?
    public let isSummarized: Bool
    public let applyResult: ((ExteralessAIInsertion) -> Bool)?

    public init(text: String, entities: [MessageTextEntity] = [], selectedRange: NSRange? = nil, messageId: EngineMessage.Id? = nil, chatId: EnginePeer.Id? = nil, contextMessageIds: [EngineMessage.Id] = [], image: AIImageAttachment? = nil, capability: ExteralessAIProcessingCapability? = nil, wholeMessage: Bool = false, automaticLanguage: String? = nil, isSummarized: Bool = false, applyResult: ((ExteralessAIInsertion) -> Bool)? = nil) {
        self.text = text
        self.entities = entities
        self.selectedRange = selectedRange
        self.messageId = messageId
        self.chatId = chatId ?? messageId?.peerId
        self.contextMessageIds = contextMessageIds
        self.image = image
        self.capability = capability ?? ExteralessAIProcessingCapability(messageId: messageId, peerId: chatId, allowsExternalProcessing: true, allowsCopy: true)
        self.wholeMessage = wholeMessage
        self.automaticLanguage = automaticLanguage
        self.isSummarized = isSummarized
        self.applyResult = applyResult
    }
}

public struct ExteralessAIInsertion {
    public let text: String
    public let entities: [MessageTextEntity]
    public let asQuote: Bool

    /// Use ChatTextInputState.replacingFlatRange with this new fragment. Do not
    /// rebuild the user's complete document from its derived inputText view.
    public func attributedText() -> NSAttributedString {
        let value = NSMutableAttributedString(attributedString: chatInputStateStringWithAppliedEntities(text, entities: entities))
        if asQuote && value.length > 0 {
            value.addAttribute(ChatTextInputAttributes.block, value: ChatTextInputTextQuoteAttribute(kind: .quote, isCollapsed: false), range: NSRange(location: 0, length: value.length))
        }
        // Keep the original markdown source when there are no explicit entities.
        // Telegram's normal composer/send parser handles it without flattening
        // headings, tables or code fences in an existing document.
        return value
    }
}

/// Coordinator-owned chat callsites call these closures with their real context
/// and presenter. They are installed/removed by application composition below.
@MainActor
public enum ExteralessAIEntry {
    public static var textActions: ((AccountContext, ViewController, ExteralessAITextInput) -> Void)?
    public static var translate: ((AccountContext, ViewController, ExteralessAITextInput) -> Void)?
    public static var transcribe: ((AccountContext, ViewController, EngineMessage.Id, TelegramMediaFile) -> Void)?
    public static var speak: ((AccountContext, ViewController, ExteralessAITextInput) -> Void)?
    public static var reviewPlugin: ((AccountContext, ViewController, String) -> Void)?
    public static var translateMessage: ((AccountContext, ViewController, EngineMessage, String?, Bool) -> Void)?
    public static var translateWithLLM: ((AccountContext, ViewController, ExteralessAITextInput) -> Void)?
    fileprivate static var owner: UUID?
}

@MainActor
public final class ExteralessAIIntegration {
    let settings = AISettings()
    private let transport: any AIHTTPTransport
    private lazy var bingCache = AIBingSessionCache(transport: transport, store: settings.store)
    lazy var client = AIClient(transport: transport)
    lazy var translator = AITranslationClient(transport: transport, settings: settings, bingCache: bingCache)
    let speech: ExteralessSpeechService
    var reviewSource: any AIPluginReviewSource = ExteralessInstalledPluginReviewSource()
    let reviewCache = AIPluginReviewCache()
    var catalog: [String: AIModelInfo] = [:]
    private var tools: AIToolHandler?
    private var lastResult: (content: ExteralessAIResultContent, scope: ExteralessAIScope?)?
    private let id = UUID()
    private var context: AccountContext?
    private var screens: [WeakAIResultController] = []
    private lazy var recovery = AISettingsRecovery(settings: settings)
    public private(set) lazy var nativeAdapter = ExteralessAINativeAdapter(integration: self)
    private var observation: ClientSettingsObservation?
    private var nativeSettingsDisposable: Disposable?
    private var presentationDisposable: Disposable?
    private let translationWrite = MetaDisposable()
    private var nativeTranslationSettings: TranslationSettings?
    private var pendingShowTranslate: Bool?
    private var lastLanguage: String?

    public init(transport: any AIHTTPTransport = AIURLSessionTransport()) {
        self.transport = transport
        self.speech = ExteralessSpeechService(transport: transport)
        try? settings.store.register(AINativeVisibilityPolicy.definitions)
        try? recovery.prepare()
        ExteralessSettingsUI.registerActions([
            ExteralessSettingsAction(id: "ai.services", title: "AI Providers and Models", section: "AI", action: { [weak self] context, presenter in
                guard let self else { return }
                presenter.push(ExteralessAIProvidersController(context: context, integration: self))
            }),
            ExteralessSettingsAction(id: "ai.roles", title: "AI Roles and System Prompts", section: "AI", action: { [weak self] context, presenter in
                guard let self else { return }
                presenter.push(ExteralessAIRolesController(context: context, integration: self))
            }),
            ExteralessSettingsAction(id: "ai.editor", title: "AI Text Editor", section: "AI", action: { [weak self] context, presenter in
                guard let self else { return }
                presenter.push(ExteralessAIEditorController(context: context, integration: self))
            }),
            ExteralessSettingsAction(id: "ai.result", title: "Latest AI Result", section: "AI", action: { [weak self] context, presenter in
                guard let self, self.context === context else { return }
                guard let result = self.lastResult else {
                    exteralessAIShowError(from: presenter, text: "Run a text or transcription action to see its result here.")
                    return
                }
                let access = ExteralessAIResultAccess(integration: self, context: context, capability: result.scope?.capability ?? .userInput, previousScope: result.scope)
                let screen = ExteralessAIResultController(context: context, title: "Latest AI Result", source: "", sourceEntities: [], settings: self.settings, speech: self.speech, asQuote: false, applyResult: nil, access: access, operation: { event in
                    _ = try await access.resolve()
                    try await access.validate()
                    await event(.text(result.content.text.text))
                    return result.content
                })
                self.presentResult(screen, from: presenter)
            }),
            ExteralessSettingsAction(id: "ai.translationModels", title: "LLM Translation Models and Prompts", section: "Translation", action: { [weak self] context, presenter in
                guard let self else { return }
                presenter.push(ExteralessAILLMController(context: context, integration: self))
            }),
            ExteralessSettingsAction(id: "ai.translationLanguages", title: "Translation Languages and Favorites", section: "Translation", action: { [weak self] context, presenter in
                guard let self else { return }
                let store = self.settings.store
                let language = context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode }
                presenter.push(ExteralessAILanguagePicker(context: context, integration: self, current: store.string("ai.translateToLang", default: language), defaultLanguage: language, selected: { value in
                    try await ExteralessAIPersistence.run { try store.set(.string(value), for: "ai.translateToLang") }
                }))
            }),
            ExteralessSettingsAction(id: "ai.speech", title: "Speech Voices and Audio Transcription", section: "Speech", action: { [weak self] context, presenter in
                guard let self else { return }
                presenter.push(ExteralessSpeechController(context: context, integration: self))
            }),
            ExteralessSettingsAction(id: "ai.pluginReview", title: "Review a Plugin with AI", section: "AI", action: { [weak self] context, presenter in
                guard let self else { return }
                presenter.push(ExteralessAIPluginReviewController(context: context, integration: self))
            })
        ])
        observation = settings.store.observe { [weak self] keys in
            guard keys.contains("ai.saveHistory") || keys.contains("ai.showTranslate") || keys.contains("ai.telegramUIAutoTranslate") || keys.contains("ai.translationProvider") else { return }
            Task { @MainActor [weak self] in
                guard let self, let context = self.context else { return }
                if keys.contains("ai.showTranslate") { self.applyShowTranslate(context: context) }
                if keys.contains("ai.telegramUIAutoTranslate") || keys.contains("ai.translationProvider") { self.nativeAdapter.cancelAutomaticTranslations() }
                guard keys.contains("ai.saveHistory"), !self.settings.store.bool("ai.saveHistory", default: true) else { return }
                let settings = self.settings
                let account = self.accountId(context)
                try? await ExteralessAIPersistence.run { try settings.clearHistory(accountId: account) }
            }
        }
    }

    public func update(context: AccountContext) {
        try? recovery.prepare(accountId: accountId(context))
        if self.context === context { return }
        clearContext()
        self.context = context
        lastLanguage = context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode }
        nativeSettingsDisposable = (context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.translationSettings]) |> deliverOnMainQueue).start(next: { [weak self] entries in
            guard let self, self.context === context else { return }
            let native = entries.entries[ApplicationSpecificSharedDataKeys.translationSettings]?.get(TranslationSettings.self) ?? .defaultSettings
            let first = self.nativeTranslationSettings == nil
            self.nativeTranslationSettings = native
            if let pending = self.pendingShowTranslate {
                if pending != native.showTranslate { return }
                self.pendingShowTranslate = nil
            }
            if first && self.settings.store.readSnapshot().storedKeys.contains("ai.showTranslate") {
                self.applyShowTranslate(context: context)
            } else if self.settings.store.bool("ai.showTranslate") != native.showTranslate {
                let store = self.settings.store
                Task { try? await ExteralessAIPersistence.run { try store.set(.bool(native.showTranslate), for: "ai.showTranslate") } }
            }
        })
        presentationDisposable = (context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self, self.context === context else { return }
            let language = data.strings.baseLanguageCode
            defer { self.lastLanguage = language }
            guard let previous = self.lastLanguage, previous != language else { return }
            let policy = AITranslationPolicy(store: self.settings.store)
            guard !policy.keepPreferences else { return }
            let fallback = Array(effectiveIgnoredTranslationLanguages(context: context, ignoredLanguages: nil))
            self.translationWrite.set(updateTranslationSettingsInteractively(accountManager: context.sharedContext.accountManager, { current in
                current.withUpdatedIgnoredLanguages(policy.ignoredLanguagesAfterAppLanguageChange(current: current.ignoredLanguages ?? fallback, previous: previous, next: language))
            }).start())
        })
        ExteralessAIEntry.owner = id
        ExteralessAIEntry.textActions = { [weak self] context, presenter, input in self?.presentActions(context: context, from: presenter, input: input) }
        ExteralessAIEntry.translate = { [weak self] context, presenter, input in self?.presentTranslation(context: context, from: presenter, input: input) }
        ExteralessAIEntry.transcribe = { [weak self] context, presenter, messageId, file in self?.presentMessageTranscription(context: context, from: presenter, messageId: messageId, file: file) }
        ExteralessAIEntry.speak = { [weak self] context, presenter, input in
            guard let self, self.context === context else { return }
            self.presentSpeech(context: context, from: presenter, input: input)
        }
        ExteralessAIEntry.reviewPlugin = { [weak self] context, presenter, id in self?.presentPluginReview(context: context, from: presenter, pluginId: id) }
        ExteralessAIEntry.translateMessage = { [weak self] context, presenter, message, automaticLanguage, isSummarized in self?.presentMessageTranslation(context: context, from: presenter, message: message, automaticLanguage: automaticLanguage, isSummarized: isSummarized) }
        ExteralessAIEntry.translateWithLLM = { [weak self] context, presenter, input in
            guard let self else { return }
            self.presentTranslation(context: context, from: presenter, input: self.wholeMessageInput(input, presenter: presenter), provider: .llm)
        }
    }

    public func clearContext() {
        nativeAdapter.cancelAll()
        let cache = reviewCache
        Task { await cache.clear() }
        nativeSettingsDisposable?.dispose()
        nativeSettingsDisposable = nil
        presentationDisposable?.dispose()
        presentationDisposable = nil
        translationWrite.set(nil)
        nativeTranslationSettings = nil
        pendingShowTranslate = nil
        lastLanguage = nil
        for screen in screens { screen.value?.invalidate() }
        screens = []
        speech.cancelAll()
        tools = nil
        lastResult = nil
        context = nil
        if ExteralessAIEntry.owner == id {
            ExteralessAIEntry.textActions = nil
            ExteralessAIEntry.translate = nil
            ExteralessAIEntry.transcribe = nil
            ExteralessAIEntry.speak = nil
            ExteralessAIEntry.reviewPlugin = nil
            ExteralessAIEntry.translateMessage = nil
            ExteralessAIEntry.translateWithLLM = nil
            ExteralessAIEntry.owner = nil
        }
    }

    func accountId(_ context: AccountContext) -> String { String(context.account.id.int64) }
    func owns(_ context: AccountContext) -> Bool { self.context === context }

    func resolveScope(context: AccountContext, capability: ExteralessAIProcessingCapability, purpose: AITranslationPurpose = .manual, configuration: AITranslationConfiguration? = nil, contextMessageIds: [EngineMessage.Id] = [], lease: AINativeOperationLease) async throws -> ExteralessAIScope {
        guard owns(context), !lease.isCancelled else { throw AIError.cancelled }
        let useContext = configuration?.llmUseContext == true
        let limit = useContext ? AINativeContextPolicy.visitLimit(messageLimit: configuration?.llmContextMessages ?? 0) : 0
        // Automatic requests can only follow the source's reply chain. Even a
        // caller-supplied surrounding-ID list cannot expand that policy.
        let explicitIds = useContext && purpose != .automatic ? contextMessageIds : []
        guard var scope = try await ExteralessAISignalOperation<ExteralessAIScope?>().value(context.engine.messages.resolveExteralessAIScope(capability: capability, contextMessageIds: explicitIds, followReplyChain: useContext, contextLimit: limit, lease: lease)) else { throw AIError.cancelled }
        guard scope.allowsExternalProcessing else { throw ExteralessAIUIError("This source does not allow external text processing.") }
        if useContext, AINativeContextPolicy.includesPrecedingHistory(purpose: purpose), let source = scope.source, scope.contextMessages.count < limit {
            let broadcast: Bool
            if let channel = source._asMessage().peers[source.id.peerId] as? TelegramChannel, case .broadcast = channel.info { broadcast = true }
            else { broadcast = false }
            if !broadcast {
                let history = try await ExteralessAISignalOperation<[EngineMessage]>().value(context.engine.messages.localExteralessAIContextMessages(peerId: source.id.peerId, threadId: source.threadId, around: source.index, count: limit + 1))
                let preceding = history.reversed().filter { $0.index < source.index }.prefix(limit).map(\.id)
                // Re-resolve after the await; do not trust the view's messages or
                // reuse a source version sampled before history acquisition.
                let pinned = ExteralessAIProcessingCapability.message(source, canCopy: capability.allowsCopy)
                guard let expanded = try await ExteralessAISignalOperation<ExteralessAIScope?>().value(context.engine.messages.resolveExteralessAIScope(capability: pinned, contextMessageIds: Array((explicitIds + preceding).prefix(64)), followReplyChain: true, contextLimit: limit, lease: lease)) else { throw AIError.cancelled }
                scope = expanded
            }
        }
        try await validateScope(context: context, scope: scope)
        return scope
    }

    func validateScope(context: AccountContext, scope: ExteralessAIScope) async throws {
        try Task.checkCancellation()
        guard owns(context), !scope.lease.isCancelled, scope.allowsExternalProcessing else { throw AIError.cancelled }
        let valid = try await ExteralessAISignalOperation<Bool>().value(context.engine.messages.validateExteralessAIScope(scope))
        try Task.checkCancellation()
        guard owns(context), valid, !scope.lease.isCancelled else { scope.lease.cancel(); throw AIError.cancelled }
    }

    func scopedTransport(context: AccountContext, scope: ExteralessAIScope) -> any AIHTTPTransport {
        ExteralessAIScopedTransport(base: transport, validate: scopeValidation(context: context, scope: scope))
    }

    func scopedTranslator(context: AccountContext, scope: ExteralessAIScope) -> AITranslationClient {
        // Bing session acquisition carries no message body. Keep its shared
        // coalescer while each message-bearing request has its own export gate.
        AITranslationClient(transport: scopedTransport(context: context, scope: scope), settings: settings, bingCache: bingCache)
    }

    func ensureFullRichSource(context: AccountContext, scope: ExteralessAIScope) async throws {
        guard let rich = scope.source?.richText else { return }
        if !ExteralessAIRichSource.wholePage(rich).isComplete {
            try await validateScope(context: context, scope: scope)
            let loaded = try await ExteralessAISignalOperation<RichTextMessageAttribute?>().value(context.engine.messages.loadExteralessAIFullRichSource(scope: scope))
            guard let loaded, ExteralessAIRichSource.wholePage(loaded).isComplete else { throw ExteralessAIUIError("The complete message could not be loaded. Try Show more, then retry.") }
        }
        // Includes the new native version, account, reply and both private flags.
        try await validateScope(context: context, scope: scope)
    }

    func scopeValidation(context: AccountContext, scope: ExteralessAIScope) -> @Sendable () async throws -> Void {
        let validation = ExteralessAIScopeValidation(integration: self, context: context, scope: scope)
        return { try await validation.validate() }
    }

    private func applyShowTranslate(context: AccountContext) {
        let value = settings.store.bool("ai.showTranslate")
        guard nativeTranslationSettings?.showTranslate != value else { return }
        pendingShowTranslate = value
        translationWrite.set(updateTranslationSettingsInteractively(accountManager: context.sharedContext.accountManager, { $0.withUpdatedShowTranslate(value) }).start())
    }

    func modelInfo(_ model: String) -> AIModelInfo? {
        catalog[model.lowercased()] ?? catalog[String(model.split(separator: "/").last ?? "").lowercased()]
    }

    func prepare(context: AccountContext, chatId: EnginePeer.Id? = nil) async throws {
        let recovery = self.recovery
        let account = accountId(context)
        let chat = chatId.map { String($0.toInt64()) }
        do {
            let store = settings.store
            try await ExteralessAIPersistence.run {
                try store.register(AINativeVisibilityPolicy.definitions)
                try recovery.prepare(accountId: account, chatId: chat)
            }
        } catch {
            throw ExteralessAIUIError(recovery.errorDescription ?? "AI settings are unavailable.")
        }
        try Task.checkCancellation()
        guard self.context === context else { throw AIError.cancelled }
    }

    /// Optional native/plugin-review composition seam; schemas and callbacks are
    /// supplied by the owner of those tools, never inferred from a model response.
    public func installTools(_ tools: AIToolHandler) throws {
        try settings.store.register(AIFeatures.toolDefinitions)
        self.tools = tools
    }

    func presentActions(context: AccountContext, from presenter: ViewController, input: ExteralessAITextInput) {
        guard self.context === context else { return }
        presenter.push(ExteralessAIActionController(context: context, integration: self, input: wholeMessageInput(input, presenter: presenter)))
    }

    private func wholeMessageInput(_ input: ExteralessAITextInput, presenter: ViewController) -> ExteralessAITextInput {
        guard let messageId = input.messageId, input.selectedRange == nil, !input.wholeMessage else { return input }
        let chat = presenter as? ChatControllerImpl
        var capability = input.capability
        if capability.expectedStableVersion == nil {
            if let chat, chat.isNodeLoaded, let raw = chat.chatDisplayNode.historyNode.messageGroupInCurrentHistoryView(messageId)?.first(where: { $0.id == messageId }) {
                let captured = chat.exteralessAISelectionCapability(message: raw, canCopy: capability.allowsCopy)
                capability = ExteralessAIProcessingCapability(messageId: raw.id, expectedStableVersion: raw.stableVersion, peerId: raw.id.peerId, threadId: raw.threadId, allowsExternalProcessing: capability.allowsExternalProcessing && captured.allowsExternalProcessing, allowsCopy: captured.allowsCopy)
            } else {
                capability = .init(messageId: messageId, allowsExternalProcessing: false, allowsCopy: false)
            }
        }
        return ExteralessAITextInput(text: input.text, entities: input.entities, messageId: messageId, chatId: input.chatId, contextMessageIds: input.contextMessageIds, image: input.image, capability: capability, wholeMessage: true, automaticLanguage: chat?.exteralessAIAutomaticLanguage, isSummarized: chat?.controllerInteraction?.summarizedMessageIds.contains(messageId) == true, applyResult: input.applyResult)
    }

    private func operationInput(_ input: ExteralessAITextInput, context: AccountContext, scope: ExteralessAIScope) async throws -> (AIFormattedText, [MessageTextEntity]) {
        guard input.wholeMessage, scope.source?.richText != nil else { return (try exteralessAIFormattedInput(input), input.entities) }
        try await ensureFullRichSource(context: context, scope: scope)
        guard let message = scope.source else { throw AIError.cancelled }
        let display = ExteralessAIMessageDisplay.resolve(message: message, accountId: context.account.id.int64, accountPeerId: context.account.peerId, automaticLanguage: input.automaticLanguage, isSummarized: input.isSummarized, richExpanded: true, store: settings.store)
        if let page = display.page {
            return (AIFormattedText(text: try await ExteralessAIRichTextTranslator.markdown(page: page)), [])
        }
        return (try exteralessAIFormattedInput(.init(text: display.text, entities: display.entities)), display.entities)
    }

    func presentResult(_ screen: ExteralessAIResultController, from presenter: ViewController) {
        trackResult(screen)
        presenter.push(screen)
    }

    func trackResult(_ screen: ExteralessAIResultController) {
        screens.removeAll { $0.value == nil }
        guard !screens.contains(where: { $0.value === screen }) else { return }
        screens.append(WeakAIResultController(screen))
        let currentContext = self.context
        screen.onComplete = { [weak self, weak screen] result in
            guard let self, self.context === currentContext else { return }
            guard screen?.allowsCopy == true else { return }
            self.lastResult = (result, screen?.resultScope?.renewed(lease: AINativeOperationLease()))
        }
        screen.onInvalidated = { [weak self] in self?.lastResult = nil }
    }

    func run(_ action: AITextAction, context: AccountContext, from presenter: ViewController, input: ExteralessAITextInput) {
        guard self.context === context else { return }
        let settings = self.settings
        let account = accountId(context)
        let access = ExteralessAIResultAccess(integration: self, context: context, capability: input.capability)
        let original: AIFormattedText
        do { original = try exteralessAIFormattedInput(input) }
        catch { exteralessAIShowError(from: presenter, text: AIError.sanitized(error).description); return }
        let operation: ExteralessAIResultController.Operation = { [weak self] event in
            guard let self, self.context === context else { throw AIError.cancelled }
            try await self.prepare(context: context, chatId: input.chatId)
            let scope = try await access.resolve()
            let (original, originalEntities) = try await self.operationInput(input, context: context, scope: scope)
            let client = AIClient(transport: self.scopedTransport(context: context, scope: scope))
            let service = settings.selectedService
            let role = settings.selectedRole
            let transformsFormatting = action != .assistant && action != .summarize
            let source: String; if transformsFormatting { source = try AITextFormatting.encode(original) } else { source = original.text }
            // Message-derived results keep their scope; they must not become
            // unbound history turns that can later outlive source protection.
            let usesHistory = action == .assistant && input.capability.messageId == nil
            var messages = usesHistory ? settings.history(accountId: account) : []
            messages.append(.init(role: .user, content: action.prompt(text: source), image: input.image?.data, imageMIMEType: input.image?.mimeType))
            let request = AIGenerationRequest(messages: messages, systemPrompt: action == .assistant ? role.prompt : AITextAction.editorSystemPrompt, streaming: settings.store.bool("ai.responseStreaming", default: true), temperature: Double(settings.store.integer("ai.temperature", default: 10)) / 10, modelSupportsReasoning: self.modelInfo(service.model)?.reasoning ?? false, disableTools: settings.store.bool("ai.disableTools"))
            let result = try await client.generate(service: service, apiKey: settings.apiKey(for: service), request: request, tools: action == .assistant ? self.tools : nil, onEvent: { value in
                // A source-scoped answer is published only after revalidation.
                if scope.source == nil { await event(value) }
            })
            try Task.checkCancellation()
            try await access.validate()
            var note = service.displayName + " · " + service.model
            if usesHistory {
                do { try await ExteralessAIPersistence.run { guard !scope.lease.isCancelled else { throw AIError.cancelled }; try settings.appendHistory(accountId: account, prompt: original.text, response: result.text) } }
                catch { note += "\nHistory was not saved: secure storage is unavailable." }
            }
            let output: AIFormattedText; if transformsFormatting { output = try AITextFormatting.decode(result.text, original: original) } else { output = AIFormattedText(text: result.text) }
            return ExteralessAIResultContent(text: output, note: note, entities: transformsFormatting ? exteralessAIRestoredEntities(output, originals: originalEntities) : nil)
        }
        let screen = ExteralessAIResultController(context: context, title: action.title, source: original.text, sourceEntities: input.entities, settings: settings, speech: speech, asQuote: action == .assistant && settings.store.bool("ai.insertAsQuote", default: true), applyResult: input.applyResult, access: access, operation: operation)
        presentResult(screen, from: presenter)
    }

    func presentTranslation(context: AccountContext, from presenter: ViewController, input: ExteralessAITextInput, targetLanguage: String? = nil, purpose: AITranslationPurpose = .manual, provider: AITranslationProvider? = nil) {
        guard self.context === context else { return }
        presentResult(translationController(context: context, input: input, targetLanguage: targetLanguage, purpose: purpose, provider: provider), from: presenter)
    }

    private func presentMessageTranslation(context: AccountContext, from presenter: ViewController, message: EngineMessage, automaticLanguage: String?, isSummarized: Bool) {
        guard owns(context) else { return }
        let effectiveAutomaticLanguage: String?
        let capability: ExteralessAIProcessingCapability
        if let chat = presenter as? ChatControllerImpl {
            effectiveAutomaticLanguage = chat.exteralessAIAutomaticLanguage
            capability = chat.exteralessAISelectionCapability(message: message._asMessage(), canCopy: true)
        } else {
            effectiveAutomaticLanguage = automaticLanguage
            capability = .message(message, canCopy: true)
        }
        if exteralessPresentMessageTranslationSheet(context: context, from: presenter, message: message, automaticLanguage: effectiveAutomaticLanguage, isSummarized: isSummarized, capability: capability) { return }
        let access = ExteralessAIResultAccess(integration: self, context: context, capability: capability)
        let screen = ExteralessAIResultController(context: context, title: "Translate message", source: message.text, sourceEntities: [], settings: settings, speech: speech, asQuote: false, applyResult: nil, access: access, operation: { [weak self] event in
            guard let self else { throw AIError.cancelled }
            try await self.prepare(context: context, chatId: message.id.peerId)
            let account = String(context.account.id.int64)
            let key = AIManualTranslations.messageKey(peerId: message.id.peerId.toInt64(), namespace: message.id.namespace, id: message.id.id)
            let store = self.settings.store
            let policy = AITranslationPolicy(store: store)
            var configuration = AITranslationConfiguration(settings: self.settings)
            configuration.provider = policy.provider(for: .manual)
            if message.richText != nil { configuration.provider = .google }
            if message.media.contains(where: { $0 is TelegramMediaPoll }) && configuration.provider == .deepL { configuration.provider = .google }
            configuration.llmUseContext = AINativeContextPolicy.enabled(policy: policy, purpose: .manual, effectiveProvider: configuration.provider)
            let scope = try await access.resolve(purpose: .manual, configuration: configuration)
            try await self.ensureFullRichSource(context: context, scope: scope)
            guard let current = scope.source else { throw AIError.emptyResponse }
            let configured = store.string("ai.translateToLang")
            let language = configured.isEmpty ? context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode } : configured
            let before = ExteralessAIMessageDisplay.resolve(message: current, accountId: context.account.id.int64, accountPeerId: context.account.peerId, automaticLanguage: effectiveAutomaticLanguage, isSummarized: isSummarized, richExpanded: true, store: store)
            if before.selection.canHideManual, let marker = AIManualTranslations.state(accountId: account, messageKey: key, store: store) {
                try await access.validate()
                try await ExteralessAIPersistence.run { try AIManualTranslations.set(.init(language: marker.language, visible: false), accountId: account, messageKey: key, store: store) }
                try await access.validate()
                let display = ExteralessAIMessageDisplay.resolve(message: current, accountId: context.account.id.int64, accountPeerId: context.account.peerId, automaticLanguage: effectiveAutomaticLanguage, isSummarized: isSummarized, richExpanded: true, store: store)
                await event(.text(display.text))
                return ExteralessAIResultContent(text: .init(text: display.text), note: "Translation hidden in chat", entities: display.entities)
            }
            let cached = current.attributes.compactMap { $0 as? TranslationMessageAttribute }.first {
                $0.toLang == language && ExteralessAIRichSource.isUsableTranslation($0, for: current.richText)
            }
            let summary = current.attributes.first { $0 is SummarizationMessageAttribute } as? SummarizationMessageAttribute
            if cached == nil || (isSummarized && summary?.summaryForLang(language) == nil) {
                try await self.nativeAdapter.translateAndStore(context: context, scope: scope, toLanguage: language, automatic: false, configuration: configuration, requireSummary: isSummarized)
            }
            guard let updated = try await ExteralessAISignalOperation<EngineMessage?>().value(context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: message.id))),
                  updated.attributes.contains(where: { ($0 as? TranslationMessageAttribute)?.toLang == language }) else { throw AIError.emptyResponse }
            try await access.validate()
            try await ExteralessAIPersistence.run { try AIManualTranslations.set(.init(language: language), accountId: account, messageKey: key, store: store) }
            try await access.validate()
            let display = ExteralessAIMessageDisplay.resolve(message: updated, accountId: context.account.id.int64, accountPeerId: context.account.peerId, automaticLanguage: effectiveAutomaticLanguage, isSummarized: isSummarized, richExpanded: true, store: store)
            let text = display.page.map(markdownStringFromInstantPage) ?? display.text
            await event(.text(text))
            return ExteralessAIResultContent(text: .init(text: text), note: "Stored in chat · " + language, entities: display.entities)
        })
        presentResult(screen, from: presenter)
    }

    func translationController(context: AccountContext, input: ExteralessAITextInput, targetLanguage: String?, purpose: AITranslationPurpose, provider: AITranslationProvider? = nil) -> ExteralessAIResultController {
        let access = ExteralessAIResultAccess(integration: self, context: context, capability: input.capability)
        let operation: ExteralessAIResultController.Operation = { [weak self] event in
            guard let self, self.context === context else { throw AIError.cancelled }
            try await self.prepare(context: context, chatId: input.chatId)
            let policy = AITranslationPolicy(store: self.settings.store)
            var config = AITranslationConfiguration(settings: self.settings)
            config.provider = provider ?? policy.provider(for: purpose)
            config.llmUseContext = AINativeContextPolicy.enabled(policy: policy, purpose: purpose, effectiveProvider: config.provider)
            let scope = try await access.resolve(purpose: purpose, configuration: config, contextMessageIds: input.contextMessageIds)
            let (original, originalEntities) = try await self.operationInput(input, context: context, scope: scope)
            let bridge = ExteralessAINativeTranslation(context: context, originalEntities: originalEntities)
            let translator = self.scopedTranslator(context: context, scope: scope)
            let configured = targetLanguage ?? self.settings.store.string("ai.translateToLang")
            let language = configured.isEmpty ? context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode } : configured
            let contextTexts = scope.contextMessages.map(\.text)
            let validate = self.scopeValidation(context: context, scope: scope)
            let result = try await translator.translate(original, to: language, context: contextTexts, configuration: config, native: { input, language in
                try await validate()
                return try await bridge.translate(input, to: language)
            })
            try await access.validate()
            let entities = result.provider == .telegram ? bridge.resultEntities : exteralessAIRestoredEntities(result.text, originals: originalEntities)
            let keepOriginal = purpose != .input && policy.keepsOriginal(manual: purpose != .automatic, automatic: purpose == .automatic) && !original.text.isEmpty
            let output: String
            let outputEntities: [MessageTextEntity]
            if keepOriginal {
                let offset = original.text.utf16.count + AITranslationPolicy.separator.utf16.count
                output = original.text + AITranslationPolicy.separator + result.text.text
                outputEntities = exteralessAIRestoredEntities(original, originals: originalEntities) + entities.map { MessageTextEntity(range: ($0.range.lowerBound + offset) ..< ($0.range.upperBound + offset), type: $0.type) }
            } else { output = result.text.text; outputEntities = entities }
            await event(.text(output))
            let suffix = result.usedFallback ? " · fallback after LLM connection/rate errors" : ""
            return ExteralessAIResultContent(text: AIFormattedText(text: output), note: result.provider.title + " → " + language + suffix, entities: outputEntities)
        }
        let screen = ExteralessAIResultController(context: context, title: purpose == .article ? "Translate article" : "Translate", source: (try? exteralessAIFormattedInput(input).text) ?? input.text, sourceEntities: input.entities, settings: settings, speech: speech, asQuote: false, applyResult: input.applyResult, access: access, operation: operation)
        trackResult(screen)
        return screen
    }

    func presentAudio(context: AccountContext, from presenter: ViewController, url: URL) {
        guard self.context === context else { return }
        let speech = self.speech
        let access = ExteralessAIResultAccess(integration: self, context: context, capability: .userInput)
        let screen = ExteralessAIResultController(context: context, title: "Transcribe audio", source: "", sourceEntities: [], settings: settings, speech: speech, asQuote: false, applyResult: nil, access: access, operation: { [weak self] event in
            guard let self else { throw AIError.cancelled }
            try await self.prepare(context: context)
            _ = try await access.resolve()
            var config = AITranscriptionConfiguration(settings: self.settings)
            if case let .provider(provider) = AINativeSpeechPolicy.route(configuration: config, isPremium: false) { config.provider = provider }
            let locale = self.settings.store.string("ai.OEVoskLanguage")
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let text = try await speech.transcribe(fileURL: url, locale: locale, configuration: config, partial: { text in
                Task { await event(.replaceText(text)) }
            })
            try await access.validate()
            await event(.replaceText(text))
            return ExteralessAIResultContent(text: AIFormattedText(text: text), note: config.effectiveProvider.title)
        })
        presentResult(screen, from: presenter)
    }

    func presentMessageTranscription(context: AccountContext, from presenter: ViewController, messageId: EngineMessage.Id, file: TelegramMediaFile) {
        guard self.context === context else { return }
        let access = ExteralessAIResultAccess(integration: self, context: context, capability: .init(allowsExternalProcessing: true, allowsCopy: false))
        let screen = ExteralessAIResultController(context: context, title: "Transcribe voice message", source: "", sourceEntities: [], settings: settings, speech: speech, asQuote: false, applyResult: nil, access: access, operation: { [weak self] _ in
            guard let self, self.context === context else { throw AIError.cancelled }
            _ = try await access.resolve()
            guard let operation = self.nativeAdapter.transcribe(context: context, messageId: messageId, file: file, lease: access.lease) else { throw AIError.cancelled }
            let stored = try await ExteralessAISignalOperation<Bool>().value(operation, mapError: { $0 })
            guard stored else { throw ExteralessAITranscriptionError.sourceChanged }
            // The transcript remains in the native message, with its live copy
            // protection. This progress screen retains no second transcript.
            return ExteralessAIResultContent(text: AIFormattedText(text: ""), note: "Transcription saved in the message")
        })
        presentResult(screen, from: presenter)
    }

    private func presentSpeech(context: AccountContext, from presenter: ViewController, input: ExteralessAITextInput) {
        guard owns(context) else { return }
        // Read aloud is a direct, on-device AVSpeech action, including protected
        // selections. It creates neither a copyable result nor a Latest cache row.
        do {
            let text = try exteralessAIFormattedInput(input).text
            try speech.speak(text, language: settings.store.string("ai.OEVoskLanguage"), voiceIdentifier: settings.store.string("ai.speechVoiceIdentifier"), rate: Float(settings.store.double("ai.speechRate", default: 0.5))) { _ in }
        } catch { exteralessAIShowError(from: presenter, text: (error as? ExteralessSpeechError)?.errorDescription ?? AIError.sanitized(error).description) }
    }

    deinit { observation?.cancel(); nativeSettingsDisposable?.dispose(); presentationDisposable?.dispose(); translationWrite.dispose() }
}

/// The same gate runs for the first HTTP request, LLM retries, provider fallback
/// and every tool round. A UI-level preflight alone would miss later exports.
struct ExteralessAIScopedTransport: AIHTTPTransport {
    let base: any AIHTTPTransport
    let validate: @Sendable () async throws -> Void

    func events(for request: URLRequest, maximumBytes: Int, timeout: TimeInterval) -> AsyncThrowingStream<AIHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    try await validate()
                    try Task.checkCancellation()
                    for try await event in base.events(for: request, maximumBytes: maximumBytes, timeout: timeout) {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

/// Only this main-actor holder touches AccountContext. Sendable HTTP/native
/// callbacks capture the holder instead of moving raw account objects off main.
@MainActor
private final class ExteralessAIScopeValidation {
    private weak var integration: ExteralessAIIntegration?
    private let context: AccountContext
    private let scope: ExteralessAIScope
    init(integration: ExteralessAIIntegration, context: AccountContext, scope: ExteralessAIScope) {
        self.integration = integration
        self.context = context
        self.scope = scope
    }
    func validate() async throws {
        guard let integration else { throw AIError.cancelled }
        try await integration.validateScope(context: context, scope: scope)
    }
}

@MainActor
final class ExteralessAIResultAccess {
    typealias Resolve = @MainActor (ExteralessAIProcessingCapability, AITranslationPurpose, AITranslationConfiguration?, [EngineMessage.Id], AINativeOperationLease) async throws -> ExteralessAIScope
    private let resolveScope: Resolve
    private let validateScope: @MainActor (ExteralessAIScope) async throws -> Void
    private let observeScope: @MainActor (ExteralessAIScope) -> Signal<Bool, NoError>
    private var capability: ExteralessAIProcessingCapability
    private let previousScope: ExteralessAIScope?
    private var observation: Disposable?
    private(set) var lease = AINativeOperationLease()
    private(set) var scope: ExteralessAIScope?
    private var invalidated = false
    private var generation = UUID()
    private var finished = false
    var onInvalidated: (() -> Void)?
    var allowsCopy: Bool { capability.allowsCopy && scope?.allowsCopy == true && !lease.isCancelled }

    convenience init(integration: ExteralessAIIntegration, context: AccountContext, capability: ExteralessAIProcessingCapability, previousScope: ExteralessAIScope? = nil) {
        self.init(capability: capability, previousScope: previousScope, resolve: { [weak integration] capability, purpose, configuration, ids, lease in
            guard let integration else { throw AIError.cancelled }
            return try await integration.resolveScope(context: context, capability: capability, purpose: purpose, configuration: configuration, contextMessageIds: ids, lease: lease)
        }, validate: { [weak integration] scope in
            guard let integration else { throw AIError.cancelled }
            try await integration.validateScope(context: context, scope: scope)
        }, observe: { scope in context.engine.messages.exteralessAIScopeValidity(scope) })
    }

    /// Injects only the engine data boundary for native in-memory fixtures. The
    /// operation/retry/observation lifecycle below is the production implementation.
    init(capability: ExteralessAIProcessingCapability, previousScope: ExteralessAIScope? = nil, resolve: @escaping Resolve, validate: @escaping @MainActor (ExteralessAIScope) async throws -> Void, observe: @escaping @MainActor (ExteralessAIScope) -> Signal<Bool, NoError>) {
        self.capability = capability
        self.previousScope = previousScope
        self.resolveScope = resolve
        self.validateScope = validate
        self.observeScope = observe
    }
    func begin() {
        observation?.dispose()
        observation = nil
        // Cancellation linearizes with any in-progress Postbox commit. Read its
        // receipt afterwards so an already-winning own commit is not lost.
        lease.cancel()
        if let committed = scope?.committedRetryCapability { capability = committed }
        generation = UUID()
        lease = AINativeOperationLease()
        scope = nil
        invalidated = false
        finished = false
    }
    func resolve(purpose: AITranslationPurpose = .manual, configuration: AITranslationConfiguration? = nil, contextMessageIds: [EngineMessage.Id] = []) async throws -> ExteralessAIScope {
        let generation = self.generation
        let lease = self.lease
        let scope: ExteralessAIScope
        if let previousScope { scope = previousScope.renewed(lease: lease) }
        else { scope = try await resolveScope(capability, purpose, configuration, contextMessageIds, lease) }
        try await validateScope(scope)
        guard self.generation == generation, self.lease === lease, !lease.isCancelled else { throw AIError.cancelled }
        self.scope = scope
        observation?.dispose()
        observation = (observeScope(scope) |> deliverOnMainQueue).start(next: { [weak self] valid in
            guard let self, self.generation == generation, self.scope === scope, !valid, !self.invalidated else { return }
            self.invalidated = true
            self.cancel()
            self.onInvalidated?()
        })
        return scope
    }
    func validate() async throws {
        guard let scope else { throw AIError.cancelled }
        let generation = self.generation
        try await validateScope(scope)
        guard self.generation == generation, self.scope === scope, !lease.isCancelled else { throw AIError.cancelled }
    }
    /// Completion is once-only and never learns a version from the UI. Retry's
    /// version comes exclusively from the engine's confirmed commit receipt.
    @discardableResult func finish() -> Bool {
        guard !finished, !invalidated, !lease.isCancelled, scope != nil else { return false }
        finished = true
        return true
    }
    func cancel() { lease.cancel(); observation?.dispose(); observation = nil }
    deinit { lease.cancel(); observation?.dispose() }
}

private final class WeakAIResultController {
    weak var value: ExteralessAIResultController?
    init(_ value: ExteralessAIResultController) { self.value = value }
}

struct ExteralessAIUIError: Error, LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

@MainActor
func exteralessAIShowError(from presenter: ViewController, text: String) {
    let alert = UIAlertController(title: "AI", message: text, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    presenter.present(alert, animated: true)
}

func exteralessAIFormattedInput(_ input: ExteralessAITextInput) throws -> AIFormattedText {
    var spans: [AITextSpan] = []
    for (index, entity) in input.entities.enumerated() {
        let tag: AITextSpan.Tag
        var preserve = false
        switch entity.type {
        case .Bold: tag = .bold
        case .Italic: tag = .italic
        case .Underline: tag = .underline
        case .Strikethrough: tag = .strike
        case .Spoiler: tag = .spoiler
        case .Code: tag = .code; preserve = true
        case .Pre: tag = .pre; preserve = true
        case .BlockQuote: tag = .quote
        case .TextUrl: tag = .link
        default: tag = .protected; preserve = true
        }
        spans.append(.init(id: index, offset: entity.range.lowerBound, length: entity.range.count, tag: tag, preserveText: preserve))
    }
    return try AIFormattedText(text: input.text, spans: spans).selected(input.selectedRange)
}

func exteralessAIRestoredEntities(_ value: AIFormattedText, originals: [MessageTextEntity]) -> [MessageTextEntity] {
    value.spans.compactMap { span in
        guard originals.indices.contains(span.id), span.offset >= 0, span.length > 0, span.offset + span.length <= value.text.utf16.count else { return nil }
        return MessageTextEntity(range: span.offset ..< span.offset + span.length, type: originals[span.id].type)
    }
}

@MainActor
final class ExteralessAINativeTranslation {
    let context: AccountContext
    let originalEntities: [MessageTextEntity]
    private(set) var resultEntities: [MessageTextEntity] = []
    init(context: AccountContext, originalEntities: [MessageTextEntity]) { self.context = context; self.originalEntities = originalEntities }

    func translate(_ input: AIFormattedText, to language: String) async throws -> AIFormattedText {
        let operation = ExteralessAISignalOperation<(String, [MessageTextEntity])?>()
        let result = try await operation.value(context.engine.messages.translate(text: input.text, toLang: language, entities: exteralessAIRestoredEntities(input, originals: originalEntities)))
        guard let (text, entities) = result, !text.isEmpty else { throw AIError.emptyResponse }
        resultEntities = entities
        // Telegram returns new entities with valid offsets. Preserve their full
        // payload for the screen through owned span identities where possible.
        var spans: [AITextSpan] = []
        for entity in entities {
            if let index = originalEntities.firstIndex(where: { $0.type == entity.type }), let source = input.spans.first(where: { $0.id == index }) {
                var span = source
                span.offset = entity.range.lowerBound
                span.length = entity.range.count
                spans.append(span)
            }
        }
        return AIFormattedText(text: text, spans: spans)
    }

}

/// A disposable + one-shot continuation, including cancellation before start and
/// a completed-without-value signal. No delayed callback can resume it twice.
@MainActor
final class ExteralessAISignalOperation<Value> {
    private var disposable: Disposable?
    private var continuation: CheckedContinuation<Value, Error>?
    private var finished = false
    private var timeoutTask: Task<Void, Never>?

    // SwiftSignalKit's E (including NoError/TranslationError) is deliberately
    // unconstrained; those enums do not conform to Swift.Error.
    func value<E>(_ signal: Signal<Value, E>, mapError: @escaping (E) -> Error = { _ in AIError.network }) async throws -> Value {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if finished { continuation.resume(throwing: AIError.cancelled); return }
                self.continuation = continuation
                timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    self?.finish(.failure(AIError.timeout))
                }
                let disposable = (signal |> deliverOnMainQueue).start(next: { [weak self] value in self?.finish(.success(value)) }, error: { [weak self] error in self?.finish(.failure(mapError(error))) }, completed: { [weak self] in self?.finish(.failure(AIError.emptyResponse)) })
                if finished { disposable.dispose() } else { self.disposable = disposable }
            }
        }, onCancel: { [weak self] in Task { @MainActor in self?.finish(.failure(AIError.cancelled)) } })
    }

    private func finish(_ result: Result<Value, Error>) {
        guard !finished else { return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        disposable?.dispose()
        disposable = nil
        continuation?.resume(with: result)
    }
}
