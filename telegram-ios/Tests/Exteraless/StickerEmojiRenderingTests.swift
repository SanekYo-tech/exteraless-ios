import CoreText
import Emoji
import ExteralessCore
import Foundation
import UIKit
import XCTest

/// Loginless UIKit/CoreText tests. EmojiFontFixture.swift is included by the
/// test-only BUILD handoff; no Telegram Account or account network is created.
@MainActor
final class StickerEmojiRenderingTests: XCTestCase {
    func testMixedVisibleAndNonzeroBlankGlyphUsesActualBitmapFallback() throws {
        let renderer = ExteralessEmojiRendering.shared
        let owner = renderer.begin(accountId: 80)
        defer { renderer.clear(owner: owner) }
        let face = try renderer.prepare(data: EmojiFontFixture.mixed, fileExtension: "ttf", expectedSHA256: EmojiFontFixture.mixedSHA256, owner: owner)
        XCTAssertTrue(renderer.apply(face, owner: owner))
        let fallback = UIFont.systemFont(ofSize: 32)
        let registered = try XCTUnwrap(UIFont(name: EmojiFontRegistration.privateName(sha256: EmojiFontFixture.mixedSHA256), size: 32))
        let rawWink = try self.bitmap("😉", font: registered)
        XCTAssertFalse(self.hasInk(rawWink), "The fixture's mapped glyph 2 must really draw nothing")
        for _ in 0..<3 { // Exercises both the cache miss and cached decisions.
            let smile = renderer.font(for: "😀", size: 32, accountId: 80, fallback: fallback)
            let wink = renderer.font(for: "😉", size: 32, accountId: 80, fallback: fallback)
            XCTAssertEqual(smile.fontName, registered.fontName)
            XCTAssertTrue(wink === fallback)
            XCTAssertTrue(self.hasInk(try self.bitmap("😀", font: smile)))
            XCTAssertTrue(self.hasInk(try self.bitmap("😉", font: wink)))
        }
    }

    func testPartialZWJVariationAndSkinToneFallBackAsWholeStyledGraphemes() throws {
        let renderer = ExteralessEmojiRendering.shared
        let owner = renderer.begin(accountId: 81)
        defer { renderer.clear(owner: owner) }
        let face = try renderer.prepare(data: EmojiFontFixture.mixedThumb, fileExtension: "ttf", expectedSHA256: EmojiFontFixture.mixedThumbSHA256, owner: owner)
        XCTAssertTrue(renderer.apply(face, owner: owner))
        let fallback = UIFont.monospacedSystemFont(ofSize: 24, weight: .semibold)
        let partial = ["😀\u{200d}😉", "😀\u{fe0f}", "😉\u{fe0f}", "👍🏽"]
        let original = NSMutableAttributedString(string: "A 😀 | " + partial.joined(separator: " | ") + " Z", attributes: [
            .font: fallback, .foregroundColor: UIColor.purple,
            .kern: 1.25, .underlineStyle: NSUnderlineStyle.single.rawValue
        ])
        let ns = original.string as NSString
        let smileRange = ns.range(of: "😀")
        original.addAttribute(.link, value: "https://fixture.invalid/emoji", range: smileRange)
        let result = renderer.attributedText(original, accountId: 81)
        XCTAssertEqual(result.string, original.string)
        XCTAssertEqual(result.length, original.length)
        XCTAssertEqual(result.attribute(.link, at: smileRange.location, effectiveRange: nil) as? String, "https://fixture.invalid/emoji")
        for text in partial {
            let range = ns.range(of: text)
            XCTAssertNotEqual(range.location, NSNotFound)
            for index in range.location..<NSMaxRange(range) {
                XCTAssertEqual((result.attribute(.font, at: index, effectiveRange: nil) as? UIFont)?.fontName, fallback.fontName)
                XCTAssertEqual(result.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor, .purple)
                XCTAssertEqual(result.attribute(.kern, at: index, effectiveRange: nil) as? Double, 1.25)
                XCTAssertEqual(result.attribute(.underlineStyle, at: index, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
            }
            XCTAssertTrue(renderer.font(for: text, size: 24, accountId: 81, fallback: fallback) === fallback)
            XCTAssertTrue(self.hasInk(try self.bitmap(text, font: fallback)))
        }
        let selected = try XCTUnwrap(result.attribute(.font, at: smileRange.location, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(selected.fontName, EmojiFontRegistration.privateName(sha256: EmojiFontFixture.mixedThumbSHA256))
        XCTAssertEqual(selected.pointSize, 24)
        let attachment = NSMutableAttributedString(string: "😀", attributes: [.font: fallback])
        attachment.addAttribute(NSAttributedString.Key("TelegramCustomEmoji"), value: "fixture", range: NSRange(location: 1, length: 1))
        let untouched = renderer.attributedText(attachment, accountId: 81)
        XCTAssertEqual((untouched.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.fontName, fallback.fontName)
    }

    func testDecisionChurnAndRetainedUIFontAfterResetAndOwnerRetirement() throws {
        let renderer = ExteralessEmojiRendering.shared
        let owner = renderer.begin(accountId: 82)
        defer { renderer.clear(owner: owner) }
        let face = try renderer.prepare(data: EmojiFontFixture.mixed, fileExtension: "ttf", expectedSHA256: EmojiFontFixture.mixedSHA256, owner: owner)
        XCTAssertTrue(renderer.apply(face, owner: owner))
        let fallback = UIFont.systemFont(ofSize: 32)
        let retained = renderer.font(for: "😀", size: 32, accountId: 82, fallback: fallback)
        let before = try self.bitmap("😀", font: retained)
        for value in 0x1f300..<(0x1f300 + 320) {
            let text = "😀\u{200d}" + String(UnicodeScalar(value)!)
            XCTAssertTrue(renderer.font(for: text, size: 32, accountId: 82, fallback: fallback) === fallback)
        }
        XCTAssertTrue(renderer.font(for: "😉", size: 32, accountId: 82, fallback: fallback) === fallback)
        XCTAssertEqual(renderer.font(for: "😀", size: 32, accountId: 82, fallback: fallback).fontName, retained.fontName)
        XCTAssertTrue(renderer.apply(nil, owner: owner))
        renderer.clear(owner: owner)
        XCTAssertTrue(renderer.font(for: "😀", size: 32, accountId: 82, fallback: fallback) === fallback)
        XCTAssertTrue(self.hasInk(before))
        XCTAssertEqual(try self.bitmap("😀", font: retained), before, "A retained UIFont remains usable after reset/unregister")
    }

    private func bitmap(_ text: String, font: UIFont) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: 96, height: 96))
        context.setFillColor(UIColor.black.cgColor)
        context.textPosition = CGPoint(x: 16, y: 32)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), context)
        return Data(bytes: try XCTUnwrap(context.data), count: 96 * 96 * 4)
    }

    private func hasInk(_ data: Data) -> Bool {
        stride(from: 3, to: data.count, by: 4).contains(where: { data[$0] != 0 })
    }

    func testFontRegistrationActualUIFontUTF16FallbackAndReset() throws {
        let renderer = ExteralessEmojiRendering.shared
        let owner = renderer.begin(accountId: 1)
        defer { renderer.clear(owner: owner) }
        let face = try renderer.prepare(data: EmojiFontFixture.data, fileExtension: "ttf", expectedSHA256: EmojiFontFixture.sha256, owner: owner)
        XCTAssertTrue(renderer.apply(face, owner: owner))
        let original = NSMutableAttributedString(string: "A 😀 B 👩🏽‍💻", attributes: [.font: UIFont.systemFont(ofSize: 20)])
        original.addAttribute(.link, value: "https://example.invalid", range: NSRange(location: 2, length: 2))
        let displayed = renderer.attributedText(original, accountId: 1)
        let font = try XCTUnwrap(displayed.attribute(.font, at: 2, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(font.fontName, EmojiFontRegistration.privateName(sha256: EmojiFontFixture.sha256))
        XCTAssertEqual(font.pointSize, 20)
        XCTAssertEqual(displayed.string, original.string)
        XCTAssertEqual(displayed.attribute(.link, at: 2, effectiveRange: nil) as? String, "https://example.invalid")
        XCTAssertEqual((displayed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.fontName, UIFont.systemFont(ofSize: 20).fontName)
        XCTAssertEqual((displayed.attribute(.font, at: 7, effectiveRange: nil) as? UIFont)?.fontName, UIFont.systemFont(ofSize: 20).fontName)
        XCTAssertTrue(renderer.attributedText(original, accountId: 2) === original)
        XCTAssertTrue(renderer.apply(nil, owner: owner))
        XCTAssertTrue(renderer.attributedText(original, accountId: 1) === original)
        XCTAssertNil(renderer.appliedSHA256(accountId: 1))
    }

    func testBlankFontIsNotInstalledAndOldGlyphRemainsApplied() throws {
        let renderer = ExteralessEmojiRendering.shared
        let owner = renderer.begin(accountId: 3)
        defer { renderer.clear(owner: owner) }
        let previous = try renderer.prepare(data: EmojiFontFixture.data, fileExtension: "ttf", owner: owner)
        XCTAssertTrue(renderer.apply(previous, owner: owner))
        XCTAssertThrowsError(try renderer.prepare(data: EmojiFontFixture.blank, fileExtension: "ttf", owner: owner)) { XCTAssertEqual($0 as? EmojiPackError, .registrationFailed) }
        XCTAssertEqual(renderer.appliedSHA256(accountId: 3), EmojiFontFixture.sha256)
    }

    func testNewAccountRetiresOldRegistrationOwner() throws {
        let renderer = ExteralessEmojiRendering.shared
        let old = renderer.begin(accountId: 4)
        let new = renderer.begin(accountId: 5)
        defer { renderer.clear(owner: new) }
        XCTAssertThrowsError(try renderer.prepare(data: EmojiFontFixture.data, fileExtension: "ttf", owner: old)) { XCTAssertEqual($0 as? EmojiPackError, .cancelled) }
        let face = try renderer.prepare(data: EmojiFontFixture.data, fileExtension: "ttf", owner: new)
        XCTAssertFalse(renderer.apply(face, owner: old))
        XCTAssertTrue(renderer.apply(face, owner: new))
        renderer.clear(owner: old)
        XCTAssertEqual(renderer.appliedSHA256(accountId: 5), EmojiFontFixture.sha256)
    }

    func testSameSourcePostScriptNameUpdatesWhileOldUIFontIsRetained() throws {
        let renderer = ExteralessEmojiRendering.shared
        let owner = renderer.begin(accountId: 6)
        defer { renderer.clear(owner: owner) }
        let old = try renderer.prepare(data: EmojiFontFixture.data, fileExtension: "ttf", owner: owner)
        XCTAssertTrue(renderer.apply(old, owner: owner))
        let oldUIFont = renderer.font(for: "😀", size: 24, accountId: 6, fallback: .systemFont(ofSize: 24))
        let updated = try renderer.prepare(data: EmojiFontFixture.narrow, fileExtension: "ttf", owner: owner)
        XCTAssertTrue(renderer.apply(updated, owner: owner))
        let updatedUIFont = renderer.font(for: "😀", size: 24, accountId: 6, fallback: .systemFont(ofSize: 24))
        XCTAssertNotEqual(oldUIFont.fontName, updatedUIFont.fontName)
        XCTAssertEqual(renderer.appliedSHA256(accountId: 6), ToolsSHA256.hex(EmojiFontFixture.narrow))
        XCTAssertEqual(oldUIFont.fontName, EmojiFontRegistration.privateName(sha256: EmojiFontFixture.sha256))
    }
}
