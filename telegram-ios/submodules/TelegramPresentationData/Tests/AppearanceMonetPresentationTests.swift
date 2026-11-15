import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import UIKit
import XCTest

/// Loginless, in-memory native factories/codecs/signals. Intended for the existing
/// prepared native host with a <=30s per-class execution budget, not a full build.
final class AppearanceMonetPresentationTests: XCTestCase {
    private func reference(_ id: Int64 = 9001) -> PresentationThemeReference {
        return .local(PresentationLocalTheme(title: "Monet fixture", resource: LocalFileMediaResource(fileId: id), resolvedWallpaper: nil))
    }

    @MainActor
    func testSixNativeFactoriesMatchIndependentReferenceColorsAndTextContrast() throws {
        // Oracle: pinned MCU TypeScript + Original role tones. NOT recorded by
        // the Swift implementation. docs/wave-2/monet-reference.mjs, seed 007AFF.
        let vectors: [(AppearanceMonetStyle, AppearanceMonetMode, UInt32, UInt32, UInt32)] = [
            (.telemone, .light, 0xfaf9ff, 0xe1e2ec, 0xd8e2ff),
            (.telemone, .dark, 0x11131a, 0x32353c, 0x004493),
            (.telemone, .amoled, 0x000000, 0x32353c, 0x004493),
            (.classic, .light, 0xffffff, 0xf2f0f4, 0x005bc1),
            (.classic, .dark, 0x1b1b1f, 0x303033, 0xadc6ff),
            (.classic, .amoled, 0x000000, 0x303033, 0xadc6ff)
        ]
        var previous: PresentationTheme?
        for (style, mode, background, incoming, outgoing) in vectors {
            let descriptor = AppearanceMonetDescriptor(mode: mode, seedRGB: 0x007aff, renderedStyle: style)
            let theme = makeExteralessMonetPresentationTheme(descriptor: descriptor, index: self.reference().index)
            XCTAssertEqual(theme.list.blocksBackgroundColor.rgb, background)
            XCTAssertEqual(theme.chatList.backgroundColor.rgb, background)
            XCTAssertEqual(theme.chat.defaultWallpaper, .color(background))
            XCTAssertEqual(theme.chat.message.incoming.bubble.withWallpaper.fill.map(\.rgb), [incoming])
            XCTAssertEqual(theme.chat.message.incoming.bubble.withoutWallpaper.fill.map(\.rgb), [incoming])
            XCTAssertEqual(theme.chat.message.outgoing.bubble.withWallpaper.fill.map(\.rgb), [outgoing])
            XCTAssertEqual(theme.chat.message.outgoing.bubble.withoutWallpaper.fill.map(\.rgb), [outgoing])
            XCTAssertEqual(theme.overallDarkAppearance, mode.isDark)
            XCTAssertEqual(theme.rootController.keyboardColor, mode.isDark ? .dark : .light)
            XCTAssertEqual(theme.rootController.statusBarStyle, mode.isDark ? .white : .black)
            XCTAssertEqual(theme.index, self.reference().index)
            XCTAssertEqual(exteralessMonetDescriptor(theme), descriptor)
            if let previous { XCTAssertFalse(previous.resourceCache === theme.resourceCache) }
            previous = theme
            let pairs: [(UIColor, UIColor)] = [
                (theme.list.itemPrimaryTextColor, theme.list.itemBlocksBackgroundColor),
                (theme.list.itemSecondaryTextColor, theme.list.itemBlocksBackgroundColor),
                (theme.rootController.navigationBar.primaryTextColor, theme.rootController.navigationBar.opaqueBackgroundColor),
                (theme.rootController.navigationBar.buttonColor, theme.rootController.navigationBar.opaqueBackgroundColor),
                (theme.chat.message.incoming.primaryTextColor, UIColor(rgb: incoming)),
                (theme.chat.message.incoming.linkTextColor, UIColor(rgb: incoming)),
                (theme.chat.message.outgoing.primaryTextColor, UIColor(rgb: outgoing)),
                (theme.chat.message.outgoing.linkTextColor, UIColor(rgb: outgoing)),
                (theme.chat.inputPanel.inputTextColor, theme.chat.inputPanel.inputBackgroundColor),
                (theme.chat.inputPanel.inputPlaceholderColor, theme.chat.inputPanel.inputBackgroundColor),
                (theme.chat.inputPanel.actionControlForegroundColor, theme.chat.inputPanel.actionControlFillColor)
            ]
            for (foreground, background) in pairs {
                XCTAssertGreaterThanOrEqual(ExteralessMonetPalette.contrast(foreground.argb, background.argb), 4.5, "\(style) / \(mode)")
            }
        }
    }

    func testMonetHelperToneLinkAndHarmonizationReferenceVectors() throws {
        let purple = ExteralessMonetPalette(seedRGB: 0x6750a4)
        let vectors: [(String, UInt32)] = [
            ("a1_600", 0xff6750a4), ("primary_40", 0xff6750a4),
            ("monet_primary_light", 0xff6750a4), ("primary_dark", 0xffcfbcff),
            ("background_light", 0xfffef7ff), ("background_dark", 0xff151219),
            ("surface_container_high_dark", 0xff2b2931),
            ("surface_container_highest_dark", 0xff36333b),
            ("primary_fixed", 0xffe9ddff), ("mRed500", 0xfff53b68),
            ("blue_50", 0xff766eb9), ("primary_light(a=50)", 0x7f6750a4)
        ]
        for (token, expected) in vectors { XCTAssertEqual(try XCTUnwrap(purple.color(token)), expected, token) }
        let gray = ExteralessMonetPalette(seedRGB: 0x777777)
        XCTAssertTrue(gray.isAccentNeutral)
        XCTAssertEqual(gray.color("primary_light"), 0xff5e5e5e)
        XCTAssertEqual(gray.color("primary_light", forLink: true), 0xff00629d)
        XCTAssertEqual(gray.color("primary_dark", forLink: true), 0xff99cbff)
        XCTAssertEqual(gray.color("primary_light(a=50)", forLink: true), 0x7f00629d)
        XCTAssertEqual(gray.color("neutral_40", forLink: true), 0xff5e5e5e, "only accent tokens get the link hue fallback")
        XCTAssertFalse(purple.isAccentNeutral)
        for token in ["unknown", "a1_999", "primary_98", "primary_fixed_light", "monetRedLight", "white(a=500)", String(repeating: "monet_", count: 40)] {
            XCTAssertNil(purple.color(token), token)
        }
    }

    @MainActor
    func testRealThemeCodecAndReloadKeepDescriptorIndexWallpaperAndFreshCache() throws {
        let reference = self.reference()
        let descriptor = AppearanceMonetDescriptor(mode: .dark, seedRGB: 0x6750a4, renderedStyle: .telemone)
        let theme = makeExteralessMonetPresentationTheme(descriptor: descriptor, index: reference.index, wallpaper: .color(0x123456))
        let data = try XCTUnwrap(encodePresentationTheme(theme)?.data(using: .utf8))
        let loaded = try XCTUnwrap(makePresentationTheme(data: data, themeReference: reference))
        loaded.forceSync = true
        let nextStyle: AppearanceMonetStyle = exteralessMonetDescriptor(loaded)?.renderedStyle == .classic ? .telemone : .classic
        let reloaded = exteralessMonetAppearanceTheme(loaded, style: nextStyle)
        XCTAssertEqual(reloaded.index, reference.index)
        XCTAssertEqual(exteralessMonetDescriptor(reloaded)?.seedRGB, 0x6750a4)
        XCTAssertEqual(exteralessMonetDescriptor(reloaded)?.mode, .dark)
        XCTAssertEqual(exteralessMonetDescriptor(reloaded)?.renderedStyle, nextStyle)
        XCTAssertEqual(reloaded.chat.defaultWallpaper, .color(0x123456))
        XCTAssertTrue(reloaded.forceSync)
        XCTAssertFalse(reloaded === loaded)
        XCTAssertFalse(reloaded.resourceCache === loaded.resourceCache)
        XCTAssertTrue(exteralessMonetAppearanceTheme(reloaded, style: nextStyle) === reloaded)
        let replay = ExteralessMonetThemeReplay()
        let memo = replay.theme(source: loaded, style: nextStyle)
        XCTAssertTrue(replay.theme(source: loaded, style: nextStyle) === memo)
        let nativeRevision = loaded.withUpdated(name: nil, defaultWallpaper: .color(0xabcdef))
        let revised = replay.theme(source: nativeRevision, style: nextStyle)
        XCTAssertFalse(revised === memo, "same native index is not sufficient as a palette memo key")
        XCTAssertEqual(revised.chat.defaultWallpaper, .color(0xabcdef))
        let ordinary = makeDefaultPresentationTheme(reference: .day, serviceBackgroundColor: nil).withUpdated(name: "Monet Light", defaultWallpaper: nil)
        XCTAssertNil(exteralessMonetDescriptor(ordinary))
        XCTAssertTrue(exteralessMonetAppearanceTheme(ordinary, style: .classic) === ordinary)
        XCTAssertTrue(customizePresentationTheme(ordinary, editing: false, accentColor: nil, outgoingAccentColor: nil, backgroundColors: [], bubbleColors: [], animateBubbleColors: nil) === ordinary)
    }

    @MainActor
    func testActualNativeCustomizerUsesNewSeedAndPreservesExplicitBubbleAndWallpaperOverrides() throws {
        let descriptor = AppearanceMonetDescriptor(mode: .light, seedRGB: 0x007aff, renderedStyle: .telemone)
        let source = makeExteralessMonetPresentationTheme(descriptor: descriptor, index: self.reference().index)
        let bubbleColors: [UInt32] = [0x225533, 0x447755]
        let customized = customizePresentationTheme(source, editing: false, accentColor: UIColor(rgb: 0xd33213), outgoingAccentColor: nil, backgroundColors: [], bubbleColors: bubbleColors, animateBubbleColors: true, wallpaper: .color(0x443322))
        XCTAssertEqual(exteralessMonetDescriptor(customized)?.seedRGB, 0xd33213)
        XCTAssertEqual(exteralessMonetDescriptor(customized)?.nativeOutgoingOverride, true)
        XCTAssertEqual(customized.chat.message.outgoing.bubble.withWallpaper.fill.map(\.rgb), bubbleColors)
        XCTAssertEqual(customized.chat.defaultWallpaper, .color(0x443322))
        XCTAssertTrue(customized.chat.animateMessageColors)
        let nextStyle: AppearanceMonetStyle = exteralessMonetDescriptor(customized)?.renderedStyle == .classic ? .telemone : .classic
        let restyled = exteralessMonetAppearanceTheme(customized, style: nextStyle)
        XCTAssertTrue(restyled.chat.message.outgoing === customized.chat.message.outgoing)
        XCTAssertEqual(restyled.chat.defaultWallpaper, customized.chat.defaultWallpaper)
        XCTAssertTrue(restyled.chat.animateMessageColors)
        XCTAssertEqual(restyled.index, source.index)
        XCTAssertEqual(source.chat.message.outgoing.bubble.withWallpaper.fill.map(\.rgb), [0xd8e2ff], "source is immutable")
    }

    func testNativePreferenceCodecAndNightSlotMergePreserveOtherSettings() throws {
        var settings = PresentationThemeSettings.defaultSettings
        settings.automaticThemeSwitchSetting.force = true
        settings.useSystemFont = false
        settings.fontSize = .extraLarge
        settings.listsFontSize = .small
        settings.largeEmoji = false
        settings.reduceMotion = true
        settings.themeSpecificChatWallpapers[settings.theme.index] = .color(0x334455)
        settings.themeSpecificAccentColors[settings.theme.index] = PresentationThemeAccentColor(baseColor: .purple)
        let reference = self.reference()
        let updated = try XCTUnwrap(exteralessMonetReplacingTheme(in: settings, slot: .night, expected: settings.automaticThemeSwitchSetting.theme, replacement: reference))
        let data = try JSONEncoder().encode(updated)
        let restored = try JSONDecoder().decode(PresentationThemeSettings.self, from: data)
        XCTAssertEqual(restored.theme, settings.theme)
        XCTAssertEqual(restored.automaticThemeSwitchSetting.theme, reference)
        XCTAssertEqual(restored.automaticThemeSwitchSetting.trigger, settings.automaticThemeSwitchSetting.trigger)
        XCTAssertTrue(restored.automaticThemeSwitchSetting.force)
        XCTAssertEqual(restored.themeSpecificChatWallpapers, settings.themeSpecificChatWallpapers)
        XCTAssertEqual(restored.themeSpecificAccentColors, settings.themeSpecificAccentColors)
        XCTAssertEqual(restored.fontSize, settings.fontSize)
        XCTAssertEqual(restored.listsFontSize, settings.listsFontSize)
        XCTAssertEqual(restored.useSystemFont, settings.useSystemFont)
        XCTAssertEqual(restored.largeEmoji, settings.largeEmoji)
        XCTAssertEqual(restored.reduceMotion, settings.reduceMotion)
        XCTAssertNil(exteralessMonetReplacingTheme(in: restored, slot: .night, expected: settings.automaticThemeSwitchSetting.theme, replacement: self.reference(9002)), "an obsolete editor cannot replace a newer native selection")
        let dayUpdated = try XCTUnwrap(exteralessMonetReplacingTheme(in: restored, slot: .day, expected: restored.theme, replacement: self.reference(9003)))
        XCTAssertEqual(dayUpdated.automaticThemeSwitchSetting, restored.automaticThemeSwitchSetting)
    }

    @MainActor
    func testAppearanceReplayUsesOneNativeSubscriptionAndPreservesNightAndExplicitWallpaper() throws {
        let defaults = defaultPresentationData()
        let theme = makeExteralessMonetPresentationTheme(descriptor: AppearanceMonetDescriptor(mode: .amoled, seedRGB: 0x007aff, renderedStyle: .telemone), index: self.reference().index)
        let source = PresentationData(strings: defaults.strings, theme: theme, autoNightModeTriggered: true, chatWallpaper: .color(0xdecade), chatFontSize: defaults.chatFontSize, chatBubbleCorners: defaults.chatBubbleCorners, listsFontSize: defaults.listsFontSize, dateTimeFormat: defaults.dateTimeFormat, nameDisplayOrder: defaults.nameDisplayOrder, nameSortOrder: defaults.nameSortOrder, reduceMotion: true, largeEmoji: false)
        let revisions = ValuePipe<Void>()
        var style = AppearanceMonetStyle.telemone
        var subscriptions = 0
        let native = Signal<PresentationData, NoError> { subscriber in
            subscriptions += 1
            subscriber.putNext(source)
            return EmptyDisposable
        }
        var values: [PresentationData] = []
        let first = expectation(description: "first native value")
        let changed = expectation(description: "new style without a second file loader")
        let disposable = exteralessAppearancePresentationData(native: native, updates: revisions.signal(), dateTimeFormat: { defaults.dateTimeFormat }, hideDividers: { false }, monetStyle: { style }).start(next: { value in
            values.append(value)
            if values.count == 1 { first.fulfill() } else { changed.fulfill() }
        })
        revisions.putNext(())
        wait(for: [first], timeout: 1)
        style = .classic
        revisions.putNext(())
        wait(for: [changed], timeout: 1)
        let result = try XCTUnwrap(values.last)
        XCTAssertEqual(subscriptions, 1)
        XCTAssertTrue(result.autoNightModeTriggered)
        XCTAssertEqual(result.chatWallpaper, source.chatWallpaper)
        XCTAssertEqual(result.chatFontSize, source.chatFontSize)
        XCTAssertEqual(result.listsFontSize, source.listsFontSize)
        XCTAssertTrue(result.reduceMotion)
        XCTAssertFalse(result.largeEmoji)
        XCTAssertEqual(result.theme.chat.message.outgoing.bubble.withWallpaper.fill.map(\.rgb), [0xadc6ff])
        XCTAssertEqual(result.theme.index, source.theme.index)
        XCTAssertFalse(result.theme.resourceCache === values[0].theme.resourceCache)
        disposable.dispose()
        revisions.putNext(())
        let drained = expectation(description: "disposed stream drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertEqual(values.count, 2)
    }
}
