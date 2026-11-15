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
    scopeIsCurrent: @escaping @MainActor () -> Bool) -> ViewController {
    return PluginSettingsController(context: context, actions: actions, pluginId: pluginId,
        title: title, pagePath: pagePath, scopeIsCurrent: scopeIsCurrent, actionScope: actionScope)
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
                                          read: PluginUISettingsReadInvocation) async throws -> PluginUISettingsPageDocument {
    try await requirePluginSettingsScope(scope)
    let json = try await PluginUISettingsReadExecution.withInvocation(read) { try await actions.settings(id) }
    guard read.isCurrent else { throw PluginHostError.superseded("Settings read/page expired before decoding") }
    try await requirePluginSettingsScope(scope)
    let document: PluginUISettingsPageDocument
    do {
        document = try await Task.detached(priority: .userInitiated) {
            return try PluginUISettingsPageDocument.decode(json)
        }.value
    } catch {
        throw PluginUIError(message: pluginText("Settings.InvalidJSON", "Invalid settings response") + "\n" + pluginErrorText(error))
    }
    try Task.checkCancellation()
    guard read.isCurrent else { throw PluginHostError.superseded("Settings read/page expired after decoding") }
    try await requirePluginSettingsScope(scope)
    return document
}

private struct PluginSettingsMutationResult: Sendable {
    let document: PluginUISettingsPageDocument
    let read: PluginUISettingsReadInvocation
    let error: String?
}

/// A callback can throw after persisting a value. Re-read the host in both cases,
/// so the UI never claims that a failed callback rolled a stored value back.
@MainActor private func mutatePluginSettings(actions: PluginManagerActions, id: String, scope: @escaping @MainActor () -> Bool,
                                  actionScope: PluginUISettingsActionScope?, invocation: PluginUISettingsActionInvocation,
                                  mutation: @MainActor () async throws -> Void) async throws -> PluginSettingsMutationResult {
    try await requirePluginSettingsScope(scope)
    var mutationError: String?
    do {
        try await PluginUISettingsActionExecution.withInvocation(invocation, operation: mutation)
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
    private let pagePath: [String]
    private var document: PluginUISettingsPageDocument?
    private var iconImages: [PluginUISettingsRowIdentity: UIImage] = [:]
    private var schemaIsCurrent = false
    private let scopeIsCurrent: @MainActor () -> Bool
    private let actionScope: PluginUISettingsActionScope?
    private var reloadObservation: PluginUISettingsObservation?
    private var runtimeObservation: NSObjectProtocol?
    private var pendingExternalReload = false
    private var externalReloadScheduled = false

    init(context: AccountContext, actions: PluginManagerActions, pluginId: String, title: String, pagePath: [String] = [], scopeIsCurrent: (@MainActor () -> Bool)? = nil, actionScope: PluginUISettingsActionScope? = nil) {
        self.actions = actions
        self.pluginId = pluginId
        self.pageTitle = title
        self.pagePath = pagePath
        self.scopeIsCurrent = scopeIsCurrent ?? MainActor.assumeIsolated { ExteralessPluginRuntime.shared.settingsScope(context: context, pluginId: pluginId) }
        self.actionScope = actionScope ?? MainActor.assumeIsolated { PluginUISettingsActionRegistry.capture(context: context, pluginId: pluginId) }
        super.init(context: context)
        self.reloadObservation = MainActor.assumeIsolated {
            PluginUISettingsRefresh.observe(pluginId: pluginId) { [weak self] in
                guard let self else { return }
                self.actionScope?.invalidate()
                self.schemaIsCurrent = false
                self.pendingExternalReload = true
                self.render()
            }
        }
        self.runtimeObservation = NotificationCenter.default.addObserver(forName: ExteralessPluginRuntime.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.scopeIsCurrent() else { return }
                self.actionScope?.close()
                self.schemaIsCurrent = false
                self.errorText = pluginText("Settings.ScopeExpired", "This plugin or account changed. Go back and reopen settings.")
                self.render()
            }
        }
    }

    deinit {
        self.actionScope?.close()
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
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.actionScope?.setVisible(false)
        super.viewWillDisappear(animated)
    }

    override func refresh() {
        guard !self.isBusy else { return }
        self.actionScope?.invalidate()
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
            guard read.isCurrent else { return }
            self?.apply(document)
        })
    }

    private func apply(_ document: PluginUISettingsPageDocument) {
        self.actionScope?.invalidateActions()
        guard self.scopeIsCurrent() else { self.schemaIsCurrent = false; return }
        do { self.iconImages = try document.icons.mapValues { try PluginUIResources.image($0) } }
        catch {
            self.schemaIsCurrent = false
            self.errorText = String(describing: error)
            return
        }
        self.document = document
        if let error = pluginSettingsAvailabilityError(actions: self.actions, id: self.pluginId) {
            self.schemaIsCurrent = false
            self.errorText = self.errorText ?? error
            return
        }
        let pageExists = document.page(self.pagePath) != nil
        self.schemaIsCurrent = !self.pendingExternalReload && pageExists
        if self.schemaIsCurrent { self.actionScope?.publish() }
        if !pageExists {
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
        let cell = super.tableView(tableView, cellForRowAt: indexPath)
        let id = self.sections[indexPath.section].rows[indexPath.row].id
        PluginUISettingsRowIcon.apply(image: self.iconImages[PluginUISettingsRowIdentity(path: self.pagePath, rowId: id)],
            color: self.presentationData.theme.list.itemAccentColor, to: cell)
        return cell
    }

    private func makeRow(_ item: PluginSetting) -> PluginListRow {
        var row = PluginListRow(id: item.identifier, title: item.title, detail: item.subtext)
        row.enabled = self.schemaIsCurrent && !self.isBusy
        if let callbackId = item.longCallbackId {
            row.longAction = { [weak self] in self?.click(callbackId: callbackId, openPage: nil) }
        }
        switch item.kind {
        case .switch:
            if case let .bool(value) = item.currentValue, let key = item.key {
                row.toggle = (value, { [weak self] updated in self?.update(key: key, value: .bool(updated)) })
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
                guard let self, self.checkAvailability() else { return }
                self.push(PluginSettingSelectorController(context: self.context, actions: self.actions, pluginId: self.pluginId, pagePath: self.pagePath, setting: item, scope: self.scopeIsCurrent, actionScope: self.actionScope?.fork(), updated: { [weak self] document in
                    self?.apply(document)
                }))
            }
        case .input, .edittext:
            let value = item.currentValue?.string ?? ""
            row.detail = [item.subtext, value.isEmpty ? pluginText("Settings.EmptyValue", "Empty") : value].compactMap { $0 }.joined(separator: "\n")
            row.accessory = .disclosure
            row.action = { [weak self] in
                guard let self, self.checkAvailability() else { return }
                self.push(PluginSettingInputController(context: self.context, actions: self.actions, pluginId: self.pluginId, setting: item, scope: self.scopeIsCurrent, actionScope: self.actionScope?.fork(), updated: { [weak self] document in
                    self?.apply(document)
                }))
            }
        case .slider:
            if let range = item.sliderRange, case let .number(value) = item.currentValue, let key = item.key {
                row.slider = PluginListSlider(range: range, value: range.normalize(value), commit: { [weak self] value in
                    self?.update(key: key, value: .number(value))
                })
            }
        case .text:
            if item.red == true { row.style = .destructive } else if item.accent == true { row.style = .accent }
            if item.subPage != nil { row.accessory = .disclosure }
            if item.callbackId != nil || item.subPage != nil {
                row.action = { [weak self] in
                    guard let self, self.checkAvailability() else { return }
                    if let callbackId = item.callbackId {
                        self.click(callbackId: callbackId, openPage: item.subPage == nil ? nil : item.identifier)
                    } else {
                        self.openSubpage(item)
                    }
                }
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
        return !self.isBusy && self.schemaIsCurrent
    }

    private func update(key: String, value: PluginSettingValue) {
        guard self.checkAvailability() else { return }
        let invocation: PluginUISettingsActionInvocation
        do { invocation = try capturePluginSettingsAction(self.actionScope) }
        catch { self.errorText = pluginErrorText(error); self.render(); return }
        let actions = self.actions
        let id = self.pluginId
        let scope = self.scopeIsCurrent
        let actionScope = self.actionScope
        self.schemaIsCurrent = false
        self.perform(title: pluginText("Settings.Saving", "Saving setting…"), operation: {
            return try await mutatePluginSettings(actions: actions, id: id, scope: scope, actionScope: actionScope, invocation: invocation, mutation: {
                try await actions.updateSetting(id, key, value.json())
            })
        }, completion: { [weak self] result in
            guard let self, result.read.isCurrent else { return }
            self.errorText = result.error
            self.apply(result.document)
        })
    }

    private func click(callbackId: String, openPage: String?) {
        guard self.checkAvailability() else { return }
        let invocation: PluginUISettingsActionInvocation
        do { invocation = try capturePluginSettingsAction(self.actionScope) }
        catch { self.errorText = pluginErrorText(error); self.render(); return }
        let actions = self.actions
        let id = self.pluginId
        let scope = self.scopeIsCurrent
        let actionScope = self.actionScope
        self.schemaIsCurrent = false
        self.perform(title: pluginText("Settings.Applying", "Applying plugin action…"), operation: {
            return try await mutatePluginSettings(actions: actions, id: id, scope: scope, actionScope: actionScope, invocation: invocation, mutation: {
                try await actions.click(id, callbackId)
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
    private let updated: (PluginUISettingsPageDocument) -> Void
    private let scopeIsCurrent: @MainActor () -> Bool
    private let actionScope: PluginUISettingsActionScope?
    private var reloadObservation: PluginUISettingsObservation?
    private var pendingExternalReload = false
    private var setting: PluginSetting
    private var selectionIsCurrent = true
    private var hasAppeared = false

    init(context: AccountContext, actions: PluginManagerActions, pluginId: String, pagePath: [String], setting: PluginSetting, scope: @escaping @MainActor () -> Bool, actionScope: PluginUISettingsActionScope?, updated: @escaping (PluginUISettingsPageDocument) -> Void) {
        self.actions = actions
        self.pluginId = pluginId
        self.pagePath = pagePath
        self.setting = setting
        self.updated = updated
        self.scopeIsCurrent = scope
        self.actionScope = actionScope
        super.init(context: context)
        self.actionScope?.publish()
        self.reloadObservation = MainActor.assumeIsolated {
            PluginUISettingsRefresh.observe(pluginId: pluginId) { [weak self] in
                guard let self else { return }
                self.actionScope?.invalidate()
                self.selectionIsCurrent = false
                self.pendingExternalReload = true
                if self.isScreenVisible && !self.isBusy { self.refresh() }
            }
        }
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { self.actionScope?.close() }

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
            guard read.isCurrent else { return }
            self?.apply(document)
        })
    }

    private func apply(_ document: PluginUISettingsPageDocument) {
        self.actionScope?.invalidateActions()
        guard self.scopeIsCurrent() else { self.selectionIsCurrent = false; return }
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
            var row = PluginListRow(id: "choice:\(index)", title: choice)
            row.enabled = !self.isBusy && self.selectionIsCurrent && self.scopeIsCurrent()
            if case let .number(value) = self.setting.currentValue, value == Double(index) { row.accessory = .checkmark }
            row.action = { [weak self] in self?.select(index: index) }
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

    private func select(index: Int) {
        guard self.selectionIsCurrent, self.scopeIsCurrent(), !self.isBusy, let key = self.setting.key else { return }
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
            return try await mutatePluginSettings(actions: actions, id: id, scope: scope, actionScope: actionScope, invocation: invocation, mutation: {
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
    private let updated: (PluginUISettingsPageDocument) -> Void
    private let scopeIsCurrent: @MainActor () -> Bool
    private let actionScope: PluginUISettingsActionScope?
    private var reloadObservation: PluginUISettingsObservation?
    private var settingIsCurrent = true
    private var draft: String

    init(context: AccountContext, actions: PluginManagerActions, pluginId: String, setting: PluginSetting, scope: @escaping @MainActor () -> Bool, actionScope: PluginUISettingsActionScope?, updated: @escaping (PluginUISettingsPageDocument) -> Void) {
        self.actions = actions
        self.pluginId = pluginId
        self.setting = setting
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
                self.settingIsCurrent = false
                self.errorText = pluginText("Settings.InputChanged", "This setting changed. Your draft is preserved; go back and reopen the setting.")
                self.render()
            }
        }
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { self.actionScope?.close() }

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
        guard !self.isBusy, self.scopeIsCurrent(), self.settingIsCurrent, let key = self.setting.key else { return }
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
        self.perform(title: pluginText("Settings.Saving", "Saving setting…"), operation: {
            return try await mutatePluginSettings(actions: actions, id: id, scope: scope, actionScope: actionScope, invocation: invocation, mutation: {
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
