import Foundation
import XCTest
@testable import ExteralessCore

final class CloudLegacyImportTests: XCTestCase, @unchecked Sendable {
    private func target(_ secrets: CloudFixtureSecrets = CloudFixtureSecrets(), storageURL: URL? = nil) throws -> ClientSettings {
        let file = try storageURL ?? cloudTemporaryDirectory().appendingPathComponent("settings.json")
        let settings = try ClientSettings(storageURL: file, secretStore: secrets)
        try settings.register(AppearanceFeatures.definitions + ChatFeatures.definitions + PrivacyFeatures.definitions
            + AIFeatures.definitions + ToolsFeatures.definitions + CloudFeatures.definitions + ClientAPIFeatures.definitions)
        return settings
    }

    private func remote(_ sections: [String: ClientSettingValue]) throws -> CloudLegacyRemoteSnapshot {
        let bytes = try CloudProtocol.encode(sections)
        return CloudLegacyRemoteSnapshot(owner: CloudFixture.owner, fingerprint: ToolsSHA256.hex(bytes),
            reportedUpdatedAtMilliseconds: 1234, data: bytes)
    }

    private func inspect(_ sections: [String: ClientSettingValue], settings: ClientSettings, keys: Bool = false) throws -> CloudLegacyRestorePlan {
        try CloudLegacySettingsArchive.inspect(remote(sections), snapshot: settings.readSnapshot(), includeApiKeys: keys, date: CloudFixture.date)
    }

    private func androidService(id: String = "fixture", url: String = "https://source.invalid/v1", key: String? = "incoming-fixture-key") -> ClientSettingValue {
        var value: [String: ClientSettingValue] = ["id": .string(id), "name": .string("Fixture"), "url": .string(url), "model": .string("fixture-model"), "reasoningEnabled": .bool(true)]
        value["key"] = key.map(ClientSettingValue.string) ?? .null
        return .object(value)
    }

    private func serviceString(_ services: [ClientSettingValue]) throws -> ClientSettingValue {
        .string(String(decoding: try CloudProtocol.encode(ClientSettingValue.array(services)), as: UTF8.self))
    }

    func testActualSharedPreferenceTypesPercentUnitsAndExplicitEnumSemantics() throws {
        let settings = try target()
        let plan = try inspect(["nkmrcfg": .object([
            "showSeconds": .bool(true), "sendReadMessagePackets": .bool(false),
            "OEChatsFlashIntensity": .integer(50), "OEChatsFlashWarmth": .integer(25),
            "LlmTemperature_float": .number(0.7), "DoubleTapAction": .integer(4),
            "translationProvider": .integer(7), "TransInputToLang": .string("pt-BR")
        ])], settings: settings)
        XCTAssertEqual(plan.publicInspection.settings["tools.flashIntensity"], .integer(50))
        XCTAssertEqual(plan.publicInspection.settings["tools.flashWarmth"], .integer(25))
        XCTAssertEqual(plan.publicInspection.settings["ai.llmTemperature"], .number(0.7))
        XCTAssertEqual(plan.publicInspection.settings["chats.doubleTapAction"], .integer(Int64(ChatDoubleTapAction.reply.rawValue)))
        XCTAssertEqual(plan.publicInspection.settings["ai.translationProvider"], .integer(Int64(AITranslationProvider.deepL.rawValue)))
        _ = try CloudLegacySettingsArchive.apply(plan, settings: settings, includeApiKeys: false, credentials: CloudFixtureSecrets())
        XCTAssertTrue(settings.bool("appearance.showSeconds"))
        XCTAssertFalse(settings.bool("privacy.sendReadMessagePackets"))
        XCTAssertEqual(settings.string("ai.translateInputLang"), "pt-BR")
    }

    func testWrongSuffixesUnsupportedOptionsAndDistinctLegacyAliasesAreReported() throws {
        let settings = try target()
        let plan = try inspect(["nkmrcfg": .object([
            "OEChatsFlashWarmth_float": .number(0.5), "LlmTemperature": .number(0.7),
            "translationProvider": .integer(2), "TranscribeProvider": .integer(1),
            "SortByUnread": .bool(true), "sort_by_unread": .bool(false)
        ])], settings: settings)
        XCTAssertEqual(plan.settingCount, 0)
        XCTAssertTrue(plan.skipped.contains { $0.originalIDs == ["chats.flashWarmth"] && $0.reason == .incompatibleType })
        XCTAssertTrue(plan.skipped.contains { $0.originalIDs == ["nagram.llmTemperature"] && $0.reason == .incompatibleType })
        XCTAssertTrue(plan.skipped.contains { $0.originalIDs == ["neko.translationProvider"] && $0.reason == .unsupportedOption })
        XCTAssertTrue(plan.skipped.contains { $0.originalIDs == ["nagram.sortByUnread"] })
        XCTAssertTrue(plan.skipped.contains { $0.originalIDs == ["neko.sortByUnread"] })
    }

    func testVersionedTranslationModeUsesOriginalMigrationAndMarksItAtomically() throws {
        let settings = try target()
        let old = try inspect(["nkmrcfg": .object(["TranslatorMode": .integer(0), "TranslatorModeWithOriginalMigrated": .bool(false)])], settings: settings)
        XCTAssertEqual(old.publicInspection.settings["ai.translatorMode"], .integer(1))
        XCTAssertEqual(old.publicInspection.settings["ai.translatorModeWithOriginalMigrated"], .bool(true))
        let current = try inspect(["nkmrcfg": .object(["TranslatorMode": .integer(2), "TranslatorModeWithOriginalMigrated": .bool(true)])], settings: settings)
        XCTAssertEqual(current.publicInspection.settings["ai.translatorMode"], .integer(2))
    }

    func testExcludedUserAuthSystemAndPerAccountFieldsCarrySourceIDs() throws {
        let settings = try target()
        let plan = try inspect([
            "nkmrcfg": .object(["OEGlyphCalls": .bool(true), "DisableSystemAccount": .bool(true), "userNameOverride_123": .string("private"), "customForumTabs_55": .bool(true)]),
            "aiConfig": .object(["history": .string("private-history"), "roles": .string("private-roles")]),
            "userconfing": .object(["passcodeHash": .string("not-an-importable-credential")]),
            "nekox_config": .object(["custom_app_hash": .string(String(repeating: "a", count: 32))]),
            "nekocloud": .object(["updated_at_long": .integer(777), "auto_sync": .bool(true)]),
            "mainconfig": .object(["fontSize": .integer(19)])
        ], settings: settings, keys: true)
        XCTAssertEqual(plan.settingCount, 0)
        XCTAssertEqual(plan.credentialCount, 0)
        for id in ["glyph.onCall", "neko.disableSystemAccount", "localnamehelper.userNameOverride", "dialog.customForumTabsEnable", "ai.history", "ai.roles", "nekox.customAppHash", "cloudsettingshelper.localSyncedDate"] {
            XCTAssertTrue(plan.skipped.contains { $0.originalIDs.contains(id) }, id)
        }
        XCTAssertEqual(plan.reportedUpdatedAtMilliseconds, 1234)
        XCTAssertEqual(CloudLocalState(scope: CloudFixture.scope).lastSuccessfulSyncMilliseconds, -1)
        XCTAssertFalse(settings.bool("cloud.autoSync"))
    }

    func testLegacyOverlayCASPreservesAbsentUnrelatedFieldsAndRejectsChangedPresence() async throws {
        let file = try cloudTemporaryDirectory().appendingPathComponent("settings.json")
        let secrets = CloudFixtureSecrets()
        let settings = try target(secrets, storageURL: file)
        let external = try ClientSettings(storageURL: file, secretStore: secrets)
        try external.register(settings.definitions())
        let input: [String: ClientSettingValue] = ["nkmrcfg": .object(["showSeconds": .bool(true)])]
        let stale = try inspect(input, settings: settings)
        try external.applyPublic(["appearance.showSeconds": .bool(false), "appearance.mediaPreview": .bool(false)])
        let beforeRejectedApply = try Data(contentsOf: file)
        XCTAssertThrowsError(try CloudLegacySettingsArchive.apply(stale, settings: settings, includeApiKeys: false, credentials: CloudFixtureSecrets())) {
            XCTAssertEqual($0 as? ClientSettingsError, .concurrentModification)
        }
        XCTAssertEqual(try Data(contentsOf: file), beforeRejectedApply)
        XCTAssertEqual(settings.readSnapshot().lastError, .concurrentModification)
        XCTAssertThrowsError(try inspect(input, settings: settings)) { XCTAssertEqual($0 as? CloudError, .localStorage) }
        try external.applyPublic(["appearance.disableVibration": .bool(true)],
            resetting: ["appearance.showSeconds", "appearance.mediaPreview"])
        let beforeRefresh = try Data(contentsOf: file)
        let snapshot = try await CloudSettingsArchive.readLatestSnapshot(settings: settings)
        XCTAssertNil(snapshot.lastError)
        XCTAssertEqual(snapshot.values["appearance.disableVibration"], .bool(true))
        XCTAssertEqual(snapshot.values["appearance.mediaPreview"], .bool(true))
        XCTAssertFalse(snapshot.storedKeys.contains("appearance.showSeconds"))
        XCTAssertFalse(snapshot.storedKeys.contains("appearance.mediaPreview"))
        XCTAssertEqual(try Data(contentsOf: file), beforeRefresh)
        let fresh = try CloudLegacySettingsArchive.inspect(remote(input), snapshot: snapshot, includeApiKeys: false, date: CloudFixture.date)
        try external.applyPublic(["appearance.customTitle": .string("Unrelated external edit")])
        _ = try CloudLegacySettingsArchive.apply(fresh, settings: settings, includeApiKeys: false, credentials: CloudFixtureSecrets())
        XCTAssertTrue(settings.bool("appearance.showSeconds"))
        XCTAssertTrue(settings.bool("appearance.disableVibration"))
        XCTAssertEqual(settings.string("appearance.customTitle"), "Unrelated external edit")
        XCTAssertFalse(settings.readSnapshot().storedKeys.contains("appearance.squareFab"))
    }

    func testLegacyServiceSelectionKeepsStableIdThenHashAndClosedPublicMetadata() throws {
        let settings = try target()
        let first = androidService(id: "first", key: "first-fixture")
        let second = androidService(id: "second", key: "second-fixture")
        let legacyHash = AISettings.javaServiceHash(url: "https://source.invalid/v1", model: "fixture-model", key: "second-fixture")
        let fields: [String: ClientSettingValue] = ["services": try serviceString([first, second]), "selectedService": .integer(Int64(legacyHash))]
        let hashPlan = try inspect(["aiConfig": .object(fields)], settings: settings, keys: true)
        XCTAssertEqual(hashPlan.publicInspection.settings["ai.selectedServiceId"], .string("second"))
        var byId = fields
        byId["selectedServiceId"] = .string("first")
        let idPlan = try inspect(["aiConfig": .object(byId)], settings: settings, keys: true)
        XCTAssertEqual(idPlan.publicInspection.settings["ai.selectedServiceId"], .string("first"))
        let metadata = try XCTUnwrap(idPlan.publicInspection.settings["ai.services"])
        try AIFeatures.servicesDefinition.validate(metadata)
        let text = String(decoding: try CloudProtocol.encode(metadata), as: UTF8.self)
        XCTAssertFalse(text.contains("first-fixture"))
        XCTAssertFalse(text.contains("reasoningEnabled"))
        XCTAssertEqual(idPlan.credentialGroups.count, 2)
        XCTAssertTrue(idPlan.credentialGroups.allSatisfy { $0.detail?.contains("source.invalid") == true })
    }

    func testExistingNativeKeyAndBindingAreNotReboundByRestoredServiceURL() throws {
        let secrets = CloudFixtureSecrets()
        let settings = try target(secrets)
        let native = AISettings(store: settings)
        let before = AIService(id: "fixture", url: "https://old.invalid/v1", model: "fixture-model")
        try native.save(service: before, credential: .replace("existing-fixture-key"))
        let protected = settings.string(before.keySetting)
        let plan = try inspect(["aiConfig": .object(["services": try serviceString([androidService()])])], settings: settings, keys: true)
        let result = try CloudLegacySettingsArchive.apply(plan, settings: settings, includeApiKeys: true, credentials: secrets)
        XCTAssertEqual(result.retainedCredentials, 1)
        XCTAssertEqual(settings.string(before.keySetting), protected)
        let after = try XCTUnwrap(native.services.first { $0.id == "fixture" })
        XCTAssertEqual(native.apiKey(for: after), "")
        XCTAssertEqual(native.apiKey(for: before), "existing-fixture-key")
        let exported = try CloudCredentials.export(snapshot: settings.readSnapshot(), includeApiKeys: true, storage: secrets)
        XCTAssertFalse(exported.contains { $0.id == .assistant(serviceId: "fixture") })
    }

    func testNewIncomingKeyUsesOnlyConfirmedSnapshotOriginAndWholeProtectedValueExports() throws {
        let secrets = CloudFixtureSecrets()
        let settings = try target(secrets)
        let plan = try inspect(["aiConfig": .object(["services": try serviceString([androidService()])])], settings: settings, keys: true)
        let result = try CloudLegacySettingsArchive.apply(plan, settings: settings, includeApiKeys: true, credentials: secrets)
        XCTAssertEqual(result.addedCredentials, 1)
        let native = AISettings(store: settings)
        let service = try XCTUnwrap(native.services.first)
        XCTAssertEqual(native.apiKey(for: service), "incoming-fixture-key")
        let protected = settings.string(service.keySetting)
        XCTAssertTrue(protected.hasPrefix("exteraless.ai-credential.v1\n"))
        let exported = try CloudCredentials.export(snapshot: settings.readSnapshot(), includeApiKeys: true, storage: secrets)
        let entry = try XCTUnwrap(exported.first { $0.id == .assistant(serviceId: "fixture") })
        XCTAssertEqual(entry.withValue { $0 }, protected)
        var changed = service
        changed.url = "https://other.invalid/v1"
        try native.save(service: changed, credential: .unchanged)
        XCTAssertEqual(settings.string(service.keySetting), protected)
        XCTAssertEqual(native.apiKey(for: changed), "")
    }

    func testCustomLLMAndAudioRequireTheirBackupEndpointsAndKeepBoundDestinations() throws {
        let secrets = CloudFixtureSecrets()
        let settings = try target(secrets)
        let plan = try inspect(["nkmrcfg": .object([
            "LlmApiUrl": .string("https://llm.invalid/v1"), "LlmApiKey": .string("llm-fixture-one,llm-fixture-two"),
            "TranscribeProviderOpenAiApiBase": .string("https://audio.invalid/v1"), "TranscribeProviderOpenAiApiKey": .string("audio-fixture")
        ])], settings: settings, keys: true)
        _ = try CloudLegacySettingsArchive.apply(plan, settings: settings, includeApiKeys: true, credentials: secrets)
        let native = AISettings(store: settings)
        XCTAssertEqual(native.llmAPIKeys(for: native.llmService()), ["llm-fixture-one", "llm-fixture-two"])
        XCTAssertEqual(native.openAITranscriptionAPIKey(baseURL: "https://audio.invalid/v1"), "audio-fixture")
        try settings.applyPublic(["ai.llmApiUrl": .string("https://changed.invalid/v1")])
        XCTAssertTrue(native.llmAPIKeys(for: native.llmService()).isEmpty)
        let missing = try inspect(["nkmrcfg": .object(["LlmApiKey": .string("not-for-live-url")])], settings: settings, keys: true)
        XCTAssertEqual(missing.credentialCount, 0)
        XCTAssertEqual(missing.skipped.first?.reason, .missingEndpoint)
    }

    func testDisabledCredentialsMalformedServicesAndDuplicateJSONCannotGainPermission() throws {
        let secrets = CloudFixtureSecrets()
        let settings = try target(secrets)
        secrets.resetReads()
        let off = try inspect(["aiConfig": .object(["services": try serviceString([androidService()])])], settings: settings)
        XCTAssertEqual(off.credentialCount, 0)
        XCTAssertTrue(off.skipped.contains { $0.reason == .credentialsDisabled })
        XCTAssertTrue(secrets.readKeys().isEmpty)
        var malformed: [String: ClientSettingValue] = ["id": .string("fixture"), "name": .string("x"), "url": .string("https://fixture.invalid/v1"), "model": .string("m")]
        malformed["headers"] = .object(["authorization": .string("not-public-metadata")])
        let invalid = try inspect(["aiConfig": .object(["services": try serviceString([.object(malformed)])])], settings: settings, keys: true)
        XCTAssertEqual(invalid.settingCount, 0)
        XCTAssertEqual(invalid.credentialCount, 0)
        XCTAssertTrue(invalid.skipped.contains { $0.originalIDs == ["ai.services"] })
        let duplicate = Data(#"{"nkmrcfg":{"showSeconds":true,"showSeconds":false}}"#.utf8)
        XCTAssertThrowsError(try CloudLegacyJSON.decode(duplicate))
        let escapedDuplicate = Data(#"{"url":"a","u\u0072l":"b"}"#.utf8)
        XCTAssertThrowsError(try CloudLegacyJSON.decode(escapedDuplicate))
    }

    func testUnboundNativeBackupKeyIsPreservedWithoutInferringAnOrigin() throws {
        let secrets = CloudFixtureSecrets()
        let settings = try target(secrets)
        let service = AIService(id: "fixture", url: "https://fixture.invalid/v1", model: "m")
        let metadata = try JSONDecoder().decode(ClientSettingValue.self, from: CloudProtocol.encode([service]))
        try settings.applyPublic(["ai.services": metadata])
        let entry = try CloudCredentialEntry(id: .assistant(serviceId: "fixture"), value: "old-unbound-fixture")
        try CloudCredentials.validate([entry], publicValues: settings.readSnapshot().values)
        try CloudCredentials.register([entry], settings: settings)
        _ = try secrets.insertIfAbsent(entry)
        try settings.reload()
        let native = AISettings(store: settings)
        XCTAssertEqual(native.apiKey(for: service), "")
        try native.save(service: service, credential: .unchanged, authorizeDestinationChange: true)
        XCTAssertEqual(native.apiKey(for: service), "old-unbound-fixture")
    }

    func testChatLegacyAliasPrecedenceIsProjectedBeforeTypedAdmission() throws {
        let settings = try target()
        let preview = try inspect(["nkmrcfg": .object([
            "DisableChannelMuteButton": .bool(true), "OEChatsBottomButton": .integer(2),
            "HideReactions": .bool(true), "OEChatsHideReactionsChannels": .bool(false),
            "OEChatsHideReactionsGroups": .bool(false), "OEChatsHideReactionsPrivate": .bool(false),
            "MessageColoredBackground": .bool(false), "OEChatsReplyBackground": .bool(true)
        ])], settings: settings)
        let values = preview.publicInspection.settings
        XCTAssertEqual(values["chats.bottomButton"], .integer(0))
        for key in ["chats.hideReactionsInChannels", "chats.hideReactionsInGroups", "chats.hideReactionsInPrivate"] { XCTAssertEqual(values[key], .bool(true)) }
        XCTAssertEqual(values["chats.replyBackground"], .bool(false))
        try CloudPublicRestoreProjection.validate(preview.publicInspection)
        XCTAssertFalse(preview.publicInspection.payload.clientSettings.keys.contains { $0.hasPrefix("clientAPI.") || $0.hasPrefix("cloud.") })
    }

    func testChatInactiveOrAbsentAliasesDoNotMaterializeNativeDefaults() throws {
        let settings = try target()
        let preview = try inspect(["nkmrcfg": .object([
            "DisableChannelMuteButton": .bool(false), "HideReactions": .bool(false), "MessageColoredBackground": .bool(true)
        ])], settings: settings)
        XCTAssertEqual(preview.settingCount, 0)
        XCTAssertTrue(preview.mapped.isEmpty)
        XCTAssertEqual(preview.skipped.count, 3)
        let absent = try inspect(["nkmrcfg": .object(["showSeconds": .bool(true)])], settings: settings)
        for key in ["chats.bottomButton", "chats.replyBackground", "chats.defaultHlsVideoQuality", "chats.preferOriginalQuality"] {
            XCTAssertNil(absent.publicInspection.payload.clientSettings[key])
        }
    }

    func testNativeFontFamilyAndLayoutUseTypedPortableAdmissionWithoutCredentials() throws {
        let secrets = CloudFixtureSecrets()
        let settings = try target(secrets)
        secrets.resetReads()
        let preview = try inspect(["nkmrcfg": .object([
            "TypefaceUseDefault": .bool(false), "TabletMode": .integer(2)
        ])], settings: settings)
        XCTAssertEqual(preview.publicInspection.settings, [
            "appearance.useSystemFonts": .bool(false), "appearance.tabletMode": .integer(2)
        ])
        try CloudPublicRestoreProjection.validate(preview.publicInspection)
        _ = try CloudLegacySettingsArchive.apply(preview, settings: settings, includeApiKeys: false, credentials: secrets)
        XCTAssertFalse(settings.bool("appearance.useSystemFonts", default: true))
        XCTAssertEqual(settings.integer("appearance.tabletMode"), 2)
        XCTAssertTrue(settings.readSnapshot().storedKeys.isSuperset(of: ["appearance.useSystemFonts", "appearance.tabletMode"]))
        XCTAssertTrue(secrets.readKeys().isEmpty)
    }

    func testMalformedFontAndLayoutValuesDoNotReplaceTheExistingSelection() throws {
        let settings = try target()
        try settings.applyPublic(["appearance.useSystemFonts": .bool(false), "appearance.tabletMode": .integer(1)])
        let preview = try inspect(["nkmrcfg": .object([
            "TypefaceUseDefault": .integer(1), "TabletMode": .integer(3)
        ])], settings: settings)
        XCTAssertEqual(preview.settingCount, 0)
        XCTAssertEqual(preview.skipped.count, 2)
        XCTAssertFalse(settings.bool("appearance.useSystemFonts", default: true))
        XCTAssertEqual(settings.integer("appearance.tabletMode"), 1)
    }

    func testChatLegacyHighestQualityBecomesExplicitAutoPlusOriginalQuality() throws {
        let settings = try target()
        try settings.applyPublic(["chats.defaultHlsVideoQuality": .integer(4), "chats.preferOriginalQuality": .bool(false)])
        let preview = try inspect(["nkmrcfg": .object([
            "DefaultHlsVideoQuality": .integer(1), "OEChatsPreferOriginalQuality": .bool(false)
        ])], settings: settings)
        XCTAssertEqual(preview.publicInspection.settings["chats.defaultHlsVideoQuality"], .integer(0))
        XCTAssertEqual(preview.publicInspection.settings["chats.preferOriginalQuality"], .bool(true))
        XCTAssertTrue(preview.publicInspection.resetting.isEmpty) // Source writes Auto; it does not remove the override.
        _ = try CloudLegacySettingsArchive.apply(preview, settings: settings, includeApiKeys: false, credentials: CloudFixtureSecrets())
        XCTAssertEqual(settings.integer("chats.defaultHlsVideoQuality"), 0)
        XCTAssertTrue(settings.bool("chats.preferOriginalQuality"))
        XCTAssertTrue(settings.readSnapshot().storedKeys.contains("chats.defaultHlsVideoQuality"))
    }
}
