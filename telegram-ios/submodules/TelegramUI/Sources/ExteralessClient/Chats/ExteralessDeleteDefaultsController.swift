import AccountContext
import ExteralessCore
import Foundation

final class ExteralessDeleteDefaultsController: ExteralessChatTableController {
    init(context: AccountContext) {
        super.init(context: context, title: "Deletion defaults")
        self.refreshAction = { [weak self] in self?.rebuild() }
        self.rebuild()
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func rebuild() {
        let defaults = ChatDeleteMenuDefaults.current()
        let flags: [ChatDeleteMenuDefaults.Flag] = [.banUsers, .reportSpam, .deleteAll, .commonGroups]
        self.sections = [ExteralessChatSection(footer: "Initial checks in the native moderation sheet. Only available operations are selected; each confirmation can change them.", rows: flags.map { flag in
            ExteralessChatRow(id: "chats." + flag.field, title: flag.title, checked: defaults.contains(flag), action: { [weak self] in
                self?.writeSettings({ try ChatDeleteMenuDefaults.set(flag, enabled: !defaults.contains(flag)) }, completion: { [weak self] in self?.rebuild() })
            })
        })]
        self.reloadRows()
    }
}
