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
