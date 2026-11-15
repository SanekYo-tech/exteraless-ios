import AsyncDisplayKit
import CoreText
import Display
import ExteralessCore
import Foundation
import ListSectionHeaderNode
import LottieSettings
import TelegramCore
import TelegramPresentationData
import UIKit
import XCTest
@testable import ChatListUI
@testable import ChatMessageContactBubbleContentNode

private enum FontConsumerFixtureError: Error {
    case unexpectedSecretAccess
}

private final class FontConsumerFixtureSecrets: ClientSecretStore, @unchecked Sendable {
    func data(for key: String) throws -> Data? { throw FontConsumerFixtureError.unexpectedSecretAccess }
    func set(_ data: Data?, for key: String) throws { throw FontConsumerFixtureError.unexpectedSecretAccess }
}

/// PFM-01: the actual consumers must query the new family after the first use of
/// their module, including reused layout closures and fresh nodes in that process.
/// No Account, AccountContext, network or resource download is constructed here.
@MainActor
final class FontFamilyConsumerTests: XCTestCase {
    private struct RetainedText {
        let layout: TextNodeLayout
        let text: NSAttributedString
        let font: UIFont
        let lines: [CTLine]
        let widths: [Double]
    }

    private func withSettings(_ body: (ClientSettings) throws -> Void) throws {
        let started = CFAbsoluteTimeGetCurrent()
        defer { XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - started, 30, "fixture logic budget") }
        try ExteralessFontFamily.prepare()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("font-consumers-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = ClientSettings.shared
        try settings.configure(storageURL: directory.appendingPathComponent("settings.json"), secretStore: FontConsumerFixtureSecrets(), durabilityRootURL: directory)
        let weight = AppearanceAdditionalFeatures.definitions.filter { $0.key == "appearance.forceFontWeightFallback" }
        let filtering = PrivacyExtrasFeatures.definitions.filter { $0.key == "privacy.zalgoFilter" }
        try settings.register(CoreAppearanceFontFamilyPolicy.definitions + weight + filtering)
        defer {
            try? settings.reset(CoreAppearanceFontFamilyPolicy.key)
            try? settings.reset("appearance.forceFontWeightFallback")
            try? settings.reset("privacy.zalgoFilter")
            try? FileManager.default.removeItem(at: directory)
        }
        try body(settings)
    }

    private func select(_ step: Int, settings: ClientSettings) throws {
        if step == 2 {
            try settings.reset(CoreAppearanceFontFamilyPolicy.key)
            XCTAssertFalse(settings.readSnapshot().storedKeys.contains(CoreAppearanceFontFamilyPolicy.key))
        } else {
            try settings.setPublic(.bool(step == 0), for: CoreAppearanceFontFamilyPolicy.key)
        }
    }

    private func textNodes(_ root: ASDisplayNode) -> [TextNode] {
        var pending = [root]
        var result: [TextNode] = []
        var visited = 0
        while let node = pending.popLast() {
            visited += 1
            guard visited <= 128 else {
                XCTFail("unexpectedly large fixture hierarchy")
                return result
            }
            if let text = node as? TextNode, let value = text.currentText, value.length > 0 {
                result.append(text)
            }
            pending.append(contentsOf: node.subnodes ?? [])
        }
        return result
    }

    private func check(_ node: TextNode, system: Bool, size: CGFloat) throws -> RetainedText {
        let layout = try XCTUnwrap(node.cachedLayout)
        let text = try XCTUnwrap(node.currentText)
        XCTAssertGreaterThan(text.length, 0)
        let font = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(font.familyName, system ? UIFont.systemFont(ofSize: size).familyName : "Roboto")
        XCTAssertEqual(font.pointSize, size)
        XCTAssertTrue(layout.size.width.isFinite && layout.size.height.isFinite)
        XCTAssertGreaterThan(layout.size.width, 0)
        XCTAssertGreaterThan(layout.size.height, 0)
        var lines: [CTLine] = []
        layout.enumerateRenderedLines(in: CGRect(origin: .zero, size: layout.size)) { line, _ in lines.append(line) }
        XCTAssertFalse(lines.isEmpty)
        return RetainedText(layout: layout, text: NSAttributedString(attributedString: text), font: font, lines: lines,
            widths: lines.map { CTLineGetTypographicBounds($0, nil, nil, nil) })
    }

    private func checkRetained(_ values: [RetainedText]) {
        for value in values {
            XCTAssertTrue(value.layout.attributedString?.isEqual(to: value.text) == true)
            XCTAssertTrue((value.text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont) === value.font)
            for (line, width) in zip(value.lines, value.widths) {
                XCTAssertEqual(CTLineGetTypographicBounds(line, nil, nil, nil), width, accuracy: 0.0001)
                XCTAssertGreaterThan(CTLineGetGlyphCount(line), 0)
            }
        }
    }

    func testHeaderRelayoutAndNewNodeUseCurrentFamilyIncludingSameTheme() throws {
        try self.withSettings { settings in
            let theme = defaultPresentationTheme
            let header = ListSectionHeaderNode(theme: theme)
            header.title = "ARCHIVE Rg 123"
            header.action = "MANAGE"
            let size = CGSize(width: 360, height: 32)
            var retained: [RetainedText] = []
            for step in 0...2 {
                try self.select(step, settings: settings)
                // No title/action reassignment: the layout itself must refresh
                // fonts even when a caller reuses the exact native theme object.
                header.updateLayout(size: size, leftInset: 0, rightInset: 0)
                let existing = self.textNodes(header)
                XCTAssertEqual(existing.count, 2)
                for node in existing { retained.append(try self.check(node, system: step != 1, size: 13)) }

                let nextTheme = theme.withUpdated(referenceTheme: theme.referenceTheme)
                header.updateTheme(theme: nextTheme)
                for node in self.textNodes(header) { _ = try self.check(node, system: step != 1, size: 13) }
                let fresh = ListSectionHeaderNode(theme: nextTheme)
                fresh.title = header.title
                fresh.action = header.action
                fresh.updateLayout(size: size, leftInset: 0, rightInset: 0)
                let created = self.textNodes(fresh)
                XCTAssertEqual(created.count, 2)
                XCTAssertEqual(Set(created.compactMap { $0.currentText?.string }), Set(["ARCHIVE Rg 123", "MANAGE"]))
                for node in created { _ = try self.check(node, system: step != 1, size: 13) }
                self.checkRetained(retained)
            }
        }
    }

    func testArchiveActualPagesAndHeaderReflowForReusedLayoutAndNewNode() throws {
        try self.withSettings { settings in
            let theme = defaultPresentationTheme
            let strings = defaultPresentationStrings
            let titles = Set([strings.ArchivedChats_IntroTitle1, strings.ArchivedChats_IntroTitle2, strings.ArchivedChats_IntroTitle3])
            let bodies = Set([strings.ArchivedChats_IntroText1, strings.ArchivedChats_IntroText2, strings.ArchivedChats_IntroText3])
            let header = strings.ChatList_ArchivedChatsTitle.uppercased()
            let params = ListViewItemLayoutParams(width: 360, leftInset: 0, rightInset: 0, availableHeight: 640)
            let item = ChatListArchiveInfoItem(theme: theme, strings: strings)
            let node = ChatListArchiveInfoItemNode()
            let layout = node.asyncLayout()
            var retained: [RetainedText] = []
            for step in 0...2 {
                try self.select(step, settings: settings)
                let (geometry, apply) = layout(item, params, true)
                apply()
                XCTAssertGreaterThan(geometry.contentSize.height, 0)
                let nextItem = ChatListArchiveInfoItem(theme: theme.withUpdated(referenceTheme: theme.referenceTheme), strings: strings)
                let fresh = ChatListArchiveInfoItemNode()
                fresh.asyncLayout()(nextItem, params, true).1()
                for current in [node, fresh] {
                    let rendered = self.textNodes(current)
                    XCTAssertEqual(rendered.count, 7, "three real intro pages and their real section header")
                    for textNode in rendered {
                        let text = try XCTUnwrap(textNode.currentText?.string)
                        let size: CGFloat
                        if text == header { size = 13 }
                        else if titles.contains(text) { size = 20 }
                        else {
                            XCTAssertTrue(bodies.contains(text), text)
                            size = 15
                        }
                        let snapshot = try self.check(textNode, system: step != 1, size: size)
                        if current === node { retained.append(snapshot) }
                    }
                }
                self.checkRetained(retained)
            }
        }
    }

    func testContactActualTextLayoutAndNewNodeKeepFilteredNameWhileFamilyChanges() throws {
        try self.withSettings { settings in
            try settings.setPublic(.bool(true), for: "privacy.zalgoFilter")
            let originalFirst = "A" + String(repeating: "\u{0301}", count: 4)
            let contact = TelegramMediaContact(firstName: originalFirst, lastName: "B", phoneNumber: "+1 555 0100", peerId: nil, vCardData: nil)
            let owner = IdentityAccountId(recordId: 1, userId: 100, testingEnvironment: false)
            let node = ChatMessageContactBubbleContentNode(lottieSettings: .noAccountFallback)
            let layout = node.asyncLayoutContactText()
            let avatarFrame = CGRect(x: 10, y: 14, width: 40, height: 40)
            var retained: [RetainedText] = []
            for step in 0...2 {
                try self.select(step, settings: settings)
                // The same pure snapshot overload is used by the shipping account
                // wrapper; it does not open an Account to resolve a contact name.
                let presentation = exteralessIdentityContactPresentation(owner: owner, state: nil, contact: contact, peer: nil, fallbackName: "Contact")
                XCTAssertEqual(presentation.name, "A B")
                XCTAssertEqual(presentation.initials, ["A", "B"])
                let measured = layout(presentation.name, contact.phoneNumber, .blue, .black, 230)
                measured.apply(avatarFrame)
                let fresh = ChatMessageContactBubbleContentNode(lottieSettings: .noAccountFallback)
                fresh.asyncLayoutContactText()(presentation.name, contact.phoneNumber, .blue, .black, 230).apply(avatarFrame)
                for current in [node, fresh] {
                    // These are the node's own two real TextNodes, not recreated
                    // attributed strings or a test-only Font producer.
                    let rendered = self.textNodes(current)
                    XCTAssertEqual(rendered.count, 2)
                    for textNode in rendered {
                        let snapshot = try self.check(textNode, system: step != 1, size: 14)
                        XCTAssertTrue([presentation.name, contact.phoneNumber].contains(snapshot.text.string))
                        XCTAssertEqual(textNode.frame.minX, avatarFrame.maxX + 7)
                        XCTAssertEqual(textNode.frame.minY, avatarFrame.minY + (snapshot.text.string == presentation.name ? 1 : 20))
                        if current === node { retained.append(snapshot) }
                    }
                }
                XCTAssertEqual(Array(contact.firstName.utf16), Array(originalFirst.utf16))
                self.checkRetained(retained)
            }
        }
    }
}
