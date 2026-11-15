import ExteralessCore
import Foundation
import SwiftSignalKit
import XCTest
@testable import Postbox
@testable import TelegramCore

/// Real in-memory Postbox transactions and native attributes. No Account, Network,
/// credentials, plugins, Telegram requests or secret-chat account is constructed.
final class ExteralessAINativeTests: XCTestCase {
    func testAF01MyCopyProtectionRevokesScopeWithoutMessageVersionChange() throws {
        let db = try AINativePostboxFixture()
        defer { db.close() }
        try db.seed([db.message(1, text: "private source")])
        let scope = try db.scope(1)
        let version = scope.source!.stableVersion
        try db.transaction { transaction in
            transaction.updatePeerCachedData(peerIds: [db.peer]) { _, _ in CachedUserData().withUpdatedFlags([.myCopyProtectionEnabled]) }
            XCTAssertEqual(transaction.getMessage(db.id(1))?.stableVersion, version)
            XCTAssertFalse(exteralessAIValidateScope(transaction: transaction, accountId: db.accountId, scope: scope))
        }
        let denied = try db.scope(1)
        XCTAssertFalse(denied.allowsExternalProcessing)
        XCTAssertFalse(denied.allowsCopy)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        db.queue.async { entered.signal(); _ = release.wait(timeout: .now() + 3) }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        let done = expectation(description: "protected queued write checked")
        let disposable = db.postbox.transaction { transaction -> Bool in
            let stored = exteralessAIStoreSummary(transaction: transaction, accountId: db.accountId, scope: scope, summary: .init(text: "late private result", entities: []), toLanguage: nil, canCommit: { true })
            XCTAssertFalse(stored)
            XCTAssertEqual(transaction.getMessage(db.id(1))?.stableVersion, version)
            return stored
        }.start(completed: { done.fulfill() })
        release.signal()
        wait(for: [done], timeout: 3)
        disposable.dispose()
    }

    func testAF02SourceEditKeepsFreshSummaryEligibilityOnly() throws {
        let db = try AINativePostboxFixture()
        defer { db.close() }
        for rich in [false, true] {
            let id: Int32 = rich ? 2 : 1
            let stale = SummarizationMessageAttribute(fromLang: "en", summary: .init(text: "STALE", entities: []), translated: ["fr": .init(text: "STALE FR", entities: [])])
            var old: [MessageAttribute] = [stale, TranslationMessageAttribute(text: "STALE TRANSLATION", entities: [], toLang: "fr")]
            var incoming: [MessageAttribute] = [SummarizationMessageAttribute(fromLang: "es")]
            if rich {
                old.append(RichTextMessageAttribute(instantPage: db.page("old"), fullInstantPage: nil))
                incoming.append(RichTextMessageAttribute(instantPage: db.page("new"), fullInstantPage: nil))
            }
            try db.seed([db.message(id, text: rich ? "" : "old", attributes: old)])
            let updated = db.message(id, text: rich ? "" : "new", attributes: incoming)
            try db.transaction { transaction in
                transaction.updateMessage(db.id(id), update: { .update(mergedServerMessageUpdate(previous: $0, updated: updated)) })
                let message = transaction.getMessage(db.id(id))!
                let summary = message.attributes.first { $0 is SummarizationMessageAttribute } as? SummarizationMessageAttribute
                XCTAssertEqual(summary?.fromLang, "es")
                XCTAssertNil(summary?.summary)
                XCTAssertTrue(summary?.translated.isEmpty == true)
                XCTAssertFalse(message.attributes.contains { $0 is TranslationMessageAttribute })
            }
        }
    }

    func testAF03FullRichCompletionInvalidatesPreviewResultsAndUsesActualVersion() throws {
        let db = try AINativePostboxFixture()
        defer { db.close() }
        let preview = InstantPage(blocks: [.paragraph(.plain("A"))], media: [:], isComplete: false, rtl: false, url: "", views: nil)
        let full = db.page("A + SENTINEL_B")
        try db.seed([db.message(1, text: "", attributes: [RichTextMessageAttribute(instantPage: preview, fullInstantPage: nil), TranslationMessageAttribute(text: "", entities: [], toLang: "fr", instantPage: db.page("old A")), SummarizationMessageAttribute(fromLang: "en", summary: .init(text: "old A", entities: []))])])
        let scope = try db.scope(1)
        let version = scope.source!.stableVersion
        try db.transaction { transaction in
            let result = exteralessAIStoreFullRichSource(transaction: transaction, messageId: db.id(1), expectedVersion: version, fullPage: full, summaryFromLanguage: "en", scope: scope, accountId: db.accountId)
            XCTAssertTrue(result?.instantPage === preview || result?.instantPage == preview)
            XCTAssertEqual(result?.fullInstantPage, full)
            let current = transaction.getMessage(db.id(1))!
            XCTAssertFalse(current.attributes.contains { $0 is TranslationMessageAttribute })
            XCTAssertNil((current.attributes.first { $0 is SummarizationMessageAttribute } as? SummarizationMessageAttribute)?.summary)
            XCTAssertEqual(scope.committedRetryCapability?.expectedStableVersion, current.stableVersion)
            XCTAssertNotEqual(current.stableVersion, version)
        }
        let rich = try XCTUnwrap(scope.source?.richText)
        XCTAssertTrue(ExteralessAIRichSource.wholePage(rich).plainText.contains("SENTINEL_B"))
        let message = scope.source!
        let collapsed = ExteralessAIMessageDisplay.resolve(message: message, accountId: db.accountId, accountPeerId: db.selfPeer, automaticLanguage: nil, richExpanded: false, store: db.settings.store)
        let expanded = ExteralessAIMessageDisplay.resolve(message: message, accountId: db.accountId, accountPeerId: db.selfPeer, automaticLanguage: nil, richExpanded: true, store: db.settings.store)
        XCTAssertFalse(collapsed.text.contains("SENTINEL_B"))
        XCTAssertTrue(expanded.text.contains("SENTINEL_B"))
        let copied = ExteralessAIMessageDisplay.resolve(message: message, accountId: db.accountId, accountPeerId: db.selfPeer, automaticLanguage: nil, displayedRichPage: full, store: db.settings.store)
        XCTAssertEqual(copied.page, expanded.page)
        let staleVersion = scope.source!.stableVersion
        try db.transaction { transaction in
            XCTAssertTrue(exteralessAIStoreTranslation(transaction: transaction, accountId: db.accountId, scope: scope, translation: .init(text: "", entities: [], toLang: "fr", instantPage: db.page("translated A+B")), canCommit: { true }))
            let currentVersion = transaction.getMessage(db.id(1))!.stableVersion
            XCTAssertNil(exteralessAIStoreFullRichSource(transaction: transaction, messageId: db.id(1), expectedVersion: staleVersion, fullPage: db.page("wrong late replacement"), summaryFromLanguage: nil, scope: nil, accountId: db.accountId))
            XCTAssertNotNil(exteralessAIStoreFullRichSource(transaction: transaction, messageId: db.id(1), expectedVersion: currentVersion, fullPage: db.page("A + NEW_C"), summaryFromLanguage: "en", scope: nil, accountId: db.accountId))
            XCTAssertFalse(transaction.getMessage(db.id(1))!.attributes.contains { $0 is TranslationMessageAttribute })
        }
        let cancelled = try db.scope(1)
        let cancelledVersion = cancelled.source!.stableVersion
        cancelled.lease.cancel()
        try db.transaction { transaction in
            XCTAssertNil(exteralessAIStoreFullRichSource(transaction: transaction, messageId: db.id(1), expectedVersion: cancelledVersion, fullPage: db.page("cancelled"), summaryFromLanguage: nil, scope: cancelled, accountId: db.accountId))
            XCTAssertEqual(transaction.getMessage(db.id(1))?.stableVersion, cancelledVersion)
            XCTAssertNil(cancelled.committedRetryCapability)
        }
    }

    func testAF05NilAutoTargetUsesEnglishForNativeDisplayAndCannotHideAuto() throws {
        let db = try AINativePostboxFixture()
        defer { db.close() }
        try db.settings.store.set(.integer(0), for: "ai.translatorMode")
        let policy = AITranslationPolicy(store: db.settings.store)
        let target = AINativeTranslationTarget.resolve(isEnabled: true, toLanguage: nil, appLanguage: "en", isPremium: false, peerAutoTranslate: false, policy: policy)
        XCTAssertEqual(target, "en")
        try db.seed([db.message(1, text: "original", attributes: [TranslationMessageAttribute(text: "ENGLISH", entities: [], toLang: "en")])])
        let message = try db.transaction { EngineMessage($0.getMessage(db.id(1))!) }
        let display = ExteralessAIMessageDisplay.resolve(message: message, accountId: db.accountId, accountPeerId: db.selfPeer, automaticLanguage: target, store: db.settings.store)
        XCTAssertEqual(display.text, "ENGLISH") // The shared renderer/Copy/AI/Speak projection.
        XCTAssertEqual(display.selection.origin, .automatic)
        let scope = try db.scope(1)
        XCTAssertTrue(try db.transaction {
            exteralessAIStoreTranslation(transaction: $0, accountId: db.accountId, scope: scope, translation: .init(text: "FRANCAIS", entities: [], toLang: "fr"), canCommit: { true })
        })
        let key = AIManualTranslations.messageKey(peerId: db.peer.toInt64(), namespace: message.id.namespace, id: message.id.id)
        try AIManualTranslations.set(.init(language: "fr"), accountId: String(db.accountId), messageKey: key, store: db.settings.store)
        let manual = ExteralessAIMessageDisplay.resolve(message: try XCTUnwrap(scope.source), accountId: db.accountId, accountPeerId: db.selfPeer, automaticLanguage: target, store: db.settings.store)
        XCTAssertEqual(manual.text, "FRANCAIS")
        XCTAssertFalse(manual.selection.canHideManual)
        try AIManualTranslations.set(.init(language: "fr", visible: false), accountId: String(db.accountId), messageKey: key, store: db.settings.store)
        XCTAssertTrue(try db.transaction {
            exteralessAIStoreTranslation(transaction: $0, accountId: db.accountId, scope: scope, translation: .init(text: "ENGLISH", entities: [], toLang: "en"), canCommit: { true })
        })
        let after = ExteralessAIMessageDisplay.resolve(message: try XCTUnwrap(scope.source), accountId: db.accountId, accountPeerId: db.selfPeer, automaticLanguage: target, store: db.settings.store)
        XCTAssertEqual(after.text, "ENGLISH")
        XCTAssertFalse(after.selection.canHideManual)
        try db.settings.store.set(.bool(false), for: "ai.telegramUIAutoTranslate")
        let disabled = AINativeTranslationTarget.resolve(isEnabled: true, toLanguage: nil, appLanguage: "en", isPremium: true, peerAutoTranslate: true, policy: AITranslationPolicy(store: db.settings.store))
        XCTAssertNil(disabled)
        let original = ExteralessAIMessageDisplay.resolve(message: message, accountId: db.accountId, accountPeerId: db.selfPeer, automaticLanguage: disabled, store: db.settings.store)
        XCTAssertEqual(original.text, "original")
    }

    func testInstantViewVisibilityUsesExactNativeTopLevelBlockquoteCaption() {
        let summary = InstantPageBlock.blockQuote(blocks: [.paragraph(.plain("summary body"))], caption: .bold(.plain("Cocoon AI Summary")), collapsed: false)
        XCTAssertTrue(ExteralessAIVisibility.shouldHideInstantViewBlock(summary, hideSummary: true))
        XCTAssertFalse(ExteralessAIVisibility.shouldHideInstantViewBlock(summary, hideSummary: false))
        let ordinary = InstantPageBlock.blockQuote(blocks: [.paragraph(.plain("quoted body"))], caption: .plain("Other caption"), collapsed: false)
        let nearMatch = InstantPageBlock.blockQuote(blocks: [], caption: .plain("Cocoon AI Summary "), collapsed: false)
        let pullQuote = InstantPageBlock.pullQuote(text: .plain("quoted body"), caption: .plain("Cocoon AI Summary"))
        let nested = InstantPageBlock.details(title: .plain("details"), blocks: [summary], expanded: true)
        for block in [ordinary, nearMatch, pullQuote, nested] {
            XCTAssertFalse(ExteralessAIVisibility.shouldHideInstantViewBlock(block, hideSummary: true))
        }
    }

    func testNativeSpeechFallbackGatePreservesRealErrorsAndCancelsWholeTransactionBody() throws {
        let db = try AINativePostboxFixture()
        defer { db.close() }
        let file = db.voice(300)
        let resource = EngineMediaResource.Id(file.resource.id)
        try db.seed([db.message(1, text: "", media: [file])])
        let scope = try db.scope(1)
        var commits = 0
        try db.transaction { transaction in
            let result = exteralessAICommitNativeAudio(transaction: transaction, scope: scope, messageId: db.id(1), expectedResourceId: resource) {
                commits += 1
                return .error
            }
            guard case .error = result else { return XCTFail("Native failure became typed success") }
        }
        XCTAssertEqual(commits, 1)
        scope.lease.cancel()
        try db.transaction { transaction in
            let result = exteralessAICommitNativeAudio(transaction: transaction, scope: scope, messageId: db.id(1), expectedResourceId: resource) {
                commits += 1
                transaction.updateMessage(db.id(1), update: { _ in .update(db.message(1, text: "late mutation", media: [file])) })
                return .success
            }
            guard case .error = result else { return XCTFail("Cancelled native callback succeeded") }
            XCTAssertEqual(transaction.getMessage(db.id(1))?.text, "")
        }
        XCTAssertEqual(commits, 1)
    }

    func testSummaryOffOnOrdersCancelAWithoutRetiringB() throws {
        let db = try AINativePostboxFixture()
        defer { db.close() }
        for aFirst in [false, true] {
            let id: Int32 = aFirst ? 2 : 1
            try db.seed([db.message(id, text: "summarize me")])
            let requests = AINativeOperationRegistry<Int32>()
            let a = try db.scope(id)
            let generationA = requests.begin(id)
            requests.bind(id, generation: generationA, cancel: { a.lease.cancel() })
            requests.cancel(id) // The real off action disposes A.
            let b = try db.scope(id)
            let generationB = requests.begin(id)
            func finishA() throws {
                let committed = try db.transaction { exteralessAIStoreSummary(transaction: $0, accountId: db.accountId, scope: a, summary: .init(text: "A", entities: []), toLanguage: nil, canCommit: { true }) }
                XCTAssertFalse(committed)
                XCTAssertFalse(requests.finish(id, generation: generationA))
            }
            if aFirst { try finishA() }
            let committed = try db.transaction { exteralessAIStoreSummary(transaction: $0, accountId: db.accountId, scope: b, summary: .init(text: "B", entities: []), toLanguage: nil, canCommit: { true }) }
            XCTAssertTrue(committed)
            let validAfterCommit = try db.transaction { exteralessAIValidateScope(transaction: $0, accountId: db.accountId, scope: b) }
            XCTAssertTrue(validAfterCommit) // Actual Postbox version, across transactions.
            XCTAssertTrue(requests.finish(id, generation: generationB))
            if !aFirst { try finishA() }
            let stored = try db.transaction { ($0.getMessage(db.id(id))!.attributes.first { $0 is SummarizationMessageAttribute } as? SummarizationMessageAttribute)?.summary?.text }
            XCTAssertEqual(stored, "B")
        }
    }

    func testManualVisibleTextAndEntityOffsetsAreTheNativeCopyAndAIInputSnapshot() throws {
        let db = try AINativePostboxFixture()
        defer { db.close() }
        let original = "👋 original"
        let translated = "👋 traduit"
        let entity = MessageTextEntity(range: 3 ..< 10, type: .TextUrl(url: "https://fixture.invalid"))
        try db.seed([db.message(1, text: original, attributes: [TextEntitiesMessageAttribute(entities: [entity]), TranslationMessageAttribute(text: translated, entities: [.init(range: 3 ..< 10, type: entity.type)], toLang: "fr")])])
        try AIManualTranslations.set(.init(language: "fr"), accountId: String(db.accountId), messageKey: AIManualTranslations.messageKey(peerId: db.peer.toInt64(), namespace: Namespaces.Message.Cloud, id: 1), store: db.settings.store)
        let message = try db.transaction { EngineMessage($0.getMessage(db.id(1))!) }
        for mode in 0 ... 2 {
            try db.settings.store.set(.integer(Int64(mode)), for: "ai.translatorMode")
            let display = ExteralessAIMessageDisplay.resolve(message: message, accountId: db.accountId, accountPeerId: db.selfPeer, automaticLanguage: nil, store: db.settings.store)
            let prefix = mode == 0 ? "" : original + AITranslationPolicy.separator
            XCTAssertEqual(display.text, prefix + translated)
            XCTAssertEqual(display.entities.last?.range, (prefix.utf16.count + 3) ..< (prefix.utf16.count + 10))
            XCTAssertFalse(display.isTranslating)
            XCTAssertTrue(display.selection.canHideManual)
            let auto = ExteralessAIMessageDisplay.resolve(message: message, accountId: db.accountId, accountPeerId: db.selfPeer, automaticLanguage: "fr", store: db.settings.store)
            XCTAssertFalse(auto.selection.canHideManual)
        }
    }

    func testProtectedReplyPrivateCachedProtectionAndSourceLeaseRevalidation() throws {
        let db = try AINativePostboxFixture()
        defer { db.close() }
        let child = db.message(3, text: "allowed child", reply: db.id(2))
        try db.seed([db.message(1, text: "older allowed"), db.message(2, text: "PROTECTED REPLY", protected: true), child])
        let scope = try db.scope(3, limit: 5)
        XCTAssertTrue(scope.allowsExternalProcessing)
        XCTAssertTrue(scope.contextMessages.isEmpty)
        let before = scope.expectedVersions
        try db.transaction { transaction in
            transaction.updatePeerCachedData(peerIds: [db.peer]) { _, _ in CachedUserData().withUpdatedFlags([.copyProtectionEnabled]) }
        }
        // CachedUserData changes without changing the message flag or version.
        try db.transaction { transaction in
            XCTAssertEqual(transaction.getMessage(db.id(3))?.stableVersion, before[db.id(3)])
            XCTAssertFalse(exteralessAIValidateScope(transaction: transaction, accountId: db.accountId, scope: scope))
            XCTAssertFalse(exteralessAIStoreSummary(transaction: transaction, accountId: db.accountId, scope: scope, summary: .init(text: "must not publish", entities: []), toLanguage: nil, canCommit: { true }))
        }
        let protected = try db.scope(3)
        XCTAssertFalse(protected.allowsExternalProcessing)
        XCTAssertFalse(protected.allowsCopy)
        try db.transaction { transaction in
            transaction.updatePeerCachedData(peerIds: [db.peer]) { _, _ in CachedUserData() }
        }
        XCTAssertFalse(protected.allowsCopy) // A denied capability cannot revive.
    }

    func testContextScopeRejectsForeignPeerThreadAndSecretIdsAndBoundsEmptyChain() throws {
        let db = try AINativePostboxFixture()
        defer { db.close() }
        let foreign = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(9002))
        let secret = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(9003))
        try db.seed([
            db.message(1, text: "NOT VISITED"),
            db.message(2, text: "", reply: db.id(1)),
            db.message(3, text: "", reply: db.id(2)),
            db.message(4, text: "child", reply: db.id(3)),
            db.message(5, text: "wrong thread", thread: 77),
            db.message(6, text: "FOREIGN", peer: foreign),
            db.message(7, text: "SECRET", peer: secret)
        ])
        XCTAssertTrue(try db.scope(4, limit: 2).contextMessages.isEmpty)
        let filtered = try db.scope(4, limit: 5, followReplies: false, explicit: [db.id(5), db.id(6, peer: foreign), db.id(7, peer: secret), db.id(1)])
        XCTAssertEqual(filtered.contextMessages.map(\.text), ["NOT VISITED"])
        try db.transaction { transaction in
            XCTAssertFalse(exteralessAIValidateScope(transaction: transaction, accountId: db.accountId + 1, scope: filtered))
        }
        let source = try db.scope(7, peer: secret)
        XCTAssertFalse(source.allowsExternalProcessing)
    }

    func testReplyProtectionChangeAfterAcquisitionBlocksCommitAndCopyValidation() throws {
        let db = try AINativePostboxFixture()
        defer { db.close() }
        try db.seed([db.message(1, text: "context"), db.message(2, text: "child", reply: db.id(1))])
        let scope = try db.scope(2, limit: 1)
        XCTAssertEqual(scope.contextMessages.map(\.text), ["context"])
        try db.transaction { transaction in
            transaction.updateMessage(db.id(1), update: { _ in .update(db.message(1, text: "context", protected: true)) })
            XCTAssertFalse(exteralessAIValidateScope(transaction: transaction, accountId: db.accountId, scope: scope))
            XCTAssertFalse(exteralessAIStoreTranslation(transaction: transaction, accountId: db.accountId, scope: scope, translation: .init(text: "forbidden late result", entities: [], toLang: "fr"), canCommit: { true }))
            XCTAssertFalse(transaction.getMessage(db.id(2))!.attributes.contains { $0 is TranslationMessageAttribute })
        }
    }

    func testSpeechQueuedTransactionCancellationResourceVersionAndLaterTranscript() throws {
        let db = try AINativePostboxFixture()
        defer { db.close() }
        let file = db.voice(100)
        let resource = EngineMediaResource.Id(file.resource.id)
        try db.seed([db.message(1, text: "", media: [file])])
        let scope = try db.scope(1)
        let initial = scope.expectedVersions[db.id(1)]
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        db.queue.async { entered.signal(); _ = release.wait(timeout: .now() + 3) }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        let closed = expectation(description: "queued closure actually executed")
        let disposable = db.postbox.transaction { transaction -> Bool in
            let result = exteralessAIStoreTranscription(transaction: transaction, accountId: db.accountId, scope: scope, expectedResourceId: resource, text: "late A")
            closed.fulfill()
            return result
        }.start(next: { XCTAssertFalse($0) })
        // Disposing the signal is insufficient; the production lease revokes the
        // already queued closure. Assert the closure ran and made zero mutations.
        scope.lease.cancel()
        disposable.dispose()
        release.signal()
        wait(for: [closed], timeout: 3)
        try db.transaction { transaction in
            XCTAssertEqual(transaction.getMessage(db.id(1))?.stableVersion, initial)
            XCTAssertFalse(transaction.getMessage(db.id(1))!.attributes.contains { $0 is AudioTranscriptionMessageAttribute })
        }
        let old = try db.scope(1)
        try db.transaction { $0.updateMessage(db.id(1), update: { _ in .update(db.message(1, text: "", media: [db.voice(101)])) }) }
        let fresh = try db.scope(1)
        try db.transaction { transaction in
            XCTAssertFalse(exteralessAIStoreTranscription(transaction: transaction, accountId: db.accountId, scope: old, expectedResourceId: resource, text: "old version"))
            // A matching current version does not bypass resource identity.
            XCTAssertFalse(exteralessAIStoreTranscription(transaction: transaction, accountId: db.accountId, scope: fresh, expectedResourceId: resource, text: "wrong media"))
        }
        let late = try db.scope(1)
        let currentResource = EngineMediaResource.Id(db.voice(101).resource.id)
        try db.transaction { transaction in
            XCTAssertTrue(exteralessAIStoreTranscription(transaction: transaction, accountId: db.accountId, scope: fresh, expectedResourceId: currentResource, text: "B wins"))
            XCTAssertFalse(exteralessAIStoreTranscription(transaction: transaction, accountId: db.accountId, scope: late, expectedResourceId: currentResource, text: "A late"))
            XCTAssertEqual((transaction.getMessage(db.id(1))!.attributes.first { $0 is AudioTranscriptionMessageAttribute } as? AudioTranscriptionMessageAttribute)?.text, "B wins")
        }
    }

    func testCommittedRichTranslationIsInvalidatedByActualRichOnlyServerEdit() throws {
        let db = try AINativePostboxFixture()
        defer { db.close() }
        let original = RichTextMessageAttribute(instantPage: db.page("old page"), fullInstantPage: nil)
        try db.seed([db.message(1, text: "", attributes: [original])])
        let scope = try db.scope(1)
        try db.transaction { transaction in
            XCTAssertTrue(exteralessAIStoreTranslation(transaction: transaction, accountId: db.accountId, scope: scope, translation: .init(text: "", entities: [], toLang: "fr", instantPage: db.page("ancienne page")), canCommit: { true }))
            let stored = transaction.getMessage(db.id(1))!
            XCTAssertEqual(scope.expectedVersions[stored.id], stored.stableVersion)
            let edit = db.message(1, text: "", attributes: [RichTextMessageAttribute(instantPage: db.page("new page"), fullInstantPage: nil)])
            transaction.updateMessage(stored.id, update: { current in .update(mergedServerMessageUpdate(previous: current, updated: edit)) })
            let updated = transaction.getMessage(stored.id)!
            XCTAssertNotEqual(updated.stableVersion, stored.stableVersion)
            XCTAssertFalse(updated.attributes.contains { $0 is TranslationMessageAttribute })
            let display = ExteralessAIMessageDisplay.resolve(message: EngineMessage(updated), accountId: db.accountId, accountPeerId: db.selfPeer, automaticLanguage: "fr", store: db.settings.store)
            XCTAssertEqual(display.page?.plainText, db.page("new page").plainText)
            XCTAssertTrue(display.isTranslating) // No stale attribute blocks auto acquisition.
        }
    }

    func testManualSummaryBothOrdersRemainSummaryAndPreserveUTF16Entities() throws {
        let db = try AINativePostboxFixture()
        defer { db.close() }
        let original = SummarizationMessageAttribute.Summary(text: "👋 short", entities: [.init(range: 3 ..< 8, type: .Bold)])
        let translated = SummarizationMessageAttribute.Summary(text: "👋 bref", entities: [.init(range: 3 ..< 7, type: .TextUrl(url: "https://fixture.invalid"))])
        for translateFirst in [false, true] {
            let id: Int32 = translateFirst ? 2 : 1
            try db.seed([db.message(id, text: "long original text")])
            let scope = try db.scope(id)
            try db.transaction { transaction in
                if !translateFirst {
                    XCTAssertTrue(exteralessAIStoreSummary(transaction: transaction, accountId: db.accountId, scope: scope, summary: original, toLanguage: nil, canCommit: { true }))
                }
                XCTAssertTrue(exteralessAIStoreTranslation(transaction: transaction, accountId: db.accountId, scope: scope, translation: .init(text: "full translation must not display", entities: [], toLang: "fr"), translatedSummary: translateFirst ? nil : translated, canCommit: { true }))
                if translateFirst {
                    XCTAssertTrue(exteralessAIStoreSummary(transaction: transaction, accountId: db.accountId, scope: scope, summary: original, toLanguage: nil, canCommit: { true }))
                    XCTAssertTrue(exteralessAIStoreSummary(transaction: transaction, accountId: db.accountId, scope: scope, summary: translated, toLanguage: "fr", canCommit: { true }))
                }
            }
            try AIManualTranslations.set(.init(language: "fr"), accountId: String(db.accountId), messageKey: AIManualTranslations.messageKey(peerId: db.peer.toInt64(), namespace: Namespaces.Message.Cloud, id: id), store: db.settings.store)
            let message = try db.transaction { EngineMessage($0.getMessage(db.id(id))!) }
            for mode in 0 ... 2 {
                try db.settings.store.set(.integer(Int64(mode)), for: "ai.translatorMode")
                let display = ExteralessAIMessageDisplay.resolve(message: message, accountId: db.accountId, accountPeerId: db.selfPeer, automaticLanguage: nil, isSummarized: true, store: db.settings.store)
                XCTAssertTrue(display.isSummary)
                XCTAssertFalse(display.isTranslating)
                XCTAssertEqual(display.selection.language, "fr")
                let prefix = mode == 0 ? "" : original.text + AITranslationPolicy.separator
                XCTAssertEqual(display.text, prefix + translated.text)
                XCTAssertEqual(display.entities.last?.range, (prefix.utf16.count + 3) ..< (prefix.utf16.count + 7))
            }
        }
    }

    func testQuizExplanationUsesEffectiveLanguageAndPreservesSolutionMedia() throws {
        let db = try AINativePostboxFixture()
        defer { db.close() }
        let media = db.voice(200)
        let poll = TelegramMediaPoll(pollId: MediaId(namespace: Namespaces.Media.CloudPoll, id: 1), publicity: .anonymous, kind: .quiz(multipleAnswers: false), text: "question", textEntities: [], options: [TelegramMediaPollOption(text: "answer", entities: [], opaqueIdentifier: Data([1]), date: nil, addedBy: nil)], correctAnswers: nil, results: .init(voters: nil, totalVoters: nil, recentVoters: [], solution: .init(text: "explanation", entities: [], media: media), hasUnseenVotes: nil, canViewStats: false), isClosed: false, deadlineTimeout: nil, deadlineDate: nil, pollHash: 0)
        let translation = TranslationMessageAttribute(text: "QUESTION FR", entities: [], additional: [.init(text: "OPTION FR", entities: [])], pollSolution: .init(text: "👋 SOLUTION FR", entities: [.init(range: 3 ..< 11, type: .Bold)]), toLang: "fr")
        try db.seed([db.message(1, text: "", attributes: [translation], media: [poll])])
        try AIManualTranslations.set(.init(language: "fr"), accountId: String(db.accountId), messageKey: AIManualTranslations.messageKey(peerId: db.peer.toInt64(), namespace: Namespaces.Message.Cloud, id: 1), store: db.settings.store)
        let message = try db.transaction { EngineMessage($0.getMessage(db.id(1))!) }
        let display = ExteralessAIMessageDisplay.resolve(message: message, accountId: db.accountId, accountPeerId: db.selfPeer, automaticLanguage: nil, store: db.settings.store)
        XCTAssertEqual(display.pollTitle?.text, "QUESTION FR")
        XCTAssertEqual(display.pollOptions.first?.text, "OPTION FR")
        XCTAssertEqual(display.pollSolution?.text, "👋 SOLUTION FR")
        XCTAssertEqual(display.pollSolution?.entities.first?.range, 3 ..< 11)
        XCTAssertTrue(display.pollSolution?.media?.isEqual(to: media) == true)
    }
}

private final class AINativePostboxFixture {
    let queue = Queue(name: "AINativePostboxFixture")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-native-" + UUID().uuidString)
    let accountId: Int64 = 9100
    let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(9101))
    let selfPeer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(9100))
    let settings: AISettings
    private var valueBox: SqliteValueBox?
    private(set) var postbox: Postbox!

    init() throws {
        initializeAccountManagement()
        settings = AISettings(store: try ClientSettings(storageURL: root.appendingPathComponent("settings.json"), secretStore: AINativeMemorySecrets()))
        try settings.register()
        try AIManualTranslations.register(accountId: String(accountId), store: settings.store)
        queue.sync {
            self.valueBox = SqliteValueBox(basePath: self.root.path + "/db", queue: self.queue, isTemporary: true, isReadOnly: false, useCaches: true, removeDatabaseOnError: false, encryptionParameters: nil, upgradeProgress: { _ in }, inMemory: true)
        }
        postbox = Postbox(queue: queue, basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration, valueBox: try XCTUnwrap(valueBox), timestampForAbsoluteTimeBasedOperations: 1000, isMainProcess: false, isTemporary: true, tempDir: nil, useCaches: true)
        postbox.mediaBox.fetchResource = { _, _, _ in XCTFail("AI fixture attempted network/media fetch"); return .fail(.generic) }
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
    @discardableResult func transaction<T>(_ body: @escaping (Transaction) -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        var output: T?
        let disposable = postbox.transaction(body).start(next: { output = $0; done.signal() })
        defer { disposable.dispose() }
        guard done.wait(timeout: .now() + 3) == .success else { throw AINativeFixtureError.timeout }
        return try XCTUnwrap(output)
    }
    func id(_ id: Int32, peer: PeerId? = nil) -> MessageId { MessageId(peerId: peer ?? self.peer, namespace: Namespaces.Message.Cloud, id: id) }
    func message(_ id: Int32, text: String, peer: PeerId? = nil, thread: Int64? = nil, reply: MessageId? = nil, protected: Bool = false, attributes: [MessageAttribute] = [], media: [Media] = []) -> StoreMessage {
        let reply: [MessageAttribute] = reply.map { [ReplyMessageAttribute(messageId: $0, threadMessageId: nil, quote: nil, isQuote: false, innerSubject: nil)] } ?? []
        return StoreMessage(id: self.id(id, peer: peer), customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: thread, timestamp: 100 + id, flags: protected ? [.Incoming, .CopyProtected] : [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: peer ?? self.peer, text: text, attributes: attributes + reply, media: media)
    }
    func seed(_ messages: [StoreMessage]) throws {
        try transaction { transaction in
            let user = TelegramUser(id: self.peer, accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
            transaction.updatePeersInternal([user], update: { _, value in value })
            _ = transaction.addMessages(messages, location: .Random)
        }
    }
    func scope(_ id: Int32, peer: PeerId? = nil, limit: Int = 0, followReplies: Bool = true, explicit: [MessageId] = []) throws -> ExteralessAIScope {
        let scope = try transaction { transaction in
            exteralessAIResolveScope(transaction: transaction, accountId: self.accountId, capability: .init(messageId: self.id(id, peer: peer), allowsExternalProcessing: true, allowsCopy: true), contextMessageIds: explicit, followReplyChain: followReplies, contextLimit: limit, lease: AINativeOperationLease())
        }
        return try XCTUnwrap(scope)
    }
    func page(_ text: String) -> InstantPage { InstantPage(blocks: [.paragraph(.plain(text))], media: [:], isComplete: true, rtl: false, url: "", views: nil) }
    func voice(_ id: Int64) -> TelegramMediaFile {
        TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: id), partialReference: nil, resource: LocalFileMediaResource(fileId: id), previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "audio/ogg", size: 4, attributes: [.Audio(isVoice: true, duration: 1, title: nil, performer: nil, waveform: nil)], alternativeRepresentations: [])
    }
}

private enum AINativeFixtureError: Error { case timeout }
private final class AINativeMemorySecrets: ClientSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func data(for key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func set(_ data: Data?, for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = data }
}
