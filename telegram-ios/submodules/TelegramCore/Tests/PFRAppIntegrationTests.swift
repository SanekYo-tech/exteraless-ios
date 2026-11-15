import Foundation
import Postbox
import SwiftSignalKit
import XCTest
@testable import ExteralessCore
@testable import TelegramCore

/// Production publication/startup lifetimes with immutable synthetic settings
/// and scope recorders. No Account, Network, Keychain, filesystem or UI is opened.
final class PFRAppIntegrationTests: XCTestCase {
    private final class SettingsSource: @unchecked Sendable {
        private let lock = NSLock()
        private var days: Int64 = 30
        private var failed = false

        func set(days: Int64, failed: Bool) {
            self.lock.lock(); self.days = days; self.failed = failed; self.lock.unlock()
        }

        func read() -> ClientSettingsSnapshot {
            self.lock.lock(); let days = self.days; let failed = self.failed; self.lock.unlock()
            var values = Dictionary(uniqueKeysWithValues: RetentionFeatures.definitions.map { ($0.key, $0.defaultValue) })
            values["privacy.retentionDays"] = .integer(days)
            return ClientSettingsSnapshot(definitions: RetentionFeatures.definitions, values: values,
                storedKeys: ["privacy.retentionDays"], lastError: failed ? .storageFailure(operation: "sync-directory", code: 5) : nil)
        }
    }

    private final class States: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ExteralessAccountRetentionSnapshot] = []
        func append(_ state: ExteralessAccountRetentionSnapshot) { self.lock.lock(); self.storage.append(state); self.lock.unlock() }
        var values: [ExteralessAccountRetentionSnapshot] { self.lock.lock(); defer { self.lock.unlock() }; return self.storage }
    }

    private func configuration(_ source: SettingsSource) throws -> ExteralessRetentionProcessConfiguration {
        return try ExteralessRetentionProcessConfiguration(role: .mainApplication, snapshot: source.read(),
            durabilityRootURL: URL(fileURLWithPath: "/synthetic-retention-container", isDirectory: true))
    }

    func testPFR02HeldErrorObserverCannotRegressRecoveryOrNewSubscriber() throws {
        let input = SettingsSource()
        let environment = ExteralessAccountRetentionEnvironment(readSnapshot: { input.read() })
        let seed = try self.configuration(input)
        try environment.configure(seed)
        let errorEntered = DispatchSemaphore(value: 0)
        let releaseError = DispatchSemaphore(value: 0)
        let oldFinished = DispatchSemaphore(value: 0)
        let recovered = DispatchSemaphore(value: 0)
        let states = States()
        let normal = environment.states.start(next: { states.append($0) })
        let errors = environment.errors.start(next: { state in
            guard state.version == 2 else { return }
            XCTAssertNotNil(state.error)
            _ = environment.current // Reentry must not hold the environment lock.
            errorEntered.signal()
            XCTAssertEqual(releaseError.wait(timeout: .now() + 0.5), .success)
        })
        defer { releaseError.signal(); normal.dispose(); errors.dispose() }
        DispatchQueue.global().async {
            input.set(days: 90, failed: true)
            try? environment.configure(seed)
            oldFinished.signal()
        }
        XCTAssertEqual(errorEntered.wait(timeout: .now() + 0.5), .success)
        DispatchQueue.global().async {
            input.set(days: 90, failed: false)
            try? environment.configure(seed)
            recovered.signal()
        }
        XCTAssertEqual(recovered.wait(timeout: .now() + 0.5), .success)
        let latest = environment.current
        XCTAssertNil(latest.error)
        XCTAssertEqual(latest.configuration?.policy.days, 90)
        let replay = States()
        let newSubscriber = environment.states.start(next: { replay.append($0) })
        defer { newSubscriber.dispose() }
        XCTAssertEqual(replay.values.last?.version, latest.version)
        releaseError.signal()
        XCTAssertEqual(oldFinished.wait(timeout: .now() + 0.5), .success)
        XCTAssertEqual(states.values.last?.version, environment.current.version)
        XCTAssertEqual(states.values.last?.configuration?.policy.days, 90)
        let versions = states.values.map(\.version)
        XCTAssertEqual(versions, Array(Set(versions)).sorted())
    }

    func testPFR02ReentrantRecoveryUsesOneVersionedState() throws {
        let input = SettingsSource()
        let environment = ExteralessAccountRetentionEnvironment(readSnapshot: { input.read() })
        let seed = try self.configuration(input)
        try environment.configure(seed)
        let done = DispatchSemaphore(value: 0)
        let states = States()
        let disposable = environment.states.start(next: { state in
            states.append(state)
            if state.version == 2, state.error != nil {
                input.set(days: 90, failed: false)
                try? environment.configure(seed)
            }
        })
        defer { disposable.dispose() }
        DispatchQueue.global().async {
            input.set(days: 90, failed: true)
            try? environment.configure(seed)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 0.5), .success)
        XCTAssertEqual(states.values.map(\.version), [1, 2, 3])
        XCTAssertNotNil(states.values.first(where: { $0.version == 2 })?.error)
        XCTAssertEqual(states.values.last?.configuration?.policy.days, 90)
        XCTAssertEqual(states.values.last?.version, environment.current.version)
    }

    private final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var transfers = 0
        private var disposals = 0
        var values: (Int, Int) { self.lock.lock(); defer { self.lock.unlock() }; return (self.transfers, self.disposals) }
        func transferred() { self.lock.lock(); self.transfers += 1; self.lock.unlock() }
        func disposed() { self.lock.lock(); self.disposals += 1; self.lock.unlock() }
    }

    private final class Writer {
        let scope: Disposable
        init(_ scope: Disposable) { self.scope = scope }
        deinit { self.scope.dispose() }
    }

    func testPFR03CallerCancellationAtReadyAndNetworkWaitRejectsLateTransfer() {
        for holdNetwork in [false, true] {
            let lifetime = ExteralessStateManagerStartupLifetime()
            let ready = ValuePipe<Bool>()
            let network = ValuePipe<Bool>()
            let counts = Counts()
            let scope = ExteralessRetentionWriterLease(dispose: { counts.disposed() })
            var lateTransfer: (() -> Bool)?
            var deliveries = 0
            lifetime.start({ token -> Signal<Writer?, NoError> in
                lateTransfer = { token.admitTransfer { scope.transferToWriter() } }
                return (ready.signal() |> take(1)
                |> mapToSignal { _ in network.signal() |> take(1) }
                |> map { _ -> Writer? in
                    guard token.admitTransfer({ scope.transferToWriter() }) else { return nil }
                    counts.transferred()
                    return Writer(scope)
                }) |> afterDisposed { scope.cancelBeforeTransfer() }
            }, next: { _ in deliveries += 1 })
            if holdNetwork { ready.putNext(true) }
            lifetime.dispose()
            ready.putNext(true)
            network.putNext(true)
            XCTAssertEqual(lateTransfer?(), false)
            XCTAssertEqual(deliveries, 0)
            XCTAssertEqual(counts.values.0, 0)
            XCTAssertEqual(counts.values.1, 1)
            lifetime.dispose()
            XCTAssertEqual(counts.values.1, 1)
        }
    }

    func testPFR03SuccessfulTransferLivesUntilWriterTeardown() {
        let lifetime = ExteralessStateManagerStartupLifetime()
        let ready = ValuePipe<Bool>()
        let network = ValuePipe<Bool>()
        let counts = Counts()
        let scope = ExteralessRetentionWriterLease(dispose: { counts.disposed() })
        var writer: Writer?
        lifetime.start({ token -> Signal<Writer?, NoError> in
            return (ready.signal() |> take(1)
            |> mapToSignal { _ in network.signal() |> take(1) }
            |> map { _ -> Writer? in
                guard token.admitTransfer({ scope.transferToWriter() }) else { return nil }
                counts.transferred()
                return Writer(scope)
            }) |> afterDisposed { scope.cancelBeforeTransfer() }
        }, next: { writer = $0 })
        ready.putNext(true)
        network.putNext(true)
        XCTAssertNotNil(writer)
        lifetime.dispose()
        XCTAssertEqual(counts.values.0, 1)
        XCTAssertEqual(counts.values.1, 0)
        XCTAssertFalse(scope.transferToWriter())
        writer = nil
        XCTAssertEqual(counts.values.1, 1)
        scope.dispose()
        XCTAssertEqual(counts.values.1, 1)
    }

    func testPFR03ReplacementAndCallerDeinitDisposeHeldStartupOnce() {
        let counts = Counts()
        var lifetime: ExteralessStateManagerStartupLifetime? = ExteralessStateManagerStartupLifetime()
        let first = ExteralessRetentionWriterLease(dispose: { counts.disposed() })
        let second = ExteralessRetentionWriterLease(dispose: { counts.disposed() })
        let ready = ValuePipe<Bool>()
        var oldTransfer: (() -> Bool)?
        var newTransfer: (() -> Bool)?
        lifetime?.start({ token in
            oldTransfer = { token.admitTransfer { first.transferToWriter() } }
            return ready.signal() |> afterDisposed { first.cancelBeforeTransfer() }
        }, next: { _ in XCTFail("retired first delivery") })
        lifetime?.start({ token in
            newTransfer = { token.admitTransfer { second.transferToWriter() } }
            return ready.signal() |> afterDisposed { second.cancelBeforeTransfer() }
        }, next: { _ in XCTFail("retired replacement delivery") })
        XCTAssertEqual(oldTransfer?(), false)
        XCTAssertEqual(counts.values.1, 1)
        lifetime = nil
        ready.putNext(true)
        XCTAssertEqual(newTransfer?(), false)
        XCTAssertEqual(counts.values.1, 2)
    }

    func testPFR04SupersededNetworkAttemptCannotConstructAWriter() throws {
        let configuration = try self.configuration(SettingsSource())
        let owner = RetentionOwnerState(.init(version: 1, availability: .available(configuration)))
        owner.complete(try XCTUnwrap(owner.captureWork(readiness: true)))
        let firstNetwork = ValuePipe<Int>()
        let secondNetwork = ValuePipe<Int>()
        let firstEntered = self.expectation(description: "first held network")
        let secondEntered = self.expectation(description: "replacement held network")
        let done = self.expectation(description: "single current factory continuation")
        let cleaned = self.expectation(description: "factory subscription released")
        let counts = Counts()
        let scope = ExteralessRetentionWriterLease(dispose: { counts.disposed() })
        let recovery = ExteralessAccountRetentionRecovery(accountRecordId: 1, canResetArchive: false,
            awaitReady: { owner.awaitReadiness(timeout: 0.25) }, retryReady: {
                owner.beginAttempt()
                if let work = owner.captureWork(readiness: true) { owner.complete(work) }
                return owner.awaitReadiness(timeout: 0.25)
            }, resetArchive: { XCTFail("unexpected reset"); return .single(.failure(.unavailable)) },
            isCurrent: { owner.isCurrent($0) })
        var starts = 0
        var writer: Writer?
        let disposable = exteralessAccountRetentionStartup(recovery: recovery, prepare: { _, _ in
            starts += 1
            let network = starts == 1 ? firstNetwork : secondNetwork
            let entered = starts == 1 ? firstEntered : secondEntered
            return Signal<Int, NoError> { subscriber in
                let disposable = network.signal().start(next: subscriber.putNext, completed: subscriber.putCompletion)
                entered.fulfill()
                return disposable
            }
        }, construct: { value, readiness, startup -> Writer? in
            guard startup.admitTransfer({ owner.isCurrent(readiness) && scope.transferToWriter() }) else { return nil }
            XCTAssertEqual(value, 2)
            counts.transferred()
            return Writer(scope)
        }, disposed: { scope.cancelBeforeTransfer(); cleaned.fulfill() }).start(next: { result in
            if case let .ready(value) = result { writer = value }
            else { XCTFail("valid replacement unexpectedly failed") }
        }, completed: { done.fulfill() })
        defer { disposable.dispose(); owner.close() }
        self.wait(for: [firstEntered], timeout: 0.5)
        recovery.retry()
        self.wait(for: [secondEntered], timeout: 0.5)
        firstNetwork.putNext(1)
        secondNetwork.putNext(2)
        self.wait(for: [done, cleaned], timeout: 0.5)
        XCTAssertTrue(recovery.isDisposed)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(counts.values.0, 1)
        XCTAssertEqual(counts.values.1, 0)
        XCTAssertNotNil(writer)
        writer = nil
        scope.dispose()
        XCTAssertEqual(counts.values.1, 1)
    }
    func testPFR04RevokedReadinessAtNetworkHopCannotTransfer() throws {
        let configuration = try self.configuration(SettingsSource())
        let owner = RetentionOwnerState(.init(version: 1, availability: .available(configuration)))
        owner.complete(try XCTUnwrap(owner.captureWork(readiness: true)))
        let network = ValuePipe<Int>()
        let entered = self.expectation(description: "held network producer installed")
        let failed = self.expectation(description: "revoked factory emits recovery")
        let counts = Counts()
        let scope = ExteralessRetentionWriterLease(dispose: { counts.disposed() })
        let recovery = ExteralessAccountRetentionRecovery(accountRecordId: 2, canResetArchive: false,
            awaitReady: { owner.awaitReadiness(timeout: 0.25) }, retryReady: { owner.awaitReadiness(timeout: 0.25) },
            resetArchive: { XCTFail("unexpected reset"); return .single(.failure(.unavailable)) }, isCurrent: { owner.isCurrent($0) })
        let disposable = exteralessAccountRetentionStartup(recovery: recovery, prepare: { _, _ in
            Signal<Int, NoError> { subscriber in
                let disposable = network.signal().start(next: subscriber.putNext, completed: subscriber.putCompletion)
                entered.fulfill()
                return disposable
            }
        }, construct: { _, readiness, startup -> Writer? in
            guard startup.admitTransfer({ owner.isCurrent(readiness) && scope.transferToWriter() }) else { return nil }
            counts.transferred()
            return Writer(scope)
        }, disposed: { scope.cancelBeforeTransfer() }).start(next: { result in
            guard case let .recovery(handle) = result else { XCTFail("revoked factory constructed a writer"); return }
            XCTAssertEqual(handle.currentStatus, .failed(.configurationUnavailable))
            failed.fulfill()
        })
        defer { disposable.dispose(); owner.close() }
        self.wait(for: [entered], timeout: 0.5)
        XCTAssertTrue(owner.update(.init(version: 2, availability: .unavailable)))
        network.putNext(1)
        self.wait(for: [failed], timeout: 0.5)
        XCTAssertEqual(counts.values.0, 0)
        disposable.dispose()
        XCTAssertEqual(counts.values.1, 1)
    }
}

private final class PFRFixtureSecrets: ClientSecretStore {
    func data(for key: String) throws -> Data? { nil }
    func set(_ data: Data?, for key: String) throws { throw ExteralessRetentionError.unavailable }
}

private final class PFRCommitFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    func arm() { self.lock.lock(); self.armed = true; self.lock.unlock() }
    func check() throws {
        self.lock.lock(); let armed = self.armed; self.armed = false; self.lock.unlock()
        if armed { throw ClientSettingsError.storageFailure(operation: "fixture post-rename sync", code: 5) }
    }
}

/// Actual encrypted disposable Postboxes, ClientSettings' post-rename failure
/// seam, and the same scope/factory helper as Account.swift. Network is injected.
/// Each test has a 25 s budget; no live Account, transport, Keychain or UIKit.
final class PFRNativeAccountStartupTests: XCTestCase {
    private var roots: [URL] = []
    private var postboxes: [Postbox] = []
    private var scopes: [ExteralessAccountRetentionScope] = []
    private var deadline: Double = 0
    private let accountId = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(730001))
    private let peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(730002))
    private let now: Int64 = 1_800_000_000

    override func setUp() {
        super.setUp()
        self.deadline = ProcessInfo.processInfo.systemUptime + 25
        initializeAccountManagement()
    }

    override func tearDown() {
        for scope in self.scopes { scope.dispose() }
        self.scopes.removeAll(); self.postboxes.removeAll()
        for root in self.roots { try? FileManager.default.removeItem(at: root) }
        self.roots.removeAll()
        super.tearDown()
    }

    private func waitBudget(_ expectations: [XCTestExpectation], seconds: Double = 3) {
        self.wait(for: expectations, timeout: max(0.01, min(seconds, self.deadline - ProcessInfo.processInfo.systemUptime)))
    }

    private func value<T>(_ signal: Signal<T, NoError>) throws -> T {
        let done = self.expectation(description: "bounded synthetic adapter")
        var result: T?
        let disposable = signal.start(next: { result = $0 }, completed: { done.fulfill() })
        self.waitBudget([done]); disposable.dispose()
        return try XCTUnwrap(result)
    }

    private func transaction<T>(_ postbox: Postbox, _ body: @escaping (Transaction) throws -> T) throws -> T {
        let result: Result<T, Error> = try self.value(postbox.transaction { transaction in Result { try body(transaction) } })
        return try result.get()
    }

    private func fixture(role: ExteralessRetentionProcessRole) throws -> (Postbox, ClientSettings, ExteralessAccountRetentionEnvironment, PFRCommitFault) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pfr-startup-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.roots.append(root)
        let fault = PFRCommitFault()
        let settings = try ClientSettings(storageURL: root.appendingPathComponent("settings.json"), secretStore: PFRFixtureSecrets(),
            afterFileReplace: { try fault.check() }, durabilityRootURL: root)
        try settings.register(RetentionFeatures.definitions)
        try settings.applyPublic(["privacy.retentionDays": .integer(90), "privacy.enableSaveDeletedMessages": .bool(true)])
        let environment = ExteralessAccountRetentionEnvironment(settings: settings)
        try environment.configure(.init(role: role, snapshot: settings.readSnapshot(), durabilityRootURL: root))
        let encryption = ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true,
            key: .init(data: Data(repeating: 0x36, count: 32))!, salt: .init(data: Data(repeating: 0x63, count: 16))!)
        let opened = try self.value(openPostbox(basePath: root.appendingPathComponent("postbox").path,
            seedConfiguration: telegramPostboxSeedConfiguration, encryptionParameters: encryption,
            timestampForAbsoluteTimeBasedOperations: Int32(self.now), isMainProcess: false, isTemporary: false,
            isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            |> filter { if case .upgrading = $0 { return false }; return true } |> take(1))
        guard case let .postbox(postbox) = opened else { throw ExteralessRetentionError.unavailable }
        self.postboxes.append(postbox)
        postbox.mediaBox.fetchResource = { _, _, _ in XCTFail("unexpected native transport"); return .fail(.generic) }
        try self.transaction(postbox) { transaction in
            transaction.setState(AuthorizedAccountState(isTestingEnvironment: false, masterDatacenterId: 2,
                peerId: self.accountId, state: .init(pts: 51, qts: 52, date: Int32(self.now), seq: 53), invalidatedChannels: []))
            let user = TelegramUser(id: self.peerId, accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil,
                photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
                nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
            transaction.updatePeersInternal([user], update: { _, value in value })
        }
        return (postbox, settings, environment, fault)
    }

    private func scope(_ postbox: Postbox, _ environment: ExteralessAccountRetentionEnvironment) -> ExteralessAccountRetentionScope {
        let now = self.now
        let owner = ExteralessRetentionAccount(postbox: postbox, accountPeerId: self.accountId,
            configurationState: environment.current.configurationState, clock: { now })
        let scope = ExteralessAccountRetentionScope(account: owner, environment: environment)
        self.scopes.append(scope)
        return scope
    }

    private func assertCounters(_ transaction: Transaction) {
        let state = (transaction.getState() as? AuthorizedAccountState)?.state
        XCTAssertEqual(state?.pts, 51); XCTAssertEqual(state?.qts, 52); XCTAssertEqual(state?.seq, 53)
    }

    func testPFR01BothWriterRolesRevokeHeldPruneAfterRealCommittedSettingsFailure() throws {
        for role in [ExteralessRetentionProcessRole.mainApplication, .notificationService] {
            let (postbox, settings, environment, fault) = try self.fixture(role: role)
            try self.transaction(postbox) { transaction in
                let id = MessageId(peerId: self.peerId, namespace: Namespaces.Message.Cloud, id: 1)
                _ = transaction.addMessages([StoreMessage(id: id, customStableId: nil, globallyUniqueId: nil, groupingKey: nil,
                    threadId: nil, timestamp: Int32(self.now - 60 * 86400 - 100), flags: [.Incoming], tags: [], globalTags: [], localTags: [],
                    forwardInfo: nil, authorId: self.peerId, text: "synthetic received row", attributes: [], media: [])], location: .Random)
                let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: self.accountId,
                    policy: try XCTUnwrap(environment.current.configuration).policy, now: self.now - 60 * 86400)
                XCTAssertTrue(try store.captureDeleted(XCTUnwrap(transaction.getMessage(id)), mediaBox: postbox.mediaBox))
                _ = try store.finish()
            }
            let scope = self.scope(postbox, environment), owner = scope.account
            let original = try self.value(owner.awaitReadiness()).get()
            let paused = self.expectation(description: "hold actual Postbox admission")
            postbox.setCanBeginTransactions(false, afterTransactionIfRunning: { paused.fulfill() })
            self.waitBudget([paused], seconds: 0.5)
            defer { postbox.setCanBeginTransactions(true) }
            try settings.set(.integer(30), for: "privacy.retentionDays")
            let thirty = environment.current
            XCTAssertEqual(owner.loadedPolicy?.days, 30)
            let oldWork = owner.operationScope.makeWork()
            owner.refresh(prune: true)
            let revoked = self.expectation(description: "pending readiness revoked through actual binding")
            var failures = 0
            let pending = owner.awaitReadiness(timeout: 0.5).start(next: { result in
                if case let .failure(error) = result { XCTAssertEqual(error, .configurationUnavailable); failures += 1 }
                else { XCTFail("unavailable policy emitted readiness") }
            }, completed: { revoked.fulfill() })
            defer { pending.dispose() }
            fault.arm()
            XCTAssertThrowsError(try settings.set(.integer(90), for: "privacy.retentionDays"))
            XCTAssertEqual(settings.readSnapshot().values["privacy.retentionDays"], .integer(90))
            XCTAssertNotNil(settings.readSnapshot().lastError)
            let unavailable = environment.current
            XCTAssertGreaterThan(unavailable.version, thirty.version)
            XCTAssertNotNil(unavailable.error)
            XCTAssertNil(owner.loadedPolicy)
            XCTAssertFalse(owner.performsMaintenance)
            XCTAssertFalse(oldWork.isCurrent)
            XCTAssertFalse(owner.isReadinessCurrent(original))
            self.waitBudget([revoked], seconds: 0.5)
            XCTAssertEqual(failures, 1)
            postbox.setCanBeginTransactions(true)
            try self.transaction(postbox) { transaction in
                XCTAssertEqual(try ExteralessRetentionIndex.load(transaction: transaction, accountPeerId: self.accountId)?.rows.count, 1)
                self.assertCounters(transaction)
            }
            try settings.reload()
            let recovered = try self.value(owner.awaitReadiness()).get()
            XCTAssertGreaterThan(recovered.configurationVersion, unavailable.version)
            XCTAssertTrue(owner.isReadinessCurrent(recovered))
            XCTAssertFalse(owner.updateConfiguration(thirty.configurationState))
            XCTAssertFalse(owner.updateConfiguration(unavailable.configurationState))
            XCTAssertEqual(owner.loadedPolicy?.days, 90)
            try self.transaction(postbox) { transaction in
                XCTAssertEqual(try ExteralessRetentionIndex.load(transaction: transaction, accountPeerId: self.accountId)?.rows.count, 1)
                self.assertCounters(transaction)
            }
            scope.dispose()
        }
    }

    private final class Writer {
        let scope: ExteralessAccountRetentionScope
        init(_ scope: ExteralessAccountRetentionScope) { self.scope = scope }
        deinit { self.scope.dispose() }
    }

    private func checkFactoryRecovery(explicitReset: Bool) throws {
        let (postbox, _, environment, _) = try self.fixture(role: .mainApplication)
        let empty = try exteralessRetentionEncode(ExteralessRetentionIndex(accountPeerId: self.accountId))
        let corrupt: Data
        if explicitReset {
            var future = try XCTUnwrap(JSONSerialization.jsonObject(with: empty) as? [String: Any])
            future["formatVersion"] = 99
            corrupt = try JSONSerialization.data(withJSONObject: future)
        } else { corrupt = Data([0x7b, 0x7d]) }
        try self.transaction(postbox) { transaction in
            transaction.putItemCacheEntry(id: exteralessRetentionIndexId, entry: CodableEntry(data: corrupt))
        }
        let scope = self.scope(postbox, environment), owner = scope.account
        let recovery = ExteralessAccountRetentionRecovery(accountRecordId: 73, owner: owner, canResetArchive: true)
        let failure = self.expectation(description: "pre-Account factory error")
        let uiFailure = self.expectation(description: "pre-Account presenter error")
        let completed = self.expectation(description: "one successful continuation")
        let disposed = self.expectation(description: "completed factory disposed")
        let expected = ExteralessRetentionReadinessFailure.archive(explicitReset ? .unsupportedFormat : .invalidArchive)
        let presenter = (ExteralessAccountRecoveryCenter.shared.pending
            |> filter { entries in entries.contains { $0.recovery === recovery && $0.status == .failed(expected) } }
            |> take(1)).start(next: { _ in uiFailure.fulfill() })
        defer { presenter.dispose() }
        var networkConstructions = 0, writerConstructions = 0, failures = 0, continuations = 0
        var writer: Writer?
        let startup = exteralessAccountRetentionStartup(recovery: recovery, prepare: { _, _ -> Signal<Void, NoError> in
            networkConstructions += 1
            return .single(())
        }, construct: { _, readiness, startup -> Writer? in
            guard startup.admitTransfer({ owner.isReadinessCurrent(readiness) && scope.transferToWriter() }) else { return nil }
            writerConstructions += 1
            return Writer(scope)
        }, disposed: { scope.cancelBeforeTransfer(); disposed.fulfill() })
        // The failure is a real value in the loader's combineLatest, allowing an
        // already healthy sibling to remain usable while this factory awaits Retry.
        let disposable = combineLatest(startup, Signal<Int, NoError>.single(7)).start(next: { result, sibling in
            XCTAssertEqual(sibling, 7)
            switch result {
            case let .recovery(handle):
                XCTAssertTrue(handle === recovery); XCTAssertEqual(handle.currentStatus, .failed(expected))
                failures += 1; failure.fulfill()
            case let .ready(value): writer = value; continuations += 1
            }
        }, completed: { completed.fulfill() })
        defer { disposable.dispose() }
        self.waitBudget([failure, uiFailure])
        XCTAssertEqual(networkConstructions, 0); XCTAssertEqual(writerConstructions, 0)
        try self.transaction(postbox) { transaction in
            XCTAssertEqual(transaction.retrieveItemCacheEntry(id: exteralessRetentionIndexId)?.data, corrupt)
            XCTAssertNil(transaction.retrieveItemCacheEntry(id: exteralessRetentionResetId))
            self.assertCounters(transaction)
        }
        if explicitReset { recovery.resetRetainedArchive() }
        else {
            try self.transaction(postbox) { transaction in
                transaction.putItemCacheEntry(id: exteralessRetentionIndexId, entry: CodableEntry(data: empty))
            }
            recovery.retry()
        }
        self.waitBudget([completed, disposed], seconds: explicitReset ? 20 : 3)
        XCTAssertTrue(recovery.isDisposed)
        XCTAssertEqual(networkConstructions, 1); XCTAssertEqual(writerConstructions, 1)
        XCTAssertEqual(failures, 1); XCTAssertEqual(continuations, 1)
        XCTAssertNotNil(writer)
        try self.transaction(postbox) { transaction in
            let index = try ExteralessRetentionIndex.load(transaction: transaction, accountPeerId: self.accountId)
            if explicitReset { XCTAssertNil(index) }
            else { XCTAssertNotNil(index) }
            XCTAssertNil(transaction.retrieveItemCacheEntry(id: exteralessRetentionResetId))
            self.assertCounters(transaction)
        }
        writer?.scope.dispose()
        writer = nil
        XCTAssertNil(owner.loadedPolicy)
    }

    func testPFR04FactoryAndPresenterFailBeforeNetworkThenExplicitRepairResumesOnce() throws {
        try self.checkFactoryRecovery(explicitReset: false)
    }

    func testPFR04UnsupportedIndexIsPreservedUntilExplicitResetThenResumesOnce() throws {
        try self.checkFactoryRecovery(explicitReset: true)
    }
}
