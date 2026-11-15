import Foundation

public struct PluginTLHookDecision: Equatable, Sendable {
    public var strategy: HookStrategy
    public var valueJSON: String?

    public init(strategy: HookStrategy = .default, valueJSON: String? = nil) {
        self.strategy = strategy
        self.valueJSON = valueJSON
    }
}

/// Data and native validator for one awaiting TL event. No TelegramApi dependency
/// reaches Host; the caller's cancellation predicate is rechecked on the C worker.
public struct PluginTLHostPayload: Equatable, Sendable {
    private let identity = UUID()
    public let kind: ExtensionPointKind
    public let account: Int32
    public let name: String
    public let canonicalName: String
    public var valueJSON: String
    public let metadataJSON: String
    public let errorJSON: String?
    public let canCancel: Bool
    public let originPluginIds: [String]
    public let originRootId: String?
    public let normalize: @Sendable (String) throws -> String
    public let shouldExecute: @Sendable () -> Bool

    public init(kind: ExtensionPointKind, account: Int32, name: String, canonicalName: String,
                valueJSON: String, metadataJSON: String, errorJSON: String?, canCancel: Bool,
                originPluginIds: [String] = [], originRootId: String? = nil,
                normalize: @escaping @Sendable (String) throws -> String,
                shouldExecute: @escaping @Sendable () -> Bool) {
        self.kind = kind
        self.account = account
        self.name = name
        self.canonicalName = canonicalName
        self.valueJSON = valueJSON
        self.metadataJSON = metadataJSON
        self.errorJSON = errorJSON
        self.canCancel = canCancel
        self.originPluginIds = originPluginIds
        self.originRootId = originRootId
        self.normalize = normalize
        self.shouldExecute = shouldExecute
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }

    public var valueField: String {
        switch self.kind {
        case .preRequest: return "request"
        case .postRequest: return "response"
        case .update: return "update"
        case .updates: return "updates"
        default: return "value"
        }
    }

    public var phase: String {
        switch self.kind {
        case .preRequest: return "preRequest"
        case .postRequest: return "postRequest"
        case .update: return "update"
        case .updates: return "updates"
        default: return "invalid"
        }
    }

    func validate() throws {
        guard [.preRequest, .postRequest, .update, .updates].contains(self.kind), self.account >= 0,
              !self.name.isEmpty, self.name.utf8.count <= 256, !self.canonicalName.isEmpty, self.canonicalName.utf8.count <= 256,
              self.valueJSON.utf8.count <= 16 * 1024 * 1024, self.metadataJSON.utf8.count <= 64 * 1024,
              (self.errorJSON?.utf8.count ?? 0) <= 64 * 1024,
              self.originPluginIds.count <= 32, self.originPluginIds.allSatisfy(Plugin.isValidID),
              Set(self.originPluginIds).count == self.originPluginIds.count,
              self.originPluginIds.isEmpty || self.originRootId != nil,
              self.originRootId == nil || self.originRootId?.isEmpty == false,
              (self.originRootId?.utf8.count ?? 0) <= 128 else {
            throw PluginHostError.runtimeFailure("Malformed or oversized TL transform payload")
        }
        _ = try PluginRuntimeScript.jsonValue(self.valueJSON)
        guard try PluginRuntimeScript.jsonValue(self.metadataJSON) is [String: Any] else {
            throw PluginHostError.runtimeFailure("TL transform metadata must be an object")
        }
        if let errorJSON { _ = try PluginRuntimeScript.jsonValue(errorJSON) }
    }

    func decision(_ source: String) throws -> PluginTLHookDecision {
        guard source.utf8.count <= 16 * 1024 * 1024,
              let raw = try PluginRuntimeScript.jsonValue(source) as? [String: Any],
              let name = raw["strategy"] as? String, let strategy = HookStrategy(rawValue: name),
              Set(raw.keys).isSubset(of: ["strategy", self.valueField, "params"]) else {
            throw PluginHostError.runtimeFailure("Malformed TL hook result")
        }
        guard strategy == .modify || strategy == .modifyFinal else {
            return PluginTLHookDecision(strategy: strategy)
        }
        guard let replacement = raw[self.valueField] ?? raw["params"] else {
            throw PluginHostError.runtimeFailure("TL modification omitted its value")
        }
        let candidate = try PluginRuntimeScript.encodeJSON(replacement)
        if let other = raw["params"], raw[self.valueField] != nil,
           try PluginRuntimeScript.encodeJSON(other) != candidate {
            throw PluginHostError.runtimeFailure("Ambiguous TL modification")
        }
        return PluginTLHookDecision(strategy: strategy, valueJSON: try self.normalize(candidate))
    }
}
