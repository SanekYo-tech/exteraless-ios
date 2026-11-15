import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ExteralessCore

final class AICredentialsTests: XCTestCase, @unchecked Sendable {
    func testPublicServiceDestinationChangesCannotSendStoredAuthorization() async throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        let original = AIService(id: "fixture-service", name: "Fixture", url: "https://trusted.fixture.test/v1", model: "fixture")
        try fixture.settings.save(service: original, credential: .replace("fixture-bound-key"))
        let transport = AIScriptedTransport([])
        var variants: [AIService] = []
        for url in ["https://other.fixture.test/v1", "https://trusted.fixture.test:444/v1", "https://trusted.fixture.test/other-tenant"] {
            var service = original; service.url = url; variants.append(service)
        }
        var protocolChange = original; protocolChange.wireProtocol = .vertex; variants.append(protocolChange)
        var identifierChange = original; identifierChange.id = "another-service"; variants.append(identifierChange)
        for variant in variants {
            try fixture.settings.store.setPublic(try metadata([variant]), for: "ai.services")
            let selected = fixture.settings.selectedService
            let key = fixture.settings.apiKey(for: selected)
            XCTAssertTrue(key.isEmpty)
            do {
                _ = try await AIClient(transport: transport).generate(service: selected, apiKey: key, request: .init(messages: [.init(role: .user, content: "fixture")], streaming: false))
                XCTFail("A public destination change reused a credential")
            } catch { XCTAssertEqual(error as? AIError, .missingKey) }
            XCTAssertNil(try AIRequestBuilder.models(service: selected, apiKey: key).value(forHTTPHeaderField: "Authorization"))
        }
        XCTAssertTrue(transport.requests.isEmpty)
        try fixture.settings.store.setPublic(try metadata([original]), for: "ai.services")
        XCTAssertEqual(fixture.settings.apiKey(for: original), "fixture-bound-key")
    }

    func testEquivalentOriginAndMetadataEditPreserveBindingButOtherServiceDoesNotBorrowIt() throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        var service = AIService(id: "one", url: "https://TRUSTED.fixture.test:443/v1/chat/completions/", model: "first")
        try fixture.settings.save(service: service, credential: .replace("fixture-one"))
        service.url = "https://trusted.fixture.test/v1"
        service.name = "Renamed"
        service.model = "second"
        try fixture.settings.save(service: service, credential: .unchanged)
        XCTAssertEqual(fixture.settings.apiKey(for: service), "fixture-one")
        var other = service; other.id = "two"
        try fixture.settings.save(service: other, credential: .unchanged)
        XCTAssertTrue(fixture.settings.apiKey(for: other).isEmpty)
        XCTAssertEqual(fixture.settings.apiKey(for: service), "fixture-one")
    }

    func testOnlyTrustedNativeSaveCanRebindAnExistingCredential() throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        var service = AIService(id: "fixture", url: "https://one.fixture.test/v1", model: "fixture")
        try fixture.settings.save(service: service, credential: .replace("fixture-key"))
        service.url = "https://two.fixture.test/v1"
        try fixture.settings.store.setPublic(try metadata([service]), for: "ai.services")
        try fixture.settings.register()
        try fixture.settings.save(service: service, credential: .unchanged)
        XCTAssertTrue(fixture.settings.apiKey(for: service).isEmpty)
        let record = fixture.settings.store.string(service.keySetting)
        XCTAssertThrowsError(try fixture.settings.store.setPublic(.string(record), for: service.keySetting))
        try fixture.settings.save(service: service, credential: .unchanged, authorizeDestinationChange: true)
        XCTAssertEqual(fixture.settings.apiKey(for: service), "fixture-key")
        service.url = "https://one.fixture.test/v1"
        XCTAssertTrue(fixture.settings.apiKey(for: service).isEmpty)
    }

    func testCustomLLMAndAudioKeysStayBoundAcrossPublicURLAndPresetChanges() async throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        let settings = fixture.settings
        let store = settings.store
        try settings.saveCustomLLM(baseURL: "https://llm.fixture.test/tenant-a", credential: .replace("fixture-one, fixture-two"))
        try store.set(.string("fixture-model"), for: AILLMPreset.custom.modelSetting)
        try settings.saveOpenAITranscription(baseURL: "https://audio.fixture.test/v1", credential: .replace("fixture-audio"))
        try store.set(.string("fixture-audio-model"), for: "ai.transcribeProviderOpenAiModel")
        XCTAssertEqual(AITranslationConfiguration(settings: settings).llmKeys, ["fixture-one", "fixture-two"])
        XCTAssertEqual(AITranscriptionConfiguration(settings: settings).openAIKey, "fixture-audio")
        XCTAssertThrowsError(try settings.saveLLMKey(preset: .custom, credential: .replace("fixture-replacement")))
        let blockedTransport = AIScriptedTransport([])
        let translator = AITranslationClient(transport: blockedTransport, settings: settings, retryDelay: { _ in XCTFail("Missing binding reached retry") })
        for url in ["https://other.fixture.test/v1", "https://llm.fixture.test/tenant-b", "https://llm.fixture.test:444/tenant-a"] {
            try store.setPublic(.string(url), for: "ai.llmApiUrl")
            var config = AITranslationConfiguration(settings: settings)
            config.provider = .llm
            XCTAssertTrue(config.llmKeys.isEmpty)
            do {
                _ = try await translator.translate(.init(text: "fixture"), to: "fr", configuration: config)
                XCTFail("A public LLM destination change reused a credential")
            } catch { XCTAssertEqual(error as? AIError, .missingKey) }
        }
        for url in ["https://other.fixture.test/v1", "https://audio.fixture.test/v2", "https://audio.fixture.test:444/v1"] {
            try store.setPublic(.string(url), for: "ai.transcribeProviderOpenAiApiBase")
            var config = AITranscriptionConfiguration(settings: settings)
            XCTAssertTrue(config.openAIKey.isEmpty)
            config.provider = .openAI
            let audio = try AIWaveFile.encode(pcm: Data([0, 0]), sampleRate: 48_000)
            do {
                _ = try await AISpeechHTTPClient(transport: blockedTransport).transcribe(audio: audio, configuration: config)
                XCTFail("A public audio destination change reused a credential")
            } catch { XCTAssertEqual(error as? AIError, .missingKey) }
        }
        XCTAssertTrue(blockedTransport.requests.isEmpty)
        try settings.saveLLMKey(preset: .openAI, credential: .replace("fixture-fixed-key"))
        try store.setPublic(.integer(Int64(AILLMPreset.openAI.rawValue)), for: "ai.llmProviderPreset")
        var service = settings.llmService()
        XCTAssertEqual(settings.llmAPIKeys(for: service), ["fixture-fixed-key"])
        service.url = "https://other.fixture.test/v1"
        XCTAssertTrue(settings.llmAPIKeys(for: service).isEmpty)
        service = settings.llmService(); service.id = "llm-0"
        XCTAssertTrue(settings.llmAPIKeys(for: service).isEmpty)
        try settings.saveCustomLLM(baseURL: "https://new-llm.fixture.test/v1", credential: .unchanged, authorizeDestinationChange: true)
        try store.setPublic(.integer(0), for: "ai.llmProviderPreset")
        XCTAssertEqual(settings.llmAPIKeys(for: settings.llmService()), ["fixture-one", "fixture-two"])
        try settings.saveOpenAITranscription(baseURL: "https://new-audio.fixture.test/v1", credential: .unchanged, authorizeDestinationChange: true)
        XCTAssertEqual(AITranscriptionConfiguration(settings: settings).openAIKey, "fixture-audio")
        try settings.saveCustomLLM(baseURL: "https://new-llm.fixture.test/v1", credential: .remove)
        try settings.saveOpenAITranscription(baseURL: "https://new-audio.fixture.test/v1", credential: .remove)
        try settings.saveLLMKey(preset: .openAI, credential: .remove)
        let stored = store.readSnapshot().storedKeys
        XCTAssertFalse(stored.contains(AILLMPreset.custom.keySetting))
        XCTAssertFalse(stored.contains("ai.transcribeProviderOpenAiApiKey"))
        XCTAssertFalse(stored.contains(AILLMPreset.openAI.keySetting))
    }

    func testUnboundLegacyKeysSurvivePreparationButRequireExplicitNativeBinding() throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        let settings = fixture.settings
        try settings.store.set(.string("fixture-legacy-service"), for: AIService.default.keySetting)
        try settings.store.set(.string("fixture-legacy-llm"), for: AILLMPreset.custom.keySetting)
        try settings.store.set(.string("https://llm.fixture.test/v1"), for: "ai.llmApiUrl")
        try settings.store.set(.string("fixture-legacy-audio"), for: "ai.transcribeProviderOpenAiApiKey")
        try settings.store.set(.string("https://audio.fixture.test/v1"), for: "ai.transcribeProviderOpenAiApiBase")
        try settings.register()
        try settings.save(service: .default, credential: .unchanged)
        XCTAssertTrue(settings.apiKey(for: .default).isEmpty)
        XCTAssertEqual(settings.store.string(AIService.default.keySetting), "fixture-legacy-service")
        XCTAssertTrue(settings.llmAPIKeys(for: settings.llmService()).isEmpty)
        XCTAssertTrue(AITranscriptionConfiguration(settings: settings).openAIKey.isEmpty)
        try settings.save(service: .default, credential: .unchanged, authorizeDestinationChange: true)
        try settings.saveCustomLLM(baseURL: "https://llm.fixture.test/v1", credential: .unchanged, authorizeDestinationChange: true)
        try settings.saveOpenAITranscription(baseURL: "https://audio.fixture.test/v1", credential: .unchanged, authorizeDestinationChange: true)
        XCTAssertEqual(settings.apiKey(for: .default), "fixture-legacy-service")
        XCTAssertEqual(settings.llmAPIKeys(for: settings.llmService()), ["fixture-legacy-llm"])
        XCTAssertEqual(AITranscriptionConfiguration(settings: settings).openAIKey, "fixture-legacy-audio")
    }

    func testReloadThenMetadataOnlyUISaveDoesNotDeleteUnregisteredKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AICredentialReload-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let secrets = AIFixtureSecretStore()
        let first = AISettings(store: try ClientSettings(storageURL: url, secretStore: secrets))
        try first.register()
        let second = AISettings(store: try ClientSettings(storageURL: url, secretStore: secrets))
        try second.register()
        var service = AIService(id: "new-service", url: "https://fixture.test/v1", model: "fixture")
        try second.save(service: service, credential: .replace("fixture-persistent-key"))
        let before = try secrets.data(for: service.keySetting)
        try first.store.reload()
        XCTAssertEqual(first.services.map(\.id), [service.id])
        XCTAssertTrue(first.apiKey(for: service).isEmpty) // old UI's fallback read
        service.name = "Metadata-only edit"
        try first.save(service: service, credential: .unchanged)
        XCTAssertEqual(first.apiKey(for: service), "fixture-persistent-key")
        XCTAssertEqual(try secrets.data(for: service.keySetting), before)
        XCTAssertThrowsError(try first.save(service: service, credential: .replace("")))
        XCTAssertEqual(try secrets.data(for: service.keySetting), before)
        try first.save(service: service, credential: .remove)
        XCTAssertNil(try secrets.data(for: service.keySetting))
    }

    func testClosedServiceShapeRejectsRawCredentialUnknownAndWrongTypedFieldsBeforePersistence() throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        let store = fixture.settings.store
        let service = AIService(id: "fixture", name: "Portable service metadata", url: "https://fixture.test/v1", model: "fixture")
        try fixture.settings.save(service: service, credential: .replace("fixture-never-exported"))
        guard case let .array(values) = try metadata([service]), case let .object(record) = values[0] else { return XCTFail("Invalid fixture") }
        let before = try Data(contentsOf: fixture.url)
        for (field, value) in [("key", ClientSettingValue.string("fixture-nested-secret")), ("credentials", .object(["key": .string("fixture-nested-secret")])), ("model", .integer(123)), ("reasoningEffort", .string("2")), ("url", .object(["key": .string("fixture-nested-secret")])), ("unknown", .bool(true))] {
            var rejected = record; rejected[field] = value
            XCTAssertThrowsError(try store.setPublic(.array([.object(rejected)]), for: "ai.services")) { XCTAssertEqual($0 as? ClientSettingsError, .invalidValue(key: "ai.services", reason: .shape)) }
            XCTAssertEqual(try Data(contentsOf: fixture.url), before)
            XCTAssertFalse(String(decoding: try store.exportJSON(), as: UTF8.self).contains("fixture-nested-secret"))
        }
        XCTAssertThrowsError(try store.setPublic(.array(Array(repeating: .object(record), count: AIFeatures.maximumServices + 1)), for: "ai.services"))
        let exported = String(decoding: try store.exportJSON(), as: UTF8.self)
        XCTAssertTrue(exported.contains("Portable service metadata"))
        XCTAssertTrue(exported.contains("ai.services"))
        XCTAssertFalse(exported.contains("fixture-never-exported"))
        XCTAssertEqual(store.readSnapshot().values[service.keySetting], .null)
        XCTAssertFalse(AIFeatures.servicesDefinition.isSecret)
    }

    func testLegacyRawServiceCredentialsAreRejectedWithoutPublishingAWeakRepairSchema() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIRawServices-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("settings.json")
        try Data(#"{"ai.services":[{"id":"legacy","url":"https://fixture.test/v1","model":"fixture","key":"fixture-raw-secret"}]}"#.utf8).write(to: url)
        let settings = AISettings(store: try ClientSettings(storageURL: url, secretStore: AIFixtureSecretStore()))
        XCTAssertThrowsError(try settings.register())
        XCTAssertNil(settings.store.readSnapshot().values["ai.services"])
        XCTAssertFalse(String(decoding: try settings.store.exportJSON(), as: UTF8.self).contains("fixture-raw-secret"))
        XCTAssertFalse(settings.store.definitions().contains { $0.key == "ai.services" && $0.valueShape == nil })
    }

    private func metadata(_ services: [AIService]) throws -> ClientSettingValue {
        try JSONDecoder().decode(ClientSettingValue.self, from: JSONEncoder().encode(services))
    }
}
