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
    let failWrites = SettingsTestBox(false)

    func data(for key: String) throws -> Data? { self.values.value[key] }

    func set(_ data: Data?, for key: String) throws {
        if self.failWrites.value { throw SettingsTestSecretFailure() }
        self.values.update { $0[key] = data }
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
        XCTAssertEqual(second.definitions(), [])
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
        XCTAssertEqual(store.string(definition.key), "previous")
        try store.set(.string("replacement"), for: definition.key)
        XCTAssertEqual(store.string(definition.key), "replacement")
        try secrets.set(corrupt, for: definition.key)
        try store.reset(definition.key)
        XCTAssertNil(try secrets.data(for: definition.key))
        XCTAssertEqual(store.string(definition.key), "")
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
