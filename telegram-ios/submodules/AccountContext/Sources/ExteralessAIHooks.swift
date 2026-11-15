import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore

@MainActor
public protocol ExteralessAIEngineAdapter: AnyObject, Sendable {
    func handles(context: AccountContext) -> Bool
    func compose(context: AccountContext, text: ComposedRichMessage, mode: TelegramComposeAIMessageMode, styles: [TelegramComposeAIMessageMode.CloudStyle], sourceLanguage: String?, capability: ExteralessAIProcessingCapability) -> Signal<TelegramAIComposeMessageResult, TelegramAIComposeMessageError>?
    func transcribe(context: AccountContext, messageId: EngineMessage.Id, file: TelegramMediaFile, lease: AINativeOperationLease?) -> Signal<Bool, ExteralessAITranscriptionError>?
    func summarize(context: AccountContext, messageId: EngineMessage.Id, toLanguage: String?) -> Signal<Never, SummarizeError>?
    func translateMessages(context: AccountContext, messageIds: [EngineMessage.Id], fromLanguage: String?, toLanguage: String, automatic: Bool) -> Signal<Never, TranslationError>?
    func articleController(context: AccountContext, text: String, entities: [MessageTextEntity], toLanguage: String?) -> ViewController?
}

private final class AIHookStorage: @unchecked Sendable {
    struct Lease: Sendable { let id: UUID; let adapter: (any ExteralessAIEngineAdapter)? }
    private let lock = NSLock()
    private var current = Lease(id: UUID(), adapter: nil)
    func install(_ adapter: (any ExteralessAIEngineAdapter)?) {
        lock.lock(); defer { lock.unlock() }
        if current.adapter === adapter { return }
        current = Lease(id: UUID(), adapter: adapter)
    }
    func capture() -> Lease { lock.lock(); defer { lock.unlock() }; return current }
    func valid(_ lease: Lease) -> Bool { lock.lock(); defer { lock.unlock() }; return current.id == lease.id }
}

/// AccountContext-level routing keeps lower UI components independent of TelegramUI.
/// Queued/disposed requests cannot start a fallback on a newly selected account.
public enum ExteralessAIHooks {
    public static var aiEditorVisible: Bool { !AINativeVisibilityPolicy().hideAiEditor }
    public static var messageSummaryVisible: Bool { !AINativeVisibilityPolicy().hideMessageSummary }

    private static let storage = AIHookStorage()
    private static let pageCache = AITranslatedPageCache()
    public static func renderedPage(original: InstantPage, translated: InstantPage, includeOriginal: Bool) -> InstantPage {
        includeOriginal ? pageCache.page(original: original, translated: translated) : translated
    }
    @MainActor public static func install(_ adapter: (any ExteralessAIEngineAdapter)?) { storage.install(adapter) }

    private static func deferred<Value, Failure>(context: AccountContext, cancelled: Failure, choose: @escaping @MainActor (any ExteralessAIEngineAdapter) -> Signal<Value, Failure>?, fallback: @escaping () -> Signal<Value, Failure>) -> Signal<Value, Failure> {
        let lease = storage.capture()
        return Signal { subscriber in
            let disposed = Atomic(value: false)
            let disposable = MetaDisposable()
            Queue.mainQueue().async {
                guard !disposed.with({ $0 }) else { return }
                MainActor.assumeIsolated {
                    guard storage.valid(lease) else { subscriber.putError(cancelled); return }
                    let selected: Signal<Value, Failure>
                    if let adapter = lease.adapter {
                        guard adapter.handles(context: context) else { subscriber.putError(cancelled); return }
                        selected = choose(adapter) ?? fallback()
                    } else { selected = fallback() }
                    guard !disposed.with({ $0 }) else { return }
                    disposable.set(selected.start(next: { subscriber.putNext($0) }, error: { subscriber.putError($0) }, completed: { subscriber.putCompletion() }))
                }
            }
            return ActionDisposable { _ = disposed.swap(true); disposable.dispose() }
        }
    }

    public static func compose(context: AccountContext, text: ComposedRichMessage, mode: TelegramComposeAIMessageMode, styles: [TelegramComposeAIMessageMode.CloudStyle], sourceLanguage: String?, capability: ExteralessAIProcessingCapability, fallback: @escaping () -> Signal<TelegramAIComposeMessageResult, TelegramAIComposeMessageError>) -> Signal<TelegramAIComposeMessageResult, TelegramAIComposeMessageError> {
        deferred(context: context, cancelled: .generic, choose: { adapter in
            guard capability.allowsExternalProcessing else { return nil }
            return adapter.compose(context: context, text: text, mode: mode, styles: styles, sourceLanguage: sourceLanguage, capability: capability)
        }, fallback: fallback)
    }
    public static func usesSelectedTranscription(isPremium: Bool, store: ClientSettings = .shared) -> Bool {
        AINativeSpeechPolicy.usesSelectedProvider(AITranscriptionProvider(rawValue: store.integer("ai.transcribeProvider")) ?? .auto, isPremium: isPremium)
    }
    public static func transcribe(context: AccountContext, messageId: EngineMessage.Id, file: TelegramMediaFile) -> Signal<Bool, ExteralessAITranscriptionError> {
        deferred(context: context, cancelled: .cancelled, choose: { $0.transcribe(context: context, messageId: messageId, file: file, lease: nil) }, fallback: { .fail(.nativeFailed) })
    }
    /// Copy/share/insert at a stock surface recheck the real source immediately
    /// before delivery. Nil copyResult and cached UI flags are not capabilities.
    public static func withCopyCapability(context: AccountContext, capability: ExteralessAIProcessingCapability, perform: @escaping @MainActor () -> Void) {
        let owner = storage.capture()
        Task { @MainActor in
            guard capability.allowsCopy, storage.valid(owner) else { return }
            if let adapter = owner.adapter, !adapter.handles(context: context) { return }
            let lease = AINativeOperationLease()
            defer { lease.cancel() }
            guard let scope = await context.engine.messages.resolveExteralessAIScope(capability: capability, lease: lease).get(), scope.allowsCopy else { return }
            let valid = await context.engine.messages.validateExteralessAIScope(scope).get()
            guard valid, !Task.isCancelled, storage.valid(owner) else { return }
            if let adapter = owner.adapter, !adapter.handles(context: context) { return }
            perform()
        }
    }
    public static func summarize(context: AccountContext, messageId: EngineMessage.Id, toLanguage: String?, fallback: @escaping () -> Signal<Never, SummarizeError>) -> Signal<Never, SummarizeError> {
        deferred(context: context, cancelled: .generic, choose: { $0.summarize(context: context, messageId: messageId, toLanguage: toLanguage) }, fallback: fallback)
    }
    public static func translateMessages(context: AccountContext, messageIds: [EngineMessage.Id], fromLanguage: String?, toLanguage: String, automatic: Bool, fallback: @escaping () -> Signal<Never, TranslationError>) -> Signal<Never, TranslationError> {
        deferred(context: context, cancelled: .generic, choose: { $0.translateMessages(context: context, messageIds: messageIds, fromLanguage: fromLanguage, toLanguage: toLanguage, automatic: automatic) }, fallback: fallback)
    }
    @MainActor public static func articleController(context: AccountContext, text: String, entities: [MessageTextEntity], toLanguage: String?) -> ViewController? {
        guard let adapter = storage.capture().adapter, adapter.handles(context: context) else { return nil }
        return adapter.articleController(context: context, text: text, entities: entities, toLanguage: toLanguage)
    }
    public static func policyChanges() -> Signal<Void, NoError> {
        Signal { subscriber in
            let observation = ClientSettings.shared.observe { keys in
                if keys.isEmpty || keys.contains("ai.telegramUIAutoTranslate") || keys.contains("ai.translationProvider") { subscriber.putNext(Void()) }
            }
            subscriber.putNext(Void())
            return ActionDisposable { observation.cancel() }
        } |> deliverOnMainQueue
    }
}

private final class AITranslatedPageCache: @unchecked Sendable {
    private struct Key: Hashable { let original: ObjectIdentifier; let translated: ObjectIdentifier }
    private struct Value { let original: InstantPage; let translated: InstantPage; let combined: InstantPage }
    private let lock = NSLock()
    private var values: [Key: Value] = [:]
    private var order: [Key] = []
    func page(original: InstantPage, translated: InstantPage) -> InstantPage {
        lock.lock(); defer { lock.unlock() }
        let key = Key(original: ObjectIdentifier(original), translated: ObjectIdentifier(translated))
        if let value = values[key] { return value.combined }
        var media = original.media
        for (id, value) in translated.media { media[id] = value }
        let combined = InstantPage(blocks: original.blocks + [.divider] + translated.blocks, media: media, isComplete: translated.isComplete, rtl: translated.rtl, url: translated.url, views: translated.views)
        values[key] = Value(original: original, translated: translated, combined: combined)
        order.append(key)
        if order.count > 32 { values.removeValue(forKey: order.removeFirst()) }
        return combined
    }
}
