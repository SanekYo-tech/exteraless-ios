import Foundation
import SwiftSignalKit
import TelegramPresentationData
import UIKit
import XCTest

final class AppearancePresentationRevisionTests: XCTestCase {
    @MainActor
    func testRevisionsDoNotRestartNativeThemeLoadAndPublishLatestImmutableValue() throws {
        let defaults = defaultPresentationData()
        let first = defaults.withUpdated(theme: defaults.theme.withUpdated(referenceTheme: defaults.theme.referenceTheme))
        first.theme.forceSync = true
        let second = first.withUpdated(theme: first.theme.withUpdated(name: "Second native theme", defaultWallpaper: nil))
        let nativeValues = ValuePipe<PresentationData>()
        let revisions = ValuePipe<Void>()
        var subscriptions = 0
        let native = Signal<PresentationData, NoError> { subscriber in
            subscriptions += 1
            return nativeValues.signal().start(next: { subscriber.putNext($0) })
        }
        var received: [PresentationData] = []
        let values = expectation(description: "native + cheap revisions")
        values.expectedFulfillmentCount = 4
        let disposable = exteralessAppearancePresentationData(native: native, updates: revisions.signal(), dateTimeFormat: { first.dateTimeFormat }, hideDividers: { false }).start(next: { data in
            XCTAssertTrue(Thread.isMainThread)
            received.append(data)
            values.fulfill()
        })
        nativeValues.putNext(first)
        revisions.putNext(())
        revisions.putNext(())
        nativeValues.putNext(second)
        revisions.putNext(())
        wait(for: [values], timeout: 1)
        XCTAssertEqual(subscriptions, 1, "appearance changes must not resubscribe a file-backed loader")
        XCTAssertEqual(received.count, 4)
        let initial = try XCTUnwrap(received.first)
        let revision = try XCTUnwrap(received.dropFirst().first)
        let latest = try XCTUnwrap(received.last)
        XCTAssertFalse(initial.theme === first.theme)
        XCTAssertFalse(initial.theme.resourceCache === first.theme.resourceCache)
        XCTAssertTrue(initial.theme.list === first.theme.list, "immutable palette is reused, not decoded again")
        XCTAssertTrue(initial.theme.forceSync)
        XCTAssertFalse(initial.theme === revision.theme, "native identity-based layout gates must invalidate")
        XCTAssertEqual(latest.theme.name.string, "Second native theme")
        XCTAssertEqual(latest.chatWallpaper, second.chatWallpaper)
        XCTAssertEqual(latest.dateTimeFormat, first.dateTimeFormat)

        disposable.dispose()
        nativeValues.putNext(first)
        revisions.putNext(())
        let drained = expectation(description: "cancelled subscription drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertEqual(received.count, 4, "queued old lifetime cannot publish after disposal")
    }

    @MainActor
    func testDividerAliasDoesNotMutateTheNativeThemeAndRestoresItsColors() throws {
        let source = defaultPresentationData()
        let original = source.theme.list.itemBlocksSeparatorColor
        let revisions = ValuePipe<Void>()
        var hidden = true
        var received: [PresentationData] = []
        let first = expectation(description: "hidden dividers")
        let restored = expectation(description: "restored dividers")
        let disposable = exteralessAppearancePresentationData(native: .single(source), updates: revisions.signal(), dateTimeFormat: { source.dateTimeFormat }, hideDividers: { hidden }).start(next: { value in
            received.append(value)
            if received.count == 1 { first.fulfill() } else { restored.fulfill() }
        })
        revisions.putNext(())
        wait(for: [first], timeout: 1)
        XCTAssertEqual(try XCTUnwrap(received.first).theme.list.itemBlocksSeparatorColor.cgColor.alpha, 0)
        XCTAssertEqual(source.theme.list.itemBlocksSeparatorColor, original)
        hidden = false
        revisions.putNext(())
        wait(for: [restored], timeout: 1)
        XCTAssertTrue(try XCTUnwrap(received.last).theme.list === source.theme.list)
        XCTAssertEqual(try XCTUnwrap(received.last).theme.list.itemBlocksSeparatorColor, original)
        disposable.dispose()
    }
}
