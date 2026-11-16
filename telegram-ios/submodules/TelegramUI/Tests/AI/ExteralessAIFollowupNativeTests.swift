import AccountContext
import AudioTranscriptionButtonComponent
import ComponentFlow
import ExteralessCore
import Foundation
import SwiftSignalKit
import UIKit
import XCTest
@testable import ChatMessageInteractiveInstantVideoNode
@testable import Postbox
@testable import TelegramCore
@testable import TelegramUI

final class ExteralessAIFollowupNativeTests: XCTestCase {
    @MainActor func testAF01ActualResultAccessObserverRevokesCopyAndFurtherExports() async throws {
        let db = try AIFollowupDatabase()
        defer { db.close() }
        let message = try db.message()
        let access = db.access(capability: .message(message, canCopy: true))
        defer { access.onInvalidated = nil; access.cancel() }
        access.begin()
        _ = try await access.resolve()
        let view = ExteralessAIResultTextView()
        view.text = "private fixture"
        view.copyAllowed = access.allowsCopy
        var copies = 0
        view.copySelection = { copies += 1 }
        view.copy(nil)
        XCTAssertEqual(copies, 1)
        let revoked = expectation(description: "actual cached-data observer revoked access")
        access.onInvalidated = {
            view.copyAllowed = access.allowsCopy
            revoked.fulfill()
        }
        let transport = AIFollowupTransport()
        let guarded = ExteralessAIScopedTransport(base: transport, validate: { try await access.validate() })
        var request = URLRequest(url: URL(string: "https://fixture.invalid/body")!)
        request.httpMethod = "POST"
        request.httpBody = Data(message.text.utf8)
        _ = try await guarded.data(for: request)
        try db.transaction { transaction in
            transaction.updatePeerCachedData(peerIds: [db.peer]) { _, _ in CachedUserData().withUpdatedFlags([.myCopyProtectionEnabled]) }
        }
        await waitFor([revoked])
        XCTAssertEqual(try db.message().stableVersion, message.stableVersion)
        XCTAssertFalse(access.allowsCopy)
        view.copy(nil)
        XCTAssertEqual(copies, 1)
        do { _ = try await guarded.data(for: request); XCTFail("protected source exported again") }
        catch { XCTAssertEqual(error as? AIError, .cancelled) }
        XCTAssertEqual(transport.count, 1)
    }

    @MainActor func testAF06RealResultAccessSuccessRetryAndExternalEdit() async throws {
        let db = try AIFollowupDatabase()
        defer { db.close() }
        let initial = try db.message()
        let access = db.access(capability: .message(initial, canCopy: true))
        defer { access.cancel() }
        access.begin()
        let first = try await access.resolve()
        let stored = try db.transaction {
            exteralessAIStoreTranslation(transaction: $0, accountId: db.accountId, scope: first, translation: .init(text: "translated", entities: [], toLang: "en"), canCommit: { true })
        }
        XCTAssertTrue(stored)
        let committed = try db.message().stableVersion
        XCTAssertNotEqual(committed, initial.stableVersion)
        try await access.validate()
        XCTAssertTrue(access.finish())
        XCTAssertFalse(access.finish())
        access.begin() // Real Retry, rather than constructing a capability at V'.
        let retry = try await access.resolve()
        XCTAssertEqual(retry.source?.stableVersion, committed)
        try await access.validate()
        XCTAssertTrue(access.finish())
        try db.transaction { transaction in
            transaction.updateMessage(db.id, update: { _ in .update(db.stored(text: "external edit")) })
        }
        XCTAssertFalse(access.finish()) // Repeated completion learns no new version.
        access.begin()
        do { _ = try await access.resolve(); XCTFail("external edit was treated as own commit") }
        catch { XCTAssertEqual(error as? AIError, .cancelled) }
        XCTAssertFalse(access.allowsCopy)
        XCTAssertFalse(access.finish())
    }

    @MainActor func testAF03FullRichSourceFeedsCopySummaryAndRealTranslationClient() async throws {
        let db = try AIFollowupDatabase()
        defer { db.close() }
        let preview = InstantPage(blocks: [.paragraph(.plain("A"))], media: [:], isComplete: false, rtl: false, url: "", views: nil)
        let full = InstantPage(blocks: [.paragraph(.plain("A")), .paragraph(.plain("SENTINEL_B"))], media: [:], isComplete: true, rtl: false, url: "", views: nil)
        let previewAttribute = RichTextMessageAttribute(instantPage: preview, fullInstantPage: nil)
        try db.transaction { transaction in
            transaction.updateMessage(db.id, update: { _ in
                .update(db.stored(text: "", attributes: [previewAttribute, TranslationMessageAttribute(text: "", entities: [], toLang: "fr", instantPage: preview), SummarizationMessageAttribute(fromLang: "en", summary: .init(text: "old A only", entities: []))]))
            })
        }
        let key = AIManualTranslations.messageKey(peerId: db.peer.toInt64(), namespace: db.id.namespace, id: db.id.id)
        try AIManualTranslations.set(.init(language: "fr"), accountId: String(db.accountId), messageKey: key, store: db.settings.store)
        let initial = try db.message()
        let partial = ExteralessAIMessageDisplay.resolve(message: initial, accountId: db.accountId, accountPeerId: db.selfPeer, automaticLanguage: nil, store: db.settings.store)
        XCTAssertNotNil(partial.translation)
        XCTAssertTrue(ExteralessAIRichSource.needsShowMore(source: previewAttribute, displayedPage: try XCTUnwrap(partial.page)))
        let transport = AIFollowupTransport(response: { request in
            let input = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? "MISSING_SOURCE"
            return try! JSONSerialization.data(withJSONObject: ["sentences": [["trans": "FR:" + input]]])
        })
        let client = AITranslationClient(transport: transport, settings: db.settings)
        let config = AITranslationConfiguration(settings: db.settings)
        do {
            _ = try await ExteralessAIRichTextTranslator.translate(source: previewAttribute, client: client, to: "fr", configuration: config)
            XCTFail("incomplete whole-message source reached the provider")
        } catch { XCTAssertEqual(error as? AIError, .incompleteStream) }
        XCTAssertEqual(transport.count, 0)

        let access = db.access(capability: .message(initial, canCopy: true))
        defer { access.cancel() }
        access.begin()
        let scope = try await access.resolve()
        // The exact completion transaction called by native Show more/getRichMessage.
        let loaded = try db.transaction {
            exteralessAIStoreFullRichSource(transaction: $0, messageId: db.id, expectedVersion: initial.stableVersion, fullPage: full, summaryFromLanguage: "en", scope: scope, accountId: db.accountId)
        }
        let source = try XCTUnwrap(loaded)
        try await access.validate()
        let current = try XCTUnwrap(scope.source)
        XCTAssertFalse(current.attributes.contains { $0 is TranslationMessageAttribute })
        let expanded = ExteralessAIMessageDisplay.resolve(message: current, accountId: db.accountId, accountPeerId: db.selfPeer, automaticLanguage: nil, richExpanded: true, store: db.settings.store)
        let copy = ExteralessAIMessageDisplay.resolve(message: current, accountId: db.accountId, accountPeerId: db.selfPeer, automaticLanguage: nil, displayedRichPage: expanded.page, store: db.settings.store)
        XCTAssertEqual(copy.page, expanded.page)
        XCTAssertTrue(copy.text.contains("SENTINEL_B"))
        let summarySource = try await ExteralessAIRichTextTranslator.markdown(source: source)
        XCTAssertTrue(AITextAction.summarize.prompt(text: summarySource).contains("SENTINEL_B"))
        let translated = try await ExteralessAIRichTextTranslator.translate(source: source, client: client, to: "fr", configuration: config)
        let queries = transport.recordedRequests.compactMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        }
        XCTAssertEqual(Set(queries), Set(["A", "SENTINEL_B"]))
        XCTAssertTrue(translated.isComplete)
        XCTAssertTrue(translated.plainText.contains("FR:SENTINEL_B"))
        XCTAssertFalse(ExteralessAIRichSource.needsShowMore(source: source, displayedPage: translated))
        XCTAssertTrue(try db.transaction {
            exteralessAIStoreTranslation(transaction: $0, accountId: db.accountId, scope: scope, translation: .init(text: "", entities: [], toLang: "fr", instantPage: translated), canCommit: { true })
        })
        try await access.validate()
        XCTAssertTrue(access.finish())
        access.begin()
        let retried = try await access.resolve()
        XCTAssertTrue(retried.source?.richText?.fullInstantPage?.plainText.contains("SENTINEL_B") == true)
        let displayed = ExteralessAIMessageDisplay.resolve(message: try XCTUnwrap(retried.source), accountId: db.accountId, accountPeerId: db.selfPeer, automaticLanguage: nil, richExpanded: true, store: db.settings.store)
        XCTAssertTrue(displayed.page?.isComplete == true)
        XCTAssertTrue(displayed.text.contains("FR:SENTINEL_B"))
    }

    @MainActor func testAF04ActualRoundButtonRoutesSelectedProviderWithoutPremiumGate() async throws {
        for premium in [false, true] {
            for provider in AITranscriptionProvider.allCases {
                let db = try AIFollowupDatabase(voice: true)
                defer { db.close() }
                try db.settings.store.set(.integer(Int64(provider.rawValue)), for: "ai.transcribeProvider")
                var configuration = AITranscriptionConfiguration(settings: db.settings)
                configuration.geminiKey = "fixture-key"
                configuration.openAIKey = "fixture-key"
                configuration.openAIBaseURL = "https://fixture.invalid/v1"
                configuration.openAIModel = "fixture"
                configuration.cloudflareAccountId = String(repeating: "a", count: 32)
                configuration.cloudflareToken = "fixture-key"
                let config = configuration
                let native = provider == .auto && premium
                let expected = provider == .auto ? AITranscriptionProvider.gemini : provider
                let response: String
                switch expected {
                case .gemini: response = #"{"candidates":[{"content":{"parts":[{"text":"fixture transcript"}]},"finishReason":"STOP"}]}"#
                case .workersAI: response = #"{"success":true,"result":{"text":"fixture transcript"}}"#
                default: response = #"{"choices":[{"message":{"role":"assistant","content":"fixture transcript"},"finish_reason":"stop"}]}"#
                }
                let transport = AIFollowupTransport(response: response)
                let speech = ExteralessSpeechService(transport: transport)
                speech.decodeAudio = { _, _ in try AIWaveFile.encode(pcm: Data([0, 0, 1, 0]), sampleRate: 48_000) }
                speech.recognitionOverride = { _, _ in "fixture transcript" }
                let captured = try db.message()
                let node = ChatMessageInteractiveInstantVideoNode()
                var starts = 0
                var nativeGates = 0
                var nativeCalls = 0
                var providers: [AITranscriptionProvider] = []
                let finished = expectation(description: "round button terminal callback")
                // Construct on MainActor; the real producer creates its task/lease on subscription.
                let request = exteralessAINativeRequest(isCurrent: { true }, error: { ExteralessAITranscriptionError.failed(AIError.sanitized($0).description) }) { lease in
                    starts += 1
                    return try await ExteralessAINativeTranscriptionRequest.run(configuration: config, isPremium: premium, telegram: {
                        nativeCalls += 1
                        let capability = ExteralessAIProcessingCapability(messageId: captured.id, expectedStableVersion: captured.stableVersion, allowsExternalProcessing: false, allowsCopy: false)
                        let scope = try db.scope(capability: capability, lease: lease)
                        return try db.transaction { db.storeAudio(transaction: $0, scope: scope, native: true, text: "fixture transcript") }
                    }, provider: { resolved in
                        providers.append(resolved.provider)
                        let scope = try db.scope(capability: .message(captured, canCopy: true), lease: lease)
                        let text = try await speech.transcribe(fileURL: db.root.appendingPathComponent("round.mp4"), locale: "en", configuration: resolved)
                        return try db.transaction { db.storeAudio(transaction: $0, scope: scope, native: false, text: text) }
                    })
                }
                node.aiTranscriptionInputProvider = {
                    .init(identity: db.roundIdentity, existingText: nil, usesSelectedProvider: {
                        ExteralessAIHooks.usesSelectedTranscription(isPremium: premium, store: db.settings.store)
                    }, allowNative: { nativeGates += 1; return premium }, request: { request }, failed: { _ in XCTFail("unexpected failure"); finished.fulfill() }, finished: { finished.fulfill() })
                }
                let button = roundButton(node)
                button.sendActions(for: .touchUpInside)
                await waitFor([finished])
                XCTAssertEqual(starts, 1)
                XCTAssertEqual(nativeGates, native ? 1 : 0)
                XCTAssertEqual(nativeCalls, native ? 1 : 0)
                XCTAssertEqual(providers, native ? [] : [expected])
                XCTAssertEqual(transport.count, native || expected == .apple ? 0 : 1)
                XCTAssertEqual((try db.message().attributes.first { $0 is AudioTranscriptionMessageAttribute } as? AudioTranscriptionMessageAttribute)?.text, "fixture transcript")
                if case .expanded = node.audioTranscriptionState {} else { XCTFail("successful round route did not expand") }
            }
        }
    }

    @MainActor func testAF04RoundButtonCancelReachesQueuedRealPostboxCommit() async throws {
        let db = try AIFollowupDatabase(voice: true)
        defer { db.close() }
        for native in [false, true] {
            try db.settings.store.set(.integer(Int64((native ? AITranscriptionProvider.auto : .apple).rawValue)), for: "ai.transcribeProvider")
            let config = AITranscriptionConfiguration(settings: db.settings)
            let initial = try db.message()
            let capability = ExteralessAIProcessingCapability(messageId: initial.id, expectedStableVersion: initial.stableVersion, allowsExternalProcessing: !native, allowsCopy: !native)
            let scope = try db.scope(capability: capability, lease: AINativeOperationLease())
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            db.queue.async { entered.signal(); _ = release.wait(timeout: .now() + 3) }
            XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
            let enqueued = expectation(description: "round request queued its response transaction")
            let committed = expectation(description: "queued round-video storage body ran")
            let ended = expectation(description: "real request task retired")
            let node = ChatMessageInteractiveInstantVideoNode()
            var starts = 0
            var terminal = 0
            @MainActor func queuedCommit() async throws -> Bool {
                let response = Signal<Bool, NoError> { subscriber in
                    let disposable = db.postbox.transaction { transaction -> Bool in
                        let stored = db.storeAudio(transaction: transaction, scope: scope, native: native, text: "late round result")
                        XCTAssertFalse(stored)
                        committed.fulfill()
                        return stored
                    }.start(next: { subscriber.putNext($0) }, completed: { subscriber.putCompletion() })
                    enqueued.fulfill()
                    return disposable
                }
                return try await ExteralessAISignalOperation<Bool>().value(response)
            }
            let request = exteralessAINativeRequest(lease: scope.lease, isCurrent: { true }, ended: { _ in ended.fulfill() }, error: { ExteralessAITranscriptionError.failed(AIError.sanitized($0).description) }) { _ in
                starts += 1
                return try await ExteralessAINativeTranscriptionRequest.run(configuration: config, isPremium: native, telegram: {
                    XCTAssertTrue(native)
                    return try await queuedCommit()
                }, provider: { selected in
                    XCTAssertFalse(native)
                    XCTAssertEqual(selected.provider, .apple)
                    return try await queuedCommit()
                })
            }
            node.aiTranscriptionInputProvider = {
                .init(identity: db.roundIdentity, existingText: nil, usesSelectedProvider: {
                    ExteralessAIHooks.usesSelectedTranscription(isPremium: native, store: db.settings.store)
                }, allowNative: { XCTAssertTrue(native); return native }, request: { request }, failed: { _ in terminal += 1 }, finished: { terminal += 1 })
            }
            let button = roundButton(node)
            button.sendActions(for: .touchUpInside)
            await waitFor([enqueued])
            node.audioTranscriptionState = .locked // A cached cooldown relayout must not swallow Cancel.
            button.sendActions(for: .touchUpInside)
            XCTAssertTrue(scope.lease.isCancelled)
            release.signal()
            await waitFor([committed, ended])
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(terminal, 0)
            XCTAssertEqual(try db.message().stableVersion, initial.stableVersion)
            XCTAssertFalse(try db.message().attributes.contains { $0 is AudioTranscriptionMessageAttribute })
            let trial = try db.transaction { $0.getPreferencesEntry(key: PreferencesKeys.audioTranscriptionTrialState)?.get(AudioTranscription.TrialState.self) ?? .defaultValue }
            XCTAssertEqual(trial, .defaultValue)
            if case .collapsed = node.audioTranscriptionState {} else { XCTFail("cancelled round route stayed loading") }
        }
    }

    @MainActor func testAIAF01SamePreviewServerEditReloadsFullSourceAndPreservesOwnCommitRetry() async throws {
        for hiddenEditLabel in [false, true] {
            let db = try AIFollowupDatabase()
            defer { db.close() }
            func page(_ texts: [String], complete: Bool = true) -> InstantPage {
                InstantPage(blocks: texts.map { .paragraph(.plain($0)) }, media: [:], isComplete: complete, rtl: false, url: "", views: nil)
            }
            let preview = page(["A"], complete: false)
            let oldFull = page(["A", "OLD_B"])
            let newFull = page(["A", "NEW_C"])
            let oldTranslation = TranslationMessageAttribute(text: "", entities: [], toLang: "fr", instantPage: page(["FR_A", "FR_OLD_B"]))
            let ownTranslation = TranslationMessageAttribute(text: "", entities: [], toLang: "de", instantPage: page(["DE_A", "DE_OLD_B"]))
            try db.transaction { transaction in
                transaction.updateMessage(db.id, update: { _ in .update(db.stored(text: "", attributes: [
                    EditedMessageAttribute(date: 100, isHidden: hiddenEditLabel),
                    RichTextMessageAttribute(instantPage: preview, fullInstantPage: oldFull),
                    oldTranslation,
                    SummarizationMessageAttribute(fromLang: "en", summary: .init(text: "OLD_B summary", entities: []))
                ])) })
            }
            // Positive control: a same-revision partial refresh still reuses the
            // native full cache and translation through both real merge layers.
            let refresh = db.stored(text: "", attributes: [EditedMessageAttribute(date: 100, isHidden: hiddenEditLabel), RichTextMessageAttribute(instantPage: preview, fullInstantPage: nil)])
            try db.transaction { transaction in
                transaction.updateMessage(db.id, update: { .update(mergedServerMessageUpdate(previous: $0, updated: refresh)) })
            }
            let initial = try db.message()
            XCTAssertEqual(initial.richText?.fullInstantPage, oldFull)
            XCTAssertTrue(initial.attributes.contains { $0 is TranslationMessageAttribute })
            let access = db.access(capability: .message(initial, canCopy: true))
            defer { access.cancel() }
            access.begin()
            let scope = try await access.resolve()
            XCTAssertTrue(try db.transaction {
                exteralessAIStoreTranslation(transaction: $0, accountId: db.accountId, scope: scope, translation: ownTranslation, canCommit: { true })
            })
            let ownCommit = try db.message()
            XCTAssertNotEqual(ownCommit.stableVersion, initial.stableVersion)
            XCTAssertEqual((ownCommit.attributes.first { $0 is EditedMessageAttribute } as? EditedMessageAttribute)?.date, 100)
            XCTAssertEqual(ownCommit.richText?.fullInstantPage, oldFull)
            try await access.validate()
            XCTAssertTrue(access.finish())
            access.begin() // Actual AF-06 Retry; the UI learns no version from this test.
            let retry = try await access.resolve()
            XCTAssertEqual(retry.source?.stableVersion, ownCommit.stableVersion)

            let incoming = db.stored(text: "", attributes: [
                EditedMessageAttribute(date: 101, isHidden: hiddenEditLabel),
                RichTextMessageAttribute(instantPage: preview, fullInstantPage: nil),
                SummarizationMessageAttribute(fromLang: "es")
            ])
            try db.transaction { transaction in
                transaction.updateMessage(db.id, update: { .update(mergedServerMessageUpdate(previous: $0, updated: incoming)) })
                XCTAssertFalse(exteralessAIValidateScope(transaction: transaction, accountId: db.accountId, scope: retry))
            }
            let edited = try db.message() // After MessageHistoryTable's actual Seed merge.
            XCTAssertEqual(edited.richText?.instantPage, preview)
            XCTAssertNil(edited.richText?.fullInstantPage)
            XCTAssertFalse(edited.attributes.contains { $0 is TranslationMessageAttribute })
            XCTAssertEqual((edited.attributes.first { $0 is EditedMessageAttribute } as? EditedMessageAttribute)?.date, 101)
            let eligibility = try XCTUnwrap(edited.attributes.first { $0 is SummarizationMessageAttribute } as? SummarizationMessageAttribute)
            XCTAssertEqual(eligibility.fromLang, "es")
            XCTAssertNil(eligibility.summary)
            XCTAssertTrue(eligibility.translated.isEmpty)
            access.begin()
            do { _ = try await access.resolve(); XCTFail("server edit reused an own-commit receipt") }
            catch { XCTAssertEqual(error as? AIError, .cancelled) }

            let readyAccess = db.access(capability: .message(edited, canCopy: true))
            defer { readyAccess.cancel() }
            readyAccess.begin()
            let readyScope = try await readyAccess.resolve()
            let currentRich = try XCTUnwrap(readyScope.source?.richText)
            var fullFetches = 0
            // The production admission predicate must now request full content.
            // Only native I/O is injected; completion and lease/version checks are real.
            if !ExteralessAIRichSource.wholePage(currentRich).isComplete {
                try await readyAccess.validate()
                fullFetches += 1
                let version = try XCTUnwrap(readyScope.source?.stableVersion)
                let loaded = try await ExteralessAISignalOperation<RichTextMessageAttribute?>().value(db.postbox.transaction {
                    exteralessAIStoreFullRichSource(transaction: $0, messageId: db.id, expectedVersion: version, fullPage: newFull, summaryFromLanguage: "es", scope: readyScope, accountId: db.accountId)
                })
                XCTAssertEqual(loaded?.fullInstantPage, newFull)
            }
            XCTAssertEqual(fullFetches, 1)
            try await readyAccess.validate()
            let completeSource = try XCTUnwrap(readyScope.source?.richText)
            let aiInput = try await ExteralessAIRichTextTranslator.markdown(source: completeSource)
            XCTAssertTrue(aiInput.contains("NEW_C"))
            XCTAssertFalse(aiInput.contains("OLD_B"))
            let transport = AIFollowupTransport(response: { request in
                let input = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? "MISSING_SOURCE"
                return try! JSONSerialization.data(withJSONObject: ["sentences": [["trans": "FR:" + input]]])
            })
            let client = AITranslationClient(transport: ExteralessAIScopedTransport(base: transport, validate: { try await readyAccess.validate() }), settings: db.settings)
            let translated = try await ExteralessAIRichTextTranslator.translate(source: completeSource, client: client, to: "fr", configuration: AITranslationConfiguration(settings: db.settings))
            let inputs = transport.recordedRequests.compactMap { request in
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
            }
            XCTAssertEqual(Set(inputs), Set(["A", "NEW_C"]))
            XCTAssertTrue(translated.isComplete)
            XCTAssertTrue(try db.transaction {
                exteralessAIStoreTranslation(transaction: $0, accountId: db.accountId, scope: readyScope, translation: .init(text: "", entities: [], toLang: "fr", instantPage: translated), canCommit: { true })
            })
            try await readyAccess.validate()
            XCTAssertTrue(readyAccess.finish())
            readyAccess.begin()
            let readyRetry = try await readyAccess.resolve()
            XCTAssertEqual(readyRetry.source?.richText?.fullInstantPage, newFull)
            XCTAssertEqual((readyRetry.source?.attributes.first { $0 is EditedMessageAttribute } as? EditedMessageAttribute)?.date, 101)
        }
    }

    @MainActor private func waitFor(_ expectations: [XCTestExpectation]) async {
        let result = await XCTWaiter.fulfillment(of: expectations, timeout: 3)
        XCTAssertEqual(result, .completed)
    }

    @MainActor private func roundButton(_ node: ChatMessageInteractiveInstantVideoNode) -> AudioTranscriptionButtonComponent.View {
        let host = ComponentHostView<Empty>()
        node.audioTranscriptionButton = host
        node.view.addSubview(host)
        _ = host.update(transition: ComponentTransition(animation: .none), component: AnyComponent(node.aiTranscriptionButtonComponent(theme: .custom(.black, .white), transcriptionState: .collapsed)), environment: {}, containerSize: CGSize(width: 30, height: 30))
        return host.componentView as! AudioTranscriptionButtonComponent.View
    }
}

private final class AIFollowupDatabase: @unchecked Sendable {
    let queue = Queue(name: "AIFollowupDatabase")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-followup-" + UUID().uuidString)
    let accountId: Int64 = 9200
    let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(9201))
    let selfPeer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(9200))
    var id: MessageId { MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: 1) }
    let file = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: 1), partialReference: nil, resource: LocalFileMediaResource(fileId: 92001), previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "video/mp4", size: 4, attributes: [.Video(duration: 1, size: PixelDimensions(width: 32, height: 32), flags: [.instantRoundVideo], preloadSize: nil, coverTime: nil, videoCodec: nil)], alternativeRepresentations: [])
    var roundIdentity: ChatMessageInteractiveInstantVideoNode.AITranscriptionIdentity { .init(accountId: accountId, messageId: id, resourceId: EngineMediaResource.Id(file.resource.id)) }
    let settings: AISettings
    private var valueBox: SqliteValueBox?
    private(set) var postbox: Postbox!

    init(voice: Bool = false) throws {
        initializeAccountManagement()
        settings = AISettings(store: try ClientSettings(storageURL: root.appendingPathComponent("settings.json"), secretStore: AIFollowupMemorySecrets()))
        try settings.register()
        try AIManualTranslations.register(accountId: String(accountId), store: settings.store)
        queue.sync {
            self.valueBox = SqliteValueBox(basePath: self.root.path + "/db", queue: self.queue, isTemporary: true, isReadOnly: false, useCaches: true, removeDatabaseOnError: false, encryptionParameters: nil, upgradeProgress: { _ in }, inMemory: true)
        }
        postbox = Postbox(queue: queue, basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration, valueBox: try XCTUnwrap(valueBox), timestampForAbsoluteTimeBasedOperations: 1000, isMainProcess: false, isTemporary: true, tempDir: nil, useCaches: true)
        postbox.mediaBox.fetchResource = { _, _, _ in XCTFail("follow-up fixture attempted media/network fetch"); return .fail(.generic) }
        try transaction { transaction in
            let user = TelegramUser(id: self.peer, accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
            transaction.updatePeersInternal([user], update: { _, value in value })
            _ = transaction.addMessages([self.stored(text: voice ? "" : "private fixture", media: voice ? [self.file] : [])], location: .Random)
        }
    }
    func stored(text: String, attributes: [MessageAttribute] = [], media: [Media] = []) -> StoreMessage {
        StoreMessage(id: id, customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: 100, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: peer, text: text, attributes: attributes, media: media)
    }
    @discardableResult func transaction<T>(_ body: @escaping (Transaction) -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        var value: T?
        let disposable = postbox.transaction(body).start(next: { value = $0; done.signal() })
        defer { disposable.dispose() }
        guard done.wait(timeout: .now() + 3) == .success else { throw AIError.timeout }
        return try XCTUnwrap(value)
    }
    func message() throws -> EngineMessage { try transaction { EngineMessage($0.getMessage(self.id)!) } }
    func scope(capability: ExteralessAIProcessingCapability, lease: AINativeOperationLease) throws -> ExteralessAIScope {
        let value = try transaction { exteralessAIResolveScope(transaction: $0, accountId: self.accountId, capability: capability, contextMessageIds: [], followReplyChain: false, contextLimit: 0, lease: lease) }
        guard let value else { throw AIError.cancelled }
        return value
    }
    @MainActor func access(capability: ExteralessAIProcessingCapability) -> ExteralessAIResultAccess {
        ExteralessAIResultAccess(capability: capability, resolve: { capability, _, _, _, lease in
            let scope = try self.scope(capability: capability, lease: lease)
            guard scope.allowsExternalProcessing else { throw AIError.cancelled }
            return scope
        }, validate: { scope in
            let valid = try self.transaction { exteralessAIValidateScope(transaction: $0, accountId: self.accountId, scope: scope) }
            guard valid else { scope.lease.cancel(); throw AIError.cancelled }
        }, observe: { exteralessAIObserveScopeValidity(postbox: self.postbox, accountId: self.accountId, scope: $0) })
    }
    func storeAudio(transaction: Transaction, scope: ExteralessAIScope, native: Bool, text: String) -> Bool {
        let resource = EngineMediaResource.Id(file.resource.id)
        if !native { return exteralessAIStoreTranscription(transaction: transaction, accountId: accountId, scope: scope, expectedResourceId: resource, text: text) }
        let result = exteralessAICommitNativeAudio(transaction: transaction, scope: scope, messageId: id, expectedResourceId: resource) {
            _internal_updateAudioTranscriptionTrialState(transaction: transaction) { $0.withUpdatedRemainingCount(0) }
            transaction.updateMessage(self.id, update: { current in
                let attributes: [MessageAttribute] = [AudioTranscriptionMessageAttribute(id: 1, text: text, isPending: false, didRate: false, error: nil)]
                return .update(exteralessAIMessageWithAttributes(current, attributes: attributes))
            })
            return .success
        }
        if case .success = result { return true }
        return false
    }
    func close() {
        let ready = DispatchSemaphore(value: 0)
        let disposable = postbox.mediaBox.storageBox.totalSize().start(next: { _ in ready.signal() })
        XCTAssertEqual(ready.wait(timeout: .now() + 3), .success)
        disposable.dispose()
        postbox = nil
        queue.sync { self.valueBox = nil }
        try? FileManager.default.removeItem(at: root)
    }
}

private final class AIFollowupTransport: AIHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private let response: @Sendable (URLRequest) -> Data
    init(response: String = "fixture") { self.response = { _ in Data(response.utf8) } }
    init(response: @escaping @Sendable (URLRequest) -> Data) { self.response = response }
    var recordedRequests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    var count: Int { recordedRequests.count }
    func events(for request: URLRequest, maximumBytes: Int, timeout: TimeInterval) -> AsyncThrowingStream<AIHTTPEvent, Error> {
        lock.lock(); requests.append(request); lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.response(status: 200, headers: [:]))
            continuation.yield(.data(response(request)))
            continuation.finish()
        }
    }
}

private final class AIFollowupMemorySecrets: ClientSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func data(for key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func set(_ data: Data?, for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = data }
}
