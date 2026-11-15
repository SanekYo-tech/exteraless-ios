import AccountContext
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore

@MainActor
public func exteralessDialogForumSettingsController(context: AccountContext, peerId: EnginePeer.Id) -> ViewController {
    ExteralessDialogForumController(context: context, peerId: peerId)
}

@MainActor
final class ExteralessDialogForumController: ExteralessSettingsListController {
    private let peerId: EnginePeer.Id
    private var layout: DialogForumLayout?
    private var isForum = false
    private var accountIsActive = true
    private var writing = false
    private let dataDisposable = MetaDisposable()
    private let writeDisposable = MetaDisposable()

    init(context: AccountContext, peerId: EnginePeer.Id) {
        self.peerId = peerId
        super.init(context: context)
        self.title = "Forum layout"
        dataDisposable.set((combineLatest(
            context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)),
            exteralessDialogForumLayout(account: context.account, peerId: peerId)
        ) |> deliverOnMainQueue).start(next: { [weak self] peer, layout in
            guard let self, self.accountIsActive else { return }
            self.layout = layout
            if case let .channel(channel) = peer { self.isForum = channel.isForum && !channel.flags.contains(.isMonoforum) }
            else { self.isForum = false }
            self.render()
        }))
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { dataDisposable.dispose(); writeDisposable.dispose() }

    func invalidateAccount() {
        accountIsActive = false
        dataDisposable.set(nil)
        writeDisposable.set(nil)
        render()
    }

    override func render() {
        let choices: [(DialogForumLayout, String)] = [(.inherit, "Default"), (.tabs, "Tabs"), (.list, "List")]
        let rows = choices.map { value, title -> ExteralessSettingsRow in
            var row = ExteralessSettingsRow(id: "forum.\(value.rawValue)", title: title)
            row.accessory = layout == value ? .checkmark : .none
            row.enabled = accountIsActive && isForum && layout != nil && !writing
            row.action = { [weak self] in self?.select(value) }
            return row
        }
        let footer: String
        if !accountIsActive { footer = "Reopen this screen for the selected account." }
        else if layout != nil && !isForum { footer = "Choose a forum group to change its local layout." }
        else { footer = "Applies to this forum on this account and device. Default follows Telegram's layout. Other members' settings stay intact." }
        setSections(operationSections() + [ExteralessSettingsSection(footer: footer, rows: rows)])
    }

    private func select(_ layout: DialogForumLayout) {
        guard accountIsActive, isForum, !writing else { return }
        writing = true
        errorText = nil
        render()
        writeDisposable.set((exteralessSetDialogForumLayout(account: context.account, peerId: peerId, layout: layout)
        |> deliverOnMainQueue).start(next: { [weak self] applied in
            guard let self, self.accountIsActive else { return }
            self.writing = false
            if !applied { self.errorText = "The forum is no longer available. Refresh and try again." }
            self.render()
        }))
    }
}
