import AccountContext
import BrowserUI
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import TextFormat

/// Typed entry points used by the AccountContext facade in the coordinator hunks.
/// The facade is below TelegramUI in the graph; no component imports TelegramUI
/// back through a dependency cycle. All native object access is confined to main.
@MainActor
public final class ExteralessAINativeAdapter {
    private weak var integration: ExteralessAIIntegration?
    private var generation = UUID()
    private var operations: [UUID: (token: AINativeOperationLease, tag: String?)] = [:]

    init(integration: ExteralessAIIntegration) { self.integration = integration }
    public func handles(context: AccountContext) -> Bool { integration?.owns(context) == true }

    public func cancelAll() {
        generation = UUID()
        let operations = Array(self.operations.values)
        self.operations.removeAll()
        for operation in operations { operation.token.cancel() }
    }

    public func cancelAutomaticTranslations() {
        let ids = operations.filter { $0.value.tag == "automatic" }.map(\.key)
        for id in ids { operations.removeValue(forKey: id)?.token.cancel() }
    }

    public func compose(context: AccountContext, text: ComposedRichMessage, mode: TelegramComposeAIMessageMode, styles: [TelegramComposeAIMessageMode.CloudStyle], sourceLanguage: String?, capability: ExteralessAIProcessingCapability) -> Signal<TelegramAIComposeMessageResult, TelegramAIComposeMessageError>? {
        guard capability.allowsExternalProcessing, let integration, integration.owns(context), integration.settings.store.value("ai.replaceTelegramEditor") != .bool(false) else { return nil }
        return signal(context: context, error: { ($0 as? ExteralessAIForwardedError)?.compose ?? .generic }) { [weak integration] cancellation in
            guard let integration else { throw AIError.cancelled }
            try await integration.prepare(context: context)
            let service = integration.settings.selectedService
            let key = integration.settings.apiKey(for: service)
            let premium = try await self.isPremium(context)
            let enabled = AIReplacementPolicy.enabled(integration.settings.store.value("ai.replaceTelegramEditor"), isPremium: premium, configured: !key.isEmpty && !service.url.isEmpty && !service.model.isEmpty)
            if !enabled {
                return try await ExteralessAISignalOperation<TelegramAIComposeMessageResult>().value(context.engine.messages.composeAIMessage(text: text, mode: mode), mapError: { ExteralessAIForwardedError(compose: $0) })
            }
            let scope = try await integration.resolveScope(context: context, capability: capability, lease: cancellation)
            let original = try await self.source(text)
            var task = AIComposeTask(sourceLanguage: sourceLanguage)
            var generationPrompt: String?
            switch mode {
            case .proofread: task.proofread = true
            case let .translate(language, emojify, style):
                task.translateTo = language; task.emojify = emojify
                task.style = try self.style(style, styles: styles)
            case let .stylize(emojify, style):
                task.emojify = emojify
                task.style = try self.style(style, styles: styles)
            case let .generate(prompt): generationPrompt = prompt
            }
            let encoded = try AITextFormatting.encode(original.formatted)
            let request = AIGenerationRequest(messages: [.init(role: .user, content: generationPrompt ?? task.prompt(text: encoded))], systemPrompt: generationPrompt == nil ? AITextAction.editorSystemPrompt : AIRole.suggestions[0].prompt, streaming: false, temperature: Double(integration.settings.store.integer("ai.temperature", default: 10)) / 10, modelSupportsReasoning: integration.modelInfo(service.model)?.reasoning ?? false)
            let response = try await AIClient(transport: integration.scopedTransport(context: context, scope: scope)).generate(service: service, apiKey: key, request: request)
            try await integration.validateScope(context: context, scope: scope)
            let result: ComposedRichMessage
            if original.rich || generationPrompt != nil {
                guard let rich = inputRichTextAttributeFromText(context: context, text: response.text) else { throw AIError.invalidResponse }
                result = .rich(instantPage: rich.instantPage)
            } else {
                let restored = try AITextFormatting.decode(response.text, original: original.formatted)
                result = .plain(text: restored.text, entities: exteralessAIRestoredEntities(restored, originals: original.entities))
            }
            let outputText: String
            switch result {
            case let .plain(text, _): outputText = text
            case let .rich(page): outputText = page.plainText
            case .empty: outputText = ""
            }
            let difference = AITextDifference.changedRange(original: original.formatted.text, updated: outputText).map { [$0] } ?? []
            return TelegramAIComposeMessageResult(text: result, diffRanges: difference)
        }
    }

    public func summarize(context: AccountContext, messageId: EngineMessage.Id, toLanguage: String?) -> Signal<Never, SummarizeError>? {
        guard let integration, integration.owns(context), integration.settings.store.value("ai.replaceTelegramSummaries") != .bool(false) else { return nil }
        let operation: Signal<Void, SummarizeError> = signal(context: context, error: { ($0 as? ExteralessAIForwardedError)?.summary ?? .generic }) { [weak integration] cancellation in
            guard let integration else { throw AIError.cancelled }
            try await integration.prepare(context: context, chatId: messageId.peerId)
            let service = integration.settings.selectedService
            let key = integration.settings.apiKey(for: service)
            let premium = try await self.isPremium(context)
            let enabled = AIReplacementPolicy.enabled(integration.settings.store.value("ai.replaceTelegramSummaries"), isPremium: premium, configured: !key.isEmpty && !service.url.isEmpty && !service.model.isEmpty)
            if !enabled {
                try await self.completion(context.engine.messages.summarizeMessage(messageId: messageId, translateToLang: toLanguage), mapError: { ExteralessAIForwardedError(summary: $0) })
                return
            }
            let scope = try await integration.resolveScope(context: context, capability: .init(messageId: messageId, allowsExternalProcessing: true, allowsCopy: true), lease: cancellation)
            try await integration.ensureFullRichSource(context: context, scope: scope)
            guard let message = scope.source else { throw AIError.emptyResponse }
            let original: String
            if let rich = message.richText { original = try await ExteralessAIRichTextTranslator.markdown(source: rich) }
            else { original = message.text }
            let prompt = AITextAction.summarize.prompt(text: original, language: toLanguage ?? "")
            let response = try await AIClient(transport: integration.scopedTransport(context: context, scope: scope)).generate(service: service, apiKey: key, request: .init(messages: [.init(role: .user, content: prompt)], systemPrompt: AITextAction.editorSystemPrompt, streaming: false, temperature: Double(integration.settings.store.integer("ai.temperature", default: 10)) / 10))
            try await integration.validateScope(context: context, scope: scope)
            let updated = try await ExteralessAISignalOperation<Bool>().value(context.engine.messages.storeExteralessAISummary(
                scope: scope,
                summary: .init(text: response.text, entities: []),
                toLanguage: toLanguage,
                canCommit: { !cancellation.isCancelled }
            ))
            try Task.checkCancellation()
            guard updated else { throw AIError.cancelled }
        }
        return operation |> ignoreValues
    }

    public func translateMessages(context: AccountContext, messageIds: [EngineMessage.Id], fromLanguage: String?, toLanguage: String, automatic: Bool) -> Signal<Never, TranslationError>? {
        guard let integration, integration.owns(context) else { return nil }
        let initial = AITranslationPolicy(store: integration.settings.store)
        if initial.provider == .telegram && automatic && initial.autoEnabled { return nil }
        let operation: Signal<Void, TranslationError> = signal(context: context, tag: automatic ? "automatic" : nil, error: { error in
            switch AIError.sanitized(error) { case .unsupportedLanguage: return .invalidLanguage; case .inputTooLarge: return .textTooLong; default: return .generic }
        }) { [weak integration] cancellation in
            guard let integration else { throw AIError.cancelled }
            try await integration.prepare(context: context)
            let policy = AITranslationPolicy(store: integration.settings.store)
            if automatic { let premium = try await self.isPremium(context); if !policy.canAutomaticallyTranslate(isPremium: premium) { return } }
            guard messageIds.count <= 64 else { throw AIError.inputTooLarge }
            let unique = Array(Set(messageIds)).sorted {
                if $0.peerId != $1.peerId { return $0.peerId.toInt64() < $1.peerId.toInt64() }
                return $0.namespace == $1.namespace ? $0.id < $1.id : $0.namespace < $1.namespace
            }
            let messages = try await ExteralessAISignalOperation<[EngineMessage.Id: EngineMessage]>().value(context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Messages(ids: Set(unique))))
            for id in unique {
                try Task.checkCancellation()
                guard let message = messages[id] else { continue } // deleted while queued
                if automatic && message.author?.id == context.account.peerId { continue }
                let purpose: AITranslationPurpose = automatic ? .automatic : .manual
                var config = AITranslationConfiguration(settings: integration.settings)
                config.provider = policy.provider(for: purpose)
                if message.richText != nil { config.provider = .google }
                if message.media.contains(where: { $0 is TelegramMediaPoll }) && config.provider == .deepL { config.provider = .google }
                config.llmUseContext = AINativeContextPolicy.enabled(policy: policy, purpose: purpose, effectiveProvider: config.provider)
                let scope = try await integration.resolveScope(context: context, capability: .message(message, canCopy: true), purpose: purpose, configuration: config, lease: cancellation)
                try await self.translateAndStore(context: context, scope: scope, toLanguage: toLanguage, automatic: automatic, configuration: config)
                if !automatic {
                    let settings = integration.settings.store
                    let account = String(context.account.id.int64)
                    let key = AIManualTranslations.messageKey(peerId: id.peerId.toInt64(), namespace: id.namespace, id: id.id)
                    try await ExteralessAIPersistence.run { try AIManualTranslations.set(.init(language: toLanguage), accountId: account, messageKey: key, store: settings) }
                }
            }
        }
        return operation |> ignoreValues
    }

    func translateAndStore(context: AccountContext, scope: ExteralessAIScope, toLanguage: String, automatic: Bool, configuration: AITranslationConfiguration, requireSummary: Bool = false) async throws {
        guard let integration else { throw AIError.cancelled }
        try await integration.ensureFullRichSource(context: context, scope: scope)
        guard let message = scope.source else { throw AIError.cancelled }
        let client = integration.scopedTranslator(context: context, scope: scope)
        let result = try await translateMessage(context: context, integration: integration, client: client, scope: scope, message: message, to: toLanguage, configuration: configuration)
        let summaryAttribute = message.attributes.first { $0 is SummarizationMessageAttribute } as? SummarizationMessageAttribute
        let summarySource = summaryAttribute?.summary ?? summaryAttribute?.translated.sorted(by: { $0.key < $1.key }).first?.value
        let translatedSummary: SummarizationMessageAttribute.Summary?
        if let cached = summaryAttribute?.summaryForLang(toLanguage) { translatedSummary = cached }
        else if let summarySource {
            let value = try await translateText(context: context, integration: integration, client: client, scope: scope, text: summarySource.text, entities: summarySource.entities, to: toLanguage, configuration: configuration)
            translatedSummary = .init(text: value.0, entities: value.1)
        } else if requireSummary {
            let service = integration.settings.selectedService
            let source: String
            if let rich = message.richText { source = try await ExteralessAIRichTextTranslator.markdown(source: rich) }
            else { source = message.text }
            let response = try await AIClient(transport: integration.scopedTransport(context: context, scope: scope)).generate(service: service, apiKey: integration.settings.apiKey(for: service), request: .init(messages: [.init(role: .user, content: AITextAction.summarize.prompt(text: source, language: toLanguage))], systemPrompt: AITextAction.editorSystemPrompt, streaming: false))
            translatedSummary = .init(text: response.text, entities: [])
        } else { translatedSummary = nil }
        try await integration.validateScope(context: context, scope: scope)
        let store = integration.settings.store
        let stored = try await ExteralessAISignalOperation<Bool>().value(context.engine.messages.storeExteralessAITranslation(scope: scope, translation: result, translatedSummary: translatedSummary, canCommit: {
            !scope.lease.isCancelled && (!automatic || store.bool("ai.telegramUIAutoTranslate", default: true))
        }))
        try Task.checkCancellation()
        guard stored, integration.owns(context) else { throw AIError.cancelled }
    }

    public func articleController(context: AccountContext, text: String, entities: [MessageTextEntity], toLanguage: String?) -> ViewController? {
        guard let integration, integration.owns(context) else { return nil }
        return integration.translationController(context: context, input: ExteralessAITextInput(text: text, entities: entities), targetLanguage: toLanguage, purpose: .article)
    }

    /// Both the stock inline button and the message menu use this typed path.
    /// Auto/Premium remains the real Telegram route; an explicit provider never
    /// silently falls back to Telegram or another cloud provider on failure.
    public func transcribe(context: AccountContext, messageId: EngineMessage.Id, file: TelegramMediaFile, lease: AINativeOperationLease? = nil) -> Signal<Bool, ExteralessAITranscriptionError>? {
        guard let integration, integration.owns(context) else { return nil }
        return signal(context: context, lease: lease, error: { error in
            if let error = error as? ExteralessAITranscriptionError { return error }
            if let error = error as? ExteralessSpeechError { return .failed(error.errorDescription ?? "Speech failed.") }
            if let error = error as? ExteralessAIUIError { return .failed(error.text) }
            if AIError.sanitized(error) == .cancelled { return .cancelled }
            return .failed(AIError.sanitized(error).description)
        }) { [weak integration] cancellation in
            guard let integration else { throw AIError.cancelled }
            try await integration.prepare(context: context, chatId: messageId.peerId)
            let configuration = AITranscriptionConfiguration(settings: integration.settings)
            let premium = try await self.isPremium(context)
            return try await ExteralessAINativeTranscriptionRequest.run(configuration: configuration, isPremium: premium, telegram: {
                // Native Telegram processing is permitted for a copy-protected
                // cloud message; it never grants external/copy capability.
                guard let scope = try await ExteralessAISignalOperation<ExteralessAIScope?>().value(context.engine.messages.resolveExteralessAIScope(capability: .init(messageId: messageId, allowsExternalProcessing: false, allowsCopy: false), lease: cancellation)) else { throw AIError.cancelled }
                let result = try await ExteralessAISignalOperation<EngineAudioTranscriptionResult>().value(context.engine.messages.transcribeExteralessAITelegramAudio(scope: scope, expectedResourceId: EngineMediaResource.Id(file.resource.id)))
                guard case .success = result else { throw ExteralessAITranscriptionError.nativeFailed }
                return true
            }, provider: { configuration in
                let scope = try await integration.resolveScope(context: context, capability: .init(messageId: messageId, allowsExternalProcessing: true, allowsCopy: true), lease: cancellation)
                let resourceId = EngineMediaResource.Id(file.resource.id)
                guard let source = scope.source, source._asMessage().effectiveMedia.contains(where: { ($0 as? TelegramMediaFile)?.resource.id == file.resource.id }) else { throw ExteralessAITranscriptionError.sourceChanged }
                let resource = try await ExteralessAISignalOperation<EngineMediaResource.ResourceData>().value(context.engine.resources.data(resource: EngineMediaResource(file.resource), incremental: true) |> take(1))
                guard resource.isComplete else { throw ExteralessAITranscriptionError.notDownloaded }
                let text = try await integration.speech.transcribe(fileURL: URL(fileURLWithPath: resource.path), locale: integration.settings.store.string("ai.OEVoskLanguage"), configuration: configuration, transport: integration.scopedTransport(context: context, scope: scope))
                try await integration.validateScope(context: context, scope: scope)
                let stored = try await ExteralessAISignalOperation<Bool>().value(context.engine.messages.storeExteralessAITranscription(scope: scope, expectedResourceId: resourceId, text: text))
                try Task.checkCancellation()
                guard stored else { throw ExteralessAITranscriptionError.sourceChanged }
                return true
            })
        }
    }

    private func translateMessage(context: AccountContext, integration: ExteralessAIIntegration, client: AITranslationClient, scope: ExteralessAIScope, message: EngineMessage, to: String, configuration: AITranslationConfiguration) async throws -> TranslationMessageAttribute {
        if let rich = message.richText {
            var config = configuration
            config.provider = .google // RichMessageTransHelper forces Google.
            let page = try await ExteralessAIRichTextTranslator.translate(source: rich, client: client, to: to, configuration: config)
            return TranslationMessageAttribute(text: "", entities: [], toLang: to, instantPage: page)
        }
        if let poll = message.media.first(where: { $0 is TelegramMediaPoll }) as? TelegramMediaPoll {
            guard poll.options.count <= 64 else { throw AIError.inputTooLarge }
            var parts = [(poll.text, poll.textEntities)] + poll.options.map { ($0.text, $0.entities) }
            if let solution = poll.results.solution { parts.append((solution.text, solution.entities)) }
            var config = configuration
            if config.provider == .deepL { config.provider = .google }
            var outputs: [(String, [MessageTextEntity])] = []
            for part in parts { outputs.append(try await translateText(context: context, integration: integration, client: client, scope: scope, text: part.0, entities: part.1, to: to, configuration: config)) }
            let answers = outputs.dropFirst().prefix(poll.options.count).map { TranslationMessageAttribute.Additional(text: $0.0, entities: $0.1) }
            let solution = poll.results.solution != nil ? outputs.last.map { TranslationMessageAttribute.Additional(text: $0.0, entities: $0.1) } : nil
            return TranslationMessageAttribute(text: outputs[0].0, entities: outputs[0].1, additional: Array(answers), pollSolution: solution, toLang: to)
        }
        let transcription = message.attributes.first { $0 is AudioTranscriptionMessageAttribute } as? AudioTranscriptionMessageAttribute
        let text = message.text.isEmpty ? transcription?.text ?? "" : message.text
        let entities = (message.attributes.first { $0 is TextEntitiesMessageAttribute } as? TextEntitiesMessageAttribute)?.entities ?? []
        let translated = try await translateText(context: context, integration: integration, client: client, scope: scope, text: text, entities: entities, to: to, configuration: configuration)
        return TranslationMessageAttribute(text: translated.0, entities: translated.1, toLang: to)
    }

    private func translateText(context: AccountContext, integration: ExteralessAIIntegration, client: AITranslationClient, scope: ExteralessAIScope, text: String, entities: [MessageTextEntity], to: String, configuration: AITranslationConfiguration) async throws -> (String, [MessageTextEntity]) {
        let input = try exteralessAIFormattedInput(ExteralessAITextInput(text: text, entities: entities))
        let native = ExteralessAINativeTranslation(context: context, originalEntities: entities)
        let validate = integration.scopeValidation(context: context, scope: scope)
        let result = try await client.translate(input, to: to, context: scope.contextMessages.map(\.text), configuration: configuration, native: { input, language in
            try await validate()
            return try await native.translate(input, to: language)
        })
        return (result.text.text, result.provider == .telegram ? native.resultEntities : exteralessAIRestoredEntities(result.text, originals: entities))
    }

    private func isPremium(_ context: AccountContext) async throws -> Bool {
        let peer = try await ExteralessAISignalOperation<EnginePeer?>().value(context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId)))
        return peer?.isPremium ?? false
    }
    private func source(_ text: ComposedRichMessage) async throws -> (formatted: AIFormattedText, entities: [MessageTextEntity], rich: Bool) {
        switch text {
        case .empty: return (.init(text: ""), [], false)
        case let .plain(text, entities):
            return (try exteralessAIFormattedInput(.init(text: text, entities: entities)), entities, false)
        case let .rich(page):
            return (.init(text: try await ExteralessAIRichTextTranslator.markdown(page: page)), [], true)
        }
    }
    private func style(_ reference: TelegramComposeAIMessageMode.StyleReference, styles: [TelegramComposeAIMessageMode.CloudStyle]) throws -> String? {
        switch reference {
        case .neutral: return nil
        case let .prompt(prompt): return prompt.isEmpty ? nil : "following this style: " + prompt
        case let .style(reference):
            if case let .standard(id) = reference, let tone = AITextAction.tones.first(where: { $0.id == id }) { return tone.prompt }
            guard let style = styles.first(where: { $0.reference == reference }) else { throw AIError.configuration }
            switch style.content {
            case let .standard(value): return "in a " + value.title + " style"
            case let .custom(value):
                if let prompt = value.prompt, !prompt.isEmpty { return "following this style: " + prompt }
                return "in a " + value.title + " style"
            }
        }
    }

    private func completion<E>(_ signal: Signal<Never, E>, mapError: @escaping (E) -> Error = { _ in AIError.network }) async throws {
        let value = Signal<Void, E> { subscriber in
            signal.start(error: { subscriber.putError($0) }, completed: { subscriber.putNext(Void()); subscriber.putCompletion() })
        }
        _ = try await ExteralessAISignalOperation<Void>().value(value, mapError: mapError)
    }

    private func signal<Value, Failure>(context: AccountContext, tag: String? = nil, lease: AINativeOperationLease? = nil, error mapFailure: @escaping (Error) -> Failure, operation: @escaping @MainActor (AINativeOperationLease) async throws -> Value) -> Signal<Value, Failure> {
        let generation = self.generation
        return exteralessAINativeRequest(lease: lease, isCurrent: { [weak self] in
            self?.generation == generation && self?.integration?.owns(context) == true
        }, started: { [weak self] id, token in
            self?.operations[id] = (token, tag)
        }, ended: { [weak self] id in
            self?.operations.removeValue(forKey: id)
        }, error: mapFailure, operation: operation)
    }
}

private struct ExteralessAIForwardedError: Error, @unchecked Sendable {
    let compose: TelegramAIComposeMessageError?
    let summary: SummarizeError?
    init(compose: TelegramAIComposeMessageError? = nil, summary: SummarizeError? = nil) { self.compose = compose; self.summary = summary }
}
