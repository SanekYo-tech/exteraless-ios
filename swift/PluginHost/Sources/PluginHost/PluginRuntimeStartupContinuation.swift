import Foundation

/// Owns the unfinished startup of one newly constructed Host. The composition
/// root installs providers once, then uses this same object for initial startup
/// and an owned Tools-recovery handoff. It never constructs, stops or replaces a
/// Host, and never retries an ordinary start which has already been attempted.
@MainActor public final class PluginRuntimeStartupContinuation {
    public struct Policy: Equatable, Sendable {
        public let engineEnabled: Bool
        public let safeMode: Bool
        public init(engineEnabled: Bool, safeMode: Bool) {
            self.engineEnabled = engineEnabled
            self.safeMode = safeMode
        }
    }

    public struct Started: Sendable {
        public let safeMode: Bool
        public let disabledPluginIds: [String]
    }

    public enum Phase: Equatable, Sendable {
        case pendingRecovery, recovering, recoveryBlocked, pendingStart
        case preparing, starting, pendingCompletion, ready, failed, retired
    }

    /// Native-only receipt captured by the root that owns the actual maintenance
    /// lease. A receipt from another startup or an older finish cannot clear this
    /// startup's recovery block. It is not a serializable journal/write witness.
    public struct Maintenance: Sendable {
        fileprivate let owner: UUID
        fileprivate let generation: UUID
    }

    public let host: PluginHost
    public private(set) var phase: Phase = .pendingRecovery
    public private(set) var failure: PluginHostError?
    public private(set) var hasAttemptedStart = false
    private let identity = UUID()
    private var generation = UUID()
    private var recovered = false
    private var prepared = false
    private var started: Started?
    private var operation: Task<Void, Error>?

    /// `host` must be the fresh Host whose ordinary start this object will own.
    public init(host: PluginHost) { self.host = host }

    public var canContinue: Bool {
        guard operation == nil else { return false }
        return phase == .pendingRecovery || phase == .pendingStart || phase == .pendingCompletion
    }

    public func captureMaintenance() -> Maintenance? {
        guard operation == nil, !hasAttemptedStart, !host.isRunning,
              phase == .pendingRecovery || phase == .pendingStart || phase == .recoveryBlocked else { return nil }
        return Maintenance(owner: identity, generation: generation)
    }

    /// Call only after the root's same-owner lease.finish succeeded. For a fresh
    /// Host, resume=true only reopens admission; it does not initialize Python.
    /// A failed reconciliation keeps the block. This method never starts Python.
    public func acknowledgeMaintenance(_ receipt: Maintenance, recovered: Bool) throws {
        guard receipt.owner == identity, receipt.generation == generation,
              operation == nil, !hasAttemptedStart, phase != .failed, phase != .retired else {
            throw PluginHostError.superseded("Cold-start maintenance owner changed")
        }
        if recovered {
            guard !host.isSettingsMaintenanceActive else {
                throw PluginHostError.runtimeFailure("Cold-start maintenance has not finished")
            }
            // A service outcome is not a journal/write witness. Re-run the
            // existing data-only recovery under its real fresh-Host lease before
            // starting (also catches a stale review or a newly retained journal).
            self.recovered = false
            phase = .pendingRecovery
            failure = nil
        } else {
            self.recovered = false
            phase = .recoveryBlocked
            failure = .runtimeFailure("Settings recovery is still required before startup")
        }
        generation = UUID()
    }

    /// Account/root retirement revokes continuations without a terminal Host
    /// stop/start cycle. Already admitted native work is allowed to finish.
    public func retire() {
        phase = .retired
        generation = UUID()
        operation?.cancel()
    }

    /// `isCurrent` captures the initiating account generation, not a newest-owner
    /// lookup. `policy` is read again after every await before the ordinary start.
    /// `prepare` and the synchronous remaining stages each run at most once.
    public func run(
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        policy: @escaping @MainActor @Sendable () throws -> Policy,
        recoverBeforeStart: @escaping @MainActor @Sendable () async throws -> Void,
        prepare: @escaping @MainActor @Sendable (Policy) async throws -> Void = { _ in },
        complete: @escaping @MainActor @Sendable (Started) -> Void
    ) async throws {
        if let operation { try await operation.value; return }
        switch phase {
        case .ready: return
        case .recoveryBlocked, .failed:
            throw failure ?? PluginHostError.runtimeFailure("Startup cannot continue")
        case .retired: throw PluginHostError.superseded("Startup owner retired")
        default: break
        }
        let operation = Task { @MainActor in
            do {
                try await self.perform(isCurrent: isCurrent, policy: policy,
                                       recoverBeforeStart: recoverBeforeStart, prepare: prepare, complete: complete)
                self.failure = nil
            } catch {
                self.failure = bridgePluginError(error)
                throw error
            }
        }
        self.operation = operation
        defer { self.operation = nil }
        try await withTaskCancellationHandler(operation: {
            try await operation.value
        }, onCancel: { operation.cancel() })
    }

    private func perform(
        isCurrent: @MainActor () -> Bool,
        policy: @MainActor () throws -> Policy,
        recoverBeforeStart: @MainActor () async throws -> Void,
        prepare: @MainActor (Policy) async throws -> Void,
        complete: @MainActor (Started) -> Void
    ) async throws {
        @MainActor func admission() throws -> Policy? {
            try Task.checkCancellation()
            guard phase != .retired, isCurrent() else {
                throw PluginHostError.superseded("Startup account or maintenance scope retired")
            }
            let value = try policy()
            return value.engineEnabled ? value : nil
        }
        guard try admission() != nil else { return }
        if !recovered {
            phase = .recovering
            do { try await recoverBeforeStart() }
            catch {
                if phase != .retired { phase = .recoveryBlocked }
                throw error
            }
            guard phase != .retired else { throw PluginHostError.superseded("Startup owner retired") }
            recovered = true
            phase = .pendingStart
        }
        guard let current = try admission() else { return }
        if !prepared {
            phase = .preparing
            do { try await prepare(current) }
            catch {
                if phase != .retired { phase = .failed }
                throw error
            }
            guard phase != .retired else { throw PluginHostError.superseded("Startup owner retired") }
            prepared = true
            phase = .pendingStart
        }
        guard let current = try admission() else { return }
        if !hasAttemptedStart {
            guard !host.isRunning, !host.isSettingsMaintenanceActive else {
                phase = .failed
                throw PluginHostError.runtimeFailure("Host is not owned by this fresh startup")
            }
            let enabled = Set(host.pluginList().filter(\.enabled).map(\.id))
            hasAttemptedStart = true // Never reset, including a partial initialization failure.
            phase = .starting
            do { try await host.start(safeMode: current.safeMode) }
            catch {
                if phase != .retired { phase = .failed }
                throw error
            }
            started = Started(safeMode: current.safeMode, disabledPluginIds: host.pluginList().filter {
                enabled.contains($0.id) && !$0.enabled && $0.loadError == "plugin crashed the app"
            }.map(\.id))
            guard phase != .retired else { throw PluginHostError.superseded("Startup owner retired") }
            phase = .pendingCompletion
        }
        guard try admission() != nil else { return }
        guard host.isRunning, let started else {
            phase = .failed
            throw PluginHostError.runtimeFailure("Ordinary Host startup did not become ready")
        }
        // No suspension between the final scope check and publication/hooks/event.
        complete(started)
        phase = .ready
    }
}
