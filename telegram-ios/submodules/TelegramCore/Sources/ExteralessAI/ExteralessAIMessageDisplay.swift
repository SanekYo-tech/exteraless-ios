import ExteralessCore
import Foundation
import Postbox

/// One native display decision for renderers, Copy, selection/AI input and speech.
/// Permissions are supplied separately by the current engine scope, never inferred
/// from the presence of a cached translation or a manual marker.
public struct ExteralessAIMessageDisplay {
    public let selection: AINativeDisplaySelection
    private let resolvedText: String
    // Rich render passes only consume `page`; do not flatten the entire graph on
    // every layout just to expose a string to Copy/AI actions that may never run.
    public var text: String { page?.plainText ?? resolvedText }
    public let entities: [MessageTextEntity]
    public let page: InstantPage?
    public let translation: TranslationMessageAttribute?
    public let isSummary: Bool
    public let isTranslating: Bool
    public let pollTitle: TranslationMessageAttribute.Additional?
    public let pollOptions: [TranslationMessageAttribute.Additional]
    public let pollSolution: TelegramMediaPollResults.Solution?

    private init(selection: AINativeDisplaySelection, text: String, entities: [MessageTextEntity], page: InstantPage?, translation: TranslationMessageAttribute?, isSummary: Bool, isTranslating: Bool, pollTitle: TranslationMessageAttribute.Additional?, pollOptions: [TranslationMessageAttribute.Additional], pollSolution: TelegramMediaPollResults.Solution?) {
        self.selection = selection
        self.resolvedText = text
        self.entities = entities
        self.page = page
        self.translation = translation
        self.isSummary = isSummary
        self.isTranslating = isTranslating
        self.pollTitle = pollTitle
        self.pollOptions = pollOptions
        self.pollSolution = pollSolution
    }

    public static func resolve(message: EngineMessage, accountId: Int64, accountPeerId: EnginePeer.Id, automaticLanguage: String?, isSummarized: Bool = false, richExpanded: Bool = false, displayedRichPage: InstantPage? = nil, enabled: Bool = true, store: ClientSettings = .shared) -> ExteralessAIMessageDisplay {
        let raw = message._asMessage()
        let policy = AITranslationPolicy(store: store)
        let marker = AIManualTranslations.state(accountId: String(accountId), messageKey: AIManualTranslations.messageKey(peerId: message.id.peerId.toInt64(), namespace: message.id.namespace, id: message.id.id), store: store)
        let rich = raw.richText
        let translations = raw.attributes.compactMap { $0 as? TranslationMessageAttribute }.filter { value in
            ExteralessAIRichSource.isUsableTranslation(value, for: rich)
        }
        let summary = raw.attributes.first { $0 is SummarizationMessageAttribute } as? SummarizationMessageAttribute
        // An edit invalidates the native attribute. An old marker must not turn
        // the edited message into an unfinishable manual-translation spinner.
        let manualAvailable = marker.map { marker in
            translations.contains { $0.toLang == marker.language && (raw.richText == nil ? !$0.text.isEmpty : $0.instantPage != nil) }
                || (isSummarized && summary?.summaryForLang(marker.language) != nil)
        } ?? false
        let selection = AINativeDisplaySelection(policy: policy, manual: marker, manualAvailable: manualAvailable, automaticLanguage: automaticLanguage, incoming: raw.effectivelyIncoming(accountPeerId), enabled: enabled)
        let translation = translations.first { $0.toLang == selection.language }
        let originalEntities = raw.textEntitiesAttribute?.entities ?? []
        let transcript = raw.attributes.first { $0 is AudioTranscriptionMessageAttribute } as? AudioTranscriptionMessageAttribute
        let originalText = raw.text.isEmpty ? transcript?.text ?? "" : raw.text

        if enabled && isSummarized {
            // Keep an open summary a summary while its requested language is being
            // produced. Never substitute the full message's translation here.
            if let value = summary?.summaryForLang(selection.language) ?? summary?.summary {
                let translated = selection.language != nil && summary?.summaryForLang(selection.language) != nil
                let display = compose(original: summary?.summary?.text ?? "", originalEntities: summary?.summary?.entities ?? [], translated: value.text, translatedEntities: value.entities, includeOriginal: translated && selection.keepsOriginal)
                return ExteralessAIMessageDisplay(selection: selection, text: display.0, entities: display.1, page: nil, translation: translation, isSummary: true, isTranslating: false, pollTitle: nil, pollOptions: [], pollSolution: nil)
            }
            return ExteralessAIMessageDisplay(selection: selection, text: originalText, entities: originalEntities, page: displayedRichPage ?? rich.map { ExteralessAIRichSource.displayedOriginal($0, expanded: richExpanded) }, translation: nil, isSummary: false, isTranslating: true, pollTitle: nil, pollOptions: [], pollSolution: nil)
        }

        if let poll = raw.media.first(where: { $0 is TelegramMediaPoll }) as? TelegramMediaPoll {
            let translated = translation.flatMap { value in
                !value.text.isEmpty && value.additional.count == poll.options.count ? value : nil
            }
            let title = TranslationMessageAttribute.Additional(text: translated?.text ?? poll.text, entities: translated?.entities ?? poll.textEntities)
            let options = translated?.additional ?? poll.options.map { .init(text: $0.text, entities: $0.entities) }
            let solution: TelegramMediaPollResults.Solution?
            if let original = poll.results.solution, let value = translated?.pollSolution {
                solution = .init(text: value.text, entities: value.entities, media: original.media)
            } else { solution = poll.results.solution }
            var text = title.text
            var entities = title.entities
            for option in options {
                let offset = text.utf16.count + "\n— ".utf16.count
                text += "\n— " + option.text
                entities += shifted(option.entities, by: offset)
            }
            return ExteralessAIMessageDisplay(selection: selection, text: text, entities: entities, page: nil, translation: translated, isSummary: false, isTranslating: selection.language != nil && translated == nil, pollTitle: title, pollOptions: options, pollSolution: solution)
        }

        if let rich {
            let original = ExteralessAIRichSource.displayedOriginal(rich, expanded: richExpanded)
            let page = displayedRichPage ?? translation?.instantPage.map { translated in
                let prefix = translated.isComplete ? ExteralessAIRichSource.wholePage(rich) : original
                return selection.keepsOriginal ? pageCache.page(original: prefix, translated: translated) : translated
            } ?? original
            return ExteralessAIMessageDisplay(selection: selection, text: "", entities: [], page: page, translation: translation, isSummary: false, isTranslating: selection.language != nil && translation?.instantPage == nil, pollTitle: nil, pollOptions: [], pollSolution: nil)
        }

        let translated = translation.flatMap { $0.text.isEmpty ? nil : $0 }
        let display = translated.map {
            compose(original: originalText, originalEntities: originalEntities, translated: $0.text, translatedEntities: $0.entities, includeOriginal: transcript == nil && selection.keepsOriginal)
        } ?? (originalText, originalEntities)
        return ExteralessAIMessageDisplay(selection: selection, text: display.0, entities: display.1, page: nil, translation: translated, isSummary: false, isTranslating: selection.language != nil && translated == nil && !originalText.isEmpty, pollTitle: nil, pollOptions: [], pollSolution: nil)
    }

    public static func compose(original: String, originalEntities: [MessageTextEntity], translated: String, translatedEntities: [MessageTextEntity], includeOriginal: Bool) -> (String, [MessageTextEntity]) {
        guard includeOriginal, !original.isEmpty else { return (translated, translatedEntities) }
        let prefix = original + AITranslationPolicy.separator
        return (prefix + translated, originalEntities + shifted(translatedEntities, by: prefix.utf16.count))
    }

    private static func shifted(_ entities: [MessageTextEntity], by offset: Int) -> [MessageTextEntity] {
        entities.map { MessageTextEntity(range: ($0.range.lowerBound + offset) ..< ($0.range.upperBound + offset), type: $0.type) }
    }

    private static let pageCache = ExteralessAIDisplayPageCache()
    private static let summaryPageCache = ExteralessAISummaryPageCache()

    /// TextFormat supplies its native entities -> ChatInputContent conversion.
    /// The bounded cache keeps the rich renderer's page identity stable per frame.
    public func richSummaryPage(make: (String, [MessageTextEntity]) -> InstantPage) -> InstantPage? {
        guard isSummary else { return nil }
        return Self.summaryPageCache.page(text: text, entities: entities, make: make)
    }
}

private final class ExteralessAISummaryPageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(text: String, entities: [MessageTextEntity], page: InstantPage)] = []
    func page(text: String, entities: [MessageTextEntity], make: (String, [MessageTextEntity]) -> InstantPage) -> InstantPage {
        lock.lock(); defer { lock.unlock() }
        if let value = values.first(where: { $0.text == text && $0.entities == entities }) { return value.page }
        let page = make(text, entities)
        values.append((text, entities, page))
        if values.count > 16 { values.removeFirst() }
        return page
    }
}

private final class ExteralessAIDisplayPageCache: @unchecked Sendable {
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
