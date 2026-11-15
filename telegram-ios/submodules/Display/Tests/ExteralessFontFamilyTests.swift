import CoreGraphics
import CoreText
import Display
import ExteralessCore
import Foundation
import UIKit
import XCTest

/// Run only in the loginless NativeTestHost with the actual pinned font resources.
/// These tests exercise public Font producers and real CoreText/TextNode layout.
@MainActor
final class ExteralessFontFamilyTests: XCTestCase {
    private func withSettings(_ body: (ClientSettings, URL) throws -> Void) throws {
        // Registration precedes even the first publication of the definition.
        try ExteralessFontFamily.prepare()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-fonts-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("settings.json")
        let settings = ClientSettings.shared
        try settings.configure(storageURL: url)
        let fallback = try XCTUnwrap(AppearanceAdditionalFeatures.definitions.first { $0.key == "appearance.forceFontWeightFallback" })
        try settings.register(CoreAppearanceFontFamilyPolicy.definitions + [fallback])
        defer {
            try? settings.reset(CoreAppearanceFontFamilyPolicy.key)
            try? settings.reset(fallback.key)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(settings, url)
    }

    private func sansSerifFonts(_ size: CGFloat) -> [UIFont] {
        return [Font.regular(size), Font.light(size), Font.medium(size), Font.semibold(size), Font.bold(size),
            Font.heavy(size), Font.italic(size), Font.mediumItalic(size), Font.semiboldItalic(size)]
    }

    private func variation(_ font: UIFont, axis: UInt32) throws -> Double {
        let values = try XCTUnwrap(CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber])
        return try XCTUnwrap(values[NSNumber(value: axis)]).doubleValue
    }

    private func outline(_ font: UIFont) throws -> CGPath {
        var character: UniChar = 0x52 // R: shared nontrivial Latin outline
        var glyph: CGGlyph = 0
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font as CTFont, &character, &glyph, 1))
        XCTAssertNotEqual(glyph, 0)
        return try XCTUnwrap(CTFontCreatePathForGlyph(font as CTFont, glyph, nil))
    }

    private func bitmap(_ line: CTLine) throws -> Data {
        let width = 640
        let height = 128
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.textPosition = CGPoint(x: 16, y: 40)
        CTLineDraw(line, context)
        return Data(bytes: try XCTUnwrap(context.data), count: width * height * 4)
    }

    func testPublicProducersUseTheRealSystemOrBundledFamily() throws {
        try self.withSettings { settings, _ in
            let system = Font.regular(19)
            XCTAssertEqual(system.fontName, UIFont.systemFont(ofSize: 19).fontName)
            for font in self.sansSerifFonts(19) {
                XCTAssertEqual(font.familyName, UIFont.systemFont(ofSize: 19).familyName)
                XCTAssertEqual(font.pointSize, 19)
            }
            try settings.setPublic(.bool(false), for: CoreAppearanceFontFamilyPolicy.key)
            for font in self.sansSerifFonts(19) {
                XCTAssertEqual(CTFontCopyFamilyName(font as CTFont) as String, "Roboto")
                XCTAssertEqual(font.pointSize, 19)
            }
            XCTAssertNotNil(UIFont(name: "Roboto-Regular", size: 19), "registered in this process, not a manufactured alias")
            XCTAssertNotNil(UIFont(name: "Roboto-Italic", size: 19))
            XCTAssertFalse(CFEqual(try self.outline(system), try self.outline(Font.regular(19))))
            let retained = Font.regular(19)
            try settings.reset(CoreAppearanceFontFamilyPolicy.key)
            XCTAssertTrue(Font.regular(19) === system, "system and Roboto cache entries are separate")
            try settings.set(.bool(false), for: CoreAppearanceFontFamilyPolicy.key)
            XCTAssertTrue(Font.regular(19) === retained)
        }
    }

    func testActualVariableOutlinesWeightsItalicAndTabularDigits() throws {
        try self.withSettings { settings, _ in
            let weights: [(Font.Weight, UIFont.Weight, Double)] = [(.thin, .thin, 200), (.light, .light, 300), (.regular, .regular, 400),
                (.medium, .medium, 500), (.semibold, .semibold, 600), (.bold, .bold, 700), (.heavy, .heavy, 800)]
            for system in [true, false] {
                try settings.set(.bool(system), for: CoreAppearanceFontFamilyPolicy.key)
                for (weight, nativeWeight, expected) in weights {
                    for italic in [false, true] {
                        let traits: Font.Traits = italic ? [.italic, .monospacedNumbers] : [.monospacedNumbers]
                        let font = Font.with(size: 23.5, weight: weight, traits: traits)
                        XCTAssertEqual(font.pointSize, 23.5)
                        XCTAssertEqual(CTFontGetSymbolicTraits(font as CTFont).contains(.traitItalic), italic)
                        XCTAssertEqual(CTFontGetSymbolicTraits(font as CTFont).contains(.traitBold),
                            CTFontGetSymbolicTraits(UIFont.systemFont(ofSize: 23.5, weight: nativeWeight) as CTFont).contains(.traitBold))
                        if !system {
                            XCTAssertEqual(try self.variation(font, axis: 0x77676874), expected, accuracy: 0.01)
                            XCTAssertEqual(try self.variation(font, axis: 0x77647468), 100, accuracy: 0.01)
                        }
                        let one = CTLineCreateWithAttributedString(NSAttributedString(string: "11111", attributes: [.font: font]))
                        let eight = CTLineCreateWithAttributedString(NSAttributedString(string: "88888", attributes: [.font: font]))
                        XCTAssertEqual(CTLineGetTypographicBounds(one, nil, nil, nil), CTLineGetTypographicBounds(eight, nil, nil, nil), accuracy: 0.01)
                    }
                }
            }
            XCTAssertFalse(CFEqual(try self.outline(Font.with(size: 23.5, weight: .thin)), try self.outline(Font.bold(23.5))),
                "different axis metadata must produce different glyphs")
            XCTAssertFalse(CFEqual(try self.outline(Font.regular(23.5)), try self.outline(Font.italic(23.5))))
            let condensed = Font.with(size: 23.5, weight: .bold, width: .condensed, traits: .italic)
            XCTAssertEqual(try self.variation(condensed, axis: 0x77647468), 75, accuracy: 0.01)
            XCTAssertEqual(try self.variation(condensed, axis: 0x77676874), 700, accuracy: 0.01)
            XCTAssertTrue(CTFontGetSymbolicTraits(condensed as CTFont).contains(.traitItalic))

            try settings.set(.bool(true), for: "appearance.forceFontWeightFallback")
            for font in [Font.medium(23.5), Font.semibold(23.5), Font.mediumItalic(23.5), Font.semiboldItalic(23.5)] {
                XCTAssertEqual(font.familyName, "Roboto")
                XCTAssertEqual(try self.variation(font, axis: 0x77676874), 700, accuracy: 0.01)
            }
            XCTAssertTrue(CTFontGetSymbolicTraits(Font.mediumItalic(23.5) as CTFont).contains(.traitItalic))
            XCTAssertFalse(CoreAppearanceFontFamilyPolicy.useSystemFonts(in: settings))
        }
    }

    func testExplicitRolesAndDynamicTypeSizesArePreserved() throws {
        try self.withSettings { settings, _ in
            func specialized() -> [UIFont] {
                return [Font.monospace(21), Font.semiboldMonospace(21), Font.italicMonospace(21), Font.semiboldItalicMonospace(21),
                    Font.with(size: 21, design: .serif, weight: .bold, traits: .italic),
                    Font.with(size: 21, design: .monospace, weight: .semibold, traits: .italic),
                    Font.with(size: 21, design: .round, weight: .medium), Font.with(size: 21, design: .camera),
                    Font.with(size: 21, width: .expanded), Font.with(size: 21, width: .compressed),
                    Font.with(size: 21, traits: .alternateDollarSign)]
            }
            let originals = specialized()
            let categories: [UIContentSizeCategory] = [.large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge]
            let metrics = UIFontMetrics(forTextStyle: .body)
            let systemSizes = categories.map { metrics.scaledFont(for: Font.regular(17), compatibleWith: UITraitCollection(preferredContentSizeCategory: $0)).pointSize }
            try settings.set(.bool(false), for: CoreAppearanceFontFamilyPolicy.key)
            for (before, after) in zip(originals, specialized()) {
                XCTAssertEqual(before.fontName, after.fontName)
                XCTAssertEqual(before.pointSize, after.pointSize)
                XCTAssertEqual(before.fontDescriptor.symbolicTraits, after.fontDescriptor.symbolicTraits)
            }
            for (index, category) in categories.enumerated() {
                let font = metrics.scaledFont(for: Font.regular(17), compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
                XCTAssertEqual(font.familyName, "Roboto")
                XCTAssertEqual(font.pointSize, systemSizes[index], accuracy: 0.01)
                XCTAssertEqual(Font.regular(font.pointSize).pointSize, font.pointSize, "already scaled sizes are not scaled a second time")
                let styled = metrics.scaledFont(for: Font.mediumItalic(17), compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
                XCTAssertEqual(styled.pointSize, systemSizes[index], accuracy: 0.01)
                XCTAssertEqual(try self.variation(styled, axis: 0x77676874), 500, accuracy: 0.01)
                XCTAssertTrue(CTFontGetSymbolicTraits(styled as CTFont).contains(.traitItalic))
            }
            XCTAssertGreaterThan(systemSizes.last ?? 0, systemSizes.first ?? 0)
        }
    }

    func testReloadPublishesUsableFontsAndRetainsOldCoreTextLines() throws {
        try self.withSettings { settings, url in
            let external = try ClientSettings(storageURL: url)
            try external.register(CoreAppearanceFontFamilyPolicy.definitions)
            try external.setPublic(.bool(false), for: CoreAppearanceFontFamilyPolicy.key)
            let observed = self.expectation(description: "reload observer uses registered Roboto")
            let observation = settings.observe { keys in
                guard keys.contains(CoreAppearanceFontFamilyPolicy.key) else { return }
                XCTAssertEqual(Font.regular(24).familyName, "Roboto")
                observed.fulfill()
            }
            try settings.reload()
            observation.cancel()
            self.wait(for: [observed], timeout: 1)
            let retained = Font.mediumItalic(24)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Roboto 漢字 👩🏽‍💻", attributes: [.font: retained, .foregroundColor: UIColor.black]))
            let before = try self.bitmap(line)
            XCTAssertTrue(stride(from: 3, to: before.count, by: 4).contains { before[$0] != 0 })
            for _ in 0..<3 {
                try external.reset(CoreAppearanceFontFamilyPolicy.key)
                try settings.reload()
                XCTAssertEqual(Font.regular(24).fontName, UIFont.systemFont(ofSize: 24).fontName)
                try ExteralessFontFamily.prepare()
                XCTAssertEqual(try self.bitmap(line), before, "an existing CTLine must still draw after family reset")
                try external.setPublic(.bool(false), for: CoreAppearanceFontFamilyPolicy.key)
                try settings.reload()
                XCTAssertTrue(Font.mediumItalic(24) === retained)
            }
        }
    }

    func testRealTextNodeFallbackUTF16LinksAndBoundsAcrossTraits() throws {
        try self.withSettings { settings, _ in
            let string = "Roboto e\u{301} Привет Ελληνικά العربية हिन्दी 漢字 かな 한글 👩🏽‍💻 🇯🇵 link"
            let nsString = string as NSString
            let linkRange = nsString.range(of: "link")
            let cjkRange = nsString.range(of: "漢字")
            let emojiRange = nsString.range(of: "👩🏽‍💻")
            let combinations: [Font.Traits] = [[], .italic, [.italic, .monospacedNumbers]]
            let sizes: [CGFloat] = [17, 32]
            XCTAssertGreaterThan(nsString.length, string.count)
            for system in [true, false] {
                try settings.set(.bool(system), for: CoreAppearanceFontFamilyPolicy.key)
                for traits in combinations {
                    for size in sizes {
                        let font = Font.with(size: size, weight: .semibold, traits: traits)
                        let text = NSMutableAttributedString(string: string, attributes: [.font: font, .foregroundColor: UIColor.black])
                        text.addAttribute(.link, value: "https://fixture.invalid/fonts", range: linkRange)
                        let original = NSAttributedString(attributedString: text)
                        let (layout, _) = TextNode.asyncLayout(nil)(TextNodeLayoutArguments(attributedString: text,
                            maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: 260, height: 4096)))
                        XCTAssertFalse(layout.truncated)
                        XCTAssertTrue(layout.size.width.isFinite && layout.size.height.isFinite)
                        XCTAssertLessThanOrEqual(layout.size.width, 261)
                        XCTAssertGreaterThan(layout.size.height, size)
                        XCTAssertTrue(text.isEqual(to: original), "layout must preserve the string and every entity attribute")
                        let attributed = try XCTUnwrap(layout.attributedString)
                        XCTAssertEqual(attributed.attribute(.link, at: linkRange.location, effectiveRange: nil) as? String, "https://fixture.invalid/fonts")
                        for range in [cjkRange, emojiRange, linkRange] {
                            let rects = try XCTUnwrap(layout.rangeRects(in: range)).rects
                            XCTAssertFalse(rects.isEmpty)
                            for rect in rects {
                                XCTAssertTrue(rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite)
                                XCTAssertGreaterThan(rect.width, 0)
                                XCTAssertGreaterThan(rect.height, 0)
                                XCTAssertGreaterThanOrEqual(rect.minX, -1)
                                XCTAssertGreaterThanOrEqual(rect.minY, -1)
                                XCTAssertLessThanOrEqual(rect.maxX, layout.size.width + 1)
                                XCTAssertLessThanOrEqual(rect.maxY, layout.size.height + 1)
                            }
                        }
                        var cjkFallback = false
                        var emojiFallback = false
                        layout.enumerateRenderedLines(in: CGRect(origin: .zero, size: layout.size)) { line, _ in
                            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                                let range = CTRunGetStringRange(run)
                                XCTAssertGreaterThanOrEqual(range.location, 0)
                                XCTAssertLessThanOrEqual(range.location + range.length, nsString.length)
                                let runRange = NSRange(location: range.location, length: range.length)
                                let attributes = CTRunGetAttributes(run) as NSDictionary
                                let runFont = attributes[kCTFontAttributeName] as! CTFont
                                if NSIntersectionRange(runRange, cjkRange).length > 0 || NSIntersectionRange(runRange, emojiRange).length > 0 {
                                    XCTAssertNotEqual(CTFontCopyFamilyName(runFont) as String, "Roboto")
                                    let count = CTRunGetGlyphCount(run)
                                    XCTAssertGreaterThan(count, 0)
                                    var glyphs = [CGGlyph](repeating: 0, count: count)
                                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                                    XCTAssertFalse(glyphs.contains(0), "supported CJK/emoji must not shape to .notdef")
                                    cjkFallback = cjkFallback || NSIntersectionRange(runRange, cjkRange).length > 0
                                    emojiFallback = emojiFallback || NSIntersectionRange(runRange, emojiRange).length > 0
                                }
                            }
                        }
                        XCTAssertTrue(cjkFallback)
                        XCTAssertTrue(emojiFallback)
                    }
                }
            }
        }
    }
}
