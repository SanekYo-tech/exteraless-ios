import AccountContext
import Foundation
import TelegramCore
import UIKit
import XCTest
@testable import ShareController

/// Calls the native UIActivityItemSource used by ShareController's actual root export path.
/// The activity controller is never presented and no clipboard/Photos/activity is executed.
@MainActor
final class FeedActivityExportTests: XCTestCase {
    func testPhotoShareDescendantRechecksAtNativeItemRequestAfterItsSourceIsGone() {
        let id = FeedNativeFixtures.message(channel: FeedNativeFixtures.channel(1), id: 7, timestamp: 100).id
        let permit = ExteralessContentExportPermit(accountId: 11, messageIds: [id], exportAllowed: true)
        var source: UIViewController? = UIViewController()
        weak var weakSource = source
        var validator: NSObject? = NSObject()
        weak var weakValidator = validator
        XCTAssertTrue(permit.retainOwner(validator!, on: source!))
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        var item: ExteralessShareActivityItem? = ExteralessShareActivityItem(value: photo, reference: source!.exteralessExportPermitReference, accountId: 11)
        let activity = UIActivityViewController(activityItems: [], applicationActivities: nil)
        XCTAssertFalse((item!.activityViewControllerPlaceholderItem(activity) as? UIImage) === photo)
        XCTAssertFalse((item!.activityViewController(activity, itemForActivityType: nil) as? UIImage) === photo)
        XCTAssertEqual(permit.counters.effects, 0)
        XCTAssertTrue((item!.activityViewController(activity, itemForActivityType: .copyToPasteboard) as? UIImage) === photo)
        XCTAssertEqual(permit.counters.effects, 1)
        source = nil
        validator = nil
        XCTAssertNil(weakSource)
        XCTAssertNotNil(weakValidator)
        permit.revoke()
        XCTAssertNil(item!.activityViewController(activity, itemForActivityType: .saveToCameraRoll))
        XCTAssertNil(item!.activityViewController(activity, itemForActivityType: .copyToPasteboard))
        XCTAssertEqual(permit.counters.effects, 1, "No newly admitted effect after protection/account retirement")
        item = nil
        XCTAssertNil(weakValidator)
    }

    func testNativeItemRequestRefusesForeignAccountAndDoesNotExposePlaceholderText() {
        let id = FeedNativeFixtures.message(channel: FeedNativeFixtures.channel(1), id: 7, timestamp: 100).id
        let permit = ExteralessContentExportPermit(accountId: 11, messageIds: [id], exportAllowed: true)
        let source = UIViewController()
        XCTAssertTrue(permit.own(source))
        let item = ExteralessShareActivityItem(value: "Private fixture text" as NSString, reference: source.exteralessExportPermitReference, accountId: 12)
        let activity = UIActivityViewController(activityItems: [], applicationActivities: nil)
        XCTAssertEqual(item.activityViewControllerPlaceholderItem(activity) as? String, "")
        XCTAssertNil(item.activityViewController(activity, itemForActivityType: .copyToPasteboard))
        XCTAssertEqual(permit.counters.effects, 0)
        permit.revoke()
    }
}
