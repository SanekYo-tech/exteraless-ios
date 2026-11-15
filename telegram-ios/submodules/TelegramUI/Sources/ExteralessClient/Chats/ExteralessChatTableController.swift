import AccountContext
import AsyncDisplayKit
import Display
import Foundation
import SwiftSignalKit
import TelegramPresentationData
import UIKit

struct ExteralessChatRow {
    let id: String
    let title: String
    var detail: String? = nil
    var checked: Bool = false
    var enabled: Bool = true
    var action: (() -> Void)? = nil
}

struct ExteralessChatSection {
    var title: String? = nil
    var footer: String? = nil
    var rows: [ExteralessChatRow]
}

/// Small native table host shared by the chat-domain screens. No runtime/plugin bridge is involved.
class ExteralessChatTableController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private final class ChildReference {
        weak var controller: ExteralessChatTableController?
        init(_ controller: ExteralessChatTableController) { self.controller = controller }
    }
    private static let settingsWriter = DispatchQueue(label: "Exteraless.Chats.Settings", qos: .utility)
    let context: AccountContext
    let tableView: UITableView
    private(set) var presentationData: PresentationData
    private(set) var accountIsValid = true
    var screenIsVisible = false
    var sections: [ExteralessChatSection] = []
    var refreshAction: (() -> Void)?
    var accountInvalidated: (() -> Void)?
    private var presentationDisposable: Disposable?
    private var hasLayout = false
    private var settingsWriteInFlight = false
    private var childScreens: [ChildReference] = []

    init(context: AccountContext, title: String, tableStyle: UITableView.Style = .insetGrouped) {
        self.context = context
        self.tableView = UITableView(frame: .zero, style: tableStyle)
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))
        self.title = title
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { self.presentationDisposable?.dispose() }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.view.addSubview(self.tableView)
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.tableView.rowHeight = UITableView.automaticDimension
        self.tableView.estimatedRowHeight = 72
        self.tableView.keyboardDismissMode = .interactive
        self.tableView.contentInsetAdjustmentBehavior = .never
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(self.refreshPressed), for: .valueChanged)
        self.tableView.refreshControl = refresh
        self.applyPresentation()
        self.presentationDisposable = (self.context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }
            self.presentationData = data
            self.applyPresentation()
        })
        self.displayNodeDidLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.screenIsVisible = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.screenIsVisible = false
        self.tableView.refreshControl?.endRefreshing()
        super.viewWillDisappear(animated)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let sides = layout.sideInsets(forBandFrom: 0, to: layout.size.height)
        transition.updateFrame(view: self.tableView, frame: CGRect(x: sides.left, y: 0, width: max(0, layout.size.width - sides.left - sides.right), height: layout.size.height))
        var insets = layout.insets(options: [.input])
        insets.top = max(insets.top, self.navigationLayout(layout: layout).navigationFrame.maxY)
        insets.left = 0
        insets.right = 0
        self.tableView.contentInset = insets
        self.tableView.scrollIndicatorInsets = insets
        if !self.hasLayout {
            self.hasLayout = true
            self.tableView.setContentOffset(CGPoint(x: 0, y: -insets.top), animated: false)
        }
    }

    func reloadRows() { self.tableView.reloadData() }

    /// Durable ClientSettings writes can include fsync; keep them off the UI/layout queue.
    func writeSettings(_ operation: @escaping @Sendable () throws -> Void, completion: @escaping () -> Void) {
        guard self.accountIsValid, !self.settingsWriteInFlight else { return }
        self.settingsWriteInFlight = true
        Self.settingsWriter.async { [weak self] in
            let errorText: String?
            do { try operation(); errorText = nil }
            catch { errorText = error.localizedDescription }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.settingsWriteInFlight = false
                guard self.accountIsValid else { return }
                if let errorText { self.displayError(errorText) }
                else { completion() }
            }
        }
    }

    func invalidateAccount() {
        guard self.accountIsValid else { return }
        self.accountIsValid = false
        for reference in self.childScreens { reference.controller?.invalidateAccount() }
        self.childScreens.removeAll()
        self.accountInvalidated?()
        self.refreshAction = nil
        self.tableView.refreshControl?.endRefreshing()
        self.sections = [ExteralessChatSection(rows: [ExteralessChatRow(id: "account.changed", title: "Account changed", detail: "Reopen this screen from the active account.", enabled: false)])]
        self.reloadRows()
    }

    func pushChild(_ controller: ViewController) {
        guard self.accountIsValid else { return }
        self.childScreens.removeAll { $0.controller == nil }
        if let controller = controller as? ExteralessChatTableController { self.childScreens.append(ChildReference(controller)) }
        self.push(controller)
    }

    func displayError(_ text: String) {
        self.sections.insert(ExteralessChatSection(rows: [ExteralessChatRow(id: "operation.error", title: "Couldn't complete the operation", detail: text, enabled: false)]), at: 0)
        self.reloadRows()
    }

    private func applyPresentation() {
        let theme = self.presentationData.theme
        self.displayNode.backgroundColor = theme.list.blocksBackgroundColor
        self.tableView.backgroundColor = theme.list.blocksBackgroundColor
        self.tableView.separatorColor = theme.list.itemBlocksSeparatorColor
        self.tableView.tintColor = theme.list.itemAccentColor
        self.tableView.refreshControl?.tintColor = theme.list.itemAccentColor
        self.overrideUserInterfaceStyle = theme.overallDarkAppearance ? .dark : .light
        self.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: self.presentationData), transition: .immediate)
        self.reloadRows()
    }

    @objc private func refreshPressed() {
        guard self.accountIsValid else { self.tableView.refreshControl?.endRefreshing(); return }
        self.refreshAction?()
        if self.refreshAction == nil { self.tableView.refreshControl?.endRefreshing() }
    }

    func numberOfSections(in tableView: UITableView) -> Int { return self.sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return self.sections[section].rows.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { return self.sections[section].title }
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { return self.sections[section].footer }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chat.row") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "chat.row")
        let row = self.sections[indexPath.section].rows[indexPath.row]
        cell.textLabel?.text = row.title
        cell.textLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont.systemFont(ofSize: self.presentationData.listsFontSize.baseDisplaySize))
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.text = row.detail
        cell.detailTextLabel?.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: UIFont.systemFont(ofSize: max(13, self.presentationData.listsFontSize.baseDisplaySize - 2)))
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.numberOfLines = 0
        cell.textLabel?.textColor = row.enabled ? self.presentationData.theme.list.itemPrimaryTextColor : self.presentationData.theme.list.itemSecondaryTextColor
        cell.detailTextLabel?.textColor = self.presentationData.theme.list.itemSecondaryTextColor
        cell.backgroundColor = self.presentationData.theme.list.itemBlocksBackgroundColor
        cell.accessoryType = row.checked ? .checkmark : (row.action == nil ? .none : .disclosureIndicator)
        cell.selectionStyle = row.enabled && row.action != nil ? .default : .none
        cell.accessibilityIdentifier = "exteraless.\(row.id)"
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard self.accountIsValid, !self.settingsWriteInFlight else { return }
        let row = self.sections[indexPath.section].rows[indexPath.row]
        if row.enabled { row.action?() }
    }
}
