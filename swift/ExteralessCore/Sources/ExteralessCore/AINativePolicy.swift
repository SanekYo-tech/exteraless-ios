import Foundation

/// Shared by native tasks and their queued Postbox commits. Cancelling a Signal
/// alone does not cancel a transaction that has already been enqueued.
public final class AINativeOperationLease: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var cancelled = false
    private var cancellation: (@Sendable () -> Void)?

    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func bind(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        let cancelled = self.cancelled
        if !cancelled { cancellation = action }
        lock.unlock()
        if cancelled { action() }
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let action = cancellation
        cancellation = nil
        lock.unlock()
        action?()
    }

    /// The short, synchronous mutation and cancellation have one ordering point.
    /// Never suspend, perform I/O or call UI from this body.
    public func withActive<T>(_ body: () throws -> T) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return nil }
        return try body()
    }
}

/// Per-message request identity. In particular, A's late error cannot retire B,
/// including after B has completed. Bind also handles synchronous completion.
public final class AINativeOperationRegistry<Key: Hashable>: @unchecked Sendable {
    private struct Entry {
        let generation: UUID
        var cancel: (() -> Void)?
    }
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    public init() {}
    public func begin(_ key: Key) -> UUID {
        lock.lock()
        let previous = entries.removeValue(forKey: key)
        let generation = UUID()
        entries[key] = Entry(generation: generation)
        lock.unlock()
        previous?.cancel?()
        return generation
    }
    public func bind(_ key: Key, generation: UUID, cancel: @escaping () -> Void) {
        lock.lock()
        let current = entries[key]?.generation == generation
        if current { entries[key]?.cancel = cancel }
        lock.unlock()
        if !current { cancel() }
    }
    @discardableResult public func finish(_ key: Key, generation: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard entries[key]?.generation == generation else { return false }
        entries.removeValue(forKey: key)
        return true
    }
    public func cancel(_ key: Key) {
        lock.lock()
        let entry = entries.removeValue(forKey: key)
        lock.unlock()
        entry?.cancel?()
    }
    public func cancelAll() {
        lock.lock()
        let previous = entries
        entries.removeAll()
        lock.unlock()
        for entry in previous.values { entry.cancel?() }
    }
    deinit { cancelAll() }
}

public struct AINativeDisplaySelection: Equatable, Sendable {
    public enum Origin: Equatable, Sendable { case original, manual, automatic }
    public let language: String?
    public let origin: Origin
    public let keepsOriginal: Bool
    public let canHideManual: Bool

    public init(policy: AITranslationPolicy, manual: AIManualTranslationState?, manualAvailable: Bool, automaticLanguage: String?, incoming: Bool, enabled: Bool = true) {
        let automatic = enabled && policy.autoEnabled && incoming ? automaticLanguage : nil
        if enabled, manualAvailable, let manual, manual.visible {
            language = manual.language
            origin = .manual
        } else if let automatic {
            language = automatic
            origin = .automatic
        } else {
            language = nil
            origin = .original
        }
        keepsOriginal = policy.keepsOriginal(manual: origin == .manual, automatic: origin == .automatic)
        // Hiding a manual override does not hide an enabled incoming auto route.
        canHideManual = origin == .manual && automatic == nil
    }
}

/// The single target calculation used by history rendering and message actions.
/// Normalization follows the native TranslateUI base-language/nb -> no rule.
public enum AINativeTranslationTarget {
    public static func normalize(_ code: String) -> String {
        let base = code.split(separator: "-", omittingEmptySubsequences: false).first.map(String.init) ?? code
        return base == "nb" ? "no" : base
    }

    public static func resolve(isEnabled: Bool, toLanguage: String?, appLanguage: String, isPremium: Bool, peerAutoTranslate: Bool, policy: AITranslationPolicy) -> String? {
        guard isEnabled, policy.autoEnabled, policy.canAutomaticallyTranslate(isPremium: isPremium) || peerAutoTranslate else { return nil }
        return normalize(toLanguage ?? appLanguage)
    }
}

public enum AINativeContextPolicy {
    public static func enabled(policy: AITranslationPolicy, purpose: AITranslationPurpose, effectiveProvider: AITranslationProvider) -> Bool {
        effectiveProvider == .llm && policy.useContext && (purpose != .automatic || policy.useAutoContext)
    }
    public static func includesPrecedingHistory(purpose: AITranslationPurpose) -> Bool { purpose == .manual }
    /// Bounds visited IDs, not just nonempty text results (media-only replies count).
    public static func visitLimit(messageLimit: Int) -> Int { min(50, max(0, messageLimit)) }
}

public enum AINativeTranscriptionRoute: Equatable, Sendable {
    case telegram
    case provider(AITranscriptionProvider)
}

public enum AINativeSpeechPolicy {
    /// TranscribeHelper.useTranscribeAI + sendRequest. Auto on Premium is Telegram;
    /// auto otherwise chooses Gemini, configured compatible audio, then Workers.
    /// Missing Workers credentials are a setup error, not an implicit Apple route.
    public static func route(configuration: AITranscriptionConfiguration, isPremium: Bool) -> AINativeTranscriptionRoute {
        if configuration.provider != .auto { return .provider(configuration.provider) }
        if isPremium { return .telegram }
        if !configuration.geminiKey.isEmpty { return .provider(.gemini) }
        if !configuration.openAIBaseURL.isEmpty && !configuration.openAIModel.isEmpty && !configuration.openAIKey.isEmpty { return .provider(.openAI) }
        return .provider(.workersAI)
    }
    public static func usesSelectedProvider(_ provider: AITranscriptionProvider, isPremium: Bool) -> Bool {
        provider != .auto || !isPremium
    }
    public static func isConfigured(_ provider: AITranscriptionProvider, configuration: AITranscriptionConfiguration) -> Bool {
        switch provider {
        case .auto: return false
        case .workersAI: return !configuration.cloudflareAccountId.isEmpty && !configuration.cloudflareToken.isEmpty
        case .gemini: return !configuration.geminiKey.isEmpty && !configuration.geminiModel.isEmpty
        case .openAI: return !configuration.openAIBaseURL.isEmpty && !configuration.openAIModel.isEmpty && !configuration.openAIKey.isEmpty
        case .apple: return true // Actual authorization/language readiness is checked by Speech.
        }
    }
}

/// Structural budget used by the real InstantPage mapper, before reserving output
/// arrays. Empty cells, rows, unknown list items and opaque children all count.
public struct AINativeGraphBudget {
    public let maximumNodes: Int
    public let maximumDepth: Int
    public private(set) var visited = 0
    public init(maximumNodes: Int = 8192, maximumDepth: Int = 48) {
        self.maximumNodes = max(0, maximumNodes)
        self.maximumDepth = max(0, maximumDepth)
    }
    public func checkCollection(count: Int, depth: Int) throws {
        try Task.checkCancellation()
        guard count >= 0, depth <= maximumDepth, count <= maximumNodes - visited else { throw AIError.inputTooLarge }
    }
    public mutating func visit(depth: Int, count: Int = 1) throws {
        try checkCollection(count: count, depth: depth)
        visited += count
    }
}
