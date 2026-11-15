import Foundation

public enum AITranslationPurpose: String, Codable, Sendable {
    case manual, automatic, article, poll, input
}

public struct AITranslationPolicy: Sendable {
    public let showMessageTranslate: Bool
    public let showTextTranslate: Bool
    public let showLLMTranslate: Bool
    public let mode: Int
    public let autoEnabled: Bool
    public let keepPreferences: Bool
    public let useContext: Bool
    public let useAutoContext: Bool
    public let separateArticles: Bool
    public let provider: AITranslationProvider
    public let articleProvider: AITranslationProvider
    public let preferredLanguages: [String]

    public init(store: ClientSettings = .shared) {
        showMessageTranslate = store.bool("ai.showTranslate")
        showTextTranslate = store.bool("ai.showTextTranslate", default: true)
        showLLMTranslate = store.bool("ai.showTranslateMessageLLM")
        mode = store.integer("ai.translatorMode")
        autoEnabled = store.bool("ai.telegramUIAutoTranslate", default: true)
        keepPreferences = store.bool("ai.keepTranslatorPreferences")
        useContext = store.bool("ai.llmUseContext")
        useAutoContext = store.bool("ai.llmUseContextInAutoTranslate")
        separateArticles = store.bool("ai.enableSeparateArticleTranslator")
        provider = AITranslationProvider(rawValue: store.integer("ai.translationProvider", default: 1)) ?? .google
        articleProvider = AITranslationProvider(rawValue: store.integer("ai.articleTranslationProvider", default: 1)) ?? .google
        preferredLanguages = Self.parsePreferredLanguages(store.string("ai.preferredTranslateTargetLang"))
    }

    public func provider(for purpose: AITranslationPurpose) -> AITranslationProvider {
        let selected = purpose == .article && separateArticles ? articleProvider : provider
        // Translator.getBulkTranslateProvider. Manual poll translation can still
        // explicitly select a provider through the single-message route.
        return (purpose == .article || purpose == .poll || purpose == .automatic) && selected == .deepL ? .google : selected
    }

    public func usesContext(for purpose: AITranslationPurpose) -> Bool {
        useContext && (purpose != .automatic || useAutoContext) && provider(for: purpose) == .llm
    }

    public func canAutomaticallyTranslate(isPremium: Bool) -> Bool {
        autoEnabled && (isPremium || provider != .telegram)
    }

    public func keepsOriginal(manual: Bool, automatic: Bool) -> Bool {
        mode == 2 ? manual || automatic : mode == 1 && manual
    }

    public static let separator = "\n\n--------\n\n"

    public func display(original: AIFormattedText, translated: AIFormattedText, manual: Bool, automatic: Bool) -> AIFormattedText {
        guard !translated.text.isEmpty else { return original }
        guard !original.text.isEmpty, keepsOriginal(manual: manual, automatic: automatic) else { return translated }
        let offset = original.text.utf16.count + Self.separator.utf16.count
        var spans = original.spans
        let nextId = (spans.map(\.id).max() ?? -1) + 1
        spans += translated.spans.enumerated().map { index, span in
            var result = span
            result.id = nextId + index
            result.offset += offset
            return result
        }
        return AIFormattedText(text: original.text + Self.separator + translated.text, spans: spans)
    }

    public func languages(defaultLanguage: String, available: [String]) -> [String] {
        var seen = Set<String>()
        return ([defaultLanguage] + preferredLanguages + ["ja"] + available).compactMap { value in
            guard let normalized = Self.normalizedLanguage(value), seen.insert(normalized.lowercased()).inserted else { return nil }
            return normalized
        }
    }

    public func ignoredLanguagesAfterAppLanguageChange(current: [String], previous: String, next: String) -> [String] {
        guard !keepPreferences, let next = Self.normalizedLanguage(next) else { return current }
        let old = Self.normalizedLanguage(previous) ?? previous
        let containsNew = current.contains { $0.caseInsensitiveCompare(next) == .orderedSame }
        var output = current
        if !containsNew { output.removeAll { $0.caseInsensitiveCompare(old) == .orderedSame } }
        if !output.contains(where: { $0.caseInsensitiveCompare(next) == .orderedSame }) { output.append(next) }
        return output
    }

    public static func parsePreferredLanguages(_ value: String) -> [String] {
        var seen = Set<String>()
        return value.split(separator: ",", omittingEmptySubsequences: false).compactMap { raw in
            guard let code = normalizedLanguage(String(raw)), seen.insert(code.lowercased()).inserted else { return nil }
            return code
        }
    }

    public static func normalizedLanguage(_ value: String) -> String? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-").split(separator: "-", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(parts.count), let first = parts.first, (2 ... 8).contains(first.count),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57).contains($0) }) }) else { return nil }
        return parts.enumerated().map { index, part in
            if index == 0 { return part.lowercased() }
            if part.count == 4 { return part.prefix(1).uppercased() + part.dropFirst().lowercased() }
            return part.uppercased()
        }.joined(separator: "-")
    }
}

public enum AIReplacementPolicy {
    /// null/unset is the original account-dependent !isPremium default. Keeping
    /// that decision at request time also handles a Premium status change.
    public static func enabled(_ override: ClientSettingValue?, isPremium: Bool, configured: Bool) -> Bool {
        guard configured else { return false }
        if let override, case let .bool(value) = override { return value }
        return !isPremium
    }
}

public enum AITranslationModeMigration {
    public static let preparationDefinitions: [ClientSettingDefinition] = [
        .init(key: "ai.translatorMode", title: "Keep original with translation", section: "Translation", defaultValue: .integer(0)),
        .init(key: "ai.translatorModeWithOriginalMigrated", title: "Translation-mode migration completed", section: "AI state", defaultValue: .bool(false)),
        .init(key: "ai.translatorModeMigrationTarget", title: "Translation-mode migration journal", section: "AI state", defaultValue: .null)
    ]
    public static func mappedLegacyValue(_ value: Int) -> Int { value == 0 ? 1 : 0 }

    public static func apply(store: ClientSettings) throws {
        if store.bool("ai.translatorModeWithOriginalMigrated") {
            if !(0 ... 2).contains(store.integer("ai.translatorMode")) { try store.set(.integer(0), for: "ai.translatorMode") }
            return
        }
        let snapshot = store.readSnapshot()
        let target: Int
        if let stored = store.value("ai.translatorModeMigrationTarget"), case let .integer(value) = stored, let value = Int(exactly: value), (0 ... 2).contains(value) {
            target = value
        } else {
            target = snapshot.storedKeys.contains("ai.translatorMode") ? mappedLegacyValue(store.integer("ai.translatorMode")) : 0
            // Write-ahead journal makes a failure between the two following
            // writes replay the SAME target rather than flip 0/1 a second time.
            try store.set(.integer(Int64(target)), for: "ai.translatorModeMigrationTarget")
        }
        if store.integer("ai.translatorMode") != target { try store.set(.integer(Int64(target)), for: "ai.translatorMode") }
        try store.set(.bool(true), for: "ai.translatorModeWithOriginalMigrated")
        try store.reset("ai.translatorModeMigrationTarget")
    }
}

/// Only origin/visibility metadata, never message bodies. Raw translation remains
/// in Telegram's TranslationMessageAttribute, and rendering applies the mode at
/// display time. Both dictionaries are registered before their first native read.
public struct AIManualTranslationState: Codable, Equatable, Sendable {
    public var language: String
    public var visible: Bool
    public init(language: String, visible: Bool = true) { self.language = language; self.visible = visible }
}

public enum AIManualTranslations {
    private static let mutationLock = NSRecursiveLock()
    public static let maximumRecords = 2048
    private struct Record: Codable {
        var language: String
        var visible: Bool
        var sequence: UInt64
        private enum CodingKeys: String, CodingKey { case language, visible, sequence }

        init(_ state: AIManualTranslationState, sequence: UInt64) {
            language = state.language; visible = state.visible; self.sequence = sequence
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            language = try values.decode(String.self, forKey: .language)
            visible = try values.decode(Bool.self, forKey: .visible)
            sequence = try values.decodeIfPresent(UInt64.self, forKey: .sequence) ?? 0
        }
        var state: AIManualTranslationState { .init(language: language, visible: visible) }
    }
    public static func messageKey(peerId: Int64, namespace: Int32, id: Int32) -> String { "\(peerId):\(namespace):\(id)" }
    public static func register(accountId: String, store: ClientSettings = .shared) throws {
        guard Int64(accountId) != nil else { throw AIError.configuration }
        try store.register([.init(key: "ai.manualTranslations." + accountId, title: "Manual translation state", section: "AI state", defaultValue: .string(""), isSecret: true)])
    }
    public static func state(accountId: String, messageKey: String, store: ClientSettings = .shared) -> AIManualTranslationState? {
        (try? records(accountId: accountId, store: store)[messageKey])?.state
    }
    public static func set(_ state: AIManualTranslationState?, accountId: String, messageKey: String, store: ClientSettings = .shared) throws {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        try register(accountId: accountId, store: store)
        var records = try records(accountId: accountId, store: store)
        if let state {
            // Refresh on a mutation, not every renderer read. Compact the sequence
            // on overflow without changing its order; legacy records start at zero.
            if records.values.contains(where: { $0.sequence == UInt64.max }) {
                for (index, entry) in records.sorted(by: older).enumerated() { records[entry.key]?.sequence = UInt64(index + 1) }
            }
            let sequence = (records.values.map(\.sequence).max() ?? 0) + 1
            records[messageKey] = Record(state, sequence: sequence)
        } else { records.removeValue(forKey: messageKey) }
        if records.count > maximumRecords {
            // Hide is a reversible state, but hidden markers are the first eviction
            // candidates. Always retain the just-written marker, then newest visible
            // entries. Ties in a legacy dictionary use stable message-key order.
            let candidates = records.filter { $0.key != messageKey }.sorted {
                if $0.value.visible != $1.value.visible { return !$0.value.visible }
                return older($0, $1)
            }
            for entry in candidates.prefix(records.count - maximumRecords) { records.removeValue(forKey: entry.key) }
        }
        let data = try JSONEncoder().encode(records)
        try store.set(.string(String(decoding: data, as: UTF8.self)), for: "ai.manualTranslations." + accountId)
    }
    private static func older(_ lhs: (key: String, value: Record), _ rhs: (key: String, value: Record)) -> Bool {
        lhs.value.sequence == rhs.value.sequence ? lhs.key < rhs.key : lhs.value.sequence < rhs.value.sequence
    }
    private static func records(accountId: String, store: ClientSettings) throws -> [String: Record] {
        let raw = store.string("ai.manualTranslations." + accountId)
        if raw.isEmpty { return [:] }
        // A malformed secure item is preserved, rather than silently overwritten
        // with a one-entry dictionary during the next successful translation.
        guard let value = try? JSONDecoder().decode([String: Record].self, from: Data(raw.utf8)) else { throw AIError.configuration }
        return value
    }
}
