import AccountContext
import Display
import EmojiStatusSelectionComponent
import EntityKeyboard
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

@MainActor
final class ExteralessPinnedReactionsController: ExteralessSettingsListController {
    private let isChannel: Bool
    private var observation: ClientSettingsObservation?
    private var reactionsDisposable: Disposable?
    private var available: AvailableReactions?
    private var key: String { "chats.pinnedReactions\(self.isChannel ? "Channels" : "Chats")" }
    private var enabledKey: String { "chats.usePinnedReactions\(self.isChannel ? "Channels" : "Chats")" }

    init(context: AccountContext, isChannel: Bool) {
        self.isChannel = isChannel
        super.init(context: context)
        self.title = isChannel ? "Channel Pinned Reactions" : "Chat Pinned Reactions"
        self.observation = ClientSettings.shared.observe { [weak self] _ in Task { @MainActor [weak self] in self?.render() } }
        self.reactionsDisposable = (context.engine.stickers.availableReactions() |> deliverOnMainQueue).start(next: { [weak self] available in
            self?.available = available
            self?.render()
        })
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { self.observation?.cancel(); self.reactionsDisposable?.dispose() }

    override func render() {
        let pins = StickerReactionPolicy.decode(ClientSettings.shared.string(self.key, default: "[]"))
        var enabled = ExteralessSettingsRow(id: "enabled", title: "Use Pinned Reactions")
        enabled.toggle = (ClientSettings.shared.bool(self.enabledKey), { [weak self] value in
            guard let self else { return }
            let key = self.enabledKey
            self.perform({ try ClientSettings.shared.set(.bool(value), for: key) }, completion: { _ in })
        })
        enabled.enabled = !self.isBusy
        var rows = pins.enumerated().map { index, pin -> ExteralessSettingsRow in
            var row = ExteralessSettingsRow(id: "pin.\(index)", title: "\(index + 1). \(pin.label)")
            row.accessory = .disclosure
            row.action = { [weak self] in self?.edit(pin) }
            row.enabled = !self.isBusy
            return row
        }
        var add = ExteralessSettingsRow(id: "add", title: "Add Reaction…")
        add.style = .accent
        add.enabled = !self.isBusy && pins.count < StickerReactionPolicy.maximumPinnedCount
        add.action = { [weak self] in self?.choose() }
        rows.append(add)
        var reset = ExteralessSettingsRow(id: "reset", title: "Reset Pinned Reactions")
        reset.style = .destructive
        reset.enabled = !self.isBusy
        reset.action = { [weak self] in
            guard let self else { return }
            let keys: Set<String> = [self.key, self.enabledKey]
            self.perform({ try ClientSettings.shared.applyPublic([:], resetting: keys) }, completion: { _ in })
        }
        self.setSections([
            ExteralessSettingsSection(footer: "The ordered set is shared across accounts, as in the original client. Each account resolves its own emoji; chat permissions, Premium requirements and maximum reaction counts still apply. Saved-message tags and paid reactions retain native ordering.", rows: [enabled]),
            ExteralessSettingsSection(title: "Up to Seven Reactions", rows: rows),
            ExteralessSettingsSection(rows: [reset])
        ] + self.operationSections())
    }

    private func mutate(_ change: ([StickerPinnedReaction]) -> [StickerPinnedReaction]) {
        let settings = ClientSettings.shared
        let snapshot = settings.readSnapshot()
        let previous = StickerReactionPolicy.decode(settings.string(self.key, default: "[]"))
        do {
            let text = try StickerReactionPolicy.encode(change(previous))
            let key = self.key
            self.perform({ try settings.applyPublic([key: .string(text)], expected: snapshot) }, completion: { _ in })
        } catch { self.errorText = error.localizedDescription; self.render() }
    }

    private func edit(_ pin: StickerPinnedReaction) {
        let alert = UIAlertController(title: pin.label, message: nil, preferredStyle: .actionSheet)
        for (title, offset) in [("Move Up", -1), ("Move Down", 1)] {
            alert.addAction(UIAlertAction(title: title, style: .default, handler: { [weak self] _ in
                self?.mutate { items in
                    var items = items
                    if let index = items.firstIndex(of: pin), items.indices.contains(index + offset) { items.swapAt(index, index + offset) }
                    return items
                }
            }))
        }
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive, handler: { [weak self] _ in self?.mutate { $0.filter { $0 != pin } } }))
        alert.addAction(UIAlertAction(title: self.presentationData.strings.Common_Cancel, style: .cancel))
        alert.popoverPresentationController?.sourceView = self.view
        alert.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
        self.context.sharedContext.applicationBindings.presentNativeController(alert)
    }

    private func choose() {
        guard let section = self.sections.firstIndex(where: { $0.rows.contains(where: { $0.id == "add" }) }),
              let row = self.sections[section].rows.firstIndex(where: { $0.id == "add" }),
              let cell = self.tableView.cellForRow(at: IndexPath(row: row, section: section)) else { return }
        let controller = EmojiStatusSelectionController(context: self.context, mode: .backgroundSelection(completion: { [weak self] file in
            guard let self, let file else { return }
            let reaction: StickerPinnedReaction
            if let builtin = self.available?.reactions.first(where: { $0.selectAnimation.fileId == file.fileId && $0.isEnabled }), case let .builtin(value) = builtin.value {
                reaction = .emoji(value)
            } else if file.isCustomEmoji { reaction = .custom(file.fileId.id) }
            else { return }
            self.mutate { $0.contains(reaction) ? $0 : $0 + [reaction] }
        }), sourceView: cell.contentView, emojiContent: EmojiPagerContentComponent.emojiInputData(
            context: self.context, animationCache: self.context.animationCache, animationRenderer: self.context.animationRenderer,
            isStandalone: false, subject: .quickReaction, hasTrending: false, topReactionItems: [],
            areUnicodeEmojiEnabled: false, areCustomEmojiEnabled: true, chatPeerId: self.context.account.peerId
        ), currentSelection: nil, destinationItemView: { nil })
        self.present(controller, in: .window(.root))
    }
}
