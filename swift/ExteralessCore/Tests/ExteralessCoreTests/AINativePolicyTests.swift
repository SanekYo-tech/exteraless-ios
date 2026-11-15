import Foundation
import XCTest
@testable import ExteralessCore

final class AINativePolicyTests: XCTestCase {
    func testAF05DefaultAutoTargetUsesTheSameAvailabilityAndNormalization() throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        var policy = AITranslationPolicy(store: fixture.settings.store)
        XCTAssertEqual(AINativeTranslationTarget.resolve(isEnabled: true, toLanguage: nil, appLanguage: "en-raw", isPremium: false, peerAutoTranslate: false, policy: policy), "en")
        XCTAssertEqual(AINativeTranslationTarget.resolve(isEnabled: true, toLanguage: "nb-NO", appLanguage: "en", isPremium: false, peerAutoTranslate: false, policy: policy), "no")
        XCTAssertNil(AINativeTranslationTarget.resolve(isEnabled: false, toLanguage: nil, appLanguage: "en", isPremium: true, peerAutoTranslate: true, policy: policy))
        try fixture.settings.store.set(.integer(8), for: "ai.translationProvider")
        policy = AITranslationPolicy(store: fixture.settings.store)
        XCTAssertNil(AINativeTranslationTarget.resolve(isEnabled: true, toLanguage: nil, appLanguage: "en", isPremium: false, peerAutoTranslate: false, policy: policy))
        XCTAssertEqual(AINativeTranslationTarget.resolve(isEnabled: true, toLanguage: nil, appLanguage: "en", isPremium: false, peerAutoTranslate: true, policy: policy), "en")
        let target = AINativeTranslationTarget.resolve(isEnabled: true, toLanguage: nil, appLanguage: "en", isPremium: true, peerAutoTranslate: false, policy: policy)
        let selection = AINativeDisplaySelection(policy: policy, manual: .init(language: "fr"), manualAvailable: true, automaticLanguage: target, incoming: true)
        XCTAssertFalse(selection.canHideManual)
    }

    func testVisibilityDefaultsAndResetAreIndependentOfProviderReplacement() throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        let store = fixture.settings.store
        try store.register(AINativeVisibilityPolicy.definitions)
        let initial = AINativeVisibilityPolicy(store: store)
        XCTAssertFalse(initial.hideAiEditor)
        XCTAssertFalse(initial.hideIvSummary)
        XCTAssertFalse(initial.hideMessageSummary)
        for definition in AINativeVisibilityPolicy.definitions {
            XCTAssertEqual(definition.defaultValue, .bool(false))
            try store.set(.bool(true), for: definition.key)
        }
        try store.set(.bool(true), for: "ai.replaceTelegramEditor")
        try store.set(.bool(true), for: "ai.replaceTelegramSummaries")
        let hidden = AINativeVisibilityPolicy(store: store)
        XCTAssertTrue(hidden.hideAiEditor)
        XCTAssertTrue(hidden.hideIvSummary)
        XCTAssertTrue(hidden.hideMessageSummary)
        try store.reset(AINativeVisibilityPolicy.editorKey)
        XCTAssertFalse(AINativeVisibilityPolicy(store: store).hideAiEditor)
        XCTAssertTrue(AINativeVisibilityPolicy(store: store).hideIvSummary)
        XCTAssertTrue(AINativeVisibilityPolicy(store: store).hideMessageSummary)
        try store.reset(AINativeVisibilityPolicy.instantViewKey)
        try store.reset(AINativeVisibilityPolicy.messageSummaryKey)
        let restored = AINativeVisibilityPolicy(store: store)
        XCTAssertFalse(restored.hideIvSummary)
        XCTAssertFalse(restored.hideMessageSummary)
        XCTAssertTrue(store.readSnapshot().storedKeys.isDisjoint(with: AINativeVisibilityPolicy.keys))
        XCTAssertEqual(store.value("ai.replaceTelegramEditor"), .bool(true))
        XCTAssertEqual(store.value("ai.replaceTelegramSummaries"), .bool(true))
    }

    func testLateSummaryFailureCannotRetireNewSuccessAndOffDisposesA() {
        let registry = AINativeOperationRegistry<Int>()
        var cancellations = 0
        let a = registry.begin(1)
        registry.bind(1, generation: a, cancel: { cancellations += 1 })
        registry.cancel(1)
        let b = registry.begin(1)
        XCTAssertTrue(registry.finish(1, generation: b))
        XCTAssertFalse(registry.finish(1, generation: a))
        XCTAssertEqual(cancellations, 1)
        // Synchronous completion before the signal's disposable is assigned.
        var disposedLateBinding = false
        registry.bind(1, generation: b, cancel: { disposedLateBinding = true })
        XCTAssertTrue(disposedLateBinding)
    }

    func testLeaseCancellationBeforeQueuedMutationIsFinal() {
        let lease = AINativeOperationLease()
        var writes = 0
        lease.cancel()
        let result: Bool? = lease.withActive { writes += 1; return true }
        XCTAssertNil(result)
        XCTAssertEqual(writes, 0)
        var lateBindingCancelled = false
        let flag = AINativeTestFlag()
        lease.bind { flag.set() }
        lateBindingCancelled = flag.value
        XCTAssertTrue(lateBindingCancelled)
    }

    func testEffectiveOverrideDrivesContextAndAutoDoesNotUsePrecedingHistory() throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        try fixture.settings.store.set(.bool(true), for: "ai.llmUseContext")
        let googleDefault = AITranslationPolicy(store: fixture.settings.store)
        XCTAssertTrue(AINativeContextPolicy.enabled(policy: googleDefault, purpose: .manual, effectiveProvider: .llm))
        try fixture.settings.store.set(.integer(10), for: "ai.translationProvider")
        let llmDefault = AITranslationPolicy(store: fixture.settings.store)
        XCTAssertFalse(AINativeContextPolicy.enabled(policy: llmDefault, purpose: .manual, effectiveProvider: .google))
        XCTAssertFalse(AINativeContextPolicy.enabled(policy: llmDefault, purpose: .automatic, effectiveProvider: .llm))
        XCTAssertFalse(AINativeContextPolicy.includesPrecedingHistory(purpose: .automatic))
        XCTAssertTrue(AINativeContextPolicy.includesPrecedingHistory(purpose: .manual))
        XCTAssertEqual(AINativeContextPolicy.visitLimit(messageLimit: Int.max), 50)
    }

    func testManualDisplayLanguageAndHideAvailabilityWithAutoAndInvalidatedCache() throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        for mode in 0 ... 2 {
            try fixture.settings.store.set(.integer(Int64(mode)), for: "ai.translatorMode")
            let policy = AITranslationPolicy(store: fixture.settings.store)
            let manual = AIManualTranslationState(language: "fr")
            let off = AINativeDisplaySelection(policy: policy, manual: manual, manualAvailable: true, automaticLanguage: nil, incoming: true)
            XCTAssertEqual(off.language, "fr")
            XCTAssertEqual(off.keepsOriginal, mode != 0)
            XCTAssertTrue(off.canHideManual)
            let on = AINativeDisplaySelection(policy: policy, manual: manual, manualAvailable: true, automaticLanguage: "de", incoming: true)
            XCTAssertEqual(on.language, "fr")
            XCTAssertFalse(on.canHideManual)
            let edited = AINativeDisplaySelection(policy: policy, manual: manual, manualAvailable: false, automaticLanguage: nil, incoming: true)
            XCTAssertNil(edited.language)
            XCTAssertEqual(edited.origin, .original)
        }
    }

    func testSpeechRouteReadinessMatrixUsesActualPremiumAndExplicitSelection() throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        var config = AITranscriptionConfiguration(settings: fixture.settings)
        config.geminiKey = ""; config.openAIKey = ""; config.cloudflareToken = ""
        for premium in [false, true] {
            for provider in AITranscriptionProvider.allCases {
                config.provider = provider
                let route = AINativeSpeechPolicy.route(configuration: config, isPremium: premium)
                if provider == .auto {
                    XCTAssertEqual(route, premium ? .telegram : .provider(.workersAI))
                } else { XCTAssertEqual(route, .provider(provider)) }
                if provider != .auto {
                    XCTAssertEqual(AINativeSpeechPolicy.isConfigured(provider, configuration: config), provider == .apple)
                }
            }
        }
        config.provider = .auto
        config.openAIBaseURL = "https://audio.invalid/v1"; config.openAIModel = "fixture"; config.openAIKey = "fixture"
        XCTAssertEqual(AINativeSpeechPolicy.route(configuration: config, isPremium: false), .provider(.openAI))
        config.geminiKey = "fixture"
        XCTAssertEqual(AINativeSpeechPolicy.route(configuration: config, isPremium: false), .provider(.gemini))
        XCTAssertEqual(AINativeSpeechPolicy.route(configuration: config, isPremium: true), .telegram)
    }
}

private final class AINativeTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var setValue = false
    func set() { lock.lock(); setValue = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return setValue }
}
