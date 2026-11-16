import AccountContext
import CallListUI
import ContactListUI
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

private enum ExteralessMenuRoutes {
    // Keep Android IDs stable. Extra providers are discovered on every render.
    static let ids = [14, 2, 3, 6, 10, 11, 8, 102, 110]

    static func available(context: AccountContext) -> [Int] {
        return ids + MainActor.assumeIsolated { ExteralessMainMenuRegistry.availableIds(context: context) }.filter { !ids.contains($0) }
    }

    static var known: [Int] {
        ids + MainActor.assumeIsolated { ExteralessMainMenuRegistry.registeredIds }.filter { !ids.contains($0) }
    }

    static func title(_ id: Int) -> String {
        if let route = MainActor.assumeIsolated({ ExteralessMainMenuRegistry.route(id: id) }) { return route.title }
        switch id {
        case -1: return "Separator"
        case 14: return "Archived Chats"
        case 2: return "New Group"
        case 3: return "New Channel"
        case 6: return "Contacts"
        case 10: return "Calls"
        case 11: return "Saved Messages"
        case 8: return "Settings"
        case 102: return "Plugins"
        case 110: return "Exteraless Settings"
        case 18: return "My Profile"
        case 105: return "Bots and Apps"
        case 101: return "Browser"
        case 17: return "QR Code"
        case 106: return "Channel Feed"
        case 107: return "Ghost Mode"
        case 108: return "Recent Chats"
        case 109: return "Wallet"
        case 111: return "Close App (not supported by iOS)"
        default: return "Route \(id)"
        }
    }
}

@MainActor
public func exteralessPresentMainMenu(context: AccountContext, from controller: ViewController) {
    guard ExteralessAppearanceEntry.isMainMenuAvailable(context: context) else { return }
    let asSheet = ClientSettings.shared.bool("appearance.navigationDrawer")
    let immersive = asSheet && ClientSettings.shared.bool("appearance.immersiveDrawerAnimation") && !UIAccessibility.isReduceMotionEnabled
    let snapshot = immersive ? (context.sharedContext.mainWindow?.viewController as? NavigationController)?.view.snapshotView(afterScreenUpdates: false) : nil
    let menu = ExteralessMainMenuController(context: context, asSheet: asSheet, backdrop: snapshot)
    if asSheet {
        controller.present(menu, in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .none))
    } else {
        controller.push(menu)
    }
}

final class ExteralessMainMenuController: ExteralessAppearanceListController, UIGestureRecognizerDelegate {
    private let asSheet: Bool
    private let backdrop: UIView?
    private let drawerPanel = UIView()
    private let dimmingView = UIControl()
    private let drawerTitle = UILabel()
    private let drawerClose = UIButton(type: .system)
    private weak var presentationRoot: NavigationController?
    private var closePan: UIPanGestureRecognizer?
    private var drawerWidth: CGFloat = 0
    private var drawerDirection: CGFloat = 1
    private var drawerProgress: CGFloat = 1
    private var drawerPanStartProgress: CGFloat = 0
    private var didAnimateDrawer = false
    private var didSetDrawerOffset = false
    private var isClosingDrawer = false

    init(context: AccountContext, asSheet: Bool, backdrop: UIView? = nil) {
        self.asSheet = asSheet
        self.backdrop = backdrop
        super.init(context: context)
        self.presentationRoot = context.sharedContext.mainWindow?.viewController as? NavigationController
        self.title = "Main Menu"
        self.allowsRefresh = false
        NotificationCenter.default.addObserver(self, selector: #selector(self.entryContextChanged), name: ExteralessAppearanceEntry.contextDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.pluginMenuEntriesChanged), name: PluginUIBridgeExtension.menuItemsDidChange, object: nil)
        if asSheet {
            self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Close, style: .plain, target: self, action: #selector(self.closePressed))
        }
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func closePressed() { self.dismiss() }

    @objc private func pluginMenuEntriesChanged() {
        if !self.isClosingDrawer { self.render() }
    }

    @objc private func entryContextChanged() {
        if !ExteralessAppearanceEntry.isMainMenuAvailable(context: self.context) {
            self.isClosingDrawer = true
            super.dismiss()
        }
    }

    override func loadDisplayNode() {
        super.loadDisplayNode()
        guard self.asSheet else { return }
        self.navigationBar?.isHidden = true
        self.displayNode.view.accessibilityViewIsModal = true
        if let backdrop {
            backdrop.isUserInteractionEnabled = false
            backdrop.clipsToBounds = true
            self.displayNode.view.insertSubview(backdrop, at: 0)
        }
        self.dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        self.dimmingView.alpha = 0
        self.dimmingView.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)
        self.displayNode.view.addSubview(self.dimmingView)
        self.displayNode.view.addSubview(self.drawerPanel)
        self.drawerPanel.clipsToBounds = true
        self.drawerPanel.layer.cornerCurve = .continuous
        self.drawerPanel.addSubview(self.tableView)
        self.drawerPanel.addSubview(self.drawerTitle)
        self.drawerPanel.addSubview(self.drawerClose)
        self.drawerTitle.text = "Main Menu"
        self.drawerTitle.font = UIFont.preferredFont(forTextStyle: .headline)
        self.drawerTitle.adjustsFontForContentSizeCategory = true
        self.drawerTitle.accessibilityTraits = .header
        self.drawerClose.setImage(UIImage(systemName: "xmark"), for: .normal)
        self.drawerClose.accessibilityLabel = self.presentationData.strings.Common_Close
        self.drawerClose.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(self.drawerPan(_:)))
        pan.delegate = self
        self.closePan = pan
        self.drawerPanel.addGestureRecognizer(pan)
        self.tableView.panGestureRecognizer.require(toFail: pan)
        self.updateDrawerColors()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        guard self.asSheet else { return }
        let sides = layout.sideInsets(forBandFrom: 0, to: layout.size.height)
        let available = max(0, layout.size.width - sides.left - sides.right)
        self.drawerWidth = CGFloat(AppearanceDrawerPolicy.width(available: Double(available)))
        let rtl = UIView.userInterfaceLayoutDirection(for: self.view.semanticContentAttribute) == .rightToLeft
        self.drawerDirection = rtl ? -1 : 1
        let x = rtl ? layout.size.width - sides.right - self.drawerWidth : sides.left
        self.drawerPanel.layer.maskedCorners = rtl ? [.layerMinXMinYCorner, .layerMinXMaxYCorner] : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        self.drawerPanel.layer.cornerRadius = 20
        self.dimmingView.frame = CGRect(origin: .zero, size: layout.size)
        self.backdrop?.bounds = CGRect(origin: .zero, size: layout.size)
        self.backdrop?.center = CGPoint(x: layout.size.width * 0.5, y: layout.size.height * 0.5)
        self.drawerPanel.bounds = CGRect(x: 0, y: 0, width: self.drawerWidth, height: layout.size.height)
        self.drawerPanel.center = CGPoint(x: x + self.drawerWidth * 0.5, y: layout.size.height * 0.5)
        let top = max(layout.safeInsets.top, layout.navigationBarStatusBarHeight ?? 0)
        let headerHeight = top + 56
        self.drawerClose.frame = CGRect(x: rtl ? 8 : self.drawerWidth - 52, y: top + 6, width: 44, height: 44)
        self.drawerTitle.textAlignment = rtl ? .right : .left
        self.drawerTitle.frame = CGRect(x: rtl ? 60 : 20, y: top + 6, width: max(0, self.drawerWidth - 80), height: 44)
        self.tableView.frame = CGRect(x: 0, y: headerHeight, width: self.drawerWidth, height: max(0, layout.size.height - headerHeight))
        self.tableView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: layout.insets(options: [.input]).bottom + 12, right: 0)
        self.tableView.scrollIndicatorInsets = self.tableView.contentInset
        if !self.didSetDrawerOffset {
            self.didSetDrawerOffset = true
            self.tableView.setContentOffset(CGPoint(x: 0, y: -8), animated: false)
        }
        self.applyDrawerProgress(self.drawerProgress)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard self.asSheet, !self.didAnimateDrawer else { return }
        self.didAnimateDrawer = true
        self.animateDrawer(to: 0, completion: nil)
    }

    override func accessibilityPerformEscape() -> Bool {
        self.dismiss()
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, !self.isClosingDrawer else { return false }
        let velocity = pan.velocity(in: self.drawerPanel)
        return abs(velocity.x) > abs(velocity.y) && velocity.x * self.drawerDirection < 0
    }

    @objc private func drawerPan(_ pan: UIPanGestureRecognizer) {
        let progress = CGFloat(AppearanceDrawerPolicy.progress(translation: Double(-pan.translation(in: self.displayNode.view).x * self.drawerDirection + self.drawerPanStartProgress * self.drawerWidth), width: Double(self.drawerWidth)))
        switch pan.state {
        case .began:
            let offset = self.drawerPanel.layer.presentation()?.transform.m41 ?? self.drawerPanel.layer.transform.m41
            self.drawerPanStartProgress = CGFloat(AppearanceDrawerPolicy.progress(translation: Double(abs(offset)), width: Double(self.drawerWidth)))
            self.drawerPanel.layer.removeAllAnimations()
            self.dimmingView.layer.removeAllAnimations()
            self.backdrop?.layer.removeAllAnimations()
            pan.setTranslation(.zero, in: self.displayNode.view)
            self.applyDrawerProgress(self.drawerPanStartProgress)
        case .changed:
            self.applyDrawerProgress(progress)
        case .ended, .cancelled:
            let velocity = -pan.velocity(in: self.displayNode.view).x * self.drawerDirection
            if AppearanceDrawerPolicy.shouldDismiss(progress: Double(progress), velocity: Double(velocity), cancelled: pan.state == .cancelled) { self.dismiss() }
            else { self.animateDrawer(to: 0, completion: nil) }
        default: break
        }
    }

    private func updateDrawerColors() {
        guard self.asSheet, self.isNodeLoaded else { return }
        self.displayNode.backgroundColor = self.backdrop == nil ? .clear : self.presentationData.theme.list.blocksBackgroundColor
        self.drawerPanel.backgroundColor = self.presentationData.theme.list.blocksBackgroundColor
        self.drawerTitle.textColor = self.presentationData.theme.list.itemPrimaryTextColor
        self.drawerClose.tintColor = self.presentationData.theme.list.itemAccentColor
    }

    private func applyDrawerProgress(_ progress: CGFloat) {
        self.drawerProgress = progress
        self.drawerPanel.transform = CGAffineTransform(translationX: -self.drawerDirection * self.drawerWidth * progress, y: 0)
        self.dimmingView.alpha = 1 - progress
        let scale = CGFloat(AppearanceDrawerPolicy.backdropScale(progress: Double(progress), immersive: self.backdrop != nil))
        self.backdrop?.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.backdrop?.layer.cornerRadius = 18 * (1 - progress)
    }

    private func animateDrawer(to progress: CGFloat, completion: (() -> Void)?) {
        let duration = UIAccessibility.isReduceMotionEnabled || self.presentationData.reduceMotion ? 0 : 0.28
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut], animations: {
            self.applyDrawerProgress(progress)
        }, completion: { _ in completion?() })
    }

    override func dismiss(completion: (() -> Void)? = nil) {
        guard self.asSheet, self.isNodeLoaded else { super.dismiss(completion: completion); return }
        guard !self.isClosingDrawer else { return }
        self.isClosingDrawer = true
        self.drawerPanel.isUserInteractionEnabled = false
        self.animateDrawer(to: 1, completion: { [weak self] in
            guard let self else { return }
            let sameRoot = ExteralessAppearanceEntry.isMainMenuAvailable(context: self.context) && self.presentationRoot != nil && (self.context.sharedContext.mainWindow?.viewController as? NavigationController) === self.presentationRoot
            self.finishDrawerDismiss(completion: sameRoot ? completion : nil)
        })
    }

    private func finishDrawerDismiss(completion: (() -> Void)?) { super.dismiss(completion: completion) }

    override func render() {
        self.updateDrawerColors()
        let available = Set(ExteralessMenuRoutes.available(context: self.context))
        let layout = AppearanceMenuLayout(rawValue: ClientSettings.shared.string("appearance.mainMenuLayout"), availableIds: ExteralessMenuRoutes.known, settingsInTabs: !ClientSettings.shared.bool("appearance.mainTabsHideProfile") && !exteralessRootTabsAreHidden(), preserveUnavailable: true)
        var sections: [PluginListSection] = []
        var rows: [PluginListRow] = []
        for id in layout.visible {
            if id == AppearanceMenuLayout.divider {
                if !rows.isEmpty { sections.append(PluginListSection(rows: rows)); rows = [] }
                continue
            }
            guard available.contains(id) else { continue }
            var row = PluginListRow(id: "menu.\(id)", title: ExteralessMenuRoutes.title(id))
            row.accessory = .disclosure
            row.action = { [weak self] in self?.open(id) }
            rows.append(row)
        }
        if !rows.isEmpty { sections.append(PluginListSection(rows: rows)) }
        if ClientSettings.shared.bool("appearance.hideDialogsSearchField") {
            var search = PluginListRow(id: "appearance.search", title: self.presentationData.strings.Common_Search)
            search.accessory = .disclosure
            search.action = { [weak self] in self?.openRequiredSearch() }
            sections.append(PluginListSection(rows: [search]))
        }
        var edit = PluginListRow(id: "customize", title: "Customize Main Menu")
        edit.style = .accent
        edit.action = { [weak self] in
            guard let self else { return }
            self.navigate(ExteralessMenuLayoutController(context: self.context))
        }
        sections.append(PluginListSection(rows: [edit]))
        let pluginRows = MainActor.assumeIsolated {
            ExteralessPluginRuntime.shared.pluginUI?.menuRows(context: self.context, placement: .main, source: self) ?? []
        }
        if !pluginRows.isEmpty { sections.append(PluginListSection(title: "Plugins", rows: pluginRows)) }
        sections += self.operationSections()
        self.setSections(sections)
    }

    private func navigate(_ controller: ViewController) {
        guard !self.isClosingDrawer, ExteralessAppearanceEntry.isMainMenuAvailable(context: self.context) else { return }
        if self.asSheet {
            guard let root = self.context.sharedContext.mainWindow?.viewController as? NavigationController else {
                self.errorText = "The account navigation is not available."
                self.render()
                return
            }
            self.dismiss(completion: { root.pushViewController(controller) })
        } else {
            self.push(controller)
        }
    }

    private func openRequiredSearch() {
        guard !self.isClosingDrawer, ExteralessAppearanceEntry.isMainMenuAvailable(context: self.context) else { return }
        let context = self.context
        if self.asSheet {
            guard let root = self.presentationRoot else { return }
            self.dismiss(completion: {
                MainActor.assumeIsolated {
                    guard ExteralessAppearanceEntry.isMainMenuAvailable(context: context),
                          (context.sharedContext.mainWindow?.viewController as? NavigationController) === root,
                          let parent = root.topViewController as? ViewController else { return }
                    exteralessOpenMenuSearch(context: context, parent: parent, filter: .chats)
                }
            })
        } else {
            MainActor.assumeIsolated { exteralessOpenMenuSearch(context: context, parent: self, filter: .chats) }
        }
    }

    private func open(_ id: Int) {
        guard !self.isClosingDrawer, ExteralessAppearanceEntry.isMainMenuAvailable(context: self.context) else { return }
        if let route = MainActor.assumeIsolated({ ExteralessMainMenuRegistry.route(id: id) }), MainActor.assumeIsolated({ route.isAvailable(self.context) }) {
            let context = self.context
            if self.asSheet {
                guard let root = context.sharedContext.mainWindow?.viewController as? NavigationController, let parent = root.viewControllers.last as? ViewController else {
                    self.errorText = "The account navigation is not available."
                    self.render()
                    return
                }
                self.dismiss(completion: { MainActor.assumeIsolated { route.action(context, parent) } })
            } else {
                MainActor.assumeIsolated { route.action(context, self) }
            }
            return
        }
        switch id {
        case 14:
            self.navigate(self.context.sharedContext.makeChatListController(context: self.context, location: .chatList(groupId: .archive), controlsHistoryPreload: false, hideNetworkActivityStatus: false, previewing: false, enableDebugActions: false))
        case 2:
            let context = self.context
            let controller = context.sharedContext.makeContactMultiselectionController(ContactMultiselectionControllerParams(context: context, mode: .groupCreation(isCall: false), onlyWriteable: true))
            let resultDisposable = (controller.result |> take(1) |> deliverOnMainQueue).start(next: { [weak controller] result in
                guard let controller, case let .result(ids, _) = result else { return }
                let peerIds: [EnginePeer.Id] = ids.compactMap { if case let .peer(id) = $0 { return id }; return nil }
                let next = context.sharedContext.makeCreateGroupController(context: context, peerIds: peerIds, initialTitle: nil, mode: .generic, completion: nil)
                (controller.navigationController as? NavigationController)?.pushViewController(next)
            })
            exteralessRetainGroupSelection(resultDisposable, controller: controller)
            self.navigate(controller)
        case 3:
            self.navigate(exteralessChannelCreationController(context: self.context))
        case 6:
            self.navigate(ContactsController(context: self.context))
        case 10:
            self.navigate(CallListController(context: self.context, mode: .navigation))
        case 11:
            self.navigate(self.context.sharedContext.makeChatController(context: self.context, chatLocation: .peer(id: self.context.account.peerId), subject: nil, botStart: nil, mode: .standard(.default), params: nil))
        case 8:
            guard let root = self.context.sharedContext.mainWindow?.viewController as? TelegramRootController else {
                self.errorText = "The account settings are not available."
                self.render()
                return
            }
            if !exteralessRootTabsAreHidden(), let settings = root.accountSettingsController, root.rootTabController?.controllers.contains(where: { $0 === settings }) == true {
                if self.asSheet { self.dismiss(completion: { root.openSettings(edit: false) }) }
                else { root.openSettings(edit: false) }
            } else {
                self.navigate(exteralessOwnProfileController(context: self.context, settings: true))
            }
        case 102:
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.navigate(exteralessPluginManagerController(context: self.context))
            }
        case 110:
            Task { @MainActor [weak self] in
                guard let self, let settings = exteralessSettingsController(context: self.context) else { return }
                self.navigate(settings)
            }
        default:
            self.errorText = "This shortcut is not available on iOS."
            self.render()
        }
    }
}

/// Reordering and hide/show share the original serialized layout. Table indices
/// are kept independent of appearance's optional integrated-header rows.
final class ExteralessMenuLayoutController: PluginListController {
    private var layout = AppearanceMenuLayout(rawValue: "", availableIds: ExteralessMenuRoutes.ids)

    override init(context: AccountContext) {
        super.init(context: context)
        self.title = "Customize Main Menu"
        self.allowsRefresh = false
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Reset", style: .plain, target: self, action: #selector(self.resetPressed))
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadDisplayNode() {
        super.loadDisplayNode()
        self.tableView.setEditing(true, animated: false)
        self.tableView.allowsSelectionDuringEditing = true
    }

    override func render() {
        let available = Set(ExteralessMenuRoutes.available(context: self.context))
        self.layout = AppearanceMenuLayout(rawValue: ClientSettings.shared.string("appearance.mainMenuLayout"), availableIds: ExteralessMenuRoutes.known, settingsInTabs: !ClientSettings.shared.bool("appearance.mainTabsHideProfile") && !exteralessRootTabsAreHidden(), preserveUnavailable: true)
        func rows(_ ids: [Int], visible: Bool) -> [PluginListRow] {
            return ids.enumerated().map { index, id in
                var row = PluginListRow(id: "\(visible).\(id).\(index)", title: ExteralessMenuRoutes.title(id), detail: id == -1 || available.contains(id) ? (visible ? "Tap to hide" : "Tap to show") : "Position retained; this route’s native provider is not available.")
                row.enabled = !self.isBusy && (id == AppearanceMenuLayout.divider || available.contains(id)) && (visible || self.layout.visible.count < 128)
                row.action = { [weak self] in self?.toggle(at: index, visible: visible) }
                return row
            }
        }
        var add = PluginListRow(id: "add-divider", title: "Add Separator")
        add.style = .accent
        add.enabled = !self.isBusy && self.layout.visible.count < 128
        add.action = { [weak self] in
            guard let self, !self.isBusy, self.layout.visible.count < 128 else { return }
            self.layout.visible.append(AppearanceMenuLayout.divider)
            self.save(self.layout.rawValue)
        }
        self.setSections([
            PluginListSection(title: "Visible", footer: "Drag the handles to reorder. Tap a separator to remove it.", rows: rows(self.layout.visible, visible: true)),
            PluginListSection(title: "Hidden", rows: rows(self.layout.hidden, visible: false)),
            PluginListSection(rows: [add])
        ] + self.operationSections())
        self.navigationItem.rightBarButtonItem?.isEnabled = !self.isBusy && !ClientSettings.shared.string("appearance.mainMenuLayout").isEmpty
    }

    private func toggle(at index: Int, visible: Bool) {
        guard !self.isBusy else { return }
        if visible {
            guard self.layout.visible.indices.contains(index) else { return }
            if self.layout.visible[index] == AppearanceMenuLayout.settings && (ClientSettings.shared.bool("appearance.mainTabsHideProfile") || exteralessRootTabsAreHidden()) {
                self.errorText = "Keep Settings in the menu while its tab is hidden."
                self.render()
                return
            }
            let id = self.layout.visible.remove(at: index)
            if id != AppearanceMenuLayout.divider { self.layout.hidden.insert(id, at: 0) }
        } else {
            guard self.layout.hidden.indices.contains(index) else { return }
            self.layout.visible.append(self.layout.hidden.remove(at: index))
        }
        self.save(self.layout.rawValue)
    }

    @objc private func resetPressed() { self.save("") }

    private func save(_ raw: String) {
        self.perform(title: "Saving layout…", operation: {
            try await ExteralessAppearancePersistence.set(.string(raw), for: "appearance.mainMenuLayout")
        }, completion: { [weak self] in self?.render() })
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        guard !self.isBusy, indexPath.section < 2 else { return false }
        let ids = indexPath.section == 0 ? self.layout.visible : self.layout.hidden
        guard ids.indices.contains(indexPath.row) else { return false }
        return ids[indexPath.row] == AppearanceMenuLayout.divider || ExteralessMenuRoutes.available(context: self.context).contains(ids[indexPath.row])
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { .none }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }

    func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt source: IndexPath, toProposedIndexPath proposed: IndexPath) -> IndexPath {
        return proposed.section == source.section ? proposed : source
    }

    func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        guard !self.isBusy, source.section == destination.section else { self.render(); return }
        if source.section == 0 {
            self.layout.visible.insert(self.layout.visible.remove(at: source.row), at: destination.row)
        } else if source.section == 1 {
            self.layout.hidden.insert(self.layout.hidden.remove(at: source.row), at: destination.row)
        }
        self.save(self.layout.rawValue)
    }
}
