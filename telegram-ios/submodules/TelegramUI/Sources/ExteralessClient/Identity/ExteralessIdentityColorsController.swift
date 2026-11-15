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
func exteralessIdentityPickEmoji(context: AccountContext, parent: ViewController, source: UIView, status: Bool, selected: Int64?, completion: @escaping (TelegramMediaFile?, Int32?) -> Void) {
    let mode: EmojiStatusSelectionController.Mode = status ? .customStatusSelection(completion: completion) : .backgroundSelection(completion: { completion($0, nil) })
    let selectedItems: Set<AnyHashable> = Set(selected.map { [AnyHashable(EngineMedia.Id(namespace: Namespaces.Media.CloudFile, id: $0))] } ?? [])
    let controller = EmojiStatusSelectionController(context: context, mode: mode, sourceView: source,
        emojiContent: EmojiPagerContentComponent.emojiInputData(context: context, animationCache: context.animationCache,
            animationRenderer: context.animationRenderer, isStandalone: false, subject: status ? .channelStatus : .backgroundIcon,
            hasTrending: false, topReactionItems: [], areUnicodeEmojiEnabled: false, areCustomEmojiEnabled: true,
            chatPeerId: context.account.peerId, selectedItems: selectedItems, forceHasPremium: true),
        currentSelection: selected, destinationItemView: { nil })
    // forceHasPremium is confined to this local-only picker. custom/background
    // modes return a document; neither performs account.updateEmojiStatus.
    parent.present(controller, in: .window(.root))
}

@MainActor
final class ExteralessIdentityColorsController: ExteralessIdentityController {
    private let peer: EnginePeer
    private var draft: IdentityPeerColors?
    private var expected: IdentityPeerColors?
    private var files: [Int64: TelegramMediaFile] = [:]

    init(context: AccountContext, permit: IdentityEditPermit, peer: EnginePeer) {
        self.peer = peer
        super.init(context: context, permit: permit)
        allowsRefresh = false
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didLoadIdentity(_ state: IdentityAccountState) {
        guard draft == nil else { return }
        expected = state.colors
        if let colors = state.colors { draft = colors }
        else {
            let color: Int32?
            if case let .preset(value)? = peer.nameColor { color = value.rawValue } else { color = nil }
            draft = IdentityPeerColors(colorId: color, emojiId: peer.backgroundEmojiId, profileColorId: peer.profileColor?.rawValue, profileEmojiId: peer.profileBackgroundEmojiId)
        }
    }

    override func render() {
        title = "Local appearance"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: presentationData.strings.Common_Save, style: .done, target: self, action: #selector(save))
        navigationItem.rightBarButtonItem?.isEnabled = canEdit && draft != nil
        var rows: [ExteralessSettingsRow] = []
        for (profile, title) in [(false, "Reply color"), (true, "Profile color")] {
            let value = profile ? draft?.profileColorId : draft?.colorId
            var row = ExteralessSettingsRow(id: profile ? "profileColor" : "color", title: title, detail: value.map { "Color \($0)" } ?? "Telegram value")
            row.enabled = canEdit; row.accessory = .disclosure
            row.action = { [weak self] in
                guard let self, self.canEdit else { return }
                self.push(ExteralessIdentityPaletteController(context: self.context, permit: self.permit, profile: profile, selected: value, selectedColor: { [weak self] color in
                    guard let self, self.canEdit else { return }
                    if profile { self.draft?.profileColorId = color } else { self.draft?.colorId = color }
                    self.render()
                }))
            }
            rows.append(row)
            let emoji = profile ? draft?.profileEmojiId : draft?.emojiId
            var pattern = ExteralessSettingsRow(id: profile ? "profileEmoji" : "emoji", title: profile ? "Profile pattern" : "Reply pattern", detail: emoji.map { "Document \($0)" } ?? "Telegram value")
            pattern.enabled = canEdit; pattern.accessory = .disclosure
            pattern.action = { [weak self] in
                guard let self, self.canEdit else { return }
                exteralessIdentityPickEmoji(context: self.context, parent: self, source: self.view, status: false, selected: emoji) { [weak self] file, _ in
                    guard let self, self.canEdit else { return }
                    if profile { self.draft?.profileEmojiId = file?.fileId.id } else { self.draft?.emojiId = file?.fileId.id }
                    if let file { self.files[file.fileId.id] = file }
                    let ids = Set([self.draft?.emojiId, self.draft?.profileEmojiId].compactMap { $0 })
                    self.files = self.files.filter { ids.contains($0.key) }
                    self.render()
                }
            }
            rows.append(pattern)
        }
        var restore = ExteralessSettingsRow(id: "restore", title: "Restore Telegram appearance")
        restore.enabled = canEdit; restore.style = .destructive
        restore.action = { [weak self] in
            guard let self, self.canEdit else { return }
            self.apply(.colors(nil, expected: self.expected)) { [weak self] in self?.dismiss(animated: true) }
        }
        rows.append(restore)
        setSections(identityOperationSections() + [.init(rows: rows)])
    }

    @objc private func save() {
        guard canEdit, let draft else { return }
        apply(.colors(draft, expected: expected), emojiFiles: Array(files.values)) { [weak self] in self?.dismiss(animated: true) }
    }
}

@MainActor
private final class ExteralessIdentityPaletteController: ExteralessSettingsListController {
    private let permit: IdentityEditPermit
    private let profile: Bool
    private let selected: Int32?
    private let selectedColor: (Int32?) -> Void
    private var colors: [Int32] = []

    init(context: AccountContext, permit: IdentityEditPermit, profile: Bool, selected: Int32?, selectedColor: @escaping (Int32?) -> Void) {
        self.permit = permit; self.profile = profile; self.selected = selected; self.selectedColor = selectedColor
        super.init(context: context)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func render() {
        title = profile ? "Profile color" : "Reply color"
        let palette = context.peerNameColors
        var seen = Set<Int32>()
        colors = ((profile ? palette.profileDisplayOrder : palette.displayOrder) + (profile ? palette.profileColors.keys.sorted() : palette.colors.keys.sorted()))
            .filter { $0 >= 0 && seen.insert($0).inserted }
        let valid = (try? permit.check(owner: exteralessIdentityAccountId(context.account))) != nil
        var rows = ([Int32?](arrayLiteral: nil) + colors.map { Optional($0) }).map { color -> ExteralessSettingsRow in
            var row = ExteralessSettingsRow(id: color.map(String.init) ?? "default", title: color.map { "Color \($0)" } ?? "Telegram value")
            row.enabled = valid; row.accessory = color == selected ? .checkmark : .none
            row.action = { [weak self] in
                guard let self, (try? self.permit.check(owner: exteralessIdentityAccountId(self.context.account))) != nil else { return }
                self.selectedColor(color); self.dismiss(animated: true)
            }
            return row
        }
        if colors.isEmpty { rows.append(.init(id: "empty", title: "No cached profile palette")) }
        setSections([.init(rows: rows)])
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = super.tableView(tableView, cellForRowAt: indexPath)
        if indexPath.row > 0, indexPath.row <= colors.count {
            let id = colors[indexPath.row - 1]
            let palette = profile ? context.peerNameColors.getProfile(PeerNameColor(rawValue: id), dark: presentationData.theme.overallDarkAppearance) : context.peerNameColors.get(PeerNameColor(rawValue: id), dark: presentationData.theme.overallDarkAppearance)
            let swatches = [palette.main, palette.secondary, palette.tertiary].compactMap { $0 }
            let preview = UIView(frame: CGRect(x: 0, y: 0, width: 66, height: 22))
            for (index, color) in swatches.enumerated() {
                let dot = UIView(frame: CGRect(x: CGFloat(index) * 22, y: 0, width: 20, height: 20))
                dot.backgroundColor = color; dot.layer.cornerRadius = 10; preview.addSubview(dot)
            }
            preview.accessibilityLabel = "Color \(id)" + (selected == id ? ", selected" : "")
            cell.accessoryView = preview
        } else { cell.accessoryView = nil }
        return cell
    }
}
