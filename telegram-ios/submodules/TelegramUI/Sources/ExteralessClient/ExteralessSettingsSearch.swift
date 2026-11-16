import AccountContext
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import UIKit

private final class ExteralessSettingsSearchNotification: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

/// The two coordinator hooks in registerActions/unregisterActions version actual
/// registration events, including remove/reinsert of the very same action value.
@MainActor
enum ExteralessSettingsSearchRegistry {
    private static var versions: [String: UUID] = [:]

    static func registered(_ id: String) { versions[id] = UUID() }
    static func removed(_ ids: Set<String>) { for id in ids { versions.removeValue(forKey: id) } }
    static func version(_ id: String) -> UUID {
        if let value = versions[id] { return value }
        let value = UUID()
        versions[id] = value
        return value
    }
}

@MainActor
enum ExteralessSettingsSearch {
    private static var current: ExteralessSettingsSearchSession?

    static func install(context: AccountContext, settings: ClientSettings = .shared, isCurrent: @escaping @MainActor () -> Bool) {
        if let current, current.matches(context: context, settings: settings) { return }
        retire()
        let session = ExteralessSettingsSearchSession(context: context, settings: settings, isCurrent: isCurrent)
        current = session
        ExteralessSettingsSearchEntry.install(session)
    }

    static func retire() {
        current?.retire()
        current = nil
        ExteralessSettingsSearchEntry.install(nil)
    }

}

/// Public injection accepts a GIVEN context and real ClientSettings, as the
/// existing settings fixture does. It never constructs accounts or a replacement
/// renderer. Shipping uses actual ExteralessSettingsUI registrations.
@MainActor
public final class ExteralessSettingsSearchSession: ExteralessSettingsSearchProvider {
    static let didChange = Notification.Name("ExteralessSettingsSearchSessionDidChange")
    private weak var context: AccountContext?
    let settings: ClientSettings
    private let contextIsCurrent: @MainActor () -> Bool
    private let actionSource: @MainActor () -> [ExteralessSettingsAction]
    private let actionVersion: @MainActor (String) -> UUID
    private var active = true
    private var index = ClientSettingsSearchIndex()
    private var observation: ClientSettingsObservation?
    private var actionObserver: ExteralessSettingsSearchNotification?
    private let pendingURLs = DisposableSet()
    private(set) var catalogError: ClientSettingsRouteError?

    public convenience init(context: AccountContext, settings: ClientSettings, isCurrent: @escaping @MainActor () -> Bool) {
        self.init(context: context, settings: settings, actions: { ExteralessSettingsUI.registeredActions },
                  registration: { ExteralessSettingsSearchRegistry.version($0) }, isCurrent: isCurrent)
    }

    public init(context: AccountContext, settings: ClientSettings,
                actions: @escaping @MainActor () -> [ExteralessSettingsAction],
                registration: @escaping @MainActor (String) -> UUID,
                isCurrent: @escaping @MainActor () -> Bool) {
        self.context = context
        self.settings = settings
        self.actionSource = actions
        self.actionVersion = registration
        self.contextIsCurrent = isCurrent
        self.observation = settings.observe { [weak self] _ in
            Task { @MainActor [weak self] in self?.changed() }
        }
        self.actionObserver = ExteralessSettingsSearchNotification(NotificationCenter.default.addObserver(forName: ExteralessSettingsUI.actionsDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.changed() }
        })
    }

    deinit {
        observation?.cancel()
        pendingURLs.dispose()
    }

    public var isCurrent: Bool { active && context != nil && contextIsCurrent() }

    func matches(context: AccountContext, settings: ClientSettings) -> Bool {
        isCurrent && self.context === context && self.settings === settings
    }

    var rootActions: [ExteralessSettingsAction] { isCurrent ? actionSource() : [] }

    public func retire() {
        guard active else { return }
        active = false
        index.retire()
        pendingURLs.dispose()
        observation?.cancel()
        observation = nil
        actionObserver = nil
        context = nil
        NotificationCenter.default.post(name: Self.didChange, object: self)
        ExteralessSettingsSearchEntry.notifyChanged()
    }

    private func changed() {
        guard isCurrent else { return }
        refresh()
        NotificationCenter.default.post(name: Self.didChange, object: self)
        ExteralessSettingsSearchEntry.notifyChanged()
    }

    private func refresh() {
        guard isCurrent else { return }
        let snapshot = settings.readSnapshot()
        let actions = rootActions.map { action in
            ClientSettingsSearchAction(id: action.id, title: action.title, section: action.section, registration: actionVersion(action.id))
        }
        do {
            try index.refresh(definitions: snapshot.definitions, secretKeys: snapshot.secretKeys, actions: actions,
                              definitionVersions: snapshot.definitionVersions,
                              localize: { clientSettingsText($0, $1) })
            catalogError = nil
        } catch { catalogError = (error as? ClientSettingsRouteError) ?? .notFound }
    }

    public func items(context: AccountContext) -> [ClientSettingsSearchItem] {
        guard isCurrent, self.context === context else { return [] }
        refresh()
        return index.items
    }

    public func results(_ query: String) -> [ClientSettingsSearchItem] {
        guard isCurrent else { return [] }
        refresh()
        return index.search(query)
    }

    public func resolve(_ request: ClientSettingsRouteRequest) throws -> ClientSettingsSearchItem {
        guard isCurrent else { throw ClientSettingsRouteError.retired }
        refresh()
        if let catalogError { throw catalogError }
        return try index.resolve(request)
    }

    public func accepts(_ ticket: ClientSettingsSearchTicket) -> Bool {
        guard isCurrent else { return false }
        refresh()
        return (try? index.validate(ticket)) != nil
    }

    public func link(ticket: ClientSettingsSearchTicket, context: AccountContext) -> URL? {
        guard isCurrent, self.context === context else { return nil }
        refresh()
        return (try? index.validate(ticket))?.link
    }

    public func makeSearchController() -> ViewController? {
        guard isCurrent, let context else { return nil }
        return ExteralessSettingsSearchController(context: context, session: self)
    }

    public func makeRoot(context: AccountContext, settings: ClientSettings?) -> ViewController? {
        guard matches(context: context, settings: settings ?? self.settings) else { return nil }
        return exteralessSettingsController(context: context, settings: self.settings, searchSession: self)
    }

    /// Resolves at user admission, not after unlock. The operation strongly owns
    /// this exact session and its typed selection; A -> B -> A cannot rebind it.
    public func prepare(request: Result<ClientSettingsRouteRequest, ClientSettingsRouteError>, context: AccountContext) -> ExteralessSettingsSearchOpen? {
        guard isCurrent, self.context === context else { return nil }
        let selection: Result<ClientSettingsSearchItem, ClientSettingsRouteError>
        do { selection = .success(try resolve(request.get())) }
        catch { selection = .failure((error as? ClientSettingsRouteError) ?? .invalidLink) }
        return ExteralessSettingsSearchOpen { [self, weak context] unlocked, presenter in
            guard let context, isCurrent, self.context === context else { return }
            let disposable = MetaDisposable()
            pendingURLs.add(disposable)
            disposable.set((unlocked
            |> filter { $0 }
            |> take(1)
            |> timeout(30.0, queue: .mainQueue(), alternate: .complete())
            |> deliverOnMainQueue).start(next: { [self, weak context] _ in
                MainActor.assumeIsolated {
                    // Check lifetime before the nil-navigation/main-window lookup.
                    guard let context, isCurrent, self.context === context, let parent = presenter() else { return }
                    do { _ = try navigate(selection.get(), from: parent) }
                    catch { show(error: (error as? ClientSettingsRouteError) ?? .invalidLink, context: context, from: parent) }
                }
            }, completed: { [pendingURLs] in
                pendingURLs.remove(disposable)
                disposable.dispose()
            }))
        }
    }

    @discardableResult
    public func open(ticket: ClientSettingsSearchTicket, context: AccountContext, from: ViewController) -> Bool {
        guard isCurrent, self.context === context else { return false }
        refresh()
        do { return try navigate(index.validate(ticket), from: from) }
        catch { show(error: (error as? ClientSettingsRouteError) ?? .notFound, context: context, from: from); return false }
    }

    @discardableResult
    public func open(request: ClientSettingsRouteRequest, context: AccountContext, from: ViewController) -> Bool {
        guard isCurrent, self.context === context else { return false }
        do { return try navigate(resolve(request), from: from) }
        catch { show(error: (error as? ClientSettingsRouteError) ?? .notFound, context: context, from: from); return false }
    }

    private func navigate(_ item: ClientSettingsSearchItem, from presenter: ViewController) throws -> Bool {
        guard isCurrent, let context else { throw ClientSettingsRouteError.retired }
        refresh()
        _ = try index.validate(item.ticket)
        presenter.view.endEditing(true)
        // End-editing/delegate callbacks may retire the scope or replace an action.
        guard accepts(item.ticket) else { throw ClientSettingsRouteError.changed }
        switch item.route {
        case let .action(id):
            guard let action = rootActions.first(where: { $0.id == id }), accepts(item.ticket) else { throw ClientSettingsRouteError.changed }
            action.action(context, presenter)
        case .root, .row, .setting:
            guard let controller = exteralessSettingsDestinationController(context: context, settings: settings,
                route: item.route, searchSession: self, ticket: item.ticket), accepts(item.ticket) else { return false }
            presenter.push(controller)
        case .search:
            guard let controller = makeSearchController(), accepts(item.ticket) else { return false }
            presenter.push(controller)
        case let .unavailable(reason): throw ClientSettingsRouteError.unavailable(reason)
        }
        return true
    }

    public func show(error: ClientSettingsRouteError, context: AccountContext, from presenter: ViewController) {
        guard isCurrent, self.context === context, presenter.presentedViewController == nil else { return }
        let alert = UIAlertController(title: clientSettingsText("Search.Unavailable", "Setting unavailable"),
                                      message: error.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: clientSettingsText("Search.OK", "OK"), style: .cancel))
        presenter.present(alert, animated: true)
    }

    /// Root's existing Reset remains an explicit action. Opening/copying the link
    /// never applies a value, invokes a toggle, or accepts Android v/value imports.
    func presentRowMenu(request: ClientSettingsRouteRequest, from presenter: ViewController, reset: (() -> Void)?) {
        guard isCurrent, let item = try? resolve(request), item.link != nil else { return }
        let menu = UIAlertController(title: item.title, message: nil, preferredStyle: .actionSheet)
        menu.addAction(UIAlertAction(title: clientSettingsText("Search.CopyLink", "Copy settings link"), style: .default) { [weak self] _ in
            guard self?.accepts(item.ticket) == true, let currentURL = ClientSettingsLink.url(for: item.route) else { return }
            UIPasteboard.general.url = currentURL
        })
        if let reset {
            menu.addAction(UIAlertAction(title: clientSettingsText("Reset", "Reset to default"), style: .destructive) { [weak self, weak menu] _ in
                guard self?.accepts(item.ticket) == true, let menu else { return }
                menu.dismiss(animated: true) { [weak self] in
                    guard self?.accepts(item.ticket) == true else { return }
                    reset()
                }
            })
        }
        menu.addAction(UIAlertAction(title: clientSettingsText("Search.Cancel", "Cancel"), style: .cancel))
        menu.popoverPresentationController?.sourceView = presenter.view
        menu.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        guard accepts(item.ticket) else { return }
        presenter.present(menu, animated: true)
    }
}

@MainActor
private final class ExteralessSettingsSearchController: ExteralessSettingsListController, UISearchBarDelegate {
    private let session: ExteralessSettingsSearchSession
    private let searchBar = UISearchBar()
    private var notification: ExteralessSettingsSearchNotification?

    init(context: AccountContext, session: ExteralessSettingsSearchSession) {
        self.session = session
        super.init(context: context)
        allowsRefresh = false
        title = clientSettingsText("Search.Title", "Search Exteraless settings")
        searchBar.placeholder = clientSettingsText("Search.Placeholder", "Name, description or Original row")
        searchBar.searchTextField.accessibilityIdentifier = "settings.search.query"
        searchBar.searchTextField.autocorrectionType = .no
        searchBar.searchTextField.autocapitalizationType = .none
        searchBar.searchTextField.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
        searchBar.delegate = self
        notification = ExteralessSettingsSearchNotification(NotificationCenter.default.addObserver(forName: ExteralessSettingsSearchSession.didChange, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.render() }
        })
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadDisplayNode() {
        super.loadDisplayNode()
        searchBar.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 56)
        tableView.tableHeaderView = searchBar
        render()
    }

    override func render() {
        guard session.isCurrent else {
            searchBar.searchTextField.resignFirstResponder()
            searchBar.isUserInteractionEnabled = false
            setSections([.init(rows: [.init(id: "settings.search.retired", title: ClientSettingsRouteError.retired.message)])])
            return
        }
        searchBar.barStyle = presentationData.theme.overallDarkAppearance ? .black : .default
        searchBar.searchTextField.textColor = presentationData.theme.list.itemPrimaryTextColor
        searchBar.tintColor = presentationData.theme.list.itemAccentColor
        let query = searchBar.text ?? ""
        let found = session.results(query)
        var rows = found.map { item -> ExteralessSettingsRow in
            let detail = [item.section, item.explanation, item.unavailableReason].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            var row = ExteralessSettingsRow(id: item.ticket.storageID, title: item.title, detail: detail)
            row.enabled = item.isAvailable
            row.accessory = item.isAvailable ? .disclosure : .none
            row.action = { [weak self] in
                guard let self else { return }
                _ = self.session.open(ticket: item.ticket, context: self.context, from: self)
            }
            row.longAction = { [weak self] in
                guard let self, self.session.accepts(item.ticket) else { return }
                self.session.presentRowMenu(request: .canonical(item.route), from: self, reset: nil)
            }
            return row
        }
        if let error = session.catalogError {
            rows = [.init(id: "settings.search.error", title: error.message)]
        } else if rows.isEmpty {
            let text = query.utf16.count > ClientSettingsSearchIndex.maximumQueryUTF16
                ? clientSettingsText("Search.TooLong", "Use a shorter search")
                : query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? clientSettingsText("Search.Hint", "Search registered settings and native pages")
                    : clientSettingsText("Search.Empty", "No matching settings")
            rows = [.init(id: "settings.search.empty", title: text)]
        }
        setSections([.init(footer: clientSettingsText("Search.Footer", "Names and descriptions only. Selecting a result opens its control; it does not change its value."), rows: rows)])
    }

    @objc private func queryChanged() { render() }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
    func searchBar(_ searchBar: UISearchBar, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        let length = (searchBar.text ?? "").utf16.count
        return range.location >= 0 && range.length >= 0 && range.location <= length && range.length <= length - range.location
            && length - range.length + text.utf16.prefix(ClientSettingsSearchIndex.maximumQueryUTF16 + 1).count <= ClientSettingsSearchIndex.maximumQueryUTF16
    }
}

/// Actual table geometry, after layout, identifies the selected row. This never
/// calls didSelectRowAt or a control action. No cell is manufactured by the helper.
@MainActor
final class ExteralessSettingsRowFocus {
    private let rowID: String
    private let valid: @MainActor () -> Bool
    private var finished = false

    init(rowID: String, valid: @escaping @MainActor () -> Bool) { self.rowID = rowID; self.valid = valid }

    func apply(to controller: ExteralessSettingsListController) {
        guard !finished, valid(), !controller.isBusy, controller.isNodeLoaded, controller.view.window != nil, !controller.tableView.bounds.isEmpty else { return }
        guard let section = controller.sections.firstIndex(where: { $0.rows.contains(where: { $0.id == rowID }) }),
              let row = controller.sections[section].rows.firstIndex(where: { $0.id == rowID }) else { return }
        let path = IndexPath(row: row, section: section)
        let table = controller.tableView
        table.layoutIfNeeded()
        table.scrollToRow(at: path, at: .middle, animated: false)
        table.layoutIfNeeded()
        guard valid(), let cell = table.cellForRow(at: path) else { return }
        finished = true
        cell.setHighlighted(true, animated: false)
        UIAccessibility.post(notification: .layoutChanged, argument: cell)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak cell, weak self] in
            guard self?.valid() == true else { return }
            cell?.setHighlighted(false, animated: true)
        }
    }
}
