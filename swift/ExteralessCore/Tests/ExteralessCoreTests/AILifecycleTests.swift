import Foundation
import XCTest
@testable import ExteralessCore

final class AILifecycleTests: XCTestCase {
    func testExplicitAndroidImportMigratesHashWithoutExportingKeys() throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        XCTAssertEqual(AISettings.javaServiceHash(url: "a", model: "b", key: "c"), 96354)
        let hash = AISettings.javaServiceHash(url: "https://fixture.invalid/v1", model: "second", key: "fixture-two")
        let payload: [String: Any] = ["selectedService": Int(hash), "services": [
            ["url": "https://fixture.invalid/v1", "model": "first", "key": "fixture-one"],
            ["url": "https://fixture.invalid/v1", "model": "second", "key": "fixture-two", "reasoningEnabled": true]
        ]]
        try fixture.settings.importAndroidServices(JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(fixture.settings.selectedService.model, "second")
        XCTAssertEqual(fixture.settings.selectedService.reasoningEffort, 2)
        XCTAssertEqual(fixture.settings.apiKey(for: fixture.settings.selectedService), "fixture-two")
        XCTAssertFalse(try String(contentsOf: fixture.url, encoding: .utf8).contains("fixture-two"))
        XCTAssertFalse(String(decoding: try fixture.settings.store.exportJSON(), as: UTF8.self).contains("fixture-two"))
    }

    func testAICF02AndroidImportRemovalAndRollbackKeepOverridePresence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AICF02-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func fixture(_ name: String) throws -> (settings: AISettings, secrets: AICF02SecretStore, url: URL) {
            let secrets = AICF02SecretStore()
            let url = root.appendingPathComponent(name).appendingPathComponent("settings.json")
            let settings = AISettings(store: try ClientSettings(storageURL: url, secretStore: secrets))
            try settings.register()
            return (settings, secrets, url)
        }
        func record(_ service: AIService, key: String? = nil) -> [String: Any] {
            var result: [String: Any] = ["id": service.id, "name": service.name, "url": service.url, "model": service.model]
            if let key { result["key"] = key }
            return result
        }

        // Missing, null and empty imported keys must remove absent, explicit-empty
        // and bound prior items, so add-only Cloud restore can subsequently insert.
        for keyVariant in 0 ..< 3 {
            let (settings, secrets, _) = try fixture("remove-\(keyVariant)")
            for prior in 0 ..< 3 {
                let service = AIService(id: "remove-\(prior)", name: "Fixture", url: "https://fixture.invalid/v1", model: "fixture-model")
                try settings.save(service: service, credential: prior == 2 ? .replace("fixture-prior-key") : .unchanged)
                if prior == 1 {
                    try settings.store.set(.string(""), for: service.keySetting)
                    XCTAssertNotNil(try secrets.data(for: service.keySetting), "SC-05 explicit empty remains an override")
                    XCTAssertTrue(settings.store.readSnapshot().storedKeys.contains(service.keySetting))
                }
                var imported = record(service)
                if keyVariant == 1 { imported["key"] = NSNull() }
                if keyVariant == 2 { imported["key"] = "" }
                try settings.importAndroidServices(JSONSerialization.data(withJSONObject: [imported]))
                XCTAssertNil(try secrets.data(for: service.keySetting))
                XCTAssertFalse(settings.store.readSnapshot().storedKeys.contains(service.keySetting))
                let entry = try CloudAICredentialBridge.importedAndroid("fixture-cloud-restored", id: .assistant(serviceId: service.id), metadata: settings.store.readSnapshot().values)
                switch try secrets.insertIfAbsent(entry) {
                case .inserted: break
                case .alreadyPresent: XCTFail("AICF-02: an empty import left a duplicate Keychain item")
                }
                try settings.store.reload()
                XCTAssertEqual(settings.apiKey(for: service), "fixture-cloud-restored")
                let bytes = try secrets.data(for: service.keySetting)
                switch try secrets.insertIfAbsent(entry) {
                case .inserted: XCTFail("Fixture add-only storage replaced an existing item")
                case .alreadyPresent: break
                }
                XCTAssertEqual(try secrets.data(for: service.keySetting), bytes)
            }
        }

        // Fault the second secret write. The first previously absent, empty or
        // bound item must recover exactly; the unattempted third key stays absent.
        let scenarios: [(prior: Int, services: Bool, selection: Bool)] = [(0, false, false), (1, true, false), (2, false, true), (2, true, true)]
        for (index, scenario) in scenarios.enumerated() {
            let (settings, secrets, url) = try fixture("rollback-\(index)")
            let services = ["first", "second", "third"].map { AIService(id: $0, name: "Fixture", url: "https://fixture.invalid/v1", model: "fixture-model") }
            for service in services { try settings.save(service: service, credential: .unchanged) }
            if scenario.prior == 1 { try settings.store.set(.string(""), for: services[0].keySetting) }
            if scenario.prior == 2 { try settings.save(service: services[0], credential: .replace("fixture-first-before")) }
            try settings.save(service: services[1], credential: .replace("fixture-second-before"))
            try settings.store.set(.string("fixture-unrelated"), for: "ai.googleCloudTranslateKey")
            if scenario.services {
                let records = index == 1 ? [] : [services[1]]
                let metadata = try JSONDecoder().decode(ClientSettingValue.self, from: JSONEncoder().encode(records))
                try settings.store.set(metadata, for: "ai.services")
            } else { try settings.store.reset("ai.services") }
            if scenario.selection { try settings.store.set(.string(index == 2 ? "" : services[1].id), for: "ai.selectedServiceId") }
            else { try settings.store.reset("ai.selectedServiceId") }
            let before = settings.store.readSnapshot()
            let backend = secrets.snapshot()
            let document = try Data(contentsOf: url)
            let imported = [record(services[0], key: "fixture-first-after"), record(services[1], key: "fixture-second-after"), record(services[2])]
            secrets.failSecondWrite()
            XCTAssertThrowsError(try settings.importAndroidServices(JSONSerialization.data(withJSONObject: imported))) {
                XCTAssertEqual($0 as? ClientSettingsError, .secretStorageFailure(status: -1))
            }
            XCTAssertEqual(Array(secrets.attemptedKeys.prefix(2)), [services[0].keySetting, services[1].keySetting])
            XCTAssertEqual(secrets.snapshot(), backend)
            XCTAssertEqual(settings.store.readSnapshot().storedKeys, before.storedKeys)
            XCTAssertEqual(settings.store.readSnapshot().values, before.values)
            XCTAssertEqual(try Data(contentsOf: url), document)
        }
    }

    func testPerChatLanguageIsRestoredBeforeFirstReadAndResetInheritsGlobal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AILifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let secrets = AIFixtureSecretStore()
        let first = AISettings(store: try ClientSettings(storageURL: url, secretStore: secrets))
        try first.register()
        try first.setInputLanguage("ja", chatId: "100")
        try first.setInputLanguage("fr", chatId: "200")
        let restored = AISettings(store: try ClientSettings(storageURL: url, secretStore: secrets))
        try restored.register()
        XCTAssertNil(restored.store.value("ai.translateInputLang_100"))
        XCTAssertEqual(try restored.inputLanguage(chatId: "100"), "ja")
        XCTAssertEqual(try restored.inputLanguage(chatId: "200"), "fr")
        try restored.store.set(.string("de"), for: "ai.translateInputLang")
        XCTAssertEqual(try restored.inputLanguage(chatId: "300"), "de")
        try restored.store.reset("ai.translateInputLang_100")
        XCTAssertEqual(try restored.inputLanguage(chatId: "100"), "de")
    }

    func testServicesRecoverAcrossRecreationAndSharedStorageReconfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIShared-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.json")
        let b = root.appendingPathComponent("group/b.json")
        let secrets = AIFixtureSecretStore()
        let serviceA = AIService(id: "fixture-a", url: "https://fixture.invalid/v1", model: "fixture-a")
        let serviceB = AIService(id: "fixture-b", url: "https://fixture.invalid/v1", model: "fixture-b")
        for (url, service, key) in [(a, serviceA, "fixture-key-a"), (b, serviceB, "fixture-key-b")] {
            let settings = AISettings(store: try ClientSettings(storageURL: url, secretStore: secrets))
            try settings.register()
            try settings.save(service: service, credential: .replace(key))
        }
        let store = try ClientSettings(storageURL: a, secretStore: secrets)
        let settings = AISettings(store: store)
        let recovery = AISettingsRecovery(settings: settings)
        try recovery.prepare(accountId: "1")
        XCTAssertEqual(settings.apiKey(for: settings.selectedService), "fixture-key-a")
        try store.configure(storageURL: b)
        try recovery.prepare(accountId: "2")
        XCTAssertEqual(settings.selectedService.id, "fixture-b")
        XCTAssertEqual(settings.apiKey(for: settings.selectedService), "fixture-key-b")
        XCTAssertNil(recovery.errorDescription)
        let exported = String(decoding: try store.exportJSON(), as: UTF8.self)
        XCTAssertFalse(exported.contains("fixture-key"))
    }

    func testSecureStoreFailureDoesNotPermanentlyPoisonRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIRetry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = AIRetrySecretStore()
        let settings = AISettings(store: try ClientSettings(storageURL: root.appendingPathComponent("settings.json"), secretStore: backend))
        let recovery = AISettingsRecovery(settings: settings)
        backend.failReads = true
        XCTAssertThrowsError(try recovery.prepare(accountId: "1"))
        XCTAssertNotNil(recovery.errorDescription)
        backend.failReads = false
        try recovery.prepare(accountId: "1")
        XCTAssertNil(recovery.errorDescription)
        try settings.save(service: .default, credential: .replace("fixture-only-key"))
        XCTAssertEqual(settings.apiKey(for: .default), "fixture-only-key")
    }
}

/// Shared raw storage for the real ClientSettings path and a Cloud add-only
/// fixture. Empty JSON strings count as present, matching SC-05/SecItemAdd.
private final class AICF02SecretStore: ClientSecretStore, CloudCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var attempted: [String] = []
    private var failAt: Int?

    var attemptedKeys: [String] { lock.lock(); defer { lock.unlock() }; return attempted }
    func snapshot() -> [String: Data] { lock.lock(); defer { lock.unlock() }; return values }
    func failSecondWrite() { lock.lock(); defer { lock.unlock() }; attempted = []; failAt = 2 }
    func data(for key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func set(_ data: Data?, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        attempted.append(key)
        if attempted.count == failAt {
            failAt = nil
            throw ClientSettingsError.secretStorageFailure(status: -1)
        }
        values[key] = data
    }
    func read(_ id: CloudCredentialID) throws -> String? {
        guard let bytes = try data(for: id.settingKey) else { return nil }
        guard case let .string(value) = try JSONDecoder().decode(ClientSettingValue.self, from: bytes) else { throw CloudError.invalidCredential }
        return value
    }
    func insertIfAbsent(_ entry: CloudCredentialEntry) throws -> CloudCredentialInsertResult {
        lock.lock(); defer { lock.unlock() }
        _ = try entry.validated()
        guard values[entry.id.settingKey] == nil else { return .alreadyPresent }
        values[entry.id.settingKey] = try entry.withValue { try JSONEncoder().encode(ClientSettingValue.string($0)) }
        return .inserted
    }
}

private final class AIRetrySecretStore: ClientSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var fails = false
    private var values: [String: Data] = [:]
    var failReads: Bool {
        get { lock.lock(); defer { lock.unlock() }; return fails }
        set { lock.lock(); defer { lock.unlock() }; fails = newValue }
    }
    func data(for key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if fails { throw ClientSettingsError.secretStorageUnavailable }
        return values[key]
    }
    func set(_ data: Data?, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = data
    }
}
