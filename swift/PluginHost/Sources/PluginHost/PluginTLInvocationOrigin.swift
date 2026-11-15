import Foundation

/// Native causal ancestry, not a permission exemption. Ordinary plugin requests
/// have no ancestry; a request emitted inside a hook skips only ancestor plugins.
public struct PluginTLInvocationOrigin: Equatable, Sendable {
    public let rootId: String
    public let pluginIds: [String]

    public init(rootId: String, pluginIds: [String]) throws {
        guard !rootId.isEmpty, rootId.utf8.count <= 128, pluginIds.count <= 32,
              pluginIds.allSatisfy(Plugin.isValidID), Set(pluginIds).count == pluginIds.count else {
            throw PluginHostError.runtimeFailure("Invalid or excessive TL hook ancestry")
        }
        self.rootId = rootId
        self.pluginIds = pluginIds
    }

    func entering(_ pluginId: String) throws -> Self {
        guard !self.pluginIds.contains(pluginId) else { throw PluginHostError.runtimeFailure("TL hook ancestry reentry") }
        return try Self(rootId: self.rootId, pluginIds: self.pluginIds + [pluginId])
    }
}

final class PluginTLInvocationScope: @unchecked Sendable {
    let owner: PluginHost.CallbackOwner
    let origin: PluginTLInvocationOrigin
    weak var registry: PluginTLOriginRegistry?
    private let lock = NSLock()
    private var active = true

    init(owner: PluginHost.CallbackOwner, origin: PluginTLInvocationOrigin, registry: PluginTLOriginRegistry) {
        self.owner = owner; self.origin = origin; self.registry = registry
    }
    var isActive: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.active }
    func close() { self.lock.lock(); self.active = false; self.lock.unlock() }
}

/// Installed in invokePlugin's ACTUAL mailbox predicate, not on the Task that is
/// waiting for that mailbox. The next invocation installs its own scope (or nil).
public enum PluginTLNativeOrigin {
    private static let key = "exteraless.native.tl-hook-origin"
    static func install(_ scope: PluginTLInvocationScope?) {
        if let scope { Thread.current.threadDictionary[key] = scope }
        else { Thread.current.threadDictionary.removeObject(forKey: key) }
    }

    public static func capture(owner: PluginHost.CallbackOwner) throws -> PluginTLInvocationOrigin? {
        guard let scope = Thread.current.threadDictionary[key] as? PluginTLInvocationScope,
              scope.owner == owner else { return nil }
        guard scope.isActive else { throw PluginHostError.superseded("TL hook invocation already ended") }
        guard scope.origin.pluginIds.count < 32 else { throw PluginHostError.runtimeFailure("TL_ORIGIN_DEPTH_LIMIT") }
        return scope.origin
    }

    public static func capture(owner: PluginHost.CallbackOwner, callbackHandle: Int64) throws -> PluginTLInvocationOrigin? {
        guard let scope = Thread.current.threadDictionary[key] as? PluginTLInvocationScope,
              scope.owner == owner else { return nil }
        guard scope.isActive else { throw PluginHostError.superseded("TL hook invocation already ended") }
        guard scope.origin.pluginIds.count < 32 else { throw PluginHostError.runtimeFailure("TL_ORIGIN_DEPTH_LIMIT") }
        guard let registry = scope.registry else { throw PluginHostError.superseded("TL origin host expired") }
        try registry.bind(owner: owner, handle: callbackHandle, origin: scope.origin)
        return scope.origin
    }
}

final class PluginTLOriginRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [PluginHost.CallbackOwner: [Int64: PluginTLInvocationOrigin]] = [:]
    private var count = 0

    func bind(owner: PluginHost.CallbackOwner, handle: Int64, origin: PluginTLInvocationOrigin) throws {
        self.lock.lock(); defer { self.lock.unlock() }
        guard handle > 0 else { throw PluginHostError.runtimeFailure("Invalid TL-origin callback handle") }
        if let existing = self.callbacks[owner]?[handle] {
            guard existing == origin else { throw PluginHostError.runtimeFailure("TL callback lease has different ancestry") }
            return
        }
        guard self.count < 16_384, (self.callbacks[owner]?.count ?? 0) < 1024 else {
            throw PluginHostError.runtimeFailure("TL origin callback quota exceeded")
        }
        self.callbacks[owner, default: [:]][handle] = origin
        self.count += 1
    }

    func origin(owner: PluginHost.CallbackOwner, handle: Int64) -> PluginTLInvocationOrigin? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.callbacks[owner]?[handle]
    }

    func release(owner: PluginHost.CallbackOwner, handles: [Int64]) {
        self.lock.lock(); defer { self.lock.unlock() }
        for handle in Set(handles) {
            if self.callbacks[owner]?.removeValue(forKey: handle) != nil { self.count -= 1 }
        }
        if self.callbacks[owner]?.isEmpty == true { self.callbacks.removeValue(forKey: owner) }
    }

    /// Caller holds Host's retirement/loading reservation, so this cannot erase
    /// another generation. This never invokes Python or changes native admission.
    func retire(pluginId: String) {
        self.lock.lock(); defer { self.lock.unlock() }
        for owner in Array(self.callbacks.keys) where owner.pluginId == pluginId {
            self.count -= self.callbacks.removeValue(forKey: owner)?.count ?? 0
        }
    }
}
