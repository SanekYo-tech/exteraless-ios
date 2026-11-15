import Foundation

public enum CloudSyncStatus: Equatable, Sendable {
    case idle, syncing, reading, restoring, deleting, closed
    case failed(CloudError)
}

public struct CloudSyncResult: Equatable, Sendable {
    public let uploaded: Bool
    public let settings: Int
    public let credentials: Int
}

public struct CloudRestoreAdmission: Sendable {
    let commit: @MainActor @Sendable () throws -> Void
    /// Call once after obtaining the shared maintenance lease, immediately before
    /// entering the journalled write. Waiting for the lease remains cancellable.
    @MainActor public func beginCommit() throws { try commit() }
}

/// Owns one account lifetime. Same-intent Sync callers share a task; all other
/// concurrent actions are rejected. Remote reads happen only through a user action
/// or the explicitly enabled foreground auto-sync scheduler.
@MainActor public final class CloudSyncSession {
    public typealias Restore = @MainActor (CloudRestorePlan, Bool, CloudRestoreAdmission) async throws -> CloudRestoreResult
    public typealias RestoreAndroid = @MainActor (CloudLegacyRestorePlan, Bool, CloudRestoreAdmission) async throws -> CloudRestoreResult
    public let scope: CloudAccountScope
    public private(set) var state: CloudLocalState
    public private(set) var status: CloudSyncStatus = .idle
    public private(set) var latestCatalog: CloudCatalog?
    public private(set) var canCancel = true
    public var didChange: (@MainActor () -> Void)?
    public var restore: Restore?
    public var restoreAndroid: RestoreAndroid?
    public var isBusy: Bool { task != nil }
    public var isClosed: Bool { closed }

    private enum ResultValue: Sendable {
        case synced(CloudSyncResult), catalog(CloudCatalog), preview(CloudRestorePlan), legacyPreview(CloudLegacyRestorePlan), restored(CloudRestoreResult), deleted
    }
    private enum Kind: Equatable { case sync(Set<UUID>?), catalog, preview, previewAndroid, restore, restoreAndroid, delete }
    private let settings: ClientSettings
    private let remote: CloudRemoteStore
    private let stateStorage: any CloudSyncStateStorage
    private let credentials: any CloudCredentialStorage
    private let appVersion: String
    private let clock: @Sendable () -> Date
    private var task: Task<ResultValue, Error>?
    private var kind: Kind?
    private var generation = UUID()
    private var closed = false

    public init(scope: CloudAccountScope, settings: ClientSettings, remote: CloudRemoteStore,
                stateStorage: any CloudSyncStateStorage, credentials: any CloudCredentialStorage,
                appVersion: String, clock: @escaping @Sendable () -> Date = { Date() }, restore: Restore? = nil) throws {
        self.scope = scope
        self.settings = settings
        self.remote = remote
        self.stateStorage = stateStorage
        self.credentials = credentials
        self.appVersion = appVersion
        self.clock = clock
        self.restore = restore
        self.state = try stateStorage.load(scope: scope)
    }

    deinit { task?.cancel() }

    public func syncNow(acknowledging heads: Set<UUID>? = nil) async throws -> CloudSyncResult {
        let value = try await run(.sync(heads), status: .syncing) { [self] token in
            let snapshot = settings.readSnapshot()
            let includeKeys = CloudSyncPolicy(snapshot: snapshot).includeApiKeys
            let owner = scope.owner
            let appVersion = self.appVersion
            let credentials = self.credentials
            let date = clock()
            let prepared = try await Task.detached(priority: .utility) {
                try CloudSettingsArchive.prepare(snapshot: snapshot, owner: owner, appVersion: appVersion,
                    includeApiKeys: includeKeys, credentials: credentials, date: date)
            }.value
            try check(token)
            // A policy change while preparing must never release stale key bytes.
            guard CloudSyncPolicy(snapshot: settings.readSnapshot()).includeApiKeys == includeKeys else { throw CancellationError() }
            let catalog = try await remote.catalog()
            try check(token)
            latestCatalog = catalog
            let expected = heads ?? Set(state.acceptedHeads)
            guard catalog.heads == expected else { throw CloudError.conflict }
            if heads == nil, state.uploadedContentDigest == prepared.contentDigest, !catalog.heads.isEmpty {
                return .synced(CloudSyncResult(uploaded: false, settings: prepared.settingCount, credentials: prepared.credentialCount))
            }
            let settings = self.settings
            let revision = try await remote.publish(prepared.data, expectedHeads: expected, date: date,
                allowed: { CloudSyncPolicy(snapshot: settings.readSnapshot()).includeApiKeys == includeKeys })
            try check(token)
            let next = CloudLocalState(scope: scope, acceptedHeads: [revision.id],
                lastSuccessfulSyncMilliseconds: try nowMilliseconds(), uploadedContentDigest: prepared.contentDigest)
            try stateStorage.save(next)
            state = next
            latestCatalog = nil
            return .synced(CloudSyncResult(uploaded: true, settings: prepared.settingCount, credentials: prepared.credentialCount))
        }
        guard case let .synced(result) = value else { throw CloudError.busy }
        return result
    }

    public func loadCatalog() async throws -> CloudCatalog {
        let value = try await run(.catalog, status: .reading) { [self] token in
            let catalog = try await remote.catalog()
            try check(token)
            latestCatalog = catalog
            return .catalog(catalog)
        }
        guard case let .catalog(result) = value else { throw CloudError.busy }
        return result
    }

    public func preview(_ revision: CloudRevision, expectedHeads: Set<UUID>) async throws -> CloudRestorePlan {
        let value = try await run(.preview, status: .reading) { [self] token in
            let snapshot = settings.readSnapshot() // The CAS image belongs to this preview.
            let catalog = try await remote.catalog()
            guard catalog.heads == expectedHeads, catalog.revisions.contains(revision) else { throw CloudError.conflict }
            let data = try await remote.read(revision)
            try check(token)
            guard try await remote.catalog().heads == expectedHeads else { throw CloudError.conflict }
            try check(token)
            let owner = scope.owner
            let plan = try await Task.detached(priority: .utility) {
                try CloudSettingsArchive.inspect(data, revision: revision, heads: expectedHeads, owner: owner, snapshot: snapshot)
            }.value
            try check(token)
            return .preview(plan)
        }
        guard case let .preview(result) = value else { throw CloudError.busy }
        return result
    }

    public func restore(_ plan: CloudRestorePlan) async throws -> CloudRestoreResult {
        let value = try await run(.restore, status: .restoring) { [self] token in
            guard let restore else { throw CloudError.maintenanceUnavailable }
            guard plan.revision.owner == scope.owner else { throw CloudError.wrongAccount }
            guard plan.expectedHeads.count <= CloudProtocol.maximumHeads else { throw CloudError.conflict }
            guard try await remote.catalog().heads == plan.expectedHeads else { throw CloudError.conflict }
            try check(token)
            let includeKeys = CloudSyncPolicy(snapshot: settings.readSnapshot()).includeApiKeys
            let admission = CloudRestoreAdmission { [weak self] in
                guard let self else { throw CloudError.contextClosed }
                try self.check(token)
                guard self.canCancel else { throw CloudError.busy }
                self.canCancel = false
                self.didChange?()
            }
            let result = try await restore(plan, includeKeys, admission)
            try check(token)
            guard !canCancel else { throw CloudError.maintenanceUnavailable }
            let next = CloudLocalState(scope: scope,
                acceptedHeads: plan.expectedHeads.sorted { $0.uuidString < $1.uuidString },
                lastSuccessfulSyncMilliseconds: try nowMilliseconds())
            try stateStorage.save(next)
            state = next
            return .restored(result)
        }
        guard case let .restored(result) = value else { throw CloudError.busy }
        return result
    }

    public func deleteNativeHistory(expectedHeads: Set<UUID>) async throws {
        _ = try await run(.delete, status: .deleting) { [self] token in
            try await remote.deleteNativeHistory(expectedHeads: expectedHeads)
            try check(token)
            var next = state
            next.acceptedHeads = []
            next.uploadedContentDigest = nil
            // Deletion is not a sync/restore success; keep the previous date.
            try stateStorage.save(next)
            state = next
            latestCatalog = nil
            return .deleted
        }
    }

    public func previewAndroid() async throws -> CloudLegacyRestorePlan {
        let value = try await run(.previewAndroid, status: .reading) { [self] token in
            let snapshot = settings.readSnapshot()
            let includeKeys = CloudSyncPolicy(snapshot: snapshot).includeApiKeys
            let legacy = try await remote.readAndroidSnapshot()
            try check(token)
            guard legacy.owner == scope.owner else { throw CloudError.wrongAccount }
            let plan = try await Task.detached(priority: .utility) {
                try CloudLegacySettingsArchive.inspect(legacy, snapshot: snapshot, includeApiKeys: includeKeys)
            }.value
            try check(token)
            return .legacyPreview(plan)
        }
        guard case let .legacyPreview(plan) = value else { throw CloudError.busy }
        return plan
    }

    public func restoreAndroid(_ plan: CloudLegacyRestorePlan) async throws -> CloudRestoreResult {
        let value = try await run(.restoreAndroid, status: .restoring) { [self] token in
            guard let restoreAndroid else { throw CloudError.maintenanceUnavailable }
            guard plan.owner == scope.owner else { throw CloudError.wrongAccount }
            let current = try await remote.readAndroidSnapshot()
            guard current.fingerprint == plan.remoteFingerprint else { throw CloudError.conflict }
            try check(token)
            let includeKeys = CloudSyncPolicy(snapshot: settings.readSnapshot()).includeApiKeys
            guard plan.settingCount > 0 || (includeKeys && plan.credentialCount > 0) else { throw CloudError.nothingToRestore }
            let admission = CloudRestoreAdmission { [weak self] in
                guard let self else { throw CloudError.contextClosed }
                try self.check(token)
                guard self.canCancel else { throw CloudError.busy }
                self.canCancel = false
                self.didChange?()
            }
            let result = try await restoreAndroid(plan, includeKeys, admission)
            try check(token)
            guard !canCancel else { throw CloudError.maintenanceUnavailable }
            guard result.settings > 0 || result.addedCredentials > 0 else { throw CloudError.nothingToRestore }
            var next = state
            next.uploadedContentDigest = nil
            next.lastSuccessfulSyncMilliseconds = try nowMilliseconds()
            // Keep native acceptedHeads: Android has no native revision DAG and
            // its global updated_at is not this account's successful-sync date.
            try stateStorage.save(next)
            state = next
            return .restored(result)
        }
        guard case let .restored(result) = value else { throw CloudError.busy }
        return result
    }

    public func deleteDamagedNativeData() async throws {
        _ = try await run(.delete, status: .deleting) { [self] token in
            try await remote.deleteDamagedNativeData()
            try check(token)
            var next = state
            next.acceptedHeads = []
            next.uploadedContentDigest = nil
            try stateStorage.save(next)
            state = next
            latestCatalog = nil
            return .deleted
        }
    }

    public func cancel() {
        guard canCancel else { return }
        generation = UUID()
        task?.cancel()
        task = nil
        kind = nil
        status = closed ? .closed : .idle
        didChange?()
    }

    public func clear() {
        closed = true
        generation = UUID()
        task?.cancel()
        task = nil
        kind = nil
        latestCatalog = nil
        restore = nil
        restoreAndroid = nil
        status = .closed
        didChange?()
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard !closed, generation == token else { throw CloudError.contextClosed }
    }

    private func nowMilliseconds() throws -> Int64 {
        let milliseconds = clock().timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds > 0, milliseconds < Double(Int64.max) else { throw CloudError.localStorage }
        return Int64(milliseconds)
    }

    private func run(_ kind: Kind, status: CloudSyncStatus,
                     body: @escaping @MainActor (UUID) async throws -> ResultValue) async throws -> ResultValue {
        guard !closed else { throw CloudError.contextClosed }
        if let task {
            if case .sync = kind, self.kind == kind { return try await task.value }
            throw CloudError.busy
        }
        let token = UUID()
        generation = token
        self.kind = kind
        self.status = status
        let task = Task { @MainActor in try await body(token) }
        self.task = task
        didChange?()
        do {
            let value = try await task.value
            try check(token)
            self.task = nil
            self.kind = nil
            self.canCancel = true
            self.status = .idle
            didChange?()
            return value
        } catch {
            if generation == token {
                self.task = nil
                self.kind = nil
                self.canCancel = true
                self.status = error is CancellationError ? .idle : .failed((error as? CloudError) ?? .localStorage)
                didChange?()
            }
            if error is CancellationError { throw error }
            throw (error as? CloudError) ?? .localStorage
        }
    }
}
