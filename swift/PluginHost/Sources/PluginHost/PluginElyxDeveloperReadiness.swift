import Foundation

/// A no-FD challenge issued by the native registry, bound to one fresh inspector.
/// Its Python request is an ordinary check of an unknown read_id and must fail.
final class PluginElyxDeveloperReadinessChallenge: @unchecked Sendable {
    let nonce: String
    let context: PluginElyxDeveloperInspectionContext
    private weak var registry: PluginElyxDeveloperDescriptorRegistry?
    private let lock = NSLock()
    private var observations = 0
    private var retired = false

    init(registry: PluginElyxDeveloperDescriptorRegistry) {
        self.registry = registry; nonce = elyxNativeNonce(); context = registry.makeInspectionContext()
    }
    func observe() {
        lock.lock(); if !retired { observations += 1 }; lock.unlock()
    }
    func validate(_ output: String, registryID: UUID, epoch: UUID) throws -> PluginElyxDeveloperBridgeReadiness {
        lock.lock(); let count = observations; let invalid = retired; lock.unlock()
        guard !invalid, count == 1, output.utf8.count <= 4096,
              let raw = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              Set(raw.keys) == Set(["abi", "challenge", "gate", "hooks", "rejected"]),
              raw["abi"] as? String == PluginElyxDeveloperDescriptorRegistry.sourceABI,
              raw["challenge"] as? String == nonce, raw["gate"] as? String == "builtin",
              let hooks = raw["hooks"] as? [String], hooks == ["inspect", "manifest", "verifiedLoad"],
              let rejected = raw["rejected"], try PluginJSONValue(jsonObject: rejected) == .bool(true) else {
            throw PluginElyxDeveloperError.unavailable("Elyx readiness did not prove the built-in gate, three hooks and this native registry challenge")
        }
        return .init(abi: PluginElyxDeveloperDescriptorRegistry.abi, registry: registryID, epoch: epoch,
                     hooks: Set(hooks.compactMap(PluginElyxDeveloperBridgeReadiness.Hook.init(rawValue:))))
    }
    /// Stop accepting observations once native execution has really finished.
    /// The observation receipt itself survives for the awaiter's validation.
    func finished() { registry?.finishReadinessChallenge(nonce) }
    func invalidate() { lock.lock(); retired = true; lock.unlock() }
    deinit { registry?.finishReadinessChallenge(nonce) }
}

/// Read-only native instrumentation for component probes; it neither replaces
/// the dispatcher nor changes an operation's result.
public struct PluginElyxDeveloperRegistryMetrics: Sendable {
    public let operations: [String: Int]
    public let bytesRead: Int
    public let challengesObserved: Int
    public let capabilities: Int
    public let readTickets: Int
    public let sourceReceipts: Int
    public let accepting: Bool
}

final class PluginElyxProbeHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var value: InterpreterHandle?
    func set(_ handle: InterpreterHandle) { lock.lock(); value = handle; lock.unlock() }
    var current: InterpreterHandle? { lock.lock(); defer { lock.unlock() }; return value }
}
