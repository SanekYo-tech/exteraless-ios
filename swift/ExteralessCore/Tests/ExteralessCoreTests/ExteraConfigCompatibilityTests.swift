import Foundation
import XCTest
@testable import ExteralessCore

private final class ExteraTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func update(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}

private final class ExteraTestSecrets: ClientSecretStore, @unchecked Sendable {
    let values = ExteraTestBox<[String: Data]>([:])
    let reads = ExteraTestBox(0)
    let writes = ExteraTestBox(0)
    func data(for key: String) throws -> Data? { reads.update { $0 += 1 }; return values.value[key] }
    func set(_ data: Data?, for key: String) throws { writes.update { $0 += 1 }; values.update { $0[key] = data } }
}

private actor ExteraTestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { opened = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
}

final class ExteraConfigCompatibilityTests: XCTestCase {
    private func storage() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("extera-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("client-settings.json")
    }

    func testOriginalGlobalDefaultsAndClosedNamespace() throws {
        let settings = try ClientSettings(storageURL: storage())
        try settings.register(ExteraConfigCompatibility.definitions)
        let expected: [String: ClientSettingValue] = [
            "translationFormality": .integer(0), "useYandexMaps": .bool(false), "tabIcons": .integer(1),
            "tabCounter": .bool(true), "newSliderStyle": .bool(true), "newSwitchStyle": .bool(true),
            "springAnimations": .bool(true), "forceBlur": .bool(false), "eventType": .integer(0),
            "unlimitedRecentStickers": .bool(false), "quickTransitionForChannels": .bool(true),
            "quickTransitionForTopics": .bool(true), "showClearButton": .bool(true), "showGenerateButton": .bool(true),
            "recognitionLanguage": .string("none"), "postprocessingWithAi": .bool(false),
            "useGoogleAnalytics": .bool(false), "enableAdBlock": .bool(true), "updateScheduleTimestamp": .integer(0),
            "sdkUpdateScheduleTimestamp": .integer(0), "pluginsPySdkAutoUpdate": .bool(true), "pluginsPySdkBetaVersions": .bool(false)
        ]
        XCTAssertEqual(ExteraConfigCompatibility.definitions.count, 22)
        XCTAssertEqual(ExteraConfigCompatibility.keys.count, 22)
        XCTAssertTrue(ExteraConfigCompatibility.definitions.allSatisfy { $0.section == "Compatibility state" && !$0.isSecret })
        for (key, value) in expected { XCTAssertEqual(settings.value(ExteraConfigCompatibility.prefix + key), value, key) }
        XCTAssertThrowsError(try ExteraConfigCompatibility.applyPublicJSON("{\"compat.exteraconfig.notDeclared\":true}", to: settings))
        XCTAssertNil(settings.value("compat.exteraconfig.notDeclared"))
    }

    func testDifferentReadersShareGlobalPersistenceAndExactInt64() throws {
        let url = try storage()
        let first = try ClientSettings(storageURL: url)
        let second = try ClientSettings(storageURL: url)
        try first.register(ExteraConfigCompatibility.definitions)
        try second.register(ExteraConfigCompatibility.definitions)
        try ExteraConfigCompatibility.applyPublicJSON("{\"compat.exteraconfig.tabIcons\":2,\"compat.exteraconfig.tabCounter\":false,\"compat.exteraconfig.updateScheduleTimestamp\":9007199254740993,\"compat.exteraconfig.recognitionLanguage\":\"雪\\u0000π\"}", to: first)
        try second.reload()
        XCTAssertEqual(second.value("compat.exteraconfig.tabIcons"), .integer(2))
        XCTAssertEqual(second.value("compat.exteraconfig.tabCounter"), .bool(false))
        XCTAssertEqual(second.value("compat.exteraconfig.updateScheduleTimestamp"), .integer(9_007_199_254_740_993))
        XCTAssertEqual(second.value("compat.exteraconfig.recognitionLanguage"), .string("雪\u{0}π"))
        let third = try ClientSettings(storageURL: url)
        try third.register(ExteraConfigCompatibility.definitions)
        XCTAssertEqual(third.snapshot(), second.snapshot())
    }

    func testTypedEnumsBoolIntegerBoundsAndRawJSON() throws {
        let settings = try ClientSettings(storageURL: storage())
        try settings.register(ExteraConfigCompatibility.definitions)
        for json in ["{\"compat.exteraconfig.tabIcons\":true}", "{\"compat.exteraconfig.tabIcons\":3}",
                     "{\"compat.exteraconfig.tabCounter\":1}", "{\"compat.exteraconfig.eventType\":2147483648}",
                     "{\"compat.exteraconfig.eventType\":1,\"compat.exteraconfig.eventType\":2}",
                     "{\"compat.exteraconfig.updateScheduleTimestamp\":9223372036854775808}",
                     "{\"compat.exteraconfig.eventType\":NaN}"] {
            XCTAssertThrowsError(try ExteraConfigCompatibility.applyPublicJSON(json, to: settings), json)
        }
        XCTAssertThrowsError(try ExteraConfigCompatibility.validatePublicValue(.string(String(repeating: "x", count: 65_537)), for: "compat.exteraconfig.recognitionLanguage"))
        XCTAssertEqual(settings.value("compat.exteraconfig.tabCounter"), .bool(true))
        XCTAssertEqual(settings.value("compat.exteraconfig.tabIcons"), .integer(1))
    }

    func testAtomicSnowBatchRollsBackBothKeys() throws {
        let url = try storage()
        let settings = try ClientSettings(storageURL: url)
        let definitions = AppearanceFeatures.definitions.filter { ["appearance.actionBarDecoration", "appearance.chatDecoration"].contains($0.key) }
        XCTAssertEqual(definitions.count, 2)
        try settings.register(definitions)
        try ExteraConfigCompatibility.applyPublicJSON("{\"appearance.actionBarDecoration\":0,\"appearance.chatDecoration\":0}", to: settings)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try ExteraConfigCompatibility.applyPublicJSON("{\"appearance.actionBarDecoration\":1,\"appearance.chatDecoration\":2}", to: settings))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(settings.integer("appearance.actionBarDecoration"), 0)
        XCTAssertEqual(settings.integer("appearance.chatDecoration"), 0)
        try ExteraConfigCompatibility.applyPublicJSON("{\"appearance.actionBarDecoration\":1,\"appearance.chatDecoration\":1}", to: settings)
        let reopened = try ClientSettings(storageURL: url)
        try reopened.register(definitions)
        XCTAssertEqual(reopened.integer("appearance.actionBarDecoration"), 1)
        XCTAssertEqual(reopened.integer("appearance.chatDecoration"), 1)
    }

    func testSecretAliasesAndClosedAIMetadataCannotRidePublicBatch() throws {
        let secret = ExteraTestSecrets()
        let settings = try ClientSettings(storageURL: storage(), secretStore: secret)
        try settings.register([
            .init(key: "legacyCredential", title: "Legacy", section: "Fixture", defaultValue: .string("")),
            .init(key: "ai.privateCredential", title: "Private", section: "Fixture", defaultValue: .string(""), isSecret: true),
            .init(key: "fixture.public", title: "Public", section: "Fixture", defaultValue: .bool(false)),
            AIFeatures.servicesDefinition
        ])
        try settings.set(.string("credential-destination-envelope"), for: "legacyCredential")
        try settings.migrateKey(from: "legacyCredential", to: "ai.privateCredential")
        let reads = secret.reads.value, writes = secret.writes.value, bytes = secret.values.value
        for key in ["legacyCredential", "ai.privateCredential"] {
            XCTAssertThrowsError(try ExteraConfigCompatibility.applyPublicJSON("{\"fixture.public\":true,\"\(key)\":\"bad\"}", to: settings))
            XCTAssertThrowsError(try ExteraConfigCompatibility.publicMetadata(for: key, in: settings))
        }
        XCTAssertThrowsError(try ExteraConfigCompatibility.applyPublicJSON("{\"fixture.public\":true,\"ai.services\":[{\"id\":\"a\",\"name\":\"A\",\"url\":\"https://example.invalid\",\"model\":\"m\",\"reasoningEffort\":0,\"wireProtocol\":\"openAI\",\"key\":\"credential\"}]}", to: settings))
        XCTAssertEqual(settings.value("fixture.public"), .bool(false))
        XCTAssertEqual(secret.values.value, bytes)
        XCTAssertEqual(secret.reads.value, reads)
        XCTAssertEqual(secret.writes.value, writes)
    }

    func testMetadataIsRegisteredNativeDefaultAndPreservesLiteralMarkers() throws {
        let settings = try ClientSettings(storageURL: storage())
        XCTAssertEqual(try ExteraConfigCompatibility.publicMetadata(for: "compat.exteraconfig.tabIcons", in: settings), .null)
        try settings.register(ExteraConfigCompatibility.definitions)
        guard case let .object(metadata) = try ExteraConfigCompatibility.publicMetadata(for: "compat.exteraconfig.tabIcons", in: settings) else { return XCTFail("Missing metadata") }
        XCTAssertEqual(metadata["default"], .integer(1))
        XCTAssertEqual(metadata["type"], .string("int"))
        let marker: ClientSettingValue = .object(["__handle__": .integer(19), "__bytes__": .string("literal")])
        try settings.register([.init(key: "fixture.marker", title: "Marker", section: "Fixture", defaultValue: marker)])
        let value = try ExteraConfigCompatibility.publicMetadata(for: "fixture.marker", in: settings)
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        guard case let .object(decoded) = try ClientSettingValue.decodeJSON(json) else { return XCTFail("Metadata JSON") }
        XCTAssertEqual(decoded["default"], marker)
    }

    func testManagerCommandsAreFIFOAndAdmissionDoesNotWaitForEffect() async throws {
        let gate = ExteraTestGate()
        let trace = ExteraTestBox<[String]>([])
        let entered = expectation(description: "first native effect entered")
        let finished = expectation(description: "two serial effects"); finished.expectedFulfillmentCount = 2
        let queue = ExteraConfigCommandQueue<String>(apply: { _, mutation in
            trace.update { $0.append("start:" + mutation.field) }
            if mutation.field == "engineEnabled" { entered.fulfill(); await gate.wait() }
            trace.update { $0.append("end:" + mutation.field) }
            finished.fulfill()
        }, failed: { _, _, _ in XCTFail("Unexpected command failure") })
        let first = try queue.enqueue(owner: "owner", mutation: .engine(false))
        let second = try queue.enqueue(owner: "owner", mutation: .safeMode(true))
        XCTAssertNotEqual(first, second)
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(trace.value, ["start:engineEnabled"])
        await gate.open()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(trace.value, ["start:engineEnabled", "end:engineEnabled", "start:safeMode", "end:safeMode"])
    }

    func testSelfDisableRetiresPendingCallerButCompletesCurrentEffect() async throws {
        let callerReturned = ExteraTestGate()
        let state = ExteraTestBox(true)
        let entered = expectation(description: "self-disable waiting asynchronously")
        let completed = expectation(description: "self-disable finished")
        let cancelled = expectation(description: "old queued owner retired")
        let queue = ExteraConfigCommandQueue<String>(maximumPending: 2, maximumPerOwner: 2, apply: { _, mutation in
            guard case .engine(false) = mutation else { return XCTFail("Retired request resurrected execution") }
            entered.fulfill()
            await callerReturned.wait()
            state.update { $0 = false }
            completed.fulfill()
        }, failed: { _, _, error in
            guard case .callerRetired? = error as? ExteraConfigCommandError else { return XCTFail("Wrong retirement error") }
            cancelled.fulfill()
        })
        _ = try queue.enqueue(owner: "retiring-epoch", mutation: .engine(false))
        _ = try queue.enqueue(owner: "retiring-epoch", mutation: .engine(true))
        XCTAssertThrowsError(try queue.enqueue(owner: "retiring-epoch", mutation: .safeMode(false)))
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(state.value, "enqueue must not wait for C caller/Host quiescence")
        queue.retire { $0 == "retiring-epoch" }
        await fulfillment(of: [cancelled], timeout: 3)
        await callerReturned.open()
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertFalse(state.value)
    }
}
