import Foundation
import XCTest
@testable import PluginHost

private final class TrustTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return storage }
    @discardableResult func change<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        return body(&storage)
    }
}

final class PluginTrustLevelTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ text: String, root: URL) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent("grants.json"), options: .atomic)
    }

    func testNewInstallDefaultsToZeroAndReplacementPreservesConsent() throws {
        let store = try PluginStore(directory: directory())
        let model = PermissionsModel()
        try model.load(from: store)
        XCTAssertNil(model.snapshot("fresh").record)
        XCTAssertEqual(model.effective("fresh"), [.ui])
        // An orphan record for a previously removed ID is not new-install consent.
        try model.setGranted("fresh", [.network, .native], to: store)
        try model.prepareInstall("fresh", replacing: false, to: store)
        XCTAssertEqual(model.snapshot("fresh").record, PluginPermissionRecord())
        XCTAssertEqual(model.level("fresh").rawValue, 0)
        try model.setConsent("fresh", level: .trusted, permissions: [.files, .hooks], to: store)
        try model.prepareInstall("fresh", replacing: true, to: store)
        XCTAssertEqual(model.effective("fresh"), [.ui, .files, .hooks])
        try model.clear("fresh", in: store)
        XCTAssertNil(try store.loadPermissionRecords()["fresh"])
        try model.prepareInstall("fresh", replacing: false, to: store)
        XCTAssertEqual(model.snapshot("fresh").record, PluginPermissionRecord())
    }

    func testLegacyMigrationUsesRawGrantsAndIsDurableEvenInUnsafeMode() throws {
        let root = try directory()
        try write("""
        {"empty":[],"uiOnly":["ui","unknown"],"network":["network","network"],
         "other":["settings","files","messages.read","messages.send","intents"],
         "hooks":["hooks","network"],"native":["native"]}
        """, root: root)
        let store = try PluginStore(directory: root)
        let model = PermissionsModel(unsafeMode: true)
        try model.load(from: store)
        try model.migrateInstalled(["empty", "uiOnly", "network", "other", "hooks", "native", "withoutGrantRecord"], to: store)
        let expected: [String: PluginTrustLevel] = [
            "empty": .isolated, "uiOnly": .isolated, "network": .gated,
            "other": .gated, "hooks": .trusted, "native": .trusted, "withoutGrantRecord": .isolated
        ]
        for (id, level) in expected { XCTAssertEqual(model.level(id), level, id) }
        let data = try Data(contentsOf: root.appendingPathComponent("grants.json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(document["version"] as? Int, 1)
        let reopened = PermissionsModel()
        try reopened.load(from: PluginStore(directory: root))
        for (id, level) in expected {
            XCTAssertEqual(reopened.level(id), level, id)
            XCTAssertEqual(reopened.snapshot(id).record, model.snapshot(id).record, id)
        }
        XCTAssertEqual(reopened.effective("hooks"), [.ui, .hooks, .network])
        XCTAssertEqual(reopened.effective("other"), [.ui, .settings, .files, .messagesRead, .messagesSend, .intents])
        XCTAssertEqual(reopened.snapshot("network").grants, [.network])
    }

    func testExplicitCeilingCapsMismatchedStoredGrantsAndTrustedDoesNotImplyGrants() throws {
        let root = try directory()
        try write("""
        {"version":1,"records":{
          "zero":{"level":0,"grants":["network","hooks","native"]},
          "one":{"level":1,"grants":["network","hooks","native"]},
          "two":{"level":2,"grants":["network","hooks"]},
          "noConsent":{"level":2,"grants":[]},
          "missingLevel":{"grants":["native"]}}}
        """, root: root)
        let store = try PluginStore(directory: root)
        let model = PermissionsModel()
        try model.load(from: store)
        XCTAssertEqual(model.snapshot("zero").grants, [.network, .hooks, .native])
        XCTAssertEqual(model.effective("zero"), [.ui])
        XCTAssertEqual(model.effective("one"), [.ui, .network])
        XCTAssertEqual(model.effective("two"), [.ui, .network, .hooks])
        XCTAssertFalse(model.has("two", .native))
        XCTAssertEqual(model.effective("noConsent"), [.ui])
        XCTAssertEqual(model.level("missingLevel"), .trusted)
        // Merely raising a mismatched ceiling is not new consent to hidden bits.
        try model.setLevel("zero", .trusted, to: store)
        XCTAssertEqual(model.effective("zero"), [.ui])
        model.unsafeMode = true
        for id in ["zero", "one", "noConsent", "absent"] {
            XCTAssertEqual(model.snapshot(id).effective, Set(PluginPermission.allCases))
        }
        model.unsafeMode = false
        XCTAssertEqual(model.effective("noConsent"), [.ui])
    }

    func testDowngradeUpgradeAndReopenNeverResurrectPrunedGrants() throws {
        let root = try directory()
        let store = try PluginStore(directory: root)
        let model = PermissionsModel()
        try model.setConsent("alpha", level: .trusted, permissions: [.network, .hooks, .native], to: store)
        try model.setLevel("alpha", .gated, to: store)
        XCTAssertEqual(try store.loadGrants()["alpha"], [.network])
        try model.setLevel("alpha", .trusted, to: store)
        let reopened = PermissionsModel()
        try reopened.load(from: PluginStore(directory: root))
        XCTAssertEqual(reopened.level("alpha"), .trusted)
        XCTAssertEqual(reopened.effective("alpha"), [.ui, .network])
        reopened.unsafeMode = true
        try reopened.setLevel("alpha", .isolated, to: store)
        XCTAssertEqual(try store.loadPermissionRecords()["alpha"], PluginPermissionRecord())
        try reopened.setLevel("alpha", .trusted, to: store)
        reopened.unsafeMode = false
        XCTAssertEqual(reopened.effective("alpha"), [.ui])
        let again = PermissionsModel()
        try again.load(from: PluginStore(directory: root))
        XCTAssertEqual(again.snapshot("alpha").record, reopened.snapshot("alpha").record)
    }

    func testLegacyNativeConsentStillWorksButLevelAwareUICannotImplicitlyRaiseLevel() throws {
        let store = try PluginStore(directory: directory())
        let model = PermissionsModel()
        try model.prepareInstall("alpha", replacing: false, to: store)
        try model.setGranted("alpha", [.network], to: store)
        XCTAssertEqual(model.level("alpha"), .gated)
        XCTAssertEqual(model.effective("alpha"), [.ui, .network])
        try model.setGranted("alpha", [.hooks], to: store)
        XCTAssertEqual(model.level("alpha"), .trusted)
        XCTAssertEqual(model.effective("alpha"), [.ui, .hooks])
        try model.setGranted("alpha", [], to: store)
        XCTAssertEqual(model.level("alpha"), .trusted)
        XCTAssertEqual(model.effective("alpha"), [.ui])
        try model.setLevel("alpha", .isolated, to: store)
        XCTAssertThrowsError(try model.setConsent("alpha", level: .isolated, permissions: [.network], to: store))
        XCTAssertThrowsError(try model.setConsent("alpha", level: .gated, permissions: [.native], to: store))
        XCTAssertEqual(model.snapshot("alpha").record, PluginPermissionRecord())
        // A bulk old save preserves a real level instead of migrating it again.
        try store.saveGrants(["alpha": [.network, .hooks], "legacyNew": [.native]])
        try model.load(from: store)
        XCTAssertEqual(model.snapshot("alpha").record, PluginPermissionRecord())
        XCTAssertEqual(model.level("legacyNew"), .trusted)
        XCTAssertEqual(model.effective("legacyNew"), [.ui, .native])
    }

    func testBadStorageIsAnErrorAndNeverAnEmptyStoreOrOverwrite() throws {
        let root = try directory()
        let store = try PluginStore(directory: root)
        let model = PermissionsModel()
        try model.setGranted("alpha", [.network], to: store)
        let before = model.snapshot("alpha")
        let invalid = [
            "", "[]", "null", "{", "{\"alpha\":null}",
            "{\"version\":2,\"records\":{}}",
            "{\"version\":1,\"records\":{\"alpha\":{\"level\":null,\"grants\":[]}}}",
            "{\"version\":1,\"records\":{\"alpha\":{\"level\":3,\"grants\":[]}}}",
            "{\"version\":1,\"records\":{\"alpha\":{\"level\":true,\"grants\":[]}}}",
            "{\"version\":1,\"records\":{\"alpha\":{\"level\":1,\"grants\":[\"typo\"]}}}",
            "{\"version\":1,\"records\":{},\"unexpected\":true}"
        ]
        for text in invalid {
            try write(text, root: root)
            XCTAssertThrowsError(try store.loadGrants(), text)
            XCTAssertThrowsError(try model.load(from: store), text)
            XCTAssertThrowsError(try model.clear("alpha", in: store), text)
            XCTAssertThrowsError(try store.saveGrants([:]), text)
            XCTAssertEqual(model.snapshot("alpha"), before)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("grants.json")), Data(text.utf8))
        }
    }

    func testFailedMigrationAndFailedMutationKeepDiskAndMemoryUnchanged() throws {
        let root = try directory()
        let failure = TrustTestBox(true)
        let store = try PluginStore(directory: root, beforePermissionCommit: {
            if failure.value { throw CocoaError(.fileWriteNoPermission) }
        })
        let legacy = "{\"alpha\":[\"native\",\"network\"]}"
        try write(legacy, root: root)
        let model = PermissionsModel()
        XCTAssertThrowsError(try model.load(from: store))
        XCTAssertNil(model.snapshot("alpha").record)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("grants.json")), Data(legacy.utf8))
        failure.change { $0 = false }
        try model.load(from: store)
        let before = model.snapshot("alpha")
        let bytes = try Data(contentsOf: root.appendingPathComponent("grants.json"))
        failure.change { $0 = true }
        XCTAssertThrowsError(try model.setLevel("alpha", .isolated, to: store))
        XCTAssertThrowsError(try model.setGranted("alpha", [], to: store))
        XCTAssertThrowsError(try model.clear("alpha", in: store))
        XCTAssertEqual(model.snapshot("alpha"), before)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("grants.json")), bytes)
        let reopened = PermissionsModel()
        try reopened.load(from: PluginStore(directory: root))
        XCTAssertEqual(reopened.snapshot("alpha").record, before.record)
        XCTAssertEqual(reopened.snapshot("alpha").unsafeMode, before.unsafeMode)

        // Also exercise the real atomic writer's error, after successful decode:
        // replace its destination with a directory at the pre-commit test seam.
        let file = root.appendingPathComponent("grants.json")
        let backup = root.appendingPathComponent("grants.before-write-failure")
        let obstructed = try PluginStore(directory: root, beforePermissionCommit: {
            try FileManager.default.moveItem(at: file, to: backup)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        })
        XCTAssertThrowsError(try model.setLevel("alpha", .isolated, to: obstructed))
        XCTAssertEqual(model.snapshot("alpha"), before)
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType, .typeDirectory)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        XCTAssertEqual(try PluginStore(directory: root).loadPermissionRecords()["alpha"], before.record)
    }

    func testAuthorityChecksAtCommitOnceAndPublicationFollowsSuccessfulCommit() throws {
        let root = try directory()
        let model = PermissionsModel()
        let observation = TrustTestBox<PluginPermissionSnapshot?>(nil)
        let store = try PluginStore(directory: root, beforePermissionCommit: {
            observation.change { $0 = model.snapshot("alpha") }
        })
        try model.setGranted("alpha", [.network, .native], to: store)
        let before = model.snapshot("alpha")
        let bytes = try Data(contentsOf: root.appendingPathComponent("grants.json"))
        XCTAssertThrowsError(try model.setLevel("alpha", .isolated, to: store, isCurrent: { false })) { error in
            XCTAssertEqual(error as? PluginPermissionStoreError, .authorityExpired)
        }
        XCTAssertEqual(observation.value, before)
        XCTAssertEqual(model.snapshot("alpha"), before)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("grants.json")), bytes)
        let checks = TrustTestBox(0)
        try model.setLevel("alpha", .isolated, to: store, isCurrent: {
            checks.change { $0 += 1; return $0 == 1 }
        })
        XCTAssertEqual(checks.value, 1, "Do not throw a stale-authority error AFTER a durable commit")
        XCTAssertEqual(observation.value, before, "Uncommitted data must not become effective")
        XCTAssertEqual(model.snapshot("alpha").record, PluginPermissionRecord())
        XCTAssertEqual(try PluginStore(directory: root).loadPermissionRecords()["alpha"], PluginPermissionRecord())
    }

    func testRetainedPredicateCannotRecoverAfterLoweringOrUnsafeToggleAndReadsAreCoherent() throws {
        let store = try PluginStore(directory: directory())
        let model = PermissionsModel()
        try model.setConsent("alpha", level: .trusted, permissions: [.network, .native], to: store)
        let before = model.snapshot("alpha")
        let permitted = model.futurePredicate("alpha", requiring: [.network, .native])
        let neverAdmitted = model.futurePredicate("alpha", requiring: [.files])
        XCTAssertTrue(permitted())
        try model.setLevel("alpha", .isolated, to: store)
        try model.setConsent("alpha", level: .trusted, permissions: [.network, .native, .files], to: store)
        XCTAssertNotEqual(model.snapshot("alpha").revision, before.revision)
        XCTAssertFalse(permitted())
        XCTAssertFalse(neverAdmitted())
        try model.setConsent("alpha", level: .trusted, permissions: [.network, .native], to: store)
        XCTAssertEqual(model.snapshot("alpha").record, before.record)
        XCTAssertNotEqual(model.snapshot("alpha").revision, before.revision, "A -> B -> A must expire a native editor snapshot")
        model.unsafeMode = true
        let override = model.futurePredicate("absent", requiring: [.hooks])
        XCTAssertTrue(override())
        model.unsafeMode = false
        model.unsafeMode = true
        XCTAssertFalse(override())
        try model.setLevel("alpha", .isolated, to: store)
        let failures = TrustTestBox(0)
        DispatchQueue.concurrentPerform(iterations: 128) { index in
            model.unsafeMode = index.isMultiple(of: 2)
            let snapshot = model.snapshot("alpha")
            let expected: Set<PluginPermission> = snapshot.unsafeMode ? Set(PluginPermission.allCases) : [.ui]
            if snapshot.level != .isolated || !snapshot.grants.isEmpty || snapshot.effective != expected {
                failures.change { $0 += 1 }
            }
        }
        XCTAssertEqual(failures.value, 0)
    }
}
