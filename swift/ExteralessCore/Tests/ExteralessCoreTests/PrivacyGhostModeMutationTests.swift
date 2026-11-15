import Foundation
import XCTest
@testable import ExteralessCore

private final class GhostMutationBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return storage }
    @discardableResult
    func update<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&storage)
    }
}

private struct GhostMutationSecrets: ClientSecretStore {
    func data(for key: String) throws -> Data? { throw ClientSettingsError.secretAccessDenied }
    func set(_ data: Data?, for key: String) throws { throw ClientSettingsError.secretAccessDenied }
}

private struct GhostMutationEvent {
    let keys: Set<String>
    let snapshot: ClientSettingsSnapshot
    let disk: Data?
}

final class PrivacyGhostModeMutationTests: XCTestCase {
    private let normalValues: [String: ClientSettingValue] = [
        "privacy.sendReadMessagePackets": .bool(true),
        "privacy.sendReadStoriesPackets": .bool(true),
        "privacy.sendOnlinePackets": .bool(true),
        "privacy.sendUploadProgress": .bool(true),
        "privacy.sendOfflinePacketAfterOnline": .bool(false)
    ]
    private let ghostValues: [String: ClientSettingValue] = [
        "privacy.sendReadMessagePackets": .bool(false),
        "privacy.sendReadStoriesPackets": .bool(false),
        "privacy.sendOnlinePackets": .bool(false),
        "privacy.sendUploadProgress": .bool(false),
        "privacy.sendOfflinePacketAfterOnline": .bool(true)
    ]

    private func storageURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-mutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("client-settings.json")
    }

    private func makeStore(at url: URL, afterReplace: (@Sendable () throws -> Void)? = nil,
                           fileHooks: ClientSettingsFileHooks = ClientSettingsFileHooks()) throws -> ClientSettings {
        let store = try ClientSettings(storageURL: url, secretStore: GhostMutationSecrets(), afterFileReplace: afterReplace,
                                       durabilityRootURL: url.deletingLastPathComponent(), fileHooks: fileHooks)
        try store.register(PrivacyFeatures.definitions)
        return store
    }

    private func diskValues(at url: URL) throws -> [String: ClientSettingValue] {
        let root = try JSONDecoder().decode([String: ClientSettingValue].self, from: Data(contentsOf: url))
        guard case let .object(values) = root["values"] else { throw ClientSettingsError.invalidJSON }
        return values
    }

    private func observe(_ store: ClientSettings, at url: URL, into events: GhostMutationBox<[GhostMutationEvent]>) -> ClientSettingsObservation {
        return store.observe { keys in
            let event = GhostMutationEvent(keys: keys, snapshot: store.readSnapshot(), disk: try? Data(contentsOf: url))
            events.update { $0.append(event) }
        }
    }

    func testBothDirectionsAndResetWriteAndObserveOneCompleteGeneration() throws {
        let url = try storageURL()
        let writes = GhostMutationBox(0)
        let store = try makeStore(at: url, afterReplace: { writes.update { $0 += 1 } })
        let baseline = store.readSnapshot()
        XCTAssertTrue(baseline.storedKeys.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let events = GhostMutationBox<[GhostMutationEvent]>([])
        let observation = observe(store, at: url, into: events)
        defer { observation.cancel() }

        for (active, patch) in [(true, ghostValues), (false, normalValues)] {
            events.update { $0.removeAll() }
            let previousWrites = writes.value
            XCTAssertEqual(try PrivacyGhostModeMutation.toggle(in: store), active)
            let expected = baseline.values.merging(patch) { _, new in new }
            XCTAssertEqual(store.snapshot(), expected)
            XCTAssertEqual(store.readSnapshot().storedKeys, Set(normalValues.keys))
            XCTAssertEqual(try diskValues(at: url), patch)
            XCTAssertEqual(writes.value, previousWrites + 1)
            XCTAssertEqual(events.value.count, 1)
            let event = try XCTUnwrap(events.value.first)
            XCTAssertEqual(event.keys, Set(normalValues.keys))
            XCTAssertEqual(event.snapshot.values, expected)
            XCTAssertEqual(event.snapshot.storedKeys, Set(normalValues.keys))
            XCTAssertEqual(event.disk, try Data(contentsOf: url))
        }

        // Disabling deliberately stores defaults. Reset removes those overrides,
        // and the next toggle must start from their absent/default generation.
        events.update { $0.removeAll() }
        try store.applyPublic([:], resetting: Set(normalValues.keys), expected: store.readSnapshot())
        XCTAssertEqual(writes.value, 3)
        XCTAssertEqual(events.value.map(\.keys), [Set(normalValues.keys)])
        XCTAssertEqual(store.snapshot(), baseline.values)
        XCTAssertTrue(store.readSnapshot().storedKeys.isEmpty)
        XCTAssertEqual(try diskValues(at: url), [:])
        events.update { $0.removeAll() }
        XCTAssertTrue(try PrivacyGhostModeMutation.toggle(in: store))
        XCTAssertEqual(writes.value, 4)
        XCTAssertEqual(events.value.map(\.keys), [Set(normalValues.keys)])
        let reopened = try makeStore(at: url)
        XCTAssertEqual(reopened.snapshot(), baseline.values.merging(ghostValues) { _, new in new })
        XCTAssertEqual(reopened.readSnapshot().storedKeys, Set(normalValues.keys))
    }

    func testMixedLockedValuesKeepAbsenceExplicitDefaultsAndOverrides() throws {
        let url = try storageURL()
        let writes = GhostMutationBox(0)
        let store = try makeStore(at: url, afterReplace: { writes.update { $0 += 1 } })
        let seed: [String: ClientSettingValue] = [
            "privacy.sendReadMessagePacketsLocked": .bool(true), // value absent
            "privacy.sendReadStoriesPacketsLocked": .bool(true),
            "privacy.sendReadStoriesPackets": .bool(true), // explicit default
            "privacy.sendOnlinePacketsLocked": .bool(true),
            "privacy.sendOnlinePackets": .bool(false), // non-default override
            "privacy.sendUploadProgressLocked": .bool(false), // explicit default lock
            "privacy.hidePhone": .bool(false)
        ]
        try store.applyPublic(seed)
        let before = store.readSnapshot()
        let events = GhostMutationBox<[GhostMutationEvent]>([])
        let observation = observe(store, at: url, into: events)
        defer { observation.cancel() }
        for active in [true, false] {
            let patch: [String: ClientSettingValue] = [
                "privacy.sendUploadProgress": .bool(!active),
                "privacy.sendOfflinePacketAfterOnline": .bool(active)
            ]
            events.update { $0.removeAll() }
            let previousWrites = writes.value
            XCTAssertEqual(try PrivacyGhostModeMutation.toggle(in: store), active)
            XCTAssertEqual(store.snapshot(), before.values.merging(patch) { _, new in new })
            XCTAssertEqual(store.readSnapshot().storedKeys, before.storedKeys.union(patch.keys))
            XCTAssertEqual(try diskValues(at: url), seed.merging(patch) { _, new in new })
            XCTAssertEqual(writes.value, previousWrites + 1)
            XCTAssertEqual(events.value.map(\.keys), [Set(patch.keys)])
        }
    }

    func testAllLockedReturnsActiveWithoutAReplacementOrObservation() throws {
        let url = try storageURL()
        let writes = GhostMutationBox(0)
        let store = try makeStore(at: url, afterReplace: { writes.update { $0 += 1 } })
        var seed: [String: ClientSettingValue] = [
            "privacy.sendReadStoriesPackets": .bool(true),
            "privacy.sendOnlinePackets": .bool(false),
            "privacy.sendOfflinePacketAfterOnline": .bool(true)
        ]
        for key in normalValues.keys { seed[key + "Locked"] = .bool(true) }
        try store.applyPublic(seed)
        let before = store.readSnapshot()
        let original = try Data(contentsOf: url)
        let previousWrites = writes.value
        let events = GhostMutationBox<[GhostMutationEvent]>([])
        let observation = observe(store, at: url, into: events)
        defer { observation.cancel() }
        XCTAssertTrue(PrivacyPolicy(values: before.values).ghostModeActive)
        for _ in 0..<2 {
            XCTAssertTrue(try PrivacyGhostModeMutation.toggle(in: store))
            XCTAssertEqual(store.snapshot(), before.values)
            XCTAssertEqual(store.readSnapshot().storedKeys, before.storedKeys)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
        XCTAssertEqual(writes.value, previousWrites)
        XCTAssertTrue(events.value.isEmpty)
    }

    func testPreAndPostReplaceFailuresExposeOnlyWholeStates() throws {
        for beforeReplace in [true, false] {
            let url = try storageURL()
            let fail = GhostMutationBox(false)
            let attempts = GhostMutationBox(0)
            let writes = GhostMutationBox(0)
            let hooks = ClientSettingsFileHooks(beforeFileReplace: {
                attempts.update { $0 += 1 }
                if beforeReplace && fail.value { throw NSError(domain: NSPOSIXErrorDomain, code: 5) }
            })
            let store = try makeStore(at: url, afterReplace: {
                writes.update { $0 += 1 }
                if !beforeReplace && fail.value { throw NSError(domain: NSPOSIXErrorDomain, code: 5) }
            }, fileHooks: hooks)
            let seed: [String: ClientSettingValue] = [
                "privacy.sendReadMessagePacketsLocked": .bool(true),
                "privacy.sendReadStoriesPackets": .bool(true),
                "privacy.sendUploadProgressLocked": .bool(false)
            ]
            try store.applyPublic(seed)
            let before = store.readSnapshot()
            let original = try Data(contentsOf: url)
            let patch = ghostValues.filter { $0.key != "privacy.sendReadMessagePackets" }
            let events = GhostMutationBox<[GhostMutationEvent]>([])
            let observation = observe(store, at: url, into: events)
            defer { observation.cancel() }
            attempts.update { $0 = 0 }; writes.update { $0 = 0 }; fail.update { $0 = true }
            let failure = ClientSettingsError.storageFailure(operation: beforeReplace ? "replace" : "sync directory", code: 5)
            XCTAssertThrowsError(try PrivacyGhostModeMutation.toggle(in: store)) {
                XCTAssertEqual($0 as? ClientSettingsError, failure)
            }
            let expectedValues = beforeReplace ? before.values : before.values.merging(patch) { _, new in new }
            let expectedPresence = beforeReplace ? before.storedKeys : before.storedKeys.union(patch.keys)
            XCTAssertEqual(attempts.value, 1)
            XCTAssertEqual(writes.value, beforeReplace ? 0 : 1)
            XCTAssertEqual(store.snapshot(), expectedValues)
            XCTAssertEqual(store.readSnapshot().storedKeys, expectedPresence)
            XCTAssertEqual(store.lastError, failure)
            XCTAssertEqual(events.value.count, 1)
            let event = try XCTUnwrap(events.value.first)
            XCTAssertEqual(event.keys, beforeReplace ? Set<String>() : Set(patch.keys))
            XCTAssertEqual(event.snapshot.values, expectedValues)
            XCTAssertEqual(event.snapshot.storedKeys, expectedPresence)
            XCTAssertEqual(event.snapshot.lastError, failure)
            XCTAssertEqual(event.disk, try Data(contentsOf: url))
            XCTAssertEqual(try diskValues(at: url), beforeReplace ? seed : seed.merging(patch) { _, new in new })
            if beforeReplace { XCTAssertEqual(try Data(contentsOf: url), original) }
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)),
                           Set(["client-settings.json", "client-settings.json.lock"]))

            fail.update { $0 = false }
            XCTAssertEqual(try PrivacyGhostModeMutation.toggle(in: store), beforeReplace,
                           "Retry must use the actual whole state, including a post-rename commit")
            XCTAssertNil(store.lastError)
        }
    }

    // Deterministic external-writer interleavings, with tiny documents and no sleeps.
    // Each fixture uses the real flock/read/replace and error-recovery path.
    private func assertStaleRejected(seed: [String: ClientSettingValue], externalValues: [String: ClientSettingValue],
                                     resetting: Set<String> = [], presenceOnly: Bool = false, refreshCache: Bool = false,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try storageURL()
        let writes = GhostMutationBox(0)
        let store = try makeStore(at: url, afterReplace: { writes.update { $0 += 1 } })
        try store.applyPublic(seed)
        let external = try makeStore(at: url)
        let before = store.readSnapshot()
        let previousWrites = writes.value
        try external.applyPublic(externalValues, resetting: resetting)
        let changed = external.readSnapshot()
        let label = Set(externalValues.keys).union(resetting).sorted().joined(separator: ", ")
        if presenceOnly {
            XCTAssertEqual(before.values, changed.values, label, file: file, line: line)
            XCTAssertNotEqual(before.storedKeys, changed.storedKeys, label, file: file, line: line)
        } else {
            XCTAssertNotEqual(before.values, changed.values, label, file: file, line: line)
            XCTAssertEqual(before.storedKeys, changed.storedKeys, label, file: file, line: line)
        }
        if refreshCache { try store.reload() }
        else { XCTAssertEqual(store.snapshot(), before.values, label, file: file, line: line) }
        let original = try Data(contentsOf: url)
        let events = GhostMutationBox<[GhostMutationEvent]>([])
        let observation = observe(store, at: url, into: events)
        defer { observation.cancel() }
        XCTAssertThrowsError(try PrivacyGhostModeMutation.toggle(in: store, expectedBefore: before), label, file: file, line: line) {
            XCTAssertEqual($0 as? ClientSettingsError, .concurrentModification, label, file: file, line: line)
        }
        XCTAssertEqual(writes.value, previousWrites, label, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: url), original, label, file: file, line: line)
        XCTAssertEqual(store.snapshot(), changed.values, label, file: file, line: line)
        XCTAssertEqual(store.readSnapshot().storedKeys, changed.storedKeys, label, file: file, line: line)
        XCTAssertEqual(store.lastError, .concurrentModification, label, file: file, line: line)
        XCTAssertEqual(events.value.count, 1, label, file: file, line: line)
        let event = try XCTUnwrap(events.value.first)
        XCTAssertEqual(event.snapshot.values, changed.values, label, file: file, line: line)
        XCTAssertEqual(event.snapshot.storedKeys, changed.storedKeys, label, file: file, line: line)
        XCTAssertEqual(event.disk, original, label, file: file, line: line)
    }

    func testStaleLockValuesRejectEveryGhostLock() throws {
        for key in normalValues.keys.sorted() {
            try assertStaleRejected(seed: [key + "Locked": .bool(false)], externalValues: [key + "Locked": .bool(true)])
        }
    }

    func testStaleValuesRejectUnlockedAndAllLockedSnapshots() throws {
        for locked in [false, true] {
            for key in normalValues.keys.sorted() {
                var seed = [key: try XCTUnwrap(normalValues[key])]
                if locked { for field in normalValues.keys { seed[field + "Locked"] = .bool(true) } }
                try assertStaleRejected(seed: seed, externalValues: [key: try XCTUnwrap(ghostValues[key])])
            }
        }
    }

    func testPresenceOnlySetAndResetRejectEveryGhostDependency() throws {
        for field in normalValues.keys.sorted() {
            for key in [field, field + "Locked"] {
                for reset in [false, true] {
                    let value = normalValues[key] ?? .bool(false)
                    var seed: [String: ClientSettingValue] = [:]
                    // The field is kept by policy: it must still be a CAS dependency.
                    if key == field { seed[field + "Locked"] = .bool(true) }
                    if reset { seed[key] = value }
                    try assertStaleRejected(seed: seed, externalValues: reset ? [:] : [key: value],
                                            resetting: reset ? [key] : [], presenceOnly: true)
                }
            }
        }
    }

    func testSuppliedBeforeIsNotReplacedByARefreshedCache() throws {
        try assertStaleRejected(seed: ["privacy.sendOnlinePackets": .bool(true)],
                                externalValues: ["privacy.sendOnlinePackets": .bool(false)], refreshCache: true)
    }

    func testResultBelongsToThisProjectionEvenIfAnObserverTogglesAgain() throws {
        let url = try storageURL()
        let writes = GhostMutationBox(0)
        let store = try makeStore(at: url, afterReplace: { writes.update { $0 += 1 } })
        let callbacks = GhostMutationBox(0)
        let results = GhostMutationBox<[Bool]>([])
        let errors = GhostMutationBox<[String]>([])
        let observation = store.observe { _ in
            let first = callbacks.update { count in count += 1; return count == 1 }
            if first {
                do {
                    let active = try PrivacyGhostModeMutation.toggle(in: store)
                    results.update { $0.append(active) }
                } catch { errors.update { $0.append(error.localizedDescription) } }
            }
        }
        defer { observation.cancel() }
        XCTAssertTrue(try PrivacyGhostModeMutation.toggle(in: store))
        XCTAssertEqual(results.value, [false])
        XCTAssertTrue(errors.value.isEmpty)
        XCTAssertEqual(callbacks.value, 2)
        XCTAssertEqual(writes.value, 2)
        XCTAssertFalse(PrivacyPolicy(values: store.snapshot()).ghostModeActive)
        XCTAssertEqual(try diskValues(at: url), normalValues)
    }
}
