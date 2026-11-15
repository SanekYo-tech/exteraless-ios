import Foundation
import XCTest
@testable import ExteralessCore

final class AIManualTranslationTests: XCTestCase {
    func test2049thMarkerEvictsHiddenThenOldestAndSurvivesRecreation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIManualMarkers-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let secrets = AIFixtureSecretStore()
        let store = try ClientSettings(storageURL: url, secretStore: secrets)
        try AIManualTranslations.register(accountId: "1", store: store)
        var legacy: [String: AIManualTranslationState] = [:]
        for index in 0 ..< 2048 { legacy[key(index)] = .init(language: index == 12 ? "ja" : "fr", visible: index != 2047) }
        try store.set(.string(String(decoding: JSONEncoder().encode(legacy), as: UTF8.self)), for: "ai.manualTranslations.1")
        try AIManualTranslations.set(.init(language: "de"), accountId: "1", messageKey: key(0), store: store)
        try AIManualTranslations.set(.init(language: "it"), accountId: "1", messageKey: key(2048), store: store)
        XCTAssertEqual(try records(store).count, 2048)
        XCTAssertEqual(AIManualTranslations.state(accountId: "1", messageKey: key(2048), store: store), .init(language: "it"))
        XCTAssertNil(AIManualTranslations.state(accountId: "1", messageKey: key(2047), store: store))
        try AIManualTranslations.set(.init(language: "en"), accountId: "1", messageKey: key(2049), store: store)
        XCTAssertEqual(try records(store).count, 2048)
        XCTAssertNil(AIManualTranslations.state(accountId: "1", messageKey: key(1), store: store))
        XCTAssertEqual(AIManualTranslations.state(accountId: "1", messageKey: key(0), store: store)?.language, "de")
        XCTAssertEqual(AIManualTranslations.state(accountId: "1", messageKey: key(12), store: store)?.language, "ja")
        let restored = try ClientSettings(storageURL: url, secretStore: secrets)
        try AIManualTranslations.register(accountId: "1", store: restored)
        XCTAssertEqual(AIManualTranslations.state(accountId: "1", messageKey: key(2049), store: restored), .init(language: "en"))
        XCTAssertEqual(try records(restored).count, 2048)
        XCTAssertFalse(String(decoding: try restored.exportJSON(), as: UTF8.self).contains("manualTranslations"))
    }

    func testHiddenNewestMarkerIsKeptOnInsertionAndRemovedBeforeVisibleMarkersLater() throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        let store = fixture.settings.store
        try AIManualTranslations.register(accountId: "1", store: store)
        let legacy = Dictionary(uniqueKeysWithValues: (0 ..< 2048).map { (key($0), AIManualTranslationState(language: "fr")) })
        try store.set(.string(String(decoding: JSONEncoder().encode(legacy), as: UTF8.self)), for: "ai.manualTranslations.1")
        try AIManualTranslations.set(.init(language: "de", visible: false), accountId: "1", messageKey: key(2048), store: store)
        XCTAssertEqual(AIManualTranslations.state(accountId: "1", messageKey: key(2048), store: store)?.visible, false)
        try AIManualTranslations.set(.init(language: "ja"), accountId: "1", messageKey: key(2049), store: store)
        XCTAssertNil(AIManualTranslations.state(accountId: "1", messageKey: key(2048), store: store))
        XCTAssertEqual(AIManualTranslations.state(accountId: "1", messageKey: key(1), store: store)?.language, "fr")
        XCTAssertEqual(try records(store).count, 2048)
        try AIManualTranslations.set(nil, accountId: "1", messageKey: key(2049), store: store)
        XCTAssertEqual(try records(store).count, 2047)
    }

    func testSequenceOverflowCompactsAndMalformedSecretIsPreserved() throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        let store = fixture.settings.store
        try AIManualTranslations.register(accountId: "1", store: store)
        try store.set(.string("{\"old\":{\"language\":\"fr\",\"visible\":true,\"sequence\":18446744073709551615}}"), for: "ai.manualTranslations.1")
        try AIManualTranslations.set(.init(language: "de"), accountId: "1", messageKey: "new", store: store)
        XCTAssertEqual(AIManualTranslations.state(accountId: "1", messageKey: "old", store: store)?.language, "fr")
        XCTAssertEqual(AIManualTranslations.state(accountId: "1", messageKey: "new", store: store)?.language, "de")
        try store.set(.string("malformed-fixture"), for: "ai.manualTranslations.1")
        XCTAssertThrowsError(try AIManualTranslations.set(.init(language: "ja"), accountId: "1", messageKey: "another", store: store))
        XCTAssertEqual(store.string("ai.manualTranslations.1"), "malformed-fixture")
    }

    private func key(_ index: Int) -> String { String(format: "fixture-%04d", index) }
    private func records(_ store: ClientSettings) throws -> [String: AIManualTranslationState] {
        try JSONDecoder().decode([String: AIManualTranslationState].self, from: Data(store.string("ai.manualTranslations.1").utf8))
    }
}
