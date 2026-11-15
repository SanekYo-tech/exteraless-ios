import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

public struct ExteralessRetainedResourceFile {
    public let url: URL
    public let byteCount: Int64
}

private final class ExteralessRetentionWeakAccount {
    weak var value: ExteralessRetentionAccount?
    init(_ value: ExteralessRetentionAccount) { self.value = value }
}

/// Account-owned, including inactive accounts. The UI composition root never owns the lifetime
/// of stored files. Install in Account.init before starting cache eviction/state replay.
public final class ExteralessRetentionAccount {
    private static let registryLock = NSLock()
    private static var registry: [ObjectIdentifier: ExteralessRetentionWeakAccount] = [:]

    let postbox: Postbox
    let accountPeerId: PeerId
    var operationScope: RetentionOperationScope { self.ownerState.operationScope }
    private let queue = Queue(name: "ExteralessRetention")
    private let mediaQueue = DispatchQueue(label: "ExteralessRetention.Media", qos: .utility)
    private let vault: ExteralessRetentionMediaVault
    private let ownerState: RetentionOwnerState
    let clock: () -> Int64
    private let lifetimeLock = NSLock()
    private var pins: [String: Disposable] = [:]
    private var archiveSources: [String: String] = [:]
    private var mutationGeneration: UInt64 = 0
    private var clearing = false
    private var stopped = false
    private var leases: [String: MediaLease] = [:] // queue-confined
    private let indexDisposable = MetaDisposable()
    private let mutationsDisposable = MetaDisposable()
    private let failure = ValuePromise<ExteralessRetentionError?>(nil, ignoreRepeated: true)
    private var expiryTimer: SwiftSignalKit.Timer?

    private final class MediaLease {
        let entry: ExteralessRetentionMediaEntry
        let work: RetentionOperationWork
        let cancelled = Atomic<Bool>(value: false)
        let data = MetaDisposable()
        init(entry: ExteralessRetentionMediaEntry, work: RetentionOperationWork) { self.entry = entry; self.work = work }
        var isCancelled: Bool { self.cancelled.with { $0 } || !self.work.isCurrent }
        func dispose() { _ = self.cancelled.swap(true); self.data.dispose() }
        deinit { self.dispose() }
    }

    public convenience init(postbox: Postbox, accountPeerId: EnginePeer.Id, configuration: ExteralessRetentionProcessConfiguration? = nil, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.init(postbox: postbox, accountPeerId: accountPeerId, configurationState: ExteralessRetentionConfigurationState(version: 0, availability: configuration.map { .available($0) } ?? .unavailable), clock: clock, fileSystem: RetentionFileSystem())
    }

    public convenience init(postbox: Postbox, accountPeerId: EnginePeer.Id, configurationState: ExteralessRetentionConfigurationState, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.init(postbox: postbox, accountPeerId: accountPeerId, configurationState: configurationState, clock: clock, fileSystem: RetentionFileSystem())
    }

    convenience init(postbox: Postbox, accountPeerId: EnginePeer.Id, configuration: ExteralessRetentionProcessConfiguration?, clock: @escaping () -> Int64, fileSystem: RetentionFileSystem) {
        self.init(postbox: postbox, accountPeerId: accountPeerId, configurationState: ExteralessRetentionConfigurationState(version: 0, availability: configuration.map { .available($0) } ?? .unavailable), clock: clock, fileSystem: fileSystem)
    }

    init(postbox: Postbox, accountPeerId: EnginePeer.Id, configurationState: ExteralessRetentionConfigurationState, clock: @escaping () -> Int64, fileSystem: RetentionFileSystem) {
        self.postbox = postbox
        self.accountPeerId = accountPeerId
        self.ownerState = RetentionOwnerState(configurationState)
        self.clock = clock
        let configuration = self.ownerState.currentConfiguration
        let accountRoot = URL(fileURLWithPath: postbox.mediaBox.basePath, isDirectory: true).deletingLastPathComponent()
        self.vault = ExteralessRetentionMediaVault(directory: accountRoot.appendingPathComponent("exteraless-retention-media", isDirectory: true), durabilityRootURL: configuration?.durabilityRootURL ?? accountRoot, fileSystem: fileSystem)
        Self.registryLock.lock()
        Self.registry = Self.registry.filter { $0.value.value != nil }
        if Self.registry[ObjectIdentifier(postbox.mediaBox)]?.value != nil {
            Self.registryLock.unlock()
            self.stopped = true
            self.ownerState.close()
            self.failure.set(.unavailable)
            return
        }
        Self.registry[ObjectIdentifier(postbox.mediaBox)] = ExteralessRetentionWeakAccount(self)
        Self.registryLock.unlock()
        if configuration == nil { self.failure.set(.unavailable) }
        // Postbox's before-mutation boundary covers edit updates AND history/getDifference upserts
        // after offline periods. Its callback runs in the existing transaction before mutation.
        self.updateMutationObserver()
        let key = PostboxViewKey.cachedItem(exteralessRetentionIndexId)
        let firstRefresh = Atomic<Bool>(value: true)
        self.indexDisposable.set(postbox.combinedView(keys: [key]).start(next: { [weak self] _ in
            let first = firstRefresh.swap(false)
            self?.refresh(prune: first, retryFailedMedia: first)
        }))
        self.queue.async { [weak self] in
            guard let self else { return }
            let timer = SwiftSignalKit.Timer(timeout: 60.0, repeat: true, completion: { [weak self] in self?.refresh(prune: true) }, queue: self.queue)
            self.lifetimeLock.lock()
            if self.stopped { self.lifetimeLock.unlock(); return }
            self.expiryTimer = timer
            timer.start()
            self.lifetimeLock.unlock()
        }
    }

    deinit { self.dispose() }

    @discardableResult
    public func updateConfiguration(_ state: ExteralessRetentionConfigurationState) -> Bool {
        guard self.ownerState.update(state) else { return false }
        self.lifetimeLock.lock()
        self.mutationGeneration &+= 1
        self.lifetimeLock.unlock()
        if let value = self.ownerState.currentConfiguration {
            self.vault.updateDurabilityRoot(value.durabilityRootURL)
            self.failure.set(nil)
        } else { self.failure.set(.unavailable) }
        self.queue.async { [weak self] in
            guard let self else { return }
            for (id, lease) in self.leases where lease.isCancelled { lease.dispose(); self.leases.removeValue(forKey: id) }
        }
        self.updateMutationObserver()
        self.refresh(prune: true)
        return true
    }

    var loadedPolicy: RetentionPolicy? {
        self.lifetimeLock.lock(); defer { self.lifetimeLock.unlock() }
        return self.stopped ? nil : self.ownerState.currentConfiguration?.policy
    }

    var performsMaintenance: Bool {
        self.lifetimeLock.lock(); defer { self.lifetimeLock.unlock() }
        return !self.stopped && self.ownerState.currentConfiguration?.performsMaintenance == true
    }

    static func policy(mediaBox: MediaBox) throws -> RetentionPolicy {
        guard let value = self.get(mediaBox: mediaBox)?.loadedPolicy else { throw ExteralessRetentionError.unavailable }
        return value
    }

    static func readState(mediaBox: MediaBox) throws -> (policy: RetentionPolicy, now: Int64) {
        guard let owner = self.get(mediaBox: mediaBox), let policy = owner.loadedPolicy else { throw ExteralessRetentionError.unavailable }
        return (policy, owner.clock())
    }

    private func updateMutationObserver() {
        guard !self.operationIsStopped, self.loadedPolicy?.saveEdits == true else { self.mutationsDisposable.set(nil); return }
        self.mutationsDisposable.set(self.postbox.installMessageHistoryObserver { [weak self] transaction, previous, updated in
            guard let self, !self.operationIsStopped else { return }
            exteralessRetainBeforeEdit(transaction: transaction, mediaBox: self.postbox.mediaBox, previous: previous, updated: updated)
        })
    }

    /// Account.deinit calls this even if a queued crypto operation still temporarily retains
    /// the service. Removing/switching the UI context is not an account deletion.
    public func dispose() {
        self.ownerState.close()
        self.lifetimeLock.lock()
        if self.stopped { self.lifetimeLock.unlock(); return }
        self.stopped = true
        let pins = self.pins
        self.pins.removeAll()
        self.archiveSources.removeAll()
        let timer = self.expiryTimer
        self.expiryTimer = nil
        self.lifetimeLock.unlock()
        for pin in pins.values { pin.dispose() }
        self.queue.async { timer?.invalidate() }
        self.queue.async { [weak self] in
            guard let self else { return }
            for lease in self.leases.values { lease.dispose() }
            self.leases.removeAll()
        }
        self.indexDisposable.dispose()
        self.mutationsDisposable.dispose()
        Self.registryLock.lock()
        if Self.registry[ObjectIdentifier(self.postbox.mediaBox)]?.value === self { Self.registry.removeValue(forKey: ObjectIdentifier(self.postbox.mediaBox)) }
        Self.registryLock.unlock()
    }

    static func get(mediaBox: MediaBox) -> ExteralessRetentionAccount? {
        Self.registryLock.lock()
        let value = Self.registry[ObjectIdentifier(mediaBox)]?.value
        Self.registryLock.unlock()
        return value
    }

    func sourceId(forArchiveResource id: MediaResourceId) -> String? {
        self.lifetimeLock.lock()
        let value = self.stopped || self.clearing ? nil : self.archiveSources[id.stringRepresentation]
        self.lifetimeLock.unlock()
        return value
    }

    private var operationIsStopped: Bool {
        self.lifetimeLock.lock()
        let value = self.stopped || self.clearing
        self.lifetimeLock.unlock()
        return value || self.ownerState.currentConfiguration == nil
    }

    private func wantedPins(_ index: ExteralessRetentionIndex?) -> Set<String> {
        var result = Set<String>()
        for entry in index?.media.values.map({ $0 }) ?? [] {
            result.insert(entry.cacheId.stringRepresentation)
            if entry.state != .stored { result.insert(entry.id) }
        }
        return result
    }

    /// Account's cache eviction setup waits for this barrier, not for media copying. All native
    /// keepResource subscriptions have reached MediaBox.dataQueue before true is emitted.
    public var ready: Signal<Bool, NoError> {
        self.awaitReadiness(timeout: 25) |> mapToSignal { [weak self] result in
            if case let .success(token) = result, self?.isReadinessCurrent(token) == true { return Signal<Bool, NoError>.single(true) }
            return .complete()
        }
    }
    public var errors: Signal<ExteralessRetentionError?, NoError> { self.failure.get() }

    public func awaitReadiness(timeout: Double = 5) -> Signal<Result<ExteralessRetentionReadinessToken, ExteralessRetentionReadinessFailure>, NoError> {
        self.ownerState.awaitReadiness(timeout: timeout)
    }

    public func isReadinessCurrent(_ token: ExteralessRetentionReadinessToken) -> Bool {
        !self.operationIsStopped && self.ownerState.isCurrent(token)
    }

    public func retryReadiness(timeout: Double = 5) -> Signal<Result<ExteralessRetentionReadinessToken, ExteralessRetentionReadinessFailure>, NoError> {
        Signal { subscriber in
            guard !self.operationIsStopped, let attempt = self.ownerState.beginAttempt() else {
                subscriber.putNext(.failure(.configurationUnavailable)); subscriber.putCompletion(); return EmptyDisposable
            }
            self.updateMutationObserver()
            self.refresh(prune: true, retryFailedMedia: true)
            return self.ownerState.awaitReadiness(timeout: timeout, expectedAttempt: attempt).start(next: subscriber.putNext, completed: subscriber.putCompletion)
        }
    }

    public func resetArchiveForRecovery() -> Signal<Result<Void, ExteralessRetentionError>, NoError> { self.clearAll() }

    /// Called after staging the index in the SAME transaction as an edit/delete, before any
    /// native resource removal is queued. Work is only lease registration; file I/O is asynchronous.
    func didMutate(_ index: ExteralessRetentionIndex) {
        self.lifetimeLock.lock()
        if !self.stopped && !self.clearing && self.ownerState.currentConfiguration != nil {
            self.mutationGeneration &+= 1
            self.archiveSources = Dictionary(uniqueKeysWithValues: index.media.values.map { ($0.cacheId.stringRepresentation, $0.id) })
            for id in self.wantedPins(index) where self.pins[id] == nil {
                self.pins[id] = self.postbox.mediaBox.keepResource(id: MediaResourceId(id)).start()
            }
        }
        self.lifetimeLock.unlock()
        self.refresh()
    }

    func report(_ error: Error) {
        self.failure.set(exteralessRetentionError(error))
    }

    /// Also called on foreground/account activation: CachedItemView intentionally does not
    /// refresh on an external Postbox transaction (e.g. a notification extension).
    public func refresh(prune: Bool = false, retryFailedMedia: Bool = false) {
        guard !self.operationIsStopped, let admission = self.ownerState.captureWork(readiness: true) else { return }
        let policy = admission.configuration.policy
        let prune = prune && admission.configuration.performsMaintenance
        let now = self.clock()
        let work = admission.work
        let postbox = self.postbox
        let accountPeerId = self.accountPeerId
        self.lifetimeLock.lock()
        let generation = self.mutationGeneration
        self.lifetimeLock.unlock()
        let _ = (postbox.transaction { transaction -> (Result<ExteralessRetentionIndex?, ExteralessRetentionError>, Bool, Bool) in
            guard work.isCurrent else { return (.failure(.cancelled), false, false) }
            if transaction.retrieveItemCacheEntry(id: exteralessRetentionResetId) != nil { return (.success(nil), false, true) }
            do {
                if prune, transaction.retrieveItemCacheEntry(id: retentionArchivePeersId) != nil {
                    var descriptors = try RetentionArchivePeerStore.load(transaction: transaction, accountPeerId: accountPeerId, policy: policy, now: now)
                    transaction.putItemCacheEntry(id: retentionArchivePeersId, entry: try descriptors.bound(limit: policy.messageLimit))
                }
                guard let index = try ExteralessRetentionIndex.load(transaction: transaction, accountPeerId: accountPeerId) else { return (.success(nil), false, false) }
                if prune || (retryFailedMedia && admission.configuration.performsMaintenance) {
                    let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: accountPeerId, policy: policy, now: now)
                    let more = try store.pruneVersions()
                    if retryFailedMedia { store.retryFailedMedia() }
                    return (.success(try store.finish()), more, false)
                }
                return (.success(index), false, false)
            } catch { return (.failure(exteralessRetentionError(error)), false, false) }
        } |> deliverOn(self.queue)).start(next: { [weak self] result, more, resetting in
            guard let self, !self.operationIsStopped, work.isCurrent else { return }
            if resetting {
                self.lifetimeLock.lock()
                let alreadyClearing = self.clearing
                self.lifetimeLock.unlock()
                if !alreadyClearing && self.performsMaintenance {
                    let _ = self.clearAll().start(next: { [weak self] result in
                        if case let .failure(error) = result { self?.report(error) }
                    })
                }
                return
            }
            switch result {
            case let .success(index): self.reconcile(index, generation: generation, admission: admission)
            case let .failure(error): self.report(error); self.ownerState.complete(admission, error: error)
            }
            if more { self.refresh(prune: true) }
        })
    }

    private func reconcile(_ index: ExteralessRetentionIndex?, generation: UInt64, admission: RetentionConfiguredWork) {
        self.lifetimeLock.lock()
        if self.stopped || self.clearing || self.mutationGeneration != generation || !admission.work.isCurrent {
            self.lifetimeLock.unlock()
            return
        }
        let desired = self.wantedPins(index)
        self.archiveSources = Dictionary(uniqueKeysWithValues: index?.media.values.map { ($0.cacheId.stringRepresentation, $0.id) } ?? [])
        for id in desired where self.pins[id] == nil { self.pins[id] = self.postbox.mediaBox.keepResource(id: MediaResourceId(id)).start() }
        let released = self.pins.filter { !desired.contains($0.key) }
        for id in released.keys { self.pins.removeValue(forKey: id) }
        self.lifetimeLock.unlock()
        for pin in released.values { pin.dispose() }
        for (id, lease) in self.leases {
            if lease.isCancelled || index?.media[id]?.token != lease.entry.token || index?.media[id]?.state != lease.entry.state || index?.media[id]?.state == .stored {
                lease.dispose()
                self.leases.removeValue(forKey: id)
            }
        }
        if let index {
            for entry in index.media.values where entry.state == .pending && self.leases[entry.id] == nil {
                let lease = MediaLease(entry: entry, work: admission.work)
                self.leases[entry.id] = lease
                // First recover a complete encrypted file whose acknowledgement was interrupted.
                self.mediaQueue.async { [weak self, weak lease] in
                    guard let self, let lease, !lease.isCancelled, !self.operationIsStopped else { return }
                    do {
                        let path = try self.vault.file(for: entry)
                        let cancelled = { lease.isCancelled || self.operationIsStopped }
                        let recovered: Int64? = try self.vault.fileLock.withLock(cancelled: cancelled) {
                            let admission = try self.admitMedia(resourceId: entry.id, cancelled: cancelled)
                            guard admission.entry.token == entry.token, admission.index.epoch == index.epoch else { throw ExteralessRetentionError.cancelled }
                            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
                            return try self.vault.recover(entry: entry, index: index, expectedLength: nil, cancelled: cancelled)
                        }
                        if let count = recovered {
                            self.acknowledge(entry: entry, epoch: index.epoch, byteCount: count, work: lease.work)
                            return
                        }
                    } catch {
                        self.failMedia(entry: entry, epoch: index.epoch, error: error, work: lease.work)
                        // Leave an authenticated-but-unsynced rename available to explicit retry.
                        return
                    }
                    self.watchAvailableData(lease: lease, index: index)
                }
            }
        }
        let tokens = Set(index?.media.values.map(\.token) ?? [])
        if self.performsMaintenance {
            self.cleanupMediaFiles(keeping: tokens, generation: generation) { [weak self] result in
                if case let .failure(error) = result, error != .cancelled { self?.report(error) }
            }
        }
        self.postbox.mediaBox.dataQueue.async { [weak self] in
            guard let self, !self.operationIsStopped else { return }
            self.ownerState.complete(admission)
        }
    }

    private func watchAvailableData(lease: MediaLease, index: ExteralessRetentionIndex) {
        guard !lease.isCancelled, !self.operationIsStopped else { return }
        let entry = lease.entry
        lease.data.set((self.postbox.mediaBox.resourceData(id: MediaResourceId(entry.id))
        |> filter { $0.complete && $0.size > 0 }
        |> take(1)).start(next: { [weak self, weak lease] data in
            guard let self, let lease, !lease.isCancelled else { return }
            guard data.size <= entry.reservedBytes else {
                self.dropMedia(entry: entry, epoch: index.epoch, error: .limitExceeded, work: lease.work)
                return
            }
            do {
                // An open descriptor keeps the received inode alive even if another process
                // removes its directory entry. No bulk copying runs on the Postbox/UI queue.
                let source = try FileHandle(forReadingFrom: URL(fileURLWithPath: data.path))
                self.mediaQueue.async { [weak self, weak lease] in
                    guard let self, let lease else { try? source.close(); return }
                    defer { try? source.close() }
                    do {
                        let cancelled = { lease.isCancelled || self.operationIsStopped }
                        let count = try self.vault.fileLock.withLock(cancelled: cancelled) {
                            let admission = try self.admitMedia(resourceId: entry.id, cancelled: cancelled)
                            guard admission.entry.token == entry.token, admission.index.epoch == index.epoch else { throw ExteralessRetentionError.cancelled }
                            return try self.vault.store(source: source, length: data.size, entry: entry, index: index, cancelled: cancelled)
                        }
                        self.acknowledge(entry: entry, epoch: index.epoch, byteCount: count, work: lease.work)
                    } catch {
                        if !lease.isCancelled, !self.operationIsStopped { self.failMedia(entry: entry, epoch: index.epoch, error: error, work: lease.work) }
                    }
                }
            } catch { self.failMedia(entry: entry, epoch: index.epoch, error: error, work: lease.work) }
        }))
    }

    private func acknowledge(entry: ExteralessRetentionMediaEntry, epoch: String, byteCount: Int64, work: RetentionOperationWork) {
        let _ = self.postbox.transaction { [weak self] transaction -> Void in
            guard let self, !self.operationIsStopped, work.isCurrent, let policy = self.loadedPolicy else { return }
            do {
                let admission = try retentionAdmitMedia(transaction: transaction, accountPeerId: self.accountPeerId, policy: policy, now: self.clock(), resourceId: entry.id)
                guard admission.entry.token == entry.token, admission.index.epoch == epoch else { return }
                guard var index = try ExteralessRetentionIndex.load(transaction: transaction, accountPeerId: self.accountPeerId), index.epoch == epoch,
                      var current = index.media[entry.id], current.token == entry.token else { self.refresh(); return }
                current.state = .stored
                current.storedBytes = byteCount
                current.reservedBytes = byteCount
                index.media[entry.id] = current
                guard index.revision < UInt64.max else { throw ExteralessRetentionError.limitExceeded }
                index.revision += 1
                transaction.putItemCacheEntry(id: exteralessRetentionIndexId, entry: CodableEntry(data: try exteralessRetentionEncode(index)))
            } catch { self.report(error) }
        }.start()
    }

    private func dropMedia(entry: ExteralessRetentionMediaEntry, epoch: String, error: ExteralessRetentionError, work: RetentionOperationWork) {
        guard work.isCurrent, !self.operationIsStopped else { return }
        self.report(error)
        let _ = self.postbox.transaction { [weak self] transaction -> Void in
            guard let self, !self.operationIsStopped, work.isCurrent else { return }
            do {
                guard var index = try ExteralessRetentionIndex.load(transaction: transaction, accountPeerId: self.accountPeerId), index.epoch == epoch,
                       index.media[entry.id]?.token == entry.token else { return }
                var ownership = try RetentionMediaOwnership.load(transaction: transaction, accountPeerId: self.accountPeerId)
                try ownership.retire([entry])
                try ownership.save(transaction: transaction)
                index.media.removeValue(forKey: entry.id)
                guard index.revision < UInt64.max else { throw ExteralessRetentionError.limitExceeded }
                index.revision += 1
                transaction.putItemCacheEntry(id: exteralessRetentionIndexId, entry: CodableEntry(data: try exteralessRetentionEncode(index)))
            } catch { self.report(error) }
        }.start()
    }

    private func failMedia(entry: ExteralessRetentionMediaEntry, epoch: String, error: Error, work: RetentionOperationWork) {
        guard work.isCurrent, !self.operationIsStopped else { return }
        self.report(error)
        let _ = self.postbox.transaction { [weak self] transaction -> Void in
            guard let self, !self.operationIsStopped, work.isCurrent else { return }
            do {
                guard var index = try ExteralessRetentionIndex.load(transaction: transaction, accountPeerId: self.accountPeerId), index.epoch == epoch,
                      var value = index.media[entry.id], value.token == entry.token, value.state != .stored else { return }
                value.state = .failed
                index.media[entry.id] = value
                guard index.revision < UInt64.max else { throw ExteralessRetentionError.limitExceeded }
                index.revision += 1
                transaction.putItemCacheEntry(id: exteralessRetentionIndexId, entry: CodableEntry(data: try exteralessRetentionEncode(index)))
            } catch { self.report(error) }
        }.start()
    }

    private func admitMedia(resourceId: String, versionOwner: RetentionMediaVersionOwner? = nil, cancelled: @escaping () -> Bool) throws -> RetentionMediaAdmission {
        try retentionFileTransaction(postbox: self.postbox, cancelled: cancelled) { transaction in
            guard let policy = self.loadedPolicy else { throw ExteralessRetentionError.unavailable }
            return try retentionAdmitMedia(transaction: transaction, accountPeerId: self.accountPeerId, policy: policy, now: self.clock(), resourceId: resourceId, versionOwner: versionOwner)
        }
    }

    func materialize(resourceId: String, pathExtension: String? = nil, versionOwner: RetentionMediaVersionOwner? = nil, provenance: RetentionResourceProvenance? = nil) -> Signal<Result<ExteralessRetainedResourceFile, ExteralessRetentionError>, NoError> {
        return Signal { [weak self] subscriber in
            guard let self, let admission = self.ownerState.captureWork() else { subscriber.putNext(.failure(.unavailable)); subscriber.putCompletion(); return EmptyDisposable }
            let work = admission.work
            let cancelled = { !work.isCurrent || self.operationIsStopped }
            self.mediaQueue.async {
                let result: Result<ExteralessRetainedResourceFile, ExteralessRetentionError>
                do {
                    let file = try self.vault.fileLock.withLock(cancelled: cancelled) {
                        let admission = try self.admitMedia(resourceId: resourceId, versionOwner: versionOwner, cancelled: cancelled)
                        if let provenance, !provenance.matches(admission) { throw ExteralessRetentionError.mediaUnavailable }
                        let entry = admission.entry
                        var data = try retentionFileValue(self.postbox.mediaBox.resourceData(id: entry.cacheId, pathExtension: pathExtension), cancelled: cancelled)
                        if !data.complete || data.size <= 0 {
                            guard entry.state == .stored else { throw ExteralessRetentionError.mediaUnavailable }
                            let temporary = try self.vault.restore(entry: entry, index: admission.index, nativeCacheDirectory: URL(fileURLWithPath: self.postbox.mediaBox.basePath, isDirectory: true), cancelled: cancelled)
                            defer { try? FileManager.default.removeItem(at: temporary) }
                            if cancelled() { throw ExteralessRetentionError.cancelled }
                            self.postbox.mediaBox.moveResourceData(entry.cacheId, fromTempPath: temporary.path)
                            data = try retentionFileValue(self.postbox.mediaBox.resourceData(id: entry.cacheId, pathExtension: pathExtension), cancelled: cancelled)
                        }
                        let final = try self.admitMedia(resourceId: resourceId, versionOwner: versionOwner, cancelled: cancelled)
                        guard final.entry.token == entry.token, final.index.epoch == admission.index.epoch,
                              data.complete, data.size > 0, data.size == final.entry.storedBytes else { throw ExteralessRetentionError.mediaUnavailable }
                        let attributes = try FileManager.default.attributesOfItem(atPath: data.path)
                        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.int64Value == data.size else { throw ExteralessRetentionError.mediaIO }
                        return ExteralessRetainedResourceFile(url: URL(fileURLWithPath: data.path), byteCount: data.size)
                    }
                    result = cancelled() ? .failure(.cancelled) : .success(file)
                } catch { result = .failure(exteralessRetentionError(error)) }
                subscriber.putNext(result)
                subscriber.putCompletion()
            }
            return ActionDisposable { work.cancel() }
        }
        |> timeout(25.0, queue: self.queue, alternate: .single(.failure(.mediaIO)))
    }

    func cleanupUnownedMedia() -> Signal<Result<Void, ExteralessRetentionError>, NoError> {
        return Signal { subscriber in
            guard self.performsMaintenance else { subscriber.putNext(.failure(.unavailable)); subscriber.putCompletion(); return EmptyDisposable }
            self.cleanupMediaFiles(keeping: [], generation: nil) { result in
                subscriber.putNext(result)
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
    }

    private func cleanupMediaFiles(keeping _: Set<String>, generation: UInt64?, completion: @escaping (Result<Void, ExteralessRetentionError>) -> Void) {
        guard let admission = self.ownerState.captureWork(), admission.configuration.performsMaintenance else { completion(.failure(.unavailable)); return }
        self.mediaQueue.async {
            if let generation {
                self.lifetimeLock.lock()
                let valid = !self.clearing && !self.stopped && self.mutationGeneration == generation
                self.lifetimeLock.unlock()
                guard valid else { completion(.failure(.cancelled)); return }
            }
            do {
                let cancelled = { !admission.work.isCurrent || self.operationIsStopped || !self.performsMaintenance }
                try self.vault.fileLock.withLock(cancelled: cancelled) { try self.drainDeletionJournal(resetting: false, cancelled: cancelled) }
                completion(.success(()))
            } catch { completion(.failure(exteralessRetentionError(error))) }
        }
    }

    /// Caller holds the account's OS file lock throughout planning, file removal, fsync and ack.
    private func drainDeletionJournal(resetting: Bool, cancelled: @escaping () -> Bool) throws {
        let discovered = try self.vault.orphanedTokens(keeping: [])
        let plan: [String: String] = try retentionFileTransaction(postbox: self.postbox, cancelled: cancelled) { transaction in
            guard let state = transaction.getState() as? AuthorizedAccountState, state.peerId == self.accountPeerId else { throw ExteralessRetentionError.unavailable }
            let index: ExteralessRetentionIndex?
            if resetting { index = nil }
            else { index = try ExteralessRetentionIndex.load(transaction: transaction, accountPeerId: self.accountPeerId) }
            if resetting, transaction.retrieveItemCacheEntry(id: exteralessRetentionIndexId) != nil { throw ExteralessRetentionError.cancelled }
            let liveTokens = Set(index?.media.values.map(\.token) ?? [])
            let liveIds = Set(index?.media.values.map { $0.cacheId.stringRepresentation } ?? [])
            var ownership = try RetentionMediaOwnership.load(transaction: transaction, accountPeerId: self.accountPeerId)
            for entry in index?.media.values.map({ $0 }) ?? [] { try ownership.enroll(token: entry.token) }
            for token in discovered.subtracting(liveTokens) {
                guard let id = RetentionMediaOwnership.nativeId(token: token), !liveIds.contains(id) else { continue }
                try ownership.enroll(token: token)
            }
            ownership.pending.formUnion(Set(ownership.owned.keys).subtracting(liveTokens))
            let plan = ownership.owned.filter { ownership.pending.contains($0.key) && !liveTokens.contains($0.key) && !liveIds.contains($0.value) }
            // Durable union is committed BEFORE any native file is unlinked.
            try ownership.save(transaction: transaction)
            return plan
        }
        guard !plan.isEmpty else { try self.vault.removeOrphans([]); return }
        let nativeIds = Set(plan.values)
        self.lifetimeLock.lock()
        let released = self.pins.filter { nativeIds.contains($0.key) }
        for id in released.keys { self.pins.removeValue(forKey: id) }
        self.lifetimeLock.unlock()
        for lease in released.values { lease.dispose() }
        _ = try retentionFileValue(self.postbox.mediaBox.removeCachedResources(nativeIds.map(MediaResourceId.init), force: true, notify: true) |> filter { _ in false } |> map { _ in () } |> then(.single(())), cancelled: cancelled)
        try self.removeOwnedCacheAliases(ids: nativeIds)
        try self.vault.removeOrphans(Set(plan.keys))
        _ = try retentionFileTransaction(postbox: self.postbox, cancelled: cancelled) { transaction -> Bool in
            let index: ExteralessRetentionIndex?
            if resetting { index = nil }
            else { index = try ExteralessRetentionIndex.load(transaction: transaction, accountPeerId: self.accountPeerId) }
            let liveTokens = Set(index?.media.values.map(\.token) ?? [])
            var ownership = try RetentionMediaOwnership.load(transaction: transaction, accountPeerId: self.accountPeerId)
            for (token, id) in plan where !liveTokens.contains(token) && ownership.owned[token] == id {
                ownership.owned.removeValue(forKey: token)
                ownership.pending.remove(token)
            }
            try ownership.save(transaction: transaction)
            return true
        }
    }

    private func removeOwnedCacheAliases(ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        // MediaBox.resourceData(pathExtension:) creates real hard links, and cached image/video
        // representations have id[:representation] names. Removing only the primary path leaks
        // those bytes. Only files derived from the retired archive's proven native ids qualify.
        let root = URL(fileURLWithPath: self.postbox.mediaBox.basePath, isDirectory: true)
        for suffix in ["", "cache", "short-cache", "animation-cache"] {
            let directory = suffix.isEmpty ? root : root.appendingPathComponent(suffix, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path), let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { continue }
            for case let url as URL in iterator {
                let name = url.lastPathComponent
                var id = String(name.prefix { $0 != "." && $0 != ":" })
                if id.hasSuffix("_partial") { id = String(id.dropLast("_partial".count)) }
                if ids.contains(id), try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    try FileManager.default.removeItem(at: url)
                }
            }
            try self.vault.synchronizeDirectories(from: directory)
        }
    }

    /// Explicit full reset, including future/invalid formats. The marker is durable and blocks
    /// capture until all 20,000 possible row keys AND encrypted files have been cleared. A crash
    /// resumes the same reset on next open. No collection-wide API is used.
    func clearAll() -> Signal<Result<Void, ExteralessRetentionError>, NoError> {
        return Signal { [weak self] subscriber in
            guard let self, self.performsMaintenance, self.loadedPolicy != nil else { subscriber.putNext(.failure(.unavailable)); subscriber.putCompletion(); return EmptyDisposable }
            self.lifetimeLock.lock()
            let canBegin = !self.clearing && !self.stopped
            if canBegin { self.clearing = true; self.mutationGeneration &+= 1 }
            self.lifetimeLock.unlock()
            guard canBegin else { subscriber.putNext(.failure(.unavailable)); subscriber.putCompletion(); return EmptyDisposable }
            guard self.ownerState.beginAttempt() != nil, let admission = self.ownerState.captureWork() else {
                self.endClear(); subscriber.putNext(.failure(.unavailable)); subscriber.putCompletion(); return EmptyDisposable
            }
            // Cleanup continues after dismissal. Cancellation only detaches this subscriber;
            // leaving a partly-cleared archive writable would race a new capture.
            self.queue.async {
                for lease in self.leases.values { lease.dispose() }
                self.leases.removeAll()
                self.lifetimeLock.lock()
                let pins = self.pins
                self.pins.removeAll()
                self.archiveSources.removeAll()
                self.lifetimeLock.unlock()
                for pin in pins.values { pin.dispose() }
            }
            self.mediaQueue.async {
                let deadline = ProcessInfo.processInfo.systemUptime + 25
                let cancelled = { !admission.work.isCurrent || !self.performsMaintenance || ProcessInfo.processInfo.systemUptime >= deadline }
                let result: Result<Void, ExteralessRetentionError>
                do {
                    try self.vault.fileLock.withLock(cancelled: cancelled) {
                        let orphans = try self.vault.orphanedTokens(keeping: [])
                        _ = try retentionFileTransaction(postbox: self.postbox, cancelled: cancelled) { transaction -> Bool in
                            guard let state = transaction.getState() as? AuthorizedAccountState, state.peerId == self.accountPeerId else { throw ExteralessRetentionError.unavailable }
                            var ownership = try RetentionMediaOwnership.load(transaction: transaction, accountPeerId: self.accountPeerId)
                            if let raw = transaction.retrieveItemCacheEntry(id: exteralessRetentionIndexId), let index = try? JSONDecoder().decode(ExteralessRetentionIndex.self, from: raw.data) {
                                guard index.accountPeerId == self.accountPeerId.toInt64() else { throw ExteralessRetentionError.invalidArchive }
                                try ownership.retire(Array(index.media.values))
                            }
                            for token in orphans { try ownership.enroll(token: token) }
                            ownership.pending.formUnion(ownership.owned.keys)
                            try ownership.save(transaction: transaction)
                            transaction.putItemCacheEntry(id: exteralessRetentionResetId, entry: CodableEntry(data: Data([1])))
                            transaction.removeItemCacheEntry(id: exteralessRetentionIndexId)
                            transaction.removeItemCacheEntry(id: retentionArchivePeersId)
                            RetentionAlbumIdentities.clear(transaction: transaction)
                            return true
                        }
                        for start in stride(from: 0, to: exteralessRetentionSlotCount, by: 256) {
                            _ = try retentionFileTransaction(postbox: self.postbox, cancelled: cancelled) { transaction -> Bool in
                                for slot in start ..< min(start + 256, exteralessRetentionSlotCount) { transaction.removeItemCacheEntry(id: exteralessRetentionRowId(slot)) }
                                return true
                            }
                        }
                        try self.drainDeletionJournal(resetting: true, cancelled: cancelled)
                        try self.vault.clear()
                        _ = try retentionFileTransaction(postbox: self.postbox, cancelled: cancelled) { transaction -> Bool in
                            transaction.removeItemCacheEntry(id: exteralessRetentionResetId)
                            return true
                        }
                    }
                    result = .success(())
                } catch { result = .failure(exteralessRetentionError(error)) }
                self.endClear()
                switch result {
                case .success: self.failure.set(nil); self.refresh()
                case let .failure(error): self.report(error); self.ownerState.complete(admission, error: error)
                }
                subscriber.putNext(result)
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
    }

    private func endClear() {
        self.lifetimeLock.lock()
        self.clearing = false
        self.mutationGeneration &+= 1
        self.lifetimeLock.unlock()
    }
}

func exteralessRetentionError(_ error: Error) -> ExteralessRetentionError {
    if let error = error as? ExteralessRetentionError { return error }
    if let error = error as? RetentionArchiveError {
        switch error {
        case .unsupportedVersion: return .unsupportedFormat
        case .limitExceeded: return .limitExceeded
        case .invalidData: return .invalidArchive
        }
    }
    if error is DecodingError { return .invalidArchive }
    return .mediaIO
}
