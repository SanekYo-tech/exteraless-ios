import Display
import ExteralessCore
import Foundation
import TelegramCore
import TelegramUIPreferences
import UIKit

/// Only intentionally selected, descriptor-bearing native *local* themes are
/// admitted. A stock/cloud theme or an ordinary theme named Monet is not opted in.
public func exteralessMonetDescriptor(_ theme: PresentationTheme) -> AppearanceMonetDescriptor? {
    guard theme.index >> 32 == 1, case let .custom(name) = theme.name else { return nil }
    return AppearanceMonetDescriptor(encodedThemeName: name)
}

private func exteralessCurrentMonetStyle(fallback: AppearanceMonetStyle) -> AppearanceMonetStyle {
    // Prepared app/extension schemas supply the real default even if no override
    // is stored. An unprepared decoder keeps the saved snapshot's style until
    // preparation publishes a cache value; it must not invent a Telemone reset.
    guard case let .integer(raw)? = ClientSettings.shared.value(AppearanceMonetPolicy.settingKey) else { return fallback }
    return raw == 1 ? .classic : .telemone
}

/// Creates real Telegram presentation colors and a fresh native resource cache.
/// No image cache is mutated and no resource file is read. A caller choosing a
/// theme supplies its fresh local reference index; regeneration keeps that index.
public func makeExteralessMonetPresentationTheme(descriptor: AppearanceMonetDescriptor, index: Int64, preview: Bool = false, source: PresentationTheme? = nil, wallpaper: TelegramWallpaper? = nil) -> PresentationTheme {
    let dark = descriptor.mode.isDark
    let base = source ?? makeDefaultPresentationTheme(reference: dark ? .night : .day, serviceBackgroundColor: nil, preview: preview)
    let palette = ExteralessMonetPalette(seedRGB: descriptor.seedRGB)
    let tokens = AppearanceMonetTokens(style: descriptor.renderedStyle, mode: descriptor.mode)
    func color(_ token: String, link: Bool = false) -> UIColor {
        guard let argb = palette.color(token, forLink: link) else { preconditionFailure("Invalid native Monet role: \(token)") }
        return UIColor(argb: argb)
    }
    func readable(_ foreground: UIColor, _ background: UIColor) -> UIColor {
        return UIColor(argb: ExteralessMonetPalette.readable(foreground.argb, on: background.argb))
    }
    let background = color(tokens.background)
    let surface = color(tokens.surface)
    let raised = color(tokens.raisedSurface)
    let navigation = color(tokens.navigation)
    let primary = readable(color(tokens.primaryText), raised)
    let secondary = readable(color(tokens.secondaryText), raised)
    let accent = readable(color(tokens.accent), raised)
    let onAccent = readable(color(tokens.onAccent), accent)
    let separator = color(tokens.separator)
    let inputFill = color(tokens.inputFill)
    let inputText = readable(primary, inputFill)
    let inputSecondary = readable(secondary, inputFill)
    let error = readable(color(dark ? "error_dark" : "error_light"), raised)
    let success = readable(UIColor(argb: palette.harmonize(0xff4caf50)), raised)
    let serviceFill = color(tokens.serviceFill)
    let serviceText = readable(color(tokens.serviceText), serviceFill)
    let link = readable(color(tokens.link, link: true), background)
    let highlighted = surface.mixedWith(accent, alpha: dark ? 0.12 : 0.08)
    let inputField = PresentationInputFieldTheme(backgroundColor: inputFill, strokeColor: separator, placeholderColor: inputSecondary, primaryColor: inputText, controlColor: accent)

    let root = base.rootController.withUpdated(
        statusBarStyle: dark ? .white : .black,
        tabBar: base.rootController.tabBar.withUpdated(backgroundColor: navigation, separatorColor: separator, iconColor: secondary, selectedIconColor: accent, textColor: secondary, selectedTextColor: accent, badgeBackgroundColor: accent, badgeStrokeColor: navigation, badgeTextColor: onAccent),
        navigationBar: base.rootController.navigationBar.withUpdated(buttonColor: accent, disabledButtonColor: secondary.withAlphaComponent(0.4), primaryTextColor: primary, secondaryTextColor: secondary, controlColor: accent, accentTextColor: accent, blurredBackgroundColor: navigation, opaqueBackgroundColor: navigation, separatorColor: separator, badgeBackgroundColor: accent, badgeStrokeColor: navigation, badgeTextColor: onAccent, segmentedBackgroundColor: inputFill, segmentedForegroundColor: surface, segmentedTextColor: primary, segmentedDividerColor: separator, clearButtonBackgroundColor: raised, clearButtonForegroundColor: secondary),
        navigationSearchBar: base.rootController.navigationSearchBar.withUpdated(backgroundColor: navigation, accentColor: accent, inputFillColor: inputFill, inputTextColor: inputText, inputPlaceholderTextColor: inputSecondary, inputIconColor: inputSecondary, inputClearButtonColor: inputSecondary, separatorColor: separator),
        keyboardColor: dark ? .dark : .light
    )
    let list = base.list.withUpdated(
        blocksBackgroundColor: background, modalBlocksBackgroundColor: surface, plainBackgroundColor: background, modalPlainBackgroundColor: surface,
        itemPrimaryTextColor: primary, itemSecondaryTextColor: secondary, itemDisabledTextColor: secondary.withAlphaComponent(0.45), itemAccentColor: accent, itemHighlightedColor: accent, itemDestructiveColor: error, itemPlaceholderTextColor: secondary,
        itemBlocksBackgroundColor: surface, itemModalBlocksBackgroundColor: raised, itemHighlightedBackgroundColor: highlighted, itemBlocksSeparatorColor: separator, itemPlainSeparatorColor: separator,
        disclosureArrowColor: secondary, sectionHeaderTextColor: accent, freeTextColor: secondary, freeTextErrorColor: error, freeTextSuccessColor: success, freeMonoIconColor: secondary,
        itemSwitchColors: base.list.itemSwitchColors.withUpdated(frameColor: separator, handleColor: onAccent, contentColor: accent, positiveColor: accent, negativeColor: separator),
        itemDisclosureActions: base.list.itemDisclosureActions.withUpdated(accent: base.list.itemDisclosureActions.accent.withUpdated(fillColor: accent, foregroundColor: onAccent)),
        itemCheckColors: base.list.itemCheckColors.withUpdated(fillColor: accent, strokeColor: accent, foregroundColor: onAccent), controlSecondaryColor: separator,
        freeInputField: inputField, freePlainInputField: inputField, mediaPlaceholderColor: raised, scrollIndicatorColor: secondary, pageIndicatorInactiveColor: separator, inputClearButtonColor: secondary,
        itemBarChart: base.list.itemBarChart.withUpdated(color1: accent), itemInputField: inputField,
        paymentOption: PresentationThemeList.PaymentOption(inactiveFillColor: inputFill, inactiveForegroundColor: inputText, activeFillColor: accent, activeForegroundColor: onAccent)
    )
    let chatList = base.chatList.withUpdated(
        backgroundColor: background, itemSeparatorColor: separator, itemBackgroundColor: background, pinnedItemBackgroundColor: surface,
        itemHighlightedBackgroundColor: highlighted, pinnedItemHighlightedBackgroundColor: highlighted, itemSelectedBackgroundColor: highlighted,
        titleColor: primary, secretTitleColor: accent, dateTextColor: secondary, authorNameColor: accent, messageTextColor: secondary, messageHighlightedTextColor: primary, messageDraftTextColor: error,
        checkmarkColor: accent, pendingIndicatorColor: secondary, failedFillColor: error, failedForegroundColor: readable(primary, error), muteIconColor: secondary,
        unreadBadgeActiveBackgroundColor: accent, unreadBadgeActiveTextColor: onAccent, unreadBadgeInactiveBackgroundColor: raised, unreadBadgeInactiveTextColor: primary, reactionBadgeActiveBackgroundColor: accent,
        pinnedBadgeColor: secondary, pinnedSearchBarColor: inputFill, regularSearchBarColor: inputFill, sectionHeaderFillColor: surface, sectionHeaderTextColor: secondary,
        verifiedIconFillColor: accent, verifiedIconForegroundColor: onAccent, secretIconColor: accent, onlineDotColor: accent
    )

    func parted(_ original: PresentationThemePartedColors, fillToken: String, textToken: String, linkToken: String) -> PresentationThemePartedColors {
        let fill = color(fillToken)
        let text = readable(color(textToken), fill)
        let detail = readable(color(tokens.secondaryText), fill)
        let bubbleLink = readable(color(linkToken, link: true), fill)
        let bubbleAccent = readable(color(tokens.accent), fill)
        let inner = fill.mixedWith(text, alpha: 0.08)
        let reaction = fill.mixedWith(text, alpha: 0.12)
        let components = PresentationThemeBubbleColorComponents(
            fill: [fill], highlightedFill: fill.mixedWith(text, alpha: 0.1), stroke: .clear, shadow: nil,
            reactionInactiveBackground: reaction, reactionInactiveForeground: readable(bubbleAccent, reaction),
            reactionActiveBackground: bubbleAccent, reactionActiveForeground: readable(fill, bubbleAccent),
            reactionStarsInactiveBackground: original.bubble.withWallpaper.reactionStarsInactiveBackground,
            reactionStarsInactiveForeground: original.bubble.withWallpaper.reactionStarsInactiveForeground,
            reactionStarsActiveBackground: original.bubble.withWallpaper.reactionStarsActiveBackground,
            reactionStarsActiveForeground: original.bubble.withWallpaper.reactionStarsActiveForeground,
            reactionInactiveMediaPlaceholder: inner, reactionActiveMediaPlaceholder: inner
        )
        return original.withUpdated(
            bubble: PresentationThemeBubbleColor(withWallpaper: components, withoutWallpaper: components),
            primaryTextColor: text, secondaryTextColor: detail, linkTextColor: bubbleLink, linkHighlightColor: bubbleLink.withAlphaComponent(0.18), scamColor: readable(error, fill), textHighlightColor: bubbleAccent.withAlphaComponent(0.18),
            accentTextColor: bubbleAccent, accentControlColor: bubbleAccent, accentControlDisabledColor: bubbleAccent.withAlphaComponent(0.4), mediaActiveControlColor: bubbleAccent, mediaInactiveControlColor: detail, mediaControlInnerBackgroundColor: inner, pendingActivityColor: detail,
            fileTitleColor: text, fileDescriptionColor: detail, fileDurationColor: detail, mediaPlaceholderColor: inner,
            polls: original.polls.withUpdated(radioButton: detail, radioProgress: bubbleAccent, highlight: bubbleAccent.withAlphaComponent(0.12), separator: detail.withAlphaComponent(0.25), bar: bubbleAccent, barIconForeground: readable(fill, bubbleAccent), barPositive: readable(success, fill), barNegative: readable(error, fill)),
            actionButtonsFillColor: PresentationThemeVariableColor(color: fill), actionButtonsStrokeColor: PresentationThemeVariableColor(color: separator), actionButtonsTextColor: PresentationThemeVariableColor(color: bubbleAccent), textSelectionColor: bubbleAccent.withAlphaComponent(0.2), textSelectionKnobColor: bubbleAccent
        )
    }
    let incoming = parted(base.chat.message.incoming, fillToken: tokens.incomingBubble, textToken: tokens.incomingText, linkToken: tokens.incomingLink)
    let outgoing = descriptor.nativeOutgoingOverride ? base.chat.message.outgoing : parted(base.chat.message.outgoing, fillToken: tokens.outgoingBubble, textToken: tokens.outgoingText, linkToken: tokens.outgoingLink)
    let message = base.chat.message.withUpdated(
        incoming: incoming, outgoing: outgoing,
        infoPrimaryTextColor: primary, infoLinkTextColor: link,
        outgoingCheckColor: descriptor.nativeOutgoingOverride ? base.chat.message.outgoingCheckColor : outgoing.secondaryTextColor,
        shareButtonFillColor: PresentationThemeVariableColor(color: serviceFill), shareButtonStrokeColor: PresentationThemeVariableColor(color: .clear), shareButtonForegroundColor: PresentationThemeVariableColor(color: serviceText),
        selectionControlColors: base.chat.message.selectionControlColors.withUpdated(fillColor: accent, strokeColor: accent, foregroundColor: onAccent),
        deliveryFailedColors: base.chat.message.deliveryFailedColors.withUpdated(fillColor: error, foregroundColor: readable(primary, error))
    )
    let service = PresentationThemeServiceMessageColorComponents(fill: serviceFill, primaryText: serviceText, linkHighlight: serviceText.withAlphaComponent(0.15), scam: readable(error, serviceFill), dateFillStatic: serviceFill, dateFillFloating: serviceFill)
    let input = base.chat.inputPanel.withUpdated(
        panelBackgroundColor: navigation, panelBackgroundColorNoWallpaper: navigation, panelSeparatorColor: separator, panelControlAccentColor: accent, panelControlColor: secondary, panelControlDisabledColor: secondary.withAlphaComponent(0.4), panelControlDestructiveColor: error,
        inputBackgroundColor: inputFill, inputStrokeColor: separator, inputPlaceholderColor: inputSecondary, inputTextColor: inputText, inputControlColor: inputSecondary,
        actionControlFillColor: accent, actionControlForegroundColor: onAccent, primaryTextColor: primary, secondaryTextColor: secondary, mediaRecordingDotColor: error,
        mediaRecordingControl: base.chat.inputPanel.mediaRecordingControl.withUpdated(buttonColor: accent, micLevelColor: accent.withAlphaComponent(0.2), activeIconColor: onAccent)
    )
    let mediaPanel = base.chat.inputMediaPanel.withUpdated(
        panelSeparatorColor: separator, panelIconColor: secondary, panelHighlightedIconBackgroundColor: serviceFill, panelHighlightedIconColor: serviceText,
        panelContentControlOpaqueOverlayColor: secondary, panelContentControlOpaqueSelectionColor: accent,
        panelContentOpaqueSearchOverlayColor: inputFill, panelContentOpaqueSearchOverlaySelectedColor: serviceFill, panelContentOpaqueSearchOverlayHighlightColor: highlighted,
        stickersBackgroundColor: background, stickersSectionTextColor: secondary, stickersSearchBackgroundColor: inputFill, stickersSearchPlaceholderColor: inputSecondary, stickersSearchPrimaryColor: inputText, stickersSearchControlColor: accent,
        gifsBackgroundColor: background, backgroundColor: background
    )
    let chat = base.chat.withUpdated(
        defaultWallpaper: wallpaper ?? .color(background.rgb), animateMessageColors: source?.chat.animateMessageColors ?? false,
        message: message,
        serviceMessage: base.chat.serviceMessage.withUpdated(components: PresentationThemeServiceMessageColor(withDefaultWallpaper: service, withCustomWallpaper: service), unreadBarFillColor: surface, unreadBarStrokeColor: separator, unreadBarTextColor: accent, dateTextColor: PresentationThemeVariableColor(color: serviceText)),
        inputPanel: input, inputMediaPanel: mediaPanel,
        inputButtonPanel: base.chat.inputButtonPanel.withUpdated(panelSeparatorColor: separator, panelBackgroundColor: navigation, buttonFillColor: raised, buttonHighlightColor: highlighted, buttonStrokeColor: separator, buttonHighlightedFillColor: highlighted, buttonHighlightedStrokeColor: separator, buttonTextColor: primary),
        historyNavigation: base.chat.historyNavigation.withUpdated(fillColor: surface, strokeColor: separator, foregroundColor: accent, badgeBackgroundColor: accent, badgeStrokeColor: surface, badgeTextColor: onAccent)
    )
    let actionSheet = base.actionSheet.withUpdated(
        backgroundType: dark ? .dark : .light, opaqueItemBackgroundColor: surface, itemBackgroundColor: surface, opaqueItemHighlightedBackgroundColor: highlighted, itemHighlightedBackgroundColor: highlighted, opaqueItemSeparatorColor: separator,
        standardActionTextColor: accent, destructiveActionTextColor: error, disabledActionTextColor: secondary.withAlphaComponent(0.45), primaryTextColor: primary, secondaryTextColor: secondary, controlAccentColor: accent,
        inputBackgroundColor: inputFill, inputHollowBackgroundColor: inputFill, inputBorderColor: separator, inputPlaceholderColor: inputSecondary, inputTextColor: inputText, inputClearButtonColor: inputSecondary, checkContentColor: onAccent
    )
    let menu = PresentationThemeContextMenu(
        dimColor: base.contextMenu.dimColor, backgroundColor: raised, itemSeparatorColor: separator, sectionSeparatorColor: separator, itemBackgroundColor: raised, itemHighlightedBackgroundColor: highlighted,
        primaryColor: primary, secondaryColor: secondary, destructiveColor: error, badgeFillColor: accent, badgeForegroundColor: onAccent, badgeInactiveFillColor: surface, badgeInactiveForegroundColor: primary, extractedContentTintColor: base.contextMenu.extractedContentTintColor
    )
    let notification = base.inAppNotification.withUpdated(fillColor: raised, primaryTextColor: primary, expandedNotification: base.inAppNotification.expandedNotification.withUpdated(backgroundType: dark ? .dark : .light, navigationBar: base.inAppNotification.expandedNotification.navigationBar.withUpdated(backgroundColor: navigation, primaryTextColor: primary, controlColor: accent, separatorColor: separator)))
    let result = PresentationTheme(
        name: .custom(descriptor.encodedThemeName), index: index, referenceTheme: dark ? .night : .day, overallDarkAppearance: dark,
        intro: base.intro.withUpdated(statusBarStyle: dark ? .white : .black, primaryTextColor: primary, accentTextColor: accent, disabledTextColor: secondary, startButtonColor: accent, dotColor: separator),
        passcode: base.passcode.withUpdated(backgroundColors: PresentationThemeGradientColors(topColor: background, bottomColor: surface), buttonColor: accent),
        rootController: root, list: list, chatList: chatList, chat: chat, actionSheet: actionSheet, contextMenu: menu, inAppNotification: notification,
        chart: base.chart.withUpdated(labelsColor: secondary, helperLinesColor: separator, strongLinesColor: secondary, barStrongLinesColor: separator, detailsTextColor: primary, detailsArrowColor: secondary, detailsViewColor: raised, rangeViewFrameColor: separator, rangeViewMarkerColor: secondary), preview: preview
    )
    result.forceSync = base.forceSync
    result.starGift = base.starGift
    return result
}

/// The cheap appearance pipeline calls this with its latest *native* value.
/// Unrelated updates avoid regenerating the palette. Native wallpapers and
/// explicit outgoing overrides are retained; a new theme object/cache is used.
public func exteralessMonetAppearanceTheme(_ source: PresentationTheme, style: AppearanceMonetStyle? = nil) -> PresentationTheme {
    guard let previous = exteralessMonetDescriptor(source) else { return source }
    let style = style ?? exteralessCurrentMonetStyle(fallback: previous.renderedStyle)
    guard previous.renderedStyle != style else { return source }
    let descriptor = AppearanceMonetDescriptor(mode: previous.mode, seedRGB: previous.seedRGB, renderedStyle: style, nativeOutgoingOverride: previous.nativeOutgoingOverride)
    return makeExteralessMonetPresentationTheme(descriptor: descriptor, index: source.index, preview: source.preview, source: source, wallpaper: source.chat.defaultWallpaper)
}

/// One bounded palette memo per presentation adapter, on its main-queue
/// combineLatest delivery. Keys include the actual native object, not just its
/// persisted index, so same-index accent/wallpaper edits invalidate correctly.
/// The outer appearance adapter still creates a fresh theme/cache on every edit.
public final class ExteralessMonetThemeReplay {
    private var source: PresentationTheme?
    private var style: AppearanceMonetStyle?
    private var result: PresentationTheme?

    public init() {
    }

    public func theme(source: PresentationTheme, style: AppearanceMonetStyle? = nil) -> PresentationTheme {
        precondition(Thread.isMainThread)
        guard let descriptor = exteralessMonetDescriptor(source) else {
            self.source = nil
            self.style = nil
            self.result = nil
            return source
        }
        let style = style ?? exteralessCurrentMonetStyle(fallback: descriptor.renderedStyle)
        if self.source === source, self.style == style, let result = self.result { return result }
        let result = exteralessMonetAppearanceTheme(source, style: style)
        self.source = source
        self.style = style
        self.result = result
        return result
    }
}

/// Entry at the top of customizePresentationTheme, BEFORE its no-overrides fast
/// path. This is also reached on bootstrap/reload, night switches, native accent
/// editing and previews. It uses the original native customizers directly to
/// preserve explicit bubble/wallpaper choices without recursively re-entering.
public func exteralessCustomizeMonetPresentationTheme(_ source: PresentationTheme, title: String? = nil, accentColor: UIColor?, outgoingAccentColor: UIColor?, backgroundColors: [UInt32], bubbleColors: [UInt32], animateBubbleColors: Bool?, wallpaper: TelegramWallpaper?, baseColor: PresentationThemeBaseColor?, style: AppearanceMonetStyle? = nil) -> PresentationTheme? {
    guard let previous = exteralessMonetDescriptor(source), title == nil || title == source.name.string else { return nil }
    let style = style ?? exteralessCurrentMonetStyle(fallback: previous.renderedStyle)
    let seed = accentColor.flatMap { $0.alpha > 0 ? $0.rgb : nil } ?? previous.seedRGB
    let hasOutgoing = previous.nativeOutgoingOverride || !bubbleColors.isEmpty || outgoingAccentColor != nil
    let descriptor = AppearanceMonetDescriptor(mode: previous.mode, seedRGB: seed, renderedStyle: style, nativeOutgoingOverride: hasOutgoing)
    let result = makeExteralessMonetPresentationTheme(descriptor: descriptor, index: source.index, preview: source.preview, source: source, wallpaper: source.chat.defaultWallpaper)
    if outgoingAccentColor == nil && backgroundColors.isEmpty && bubbleColors.isEmpty && animateBubbleColors == nil && wallpaper == nil && baseColor == nil {
        return result
    }
    let customized: PresentationTheme
    if previous.mode.isDark {
        customized = customizeDefaultDarkPresentationTheme(theme: result, editing: false, title: nil, accentColor: nil, backgroundColors: backgroundColors, bubbleColors: bubbleColors, animateBubbleColors: animateBubbleColors ?? result.chat.animateMessageColors, wallpaper: wallpaper, baseColor: baseColor)
    } else {
        customized = customizeDefaultDayTheme(theme: result, editing: false, title: nil, accentColor: nil, outgoingAccentColor: outgoingAccentColor, backgroundColors: backgroundColors, bubbleColors: bubbleColors, animateBubbleColors: animateBubbleColors ?? result.chat.animateMessageColors, wallpaper: wallpaper, serviceBackgroundColor: nil)
    }
    // The stock customizers also assign unrelated reaction/media colors, even
    // when accentColor is nil. Copy only the explicit native override outputs.
    let chat = result.chat.withUpdated(defaultWallpaper: customized.chat.defaultWallpaper, animateMessageColors: customized.chat.animateMessageColors, message: result.chat.message.withUpdated(outgoing: hasOutgoing ? customized.chat.message.outgoing : result.chat.message.outgoing, outgoingCheckColor: hasOutgoing ? customized.chat.message.outgoingCheckColor : result.chat.message.outgoingCheckColor))
    let merged = PresentationTheme(name: result.name, index: result.index, referenceTheme: result.referenceTheme, overallDarkAppearance: result.overallDarkAppearance, intro: result.intro, passcode: result.passcode, rootController: result.rootController, list: result.list, chatList: result.chatList, chat: chat, actionSheet: result.actionSheet, contextMenu: result.contextMenu, inAppNotification: result.inAppNotification, chart: result.chart, preview: result.preview)
    merged.forceSync = source.forceSync
    merged.starGift = source.starGift
    return merged
}

/// Native preference transaction projection. Rechecks the selected slot rather
/// than replacing a captured settings struct and losing concurrent native edits.
public enum ExteralessMonetThemeSlot: Sendable {
    case day, night

    public func reference(in settings: PresentationThemeSettings) -> PresentationThemeReference {
        return self == .night ? settings.automaticThemeSwitchSetting.theme : settings.theme
    }
}

public func exteralessMonetReplacingTheme(in settings: PresentationThemeSettings, slot: ExteralessMonetThemeSlot, expected: PresentationThemeReference, replacement: PresentationThemeReference) -> PresentationThemeSettings? {
    guard slot.reference(in: settings) == expected else { return nil }
    if slot == .night {
        var automatic = settings.automaticThemeSwitchSetting
        automatic.theme = replacement
        return settings.withUpdatedAutomaticThemeSwitchSetting(automatic)
    } else {
        return settings.withUpdatedTheme(replacement)
    }
}
