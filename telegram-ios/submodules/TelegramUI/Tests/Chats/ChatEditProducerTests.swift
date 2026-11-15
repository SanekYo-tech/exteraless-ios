import SwiftSignalKit
import TelegramCore
import XCTest
@testable import TelegramUI

@MainActor
final class ChatEditProducerTests: XCTestCase {
    private struct Source: Equatable { let id: Int; let version: Int }
    private struct Request: Equatable { let media: String; let preview: String }

    func testEditABarrierAtEitherReadCannotInstallOrCleanEditB() {
        for barrier in [1, 2] {
            let first = ValuePipe<Source?>(), second = ValuePipe<Source?>()
            let token = PendingMessageUpdateAdmissionToken()
            let captured = Request(media: "media A", preview: "url A")
            var revision = 0, reads = 0, installs = 0, cleanups = 0
            var live = captured
            let subscription = exteralessSubmitChatEdit(read: { reads += 1; return reads == 1 ? first.signal() : second.signal() }, token: token, isCurrent: { revision == 0 }, sameSource: { $0 == $1 }, prepare: { _ in captured }, unchanged: { _, _ in false }, install: { _, request in
                XCTAssertEqual(request, captured)
                installs += 1
                return .single(.admitted)
            }).start(next: { result in if result == .admitted && revision == 0 { cleanups += 1 } })
            if barrier == 2 { first.putNext(Source(id: 1, version: 1)) }
            revision += 1; live = Request(media: "media B", preview: "url B"); token.cancel()
            if barrier == 1 { first.putNext(Source(id: 1, version: 1)) }
            else { second.putNext(Source(id: 1, version: 1)) }
            XCTAssertEqual(installs, 0); XCTAssertEqual(cleanups, 0)
            XCTAssertEqual(live, Request(media: "media B", preview: "url B"))
            subscription.dispose()
        }
    }

    func testMissingOrChangedSecondSourceDoesNotClaimPendingAdmission() {
        for secondSource in [nil, Source(id: 1, version: 2)] {
            let token = PendingMessageUpdateAdmissionToken()
            var reads = 0, installs = 0
            var result: PendingMessageUpdateAdmission?
            let subscription = exteralessSubmitChatEdit(read: { reads += 1; return .single(reads == 1 ? Source(id: 1, version: 1) : secondSource) }, token: token, isCurrent: { true }, sameSource: { $0 == $1 }, prepare: { _ in Request(media: "A", preview: "A") }, unchanged: { _, _ in false }, install: { _, _ in installs += 1; return .single(.admitted) }).start(next: { result = $0 })
            XCTAssertEqual(result, .rejected(.localEnqueueUnavailable))
            XCTAssertEqual(installs, 0)
            subscription.dispose()
        }
    }
}
