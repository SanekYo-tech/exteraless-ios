import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

/// Cheap render/cache invalidation, separate from native theme file reconstruction.
public func exteralessAppearanceUpdates() -> Signal<Void, NoError> {
    return Signal { subscriber in
        // Install the identity observer before admitting display updates. It
        // tracks privacy.zalgoFilter and advances the identity revision; its
        // notification below feeds the existing cheap, file-I/O-free adapter.
        let _ = ExteralessIdentityPresentation.shared
        let observation = ClientSettings.shared.observe { keys in
            if keys.contains(where: { $0.hasPrefix("appearance.") }) {
                Queue.mainQueue().async {
                    subscriber.putNext(())
                }
            }
        }
        let resources = NotificationCenter.default.addObserver(forName: AppearanceFeatures.resourcesChangedNotification, object: nil, queue: .main) { _ in
            subscriber.putNext(())
        }
        let identity = NotificationCenter.default.addObserver(forName: IdentityFeatures.presentationChanged, object: nil, queue: .main) { _ in
            subscriber.putNext(())
        }
        subscriber.putNext(())
        return ActionDisposable {
            observation.cancel()
            NotificationCenter.default.removeObserver(resources)
            NotificationCenter.default.removeObserver(identity)
        }
    }
}

/// One native subscription per lifetime. Revisions combine with its latest
/// completed value; they never rerun the file-backed theme/decode signal. Queued
/// deliveries and disposal use the same main-queue combineLatest subscription,
/// rather than detached tasks that can publish a cancelled account/theme later.
public func exteralessAppearancePresentationData(native: Signal<PresentationData, NoError>, updates: Signal<Void, NoError>, dateTimeFormat: @escaping () -> PresentationDateTimeFormat, hideDividers: @escaping () -> Bool = { ClientSettings.shared.integer("appearance.dividerStyle", default: 1) == 0 }, monetStyle: @escaping () -> AppearanceMonetStyle? = { nil }) -> Signal<PresentationData, NoError> {
    let monetReplay = ExteralessMonetThemeReplay()
    return combineLatest(queue: .mainQueue(), native, updates)
    |> map { data, _ -> PresentationData in
        // A fresh theme identity/cache invalidates existing native equality gates.
        // Palettes are immutable values here; no file/resource decoder is invoked.
        let source = monetReplay.theme(source: data.theme, style: monetStyle())
        let hidden = hideDividers()
        let list = hidden ? source.list.withUpdated(itemBlocksSeparatorColor: .clear, itemPlainSeparatorColor: .clear) : source.list
        let menu = hidden ? source.contextMenu.withUpdated(itemSeparatorColor: .clear, sectionSeparatorColor: .clear) : source.contextMenu
        let theme = PresentationTheme(name: source.name, index: source.index, referenceTheme: source.referenceTheme, overallDarkAppearance: source.overallDarkAppearance, intro: source.intro, passcode: source.passcode, rootController: source.rootController, list: list, chatList: source.chatList, chat: source.chat, actionSheet: source.actionSheet, contextMenu: menu, inAppNotification: source.inAppNotification, chart: source.chart, preview: source.preview)
        theme.forceSync = data.theme.forceSync
        theme.starGift = data.theme.starGift
        return PresentationData(strings: data.strings, theme: theme,
            autoNightModeTriggered: data.autoNightModeTriggered, chatWallpaper: data.chatWallpaper,
            chatFontSize: data.chatFontSize, chatBubbleCorners: data.chatBubbleCorners,
            listsFontSize: data.listsFontSize, dateTimeFormat: dateTimeFormat(),
            nameDisplayOrder: data.nameDisplayOrder, nameSortOrder: data.nameSortOrder,
            reduceMotion: data.reduceMotion, largeEmoji: data.largeEmoji)
    }
}
