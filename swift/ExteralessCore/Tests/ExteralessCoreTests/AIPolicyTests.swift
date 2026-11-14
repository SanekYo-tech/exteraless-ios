import Foundation
import XCTest
@testable import ExteralessCore

final class AIPolicyTests: XCTestCase {
    func testReplacementDefaultFollowsAccountPremiumAndExplicitOverride() {
        XCTAssertTrue(AIReplacementPolicy.enabled(nil, isPremium: false, configured: true))
        XCTAssertTrue(AIReplacementPolicy.enabled(.null, isPremium: false, configured: true))
        XCTAssertFalse(AIReplacementPolicy.enabled(.null, isPremium: true, configured: true))
        XCTAssertTrue(AIReplacementPolicy.enabled(.bool(true), isPremium: true, configured: true))
        XCTAssertFalse(AIReplacementPolicy.enabled(.bool(false), isPremium: false, configured: true))
        XCTAssertFalse(AIReplacementPolicy.enabled(.bool(true), isPremium: false, configured: false))
    }

    func testOriginalRenderingModeOffsetsAndAutomaticGate() throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        let store = fixture.settings.store
        let original = AIFormattedText(text: "Hi 👋", spans: [.init(id: 0, offset: 3, length: 2, tag: .protected, preserveText: true)])
        let translated = AIFormattedText(text: "Привет 👋", spans: [.init(id: 0, offset: 7, length: 2, tag: .protected, preserveText: true)])
        for mode in 0 ... 2 {
            try store.set(.integer(Int64(mode)), for: "ai.translatorMode")
            let policy = AITranslationPolicy(store: store)
            XCTAssertEqual(policy.keepsOriginal(manual: true, automatic: false), mode != 0)
            XCTAssertEqual(policy.keepsOriginal(manual: false, automatic: true), mode == 2)
            let output = policy.display(original: original, translated: translated, manual: true, automatic: false)
            if mode == 0 { XCTAssertEqual(output, translated) }
            else {
                XCTAssertEqual(output.text, "Hi 👋" + AITranslationPolicy.separator + "Привет 👋")
                XCTAssertEqual(output.spans.last?.offset, original.text.utf16.count + AITranslationPolicy.separator.utf16.count + 7)
                XCTAssertNotEqual(output.spans.first?.id, output.spans.last?.id)
            }
        }
        XCTAssertTrue(AITranslationPolicy(store: store).canAutomaticallyTranslate(isPremium: false))
        try store.set(.integer(8), for: "ai.translationProvider")
        XCTAssertFalse(AITranslationPolicy(store: store).canAutomaticallyTranslate(isPremium: false))
        XCTAssertTrue(AITranslationPolicy(store: store).canAutomaticallyTranslate(isPremium: true))
        try store.set(.bool(false), for: "ai.telegramUIAutoTranslate")
        XCTAssertFalse(AITranslationPolicy(store: store).canAutomaticallyTranslate(isPremium: true))
    }

    func testMigrationIsIdempotentAndReplaysJournalAfterInterruptedWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIMigration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for legacy in [0, 1, 2, 99] {
            let url = root.appendingPathComponent("legacy-\(legacy).json")
            try Data("{\"TranslatorMode\":\(legacy),\"TranslatorModeWithOriginalMigrated\":false}".utf8).write(to: url)
            let settings = AISettings(store: try ClientSettings(storageURL: url, secretStore: AIFixtureSecretStore()))
            try settings.register()
            let expected = legacy == 0 ? 1 : 0
            XCTAssertEqual(settings.store.integer("ai.translatorMode"), expected)
            try settings.register()
            XCTAssertEqual(settings.store.integer("ai.translatorMode"), expected)
            XCTAssertTrue(settings.store.bool("ai.translatorModeWithOriginalMigrated"))
        }
        let journal = root.appendingPathComponent("journal.json")
        try Data(#"{"ai.translatorMode":1,"ai.translatorModeWithOriginalMigrated":false,"ai.translatorModeMigrationTarget":1}"#.utf8).write(to: journal)
        let restored = AISettings(store: try ClientSettings(storageURL: journal, secretStore: AIFixtureSecretStore()))
        try restored.register()
        XCTAssertEqual(restored.store.integer("ai.translatorMode"), 1)
        XCTAssertEqual(restored.store.value("ai.translatorModeMigrationTarget"), .null)
    }

    func testArticleProviderContextAndFavoritesAreUsedAsPolicies() throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        let store = fixture.settings.store
        try store.set(.integer(10), for: "ai.translationProvider")
        try store.set(.bool(true), for: "ai.llmUseContext")
        var policy = AITranslationPolicy(store: store)
        XCTAssertTrue(policy.usesContext(for: .manual))
        XCTAssertFalse(policy.usesContext(for: .automatic))
        try store.set(.bool(true), for: "ai.llmUseContextInAutoTranslate")
        try store.set(.bool(true), for: "ai.enableSeparateArticleTranslator")
        try store.set(.integer(7), for: "ai.articleTranslationProvider")
        try store.set(.string("fr, ja, fr, pt_BR"), for: "ai.preferredTranslateTargetLang")
        policy = AITranslationPolicy(store: store)
        XCTAssertTrue(policy.usesContext(for: .automatic))
        XCTAssertEqual(policy.provider(for: .manual), .llm)
        XCTAssertEqual(policy.provider(for: .article), .google)
        XCTAssertEqual(Array(policy.languages(defaultLanguage: "en", available: ["ja", "de"]).prefix(4)), ["en", "fr", "ja", "pt-BR"])
        try store.set(.bool(false), for: "ai.enableSeparateArticleTranslator")
        XCTAssertEqual(AITranslationPolicy(store: store).provider(for: .article), .llm)
    }

    func testLanguageChangePreservesUnrelatedRestrictionsAndKeepPreference() throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        var policy = AITranslationPolicy(store: fixture.settings.store)
        XCTAssertEqual(policy.ignoredLanguagesAfterAppLanguageChange(current: ["en", "de"], previous: "en", next: "fr"), ["de", "fr"])
        XCTAssertEqual(policy.ignoredLanguagesAfterAppLanguageChange(current: ["en", "fr"], previous: "en", next: "fr"), ["en", "fr"])
        try fixture.settings.store.set(.bool(true), for: "ai.keepTranslatorPreferences")
        policy = AITranslationPolicy(store: fixture.settings.store)
        XCTAssertEqual(policy.ignoredLanguagesAfterAppLanguageChange(current: ["en", "de"], previous: "en", next: "fr"), ["en", "de"])
    }

    func testComposeTransformationAndUnicodeDifference() {
        let task = AIComposeTask(translateTo: "fr", style: "in a formal tone", emojify: true)
        let prompt = task.prompt(text: "Hello @friend")
        XCTAssertTrue(prompt.contains("Translate the text into French"))
        XCTAssertTrue(prompt.contains("formal tone"))
        XCTAssertTrue(prompt.contains("Add fitting emojis"))
        XCTAssertTrue(prompt.contains("Hello @friend"))
        XCTAssertEqual(AITextDifference.changedRange(original: "a 👋 b", updated: "a 🧑‍💻 b"), 2 ..< 7)
        XCTAssertNil(AITextDifference.changedRange(original: "same", updated: "same"))
    }
}
