import Foundation
import XCTest
@testable import ExteralessCore

private final class ResetFixtureBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { self.storage = value }
    var value: Value { self.lock.lock(); defer { self.lock.unlock() }; return self.storage }
    func update(_ body: (inout Value) -> Void) { self.lock.lock(); defer { self.lock.unlock() }; body(&self.storage) }
}

private final class ResetFixtureSecrets: ClientSecretStore, ClientAPISecureStorage, @unchecked Sendable {
    private let values = ResetFixtureBox<[String: Data]>([:])
    let failRemove = ResetFixtureBox<String?>(nil)
    let removeThenFail = ResetFixtureBox<String?>(nil)
    let failReads = ResetFixtureBox(false)
    let reads = ResetFixtureBox(0)
    let writes = ResetFixtureBox<[String]>([])
    func data(for key: String) throws -> Data? {
        self.reads.update { $0 += 1 }
        if self.failReads.value { throw ClientSettingsError.secretStorageFailure(status: -1) }
        return self.values.value[key]
    }
    func set(_ data: Data?, for key: String) throws {
        self.writes.update { $0.append(key) }
        if data == nil && self.failRemove.value == key { throw ClientSettingsError.secretStorageFailure(status: -1) }
        self.values.update { $0[key] = data }
        if data == nil && self.removeThenFail.value == key { throw ClientSettingsError.secretStorageFailure(status: -1) }
    }
    func read(_ key: String) throws -> Data? { try self.data(for: key) }
    func write(_ data: Data?, key: String) throws { try self.set(data, for: key) }
    func insertIfAbsent(_ data: Data, key: String) throws -> Data {
        var result = data
        self.values.update { values in
            if let existing = values[key] { result = existing }
            else { values[key] = data }
        }
        return result
    }
}

final class CoreSettingsResetTests: XCTestCase {
    private func url() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-reset-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("client-settings.json")
    }

    private func definition(_ key: String, _ value: ClientSettingValue, _ symbols: [String], secret: Bool = false) -> ClientSettingDefinition {
        return ClientSettingDefinition(key: key, title: key, section: "Reset fixture", defaultValue: value, isSecret: secret, androidSymbols: symbols)
    }

    private func snapshot(_ definitions: [ClientSettingDefinition]) -> ClientSettingsSnapshot {
        return ClientSettingsSnapshot(definitions: definitions, values: Dictionary(uniqueKeysWithValues: definitions.map { ($0.key, $0.defaultValue) }), storedKeys: [])
    }

    func testOriginalScopesAndActualGeneralDefinitions() throws {
        XCTAssertEqual(CoreSettingsResetCatalog.fields(for: .general).count, 7)
        XCTAssertEqual(CoreSettingsResetCatalog.fields(for: .exteraless).count, 154)
        XCTAssertEqual(CoreSettingsResetCatalog.selectedExternalSymbols.count, 13)
        XCTAssertEqual(CoreSettingsResetCatalog.retainedOriginalMarkers, ["OELegacyDefaultsPinned", "OELegacyDefaultsGeneration"])
        XCTAssertEqual(CoreSettingsResetCatalog.retainedOriginalGeneration, 2)
        let definitions = PrivacyFeatures.definitions + ToolsFeatures.definitions
        let preview = try CoreSettingsResetPreview.resolve(scope: .general, snapshot: self.snapshot(definitions))
        XCTAssertEqual(preview.publicKeys, ["privacy.botPrivacyEnabled", "privacy.botPrivacyAlwaysAsk", "privacy.botPrivacyUserId",
                                             "privacy.contentCapture", "tools.downloadSpeedBoost", "tools.crashReports"])
        XCTAssertTrue(preview.credentialKeys.isEmpty)
        XCTAssertEqual(preview.unavailable.map(\.source.symbol), ["GeneralConfig.showNagramSettings"])
        XCTAssertFalse(CoreSettingsResetCatalog.fields(for: .exteraless).contains { $0.group == .clientAPI || $0.group == .cloud })
        XCTAssertEqual(CoreSettingsResetCatalog.fields(for: .allOriginal).filter { $0.group == .clientAPI }.map(\.preferenceKey).sorted(),
                       ["custom_api", "custom_app_hash", "custom_app_id"])
        let registered = definitions + AppearanceFeatures.definitions + ChatFeatures.definitions + AIFeatures.definitions
            + AINativeVisibilityPolicy.definitions + PlayerFeatures.definitions + PlayerFeatures.galleryDefinitions
            + FeedFeatures.definitions + PillFeatures.definitions
            + StickerFeatures.definitions + IdentityFeatures.definitions + PrivacyExtrasFeatures.definitions
        let selected = try CoreSettingsResetPreview.resolve(scope: .exteraless, snapshot: self.snapshot(registered))
        XCTAssertEqual(selected.keys.count, 148)
        XCTAssertEqual(Set(selected.unavailable.map(\.source.symbol)), ["GeneralConfig.showNagramSettings", "AppearanceConfig.centerTitle",
            "AppearanceConfig.iosChatHeader", "ChatsConfig.cameraType", "ChatsConfig.unmuteWithVolumeButtons", "IconPacksConfig.customNotificationIcon"])
        for key in ["chats.activePillsRaw", "chats.hiddenPillsRaw", "chats.lastActivePillId"] {
            XCTAssertTrue(selected.keys.contains(key), "Use the real ChatFeatures definitions, not the narrower SDK Config projection")
        }
        XCTAssertTrue(CoreSettingsResetCatalog.fields(for: .allOriginal).contains { $0.preferenceKey == "OEAppearanceTitleTextMigrated" })
        XCTAssertFalse(CoreSettingsResetCatalog.fields(for: .exteraless).contains { $0.preferenceKey == "OEAppearanceTitleTextMigrated" })
    }

    func testAllIncludesSourceCredentialsButPreservesAssistantPrivateAndCompatibilityState() throws {
        let definitions = AIFeatures.definitions + ClientAPIFeatures.definitions + ExteraConfigCompatibility.definitions
            + PrivacyExtrasFeatures.privateDefinitions + NewCloudFeatures.definitions + NewNetworkFeatures.definitions
        let all = try CoreSettingsResetPreview.resolve(scope: .allOriginal, snapshot: self.snapshot(definitions))
        XCTAssertTrue(all.credentialKeys.contains("ai.googleCloudTranslateKey"))
        XCTAssertTrue(all.credentialKeys.contains("ai.deepLTranslateKey"))
        XCTAssertTrue(all.credentialKeys.contains("clientAPI.customAppHash"))
        XCTAssertTrue(all.credentialKeys.contains("clientAPI.test.customAppHash"))
        XCTAssertTrue(all.credentialKeys.contains("network.customDoH"))
        XCTAssertTrue(all.publicKeys.isSuperset(of: ["network.dnsType", "network.useIPv6", "cloud.autoSync", "cloud.includeApiKeys"]))
        XCTAssertEqual(Set(all.unavailable.filter { $0.source.group == .glyph }.map(\.source.preferenceKey)).count, 5)
        XCTAssertTrue(all.publicKeys.contains("ai.showTranslate"), "keepPinned does not preserve its BOOL_KEYS values")
        for key in ["ai.services", "ai.roles", "ai.saveHistory", "ai.googleTranslateExperimentalKey", "ai.lingoApiKey", "ai.speechRate",
                    "privacy.accountHidden", "privacy.passcodeHash", "compat.exteraconfig.pluginsPySdkAutoUpdate"] {
            XCTAssertFalse(all.keys.contains(key), key)
        }
        let selected = try CoreSettingsResetPreview.resolve(scope: .exteraless, snapshot: self.snapshot(definitions))
        XCTAssertEqual(selected.keys, ["ai.translationProvider", "ai.translateToLang"])
        XCTAssertTrue(selected.credentialKeys.isEmpty)
    }

    func testOverlappingAliasesDeduplicateAndNamesAloneDoNotGrantResetScope() throws {
        let shared = self.definition("appearance.shared", .bool(false), ["NekoConfig.showSeconds", "OpenExteraConfig.relativeLastSeen"])
        let divider = self.definition("appearance.dividerStyle", .integer(1), ["AppearanceConfig.dividerStyle"])
        let unrelated = self.definition("native.unknown", .bool(false), ["GeneralHelper.resetAllSettings", "NekoConfig.notInPinnedSource", "Unrelated.GeneralConfig.contentCapture"])
        let marker = self.definition("OELegacyDefaultsPinned", .bool(true), ["NekoConfig.showSeconds"])
        let dynamic = self.definition("ai.translateInputLang_fixture", .string(""), ["Translator.setInputTranslateLangForChat"])
        let cameraTile = self.definition("chats.hideCameraTile", .bool(false), ["ChatsConfig.hideCameraTile"])
        let preview = try CoreSettingsResetPreview.resolve(scope: .allOriginal, snapshot: self.snapshot([shared, divider, unrelated, marker, dynamic, cameraTile]))
        XCTAssertEqual(preview.keys, [shared.key, divider.key, dynamic.key, cameraTile.key])
        XCTAssertEqual(preview.entries.filter { $0.key == shared.key }.count, 1)
        XCTAssertEqual(preview.entries.first(where: { $0.key == shared.key })?.sources.count, 2)
        XCTAssertTrue(preview.entries.first(where: { $0.key == divider.key })?.sources.contains { $0.symbol == "NaConfig.hideDividers" } == true)
        XCTAssertTrue(preview.unavailable.contains { $0.source.symbol == "NekoConfig.disableInstantCamera" })
        XCTAssertEqual(preview.entries.first(where: { $0.key == cameraTile.key })?.sources.map(\.symbol), ["ChatsConfig.hideCameraTile"])
        XCTAssertFalse(try CoreSettingsResetPreview.resolve(scope: .exteraless, snapshot: self.snapshot([dynamic])).keys.contains(dynamic.key))
        let emptyStore = try ClientSettings(storageURL: self.url(), secretStore: ResetFixtureSecrets())
        let provider = CoreSettingsResetProvider(settings: emptyStore)
        let authority = CoreSettingsResetAuthority()
        let plan = try provider.prepare(scope: .general, authority: authority)
        XCTAssertTrue(plan.preview.entries.isEmpty)
        XCTAssertFalse(plan.preview.unavailable.isEmpty)
        XCTAssertThrowsError(try provider.begin(plan, authority: authority)) { XCTAssertEqual($0 as? CoreSettingsResetError, .noNativeSettings) }
    }

    func testProviderResetsPublicScopeWithOneCommitAndObserverAndRemovesPresence() throws {
        let url = try self.url()
        let secrets = ResetFixtureSecrets()
        let writes = ResetFixtureBox(0)
        let store = try ClientSettings(storageURL: url, secretStore: secrets, afterFileReplace: { writes.update { $0 += 1 } })
        let a = self.definition("privacy.botPrivacyEnabled", .bool(false), ["GeneralConfig.botPrivacyEnabled"])
        let b = self.definition("tools.downloadSpeedBoost", .integer(0), ["GeneralConfig.downloadSpeedBoost", "NekoConfig.enhancedFileLoader"])
        let unrelated = self.definition("native.unrelated", .integer(3), [])
        let credential = self.definition("ai.serviceKey.fixture", .string(""), ["Service.key"], secret: true)
        try store.register([a, b, unrelated, credential])
        try store.set(.bool(true), for: a.key)
        try store.set(.integer(2), for: b.key)
        try store.set(.integer(99), for: unrelated.key)
        try store.set(.string("UNRELATED-CREDENTIAL-FIXTURE"), for: credential.key)
        var root = try JSONDecoder().decode([String: ClientSettingValue].self, from: Data(contentsOf: url))
        guard case var .object(values) = root["values"] else { return XCTFail("Missing values") }
        values["future.unknown"] = .object(["keep": .bool(true)])
        root["values"] = .object(values)
        root["futureMetadata"] = .integer(17)
        try JSONEncoder().encode(root).write(to: url)
        let provider = CoreSettingsResetProvider(settings: store)
        let authority = CoreSettingsResetAuthority()
        let plan = try provider.prepare(scope: .general, authority: authority)
        let session = try provider.begin(plan, authority: authority)
        let events = ResetFixtureBox<[Set<String>]>([])
        let observation = store.observe { keys in events.update { $0.append(keys) } }
        defer { observation.cancel() }
        writes.update { $0 = 0 }
        let result = session.run()
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.confirmedKeys, [a.key, b.key])
        XCTAssertEqual(writes.value, 1)
        XCTAssertEqual(events.value, [Set([a.key, b.key])])
        XCTAssertFalse(store.readSnapshot().storedKeys.contains(a.key))
        XCTAssertFalse(store.readSnapshot().storedKeys.contains(b.key))
        XCTAssertEqual(store.integer(unrelated.key), 99)
        XCTAssertEqual(store.string(credential.key), "UNRELATED-CREDENTIAL-FIXTURE")
        let after = try JSONDecoder().decode([String: ClientSettingValue].self, from: Data(contentsOf: url))
        guard case let .object(persisted) = after["values"] else { return XCTFail("Missing values") }
        XCTAssertNil(persisted[a.key])
        XCTAssertNil(persisted[b.key])
        XCTAssertEqual(persisted["future.unknown"], values["future.unknown"])
        XCTAssertEqual(after["futureMetadata"], .integer(17))
        try store.register([self.definition(a.key, .bool(true), a.androidSymbols)])
        XCTAssertTrue(store.bool(a.key), "The reset follows a future default rather than retaining an explicit old default")
    }

    func testExternalCASConflictPreservesAllKeysAndUnrelatedChangesAreAllowed() throws {
        let url = try self.url()
        let a = self.definition("privacy.botPrivacyEnabled", .bool(false), ["GeneralConfig.botPrivacyEnabled"])
        let b = self.definition("tools.downloadSpeedBoost", .integer(0), ["GeneralConfig.downloadSpeedBoost"])
        let other = self.definition("native.other", .integer(0), [])
        let first = try ClientSettings(storageURL: url, secretStore: ResetFixtureSecrets())
        let second = try ClientSettings(storageURL: url, secretStore: ResetFixtureSecrets())
        for store in [first, second] { try store.register([a, b, other]) }
        try first.applyPublic([a.key: .bool(true), b.key: .integer(2)])
        let provider = CoreSettingsResetProvider(settings: first)
        let authority = CoreSettingsResetAuthority()
        let plan = try provider.prepare(scope: .general, authority: authority)
        try second.applyPublic([a.key: .bool(false)])
        let concurrent = try Data(contentsOf: url)
        let failed = try provider.begin(plan, authority: authority).run()
        XCTAssertEqual(failed.error, .settingsChanged)
        XCTAssertFalse(failed.isComplete)
        XCTAssertEqual(try Data(contentsOf: url), concurrent)
        XCTAssertEqual(first.integer(b.key), 2)
        let fresh = try provider.prepare(scope: .general, authority: authority)
        try second.applyPublic([other.key: .integer(7)])
        XCTAssertTrue(try provider.begin(fresh, authority: authority).run().isComplete)
        XCTAssertEqual(first.integer(other.key), 7)

        try first.applyPublic([a.key: .bool(true), b.key: .integer(2)])
        let last = try provider.prepare(scope: .general, authority: authority)
        let session = try provider.begin(last, authority: authority)
        try second.applyPublic([:], resetting: [a.key, b.key])
        XCTAssertEqual(session.run().error, .settingsChanged)
        XCTAssertEqual(session.run().error, .settingsChanged, "A rejected CAS cannot adopt someone else's reset and reuse the old confirmation")
    }

    func testContextInvalidationStopsBeforeWritesAndAfterAnAdmittedPublicBatch() throws {
        let url = try self.url()
        let secrets = ResetFixtureSecrets()
        let store = try ClientSettings(storageURL: url, secretStore: secrets)
        let field = self.definition("appearance.showSeconds", .bool(false), ["NekoConfig.showSeconds"])
        let credential = self.definition("ai.googleCloudTranslateKey", .string(""), ["googleCloudTranslateKey"], secret: true)
        try store.register([field, credential])
        try store.set(.bool(true), for: field.key)
        try store.set(.string("KEEP-CREDENTIAL"), for: credential.key)
        let provider = CoreSettingsResetProvider(settings: store)
        let parent = CoreSettingsResetAuthority()
        let page = parent.child()
        let plan = try provider.prepare(scope: .allOriginal, authority: page)
        let session = try provider.begin(plan, authority: page)
        let before = try Data(contentsOf: url)
        parent.invalidate()
        XCTAssertEqual(session.run().error, .contextChanged)
        XCTAssertEqual(try Data(contentsOf: url), before)
        let nextPage = CoreSettingsResetAuthority()
        let next = try provider.prepare(scope: .allOriginal, authority: nextPage)
        let operation = try provider.begin(next, authority: nextPage)
        let observation = store.observe { keys in if keys.contains(field.key) { nextPage.invalidate() } }
        defer { observation.cancel() }
        let result = operation.run()
        XCTAssertEqual(result.error, .contextChanged)
        XCTAssertEqual(result.confirmedKeys, [field.key], "An admitted batch that returned success is reported as completed even after context retirement")
        XCTAssertTrue(result.observedResetKeys.contains(field.key))
        XCTAssertEqual(store.string(credential.key), "KEEP-CREDENTIAL")
    }

    func testMixedCredentialFailureRetryKeepsPublicBatchSingleAndDoesNotLogSecrets() throws {
        let url = try self.url()
        let secrets = ResetFixtureSecrets()
        let writes = ResetFixtureBox(0)
        let store = try ClientSettings(storageURL: url, secretStore: secrets, afterFileReplace: { writes.update { $0 += 1 } })
        let field = self.definition("appearance.showSeconds", .bool(false), ["NekoConfig.showSeconds"])
        let credential = self.definition("ai.googleCloudTranslateKey", .string(""), ["googleCloudTranslateKey"], secret: true)
        let unrelated = self.definition("ai.serviceKey.fixture", .string(""), ["Service.key"], secret: true)
        try store.register([field, credential, unrelated])
        try store.set(.bool(true), for: field.key)
        try store.set(.string("RESET-CREDENTIAL-FIXTURE"), for: credential.key)
        try store.set(.string("PRESERVE-CREDENTIAL-FIXTURE"), for: unrelated.key)
        let provider = CoreSettingsResetProvider(settings: store)
        let authority = CoreSettingsResetAuthority()
        let plan = try provider.prepare(scope: .allOriginal, authority: authority)
        XCTAssertFalse(plan.description.contains("RESET-CREDENTIAL-FIXTURE"))
        XCTAssertFalse(plan.debugDescription.contains("RESET-CREDENTIAL-FIXTURE"))
        var description = ""
        dump(plan, to: &description)
        XCTAssertFalse(description.contains("RESET-CREDENTIAL-FIXTURE"))
        let session = try provider.begin(plan, authority: authority)
        dump(session, to: &description)
        XCTAssertFalse(description.contains("RESET-CREDENTIAL-FIXTURE"))
        secrets.failRemove.update { $0 = credential.key }
        writes.update { $0 = 0 }
        let failed = session.run()
        XCTAssertFalse(failed.isComplete)
        XCTAssertEqual(failed.confirmedKeys, [field.key])
        XCTAssertEqual(failed.remainingKeys, [credential.key])
        XCTAssertEqual(store.string(credential.key), "RESET-CREDENTIAL-FIXTURE")
        secrets.failRemove.update { $0 = nil }
        let complete = session.run()
        XCTAssertTrue(complete.isComplete)
        XCTAssertEqual(writes.value, 1, "Credential retry does not repeat the public reset batch")
        XCTAssertNil(try secrets.data(for: credential.key))
        XCTAssertEqual(store.string(unrelated.key), "PRESERVE-CREDENTIAL-FIXTURE")
    }

    func testCredentialEditAfterPreviewAndPublicEditAfterPartialFailureArePreserved() throws {
        let url = try self.url()
        let secrets = ResetFixtureSecrets()
        let store = try ClientSettings(storageURL: url, secretStore: secrets)
        let field = self.definition("appearance.showSeconds", .bool(false), ["NekoConfig.showSeconds"])
        let credential = self.definition("ai.googleCloudTranslateKey", .string(""), ["googleCloudTranslateKey"], secret: true)
        try store.register([field, credential])
        try store.set(.bool(true), for: field.key)
        try store.set(.string("OLD-FIXTURE"), for: credential.key)
        let provider = CoreSettingsResetProvider(settings: store)
        let authority = CoreSettingsResetAuthority()
        let before = try provider.prepare(scope: .allOriginal, authority: authority)
        try store.set(.string("NEW-FIXTURE"), for: credential.key)
        let changed = try provider.begin(before, authority: authority).run()
        XCTAssertEqual(changed.error, .settingsChanged)
        XCTAssertTrue(store.bool(field.key))
        XCTAssertEqual(store.string(credential.key), "NEW-FIXTURE")
        let fresh = try provider.prepare(scope: .allOriginal, authority: authority)
        let session = try provider.begin(fresh, authority: authority)
        secrets.failRemove.update { $0 = credential.key }
        XCTAssertFalse(session.run().isComplete)
        try store.set(.bool(true), for: field.key)
        secrets.failRemove.update { $0 = nil }
        XCTAssertEqual(session.run().error, .settingsChanged)
        XCTAssertTrue(store.bool(field.key))
        XCTAssertEqual(store.string(credential.key), "NEW-FIXTURE")
    }

    func testPostRenameFailureIsVisibleAndRetryConfirmsWithoutWritingDefaultOverrides() throws {
        let url = try self.url()
        let fail = ResetFixtureBox(false)
        let writes = ResetFixtureBox(0)
        let store = try ClientSettings(storageURL: url, secretStore: ResetFixtureSecrets(), afterFileReplace: {
            writes.update { $0 += 1 }
            if fail.value { throw NSError(domain: NSPOSIXErrorDomain, code: 5) }
        })
        let definition = self.definition("tools.downloadSpeedBoost", .integer(0), ["GeneralConfig.downloadSpeedBoost"])
        try store.register([definition])
        try store.set(.integer(2), for: definition.key)
        let provider = CoreSettingsResetProvider(settings: store)
        let authority = CoreSettingsResetAuthority()
        let session = try provider.begin(provider.prepare(scope: .general, authority: authority), authority: authority)
        writes.update { $0 = 0 }
        fail.update { $0 = true }
        let result = session.run()
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.observedResetKeys, [definition.key])
        XCTAssertTrue(result.confirmedKeys.isEmpty)
        XCTAssertFalse(store.readSnapshot().storedKeys.contains(definition.key))
        fail.update { $0 = false }
        XCTAssertTrue(session.run().isComplete)
        XCTAssertEqual(writes.value, 1)
        XCTAssertFalse(store.readSnapshot().storedKeys.contains(definition.key))
    }

    func testPreviewCancelAndPublicResetDoNotReadOrMutateUnavailableUnrelatedCredentials() throws {
        let url = try self.url()
        let secrets = ResetFixtureSecrets()
        let store = try ClientSettings(storageURL: url, secretStore: secrets)
        let field = self.definition("tools.downloadSpeedBoost", .integer(0), ["GeneralConfig.downloadSpeedBoost"])
        let credential = self.definition("ai.serviceKey.fixture", .string(""), ["Service.key"], secret: true)
        try store.register([field, credential])
        try store.set(.integer(2), for: field.key)
        try store.set(.string("PRESERVED-UNREADABLE-FIXTURE"), for: credential.key)
        secrets.failReads.update { $0 = true }
        XCTAssertThrowsError(try store.reload())
        XCTAssertNil(store.value(credential.key))
        XCTAssertTrue(store.readSnapshot().storedKeys.contains(credential.key))
        let before = try Data(contentsOf: url)
        secrets.reads.update { $0 = 0 }
        secrets.writes.update { $0 = [] }
        let provider = CoreSettingsResetProvider(settings: store)
        let cancelled = CoreSettingsResetAuthority()
        let plan = try provider.prepare(scope: .general, authority: cancelled)
        cancelled.invalidate()
        XCTAssertThrowsError(try provider.begin(plan, authority: cancelled))
        XCTAssertEqual(try Data(contentsOf: url), before)
        let authority = CoreSettingsResetAuthority()
        let fresh = try provider.prepare(scope: .general, authority: authority)
        XCTAssertTrue(try provider.begin(fresh, authority: authority).run().isComplete)
        XCTAssertEqual(secrets.reads.value, 0)
        XCTAssertTrue(secrets.writes.value.isEmpty)
        XCTAssertNil(store.value(credential.key))
        XCTAssertTrue(store.readSnapshot().storedKeys.contains(credential.key))
        XCTAssertFalse(store.readSnapshot().storedKeys.contains(field.key))
        secrets.failReads.update { $0 = false }
        XCTAssertEqual(try secrets.data(for: credential.key), try JSONEncoder().encode(ClientSettingValue.string("PRESERVED-UNREADABLE-FIXTURE")))
    }

    func testMalformedFileIsPreservedAndAnExplicitRetryWorksAfterRepair() throws {
        let url = try self.url()
        let store = try ClientSettings(storageURL: url, secretStore: ResetFixtureSecrets())
        let definition = self.definition("privacy.contentCapture", .bool(false), ["GeneralConfig.contentCapture"])
        try store.register([definition])
        try store.set(.bool(true), for: definition.key)
        let original = try Data(contentsOf: url)
        let malformed = Data("{".utf8)
        try malformed.write(to: url)
        XCTAssertThrowsError(try store.reload())
        let provider = CoreSettingsResetProvider(settings: store)
        let authority = CoreSettingsResetAuthority()
        let plan = try provider.prepare(scope: .general, authority: authority)
        XCTAssertEqual(plan.preview.storageError, .invalidJSON)
        let session = try provider.begin(plan, authority: authority)
        XCTAssertEqual(session.run().error, .storage(.invalidJSON))
        XCTAssertEqual(try Data(contentsOf: url), malformed)
        try original.write(to: url)
        XCTAssertTrue(session.run().isComplete)
        XCTAssertFalse(store.readSnapshot().storedKeys.contains(definition.key))
    }

    func testLaterCredentialRepairDoesNotHideAnEarlierFailedReply() throws {
        let url = try self.url()
        let secrets = ResetFixtureSecrets()
        let writes = ResetFixtureBox(0)
        let store = try ClientSettings(storageURL: url, secretStore: secrets, afterFileReplace: { writes.update { $0 += 1 } })
        let field = self.definition("appearance.showSeconds", .bool(false), ["NekoConfig.showSeconds"])
        let first = try XCTUnwrap(AIFeatures.definitions.first { $0.key == "ai.deepLTranslateKey" })
        let second = try XCTUnwrap(AIFeatures.definitions.first { $0.key == "ai.googleCloudTranslateKey" })
        try store.register([field, first, second])
        try store.set(.bool(true), for: field.key)
        try store.set(.string("FIRST-FIXTURE"), for: first.key)
        try secrets.set(Data("false".utf8), for: second.key)
        XCTAssertThrowsError(try store.reload())
        XCTAssertNil(store.value(second.key))
        let provider = CoreSettingsResetProvider(settings: store)
        let authority = CoreSettingsResetAuthority()
        let plan = try provider.prepare(scope: .allOriginal, authority: authority)
        let session = try provider.begin(plan, authority: authority)
        writes.update { $0 = 0 }
        let partial = session.run()
        XCTAssertEqual(partial.error, .storage(.invalidSecret))
        XCTAssertEqual(partial.confirmedKeys, [field.key, second.key])
        XCTAssertEqual(partial.remainingKeys, [first.key])
        XCTAssertEqual(partial.observedResetKeys, [field.key, first.key, second.key])
        XCTAssertNil(try secrets.data(for: first.key))
        XCTAssertNil(try secrets.data(for: second.key))
        XCTAssertTrue(session.run().isComplete)
        XCTAssertEqual(writes.value, 1)
    }

    func testDeletionWithFailedReplyDoesNotEraseANewExplicitEmptyCredentialOnRetry() throws {
        let secrets = ResetFixtureSecrets()
        let store = try ClientSettings(storageURL: self.url(), secretStore: secrets)
        let credential = try XCTUnwrap(AIFeatures.definitions.first { $0.key == "ai.googleCloudTranslateKey" })
        try store.register([credential])
        try store.set(.string("OLD-FIXTURE"), for: credential.key)
        let provider = CoreSettingsResetProvider(settings: store)
        let authority = CoreSettingsResetAuthority()
        let plan = try provider.prepare(scope: .allOriginal, authority: authority)
        let session = try provider.begin(plan, authority: authority)
        secrets.removeThenFail.update { $0 = credential.key }
        let failed = session.run()
        XCTAssertFalse(failed.isComplete)
        XCTAssertTrue(failed.confirmedKeys.isEmpty)
        XCTAssertEqual(failed.observedResetKeys, [credential.key])
        XCTAssertEqual(failed.remainingKeys, [credential.key])
        secrets.removeThenFail.update { $0 = nil }
        try store.set(.string(""), for: credential.key)
        XCTAssertEqual(session.run().error, .settingsChanged)
        XCTAssertTrue(store.readSnapshot().storedKeys.contains(credential.key))
        XCTAssertEqual(try secrets.data(for: credential.key), Data("\"\"".utf8))
    }

    func testChangedRegistrationRequiresANewScopePreviewBeforeWriting() throws {
        let url = try self.url()
        let store = try ClientSettings(storageURL: url, secretStore: ResetFixtureSecrets())
        let first = self.definition("privacy.contentCapture", .bool(false), ["GeneralConfig.contentCapture"])
        let second = self.definition("tools.crashReports", .bool(false), ["GeneralConfig.crashReports"])
        try store.register([first])
        try store.set(.bool(true), for: first.key)
        let provider = CoreSettingsResetProvider(settings: store)
        let authority = CoreSettingsResetAuthority()
        let plan = try provider.prepare(scope: .general, authority: authority)
        let session = try provider.begin(plan, authority: authority)
        try store.register([second])
        try store.set(.bool(true), for: second.key)
        let before = try Data(contentsOf: url)
        XCTAssertEqual(session.run().error, .scopeChanged)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertThrowsError(try provider.begin(plan, authority: CoreSettingsResetAuthority()))
        XCTAssertThrowsError(try CoreSettingsResetProvider(settings: store).begin(plan, authority: authority))
    }

    func testObserverCanReenterWithoutHoldingAResetLockOrRepeatingTheMutation() throws {
        let store = try ClientSettings(storageURL: self.url(), secretStore: ResetFixtureSecrets())
        let definition = self.definition("privacy.contentCapture", .bool(false), ["GeneralConfig.contentCapture"])
        try store.register([definition])
        try store.set(.bool(true), for: definition.key)
        let provider = CoreSettingsResetProvider(settings: store)
        let authority = CoreSettingsResetAuthority()
        let plan = try provider.prepare(scope: .general, authority: authority)
        let session = try provider.begin(plan, authority: authority)
        let reentrant = ResetFixtureBox<CoreSettingsResetReport?>(nil)
        let observation = store.observe { _ in reentrant.update { $0 = session.run() } }
        defer { observation.cancel() }
        XCTAssertTrue(session.run().isComplete)
        XCTAssertEqual(reentrant.value?.error, .operationInProgress)
        XCTAssertFalse(store.readSnapshot().storedKeys.contains(definition.key))
    }

    func testActualAPIPreferenceResetPreservesAccountPinsAndPendingNativeJournal() throws {
        let secrets = ResetFixtureSecrets()
        let store = try ClientSettings(storageURL: self.url(), secretStore: secrets)
        let vault = ClientAPIVault(storage: secrets)
        let scope = ClientAPIAccountScope(recordId: 123, environment: .production)
        let pin = try ClientAPICredentials(apiId: 456, apiHash: String(repeating: "a", count: 32), mode: .custom)
        _ = try vault.pin(pin, for: scope)
        let pending = ClientAPIPendingDraft(version: 1, mode: .custom, apiId: 789, replacementHash: String(repeating: "b", count: 32))
        try vault.setPending(pending, environment: .production)
        try store.register(ClientAPIFeatures.definitions)
        for environment in ClientAPIEnvironment.allCases {
            let prefix = environment.settingPrefix
            try store.set(.string(String(repeating: "c", count: 32)), for: prefix + "customAppHash")
            try store.applyPublic([prefix + "customApi": .integer(3), prefix + "customAppId": .integer(321)])
        }
        let provider = CoreSettingsResetProvider(settings: store)
        let authority = CoreSettingsResetAuthority()
        let plan = try provider.prepare(scope: .allOriginal, authority: authority)
        XCTAssertEqual(plan.preview.publicKeys.count, 4)
        XCTAssertEqual(plan.preview.credentialKeys.count, 2)
        XCTAssertTrue(try provider.begin(plan, authority: authority).run().isComplete)
        XCTAssertTrue(store.readSnapshot().storedKeys.isDisjoint(with: plan.preview.keys))
        XCTAssertEqual(try vault.pin(for: scope)?.generation, pin.generation)
        XCTAssertEqual(try vault.pending(.production)?.apiId, pending.apiId)
        XCTAssertEqual(try vault.pending(.production)?.replacementHash, pending.replacementHash)
        let api = ClientAPIConfigurationStore(settings: store, settingsSecrets: secrets, vault: vault)
        XCTAssertTrue(try api.summary(environment: .production).requiresRepair, "The retained recovery journal is not reported as reset")
    }

    @MainActor
    func testNativeActionGateRunsTheProviderOnlyForTheCurrentContext() async throws {
        final class Context {}
        let first = Context()
        let second = Context()
        var current: Context? = first
        let url = try self.url()
        let store = try ClientSettings(storageURL: url, secretStore: ResetFixtureSecrets())
        let definition = try XCTUnwrap(ToolsFeatures.definitions.first { $0.key == "tools.downloadSpeedBoost" })
        try store.register([definition])
        try store.set(.integer(2), for: definition.key)
        let provider = CoreSettingsResetProvider(settings: store)
        let authority = CoreSettingsResetAuthority()
        let plan = try provider.prepare(scope: .general, authority: authority)
        var factories = 0
        var result: CoreSettingsResetReport?
        let action = {
            CoreSettingsResetActionGate.open(requested: first, current: current, authority: authority,
                make: { _ in factories += 1; return plan },
                present: { result = try? provider.begin($0, authority: authority).run() })
        }
        XCTAssertTrue(action())
        XCTAssertTrue(result?.isComplete == true)
        XCTAssertFalse(store.readSnapshot().storedKeys.contains(definition.key))
        try store.set(.integer(2), for: definition.key)
        let before = try Data(contentsOf: url)
        current = second
        XCTAssertFalse(action())
        current = nil
        XCTAssertFalse(action())
        XCTAssertEqual(factories, 1)
        XCTAssertFalse(CoreSettingsResetActionGate.open(requested: first, current: first, authority: authority,
            make: { lease in lease.invalidate(); return plan }, present: { _ in XCTFail("A retired page was presented") }))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(store.integer(definition.key), 2)
    }
}
