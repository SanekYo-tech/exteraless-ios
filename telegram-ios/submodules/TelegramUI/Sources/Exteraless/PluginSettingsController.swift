import AccountContext
import Display
import Foundation
import PluginHost
import UIKit

private func pluginSettingsAvailabilityError(actions: PluginManagerActions, id: String) -> String? {
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

private func loadPluginSettings(actions: PluginManagerActions, id: String) async throws -> [PluginSetting] {
    let json = try await actions.settings(id)
    do {
        return try await Task.detached(priority: .userInitiated) {
            return try PluginSettingsDocument.decode(json)
        }.value
    } catch {
        throw PluginUIError(message: pluginText("Settings.InvalidJSON", "Invalid settings response") + "\n" + pluginErrorText(error))
    }
}

private struct PluginSettingsMutationResult: Sendable {
    let document: [PluginSetting]
    let error: String?
}

/// A callback can throw after persisting a value. Re-read the host in both cases,
/// so the UI never claims that a failed callback rolled a stored value back.
private func mutatePluginSettings(actions: PluginManagerActions, id: String, mutation: () async throws -> Void) async throws -> PluginSettingsMutationResult {
    var mutationError: String?
    do {
        try await mutation()
    } catch {
        mutationError = pluginErrorText(error)
    }
    do {
        let document = try await loadPluginSettings(actions: actions, id: id)
        return PluginSettingsMutationResult(document: document, error: mutationError)
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
    private var document: [PluginSetting]?
    private var schemaIsCurrent = false

    init(context: AccountContext, actions: PluginManagerActions, pluginId: String, title: String, pagePath: [String] = []) {
        self.actions = actions
        self.pluginId = pluginId
        self.pageTitle = title
        self.pagePath = pagePath
        super.init(context: context)
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func refresh() {
        guard !self.isBusy else { return }
        self.schemaIsCurrent = false
        if let error = pluginSettingsAvailabilityError(actions: self.actions, id: self.pluginId) {
            self.errorText = error
            self.tableView.refreshControl?.endRefreshing()
            self.render()
            return
        }
        let actions = self.actions
        let id = self.pluginId
        self.perform(title: pluginText("Settings.Loading", "Loading settings…"), operation: {
            return try await loadPluginSettings(actions: actions, id: id)
        }, completion: { [weak self] document in
            self?.apply(document)
        })
    }

    private func apply(_ document: [PluginSetting]) {
        self.document = document
        if let error = pluginSettingsAvailabilityError(actions: self.actions, id: self.pluginId) {
            self.schemaIsCurrent = false
            self.errorText = self.errorText ?? error
            return
        }
        self.schemaIsCurrent = PluginSettingsDocument.page(in: document, path: self.pagePath) != nil
        if !self.schemaIsCurrent {
            self.errorText = pluginText("Settings.PageMissing", "This settings page is no longer available. Go back to the previous page.")
        }
    }

    override func render() {
        self.title = self.pageTitle
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: pluginText("Refresh", "Refresh"), style: .plain, target: self, action: #selector(self.reloadPressed))
        self.navigationItem.rightBarButtonItem?.isEnabled = !self.isBusy
        var sections = self.operationSections()
        if let document = self.document, let page = PluginSettingsDocument.page(in: document, path: self.pagePath) {
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
                self.push(PluginSettingSelectorController(context: self.context, actions: self.actions, pluginId: self.pluginId, pagePath: self.pagePath, setting: item, updated: { [weak self] document in
                    self?.apply(document)
                }))
            }
        case .input, .edittext:
            let value = item.currentValue?.string ?? ""
            row.detail = [item.subtext, value.isEmpty ? pluginText("Settings.EmptyValue", "Empty") : value].compactMap { $0 }.joined(separator: "\n")
            row.accessory = .disclosure
            row.action = { [weak self] in
                guard let self, self.checkAvailability() else { return }
                self.push(PluginSettingInputController(context: self.context, actions: self.actions, pluginId: self.pluginId, setting: item, updated: { [weak self] document in
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
        let actions = self.actions
        let id = self.pluginId
        self.schemaIsCurrent = false
        self.perform(title: pluginText("Settings.Saving", "Saving setting…"), operation: {
            return try await mutatePluginSettings(actions: actions, id: id, mutation: {
                try await actions.updateSetting(id, key, value.json())
            })
        }, completion: { [weak self] result in
            guard let self else { return }
            self.errorText = result.error
            self.apply(result.document)
        })
    }

    private func click(callbackId: String, openPage: String?) {
        guard self.checkAvailability() else { return }
        let actions = self.actions
        let id = self.pluginId
        self.schemaIsCurrent = false
        self.perform(title: pluginText("Settings.Applying", "Applying plugin action…"), operation: {
            return try await mutatePluginSettings(actions: actions, id: id, mutation: {
                try await actions.click(id, callbackId)
            })
        }, completion: { [weak self] result in
            guard let self else { return }
            self.errorText = result.error
            self.apply(result.document)
            if self.errorText == nil, self.schemaIsCurrent, self.isScreenVisible, let identifier = openPage {
                if let item = PluginSettingsDocument.page(in: result.document, path: self.pagePath)?.first(where: { $0.identifier == identifier }), item.subPage != nil {
                    self.openSubpage(item)
                } else {
                    self.errorText = pluginText("Settings.PageMissing", "This settings page is no longer available. Go back to the previous page.")
                }
            }
        })
    }

    private func openSubpage(_ item: PluginSetting) {
        guard item.subPage != nil else { return }
        self.push(PluginSettingsController(context: self.context, actions: self.actions, pluginId: self.pluginId, title: item.title, pagePath: self.pagePath + [item.identifier]))
    }

    @objc private func reloadPressed() {
        self.refresh()
    }
}

private final class PluginSettingSelectorController: PluginListController {
    private let actions: PluginManagerActions
    private let pluginId: String
    private let pagePath: [String]
    private let updated: ([PluginSetting]) -> Void
    private var setting: PluginSetting
    private var selectionIsCurrent = true
    private var hasAppeared = false

    init(context: AccountContext, actions: PluginManagerActions, pluginId: String, pagePath: [String], setting: PluginSetting, updated: @escaping ([PluginSetting]) -> Void) {
        self.actions = actions
        self.pluginId = pluginId
        self.pagePath = pagePath
        self.setting = setting
        self.updated = updated
        super.init(context: context)
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func refresh() {
        guard !self.isBusy else { return }
        let firstAppearance = !self.hasAppeared
        self.hasAppeared = true
        if let error = pluginSettingsAvailabilityError(actions: self.actions, id: self.pluginId) {
            self.selectionIsCurrent = false
            self.errorText = error
            self.tableView.refreshControl?.endRefreshing()
            self.render()
            return
        }
        if firstAppearance {
            self.render()
            return
        }
        let actions = self.actions
        let id = self.pluginId
        self.selectionIsCurrent = false
        self.perform(title: pluginText("Settings.Loading", "Loading settings…"), operation: {
            return try await loadPluginSettings(actions: actions, id: id)
        }, completion: { [weak self] document in
            self?.apply(document)
        })
    }

    private func apply(_ document: [PluginSetting]) {
        self.updated(document)
        if let error = pluginSettingsAvailabilityError(actions: self.actions, id: self.pluginId) {
            self.selectionIsCurrent = false
            self.errorText = self.errorText ?? error
            return
        }
        if let setting = PluginSettingsDocument.page(in: document, path: self.pagePath)?.first(where: { $0.identifier == self.setting.identifier }), setting.kind == .selector {
            self.setting = setting
            self.selectionIsCurrent = true
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
            row.enabled = !self.isBusy && self.selectionIsCurrent
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
    }

    private func select(index: Int) {
        guard self.selectionIsCurrent, !self.isBusy, let key = self.setting.key else { return }
        if let error = pluginSettingsAvailabilityError(actions: self.actions, id: self.pluginId) {
            self.selectionIsCurrent = false
            self.errorText = error
            self.render()
            return
        }
        let actions = self.actions
        let id = self.pluginId
        self.selectionIsCurrent = false
        self.perform(title: pluginText("Settings.Saving", "Saving setting…"), operation: {
            return try await mutatePluginSettings(actions: actions, id: id, mutation: {
                try await actions.updateSetting(id, key, PluginSettingValue.number(Double(index)).json())
            })
        }, completion: { [weak self] result in
            guard let self else { return }
            self.errorText = result.error
            self.apply(result.document)
            if self.errorText == nil, self.isScreenVisible { self.dismiss(animated: true) }
        })
    }
}

private final class PluginSettingInputController: PluginListController {
    private let actions: PluginManagerActions
    private let pluginId: String
    private let setting: PluginSetting
    private let updated: ([PluginSetting]) -> Void
    private var draft: String

    init(context: AccountContext, actions: PluginManagerActions, pluginId: String, setting: PluginSetting, updated: @escaping ([PluginSetting]) -> Void) {
        self.actions = actions
        self.pluginId = pluginId
        self.setting = setting
        self.updated = updated
        self.draft = setting.currentValue?.string ?? ""
        super.init(context: context)
        self.allowsRefresh = false
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func render() {
        self.title = self.setting.title
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Save, style: .done, target: self, action: #selector(self.savePressed))
        self.updateSaveButton()
        var sections = self.operationSections()
        var row = PluginListRow(id: "input", title: self.setting.title, detail: self.setting.subtext)
        row.enabled = !self.isBusy
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
        self.navigationItem.rightBarButtonItem?.isEnabled = !self.isBusy && lengthValid
    }

    @objc private func savePressed() {
        guard !self.isBusy, let key = self.setting.key else { return }
        if let maximum = self.setting.maxLength, self.draft.unicodeScalars.count > maximum { return }
        if let error = pluginSettingsAvailabilityError(actions: self.actions, id: self.pluginId) {
            self.errorText = error
            self.render()
            return
        }
        self.view.endEditing(true)
        let actions = self.actions
        let id = self.pluginId
        let draft = self.draft
        self.perform(title: pluginText("Settings.Saving", "Saving setting…"), operation: {
            return try await mutatePluginSettings(actions: actions, id: id, mutation: {
                try await actions.updateSetting(id, key, PluginSettingValue.string(draft).json())
            })
        }, completion: { [weak self] result in
            guard let self else { return }
            self.updated(result.document)
            self.errorText = result.error
            if result.error == nil, self.isScreenVisible { self.dismiss(animated: true) }
        })
    }
}
