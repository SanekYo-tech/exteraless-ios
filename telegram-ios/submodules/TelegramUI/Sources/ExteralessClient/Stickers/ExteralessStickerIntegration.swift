import AccountContext
import Display
import Emoji
import ExteralessCore
import Foundation
import QuickReactionSetupController
import SwiftSignalKit
import TelegramCore

@MainActor
public final class ExteralessStickerIntegration {
    private var context: AccountContext?
    private var packs: ExteralessEmojiPacks?
    private var observation: ClientSettingsObservation?

    public init() {
        ExteralessSettingsUI.registerActions([
            ExteralessSettingsAction(id: "stickers.emojiPacks", title: "Emoji Packs", section: "Chats · Emoji Packs", action: { [weak self] context, controller in
                guard let self, self.context === context, let packs = self.packs else { return }
                controller.push(ExteralessEmojiPacksController(context: context, packs: packs))
            }),
            ExteralessSettingsAction(id: "stickers.pinnedChats", title: "Pinned Reactions · Chats", section: "Chats · Reactions", action: { context, controller in
                controller.push(ExteralessPinnedReactionsController(context: context, isChannel: false))
            }),
            ExteralessSettingsAction(id: "stickers.pinnedChannels", title: "Pinned Reactions · Channels", section: "Chats · Reactions", action: { context, controller in
                controller.push(ExteralessPinnedReactionsController(context: context, isChannel: true))
            }),
            ExteralessSettingsAction(id: "stickers.quickReaction", title: "Default Quick Reaction", section: "Chats · Reactions", action: { context, controller in
                controller.push(quickReactionSetupController(context: context))
            }),
            ExteralessSettingsAction(id: "stickers.nativePacks", title: "Installed Sticker Packs", section: "Chats · Stickers", action: { context, controller in
                controller.push(context.sharedContext.makeInstalledStickerPacksController(context: context, mode: .general, forceTheme: nil))
            }),
            ExteralessSettingsAction(id: "stickers.nativeEmojiPacks", title: "Telegram Custom Emoji Packs", section: "Chats · Stickers", action: { context, controller in
                controller.push(context.sharedContext.makeInstalledStickerPacksController(context: context, mode: .emoji, forceTheme: nil))
            }),
            ExteralessSettingsAction(id: "stickers.localGifs", title: "Local GIF Library", section: "Chats · Stickers", action: { context, controller in
                controller.push(ExteralessLocalGifsController(context: context))
            })
        ])
        self.observation = ClientSettings.shared.observe { [weak self] keys in
            guard keys.isEmpty || !keys.isDisjoint(with: StickerFeatures.keys) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !StickerPolicy().downloadEmojiPacks { self.packs?.cancelRemoteOperation() }
                if keys.isEmpty || !keys.isDisjoint(with: ["chats.emojiPack", "chats.useSystemEmoji"]) { self.packs?.reload() }
                NotificationCenter.default.post(name: StickerFeatures.changedNotification, object: nil)
            }
        }
    }

    public func update(context: AccountContext) {
        guard self.context !== context else { return }
        self.clearContext()
        self.context = context
        self.packs = ExteralessEmojiPacks(context: context)
        self.packs?.reload()
    }

    public func clearContext() {
        self.packs?.stop()
        self.packs = nil
        self.context = nil
    }

    deinit { self.observation?.cancel() }
}
