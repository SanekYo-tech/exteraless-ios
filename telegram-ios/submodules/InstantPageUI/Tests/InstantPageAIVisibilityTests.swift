import XCTest
import UIKit
import TelegramCore
@testable import InstantPageUI

/// Exercises the actual V1 projection objects without constructing an account,
/// media node or web view. No URLs are loaded and no page data is rewritten.
final class InstantPageAIVisibilityTests: XCTestCase {
    func testHiddenSummaryKeepsEmbedDetailsAndAnchorOrdinalsWithoutContent() throws {
        let originalFrame = CGRect(x: 0.0, y: 0.0, width: 320.0, height: 80.0)
        let embed = InstantPageWebEmbedItem(frame: originalFrame, url: "https://fixture.invalid/summary", html: "fixture", enableScrolling: true)
        let nestedEmbed = InstantPageWebEmbedItem(frame: originalFrame, url: "https://fixture.invalid/nested", html: nil, enableScrolling: true)
        let nestedAnchor = InstantPageAnchorItem(frame: .zero, anchor: "nested")
        let details = InstantPageDetailsItem(frame: originalFrame, titleItems: [], titleHeight: 44.0, items: [nestedEmbed, nestedAnchor], safeInset: 0.0, rtl: false, initiallyExpanded: true, index: 0)
        let visibleDetails = InstantPageDetailsItem(frame: originalFrame, titleItems: [], titleHeight: 44.0, items: [], safeInset: 0.0, rtl: false, initiallyExpanded: false, index: 1)
        let anchor = InstantPageAnchorItem(frame: .zero, anchor: "block")
        let style = InstantPageTextStyleStack()
        style.push(.fontSize(17.0))
        style.push(.textColor(.black))
        let rich = attributedStringForRichText(.anchor(text: .plain("hidden text"), name: "inline"), styleStack: style)
        let (_, textItems, _) = layoutTextItemWithString(rich, boundingWidth: 320.0, offset: .zero)

        let source: [InstantPageItem] = [embed, details, anchor] + textItems
        let projected = instantPageHiddenAISummaryPlaceholders(source, origin: CGPoint(x: 0.0, y: 125.0), width: 320.0)
        XCTAssertTrue(projected.allSatisfy { $0.frame.height == 0.0 && $0.frame.minY == 125.0 })
        XCTAssertFalse(projected.contains { $0 is InstantPageTextItem })
        XCTAssertTrue(projected.allSatisfy { $0.medias.isEmpty })
        let projectedEmbed = try XCTUnwrap(projected.first as? InstantPageWebEmbedItem)
        XCTAssertTrue(projectedEmbed.wantsNode) // The viewer's embed ordinal is retained.
        XCTAssertNil(projectedEmbed.url)
        XCTAssertNil(projectedEmbed.html)
        let projectedDetails = try XCTUnwrap(projected.compactMap { $0 as? InstantPageDetailsItem }.first)
        XCTAssertEqual(projectedDetails.index, 0)
        XCTAssertEqual(projectedDetails.titleHeight, 0.0)
        XCTAssertTrue(projectedDetails.titleItems.isEmpty)
        XCTAssertTrue(projectedDetails.initiallyExpanded)
        XCTAssertEqual((projected + [visibleDetails]).compactMap { ($0 as? InstantPageDetailsItem)?.index }, [0, 1])
        XCTAssertNil((projectedDetails.items.first as? InstantPageWebEmbedItem)?.url)
        XCTAssertTrue(projectedDetails.items.contains { $0.matchesAnchor("nested") })
        XCTAssertEqual(Set(projected.compactMap { ($0 as? InstantPageAnchorItem)?.anchor }), ["block", "inline"])

        XCTAssertEqual(embed.frame, originalFrame)
        XCTAssertEqual(embed.url, "https://fixture.invalid/summary")
        XCTAssertEqual(details.frame, originalFrame)
        XCTAssertEqual(details.titleHeight, 44.0)
        XCTAssertTrue((details.items.first as? InstantPageWebEmbedItem) === nestedEmbed)
        XCTAssertFalse(projectedDetails === details)
    }
}
