import Foundation

/// Public-filter cache, separate from user preferences just as LinkCleaner.FILE is on Android.
/// Call configure/install/reset on a worker. Navigation and composer reads only take the cache lock.
public final class ChatTrackingRulesStore: @unchecked Sendable {
    public struct Info: Sendable {
        public let ruleCount: Int
        public let ignoredRuleCount: Int
        public let updated: String?
        public let isOverride: Bool
        public let isFallback: Bool
    }

    public static let shared = ChatTrackingRulesStore()
    private let writerLock = NSLock()
    private let cacheLock = NSLock()
    private var rules: ChatAdGuardRules
    private var info: Info
    private var configuredURL: URL?

    public init() {
        let rules = try! ChatAdGuardRules(source: ChatAdGuardRules.fallbackSource)
        self.rules = rules
        self.info = Info(ruleCount: rules.ruleCount, ignoredRuleCount: rules.ignoredRuleCount, updated: nil, isOverride: false, isFallback: true)
    }

    public func snapshot() -> Info {
        self.cacheLock.lock()
        defer { self.cacheLock.unlock() }
        return self.info
    }

    public func clean(_ url: String) -> String {
        self.cacheLock.lock()
        let rules = self.rules
        self.cacheLock.unlock()
        return rules.clean(url)
    }

    public func configure(overrideURL: URL, bundledURL: URL?) throws {
        self.writerLock.lock()
        defer { self.writerLock.unlock() }
        guard overrideURL.isFileURL else { throw ChatTrackingRulesError.storage }
        if self.configuredURL == overrideURL { return }
        let useOverride = FileManager.default.fileExists(atPath: overrideURL.path)
        let sourceURL = useOverride ? overrideURL : bundledURL
        let rules: ChatAdGuardRules
        if let sourceURL { rules = try Self.read(sourceURL, requireUpdatedDate: true) }
        else { rules = try ChatAdGuardRules(source: ChatAdGuardRules.fallbackSource) }
        self.publish(rules, isOverride: useOverride, isFallback: sourceURL == nil)
        self.configuredURL = overrideURL
    }

    public func install(source: String, overrideURL: URL, shouldCommit: @Sendable () -> Bool = { true }) throws {
        self.writerLock.lock()
        defer { self.writerLock.unlock() }
        let rules = try ChatAdGuardRules(source: source, requireUpdatedDate: true)
        guard shouldCommit() else { throw ChatTrackingRulesError.cancelled }
        guard overrideURL.isFileURL else { throw ChatTrackingRulesError.storage }
        do {
            try FileManager.default.createDirectory(at: overrideURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(source.utf8).write(to: overrideURL, options: .atomic)
        } catch { throw ChatTrackingRulesError.storage }
        self.publish(rules, isOverride: true, isFallback: false)
        self.configuredURL = overrideURL
    }

    public func reset(overrideURL: URL, bundledURL: URL?) throws {
        self.writerLock.lock()
        defer { self.writerLock.unlock() }
        let rules: ChatAdGuardRules
        if let bundledURL { rules = try Self.read(bundledURL, requireUpdatedDate: true) }
        else { rules = try ChatAdGuardRules(source: ChatAdGuardRules.fallbackSource) }
        do {
            guard overrideURL.isFileURL else { throw ChatTrackingRulesError.storage }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: overrideURL.path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue else { throw ChatTrackingRulesError.storage }
                try FileManager.default.removeItem(at: overrideURL)
            }
        } catch { throw ChatTrackingRulesError.storage }
        self.publish(rules, isOverride: false, isFallback: bundledURL == nil)
        self.configuredURL = overrideURL
    }

    private static func read(_ url: URL, requireUpdatedDate: Bool) throws -> ChatAdGuardRules {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(ChatAdGuardRules.maximumSourceBytes) else { throw ChatTrackingRulesError.tooLarge }
            let data = try Data(contentsOf: url)
            guard data.count <= ChatAdGuardRules.maximumSourceBytes else { throw ChatTrackingRulesError.tooLarge }
            guard let source = String(data: data, encoding: .utf8) else { throw ChatTrackingRulesError.invalidFilter }
            return try ChatAdGuardRules(source: source, requireUpdatedDate: requireUpdatedDate)
        } catch let error as ChatTrackingRulesError { throw error }
        catch { throw ChatTrackingRulesError.storage }
    }

    private func publish(_ rules: ChatAdGuardRules, isOverride: Bool, isFallback: Bool) {
        self.cacheLock.lock()
        self.rules = rules
        self.info = Info(ruleCount: rules.ruleCount, ignoredRuleCount: rules.ignoredRuleCount, updated: rules.updated, isOverride: isOverride, isFallback: isFallback)
        self.cacheLock.unlock()
    }
}

public enum ChatLinkConfirmationPolicy {
    /// Explicit caller skipping and the existing mandatory URL checks retain their semantics.
    public static func shouldConfirm(concealed: Bool, mandatory: Bool, callerSkipped: Bool, confirmAll: Bool, skipBasic: Bool) -> Bool {
        if callerSkipped { return false }
        if mandatory || confirmAll { return true }
        return concealed && !skipBasic
    }
}

/// A successful in-app confirmation can feed the external opener without displaying a second
/// prompt. The exact-URL ticket is one-shot, short-lived and never persisted or logged.
public final class ChatLinkConfirmationLedger: @unchecked Sendable {
    public static let shared = ChatLinkConfirmationLedger()
    private let lock = NSLock()
    private var deadlines: [String: TimeInterval] = [:]
    public init() {}
    public func note(_ url: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard url.utf8.count <= 8192 else { return }
        self.lock.lock()
        defer { self.lock.unlock() }
        self.deadlines = self.deadlines.filter { $0.value > now }
        self.deadlines[url] = now + 15
        if self.deadlines.count > 64, let oldest = self.deadlines.min(by: { $0.value < $1.value })?.key { self.deadlines.removeValue(forKey: oldest) }
    }
    public func consume(_ url: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        let deadline = self.deadlines.removeValue(forKey: url)
        return deadline.map { $0 > now } ?? false
    }
    public func clear() {
        self.lock.lock()
        self.deadlines.removeAll()
        self.lock.unlock()
    }
}
