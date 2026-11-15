import Foundation
import XCTest
@testable import ExteralessCore

private final class SettingsTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { self.storage = value }

    var value: Value {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }

    func update(_ body: (inout Value) -> Void) {
        self.lock.lock()
        defer { self.lock.unlock() }
        body(&self.storage)
    }
}

private struct SettingsTestSecretFailure: LocalizedError {
    var errorDescription: String? { "DO-NOT-EXPOSE-SECRET-FIXTURE" }
}

private final class SettingsTestSecrets: ClientSecretStore, @unchecked Sendable {
    private let values = SettingsTestBox<[String: Data]>([:])
    let readCount = SettingsTestBox(0)
    let writeCount = SettingsTestBox(0)
    let failReads = SettingsTestBox(false)
    let failWrites = SettingsTestBox(false)
    let failWriteKey = SettingsTestBox<String?>(nil)
    let failReadsAfterWriteKey = SettingsTestBox<String?>(nil)

    func data(for key: String) throws -> Data? {
        self.readCount.update { $0 += 1 }
        if self.failReads.value { throw SettingsTestSecretFailure() }
        return self.values.value[key]
    }

    func set(_ data: Data?, for key: String) throws {
        self.writeCount.update { $0 += 1 }
        if self.failWrites.value || self.failWriteKey.value == key { throw SettingsTestSecretFailure() }
        self.values.update { $0[key] = data }
        if self.failReadsAfterWriteKey.value == key { self.failReads.update { $0 = true } }
    }
}

private final class SettingsBlockingSecrets: ClientSecretStore, @unchecked Sendable {
    private let values = SettingsTestBox<[String: Data]>([:])
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func data(for key: String) throws -> Data? { self.values.value[key] }

    func set(_ data: Data?, for key: String) throws {
        self.entered.signal()
        guard self.release.wait(timeout: .now() + 3.0) == .success else { throw SettingsTestSecretFailure() }
        self.values.update { $0[key] = data }
    }
}

final class ClientSettingsTests: XCTestCase {
    private func storageURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("client-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("client-settings.json")
    }

    private func definition(_ key: String, _ value: ClientSettingValue) -> ClientSettingDefinition {
        return ClientSettingDefinition(key: key, title: key, section: "Fixture", defaultValue: value)
    }

    private func document(_ url: URL) throws -> [String: ClientSettingValue] {
        return try JSONDecoder().decode([String: ClientSettingValue].self, from: Data(contentsOf: url))
    }

    private func rawSecret(_ key: String, in secrets: SettingsTestSecrets) throws -> ClientSettingValue {
        let data = try secrets.data(for: key)
        return try ClientSettingValue.decodeJSON(XCTUnwrap(data))
    }

    /// An intended forward state, constructed before any write/observer runs.
    private func expectedState(_ before: ClientSettingsSnapshot, applying values: [String: ClientSettingValue]) -> ClientSettingsSnapshot {
        return ClientSettingsSnapshot(definitions: before.definitions,
                                      values: before.values.merging(values) { _, new in new },
                                      storedKeys: before.storedKeys.union(values.keys), secretKeys: before.secretKeys)
    }

    func testPersistentTypedValuesAndInitialSnapshot() throws {
        let url = try self.storageURL().deletingLastPathComponent()
            .appendingPathComponent("new", isDirectory: true)
            .appendingPathComponent("directory", isDirectory: true)
            .appendingPathComponent("client-settings.json")
        let definitions = [
            self.definition("fixture.enabled", .bool(false)),
            self.definition("fixture.integer", .integer(0)),
            self.definition("fixture.number", .number(0)),
            self.definition("fixture.text", .string("")),
            self.definition("fixture.items", .array([])),
            self.definition("fixture.nullable", .null)
        ]
        let first = try ClientSettings(storageURL: url)
        try first.register(definitions)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Registering defaults is not a preference write")
        let nested: ClientSettingValue = .array([.null, .bool(true), .integer(Int64.min), .object(["unicode": .string("Тест 👋"), "fraction": .number(1.25)])])
        try first.set(.bool(true), for: "fixture.enabled")
        try first.set(.integer(Int64.max), for: "fixture.integer")
        try first.set(.number(1.0), for: "fixture.number")
        try first.set(.string("Тест 👋"), for: "fixture.text")
        try first.set(nested, for: "fixture.items")
        try first.set(.null, for: "fixture.nullable")

        let second = try ClientSettings(storageURL: url)
        try second.register(definitions)
        let snapshot = second.readSnapshot()
        XCTAssertEqual(snapshot.values["fixture.enabled"], .bool(true))
        XCTAssertEqual(snapshot.values["fixture.integer"], .integer(Int64.max))
        XCTAssertEqual(snapshot.values["fixture.number"], .number(1.0))
        XCTAssertEqual(snapshot.values["fixture.text"], .string("Тест 👋"))
        XCTAssertEqual(snapshot.values["fixture.items"], nested)
        XCTAssertEqual(snapshot.values["fixture.nullable"], .null)
        XCTAssertNil(second.value("fixture.missing"))
        XCTAssertEqual(second.string("fixture.missing", default: "fallback"), "fallback")
        XCTAssertEqual(second.integer("fixture.enabled", default: 27), 27)
        XCTAssertTrue(second.bool("fixture.enabled"))
        XCTAssertEqual(second.double("fixture.number"), 1.0)
        XCTAssertEqual(snapshot.definitions, definitions)
        XCTAssertNil(snapshot.lastError)
    }

    func testReadCacheRequiresExplicitReloadAndCorruptionNeverGetsOverwritten() throws {
        let url = try self.storageURL()
        let store = try ClientSettings(storageURL: url)
        try store.register([self.definition("fixture.enabled", .bool(false))])
        try store.set(.bool(true), for: "fixture.enabled")
        let valid = try Data(contentsOf: url)
        let corrupt = Data("{invalid JSON, DO-NOT-EXPOSE-SECRET-FIXTURE".utf8)
        try corrupt.write(to: url)

        XCTAssertTrue(store.bool("fixture.enabled"), "Hot getters must not read disk")
        XCTAssertNil(store.lastError)
        XCTAssertThrowsError(try store.reload()) { error in
            XCTAssertEqual(error as? ClientSettingsError, .invalidJSON)
            XCTAssertFalse(error.localizedDescription.contains("DO-NOT-EXPOSE"))
        }
        XCTAssertTrue(store.bool("fixture.enabled"), "A failed reload keeps the last complete generation")
        XCTAssertThrowsError(try store.set(.bool(false), for: "fixture.enabled"))
        XCTAssertThrowsError(try store.reset("fixture.enabled"))
        XCTAssertThrowsError(try store.applyPublic(["fixture.enabled": .bool(false)], expected: store.readSnapshot()))
        XCTAssertThrowsError(try store.applyPublic([:], resetting: ["fixture.enabled"]))
        XCTAssertThrowsError(try ClientSettings(storageURL: url))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)

        try valid.write(to: url)
        try store.reload()
        XCTAssertNil(store.lastError)
        try store.reset("fixture.enabled")
        XCTAssertFalse(store.bool("fixture.enabled"))
    }

    func testConfigureFailureCannotWriteToPreviousFile() throws {
        let oldURL = try self.storageURL()
        let newURL = try self.storageURL()
        let store = try ClientSettings(storageURL: oldURL)
        try store.register([self.definition("fixture.value", .integer(0))])
        try store.set(.integer(7), for: "fixture.value")
        let previous = try Data(contentsOf: oldURL)
        let corrupt = Data("[1,2,3]".utf8)
        try corrupt.write(to: newURL)
        XCTAssertThrowsError(try store.configure(storageURL: newURL))
        XCTAssertThrowsError(try store.set(.integer(8), for: "fixture.value"))
        XCTAssertEqual(try Data(contentsOf: oldURL), previous)
        XCTAssertEqual(try Data(contentsOf: newURL), corrupt)

        try Data("{\"fixture.value\":9}".utf8).write(to: newURL)
        try store.reload()
        XCTAssertEqual(store.integer("fixture.value"), 9)
        XCTAssertEqual(try Data(contentsOf: oldURL), previous)
    }

    func testLegacyMigrationUnknownKeysAndFutureMetadataSurvive() throws {
        let url = try self.storageURL()
        let original = Data("{\"oldName\":3,\"future.setting\":{\"nested\":[null,true,42]}}".utf8)
        try original.write(to: url)
        let store = try ClientSettings(storageURL: url)
        XCTAssertEqual(try Data(contentsOf: url), original, "Loading before domain registration must not rewrite legacy data")
        try store.register([self.definition("fixture.value", .integer(0))])
        try store.migrateKey(from: "oldName", to: "fixture.value")
        try store.migrateKey(from: "oldName", to: "fixture.value")
        XCTAssertEqual(store.integer("fixture.value"), 3)
        XCTAssertNil(store.snapshot()["future.setting"])
        XCTAssertThrowsError(try store.set(.bool(true), for: "future.setting"))

        var root = try self.document(url)
        XCTAssertEqual(root["version"], .integer(1))
        guard case let .object(values) = root["values"] else { return XCTFail("Missing values") }
        XCTAssertNil(values["oldName"])
        XCTAssertEqual(values["future.setting"], .object(["nested": .array([.null, .bool(true), .integer(42)])]))
        root["futureMetadata"] = .object(["revision": .integer(100)])
        try JSONEncoder().encode(root).write(to: url)
        try store.set(.integer(4), for: "fixture.value")
        XCTAssertEqual(try self.document(url)["futureMetadata"], root["futureMetadata"])
        try store.reset("fixture.value")
        guard case let .object(reset) = try self.document(url)["values"] else { return XCTFail("Missing values") }
        XCTAssertNil(reset["fixture.value"])
        XCTAssertNotNil(reset["future.setting"])
    }

    func testUnsupportedVersionIsPreserved() throws {
        let url = try self.storageURL()
        let future = Data("{\"$format\":\"exteraless.client-settings\",\"version\":99,\"values\":{}}".utf8)
        try future.write(to: url)
        XCTAssertThrowsError(try ClientSettings(storageURL: url)) { error in
            XCTAssertEqual(error as? ClientSettingsError, .unsupportedVersion(99))
        }
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    func testEnumRangeTypeStepAndNonFiniteValidationAreAtomic() throws {
        let url = try self.storageURL()
        let store = try ClientSettings(storageURL: url)
        let selector = ClientSettingDefinition(key: "fixture.mode", title: "Mode", section: "Fixture", defaultValue: .string("one"),
                                               options: [.init(value: .string("one"), title: "One"), .init(value: .string("two"), title: "Two")])
        let slider = ClientSettingDefinition(key: "fixture.size", title: "Size", section: "Fixture", defaultValue: .number(0.5),
                                             minimum: 0.0, maximum: 1.0, step: 0.1)
        let integer = ClientSettingDefinition(key: "fixture.count", title: "Count", section: "Fixture", defaultValue: .integer(-3),
                                              minimum: -3, maximum: 9, step: 3)
        try store.register([selector, slider, integer, self.definition("fixture.payload", .object([:]))])
        try store.set(.number(0.3), for: "fixture.size")
        try store.set(.integer(6), for: "fixture.count")
        let before = try Data(contentsOf: url)
        for (key, value) in [
            ("fixture.mode", ClientSettingValue.string("invalid")),
            ("fixture.mode", .integer(1)),
            ("fixture.size", .number(1.1)),
            ("fixture.size", .number(0.35)),
            ("fixture.size", .number(.nan)),
            ("fixture.size", .number(.infinity)),
            ("fixture.count", .number(1.5)),
            ("fixture.count", .integer(5)),
            ("fixture.payload", .object(["nested": .array([.number(-.infinity)])]))
        ] {
            XCTAssertThrowsError(try store.set(value, for: key))
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
        XCTAssertEqual(store.string("fixture.mode"), "one")
        XCTAssertEqual(store.double("fixture.size"), 0.3)
        XCTAssertEqual(store.integer("fixture.count"), 6)
        XCTAssertThrowsError(try JSONEncoder().encode(ClientSettingValue.array([.number(.nan)])))
        XCTAssertThrowsError(try JSONDecoder().decode(ClientSettingValue.self, from: Data("NaN".utf8)))
    }

    func testInvalidDefinitionsAndPersistedEnumNeverSilentlyBecomeDefaults() throws {
        let url = try self.storageURL()
        let store = try ClientSettings(storageURL: url)
        let valid = self.definition("fixture.enabled", .bool(false))
        let invalid = ClientSettingDefinition(key: "fixture.bad", title: "Bad", section: "Fixture", defaultValue: .integer(3), minimum: 4, maximum: 1)
        XCTAssertThrowsError(try store.register([valid, invalid]))
        XCTAssertEqual(store.definitions(), [])
        try store.register([valid])
        try store.register([valid])
        XCTAssertEqual(store.definitions(), [valid])
        XCTAssertThrowsError(try store.register([self.definition("fixture.enabled", .string("different"))]))

        let malformed = Data("{\"fixture.mode\":\"removed-option\"}".utf8)
        let secondURL = try self.storageURL()
        try malformed.write(to: secondURL)
        let second = try ClientSettings(storageURL: secondURL)
        let mode = ClientSettingDefinition(key: "fixture.mode", title: "Mode", section: "Fixture", defaultValue: .string("one"),
                                           options: [.init(value: .string("one"), title: "One")])
        XCTAssertThrowsError(try second.register([mode]))
        XCTAssertEqual(try Data(contentsOf: secondURL), malformed)
        XCTAssertEqual(second.definitions(), [mode], "Valid schemas stay addressable for explicit native repair")
        XCTAssertNil(second.value(mode.key))
    }

    func testConcurrentInstancesMergeUpdatesAndReloadExplicitly() throws {
        let url = try self.storageURL()
        let definitions = (0..<16).map { self.definition("fixture.key\($0)", .integer(-1)) }
        let first = try ClientSettings(storageURL: url)
        let second = try ClientSettings(storageURL: url)
        try first.register(definitions)
        try second.register(definitions)
        let errors = SettingsTestBox<[String]>([])
        let group = DispatchGroup()
        for index in 0..<16 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    try (index % 2 == 0 ? first : second).set(.integer(Int64(index)), for: "fixture.key\(index)")
                } catch { errors.update { $0.append(error.localizedDescription) } }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5.0), .success)
        XCTAssertEqual(errors.value, [])
        try first.reload()
        try second.reload()
        XCTAssertEqual(first.snapshot(), second.snapshot())
        for index in 0..<16 { XCTAssertEqual(first.integer("fixture.key\(index)"), index) }
        try first.set(.integer(99), for: "fixture.key0")
        XCTAssertEqual(second.integer("fixture.key0"), 0)
        try second.reload()
        XCTAssertEqual(second.integer("fixture.key0"), 99)
    }

    func testObserversReenterOutsideLocksAndCancellationStopsFutureDelivery() throws {
        let store = try ClientSettings(storageURL: self.storageURL())
        try store.register([self.definition("fixture.a", .bool(false)), self.definition("fixture.b", .bool(false))])
        let seen = SettingsTestBox<[Set<String>]>([])
        let errors = SettingsTestBox<[String]>([])
        var observation: ClientSettingsObservation? = store.observe { keys in
            seen.update { $0.append(keys) }
            _ = store.readSnapshot()
            if keys.contains("fixture.a") && store.bool("fixture.a") {
                do { try store.set(.bool(true), for: "fixture.b") }
                catch { errors.update { $0.append(error.localizedDescription) } }
            }
        }
        XCTAssertEqual(seen.value, [])
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do { try store.set(.bool(true), for: "fixture.a") }
            catch { errors.update { $0.append(error.localizedDescription) } }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 3.0), .success, "A callback must not hold a store or file lock")
        XCTAssertEqual(errors.value, [])
        XCTAssertEqual(seen.value, [Set(["fixture.a"]), Set(["fixture.b"])])
        observation?.cancel()
        observation?.cancel()
        observation = nil
        try store.set(.bool(false), for: "fixture.a")
        XCTAssertEqual(seen.value.count, 2)

        var deinitObservation: ClientSettingsObservation? = store.observe { keys in seen.update { $0.append(keys) } }
        XCTAssertNotNil(deinitObservation)
        deinitObservation = nil
        try store.set(.bool(false), for: "fixture.b")
        XCTAssertEqual(seen.value.count, 2)
    }

    func testCacheReadersDoNotWaitForSecretIOAndSeeOnlyCompleteGenerations() throws {
        let secrets = SettingsBlockingSecrets()
        let store = try ClientSettings(storageURL: self.storageURL(), secretStore: secrets)
        let definition = ClientSettingDefinition(key: "fixture.secret", title: "Secret", section: "Fixture", defaultValue: .string(""), isSecret: true)
        try store.register([definition])
        let writer = DispatchGroup()
        let errors = SettingsTestBox<[String]>([])
        writer.enter()
        DispatchQueue.global().async {
            defer { writer.leave() }
            do { try store.set(.string("cached-native-secret"), for: definition.key) }
            catch { errors.update { $0.append(error.localizedDescription) } }
        }
        XCTAssertEqual(secrets.entered.wait(timeout: .now() + 1.0), .success)
        let reader = DispatchGroup()
        let snapshot = SettingsTestBox<ClientSettingsSnapshot?>(nil)
        reader.enter()
        DispatchQueue.global().async {
            snapshot.update { $0 = store.readSnapshot() }
            reader.leave()
        }
        let didRead = reader.wait(timeout: .now() + 1.0)
        secrets.release.signal()
        XCTAssertEqual(didRead, .success, "Readers must not acquire the I/O/writer lock")
        XCTAssertEqual(snapshot.value?.values[definition.key], .null)
        XCTAssertEqual(snapshot.value?.storedKeys.contains(definition.key), false)
        XCTAssertEqual(writer.wait(timeout: .now() + 2.0), .success)
        XCTAssertEqual(errors.value, [])
        XCTAssertEqual(store.string(definition.key), "cached-native-secret")
        XCTAssertTrue(store.readSnapshot().storedKeys.contains(definition.key))
    }

    func testSecretRoundTripRedactionExportResetAndErrorSanitization() throws {
        let url = try self.storageURL()
        let secrets = SettingsTestSecrets()
        let definition = ClientSettingDefinition(key: "fixture.apiKey", title: "API key", section: "Fixture", defaultValue: .string(""), isSecret: true)
        let store = try ClientSettings(storageURL: url, secretStore: secrets)
        try store.register([definition, self.definition("fixture.enabled", .bool(false))])
        let secret = "ONLY-IN-INJECTED-SECRET-STORE-7b8fd9"
        try store.set(.string(secret), for: definition.key)
        XCTAssertEqual(store.string(definition.key), secret)
        XCTAssertEqual(store.value(definition.key), .string(secret), "Native structured consumers may read secret values")
        XCTAssertEqual(store.snapshot()[definition.key], .null)
        XCTAssertTrue(store.readSnapshot().storedKeys.contains(definition.key))
        let exported = try store.exportJSON()
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains(secret))
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains(definition.key))
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(secret))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(store.snapshot()), as: UTF8.self).contains(secret))
        try store.setPublic(.bool(true), for: "fixture.enabled")
        XCTAssertTrue(store.bool("fixture.enabled"))
        XCTAssertThrowsError(try store.setPublic(.string("plugin-replacement"), for: definition.key)) { error in
            XCTAssertEqual(error as? ClientSettingsError, .secretAccessDenied)
        }
        XCTAssertEqual(store.string(definition.key), secret)

        let reopened = try ClientSettings(storageURL: url, secretStore: secrets)
        try reopened.register([definition])
        XCTAssertEqual(reopened.string(definition.key), secret)
        secrets.failWrites.update { $0 = true }
        XCTAssertThrowsError(try reopened.set(.string("replacement"), for: definition.key)) { error in
            XCTAssertEqual(error as? ClientSettingsError, .secretStorageFailure(status: -1))
            XCTAssertFalse(error.localizedDescription.contains("DO-NOT-EXPOSE"))
        }
        XCTAssertEqual(reopened.string(definition.key), secret)
        secrets.failWrites.update { $0 = false }
        try reopened.reset(definition.key)
        XCTAssertEqual(reopened.string(definition.key), "")
        XCTAssertNil(try secrets.data(for: definition.key))
        XCTAssertFalse(reopened.readSnapshot().storedKeys.contains(definition.key))

        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(Set(files), Set(["client-settings.json", "client-settings.json.lock"]))
    }

    func testPlaintextSecretMigrationIsDurableBeforeRedactionAndFailurePreservesSource() throws {
        let url = try self.storageURL()
        let original = Data("{\"fixture.apiKey\":\"LEGACY-SECRET-FIXTURE\",\"unknown\":27}".utf8)
        try original.write(to: url)
        let secrets = SettingsTestSecrets()
        let store = try ClientSettings(storageURL: url, secretStore: secrets)
        let definition = ClientSettingDefinition(key: "fixture.apiKey", title: "API key", section: "Fixture", defaultValue: .string(""), isSecret: true)
        secrets.failWrites.update { $0 = true }
        XCTAssertThrowsError(try store.register([definition]))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(store.snapshot().values.contains(.string("LEGACY-SECRET-FIXTURE")))
        secrets.failWrites.update { $0 = false }
        try store.register([definition])
        XCTAssertEqual(store.string(definition.key), "LEGACY-SECRET-FIXTURE")
        XCTAssertNotNil(try secrets.data(for: definition.key))
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("LEGACY-SECRET-FIXTURE"))
        guard case let .object(values) = try self.document(url)["values"] else { return XCTFail("Missing values") }
        XCTAssertEqual(values, ["unknown": .integer(27)])
        XCTAssertThrowsError(try ClientSettings(storageURL: url, secretStore: secrets).register([
            self.definition("fixture.apiKey", .string(""))
        ]), "A later schema cannot downgrade a persisted secret to plaintext")
    }

    func testFailedSecretUpgradeRedactsTheOldCacheAndBlocksPlaintextWrites() throws {
        let url = try self.storageURL()
        let secrets = SettingsTestSecrets()
        let store = try ClientSettings(storageURL: url, secretStore: secrets)
        try store.register([self.definition("fixture.credential", .string(""))])
        try store.set(.string("LEGACY-CACHED-SECRET"), for: "fixture.credential")
        let original = try Data(contentsOf: url)
        let secure = ClientSettingDefinition(key: "fixture.credential", title: "Credential", section: "Fixture", defaultValue: .string(""), isSecret: true)
        secrets.failWrites.update { $0 = true }
        XCTAssertThrowsError(try store.register([secure]))
        XCTAssertEqual(store.snapshot()[secure.key], .null)
        XCTAssertFalse(String(decoding: try store.exportJSON(), as: UTF8.self).contains("LEGACY-CACHED-SECRET"))
        XCTAssertThrowsError(try store.set(.string("must-not-write-plaintext"), for: secure.key))
        XCTAssertThrowsError(try store.setPublic(.string("must-not-write-a-classified-secret"), for: secure.key)) { error in
            XCTAssertEqual(error as? ClientSettingsError, .secretAccessDenied)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        secrets.failWrites.update { $0 = false }
        try store.register([secure])
        XCTAssertEqual(store.string(secure.key), "LEGACY-CACHED-SECRET")
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("LEGACY-CACHED-SECRET"))
    }

    func testCorruptSecureItemIsPreservedOnReadAndRepairableByExplicitReplacement() throws {
        let url = try self.storageURL()
        let secrets = SettingsTestSecrets()
        let store = try ClientSettings(storageURL: url, secretStore: secrets)
        let definition = ClientSettingDefinition(key: "fixture.secret", title: "Secret", section: "Fixture", defaultValue: .string(""), isSecret: true)
        try store.register([definition])
        try store.set(.string("previous"), for: definition.key)
        let corrupt = Data("not valid JSON".utf8)
        try secrets.set(corrupt, for: definition.key)
        XCTAssertThrowsError(try store.reload())
        XCTAssertEqual(try secrets.data(for: definition.key), corrupt)
        XCTAssertNil(store.value(definition.key), "A confirmed invalid item is present but has no typed value")
        XCTAssertTrue(store.readSnapshot().storedKeys.contains(definition.key))
        try store.set(.string("replacement"), for: definition.key)
        XCTAssertEqual(store.string(definition.key), "replacement")
        try secrets.set(corrupt, for: definition.key)
        try store.reset(definition.key)
        XCTAssertNil(try secrets.data(for: definition.key))
        XCTAssertEqual(store.string(definition.key), "")
    }

    func testPublicBatchWritesAndPublishesTheWholePatchOnce() throws {
        let url = try self.storageURL()
        let writes = SettingsTestBox(0)
        let store = try ClientSettings(storageURL: url, secretStore: SettingsTestSecrets(), afterFileReplace: {
            writes.update { $0 += 1 }
        })
        try store.register([self.definition("fixture.a", .integer(0)), self.definition("fixture.b", .integer(0)),
                            self.definition("fixture.reset", .integer(5))])
        try store.set(.integer(9), for: "fixture.reset")
        let before = store.readSnapshot()
        writes.update { $0 = 0 }
        let events = SettingsTestBox<[Set<String>]>([])
        let observed = SettingsTestBox<[ClientSettingsSnapshot]>([])
        let files = SettingsTestBox<[Data]>([])
        let observation = store.observe { keys in
            events.update { $0.append(keys) }
            observed.update { $0.append(store.readSnapshot()) }
            if let data = try? Data(contentsOf: url) { files.update { $0.append(data) } }
        }
        defer { observation.cancel() }
        try store.applyPublic(["fixture.a": .integer(10), "fixture.b": .integer(20)], resetting: ["fixture.reset"], expected: before)
        XCTAssertEqual(writes.value, 1)
        XCTAssertEqual(events.value, [Set(["fixture.a", "fixture.b", "fixture.reset"])])
        XCTAssertEqual(observed.value.count, 1)
        let committed = try XCTUnwrap(observed.value.first)
        XCTAssertEqual(committed.values, ["fixture.a": .integer(10), "fixture.b": .integer(20), "fixture.reset": .integer(5)])
        XCTAssertEqual(committed.storedKeys, Set(["fixture.a", "fixture.b"]))
        XCTAssertEqual(files.value, [try Data(contentsOf: url)], "Observers see the complete replacement, never a partially written patch")
        try store.applyPublic([:], expected: before)
        XCTAssertEqual(writes.value, 1)
        XCTAssertEqual(events.value.count, 1, "An empty batch is not a refresh or a write")
    }

    func testPublicBatchRejectsInvalidKeysEnumsRangesAndOverlapBeforeAnyWrite() throws {
        let url = try self.storageURL()
        let writes = SettingsTestBox(0)
        let store = try ClientSettings(storageURL: url, secretStore: SettingsTestSecrets(), afterFileReplace: {
            writes.update { $0 += 1 }
        })
        let count = ClientSettingDefinition(key: "fixture.count", title: "Count", section: "Fixture", defaultValue: .integer(2), minimum: 0, maximum: 8, step: 2)
        let mode = ClientSettingDefinition(key: "fixture.mode", title: "Mode", section: "Fixture", defaultValue: .string("one"),
                                           options: [.init(value: .string("one"), title: "One"), .init(value: .string("two"), title: "Two")])
        try store.register([count, mode, self.definition("fixture.a", .bool(false)), self.definition("fixture.reset", .integer(5))])
        try store.set(.integer(9), for: "fixture.reset")
        let before = store.readSnapshot()
        let original = try Data(contentsOf: url)
        writes.update { $0 = 0 }
        let cases: [([String: ClientSettingValue], Set<String>, ClientSettingsError)] = [
            (["fixture.a": .bool(true), "fixture.mode": .string("invalid")], ["fixture.reset"], .invalidValue(key: "fixture.mode", reason: .option)),
            (["fixture.a": .bool(true), "fixture.count": .integer(10)], ["fixture.reset"], .invalidValue(key: "fixture.count", reason: .range)),
            (["fixture.a": .bool(true), "fixture.count": .integer(3)], [], .invalidValue(key: "fixture.count", reason: .step)),
            (["fixture.a": .bool(true), "fixture.count": .number(.infinity)], [], .nonFiniteNumber),
            (["fixture.a": .bool(true), "fixture.unknown": .null], [], .unregisteredKey("fixture.unknown")),
            (["fixture.a": .bool(true)], ["fixture.unknown"], .unregisteredKey("fixture.unknown")),
            (["fixture.a": .bool(true), "invalid/key": .bool(true)], [], .invalidKey),
            (["fixture.a": .bool(true)], ["fixture.a"], .conflictingChanges)
        ]
        for (values, resetting, error) in cases {
            XCTAssertThrowsError(try store.applyPublic(values, resetting: resetting, expected: before)) {
                XCTAssertEqual($0 as? ClientSettingsError, error)
            }
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertEqual(store.snapshot(), before.values)
            XCTAssertEqual(store.readSnapshot().storedKeys, before.storedKeys)
        }
        XCTAssertEqual(writes.value, 0)
    }

    func testPublicBatchSerializationFailureDoesNotPartiallyApplyResetsOrValues() throws {
        let url = try self.storageURL()
        let store = try ClientSettings(storageURL: url)
        try store.register([self.definition("fixture.a", .integer(0)), self.definition("fixture.large", .string("")),
                            self.definition("fixture.reset", .bool(false))])
        try store.set(.bool(true), for: "fixture.reset")
        let before = store.readSnapshot()
        let original = try Data(contentsOf: url)
        let tooLarge = String(repeating: "x", count: 8 * 1024 * 1024)
        XCTAssertThrowsError(try store.applyPublic(["fixture.a": .integer(1), "fixture.large": .string(tooLarge)],
                                                 resetting: ["fixture.reset"], expected: before))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(store.snapshot(), before.values)
        XCTAssertEqual(store.readSnapshot().storedKeys, before.storedKeys)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)),
                       Set(["client-settings.json", "client-settings.json.lock"]))
    }

    func testPublicBatchPreservesUnknownMetadataAndUnrelatedConcurrentUpdates() throws {
        let url = try self.storageURL()
        let definitions = [self.definition("fixture.a", .integer(0)), self.definition("fixture.other", .integer(0))]
        let first = try ClientSettings(storageURL: url)
        let second = try ClientSettings(storageURL: url)
        try first.register(definitions)
        try second.register(definitions)
        let before = first.readSnapshot()
        try second.set(.integer(42), for: "fixture.other")
        XCTAssertEqual(first.integer("fixture.other"), 0, "Keep the first process cache deliberately stale")
        var root = try self.document(url)
        guard case var .object(values) = root["values"] else { return XCTFail("Missing values") }
        values["future.unknown"] = .object(["items": .array([.null, .integer(Int64.max)])])
        root["values"] = .object(values)
        root["futureMetadata"] = .string("keep")
        try JSONEncoder().encode(root).write(to: url)
        try first.register([ClientSettingDefinition(key: "fixture.a", title: "Updated label", section: "Fixture", defaultValue: .integer(0))])
        try first.applyPublic(["fixture.a": .integer(7)], expected: before)
        XCTAssertEqual(first.integer("fixture.a"), 7)
        XCTAssertEqual(first.integer("fixture.other"), 42)
        let after = try self.document(url)
        XCTAssertEqual(after["version"], .integer(1))
        XCTAssertEqual(after["futureMetadata"], .string("keep"))
        guard case let .object(persisted) = after["values"] else { return XCTFail("Missing values") }
        XCTAssertEqual(persisted["future.unknown"], values["future.unknown"])
        XCTAssertEqual(persisted["fixture.other"], .integer(42))
    }

    func testPublicBatchRollbackRestoresAbsenceInsteadOfPersistingOldDefaults() throws {
        let url = try self.storageURL()
        let store = try ClientSettings(storageURL: url)
        try store.register([self.definition("fixture.absent", .integer(10)), self.definition("fixture.storedDefault", .integer(20))])
        try store.set(.integer(20), for: "fixture.storedDefault")
        let before = store.readSnapshot()
        let patch: [String: ClientSettingValue] = ["fixture.absent": .integer(11), "fixture.storedDefault": .integer(21)]
        let intended = self.expectedState(before, applying: patch)
        try store.applyPublic(patch, expected: before)
        let previousOverrides = before.values.filter { before.storedKeys.contains($0.key) }
        try store.applyPublic(previousOverrides, resetting: ["fixture.absent"], expected: intended)
        XCTAssertEqual(store.snapshot(), before.values)
        XCTAssertEqual(store.readSnapshot().storedKeys, before.storedKeys)
        guard case let .object(values) = try self.document(url)["values"] else { return XCTFail("Missing values") }
        XCTAssertNil(values["fixture.absent"])
        XCTAssertEqual(values["fixture.storedDefault"], .integer(20))
        try store.register([self.definition("fixture.absent", .integer(100)), self.definition("fixture.storedDefault", .integer(200))])
        XCTAssertEqual(store.integer("fixture.absent"), 100, "A reset follows the future default")
        XCTAssertEqual(store.integer("fixture.storedDefault"), 20, "An explicit old default remains an explicit override")
    }

    func testPublicBatchCASChecksDiskPresenceEvenWhenEffectiveValueIsUnchanged() throws {
        let url = try self.storageURL()
        let definition = self.definition("fixture.a", .integer(5))
        let first = try ClientSettings(storageURL: url)
        let second = try ClientSettings(storageURL: url)
        try first.register([definition])
        try second.register([definition])
        let absent = first.readSnapshot()
        try second.applyPublic([definition.key: .integer(5)])
        XCTAssertFalse(first.readSnapshot().storedKeys.contains(definition.key))
        XCTAssertThrowsError(try first.applyPublic([definition.key: .integer(8)], expected: absent)) {
            XCTAssertEqual($0 as? ClientSettingsError, .concurrentModification)
        }
        let stored = first.readSnapshot()
        XCTAssertTrue(stored.storedKeys.contains(definition.key))
        try second.applyPublic([:], resetting: [definition.key])
        XCTAssertThrowsError(try first.applyPublic([:], resetting: [definition.key], expected: stored)) {
            XCTAssertEqual($0 as? ClientSettingsError, .concurrentModification)
        }
        let missing = ClientSettingsSnapshot(definitions: [definition], values: [:], storedKeys: [])
        XCTAssertThrowsError(try first.applyPublic([definition.key: .integer(8)], expected: missing)) {
            XCTAssertEqual($0 as? ClientSettingsError, .concurrentModification)
        }
        XCTAssertEqual(first.integer(definition.key), 5)
        XCTAssertFalse(first.readSnapshot().storedKeys.contains(definition.key))
    }

    func testPublicBatchConcurrentCASHasExactlyOneCompleteWinner() throws {
        let url = try self.storageURL()
        let definitions = [self.definition("fixture.a", .integer(0)), self.definition("fixture.b", .integer(0))]
        let stores = [try ClientSettings(storageURL: url), try ClientSettings(storageURL: url)]
        for store in stores { try store.register(definitions) }
        let expected = stores[0].readSnapshot()
        let winners = SettingsTestBox<[Int]>([])
        let failures = SettingsTestBox<[ClientSettingsError]>([])
        let group = DispatchGroup()
        for (index, store) in stores.enumerated() {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                let value = index + 1
                do {
                    try store.applyPublic(["fixture.a": .integer(Int64(value)), "fixture.b": .integer(Int64(value))], expected: expected)
                    winners.update { $0.append(value) }
                } catch {
                    failures.update { $0.append(error as? ClientSettingsError ?? .invalidJSON) }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 3.0), .success)
        XCTAssertEqual(winners.value.count, 1)
        XCTAssertEqual(failures.value, [.concurrentModification])
        let winner = try XCTUnwrap(winners.value.first)
        let verify = try ClientSettings(storageURL: url)
        try verify.register(definitions)
        XCTAssertEqual(verify.integer("fixture.a"), winner)
        XCTAssertEqual(verify.integer("fixture.b"), winner)
    }

    func testPublicBatchDoesNotUseKeychainForCommitOrFailureRecovery() throws {
        let url = try self.storageURL()
        let secrets = SettingsTestSecrets()
        let secret = ClientSettingDefinition(key: "fixture.secret", title: "Secret", section: "Fixture", defaultValue: .string(""), isSecret: true)
        let store = try ClientSettings(storageURL: url, secretStore: secrets)
        try store.register([secret, self.definition("fixture.a", .integer(0))])
        try store.set(.string("cached-credential"), for: secret.key)
        let before = store.readSnapshot()
        let reads = secrets.readCount.value
        let writes = secrets.writeCount.value
        secrets.failReads.update { $0 = true }
        secrets.failWrites.update { $0 = true }
        try store.applyPublic(["fixture.a": .integer(1)], expected: before)
        let committed = try Data(contentsOf: url)
        for (values, resetting) in [
            (["fixture.a": ClientSettingValue.integer(2), secret.key: .string("denied")], Set<String>()),
            (["fixture.a": ClientSettingValue.integer(2)], Set([secret.key]))
        ] {
            XCTAssertThrowsError(try store.applyPublic(values, resetting: resetting, expected: before)) {
                XCTAssertEqual($0 as? ClientSettingsError, .secretAccessDenied, "Secret classification wins over the stale public CAS state")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), committed)
        XCTAssertEqual(store.integer("fixture.a"), 1)
        XCTAssertEqual(store.string(secret.key), "cached-credential")
        XCTAssertEqual(store.snapshot()[secret.key], .null)
        XCTAssertEqual(secrets.readCount.value, reads)
        XCTAssertEqual(secrets.writeCount.value, writes)
    }

    func testPublicBatchDiskSecretClassificationOverridesAnOlderPublicSnapshot() throws {
        let url = try self.storageURL()
        let secrets = SettingsTestSecrets()
        let normal = self.definition("fixture.credential", .string(""))
        let other = self.definition("fixture.other", .integer(0))
        let old = try ClientSettings(storageURL: url, secretStore: secrets)
        try old.register([normal, other])
        try old.set(.string("legacy-credential"), for: normal.key)
        let before = old.readSnapshot()
        let upgraded = try ClientSettings(storageURL: url, secretStore: secrets)
        let secure = ClientSettingDefinition(key: normal.key, title: "Credential", section: "Fixture", defaultValue: .string(""), isSecret: true)
        try upgraded.register([secure, other])
        let original = try Data(contentsOf: url)
        let reads = secrets.readCount.value
        let writes = secrets.writeCount.value
        XCTAssertThrowsError(try old.applyPublic([normal.key: .string("denied"), other.key: .integer(1)], expected: before)) {
            XCTAssertEqual($0 as? ClientSettingsError, .secretAccessDenied)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(old.snapshot()[normal.key], .null)
        let publicOnly = try ClientSettings(storageURL: url, secretStore: secrets)
        try publicOnly.register([other])
        XCTAssertThrowsError(try publicOnly.applyPublic([:], resetting: [normal.key])) {
            XCTAssertEqual($0 as? ClientSettingsError, .secretAccessDenied)
        }
        XCTAssertEqual(secrets.readCount.value, reads)
        XCTAssertEqual(secrets.writeCount.value, writes)
    }

    func testPublicBatchCannotWriteOrMigrateALearnedPlaintextSecret() throws {
        let url = try self.storageURL()
        let secrets = SettingsTestSecrets()
        let store = try ClientSettings(storageURL: url, secretStore: secrets)
        try store.register([self.definition("fixture.credential", .string("")), self.definition("fixture.other", .integer(0))])
        try store.set(.string("legacy-credential"), for: "fixture.credential")
        let before = store.readSnapshot()
        secrets.failWrites.update { $0 = true }
        let secret = ClientSettingDefinition(key: "fixture.credential", title: "Credential", section: "Fixture", defaultValue: .string(""), isSecret: true)
        XCTAssertThrowsError(try store.register([secret]))
        let original = try Data(contentsOf: url)
        let reads = secrets.readCount.value
        let writes = secrets.writeCount.value
        XCTAssertThrowsError(try store.applyPublic([secret.key: .string("denied")], expected: before)) {
            XCTAssertEqual($0 as? ClientSettingsError, .secretAccessDenied)
        }
        XCTAssertThrowsError(try store.applyPublic(["fixture.other": .integer(1)])) {
            XCTAssertEqual($0 as? ClientSettingsError, .secretAccessDenied)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(secrets.readCount.value, reads)
        XCTAssertEqual(secrets.writeCount.value, writes)
    }

    func testPublicBatchRollbackDoesNotOverwriteAnObserverEditBeforeReturn() throws {
        let url = try self.storageURL()
        let store = try ClientSettings(storageURL: url)
        try store.register([self.definition("fixture.a", .integer(0))])
        let before = store.readSnapshot()
        let patch: [String: ClientSettingValue] = ["fixture.a": .integer(1)]
        let intended = self.expectedState(before, applying: patch)
        let errors = SettingsTestBox<[String]>([])
        let observation = store.observe { keys in
            if keys.contains("fixture.a") && store.integer("fixture.a") == 1 {
                do { try store.set(.integer(2), for: "fixture.a") }
                catch { errors.update { $0.append(error.localizedDescription) } }
            }
        }
        defer { observation.cancel() }
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do { try store.applyPublic(patch, expected: before) }
            catch { errors.update { $0.append(error.localizedDescription) } }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 3.0), .success, "A batch must deliver observers outside writer/flock")
        XCTAssertEqual(errors.value, [])
        XCTAssertEqual(store.integer("fixture.a"), 2)
        XCTAssertThrowsError(try store.applyPublic([:], resetting: ["fixture.a"], expected: intended)) {
            XCTAssertEqual($0 as? ClientSettingsError, .concurrentModification)
        }
        XCTAssertEqual(store.integer("fixture.a"), 2)
        XCTAssertTrue(store.readSnapshot().storedKeys.contains("fixture.a"))
    }

    func testPublicBatchPostRenameErrorPublishesActualStateAndCanRollback() throws {
        let url = try self.storageURL()
        let failAfterRename = SettingsTestBox(false)
        let writes = SettingsTestBox(0)
        let store = try ClientSettings(storageURL: url, secretStore: SettingsTestSecrets(), afterFileReplace: {
            writes.update { $0 += 1 }
            if failAfterRename.value {
                throw NSError(domain: NSPOSIXErrorDomain, code: 5, userInfo: [NSLocalizedDescriptionKey: "DO-NOT-EXPOSE-SECRET-FIXTURE"])
            }
        })
        try store.register([self.definition("fixture.a", .integer(0)), self.definition("fixture.b", .integer(0))])
        let before = store.readSnapshot()
        let patch: [String: ClientSettingValue] = ["fixture.a": .integer(7), "fixture.b": .integer(8)]
        let intended = self.expectedState(before, applying: patch)
        let events = SettingsTestBox<[Set<String>]>([])
        let observation = store.observe { keys in events.update { $0.append(keys) } }
        defer { observation.cancel() }
        failAfterRename.update { $0 = true }
        XCTAssertThrowsError(try store.applyPublic(patch, expected: before)) { error in
            XCTAssertEqual(error as? ClientSettingsError, .storageFailure(operation: "sync directory", code: 5))
            XCTAssertFalse(error.localizedDescription.contains("DO-NOT-EXPOSE"))
        }
        XCTAssertEqual(writes.value, 1)
        XCTAssertEqual(events.value, [Set(patch.keys)])
        XCTAssertEqual(store.snapshot(), intended.values)
        XCTAssertEqual(store.readSnapshot().storedKeys, intended.storedKeys)
        guard case let .object(persisted) = try self.document(url)["values"] else { return XCTFail("Missing values") }
        XCTAssertEqual(persisted, patch)
        failAfterRename.update { $0 = false }
        try store.applyPublic([:], resetting: Set(patch.keys), expected: intended)
        XCTAssertEqual(writes.value, 2)
        XCTAssertEqual(events.value.count, 2)
        XCTAssertEqual(store.snapshot(), before.values)
        XCTAssertEqual(store.readSnapshot().storedKeys, before.storedKeys)
        XCTAssertNil(store.lastError)
    }

    func testPublicBatchCASUsesExactJSONValuesIncludingNestedNumbersAndNullPresence() throws {
        let url = try self.storageURL()
        let store = try ClientSettings(storageURL: url)
        try store.register([self.definition("fixture.value", .null)])
        let nested: ClientSettingValue = .object(["nested": .array([.number(1.0), .integer(Int64.max), .bool(true), .null])])
        try store.set(nested, for: "fixture.value")
        let before = store.readSnapshot()
        // Pin the integer-token form explicitly instead of depending on whether
        // a particular Foundation encoder chooses 1 or 1.0 for the same number.
        var root = try self.document(url)
        root["values"] = .object(["fixture.value": .object(["nested": .array([.integer(1), .integer(Int64.max), .bool(true), .null])])])
        try JSONEncoder().encode(root).write(to: url)
        try store.applyPublic(["fixture.value": .integer(Int64.max)], expected: before)
        let exactInteger = store.readSnapshot()
        XCTAssertThrowsError(try store.set(.number(Double(Int64.max)), for: "fixture.value")) {
            XCTAssertEqual($0 as? ClientSettingsError, .unsupportedNumber)
        }
        XCTAssertEqual(store.snapshot(), exactInteger.values)
        try store.set(.bool(true), for: "fixture.value")
        let boolean = store.readSnapshot()
        try store.set(.integer(1), for: "fixture.value")
        XCTAssertThrowsError(try store.applyPublic(["fixture.value": .null], expected: boolean)) {
            XCTAssertEqual($0 as? ClientSettingsError, .concurrentModification)
        }
        try store.applyPublic([:], resetting: ["fixture.value"])
        let absentNull = store.readSnapshot()
        try store.applyPublic(["fixture.value": .null], expected: absentNull)
        XCTAssertThrowsError(try store.applyPublic([:], resetting: ["fixture.value"], expected: absentNull)) {
            XCTAssertEqual($0 as? ClientSettingsError, .concurrentModification)
        }
        XCTAssertEqual(store.value("fixture.value"), .null)
        XCTAssertTrue(store.readSnapshot().storedKeys.contains("fixture.value"))
    }

    func testSC01FailedSecretRenameProtectsSourceAndAllowsNativeRetry() throws {
        let url = try self.storageURL()
        let secrets = SettingsTestSecrets()
        let store = try ClientSettings(storageURL: url, secretStore: secrets)
        let old = self.definition("review.old", .string(""))
        let secure = ClientSettingDefinition(key: "review.secure", title: "Secure", section: "Review", defaultValue: .string(""), isSecret: true)
        let flag = self.definition("review.flag", .bool(false))
        try store.register([old, secure, flag])
        try store.set(.string("ALIAS-CREDENTIAL-FIXTURE"), for: old.key)
        let original = try Data(contentsOf: url)
        secrets.failWrites.update { $0 = true }
        XCTAssertThrowsError(try store.migrateKey(from: old.key, to: secure.key))
        XCTAssertNil(store.snapshot()[old.key])
        XCTAssertTrue(store.readSnapshot().secretKeys.contains(old.key))
        XCTAssertFalse(String(decoding: try store.exportJSON(), as: UTF8.self).contains("ALIAS-CREDENTIAL-FIXTURE"))
        XCTAssertThrowsError(try store.setPublic(.string("denied"), for: old.key))
        XCTAssertThrowsError(try store.applyPublic([flag.key: .bool(true)]))
        XCTAssertEqual(try Data(contentsOf: url), original)
        secrets.failWrites.update { $0 = false }
        try store.migrateKey(from: old.key, to: secure.key)
        try store.migrateKey(from: old.key, to: secure.key)
        XCTAssertEqual(store.string(secure.key), "ALIAS-CREDENTIAL-FIXTURE")
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("ALIAS-CREDENTIAL-FIXTURE"))
        let reopened = try ClientSettings(storageURL: url, secretStore: secrets)
        try reopened.register([old, secure, flag])
        XCTAssertFalse(reopened.definitions().contains(where: { $0.key == old.key }))
        XCTAssertThrowsError(try reopened.setPublic(.string("denied"), for: old.key))
        XCTAssertFalse(String(decoding: try reopened.exportJSON(), as: UTF8.self).contains(old.key))
        try reopened.applyPublic([flag.key: .bool(true)])
        XCTAssertEqual(reopened.string(secure.key), "ALIAS-CREDENTIAL-FIXTURE")
    }

    func testSC08SecretDestinationWinsBeforeLosingSourceValidation() throws {
        let url = try self.storageURL()
        let secrets = SettingsTestSecrets()
        let secure = ClientSettingDefinition(key: "review.secure", title: "Secure", section: "Review", defaultValue: .string(""), isSecret: true)
        let raw = Data("{\"review.old\":{\"obsolete\":true}}".utf8)
        try raw.write(to: url)
        try secrets.set(try JSONEncoder().encode(ClientSettingValue.string("DESTINATION-FIXTURE")), for: secure.key)
        let store = try ClientSettings(storageURL: url, secretStore: secrets)
        try store.register([secure])
        let writes = secrets.writeCount.value
        try store.migrateKey(from: "review.old", to: secure.key)
        try store.migrateKey(from: "review.old", to: secure.key)
        XCTAssertEqual(store.string(secure.key), "DESTINATION-FIXTURE")
        XCTAssertEqual(secrets.writeCount.value, writes)
        guard case let .object(values) = try self.document(url)["values"] else { return XCTFail("Missing values") }
        XCTAssertNil(values["review.old"])

        let absentURL = try self.storageURL()
        try raw.write(to: absentURL)
        let absent = try ClientSettings(storageURL: absentURL, secretStore: SettingsTestSecrets())
        try absent.register([secure])
        let before = try Data(contentsOf: absentURL)
        XCTAssertThrowsError(try absent.migrateKey(from: "review.old", to: secure.key))
        XCTAssertEqual(try Data(contentsOf: absentURL), before)
        XCTAssertFalse(absent.readSnapshot().storedKeys.contains(secure.key))
    }

    func testSC02StrictRawNumbersAndBridgeRequestValuesNeverRoundIntegers() throws {
        let unsupported = ["18446744073709551614", "18446744073709551615", "-9223372036854775809",
                           "18446744073709551615.0", "1.8446744073709551615e19", "0.1000000000000000000001"]
        for token in unsupported {
            for json in [token, "{\"nested\":[\(token)]}",
                         "{\"op\":\"call\",\"fqcn\":\"exteraless.ios.Runtime\",\"member\":\"getClientSetting\",\"args\":[\"unknown\",\(token)]}",
                         "{\"op\":\"call\",\"fqcn\":\"exteraless.ios.Runtime\",\"member\":\"setClientSetting\",\"args\":[\"review.value\",\(token)]}"] {
                XCTAssertThrowsError(try ClientSettingValue.decodeJSON(json))
            }
        }
        for token in unsupported.prefix(3) {
            XCTAssertThrowsError(try JSONDecoder().decode(ClientSettingValue.self, from: Data(token.utf8)))
        }
        XCTAssertEqual(try ClientSettingValue.decodeJSON("\"18446744073709551615\""), .string("18446744073709551615"))
        XCTAssertEqual(try ClientSettingValue.decodeJSON("9223372036854775807"), .integer(Int64.max))
        XCTAssertEqual(try ClientSettingValue.decodeJSON("-9223372036854775808"), .integer(Int64.min))
        XCTAssertEqual(try ClientSettingValue.decodeJSON("1.250e2"), .integer(125))
        XCTAssertEqual(try ClientSettingValue.decodeJSON("0.1250"), .number(0.125))
        let exact = Double(9_007_199_254_740_994 as Int64)
        XCTAssertEqual(try ClientSettingValue.decodeJSON(JSONEncoder().encode(ClientSettingValue.number(exact))), .integer(9_007_199_254_740_994))
    }

    func testSC02UnsupportedUnknownValuesAndMetadataPreserveTheEntireFile() throws {
        let url = try self.storageURL()
        let store = try ClientSettings(storageURL: url)
        try store.register([self.definition("review.flag", .bool(false))])
        try store.set(.bool(false), for: "review.flag")
        let expected = store.readSnapshot()
        for token in ["18446744073709551614", "18446744073709551615"] {
            for extra in ["\"future\":\(token)", "\"future\":{\"nested\":[\(token)]}"] {
                let documents = [
                    "{\"$format\":\"exteraless.client-settings\",\"version\":1,\"values\":{\"review.flag\":false,\(extra)},\"secretKeys\":[]}",
                    "{\"$format\":\"exteraless.client-settings\",\"version\":1,\"values\":{\"review.flag\":false},\"secretKeys\":[],\(extra)}"
                ]
                for document in documents {
                    let raw = Data(document.utf8)
                    try raw.write(to: url)
                    XCTAssertThrowsError(try store.reload())
                    XCTAssertThrowsError(try store.setPublic(.bool(true), for: "review.flag"))
                    XCTAssertThrowsError(try store.applyPublic(["review.flag": .bool(true)], expected: expected))
                    XCTAssertEqual(try Data(contentsOf: url), raw)
                }
            }
        }
    }

    func testSC03StructuredAndNullableEnumsUseRecursiveJSONEquivalence() throws {
        let url = try self.storageURL()
        let option: ClientSettingValue = .object(["n": .array([.number(1.0), .bool(true)])])
        let definition = ClientSettingDefinition(key: "review.enum", title: "Enum", section: "Review", defaultValue: option,
                                                 options: [.init(value: option, title: "One")])
        let nullable = ClientSettingDefinition(key: "review.nullable", title: "Nullable", section: "Review", defaultValue: .null,
                                               options: [.init(value: .null, title: "None"), .init(value: .number(1.0), title: "One")])
        let store = try ClientSettings(storageURL: url)
        try store.register([definition, nullable])
        try store.set(option, for: definition.key)
        try store.set(.integer(1), for: nullable.key)
        let reopened = try ClientSettings(storageURL: url)
        try reopened.register([definition, nullable])
        XCTAssertEqual(reopened.value(definition.key), option)
        XCTAssertEqual(reopened.value(nullable.key), .number(1.0))
        try Data("{\"review.enum\":{\"n\":[1,true]},\"review.nullable\":1}".utf8).write(to: url)
        try reopened.reload()
        XCTAssertEqual(reopened.value(definition.key), option)
        XCTAssertThrowsError(try reopened.set(.object(["n": .array([.integer(1), .integer(1)])]), for: definition.key))
        let duplicate = ClientSettingDefinition(key: "review.duplicate", title: "Duplicate", section: "Review", defaultValue: option,
                                                options: [.init(value: option, title: "A"), .init(value: .object(["n": .array([.integer(1), .bool(true)])]), title: "B")])
        XCTAssertThrowsError(try reopened.register([duplicate]))
    }

    func testSC04IntegerBoundsAreExactAboveDoubleIntegerPrecision() throws {
        let bound: Int64 = 9_007_199_254_740_992
        let url = try self.storageURL()
        let store = try ClientSettings(storageURL: url)
        let definition = ClientSettingDefinition(key: "review.integer", title: "Integer", section: "Review", defaultValue: .integer(0),
                                                 minimum: -Double(bound), maximum: Double(bound), step: 1)
        try store.register([definition])
        for value in [bound - 1, bound, -bound, -bound + 1] { try store.set(.integer(value), for: definition.key) }
        let before = try Data(contentsOf: url)
        for value in [bound + 1, -bound - 1] {
            XCTAssertThrowsError(try store.set(.integer(value), for: definition.key))
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
        let stepped = ClientSettingDefinition(key: "review.step", title: "Step", section: "Review", defaultValue: .integer(bound),
                                              minimum: Double(bound), maximum: Double(bound + 4), step: 2)
        try store.register([stepped])
        try store.set(.integer(bound + 2), for: stepped.key)
        XCTAssertThrowsError(try store.set(.integer(bound + 1), for: stepped.key))
    }

    func testSC05SecretExplicitDefaultsKeepPresenceUntilReset() throws {
        let url = try self.storageURL()
        let secrets = SettingsTestSecrets()
        try Data("{\"review.flag\":false,\"review.count\":0}".utf8).write(to: url)
        func definitions(flag: Bool, count: Int64) -> [ClientSettingDefinition] {
            return [
                .init(key: "review.flag", title: "Flag", section: "Review", defaultValue: .bool(flag), isSecret: true),
                .init(key: "review.count", title: "Count", section: "Review", defaultValue: .integer(count), isSecret: true),
                .init(key: "review.empty", title: "Empty", section: "Review", defaultValue: .array([]), isSecret: true)
            ]
        }
        let store = try ClientSettings(storageURL: url, secretStore: secrets)
        try store.register(definitions(flag: false, count: 0))
        try store.set(.array([]), for: "review.empty")
        XCTAssertEqual(store.readSnapshot().storedKeys, Set(["review.flag", "review.count", "review.empty"]))
        try store.register(definitions(flag: true, count: 9))
        XCTAssertFalse(store.bool("review.flag"))
        XCTAssertEqual(store.integer("review.count"), 0)
        let reopened = try ClientSettings(storageURL: url, secretStore: secrets)
        try reopened.register(definitions(flag: true, count: 9))
        XCTAssertFalse(reopened.bool("review.flag"))
        XCTAssertEqual(reopened.integer("review.count"), 0)
        try reopened.set(.bool(true), for: "review.flag")
        try reopened.register(definitions(flag: false, count: 9))
        XCTAssertTrue(reopened.bool("review.flag"), "An explicit default is still an override")
        try reopened.reset("review.flag")
        XCTAssertFalse(reopened.bool("review.flag"))
        XCTAssertFalse(reopened.readSnapshot().storedKeys.contains("review.flag"))
    }

    func testSC06IdenticalRetriesConfirmDirectorySyncEvenInANewInstance() throws {
        let url = try self.storageURL()
        let fail = SettingsTestBox(false)
        let syncs = SettingsTestBox(0)
        let renames = SettingsTestBox(0)
        let hooks = ClientSettingsFileHooks(beforeDirectorySync: { _, stage in
            if stage == .settings {
                syncs.update { $0 += 1 }
                if fail.value { throw NSError(domain: NSPOSIXErrorDomain, code: 5) }
            }
        })
        let store = try ClientSettings(storageURL: url, secretStore: SettingsTestSecrets(), afterFileReplace: { renames.update { $0 += 1 } }, fileHooks: hooks)
        let definition = self.definition("review.flag", .bool(false))
        try store.register([definition])
        fail.update { $0 = true }
        XCTAssertThrowsError(try store.applyPublic([definition.key: .bool(true)]))
        XCTAssertTrue(store.bool(definition.key))
        let intended = store.readSnapshot()
        XCTAssertThrowsError(try store.applyPublic([definition.key: .bool(true)], expected: intended))
        XCTAssertThrowsError(try store.set(.bool(true), for: definition.key))
        XCTAssertEqual(renames.value, 1)
        XCTAssertEqual(syncs.value, 3)
        let reopened = try ClientSettings(storageURL: url, secretStore: SettingsTestSecrets(), afterFileReplace: nil, fileHooks: hooks)
        try reopened.register([definition])
        XCTAssertThrowsError(try reopened.applyPublic([definition.key: .bool(true)]))
        XCTAssertEqual(syncs.value, 4)
        fail.update { $0 = false }
        try reopened.applyPublic([definition.key: .bool(true)])
        XCTAssertEqual(syncs.value, 5)
        XCTAssertNil(reopened.lastError)
    }

    func testSC07SecondCreatorPublishesAllAncestorsWhileFirstIsPaused() throws {
        let root = try self.storageURL().deletingLastPathComponent().resolvingSymlinksInPath()
        let one = root.appendingPathComponent("one", isDirectory: true)
        let two = one.appendingPathComponent("two", isDirectory: true)
        let three = two.appendingPathComponent("three", isDirectory: true)
        let target = three.appendingPathComponent("client-settings.json")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let paused = SettingsTestBox(false)
        let faults = SettingsTestBox(0)
        let firstHooks = ClientSettingsFileHooks(afterDirectoriesCreated: { directory in
            guard directory.path == target.deletingLastPathComponent().path else { return }
            var pause = false
            paused.update { if !$0 { $0 = true; pause = true } }
            if pause {
                entered.signal()
                guard release.wait(timeout: .now() + 3.0) == .success else { throw SettingsTestSecretFailure() }
            }
            throw SettingsTestSecretFailure()
        })
        let first = try ClientSettings(storageURL: root.appendingPathComponent("initial.json"), secretStore: SettingsTestSecrets(),
                                       afterFileReplace: nil, durabilityRootURL: root, fileHooks: firstHooks)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do { try first.configure(storageURL: target, durabilityRootURL: root) }
            catch { faults.update { $0 += 1 } }
        }
        defer { release.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 1.0), .success)
        let synced = SettingsTestBox<Set<String>>([])
        let secondHooks = ClientSettingsFileHooks(beforeDirectorySync: { directory, stage in
            if stage == .ancestors { synced.update { $0.insert(directory.path) } }
        })
        let second = try ClientSettings(storageURL: target, secretStore: SettingsTestSecrets(), afterFileReplace: nil,
                                        durabilityRootURL: root, fileHooks: secondHooks)
        let definition = self.definition("review.flag", .bool(false))
        try second.register([definition])
        try second.applyPublic([definition.key: .bool(true)])
        for directory in [root, one, two, three] {
            XCTAssertTrue(synced.value.contains(directory.path))
        }
        release.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 2.0), .success)
        XCTAssertEqual(faults.value, 1)
        XCTAssertTrue(second.bool(definition.key))
    }

    func testSC07AncestorSyncFailureCannotBeSkippedOnVisibleDirectoryRetry() throws {
        let root = try self.storageURL().deletingLastPathComponent().resolvingSymlinksInPath()
        let parent = root.appendingPathComponent("new", isDirectory: true)
        let child = parent.appendingPathComponent("child", isDirectory: true)
        let target = child.appendingPathComponent("client-settings.json")
        let fail = SettingsTestBox(false)
        let visited = SettingsTestBox<[String]>([])
        let hooks = ClientSettingsFileHooks(beforeDirectorySync: { directory, stage in
            if stage == .ancestors {
                visited.update { $0.append(directory.path) }
                if fail.value && directory.path == root.path { throw NSError(domain: NSPOSIXErrorDomain, code: 5) }
            }
        })
        let store = try ClientSettings(storageURL: root.appendingPathComponent("initial.json"), secretStore: SettingsTestSecrets(),
                                       afterFileReplace: nil, durabilityRootURL: root, fileHooks: hooks)
        let definition = self.definition("review.flag", .bool(false))
        try store.register([definition])
        fail.update { $0 = true }
        XCTAssertThrowsError(try store.configure(storageURL: target, durabilityRootURL: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path))
        let previousVisits = visited.value.count
        XCTAssertThrowsError(try store.applyPublic([definition.key: .bool(true)]))
        XCTAssertGreaterThan(visited.value.count, previousVisits)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        fail.update { $0 = false }
        try store.applyPublic([definition.key: .bool(true)])
        XCTAssertTrue(visited.value.contains(parent.path))
        XCTAssertTrue(visited.value.contains(target.deletingLastPathComponent().path))
        XCTAssertTrue(store.bool(definition.key))
    }

    func testColdStartCorruptKeychainItemsRemainAddressableForNativeRepair() throws {
        let url = try self.storageURL()
        let secrets = SettingsTestSecrets()
        let a = ClientSettingDefinition(key: "review.a", title: "A", section: "Review", defaultValue: .string(""), isSecret: true)
        let b = ClientSettingDefinition(key: "review.b", title: "B", section: "Review", defaultValue: .string(""), isSecret: true)
        try secrets.set(Data("invalid".utf8), for: a.key)
        try secrets.set(Data("invalid".utf8), for: b.key)
        let store = try ClientSettings(storageURL: url, secretStore: secrets)
        XCTAssertThrowsError(try store.register([a, b]))
        XCTAssertEqual(store.definitions(), [a, b])
        XCTAssertThrowsError(try store.reset(a.key), "The other unreadable item remains an error")
        XCTAssertNil(try secrets.data(for: a.key), "The explicitly targeted repair did complete")
        try store.set(.string("REPAIRED-FIXTURE"), for: b.key)
        XCTAssertEqual(store.string(b.key), "REPAIRED-FIXTURE")
        XCTAssertNil(store.lastError)
        XCTAssertThrowsError(try store.setPublic(.string("denied"), for: b.key))
    }

    private func serviceShape(maximumCount: Int = 1) -> ClientSettingShape {
        return .array(.object(["id": .string, "name": .string, "url": .string, "model": .string,
                               "reasoningEffort": .integer, "wireProtocol": .string],
                              required: ["id", "name", "url", "model"]), maximumCount: maximumCount)
    }

    func testShapeClosedServicesRejectCredentialKeysWrongTypesAndOversizedArrays() throws {
        let url = try self.storageURL()
        let store = try ClientSettings(storageURL: url)
        let definition = ClientSettingDefinition(key: "review.services", title: "Services", section: "Review", defaultValue: .array([]), valueShape: self.serviceShape())
        try store.register([definition])
        let service: [String: ClientSettingValue] = ["id": .string("fixture"), "name": .string("Fixture"), "url": .string("https://example.invalid"),
                                                   "model": .string("fixture-model"), "reasoningEffort": .integer(1), "wireProtocol": .string("openAI")]
        try store.set(.array([.object(service)]), for: definition.key)
        let original = try Data(contentsOf: url)
        var credential = service; credential["apiKey"] = .string("SHAPE-CREDENTIAL-FIXTURE")
        var wrongType = service; wrongType["reasoningEffort"] = .bool(true)
        var missing = service; missing.removeValue(forKey: "id")
        for value in [ClientSettingValue.array([.object(credential)]), .array([.object(wrongType)]), .array([.object(missing)]),
                      .array([.object(service), .number(.nan)])] {
            XCTAssertThrowsError(try store.applyPublic([definition.key: value])) { error in
                XCTAssertEqual(error as? ClientSettingsError, .invalidValue(key: definition.key, reason: .shape))
            }
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
        let reopened = try ClientSettings(storageURL: url)
        try reopened.register([definition])
        XCTAssertEqual(reopened.value(definition.key), .array([.object(service)]))
        XCTAssertTrue(String(decoding: try reopened.exportJSON(), as: UTF8.self).contains("fixture-model"))
        XCTAssertFalse(String(decoding: try reopened.exportJSON(), as: UTF8.self).contains("SHAPE-CREDENTIAL-FIXTURE"))
    }

    func testShapeSchemaDefaultOptionsAndDepthValidation() throws {
        let store = try ClientSettings(storageURL: self.storageURL())
        let invalidRequired = ClientSettingDefinition(key: "review.required", title: "Required", section: "Review", defaultValue: .object([:]),
                                                      valueShape: .object(["id": .string], required: ["missing"]))
        let invalidCount = ClientSettingDefinition(key: "review.count", title: "Count", section: "Review", defaultValue: .array([]),
                                                   valueShape: .array(.any, maximumCount: -1))
        let invalidDefault = ClientSettingDefinition(key: "review.default", title: "Default", section: "Review", defaultValue: .array([.bool(true)]),
                                                     valueShape: .array(.integer, maximumCount: 1))
        let invalidOption = ClientSettingDefinition(key: "review.option", title: "Option", section: "Review", defaultValue: .array([]),
                                                    options: [.init(value: .array([.bool(true)]), title: "Wrong")], valueShape: .array(.number, maximumCount: 1))
        var deep: ClientSettingShape = .any
        for _ in 0..<62 { deep = .array(deep, maximumCount: 1) }
        for definition in [invalidRequired, invalidCount, invalidDefault, invalidOption,
                           .init(key: "review.deep", title: "Deep", section: "Review", defaultValue: .array([]), valueShape: deep)] {
            XCTAssertThrowsError(try store.register([definition]))
        }
        XCTAssertTrue(store.definitions().isEmpty)
        let numbers = ClientSettingDefinition(key: "review.numbers", title: "Numbers", section: "Review", defaultValue: .array([]),
                                              valueShape: .array(.number, maximumCount: 2))
        try store.register([numbers])
        try store.set(.array([.integer(Int64.max), .number(0.125)]), for: numbers.key)
        XCTAssertThrowsError(try store.set(.array([.bool(true)]), for: numbers.key))
    }

    func testShapeTighteningQuarantinesRejectedCachedValuesAndAllowsReplacement() throws {
        let url = try self.storageURL()
        let store = try ClientSettings(storageURL: url)
        let loose = self.definition("review.services", .array([]))
        try store.register([loose])
        try store.set(.array([.object(["apiKey": .string("LEGACY-SHAPE-CREDENTIAL")])]), for: loose.key)
        let original = try Data(contentsOf: url)
        let closed = ClientSettingDefinition(key: loose.key, title: "Services", section: "Review", defaultValue: .array([]), valueShape: self.serviceShape())
        XCTAssertThrowsError(try store.register([closed]))
        XCTAssertEqual(store.definitions(), [closed])
        XCTAssertNil(store.snapshot()[closed.key])
        XCTAssertFalse(String(decoding: try store.exportJSON(), as: UTF8.self).contains("LEGACY-SHAPE-CREDENTIAL"))
        XCTAssertEqual(try Data(contentsOf: url), original)
        try store.setPublic(.array([]), for: closed.key)
        XCTAssertEqual(store.value(closed.key), .array([]))
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("LEGACY-SHAPE-CREDENTIAL"))
    }

    func testSCF01TwoFailedAliasesCompleteTogetherOnNativeRetry() throws {
        let url = try self.storageURL()
        let secrets = SettingsTestSecrets()
        let renames = SettingsTestBox(0)
        let store = try ClientSettings(storageURL: url, secretStore: secrets, afterFileReplace: { renames.update { $0 += 1 } })
        let a = ClientSettingDefinition(key: "a.new", title: "A", section: "Follow-up", defaultValue: .bool(false), isSecret: true)
        let b = ClientSettingDefinition(key: "b.new", title: "B", section: "Follow-up", defaultValue: .bool(false), isSecret: true)
        let flag = self.definition("follow.flag", .bool(false))
        let definitions = [self.definition("a.old", .bool(false)), self.definition("b.old", .bool(false)), a, b, flag]
        try store.register(definitions)
        try store.set(.bool(true), for: "a.old")
        try store.set(.bool(true), for: "b.old")
        let original = try Data(contentsOf: url)
        secrets.failWrites.update { $0 = true }
        XCTAssertThrowsError(try store.migrateKey(from: "a.old", to: a.key))
        XCTAssertThrowsError(try store.migrateKey(from: "b.old", to: b.key))
        XCTAssertEqual(try Data(contentsOf: url), original)
        for key in ["a.old", "b.old"] {
            XCTAssertNil(store.snapshot()[key])
            XCTAssertTrue(store.readSnapshot().secretKeys.contains(key))
            XCTAssertThrowsError(try store.setPublic(.bool(false), for: key))
        }
        XCTAssertThrowsError(try store.applyPublic([flag.key: .bool(true)]))
        secrets.failWrites.update { $0 = false }
        let previousRenames = renames.value
        try store.migrateKey(from: "a.old", to: a.key)
        XCTAssertEqual(renames.value, previousRenames + 1, "The whole pending cohort has one JSON cleanup commit")
        try store.migrateKey(from: "b.old", to: b.key)
        try store.migrateKey(from: "a.old", to: a.key)
        XCTAssertEqual(renames.value, previousRenames + 1)
        XCTAssertTrue(store.bool(a.key))
        XCTAssertTrue(store.bool(b.key))
        XCTAssertEqual(try self.rawSecret(a.key, in: secrets), .bool(true))
        XCTAssertEqual(try self.rawSecret(b.key, in: secrets), .bool(true))
        guard case let .object(values) = try self.document(url)["values"] else { return XCTFail("Missing values") }
        XCTAssertNil(values["a.old"])
        XCTAssertNil(values["b.old"])
        let reopened = try ClientSettings(storageURL: url, secretStore: secrets)
        try reopened.register(definitions)
        try reopened.applyPublic([flag.key: .bool(true)])
        XCTAssertTrue(reopened.bool(flag.key))
        XCTAssertTrue(reopened.bool(a.key))
        XCTAssertTrue(reopened.bool(b.key))
        let exported = String(decoding: try reopened.exportJSON(), as: UTF8.self)
        for key in ["a.old", "b.old", a.key, b.key] {
            XCTAssertFalse(exported.contains(key))
            XCTAssertThrowsError(try reopened.setPublic(.bool(false), for: key))
        }
    }

    func testSCF02InvalidLegacySecretStringsAllowPerKeyResetThenSet() throws {
        let url = try self.storageURL()
        let secrets = SettingsTestSecrets()
        let original = Data("{\"a\":false,\"b\":false,\"future\":17}".utf8)
        try original.write(to: url)
        let a = ClientSettingDefinition(key: "a", title: "A", section: "Follow-up", defaultValue: .string(""), isSecret: true)
        let b = ClientSettingDefinition(key: "b", title: "B", section: "Follow-up", defaultValue: .string(""), isSecret: true)
        let flag = self.definition("follow.flag", .bool(false))
        let store = try ClientSettings(storageURL: url, secretStore: secrets)
        XCTAssertThrowsError(try store.register([a, b, flag]))
        XCTAssertThrowsError(try store.setPublic(.bool(true), for: flag.key))
        XCTAssertThrowsError(try store.applyPublic([:], resetting: [a.key, b.key]))
        XCTAssertEqual(secrets.writeCount.value, 0, "Public calls cannot quarantine or repair credentials")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertThrowsError(try store.reset(a.key)) { error in
            XCTAssertEqual(error as? ClientSettingsError, .invalidValue(key: b.key, reason: .type))
        }
        XCTAssertNil(try secrets.data(for: a.key))
        XCTAssertEqual(try self.rawSecret(b.key, in: secrets), .bool(false), "The unrequested legacy value is preserved securely")
        XCTAssertEqual(store.value(a.key), .string(""))
        XCTAssertNil(store.value(b.key), "An invalid raw value is not published as a typed credential")
        XCTAssertTrue(store.readSnapshot().storedKeys.contains(b.key))
        XCTAssertFalse(store.readSnapshot().storedKeys.contains(a.key))
        XCTAssertNotNil(store.lastError)
        guard case let .object(values) = try self.document(url)["values"] else { return XCTFail("Missing values") }
        XCTAssertEqual(values, ["future": .integer(17)])
        let reopened = try ClientSettings(storageURL: url, secretStore: secrets)
        XCTAssertThrowsError(try reopened.register([a, b, flag]), "The quarantined raw value still requires native repair")
        XCTAssertTrue(reopened.readSnapshot().storedKeys.contains(b.key))
        XCTAssertNil(reopened.value(b.key))
        XCTAssertFalse(String(decoding: try reopened.exportJSON(), as: UTF8.self).contains("\"b\""))
        try reopened.set(.string("REPAIRED-B-FIXTURE"), for: b.key)
        XCTAssertEqual(reopened.string(b.key), "REPAIRED-B-FIXTURE")
        XCTAssertFalse(reopened.readSnapshot().storedKeys.contains(a.key))
        XCTAssertNil(reopened.lastError)
        try reopened.applyPublic([flag.key: .bool(true)])
        XCTAssertTrue(reopened.bool(flag.key))
    }

    func testSCF02ShapeInvalidLegacySecretsKeepRawValuesAcrossFailedRepairRetry() throws {
        let url = try self.storageURL()
        let secrets = SettingsTestSecrets()
        let shape = ClientSettingShape.object(["allowed": .string], required: [])
        let a = ClientSettingDefinition(key: "a", title: "A", section: "Follow-up", defaultValue: .object([:]), isSecret: true, valueShape: shape)
        let b = ClientSettingDefinition(key: "b", title: "B", section: "Follow-up", defaultValue: .object([:]), isSecret: true, valueShape: shape)
        let rawA: ClientSettingValue = .object(["obsolete": .string("A-LEGACY-FIXTURE")])
        let rawB: ClientSettingValue = .object(["obsolete": .string("B-LEGACY-FIXTURE")])
        let original = try JSONEncoder().encode([a.key: rawA, b.key: rawB])
        try original.write(to: url)
        let store = try ClientSettings(storageURL: url, secretStore: secrets)
        // B is staged first: its raw copy succeeds, then A's requested write fails.
        XCTAssertThrowsError(try store.register([b, a]))
        let repaired: ClientSettingValue = .object(["allowed": .string("REPAIRED-A-FIXTURE")])
        secrets.failWriteKey.update { $0 = a.key }
        XCTAssertThrowsError(try store.set(repaired, for: a.key))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertNil(try secrets.data(for: a.key))
        XCTAssertEqual(try self.rawSecret(b.key, in: secrets), rawB)
        XCTAssertTrue(store.readSnapshot().storedKeys.contains(b.key), "The successful copy survives failure of the next write")
        XCTAssertFalse(store.readSnapshot().storedKeys.contains(a.key))
        secrets.failWriteKey.update { $0 = nil }
        XCTAssertThrowsError(try store.set(repaired, for: a.key), "B's raw shape error remains, but A must make progress")
        XCTAssertEqual(store.value(a.key), repaired)
        XCTAssertNil(store.value(b.key))
        XCTAssertTrue(store.readSnapshot().storedKeys.contains(b.key), "Matching-duplicate cleanup preserves physical presence")
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(try self.rawSecret(b.key, in: secrets), rawB)
        let json = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(json.contains("A-LEGACY-FIXTURE"))
        XCTAssertFalse(json.contains("B-LEGACY-FIXTURE"))
        XCTAssertFalse(String(decoding: try store.exportJSON(), as: UTF8.self).contains("LEGACY-FIXTURE"))
        try store.reset(b.key)
        XCTAssertNil(try secrets.data(for: b.key))
        XCTAssertEqual(store.value(a.key), repaired)
        XCTAssertNil(store.lastError)
        let reopened = try ClientSettings(storageURL: url, secretStore: secrets)
        try reopened.register([b, a])
        XCTAssertEqual(reopened.value(a.key), repaired)
        XCTAssertTrue(reopened.readSnapshot().storedKeys.contains(a.key))
        XCTAssertFalse(reopened.readSnapshot().storedKeys.contains(b.key))
    }

    func testSCR01QuarantinePresenceSurvivesPublicBatchesAndUnreadableBackend() throws {
        for raw in [ClientSettingValue.bool(false), .null] {
            let url = try self.storageURL()
            let secrets = SettingsTestSecrets()
            let a = ClientSettingDefinition(key: "scr.a", title: "A", section: "Recovery", defaultValue: .string(""), isSecret: true)
            let b = ClientSettingDefinition(key: "scr.b", title: "B", section: "Recovery", defaultValue: .string(""), isSecret: true)
            let flag = self.definition("scr.flag", .bool(false))
            try JSONEncoder().encode([a.key: raw, b.key: raw]).write(to: url)
            let store = try ClientSettings(storageURL: url, secretStore: secrets)
            XCTAssertThrowsError(try store.register([a, b, flag]))
            XCTAssertThrowsError(try store.reset(a.key))
            XCTAssertFalse(store.readSnapshot().storedKeys.contains(a.key))
            XCTAssertEqual(store.value(a.key), .string(""))
            XCTAssertTrue(store.readSnapshot().storedKeys.contains(b.key))
            XCTAssertNil(store.value(b.key))
            let originalRaw = try XCTUnwrap(try secrets.data(for: b.key))
            XCTAssertEqual(try ClientSettingValue.decodeJSON(originalRaw), raw)
            var reads = secrets.readCount.value
            var writes = secrets.writeCount.value
            try store.applyPublic([flag.key: .bool(true)])
            XCTAssertEqual(secrets.readCount.value, reads)
            XCTAssertEqual(secrets.writeCount.value, writes)
            XCTAssertTrue(store.readSnapshot().storedKeys.contains(b.key))
            XCTAssertNil(store.value(b.key))
            XCTAssertNil(store.snapshot()[b.key])
            XCTAssertFalse(String(decoding: try store.exportJSON(), as: UTF8.self).contains(b.key))

            secrets.failReads.update { $0 = true }
            XCTAssertThrowsError(try store.reload())
            XCTAssertTrue(store.readSnapshot().storedKeys.contains(b.key), "Unreadability cannot erase known presence")
            XCTAssertNil(store.value(b.key))
            XCTAssertNil(store.value(a.key), "An unreadable backend must not supply an absence default")
            reads = secrets.readCount.value
            writes = secrets.writeCount.value
            try store.applyPublic([flag.key: .bool(false)])
            XCTAssertEqual(secrets.readCount.value, reads)
            XCTAssertEqual(secrets.writeCount.value, writes)
            XCTAssertTrue(store.readSnapshot().storedKeys.contains(b.key))
            XCTAssertNil(store.value(b.key))
            XCTAssertNil(store.value(a.key))
            secrets.failReads.update { $0 = false }
            XCTAssertEqual(try secrets.data(for: b.key), originalRaw)
            try store.set(.string(""), for: b.key)
            XCTAssertEqual(store.value(b.key), .string(""))
            XCTAssertTrue(store.readSnapshot().storedKeys.contains(b.key), "Explicit default is a stored override")
            try store.reset(b.key)
            XCTAssertFalse(store.readSnapshot().storedKeys.contains(b.key))
            XCTAssertEqual(store.value(b.key), .string(""))
            XCTAssertNil(try secrets.data(for: b.key))
        }
    }

    func testSCR01RecoveryPreservesCommittedPresenceBeforeAndAfterRename() throws {
        for raw in [ClientSettingValue.bool(false), .null] {
            for beforeRename in [true, false] {
                let url = try self.storageURL()
                let secrets = SettingsTestSecrets()
                let fail = SettingsTestBox(false)
                let a = ClientSettingDefinition(key: "scr.a", title: "A", section: "Recovery", defaultValue: .string(""), isSecret: true)
                let b = ClientSettingDefinition(key: "scr.b", title: "B", section: "Recovery", defaultValue: .string(""), isSecret: true)
                let flag = self.definition("scr.flag", .bool(false))
                let definitions = [a, b, flag]
                let original = try JSONEncoder().encode([a.key: raw, b.key: raw, "future": .integer(17)])
                try original.write(to: url)
                let hooks = ClientSettingsFileHooks(beforeFileReplace: {
                    if beforeRename && fail.value { throw NSError(domain: NSPOSIXErrorDomain, code: 5) }
                })
                let store = try ClientSettings(storageURL: url, secretStore: secrets, afterFileReplace: {
                    if !beforeRename && fail.value { throw NSError(domain: NSPOSIXErrorDomain, code: 5) }
                }, fileHooks: hooks)
                XCTAssertThrowsError(try store.register(definitions))
                fail.update { $0 = true }
                XCTAssertThrowsError(try store.set(.string("COMMITTED-A-FIXTURE"), for: a.key)) { error in
                    XCTAssertEqual(error as? ClientSettingsError, .storageFailure(operation: beforeRename ? "replace" : "sync directory", code: 5))
                }
                XCTAssertEqual(store.value(a.key), .string("COMMITTED-A-FIXTURE"))
                XCTAssertTrue(store.readSnapshot().storedKeys.contains(a.key))
                XCTAssertTrue(store.readSnapshot().storedKeys.contains(b.key))
                XCTAssertNil(store.value(b.key))
                XCTAssertEqual(try self.rawSecret(b.key, in: secrets), raw)
                if beforeRename {
                    XCTAssertEqual(try Data(contentsOf: url), original)
                } else {
                    guard case let .object(values) = try self.document(url)["values"] else { return XCTFail("Missing values") }
                    XCTAssertEqual(values, ["future": .integer(17)])
                }
                fail.update { $0 = false }
                let reads = secrets.readCount.value
                let writes = secrets.writeCount.value
                if beforeRename {
                    XCTAssertThrowsError(try store.applyPublic([flag.key: .bool(true)]), "The original plaintext still requires native cleanup")
                } else {
                    try store.applyPublic([flag.key: .bool(true)])
                }
                XCTAssertEqual(secrets.readCount.value, reads)
                XCTAssertEqual(secrets.writeCount.value, writes)
                XCTAssertTrue(store.readSnapshot().storedKeys.contains(b.key))
                XCTAssertNil(store.value(b.key))
                let reopened = try ClientSettings(storageURL: url, secretStore: secrets)
                XCTAssertThrowsError(try reopened.register(definitions))
                XCTAssertEqual(reopened.value(a.key), .string("COMMITTED-A-FIXTURE"))
                XCTAssertTrue(reopened.readSnapshot().storedKeys.contains(a.key))
                XCTAssertTrue(reopened.readSnapshot().storedKeys.contains(b.key))
                XCTAssertNil(reopened.value(b.key))
                try reopened.reset(b.key)
                XCTAssertTrue(reopened.readSnapshot().storedKeys.contains(a.key))
                XCTAssertFalse(reopened.readSnapshot().storedKeys.contains(b.key))
                XCTAssertNil(try secrets.data(for: b.key))
            }
        }
    }

    func testSCR01PartialAliasWriteRetainsConfirmedPresenceWhenReadsBecomeUnavailable() throws {
        let url = try self.storageURL()
        let secrets = SettingsTestSecrets()
        let a = ClientSettingDefinition(key: "a.new", title: "A", section: "Recovery", defaultValue: .bool(false), isSecret: true)
        let b = ClientSettingDefinition(key: "b.new", title: "B", section: "Recovery", defaultValue: .bool(false), isSecret: true)
        let flag = self.definition("scr.flag", .bool(false))
        try JSONEncoder().encode(["a.old": ClientSettingValue.bool(true), "b.old": .bool(true)]).write(to: url)
        let store = try ClientSettings(storageURL: url, secretStore: secrets)
        try store.register([self.definition("a.old", .bool(false)), self.definition("b.old", .bool(false)), a, b, flag])
        secrets.failWrites.update { $0 = true }
        XCTAssertThrowsError(try store.migrateKey(from: "a.old", to: a.key))
        XCTAssertThrowsError(try store.migrateKey(from: "b.old", to: b.key))
        let original = try Data(contentsOf: url)
        secrets.failWrites.update { $0 = false }
        secrets.failWriteKey.update { $0 = b.key }
        secrets.failReadsAfterWriteKey.update { $0 = a.key }
        XCTAssertThrowsError(try store.migrateKey(from: "a.old", to: a.key))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(store.readSnapshot().storedKeys.contains(a.key), "A's acknowledged write is known even when recovery reads fail")
        XCTAssertFalse(store.readSnapshot().storedKeys.contains(b.key))
        XCTAssertNil(store.value(a.key))
        XCTAssertNil(store.value(b.key), "B is unknown/unavailable, not a confirmed absence default")
        let reads = secrets.readCount.value
        let writes = secrets.writeCount.value
        XCTAssertThrowsError(try store.applyPublic([flag.key: .bool(true)]))
        XCTAssertEqual(secrets.readCount.value, reads)
        XCTAssertEqual(secrets.writeCount.value, writes)
        XCTAssertTrue(store.readSnapshot().storedKeys.contains(a.key))
        XCTAssertNil(store.value(a.key))
        secrets.failReads.update { $0 = false }
        secrets.failReadsAfterWriteKey.update { $0 = nil }
        secrets.failWriteKey.update { $0 = nil }
        XCTAssertEqual(try self.rawSecret(a.key, in: secrets), .bool(true))
        XCTAssertNil(try secrets.data(for: b.key))
        try store.migrateKey(from: "b.old", to: b.key)
        XCTAssertTrue(store.bool(a.key))
        XCTAssertTrue(store.bool(b.key))
        XCTAssertTrue(store.readSnapshot().storedKeys.contains(a.key))
        XCTAssertTrue(store.readSnapshot().storedKeys.contains(b.key))
    }

    #if !canImport(Security)
    func testNonAppleSecretBackendExplicitlyFailsButNormalSettingsPersist() throws {
        let backend = ClientSecrets.systemStore()
        XCTAssertThrowsError(try backend.set(Data("fixture".utf8), for: "fixture.secret")) { error in
            XCTAssertEqual(error as? ClientSettingsError, .secretStorageUnavailable)
        }
        let url = try self.storageURL()
        let store = try ClientSettings(storageURL: url)
        let definition = self.definition("fixture.normal", .bool(false))
        let secret = ClientSettingDefinition(key: "fixture.secret", title: "Secret", section: "Fixture", defaultValue: .string(""), isSecret: true)
        try store.register([definition, secret])
        XCTAssertThrowsError(try store.set(.string("must-not-persist"), for: secret.key))
        try store.set(.bool(true), for: definition.key)
        let reopened = try ClientSettings(storageURL: url)
        try reopened.register([definition])
        XCTAssertTrue(reopened.bool(definition.key))
    }
    #endif
}
