import AccountContext
import Display
import Foundation
import PluginHost
import UIKit

/// Renders the same SDK settings screen with an explicitly owned host lifetime.
/// This composition seam creates no account, runtime or substitute renderer.
@MainActor
public func exteralessPluginSettingsController(context: AccountContext, actions: PluginManagerActions,
    pluginId: String, title: String, pagePath: [String] = [],
    actionScope: PluginUISettingsActionScope? = nil,
    target: String? = nil,
    scopeIsCurrent: @escaping @MainActor () -> Bool) -> ViewController {
    return PluginSettingsController(context: context, actions: actions, pluginId: pluginId,
        title: title, pagePath: pagePath, scopeIsCurrent: scopeIsCurrent, actionScope: actionScope, target: target)
}

@MainActor private func capturePluginSettingsAction(_ scope: PluginUISettingsActionScope?) throws -> PluginUISettingsActionInvocation {
    guard let scope else { throw PluginUIFailure.unavailable("Owner-bound settings execution is not installed. Reopen settings after Runtime is ready.") }
    return try scope.capture()
}

@MainActor private func capturePluginSettingsRead(_ scope: PluginUISettingsActionScope?) throws -> PluginUISettingsReadInvocation {
    guard let scope else { throw PluginUIFailure.unavailable("Owner-bound settings reads are not installed. Reopen settings after Runtime is ready.") }
    return try scope.captureRead()
}

@MainActor private func pluginSettingsAvailabilityError(actions: PluginManagerActions, id: String) -> String? {
    guard let plugin = actions.snapshot().first(where: { $0.id == id }) else {
        return pluginText("Plugin.Missing", "Plugin not found")
    }
    if let error = plugin.loadError { return error }
    if plugin.notResponding { return pluginText("Plugin.NotResponding", "Not responding") }
    if !plugin.loaded || !plugin.isEnabled {
        return pluginText("Plugin.SettingsUnavailable", "Settings require a running plugin.")
    }
    if !plugin.hasSettings { return pluginText("Plugin.NoSettings", "This plugin does not provide settings.") }
    return nil
}

func requirePluginSettingsScope(_ scope: @MainActor () -> Bool) async throws {
    guard await scope() else { throw PluginHostError.superseded("Settings page belongs to an expired plugin/account lifetime") }
}

@MainActor private func loadPluginSettings(actions: PluginManagerActions, id: String, scope: @escaping @MainActor () -> Bool,
                                          read: PluginUISettingsReadInvocation) async throws -> PluginUIManagerSettingsDocument {
    try await requirePluginSettingsScope(scope)
    let lease = PluginSettingsPageLease(owner: read.owner, account: read.account)
    PluginUIManagerSettingsLifetimes.track(lease)
    var transferred = false
    defer { if !transferred { lease.close() } }
    let json = try await PluginUISettingsReadExecution.withInvocation(read) {
        try await PluginSettingsPageExecution.$current.withValue(lease) { try await actions.settings(id) }
    }
    guard lease.wasRead else { throw PluginUIFailure.unavailable("Manager settings materialization is not bound to Host.settingsJSON(page:)") }
    guard read.isCurrent else { throw PluginHostError.superseded("Settings read/page expired before decoding") }
    try await requirePluginSettingsScope(scope)
    let document: PluginUIManagerSettingsDocument
    do {
        document = try await Task.detached(priority: .userInitiated) {
            return try PluginUIManagerSettingsDocument.decode(json, lease: lease)
        }.value
    } catch {
        throw PluginUIError(message: pluginText("Settings.InvalidJSON", "Invalid settings response") + "\n" + pluginErrorText(error))
    }
    try Task.checkCancellation()
    guard read.isCurrent else { throw PluginHostError.superseded("Settings read/page expired after decoding") }
    try await requirePluginSettingsScope(scope)
    transferred = true
    return document
}

private struct PluginSettingsMutationResult: Sendable {
    let document: PluginUIManagerSettingsDocument
    let read: PluginUISettingsReadInvocation
    let error: String?
}

/// A callback can throw after persisting a value. Re-read the host in both cases,
/// so the UI never claims that a failed callback rolled a stored value back.
@MainActor private func mutatePluginSettings(actions: PluginManagerActions, id: String, scope: @escaping @MainActor () -> Bool,
                                   actionScope: PluginUISettingsActionScope?, invocation: PluginUISettingsActionInvocation,
                                   page: PluginSettingsPageLease,
                                   mutation: @MainActor () async throws -> Void) async throws -> PluginSettingsMutationResult {
    try await requirePluginSettingsScope(scope)
    var mutationError: String?
    do {
        try await PluginUISettingsActionExecution.withInvocation(invocation) {
            try await PluginSettingsPageExecution.$current.withValue(page, operation: mutation)
        }
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as PluginHostError {
        if case .superseded = error { throw error }
        mutationError = pluginErrorText(error)
    } catch {
        mutationError = pluginErrorText(error)
    }
    // An expired page must not turn a rejected mutation into a fresh Python
    // create_settings callback. Ordinary current callback failures still reread
    // their actual persisted value, as before.
    try Task.checkCancellation()
    guard invocation.isCurrent else { throw PluginHostError.superseded("Settings action/page expired before refresh") }
    do {
        let read = try capturePluginSettingsRead(actionScope)
        let document = try await loadPluginSettings(actions: actions, id: id, scope: scope, read: read)
        return PluginSettingsMutationResult(document: document, read: read, error: mutationError)
    } catch {
        if let mutationError {
            throw PluginUIError(message: mutationError + "\n\n" + pluginErrorText(error))
        }
        throw error
    }
}

/// Renders SDK settings, including host-produced sub_page trees. Opening and
/// reloading a page are the only reads that invoke create_settings; layout never does.
final class PluginSettingsController: PluginListController {
    private let actions: PluginManagerActions
    private let pluginId: String
    private let pageTitle: String
    private var pagePath: [String]
    private let settingTarget: String?
    private var targetRowId: String?
    private var targetNeedsReveal = false
    private var document: PluginUIManagerSettingsDocument?
    private var widgetEvents: PluginUIManagerWidgetEvents?
    private var widgetValues: [String: [String: PluginUIJSON]] = [:]
    private var widgetSelector: UIAlertController?
    private var iconImages: [PluginUISettingsRowIdentity: UIImage] = [:]
    private var schemaIsCurrent = false
    private let scopeIsCurrent: @MainActor () -> Bool
    private let actionScope: PluginUISettingsActionScope?
    private var reloadObservation: PluginUISettingsObservation?
    private var runtimeObservation: NSObjectProtocol?
    private var pendingExternalReload = false
    private var externalReloadScheduled = false

    init(context: AccountContext, actions: PluginManagerActions, pluginId: String, title: String, pagePath: [String] = [], scopeIsCurrent: (@MainActor () -> Bool)? = nil, actionScope: PluginUISettingsActionScope? = nil, target: String? = nil) {
        self.actions = actions
        self.pluginId = pluginId
        self.pageTitle = title
        self.pagePath = pagePath
        self.settingTarget = target
        self.scopeIsCurrent = scopeIsCurrent ?? MainActor.assumeIsolated { ExteralessPluginRuntime.shared.settingsScope(context: context, pluginId: pluginId) }
        self.actionScope = actionScope ?? MainActor.assumeIsolated { PluginUISettingsActionRegistry.capture(context: context, pluginId: pluginId) }
        super.init(context: context)
        self.reloadObservation = MainActor.assumeIsolated {
            PluginUISettingsRefresh.observe(pluginId: pluginId) { [weak self] in
                guard let self else { return }
                self.actionScope?.invalidate()
                self.document?.lease.close()
                self.widgetEvents?.cancel()
                self.schemaIsCurrent = false
                self.pendingExternalReload = true
                self.render()
            }
        }
        self.runtimeObservation = NotificationCenter.default.addObserver(forName: ExteralessPluginRuntime.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.scopeIsCurrent() else { return }
                self.actionScope?.close()
                self.document?.lease.close()
                self.widgetEvents?.cancel()
                self.schemaIsCurrent = false
                self.errorText = pluginText("Settings.ScopeExpired", "This plugin or account changed. Go back and reopen settings.")
                self.render()
            }
        }
    }

    deinit {
        self.actionScope?.close()
        self.document?.lease.close()
        if let observer = self.runtimeObservation { NotificationCenter.default.removeObserver(observer) }
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillAppear(_ animated: Bool) {
        self.actionScope?.beginAppearance()
        super.viewWillAppear(animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.actionScope?.setVisible(true)
        self.revealTarget()
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.actionScope?.setVisible(false)
        self.widgetEvents?.cancel()
        self.widgetSelector?.dismiss(animated: false)
        self.widgetSelector = nil
        super.viewWillDisappear(animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let retained = (self.navigationController as? NavigationController)?.viewControllers.contains(where: { $0 === self }) == true
        if !retained && self.presentedViewController == nil { self.document?.lease.close() }
    }

    override func refresh() {
        guard !self.isBusy else { return }
        self.actionScope?.invalidate()
        self.document?.lease.close()
        self.widgetEvents?.cancel()
        self.widgetSelector?.dismiss(animated: false)
        self.widgetSelector = nil
        self.pendingExternalReload = false
        self.schemaIsCurrent = false
        guard self.scopeIsCurrent() else {
            self.errorText = pluginText("Settings.ScopeExpired", "This plugin or account changed. Go back and reopen settings.")
            self.tableView.refreshControl?.endRefreshing()
            self.render()
            return
        }
        if let error = pluginSettingsAvailabilityError(actions: self.actions, id: self.pluginId) {
            self.errorText = error
            self.tableView.refreshControl?.endRefreshing()
            self.render()
            return
        }
        let read: PluginUISettingsReadInvocation
        do { read = try capturePluginSettingsRead(self.actionScope) }
        catch { self.errorText = pluginErrorText(error); self.tableView.refreshControl?.endRefreshing(); self.render(); return }
        let actions = self.actions
        let id = self.pluginId
        let scope = self.scopeIsCurrent
        self.perform(title: pluginText("Settings.Loading", "Loading settings…"), operation: {
            return try await loadPluginSettings(actions: actions, id: id, scope: scope, read: read)
        }, completion: { [weak self] document in
            guard read.isCurrent else { document.lease.close(); return }
            self?.apply(document)
        })
    }

    private func apply(_ document: PluginUIManagerSettingsDocument) {
        self.actionScope?.invalidateActions()
        guard self.scopeIsCurrent(), document.lease.isOpen else { document.lease.close(); self.schemaIsCurrent = false; return }
        if self.document?.lease !== document.lease { self.document?.lease.close() }
        self.widgetEvents?.cancel()
        do {
            self.iconImages = try document.icons.mapValues { try PluginUIResources.image($0) }
            try document.validateResources(data: self.presentationData)
            if let target = self.settingTarget {
                let location = try PluginSettingsDocument.resolve(target: target, in: document.rows)
                self.pagePath = location.pagePath
                self.targetRowId = location.rowId
                self.targetNeedsReveal = true
            }
        }
        catch {
            document.lease.close()
            self.schemaIsCurrent = false
            self.errorText = String(describing: error)
            return
        }
        self.document = document
        self.widgetValues.removeAll()
        self.widgetEvents = PluginUIManagerWidgetEvents(lease: document.lease, actions: self.actions) { [weak self] error in
            guard let self, self.document?.lease === document.lease, document.lease.isOpen else { return }
            self.errorText = error
            self.render()
        }
        if let error = pluginSettingsAvailabilityError(actions: self.actions, id: self.pluginId) {
            self.schemaIsCurrent = false
            document.lease.close()
            self.errorText = self.errorText ?? error
            return
        }
        let pageExists = document.page(self.pagePath) != nil
        self.schemaIsCurrent = !self.pendingExternalReload && pageExists
        if self.schemaIsCurrent { self.actionScope?.publish() }
        if !pageExists {
            document.lease.close()
            self.errorText = pluginText("Settings.PageMissing", "This settings page is no longer available. Go back to the previous page.")
        }
    }

    override func render() {
        self.title = self.pageTitle
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: pluginText("Refresh", "Refresh"), style: .plain, target: self, action: #selector(self.reloadPressed))
        self.navigationItem.rightBarButtonItem?.isEnabled = !self.isBusy
        var sections = self.operationSections()
        if let document = self.document, let page = document.page(self.pagePath) {
            if page.isEmpty {
                sections.append(PluginListSection(rows: [PluginListRow(id: "empty-settings", title: pluginText("Settings.Empty", "No settings on this page"))]))
            } else {
                let firstPageSection = sections.count
                var section = PluginListSection(rows: [])
                func appendSection() {
                    if !section.rows.isEmpty || section.title != nil || section.footer != nil {
                        sections.append(section)
                    }
                    section = PluginListSection(rows: [])
                }
                for item in page {
                    switch item.kind {
                    case .header:
                        appendSection()
                        section.title = item.text
                    case .divider:
                        section.footer = item.text
                        appendSection()
                    default:
                        section.rows.append(self.makeRow(item))
                    }
                }
                appendSection()
                if sections.count == firstPageSection {
                    sections.append(PluginListSection(rows: [PluginListRow(id: "empty-settings", title: pluginText("Settings.Empty", "No settings on this page"))]))
                }
            }
        }
        if !self.schemaIsCurrent && !self.isBusy {
            var row = PluginListRow(id: "retry", title: pluginText("Settings.Reload", "Reload settings"), detail: pluginText("Settings.Stale", "Refresh to read the current settings from the plugin."))
            row.style = .accent
            row.action = { [weak self] in self?.refresh() }
            sections.append(PluginListSection(rows: [row]))
        }
        self.setSections(sections)
        self.revealTarget()
        if self.pendingExternalReload && !self.externalReloadScheduled && !self.isBusy && self.isScreenVisible && self.scopeIsCurrent() {
            self.externalReloadScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.externalReloadScheduled = false
                if self.isScreenVisible && !self.isBusy && self.scopeIsCurrent() { self.refresh() }
            }
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = self.sections[indexPath.section].rows[indexPath.row].id
        if let document = self.document,
           let widget = document.widgets[PluginUISettingsRowIdentity(path: self.pagePath, rowId: id)] {
            let cell = PluginUIManagerCustomCell(style: .default, reuseIdentifier: nil)
            let route = PluginUIManagerWidgetRoute(rowId: id, root: widget)
            do {
                try cell.configure(model: widget, data: self.presentationData, enabled: self.schemaIsCurrent && !self.isBusy && document.lease.isOpen,
                    values: self.widgetValues[id] ?? [:],
                    change: { [weak self] widget, value in
                        guard let self, self.sendWidget(route: route, widget: widget, name: "change", value: value, page: document.lease) else { return false }
                        self.widgetValues[id, default: [:]][widget.key] = value
                        return true
                    }, select: { [weak self] widget, source in
                        self?.selectWidget(route: route, widget: widget, source: source, page: document.lease)
                    }, activated: { [weak self] widget, long in
                        _ = self?.sendWidget(route: route, widget: widget, name: long ? "longAction" : "action", page: document.lease)
                    }, layoutChanged: { [weak self] in
                        guard let self, self.document?.lease === document.lease else { return }
                        UIView.performWithoutAnimation { self.tableView.beginUpdates(); self.tableView.endUpdates() }
                    })
                cell.rootLongAction = self.sections[indexPath.section].rows[indexPath.row].longAction
                return cell
            } catch {
                document.lease.close()
                self.schemaIsCurrent = false
                let errorCell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
                errorCell.textLabel?.text = pluginText("Settings.Unsupported", "Unsupported native setting type")
                errorCell.detailTextLabel?.text = pluginErrorText(error)
                errorCell.detailTextLabel?.numberOfLines = 0
                return errorCell
            }
        }
        let cell = super.tableView(tableView, cellForRowAt: indexPath)
        PluginUISettingsRowIcon.apply(image: self.iconImages[PluginUISettingsRowIdentity(path: self.pagePath, rowId: id)],
            color: self.presentationData.theme.list.itemAccentColor, to: cell)
        return cell
    }

    private func makeRow(_ item: PluginSetting) -> PluginListRow {
        let page = self.document?.lease
        var row = PluginListRow(id: item.identifier, title: item.title, detail: item.subtext)
        row.enabled = self.schemaIsCurrent && !self.isBusy
        if let callbackId = item.longCallbackId {
            row.longAction = { [weak self] in self?.click(callbackId: callbackId, openPage: nil, page: page) }
        }
        switch item.kind {
        case .switch:
            if case let .bool(value) = item.currentValue, let key = item.key {
                row.toggle = (value, { [weak self] updated in self?.update(key: key, value: .bool(updated), page: page) })
            }
        case .selector:
            let choices = item.items ?? []
            var selected: String?
            if case let .number(value) = item.currentValue {
                selected = choices.enumerated().first(where: { Double($0.offset) == value })?.element
            }
            let label = selected ?? pluginText("Settings.NoSelection", "No selection")
            row.detail = [item.subtext, label].compactMap { $0 }.joined(separator: "\n")
            row.accessory = .disclosure
            row.enabled = row.enabled && !choices.isEmpty
            row.action = { [weak self] in
                guard let self, let page, self.matches(page), self.checkAvailability() else { return }
                self.push(PluginSettingSelectorController(context: self.context, actions: self.actions, pluginId: self.pluginId, pagePath: self.pagePath, setting: item, scope: self.scopeIsCurrent, actionScope: self.actionScope?.fork(), pageLease: page, updated: { [weak self] document in
                    self?.apply(document)
                }))
            }
        case .input, .edittext:
            let value = item.currentValue?.string ?? ""
            row.detail = [item.subtext, value.isEmpty ? pluginText("Settings.EmptyValue", "Empty") : value].compactMap { $0 }.joined(separator: "\n")
            row.accessory = .disclosure
            row.action = { [weak self] in
                guard let self, let page, self.matches(page), self.checkAvailability() else { return }
                self.push(PluginSettingInputController(context: self.context, actions: self.actions, pluginId: self.pluginId, setting: item, scope: self.scopeIsCurrent, actionScope: self.actionScope?.fork(), pageLease: page, updated: { [weak self] document in
                    self?.apply(document)
                }))
            }
        case .slider:
            if let range = item.sliderRange, case let .number(value) = item.currentValue, let key = item.key {
                row.slider = PluginListSlider(range: range, value: range.normalize(value), commit: { [weak self] value in
                    self?.update(key: key, value: .number(value), page: page)
                })
            }
        case .text:
            if item.red == true { row.style = .destructive } else if item.accent == true { row.style = .accent }
            if item.subPage != nil { row.accessory = .disclosure }
            if item.callbackId != nil || item.subPage != nil {
                row.action = { [weak self] in
                    guard let self, let page, self.matches(page), self.checkAvailability() else { return }
                    if let callbackId = item.callbackId {
                        self.click(callbackId: callbackId, openPage: item.subPage == nil ? nil : item.identifier, page: page)
                    } else {
                        self.openSubpage(item)
                    }
                }
            }
        case .custom:
            if self.document?.widgets[PluginUISettingsRowIdentity(path: self.pagePath, rowId: item.identifier)] != nil {
                if item.callbackId != nil || item.subPage != nil {
                    row.action = { [weak self] in self?.click(callbackId: item.callbackId,
                        openPage: item.subPage == nil ? nil : item.identifier, page: page, orderedCustom: true) }
                }
                if let callback = item.longCallbackId {
                    row.longAction = { [weak self] in self?.click(callbackId: callback, openPage: nil, page: page, orderedCustom: true) }
                }
            } else {
                row.style = .error
                row.detail = item.customError ?? "Custom requires an owner-worker portable Widget model"
                row.longAction = nil
                row.enabled = false
            }
        case .header, .divider:
            break
        case .none:
            row.style = .error
            row.detail = [item.subtext, pluginText("Settings.Unsupported", "Unsupported native setting type") + ": " + item.type].compactMap { $0 }.joined(separator: "\n")
            row.longAction = nil
        }
        return row
    }

    private func checkAvailability() -> Bool {
        guard self.scopeIsCurrent() else {
            self.schemaIsCurrent = false
            self.errorText = pluginText("Settings.ScopeExpired", "This plugin or account changed. Go back and reopen settings.")
            self.render()
            return false
        }
        if let error = pluginSettingsAvailabilityError(actions: self.actions, id: self.pluginId) {
            self.schemaIsCurrent = false
            self.errorText = error
            self.render()
            return false
        }
        return !self.isBusy && self.schemaIsCurrent && self.document?.lease.isOpen == true
    }

    private func matches(_ page: PluginSettingsPageLease) -> Bool { self.document?.lease === page && page.isOpen }

    private func update(key: String, value: PluginSettingValue, page: PluginSettingsPageLease?) {
        guard let page, self.matches(page), self.checkAvailability() else { return }
        let invocation: PluginUISettingsActionInvocation
        do { invocation = try capturePluginSettingsAction(self.actionScope) }
        catch { self.errorText = pluginErrorText(error); self.render(); return }
        let actions = self.actions
        let id = self.pluginId
        let scope = self.scopeIsCurrent
        let actionScope = self.actionScope
        self.schemaIsCurrent = false
        self.perform(title: pluginText("Settings.Saving", "Saving setting…"), operation: {
            return try await mutatePluginSettings(actions: actions, id: id, scope: scope, actionScope: actionScope, invocation: invocation, page: page, mutation: {
                try await actions.updateSetting(id, key, value.json())
            })
        }, completion: { [weak self] result in
            guard let self, result.read.isCurrent else { return }
            self.errorText = result.error
            self.apply(result.document)
        })
    }

    private func click(callbackId: String?, openPage: String?, page: PluginSettingsPageLease?, orderedCustom: Bool = false) {
        guard let page, self.matches(page), self.checkAvailability() else { return }
        let invocation: PluginUISettingsActionInvocation
        do { invocation = try capturePluginSettingsAction(self.actionScope) }
        catch { self.errorText = pluginErrorText(error); self.render(); return }
        let ordered: PluginUIManagerEventReceipt?
        do {
            if orderedCustom {
                guard let events = self.widgetEvents, events.lease === page else { throw PluginUIFailure.invalidHandle("Custom page FIFO is unavailable") }
                ordered = try events.root(callbackId: callbackId, invocation: invocation)
            } else { ordered = nil }
        } catch { self.errorText = pluginErrorText(error); self.render(); return }
        let actions = self.actions
        let id = self.pluginId
        let scope = self.scopeIsCurrent
        let actionScope = self.actionScope
        self.schemaIsCurrent = false
        self.perform(title: pluginText("Settings.Applying", "Applying plugin action…"), operation: {
            return try await mutatePluginSettings(actions: actions, id: id, scope: scope, actionScope: actionScope, invocation: invocation, page: page, mutation: {
                if let ordered { try await ordered.value() }
                else if let callbackId { try await actions.click(id, callbackId) }
            })
        }, completion: { [weak self] result in
            guard let self, result.read.isCurrent else { return }
            self.errorText = result.error
            self.apply(result.document)
            if self.errorText == nil, self.schemaIsCurrent, self.isScreenVisible, self.scopeIsCurrent(), let identifier = openPage {
                if let item = result.document.page(self.pagePath)?.first(where: { $0.identifier == identifier }), item.subPage != nil {
                    self.openSubpage(item)
                } else {
                    self.errorText = pluginText("Settings.PageMissing", "This settings page is no longer available. Go back to the previous page.")
                }
            }
        })
    }

    private func sendWidget(route: PluginUIManagerWidgetRoute, widget: PluginUIWidget, name: String,
                            value: PluginUIJSON? = nil, page: PluginSettingsPageLease) -> Bool {
        guard self.matches(page), self.checkAvailability(), let events = self.widgetEvents, events.lease === page else { return false }
        do {
            let invocation = try capturePluginSettingsAction(self.actionScope)
            let (callback, json) = try route.event(widget: widget, name: name, value: value)
            return events.send(callbackId: callback, eventJSON: json, invocation: invocation)
        } catch {
            self.errorText = pluginErrorText(error)
            return false
        }
    }

    private func selectWidget(route: PluginUIManagerWidgetRoute, widget: PluginUIWidget, source: UIView, page: PluginSettingsPageLease) {
        guard self.matches(page), self.checkAvailability(), self.widgetSelector == nil else { return }
        // Capture the rendered page revision before presenting the native menu.
        // Its delayed choice must not acquire a fresh permit after a refresh.
        let invocation: PluginUISettingsActionInvocation
        do { invocation = try capturePluginSettingsAction(self.actionScope) }
        catch { self.errorText = pluginErrorText(error); return }
        let selector = UIAlertController(title: widget.text, message: nil, preferredStyle: .actionSheet)
        for (index, choice) in widget.choices.enumerated() {
            selector.addAction(UIAlertAction(title: choice, style: .default) { [weak self] _ in
                guard let self else { return }
                self.widgetSelector = nil
                guard self.matches(page), invocation.isCurrent, let events = self.widgetEvents, events.lease === page else { return }
                do {
                    let value = PluginUIJSON.integer(Int64(index))
                    let (callback, json) = try route.event(widget: widget, name: "change", value: value)
                    if events.send(callbackId: callback, eventJSON: json, invocation: invocation) {
                        self.widgetValues[route.rowId, default: [:]][widget.key] = value
                        self.render()
                    }
                } catch { self.errorText = pluginErrorText(error); self.render() }
            })
        }
        selector.addAction(UIAlertAction(title: self.presentationData.strings.Common_Cancel, style: .cancel) { [weak self] _ in self?.widgetSelector = nil })
        selector.popoverPresentationController?.sourceView = source
        selector.popoverPresentationController?.sourceRect = source.bounds
        self.widgetSelector = selector
        self.present(selector, animated: true)
    }

    private func revealTarget() {
        guard self.targetNeedsReveal, self.schemaIsCurrent, self.isScreenVisible, self.scopeIsCurrent(),
              self.document?.lease.isOpen == true, let target = self.targetRowId else { return }
        for (section, rows) in self.sections.enumerated() {
            if let row = rows.rows.firstIndex(where: { $0.id == target }) {
                self.tableView.layoutIfNeeded()
                self.tableView.scrollToRow(at: IndexPath(row: row, section: section), at: .middle, animated: false)
                self.targetNeedsReveal = false
                return
            }
        }
    }

    private func openSubpage(_ item: PluginSetting) {
        guard item.subPage != nil, self.scopeIsCurrent() else { return }
        self.push(PluginSettingsController(context: self.context, actions: self.actions, pluginId: self.pluginId, title: item.title, pagePath: self.pagePath + [item.identifier], scopeIsCurrent: self.scopeIsCurrent, actionScope: self.actionScope?.fork()))
    }

    @objc private func reloadPressed() {
        self.refresh()
    }
}

private final class PluginSettingSelectorController: PluginListController {
    private let actions: PluginManagerActions
    private let pluginId: String
    private let pagePath: [String]
    private let updated: (PluginUIManagerSettingsDocument) -> Void
    private var pageLease: PluginSettingsPageLease
    private let scopeIsCurrent: @MainActor () -> Bool
    private let actionScope: PluginUISettingsActionScope?
    private var reloadObservation: PluginUISettingsObservation?
    private var pendingExternalReload = false
    private var setting: PluginSetting
    private var selectionIsCurrent = true
    private var hasAppeared = false

    init(context: AccountContext, actions: PluginManagerActions, pluginId: String, pagePath: [String], setting: PluginSetting, scope: @escaping @MainActor () -> Bool, actionScope: PluginUISettingsActionScope?, pageLease: PluginSettingsPageLease, updated: @escaping (PluginUIManagerSettingsDocument) -> Void) {
        self.actions = actions
        self.pluginId = pluginId
        self.pagePath = pagePath
        self.setting = setting
        self.pageLease = pageLease
        self.updated = updated
        self.scopeIsCurrent = scope
        self.actionScope = actionScope
        super.init(context: context)
        self.actionScope?.publish()
        self.reloadObservation = MainActor.assumeIsolated {
            PluginUISettingsRefresh.observe(pluginId: pluginId) { [weak self] in
                guard let self else { return }
                self.actionScope?.invalidate()
                self.pageLease.close()
                self.selectionIsCurrent = false
                self.pendingExternalReload = true
                if self.isScreenVisible && !self.isBusy { self.refresh() }
            }
        }
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { self.actionScope?.close(); self.pageLease.close() }

    override func viewWillAppear(_ animated: Bool) {
        self.actionScope?.beginAppearance()
        super.viewWillAppear(animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.actionScope?.setVisible(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.actionScope?.setVisible(false)
        super.viewWillDisappear(animated)
    }

    override func refresh() {
        guard !self.isBusy else { return }
        guard self.scopeIsCurrent() else { self.actionScope?.close(); self.selectionIsCurrent = false; self.render(); return }
        let firstAppearance = !self.hasAppeared
        self.hasAppeared = true
        if let error = pluginSettingsAvailabilityError(actions: self.actions, id: self.pluginId) {
            self.selectionIsCurrent = false
            self.errorText = error
            self.tableView.refreshControl?.endRefreshing()
            self.render()
            return
        }
        if firstAppearance && !self.pendingExternalReload {
            self.render()
            return
        }
        self.actionScope?.invalidate()
        self.pageLease.close()
        let read: PluginUISettingsReadInvocation
        do { read = try capturePluginSettingsRead(self.actionScope) }
        catch { self.errorText = pluginErrorText(error); self.tableView.refreshControl?.endRefreshing(); self.render(); return }
        let actions = self.actions
        let id = self.pluginId
        let scope = self.scopeIsCurrent
        self.pendingExternalReload = false
        self.selectionIsCurrent = false
        self.perform(title: pluginText("Settings.Loading", "Loading settings…"), operation: {
            return try await loadPluginSettings(actions: actions, id: id, scope: scope, read: read)
        }, completion: { [weak self] document in
            guard read.isCurrent else { document.lease.close(); return }
            self?.apply(document)
        })
    }

    private func apply(_ document: PluginUIManagerSettingsDocument) {
        self.actionScope?.invalidateActions()
        guard self.scopeIsCurrent(), document.lease.isOpen else { document.lease.close(); self.selectionIsCurrent = false; return }
        if self.pageLease !== document.lease { self.pageLease.close() }
        self.pageLease = document.lease
        self.updated(document)
        if let error = pluginSettingsAvailabilityError(actions: self.actions, id: self.pluginId) {
            self.selectionIsCurrent = false
            self.errorText = self.errorText ?? error
            return
        }
        if let setting = document.page(self.pagePath)?.first(where: { $0.identifier == self.setting.identifier }), setting.kind == .selector {
            self.setting = setting
            self.selectionIsCurrent = !self.pendingExternalReload
            if self.selectionIsCurrent { self.actionScope?.publish() }
        } else {
            self.selectionIsCurrent = false
            self.errorText = pluginText("Settings.SettingMissing", "This setting is no longer available. Go back and reload the settings.")
        }
    }

    override func render() {
        self.title = self.setting.title
        var sections = self.operationSections()
        var rows: [PluginListRow] = []
        for (index, choice) in (self.setting.items ?? []).enumerated() {
            let page = self.pageLease
            var row = PluginListRow(id: "choice:\(index)", title: choice)
            row.enabled = !self.isBusy && self.selectionIsCurrent && self.scopeIsCurrent() && page.isOpen
            if case let .number(value) = self.setting.currentValue, value == Double(index) { row.accessory = .checkmark }
            row.action = { [weak self] in self?.select(index: index, page: page) }
            rows.append(row)
        }
        sections.append(PluginListSection(footer: self.setting.subtext, rows: rows))
        if !self.selectionIsCurrent && !self.isBusy {
            var row = PluginListRow(id: "reload", title: pluginText("Settings.Reload", "Reload settings"))
            row.style = .accent
            row.action = { [weak self] in self?.refresh() }
            sections.append(PluginListSection(rows: [row]))
        }
        self.setSections(sections)
        if self.pendingExternalReload && !self.isBusy && self.isScreenVisible && self.scopeIsCurrent() {
            self.pendingExternalReload = false
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
    }

    private func select(index: Int, page: PluginSettingsPageLease) {
        guard self.pageLease === page, page.isOpen, self.selectionIsCurrent, self.scopeIsCurrent(), !self.isBusy, let key = self.setting.key else { return }
        if let error = pluginSettingsAvailabilityError(actions: self.actions, id: self.pluginId) {
            self.selectionIsCurrent = false
            self.errorText = error
            self.render()
            return
        }
        let invocation: PluginUISettingsActionInvocation
        do { invocation = try capturePluginSettingsAction(self.actionScope) }
        catch { self.errorText = pluginErrorText(error); self.render(); return }
        let actions = self.actions
        let id = self.pluginId
        let scope = self.scopeIsCurrent
        let actionScope = self.actionScope
        self.selectionIsCurrent = false
        self.perform(title: pluginText("Settings.Saving", "Saving setting…"), operation: {
            return try await mutatePluginSettings(actions: actions, id: id, scope: scope, actionScope: actionScope, invocation: invocation, page: page, mutation: {
                try await actions.updateSetting(id, key, PluginSettingValue.number(Double(index)).json())
            })
        }, completion: { [weak self] result in
            guard let self, result.read.isCurrent else { return }
            self.errorText = result.error
            self.apply(result.document)
            if self.errorText == nil, self.isScreenVisible, self.scopeIsCurrent(), self.selectionIsCurrent { self.dismiss(animated: true) }
        })
    }
}

private final class PluginSettingInputController: PluginListController {
    private let actions: PluginManagerActions
    private let pluginId: String
    private let setting: PluginSetting
    private let updated: (PluginUIManagerSettingsDocument) -> Void
    private let pageLease: PluginSettingsPageLease
    private let scopeIsCurrent: @MainActor () -> Bool
    private let actionScope: PluginUISettingsActionScope?
    private var reloadObservation: PluginUISettingsObservation?
    private var settingIsCurrent = true
    private var draft: String

    init(context: AccountContext, actions: PluginManagerActions, pluginId: String, setting: PluginSetting, scope: @escaping @MainActor () -> Bool, actionScope: PluginUISettingsActionScope?, pageLease: PluginSettingsPageLease, updated: @escaping (PluginUIManagerSettingsDocument) -> Void) {
        self.actions = actions
        self.pluginId = pluginId
        self.setting = setting
        self.pageLease = pageLease
        self.updated = updated
        self.scopeIsCurrent = scope
        self.actionScope = actionScope
        self.draft = setting.currentValue?.string ?? ""
        super.init(context: context)
        self.actionScope?.publish()
        self.allowsRefresh = false
        self.reloadObservation = MainActor.assumeIsolated {
            PluginUISettingsRefresh.observe(pluginId: pluginId) { [weak self] in
                guard let self else { return }
                self.actionScope?.invalidate()
                self.pageLease.close()
                self.settingIsCurrent = false
                self.errorText = pluginText("Settings.InputChanged", "This setting changed. Your draft is preserved; go back and reopen the setting.")
                self.render()
            }
        }
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { self.actionScope?.close(); self.pageLease.close() }

    override func viewWillAppear(_ animated: Bool) {
        self.actionScope?.beginAppearance()
        super.viewWillAppear(animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.actionScope?.setVisible(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.actionScope?.setVisible(false)
        super.viewWillDisappear(animated)
    }

    override func render() {
        self.title = self.setting.title
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Save, style: .done, target: self, action: #selector(self.savePressed))
        self.updateSaveButton()
        var sections = self.operationSections()
        var row = PluginListRow(id: "input", title: self.setting.title, detail: self.setting.subtext)
        row.enabled = !self.isBusy && self.scopeIsCurrent() && self.settingIsCurrent
        row.input = PluginListInput(text: self.draft, placeholder: self.setting.hint ?? self.setting.text ?? "", multiline: self.setting.multiline ?? false, maxLength: self.setting.maxLength, updated: { [weak self] text in
            self?.draft = text
            self?.updateSaveButton()
        }, submitted: { [weak self] in self?.savePressed() })
        var footer: String?
        if let maximum = self.setting.maxLength {
            footer = pluginText("Settings.MaximumLength", "Maximum length") + ": \(maximum)"
        }
        sections.append(PluginListSection(footer: footer, rows: [row]))
        self.setSections(sections)
    }

    private func updateSaveButton() {
        let lengthValid = self.setting.maxLength.map { self.draft.unicodeScalars.count <= $0 } ?? true
        self.navigationItem.rightBarButtonItem?.isEnabled = !self.isBusy && lengthValid && self.scopeIsCurrent() && self.settingIsCurrent
    }

    @objc private func savePressed() {
        guard !self.isBusy, self.scopeIsCurrent(), self.settingIsCurrent, self.pageLease.isOpen, let key = self.setting.key else { return }
        if let maximum = self.setting.maxLength, self.draft.unicodeScalars.count > maximum { return }
        if let error = pluginSettingsAvailabilityError(actions: self.actions, id: self.pluginId) {
            self.errorText = error
            self.render()
            return
        }
        let invocation: PluginUISettingsActionInvocation
        do { invocation = try capturePluginSettingsAction(self.actionScope) }
        catch { self.errorText = pluginErrorText(error); self.render(); return }
        self.view.endEditing(true)
        let actions = self.actions
        let id = self.pluginId
        let draft = self.draft
        let scope = self.scopeIsCurrent
        let actionScope = self.actionScope
        let page = self.pageLease
        self.perform(title: pluginText("Settings.Saving", "Saving setting…"), operation: {
            return try await mutatePluginSettings(actions: actions, id: id, scope: scope, actionScope: actionScope, invocation: invocation, page: page, mutation: {
                try await actions.updateSetting(id, key, PluginSettingValue.string(draft).json())
            })
        }, completion: { [weak self] result in
            guard let self, result.read.isCurrent else { return }
            self.updated(result.document)
            self.errorText = result.error ?? (self.settingIsCurrent ? nil : pluginText("Settings.InputChanged", "This setting changed. Your draft is preserved; go back and reopen the setting."))
            if result.error == nil, self.settingIsCurrent, self.isScreenVisible, self.scopeIsCurrent() { self.dismiss(animated: true) }
        })
    }
}
