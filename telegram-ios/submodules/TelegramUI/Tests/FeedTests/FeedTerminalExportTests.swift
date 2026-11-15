import AccountContext
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit
import XCTest
@testable import SaveToCameraRoll
@testable import ShareController

private final class FeedCameraRollSinkFixture {
    let permit: ExteralessContentExportPermit
    var permission: ((Bool) -> Void)?
    var prepared: ((ExteralessCameraRollPrepared?) -> Void)?
    var commit: ((() -> Void) -> Bool)?
    var saved: ((Bool) -> Void)?
    var authorizations = 0
    var preparations = 0
    var saves = 0
    var effects = 0
    var cleanups = 0
    var values: [Float] = []
    var completions = 0
    var disposable: Disposable?

    init(accountId: Int64 = 11, empty: Bool = false, kind: Int = 0) {
        let id = FeedNativeFixtures.message(channel: FeedNativeFixtures.channel(1), id: 7, timestamp: 100).id
        self.permit = ExteralessContentExportPermit(accountId: 11, messageIds: [id], exportAllowed: true)
        let video: EngineMediaResource.ResourceData? = kind == 2 ? .init(path: "injected-only-video", availableSize: 3, isComplete: true) : nil
        let data = ExteralessCameraRollData(main: .init(path: "injected-only-main", availableSize: 3, isComplete: true), video: video, isImage: kind != 1)
        let input: Signal<ExteralessCameraRollInput, NoError> = empty ? .complete() : (.single(.progress(1)) |> then(.single(.ready(data))))
        let sinks = ExteralessCameraRollSinks(authorize: { [weak self] callback in
            self?.authorizations += 1; self?.permission = callback
            return EmptyDisposable
        }, prepare: { [weak self] _, callback in
            self?.preparations += 1; self?.prepared = callback
            return EmptyDisposable
        }, save: { [weak self] _, commit, callback in
            self?.saves += 1; self?.commit = commit; self?.saved = callback
            return EmptyDisposable
        })
        self.disposable = exteralessCameraRollSave(input: input, permit: self.permit, accountId: accountId, sinks: sinks).start(next: { [weak self] value in
            self?.values.append(value)
        }, completed: { [weak self] in self?.completions += 1 })
    }

    func payload(_ kind: Int) -> ExteralessCameraRollPrepared {
        let content: ExteralessCameraRollPrepared.Content
        switch kind {
        case 1: content = .video(URL(fileURLWithPath: "injected-only-video"))
        case 2: content = .livePhoto(Data([1, 2, 3]), URL(fileURLWithPath: "injected-only-paired-video"))
        default: content = .image(Data([1, 2, 3]))
        }
        return ExteralessCameraRollPrepared(content: content, cleanup: ActionDisposable { [weak self] in self?.cleanups += 1 })
    }

    func reachPhotos(_ kind: Int) {
        self.permission?(true)
        self.prepared?(self.payload(kind))
    }

    @discardableResult func write() -> Bool { self.commit?({ self.effects += 1 }) ?? false }
    func close() { self.disposable?.dispose(); self.permit.revoke() }
    deinit { self.disposable?.dispose(); self.permit.revoke() }
}

/// Shipping operation/receipt/commit adapters, injected at their native sinks. No Account,
/// resource fetch, file I/O, Photos, clipboard, activity presentation, RPC or send is executed.
final class FeedTerminalExportTests: XCTestCase, @unchecked Sendable {
    @MainActor func testPhotosRevocationAtPermissionPreparationChangesAndCompletionForAllMediaKinds() {
        for kind in 0 ... 2 {
            for boundary in 0 ... 3 {
                let fixture = FeedCameraRollSinkFixture(kind: kind)
                defer { fixture.close() }
                if boundary >= 1 { fixture.permission?(true) }
                if boundary >= 2 { fixture.prepared?(fixture.payload(kind)) }
                if boundary == 3 { XCTAssertTrue(fixture.write()) }
                let admitted = fixture.effects
                fixture.permit.revoke()
                if boundary == 0 { fixture.permission?(true) }
                if boundary == 1 { fixture.prepared?(fixture.payload(kind)) }
                XCTAssertFalse(fixture.write())
                fixture.saved?(true)
                XCTAssertEqual(fixture.effects, admitted)
                XCTAssertFalse(fixture.values.contains(1), "No Photos success receipt after retirement")
                XCTAssertEqual(fixture.authorizations, 1)
                XCTAssertEqual(fixture.preparations, boundary == 0 ? 0 : 1)
                XCTAssertEqual(fixture.saves, boundary < 2 ? 0 : 1)
                XCTAssertEqual(fixture.cleanups, boundary == 0 ? 0 : 1)
            }
        }
    }

    @MainActor func testPhotosFailuresEmptySourceForeignAccountAndUnclaimedSuccessAreNotSuccess() {
        for failure in 0 ... 5 {
            let fixture = FeedCameraRollSinkFixture(accountId: failure == 0 ? 12 : 11, empty: failure == 1, kind: failure == 4 ? 1 : (failure == 5 ? 2 : 0))
            defer { fixture.close() }
            switch failure {
            case 2: fixture.permission?(false); fixture.permission?(true)
            case 3: fixture.permission?(true); fixture.prepared?(nil)
            case 4: fixture.reachPhotos(1); XCTAssertTrue(fixture.write()); fixture.saved?(false)
            case 5: fixture.reachPhotos(2); fixture.saved?(true) // Photos did not call its effect admission.
            default: break
            }
            fixture.saved?(true)
            XCTAssertFalse(fixture.values.contains(1))
            XCTAssertFalse(fixture.permit.allows(accountId: 11))
            XCTAssertEqual(fixture.completions, 1)
        }
    }

    @MainActor func testPhotosSuccessfulCommitAndCleanupAreOnceOnlyDespiteDuplicateCallbacks() {
        for kind in 0 ... 2 {
            let fixture = FeedCameraRollSinkFixture(kind: kind)
            defer { fixture.close() }
            fixture.permission?(true)
            fixture.permission?(true)
            fixture.prepared?(fixture.payload(kind))
            fixture.prepared?(fixture.payload(kind))
            XCTAssertTrue(fixture.write())
            XCTAssertFalse(fixture.write())
            fixture.saved?(true)
            fixture.saved?(false)
            fixture.saved?(true)
            XCTAssertEqual(fixture.preparations, 1)
            XCTAssertEqual(fixture.saves, 1)
            XCTAssertEqual(fixture.effects, 1)
            XCTAssertEqual(fixture.values.filter { $0 == 1 }.count, 1)
            XCTAssertEqual(fixture.completions, 1)
            XCTAssertEqual(fixture.cleanups, 2, "The accepted and discarded duplicate preparations are both released")
            XCTAssertTrue(fixture.permit.allows(accountId: 11))
        }
    }

    @MainActor func testSubscriberCancellationStopsLateSaveCallbacksAndCleansLatePreparedMedia() {
        for prepared in [false, true] {
            let fixture = FeedCameraRollSinkFixture()
            defer { fixture.close() }
            if prepared { fixture.permission?(true) }
            fixture.disposable?.dispose()
            fixture.permission?(true)
            if prepared { fixture.prepared?(fixture.payload(2)) }
            XCTAssertFalse(fixture.write())
            fixture.saved?(true)
            XCTAssertEqual(fixture.effects, 0)
            XCTAssertEqual(fixture.saves, 0)
            XCTAssertEqual(fixture.cleanups, prepared ? 1 : 0)
            XCTAssertFalse(fixture.values.contains(1))
        }
    }

    @MainActor func testShareProgressNeedsThePhotosReceiptRatherThanAnEmptyOrDownloadCompletion() {
        let cases: [[Float?]] = [[], [nil], [0.5, 0.99], [0.5, 1]]
        for values in cases {
            let permit = self.permit()
            defer { permit.revoke() }
            let signal = Signal<Float?, NoError> { subscriber in
                for value in values { subscriber.putNext(value) }
                subscriber.putCompletion()
                return EmptyDisposable
            }
            var successes = 0, failures = 0
            let disposable = exteralessShareConfirmedProgress(signal, permit: permit, accountId: 11).start(error: { _ in failures += 1 }, completed: { successes += 1 })
            defer { disposable.dispose() }
            XCTAssertEqual(successes, values.contains(where: { $0 == 1 }) ? 1 : 0)
            XCTAssertEqual(failures, successes == 0 ? 1 : 0)
        }
    }

    @MainActor func testTimestampClipboardSinkAndNotificationBothRespectTheOriginalPermit() {
        let permit = self.permit()
        defer { permit.revoke() }
        var writes: [String] = [], notices: [Int32?] = []
        XCTAssertTrue(exteralessShareCopyTimestampLink(prefix: "https://t.me/fixture/7", timestamp: 3661, permit: permit, accountId: 11, current: { true }, write: { writes.append($0) }, copied: { notices.append($0) }))
        XCTAssertEqual(writes, ["https://t.me/fixture/7?t=1h1m1s"])
        XCTAssertEqual(notices, [3661])
        permit.revoke()
        XCTAssertFalse(exteralessShareCopyTimestampLink(prefix: "private", timestamp: 60, permit: permit, accountId: 11, current: { true }, write: { writes.append($0) }, copied: { notices.append($0) }))
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(notices.count, 1)
        // Stock nil path and native Int32 link formatting remain unchanged.
        XCTAssertTrue(exteralessShareCopyTimestampLink(prefix: "stock", timestamp: 60, permit: nil, accountId: 12, current: { false }, write: { writes.append($0) }, copied: { notices.append($0) }))
        XCTAssertEqual(writes.last, "stock?t=1m")
        let reentrant = self.permit()
        var reentrantNotices = 0
        XCTAssertTrue(exteralessShareCopyTimestampLink(prefix: "fixture", timestamp: nil, permit: reentrant, accountId: 11, current: { true }, write: { _ in reentrant.revoke() }, copied: { _ in reentrantNotices += 1 }))
        XCTAssertEqual(reentrantNotices, 0)
    }

    @MainActor func testNativeEnqueueCommitRechecksAfterHeldWorkAndCancellation() {
        for cancelByDisposal in [false, true] {
            let permit = self.permit()
            let controller = UIViewController()
            XCTAssertTrue(permit.own(controller))
            var commit: ExteralessTLEnqueueCommit?
            var native: Subscriber<EnqueueMessagesResult, NoError>?
            var results = 0
            let disposable = exteralessShareEnqueue(reference: controller.exteralessExportPermitReference, accountId: 11, enqueue: { gate in
                commit = gate
                return Signal { subscriber in native = subscriber; return EmptyDisposable }
            }).start(next: { _ in results += 1 })
            if cancelByDisposal { disposable.dispose() } else { permit.revoke() }
            XCTAssertFalse(commit?.allowsContinuation() ?? true)
            XCTAssertFalse(commit?.beginCommit() ?? true, "The actual Core transaction must reject before its writes")
            native?.putNext(.committed(messageIds: [self.messageId]))
            native?.putCompletion()
            XCTAssertEqual(results, 0)
            disposable.dispose()
            permit.revoke()
        }
    }

    @MainActor func testNativeEnqueueEmptyPartialRejectedAndLateAfterCommitCannotReportSuccess() {
        for outcome in 0 ... 4 {
            let permit = self.permit()
            let controller = UIViewController()
            XCTAssertTrue(permit.own(controller))
            var gate: ExteralessTLEnqueueCommit?
            var native: Subscriber<EnqueueMessagesResult, NoError>?
            var successes = 0, errors = 0, cancellations = 0
            let disposable = exteralessShareEnqueue(reference: controller.exteralessExportPermitReference, accountId: 11, enqueue: { commit in
                gate = commit
                return Signal { subscriber in native = subscriber; return ActionDisposable { cancellations += 1 } }
            }).start(next: { _ in successes += 1 }, error: { _ in errors += 1 })
            if outcome != 0 { XCTAssertTrue(gate?.beginCommit() == true) }
            switch outcome {
            case 0: native?.putCompletion()
            case 1: native?.putNext(.rejected(count: 1, reason: .botAuthorizationDenied))
            case 2: native?.putNext(.committed(messageIds: [self.messageId, nil]))
            case 3:
                permit.revoke()
                XCTAssertEqual(cancellations, 0, "An already claimed native job retains its completion/tracking")
                native?.putNext(.committed(messageIds: [self.messageId]))
            default: native?.putNext(.committed(messageIds: [self.messageId]))
            }
            native?.putCompletion()
            XCTAssertEqual(successes, outcome == 4 ? 1 : 0)
            XCTAssertEqual(errors, outcome < 3 ? 1 : 0)
            XCTAssertEqual(cancellations, 1)
            disposable.dispose()
            permit.revoke()
        }
    }

    @MainActor func testExternalActivityWaitHasNoSuccessForMissingAppearanceOrPresentationRefusal() {
        for mode in 0 ... 3 {
            let permit = self.permit()
            var presents = 0, handoffs = 0
            let appeared: Signal<Bool, NoError> = mode == 0 ? .complete() : .single(true)
            let disposable = exteralessShareAwaitActivity(appeared: appeared, permit: permit, accountId: 11, present: {
                presents += 1
                if mode == 2 { permit.revoke() }
                return mode != 1
            }).start(next: { _ in handoffs += 1 })
            XCTAssertEqual(presents, mode == 0 ? 0 : 1)
            XCTAssertEqual(handoffs, mode == 3 ? 1 : 0)
            disposable.dispose()
            permit.revoke()
        }
        let permit = self.permit()
        let timedOut = self.expectation(description: "bounded native appearance wait")
        let revoke = permit.onRevocation { timedOut.fulfill() }
        var presentations = 0
        let waiting = exteralessShareAwaitActivity(appeared: .never(), permit: permit, accountId: 11, timeoutInterval: 0.01, present: { presentations += 1; return true }).start()
        self.wait(for: [timedOut], timeout: 1)
        XCTAssertEqual(presentations, 0)
        waiting.dispose(); revoke.dispose(); permit.revoke()
    }

    @MainActor private var messageId: EngineMessage.Id {
        FeedNativeFixtures.message(channel: FeedNativeFixtures.channel(1), id: 7, timestamp: 100).id
    }

    @MainActor private func permit() -> ExteralessContentExportPermit {
        ExteralessContentExportPermit(accountId: 11, messageIds: [self.messageId], exportAllowed: true)
    }
}
