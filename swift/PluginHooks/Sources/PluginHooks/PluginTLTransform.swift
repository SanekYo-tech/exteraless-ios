import Foundation

public enum PluginTLTransformKind: String, Codable, Sendable, Hashable {
    case preRequest, postRequest, update, updates
}

/// Core supplies real TL JSON and a schema/identity validator. Metadata is separate
/// from the mutable value, so account, request identity and continuity are not patches.
public struct PluginTLTransformPayload: Sendable {
    public let kind: PluginTLTransformKind
    public let accountRecordId: Int64
    public let correlationId: String
    public let name: String
    public let valueJSON: String
    public let metadataJSON: String
    public let error: PluginRPCError?
    public let canCancel: Bool
    public let originPluginIds: [String]
    public let originRootId: String?
    private let normalize: @Sendable (String) throws -> String

    public init(kind: PluginTLTransformKind, accountRecordId: Int64, correlationId: String,
                name: String, valueJSON: String, metadataJSON: String, error: PluginRPCError? = nil,
                canCancel: Bool = true, originPluginIds: [String] = [], originRootId: String? = nil,
                normalize: @escaping @Sendable (String) throws -> String) {
        self.kind = kind
        self.accountRecordId = accountRecordId
        self.correlationId = correlationId
        self.name = name
        self.valueJSON = valueJSON
        self.metadataJSON = metadataJSON
        self.error = error
        self.canCancel = canCancel
        self.originPluginIds = originPluginIds
        self.originRootId = originRootId
        self.normalize = normalize
    }

    /// The host calls this after EACH MODIFY before passing a value to the next
    /// plugin. The router independently repeats it at the final native boundary.
    public func normalizedReplacement(_ json: String) throws -> String {
        return try self.normalize(json)
    }

    public func jsonString() throws -> String {
        var object: [String: Any] = [
            "schemaVersion": 1, "observational": false, "phase": self.kind.rawValue,
            "metadata": try JSONSerialization.jsonObject(with: Data(self.metadataJSON.utf8)),
            "tl": try JSONSerialization.jsonObject(with: Data(self.valueJSON.utf8), options: [.fragmentsAllowed]),
            "canCancel": self.canCancel
        ]
        if let error = self.error {
            object["tlError"] = ["_": "error", "code": error.code, "text": error.message]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}

public enum PluginTLTransformResult: Sendable, Equatable {
    case keepOriginal
    case cancel
    case modify(String)
    case modifyFinal(String)
    /// Admission/control failure. Core defines the phase-specific terminal policy.
    case failure(String)
}

public enum PluginTLTransformResultCodec {
    public enum Failure: Error { case malformed }

    /// Actual SDK dispatch_json returns strategy plus request/response/update/updates.
    /// A portable HookResult.params alias is accepted only when it is unambiguous.
    public static func decode(_ json: String, kind: PluginTLTransformKind) throws -> PluginTLTransformResult {
        guard json.utf8.count <= 16 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let strategy = object["strategy"] as? String else { throw Failure.malformed }
        let field: String
        switch kind { case .preRequest: field = "request"; case .postRequest: field = "response"; case .update: field = "update"; case .updates: field = "updates" }
        guard Set(object.keys).isSubset(of: ["strategy", field, "params"]) else { throw Failure.malformed }
        switch strategy {
        case "DEFAULT": return .keepOriginal
        case "CANCEL": return .cancel
        case "MODIFY", "MODIFY_FINAL":
            guard let value = object[field] ?? object["params"] else { throw Failure.malformed }
            let encoded = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            if let other = object["params"], object[field] != nil {
                guard try JSONSerialization.data(withJSONObject: other, options: [.fragmentsAllowed, .sortedKeys]) == encoded else { throw Failure.malformed }
            }
            let source = String(decoding: encoded, as: UTF8.self)
            return strategy == "MODIFY_FINAL" ? .modifyFinal(source) : .modify(source)
        default: throw Failure.malformed
        }
    }
}

/// Nonblocking submission/disposal gate, shared by the native Signal adapter and
/// pure fixtures. The submitted closure must only validate/submit native work; it
/// must NEVER wait for Python. Recursive locking permits a synchronous fake/native
/// source to finish or dispose itself from add(), without a start-after-dispose race.
public final class PluginTLSubmissionGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var stopped = false
    private var submitted = false
    private var cancellations: [() -> Void] = []

    public init() {}

    public var isActive: Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        return !self.stopped
    }

    public var hasSubmitted: Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.submitted
    }

    @discardableResult
    public func submit(_ action: () -> (() -> Void)?) -> Bool {
        self.lock.lock()
        guard !self.stopped, !self.submitted else { self.lock.unlock(); return false }
        self.submitted = true
        let cancellation = action()
        let stopped = self.stopped
        if !stopped, let cancellation { self.cancellations.append(cancellation) }
        self.lock.unlock()
        if stopped { cancellation?() }
        return true
    }

    public func bind(_ cancellation: @escaping () -> Void) {
        self.lock.lock()
        if self.stopped {
            self.lock.unlock()
            cancellation()
        } else {
            self.cancellations.append(cancellation)
            self.lock.unlock()
        }
    }

    /// Exactly one terminal winner. Dispose uses the same transition but emits
    /// nothing; late native responses and late installed disposables lose.
    @discardableResult
    public func stop() -> Bool {
        self.lock.lock()
        guard !self.stopped else { self.lock.unlock(); return false }
        self.stopped = true
        let cancellations = self.cancellations
        self.cancellations.removeAll()
        self.lock.unlock()
        for cancellation in cancellations { cancellation() }
        return true
    }
}
