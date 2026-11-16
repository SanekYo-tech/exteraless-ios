import Foundation

/// Root captures this before scheduling activation. Revocation also rejects an
/// old queued activation which has not created a service/registry yet.
public final class PluginElyxDeveloperActivationScope: @unchecked Sendable {
    public let id = UUID()
    private let lock = NSLock()
    private var active = true
    public init() {}
    public var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return active }
    public func invalidate() { lock.lock(); active = false; lock.unlock() }
}

/// Production Foundation-only activation shared by Runtime and native probes.
/// It owns one immutable dispatcher epoch and a readiness receipt produced only
/// by Host's fresh trusted inspector + real C/native challenge round trip.
public final class PluginElyxDeveloperService: @unchecked Sendable {
    public let scope: UUID
    public let registry = PluginElyxDeveloperDescriptorRegistry()
    private weak var host: PluginHost?
    private let externalCurrent: @Sendable () -> Bool
    private let diagnostic: @Sendable (String) -> Void
    private let lock = NSLock()
    private var bindingEpoch: UUID?
    private var retired = false
    private var proof: PluginElyxDeveloperBridgeReadiness?
    private var files: PluginElyxDeveloperFiles?
    private var setup: Task<PluginElyxDeveloperFiles, Error>?
    private var activity: PluginElyxDeveloperFileActivity?
    private var attempts = 0

    init(host: PluginHost, scope: UUID, isCurrent: @escaping @Sendable () -> Bool,
         diagnostic: @escaping @Sendable (String) -> Void) {
        self.host = host; self.scope = scope; externalCurrent = isCurrent; self.diagnostic = diagnostic
    }

    func attach() throws {
        guard let host, host.isRunning, externalCurrent() else { throw PluginElyxDeveloperError.stale("Elyx activation scope is not current") }
        lock.lock(); defer { lock.unlock() }
        guard !retired, bindingEpoch == nil else { throw PluginElyxDeveloperError.stale("Elyx service binding was retired or already installed") }
        let registry = self.registry
        bindingEpoch = host.bridge.installElyxSourceDispatcher { json, id, token in
            registry.dispatch(requestJSON: json, immutablePluginId: id, immutableOwnerToken: token)
        }
    }

    public var isActive: Bool {
        lock.lock(); let epoch = bindingEpoch; let closed = retired; lock.unlock()
        guard !closed, let epoch, let host else { return false }
        return host.isRunning && externalCurrent() && host.bridge.elyxSourceDispatcherBindingEpoch == epoch
    }

    func belongs(to host: PluginHost, scope: UUID) -> Bool { self.host === host && self.scope == scope && isActive }

    public func invalidate() {
        lock.lock()
        let epoch = bindingEpoch
        retired = true
        let pending = setup
        setup = nil; files = nil; proof = nil
        lock.unlock()
        registry.invalidate()
        pending?.cancel()
        if let epoch { host?.bridge.removeElyxSourceDispatcher(expectedEpoch: epoch) }
    }

    public var fileActivity: (sources: Int, stages: Int) {
        lock.lock(); let value = activity; lock.unlock()
        return value?.snapshot ?? (0, 0)
    }
    public var fileAuthorityCount: Int {
        lock.lock(); let value = activity; lock.unlock()
        return value?.authorityCount ?? 0
    }
    public var probeAttempts: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    public var readyReceipt: PluginElyxDeveloperBridgeReadiness? {
        lock.lock(); let prepared = files != nil; lock.unlock()
        return prepared ? (try? checkedReadiness()) : nil
    }
    private var installedEpoch: UUID? { lock.lock(); defer { lock.unlock() }; return bindingEpoch }

    public func fileAuthority() throws -> PluginElyxDeveloperFiles {
        _ = try checkedReadiness()
        lock.lock(); let value = files; lock.unlock()
        guard let value else { throw PluginElyxDeveloperError.unavailable("Elyx native file authority is not ready") }
        return value
    }

    func prepare() async throws -> PluginElyxDeveloperFiles {
        try Task.checkCancellation()
        if let ready = try? fileAuthority() { return ready }
        let task = try setupTask()
        let result = try await task.value
        try Task.checkCancellation()
        guard isActive else { throw PluginElyxDeveloperError.stale("Elyx activation retired after preparation") }
        return result
    }

    private func setupTask() throws -> Task<PluginElyxDeveloperFiles, Error> {
        guard isActive else { throw PluginElyxDeveloperError.stale("Elyx activation/Host/dispatcher epoch expired") }
        lock.lock(); defer { lock.unlock() }
        if let setup { return setup }
        guard !retired else { throw PluginElyxDeveloperError.stale("Elyx activation retired") }
        attempts += 1
        // Includes filesystem anchor construction. No heavy I/O occurs on main.
        let task = Task.detached { [weak self] () async throws -> PluginElyxDeveloperFiles in
            guard let self else { throw PluginHostError.notRunning }
            do { return try await self.build() }
            catch { self.failed(error); throw error }
        }
        setup = task
        return task
    }

    private func build() async throws -> PluginElyxDeveloperFiles {
        guard let host, isActive else { throw PluginElyxDeveloperError.stale("Elyx Host expired before readiness probe") }
        guard let epoch = installedEpoch else { throw PluginElyxDeveloperError.stale("Elyx dispatcher is not installed") }
        let receipt = try await host.probeElyxSourceReadiness(registry: registry, bindingEpoch: epoch,
            shouldExecute: { [weak self] in self?.isActive == true })
        try publishProof(receipt)
        let bridge = PluginElyxDeveloperDescriptorBridge(readiness: { [weak self] in
            guard let self else { throw PluginHostError.notRunning }
            return try self.checkedReadiness()
        }, inspect: { [weak self, weak host] call in
            guard let self, let host, self.isActive else { throw PluginElyxDeveloperError.stale("Elyx inspector activation retired") }
            return try await host.inspectElyxDeveloperDescriptor(call.descriptor, format: call.format,
                shouldExecute: { [weak self] in self?.isActive == true && call.isCurrent() })
        }, currentOwner: { [weak self, weak host] owner in
            self?.isActive == true && host?.callbackOwner(id: owner.pluginId) == owner
        })
        let provider = try PluginElyxDeveloperFiles(pluginsDirectory: URL(fileURLWithPath: host.configuration.runtime.pluginRootDirectory),
            registry: registry, bridge: bridge, currentTarget: { [weak self, weak host] target in
                guard self?.isActive == true, let host, host.callbackOwner(id: target.plugin.id) == target.owner,
                      let plugin = host.pluginList().first(where: { $0.id == target.plugin.id }) else { return false }
                return target.matches(plugin) && host.permissionSnapshot(id: target.plugin.id) == target.consent
            }, currentConsent: { [weak self, weak host] target in
                self?.isActive == true && host?.permissionSnapshot(id: target.plugin.id) == target.consent
            }, diagnostic: diagnostic)
        try publishFiles(provider)
        return provider
    }

    private func checkedReadiness() throws -> PluginElyxDeveloperBridgeReadiness {
        guard isActive else { throw PluginElyxDeveloperError.stale("Elyx native registry epoch/activation retired") }
        lock.lock(); let value = proof; let epoch = bindingEpoch; lock.unlock()
        guard let value, value.epoch == epoch, value.registry == registry.identifier else {
            throw PluginElyxDeveloperError.unavailable("Elyx source gate/hooks have not passed the native readiness probe")
        }
        return value
    }
    private func publishProof(_ value: PluginElyxDeveloperBridgeReadiness) throws {
        guard isActive else { throw PluginElyxDeveloperError.stale("Elyx readiness activation retired") }
        lock.lock(); defer { lock.unlock() }
        guard !retired, value.epoch == bindingEpoch, value.registry == registry.identifier else {
            throw PluginElyxDeveloperError.stale("Elyx readiness belongs to a replaced dispatcher")
        }
        proof = value
    }
    private func publishFiles(_ value: PluginElyxDeveloperFiles) throws {
        guard isActive else { throw PluginElyxDeveloperError.stale("Elyx activation retired during file preparation") }
        lock.lock(); defer { lock.unlock() }
        guard !retired else { throw PluginElyxDeveloperError.stale("Elyx file authority retired") }
        files = value; activity = value.activity; setup = nil
    }
    private func failed(_ error: Error) {
        lock.lock(); setup = nil; proof = nil; files = nil; let closed = retired; lock.unlock()
        if !closed { diagnostic("Elyx native readiness failed (retry allowed): \(error)") }
    }
}

/// Host retains the service, whose Host link and provider closures are weak.
final class PluginElyxDeveloperServiceSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var current: PluginElyxDeveloperService?
    func acquire(host: PluginHost, scope: UUID, isCurrent: @escaping @Sendable () -> Bool,
                 diagnostic: @escaping @Sendable (String) -> Void) throws -> PluginElyxDeveloperService {
        lock.lock(); defer { lock.unlock() }
        guard host.isRunning, isCurrent() else { throw PluginElyxDeveloperError.stale("Elyx captured activation is already retired") }
        if let current, current.belongs(to: host, scope: scope) { return current }
        current?.invalidate()
        let next = PluginElyxDeveloperService(host: host, scope: scope, isCurrent: isCurrent, diagnostic: diagnostic)
        try next.attach()
        current = next
        return next
    }
    func invalidate(scope: UUID? = nil) {
        lock.lock()
        let old = (scope == nil || current?.scope == scope) ? current : nil
        if old != nil { current = nil }
        lock.unlock()
        old?.invalidate()
    }
}
